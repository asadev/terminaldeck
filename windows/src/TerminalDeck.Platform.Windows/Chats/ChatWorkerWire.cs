using System.IO.Pipes;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed record ChatWorkerPlan(ChatRecord Chat, string ToolsDirectory, bool CodexAppServer);
public sealed record ChatWorkerIdentity(int Pid, long StartedUtcTicks, string Key, string ChatId);
public sealed record ChatWorkerState(ChatDelivery[] Deliveries, ChatSignal[] Signals, long Sequence, bool ProcessAlive, string? ConversationId);
public sealed class ChatWorkerRequest
{
  public required string Secret { get; init; }
  public required string Key { get; init; }
  public required string Operation { get; init; }
  public long After { get; init; }
  public ChatMessage? Message { get; init; }
  public string? RequestId { get; init; }
  public bool Allow { get; init; }
  public override string ToString() => "<private chat worker request>";
}
public sealed record ChatWorkerReply(ChatWorkerState? Snapshot = null, ChatSignal? Signal = null, ChatDelivery? Delivery = null, bool Success = false, string? Problem = null);
public static class ChatWorkerPaths
{
  public static string DirectoryFor(AppDataRoot root) => Path.Combine(root.DirectoryPath, "keeper", "chat-workers");
  public static string FileFor(AppDataRoot root, string key, string suffix) => Path.Combine(DirectoryFor(root), WorkerPaths.Key(key) + suffix);
  public static string Pipe(AppDataRoot root, string key) => "terminaldeck-chat-" + root.NamespaceId + "-" + WorkerPaths.Key(key);
  public static async ValueTask<NamedPipeClientStream> ConnectAsync(AppDataRoot root, string key, CancellationToken ct)
  {
    var pipe = new NamedPipeClientStream(".", Pipe(root, key), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try { await pipe.ConnectAsync(1500, ct); return pipe; }
    catch { await pipe.DisposeAsync(); throw; }
  }
}
