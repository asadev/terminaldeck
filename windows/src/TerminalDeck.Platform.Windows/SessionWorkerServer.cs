using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// This process, rather than the supervisor, owns HPCON and the complete job.
public sealed class SessionWorkerServer(AppDataRoot root, WorkerLaunch launch, ReadOnlyMemory<byte> credential)
{
  private readonly object gate = new();
  private readonly Dictionary<Guid, Channel<SessionEvent>> watchers = [];
  private readonly CancellationTokenSource stopping = new();
  private ConPtyProcess? terminal;
  private string replay = "";
  private ulong sequence;
  private int? exitCode;
  private string Key => launch.Session.CreationKey;
  private string Id => launch.Session.Definition.Id;

  public async Task RunAsync(CancellationToken ct)
  {
    WindowsPrivateDirectory.Ensure(WorkerPaths.DirectoryFor(root));
    using var ownership = new FileStream(WorkerPaths.PathFor(root, Key, ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
    using var process = Process.GetCurrentProcess();
    var identity = new WorkerIdentity(process.Id, process.StartTime.ToUniversalTime().Ticks, Key, Id);
    File.WriteAllBytes(WorkerPaths.PathFor(root, Key, ".identity.json"), JsonSerializer.SerializeToUtf8Bytes(identity));
    terminal = (ConPtyProcess)await new ConPtyTerminalFactory().StartAsync(launch.Process, launch.Size, ct);
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct, stopping.Token);
    var output = PumpAsync(lifetime.Token);
    var exit = ObserveExitAsync(lifetime.Token);
    var clients = new ConcurrentDictionary<Guid, Task>();
    using var slots = new SemaphoreSlim(16);
    try
    {
      while (!lifetime.IsCancellationRequested)
      {
        await slots.WaitAsync(lifetime.Token);
        NamedPipeServerStream? pipe = null;
        try
        {
          pipe = new(WorkerPaths.Pipe(root, Key), PipeDirection.InOut, 16, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);
          await pipe.WaitForConnectionAsync(lifetime.Token);
          var accepted = pipe; var client = Guid.NewGuid();
          var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          async Task Serve()
          {
            await start.Task;
            try { await ServeAsync(accepted, lifetime.Token); }
            finally { clients.TryRemove(client, out _); slots.Release(); }
          }
          clients[client] = Serve(); start.SetResult(); pipe = null;
        }
        catch { pipe?.Dispose(); slots.Release(); throw; }
      }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    finally
    {
      lifetime.Cancel(); await terminal.DisposeAsync();
      try { await Task.WhenAll(output, exit); } catch (OperationCanceledException) { }
      await Task.WhenAll(clients.Values);
    }
  }
  private WorkerSnapshot Snapshot() => new(Key, Id, sequence, replay, terminal!.ActiveProcessCount, terminal.RootExited, exitCode);
  private void Publish(string kind, string? text = null)
  {
    var change = new SessionEvent(++sequence, Id, kind, text, exitCode);
    foreach (var channel in watchers.Values) if (!channel.Writer.TryWrite(change)) channel.Writer.TryComplete(new IOException("Reattach to this worker."));
  }
  private async Task PumpAsync(CancellationToken ct)
  {
    var decoder = Encoding.UTF8.GetDecoder();
    await foreach (var bytes in terminal!.ReadOutputAsync(ct))
    {
      var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
      var count = decoder.GetChars(bytes.Span, chars, flush: false); var text = new string(chars, 0, count);
      lock (gate)
      {
        replay += text;
        if (replay.Length > 256 * 1024) { var offset = replay.Length - 256 * 1024; if (char.IsLowSurrogate(replay[offset])) offset++; replay = replay[offset..]; }
        Publish("data", text);
      }
    }
  }
  private async Task ObserveExitAsync(CancellationToken ct)
  {
    var code = await terminal!.WaitForExitAsync(ct);
    await terminal.WaitForTreeExitAsync(ct);
    await terminal.FinishAsync(ct);
    lock (gate) { exitCode = code; Publish("status"); }
  }
  private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken ct)
  {
    await using (pipe)
    {
      Guid? watching = null;
      try
      {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        var request = await KeeperWire.ReadAsync<WorkerRequest>(pipe, cancellationToken: deadline.Token);
        if (request.CreationKey != Key || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Secret), credential.Span)) return;
        switch (request.Operation)
        {
          case "snapshot":
            WorkerSnapshot current; lock (gate) current = Snapshot();
            await KeeperWire.WriteAsync(pipe, new WorkerMessage(Snapshot: current), true, ct); break;
          case "watch":
            var channel = Channel.CreateBounded<SessionEvent>(SessionAttachment.EventBuffer); WorkerSnapshot snapshot;
            lock (gate) { watching = Guid.NewGuid(); watchers[watching.Value] = channel; snapshot = Snapshot(); }
            await KeeperWire.WriteAsync(pipe, new WorkerMessage(Snapshot: snapshot), true, ct);
            await foreach (var change in channel.Reader.ReadAllAsync(ct)) await KeeperWire.WriteAsync(pipe, new WorkerMessage(Event: change), true, ct);
            break;
          case "write":
            if (request.Bytes is null || request.Bytes.Length > KeeperWire.MaximumInputBytes) return;
            await terminal!.WriteAsync(request.Bytes, ct); await KeeperWire.WriteAsync(pipe, new WorkerMessage(Success: true), true, ct); break;
          case "resize":
            await terminal!.ResizeAsync(request.Size ?? throw new ArgumentException(), ct); await KeeperWire.WriteAsync(pipe, new WorkerMessage(Success: true), true, ct); break;
          case "quit":
            await terminal!.QuitAsync(ct); await KeeperWire.WriteAsync(pipe, new WorkerMessage(Success: true), true, ct); stopping.Cancel(); break;
        }
      }
      catch (Exception ex) when (ex is IOException or OperationCanceledException or ArgumentException or InvalidOperationException) { }
      finally { if (watching is { } id) lock (gate) watchers.Remove(id); }
    }
  }
}
