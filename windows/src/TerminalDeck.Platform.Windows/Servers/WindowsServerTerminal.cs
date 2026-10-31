using System.Collections.Concurrent;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Platform.Windows.Servers;

// The integration owner supplies the existing session service. No server
// terminal process is started outside that service's PTY and session lifetime.
public sealed class WindowsServerTerminal(WindowsOpenSshRuntime runtime,
  Func<SavedServer, ProcessLaunch, CancellationToken, ValueTask<string>> startSession) : IServerTerminal, IAsyncDisposable
{
  private readonly ConcurrentDictionary<OpenSshTerminalLease, Task> handshakes = new();
  public async ValueTask<string> OpenAsync(ServerTerminalRequest request, CancellationToken ct)
  {
    var lease = await runtime.PrepareTerminalAsync(request.Server, ct);
    try
    {
      var id = await startSession(request.Server, lease.Launch, ct);
      var task = FinishAsync(lease); handshakes.TryAdd(lease, task);
      _ = task.ContinueWith(_ => handshakes.TryRemove(lease, out var ignored), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
      return id;
    }
    catch { await lease.DisposeAsync(); throw; }
  }
  private static async Task FinishAsync(OpenSshTerminalLease lease)
  {
    try { await lease.Handshake; } catch (Exception ex) when (ex is OperationCanceledException or IOException) { }
    finally { await lease.DisposeAsync(); }
  }
  public async ValueTask DisposeAsync()
  {
    foreach (var pair in handshakes.ToArray()) { await pair.Key.DisposeAsync(); await pair.Value; }
  }
}
