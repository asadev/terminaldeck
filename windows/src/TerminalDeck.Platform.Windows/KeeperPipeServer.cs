using System.Collections.Concurrent;
using System.IO.Pipes;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// Listener lifetime is separate from session lifetime. Stopping this listener
// closes its own streams only; it never stops a process or another keeper.
public sealed class KeeperPipeServer(AppDataRoot root, KeeperEndpoint endpoint)
{
  private readonly SemaphoreSlim slots = new(KeeperWire.MaximumConnections);
  private readonly ConcurrentDictionary<Guid, Task> clients = [];
  private int running;
  public async Task RunAsync(CancellationToken stopToken)
  {
    if (Interlocked.Exchange(ref running, 1) != 0) throw new InvalidOperationException("This keeper listener is already running.");
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stopToken);
    var cancellationToken = lifetime.Token;
    try
    {
      while (!cancellationToken.IsCancellationRequested)
      {
        await slots.WaitAsync(cancellationToken);
        NamedPipeServerStream? pipe = null;
        try
        {
          pipe = new NamedPipeServerStream("terminaldeck-" + root.NamespaceId, PipeDirection.InOut, KeeperWire.MaximumConnections,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);
          await pipe.WaitForConnectionAsync(cancellationToken);
          var id = Guid.NewGuid(); var accepted = pipe;
          // Start after publication so even immediate completion removes the right entry.
          var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          var task = ServeAfterStartAsync(id, accepted, start.Task, cancellationToken); clients[id] = task; start.SetResult(); pipe = null;
        }
        catch { if (pipe is not null) await pipe.DisposeAsync(); slots.Release(); throw; }
      }
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    finally { lifetime.Cancel(); await Task.WhenAll(clients.Values); Interlocked.Exchange(ref running, 0); }
  }
  private async Task ServeAfterStartAsync(Guid id, NamedPipeServerStream pipe, Task start, CancellationToken ct)
  {
    await start;
    try
    {
      await using (pipe)
      {
        while (pipe.IsConnected && !ct.IsCancellationRequested)
        {
          // A stalled unauthenticated client cannot occupy a slot forever.
          using var readDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct); readDeadline.CancelAfter(TimeSpan.FromSeconds(15));
          var request = await KeeperWire.ReadAsync<KeeperRequest>(pipe, cancellationToken: readDeadline.Token);
          if (request.Operation == "watch")
          {
            await using var attachment = await endpoint.WatchAsync(request, ct);
            await KeeperWire.WriteAsync(pipe, new KeeperResponse(Snapshot: attachment.Snapshot), response: true, ct);
            await foreach (var change in attachment.Events(ct)) await KeeperWire.WriteAsync(pipe, new KeeperResponse(Event: change), response: true, ct);
            break;
          }
          var response = await endpoint.HandleAsync(request, ct);
          await KeeperWire.WriteAsync(pipe, response, response: true, ct);
        }
      }
    }
    catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or KeyNotFoundException)
    { /* Close silently. No credentials, launch input or peer text goes to logs. */ }
    finally { clients.TryRemove(id, out _); slots.Release(); }
  }
}
