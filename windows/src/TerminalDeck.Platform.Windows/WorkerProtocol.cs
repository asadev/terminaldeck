using System.IO.Pipes;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public sealed record WorkerLaunch(SessionRecord Session, ProcessLaunch Process, TerminalSize Size);
public sealed record WorkerIdentity(int Pid, long StartedUtcTicks, string CreationKey, string SessionId);
public sealed record WorkerSnapshot(string CreationKey, string SessionId, ulong Sequence, string Replay, int ActiveProcesses, bool RootExited, int? ExitCode);
public sealed record WorkerMessage(WorkerSnapshot? Snapshot = null, SessionEvent? Event = null, bool? Success = null);
public sealed class WorkerRequest
{
  public required string Secret { get; init; }
  public required string Operation { get; init; }
  public required string CreationKey { get; init; }
  public byte[]? Bytes { get; init; }
  public TerminalSize? Size { get; init; }
  public override string ToString() => "<private worker request>";
}
public static class WorkerPaths
{
  public static string Key(string key) => Guid.TryParseExact(key, "N", out _) ? key : throw new ArgumentException("Choose a valid session worker.");
  public static string DirectoryFor(AppDataRoot root) => Path.Combine(root.DirectoryPath, "keeper", "workers");
  public static string PathFor(AppDataRoot root, string key, string suffix) => Path.Combine(DirectoryFor(root), Key(key) + suffix);
  public static string Pipe(AppDataRoot root, string key) => "terminaldeck-worker-" + root.NamespaceId + "-" + Key(key);
  public static async ValueTask<NamedPipeClientStream> ConnectAsync(AppDataRoot root, string key, CancellationToken ct)
  {
    var pipe = new NamedPipeClientStream(".", Pipe(root, key), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try { await pipe.ConnectAsync(1500, ct); return pipe; }
    catch { await pipe.DisposeAsync(); throw; }
  }
}
