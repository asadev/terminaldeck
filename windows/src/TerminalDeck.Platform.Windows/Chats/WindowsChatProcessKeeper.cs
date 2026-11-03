using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed class WindowsChatProcessKeeper(AppDataRoot root, string keeperExecutable, string toolsDirectory, ReadOnlyMemory<byte> credential,
  bool codexAppServer = true) : IChatProcessKeeper, IChatRecoveryJournal
{
  private readonly string secret = Convert.ToBase64String(credential.Span);
  private ChatWorkerRequest Request(string key, string operation) => new() { Secret = secret, Key = key, Operation = operation };
  private async ValueTask<ChatWorkerReply> CallAsync(ChatWorkerRequest request, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(65));
    await using var pipe = await ChatWorkerPaths.ConnectAsync(root, request.Key, deadline.Token);
    await KeeperWire.WriteAsync(pipe, request, cancellationToken: deadline.Token);
    var reply = await KeeperWire.ReadAsync<ChatWorkerReply>(pipe, true, deadline.Token);
    if (reply.Problem is not null) throw new IOException(reply.Problem);
    return reply;
  }
  public async ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken cancellationToken)
  {
    try
    {
      var reply = await CallAsync(Request(session.CreationKey, "snapshot"), cancellationToken);
      return reply.Snapshot is null ? new(ProcessPresence.Unknown) : new(ProcessPresence.Live, session.CreationKey);
    }
    catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException && !cancellationToken.IsCancellationRequested)
    {
      var path = ChatWorkerPaths.FileFor(root, session.CreationKey, ".identity.json");
      if (!File.Exists(path)) return new(session.HasStarted ? ProcessPresence.Unknown : ProcessPresence.Dead);
      ChatWorkerIdentity? identity;
      try { identity = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(path)); }
      catch (Exception e) when (e is IOException or JsonException) { return new(ProcessPresence.Unknown); }
      if (identity is null || identity.Key != session.CreationKey || identity.ChatId != session.Definition.Id) return new(ProcessPresence.Unknown);
      try
      {
        using var process = Process.GetProcessById(identity.Pid);
        return new(process.StartTime.ToUniversalTime().Ticks == identity.StartedUtcTicks && !process.HasExited ? ProcessPresence.Unknown : ProcessPresence.Dead);
      }
      catch (ArgumentException) { return new(ProcessPresence.Dead); }
      catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return new(ProcessPresence.Unknown); }
    }
  }
  public async ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken cancellationToken)
  {
    WindowsPrivateDirectory.Ensure(ChatWorkerPaths.DirectoryFor(root));
    await using var creation = new FileStream(ChatWorkerPaths.FileFor(root, session.CreationKey, ".create"), FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
    var before = await ObserveAsync(session, cancellationToken); if (before.Presence != ProcessPresence.Dead) return before;
    if (File.Exists(ChatWorkerPaths.FileFor(root, session.CreationKey, ".identity.json"))) return new(ProcessPresence.Dead);
    var chat = new ChatHistory(root).Load(session.Definition.Id) ?? throw new IOException("This chat history is missing.");
    _ = new WindowsChatLaunchPlanner(root, toolsDirectory, codexAppServer).Plan(chat);
    var bytes = JsonSerializer.SerializeToUtf8Bytes(new ChatWorkerPlan(chat, toolsDirectory, codexAppServer));
    var path = ChatWorkerPaths.FileFor(root, session.CreationKey, ".launch"); var temporary = path + "." + Guid.NewGuid().ToString("N");
    try { File.WriteAllBytes(temporary, new CurrentUserDpapi(root).Protect(bytes)); File.Move(temporary, path, true); }
    finally { CryptographicOperations.ZeroMemory(bytes); if (File.Exists(temporary)) File.Delete(temporary); }
    DetachedProcess.Start(keeperExecutable, ["--user-data-dir", root.DirectoryPath, "--chat-worker", session.CreationKey], Path.GetDirectoryName(keeperExecutable)!);
    for (var attempt = 0; attempt < 12; attempt++)
    {
      var observed = await ObserveAsync(session, cancellationToken);
      if (observed.Presence == ProcessPresence.Live) return observed;
      await Task.Delay(100, cancellationToken);
    }
    return new(ProcessPresence.Unknown, session.CreationKey);
  }
  public async ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken cancellationToken) =>
    (await CallAsync(new() { Secret = secret, Key = chat.CreationKey, Operation = "send", Message = message }, cancellationToken)).Delivery ?? throw new IOException("This chat did not acknowledge its message.");
  public async ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, JsonElement input, CancellationToken cancellationToken) =>
    _ = await CallAsync(new() { Secret = secret, Key = chat.CreationKey, Operation = "answer", RequestId = requestId, Allow = allow }, cancellationToken);
  public async ValueTask InterruptAsync(ChatRecord chat, CancellationToken cancellationToken) => _ = await CallAsync(Request(chat.CreationKey, "interrupt"), cancellationToken);
  public async ValueTask QuitAsync(string leaseIdentity, CancellationToken cancellationToken)
  {
    var identity = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, leaseIdentity, ".identity.json"))) ?? throw new IOException("This chat worker needs to reconnect.");
    _ = await CallAsync(Request(leaseIdentity, "quit"), cancellationToken);
    try
    {
      using var worker = Process.GetProcessById(identity.Pid);
      if (worker.StartTime.ToUniversalTime().Ticks != identity.StartedUtcTicks) return;
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); deadline.CancelAfter(TimeSpan.FromSeconds(15));
      await worker.WaitForExitAsync(deadline.Token);
    }
    catch (ArgumentException) { }
  }
  public ValueTask<IReadOnlyList<ChatSignal>> ReadSavedSignalsAsync(ChatRecord chat, long after, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested(); var path = ChatWorkerPaths.FileFor(root, chat.CreationKey, ".journal.json");
    if (!File.Exists(path)) return ValueTask.FromResult<IReadOnlyList<ChatSignal>>([]);
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    if (stream.Length > 128L * 1024 * 1024) throw new IOException("This chat worker’s saved events are too large to read safely.");
    var journal = JsonSerializer.Deserialize<ChatWorkerJournal>(stream) ?? throw new IOException("This chat worker’s saved events could not be read.");
    return ValueTask.FromResult<IReadOnlyList<ChatSignal>>(journal.Signals.Where(s => s.Sequence > after).ToArray());
  }
  public ValueTask WriteAsync(string leaseIdentity, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken) => throw new InvalidOperationException("Send a chat message with its client id.");
  public ValueTask ResizeAsync(string leaseIdentity, TerminalSize size, CancellationToken cancellationToken) => ValueTask.CompletedTask;
  public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
  {
    await using var pipe = await ChatWorkerPaths.ConnectAsync(root, chat.CreationKey, cancellationToken);
    await KeeperWire.WriteAsync(pipe, new ChatWorkerRequest { Secret = secret, Key = chat.CreationKey, Operation = "watch", After = after }, cancellationToken: cancellationToken);
    while (!cancellationToken.IsCancellationRequested)
    {
      var reply = await KeeperWire.ReadAsync<ChatWorkerReply>(pipe, true, cancellationToken);
      yield return reply.Signal ?? throw new IOException("Reconnect to read this chat.");
    }
  }
}
