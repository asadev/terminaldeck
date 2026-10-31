using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Chats;

public enum ChatMessageState { Queued, Dispatching, Sent, Uncertain, Failed, Removed }
public sealed record ChatOptions(string Model = "", string Effort = "");
public sealed record ChatMedia(string Id, string Name, string MimeType, string RelativePath, int Width, int Height, long Bytes);
public sealed record ChatMessage(string ClientId, string Text, ChatMedia[] Media, ChatMessageState State = ChatMessageState.Queued);
public sealed record ChatEvent(long Sequence, string Kind, string Id, string Text = "", string? ClientId = null,
  JsonElement? Data = null, DateTimeOffset At = default);
public sealed record ChatDefinition(string Id, string Provider, string Cwd, string Title, string AccountId, string AccountHome, ChatOptions Options, string Instructions = "", AiPermissionMode PermissionMode = AiPermissionMode.Ask)
{
  public void Validate(bool allowSavedUnsupportedChoices = false)
  {
    ChatPermissionModes.Validate(Provider, PermissionMode);
    if (!allowSavedUnsupportedChoices && Provider == "gemini" && Options.Effort is not ("" or "auto"))
      throw new ArgumentException("Gemini does not offer an effort choice. Choose Automatic before starting this chat.");
    if (!Guid.TryParseExact(Id, "D", out var identity) || Id != identity.ToString() || Provider is not ("claude" or "codex" or "gemini") || !Path.IsPathFullyQualified(Cwd) ||
        !Guid.TryParseExact(AccountId, "N", out _) || !Guid.TryParseExact(AccountHome, "N", out _) || Title.Length > 120 ||
        Title.Any(char.IsControl) || Instructions.Length > 128000 || Instructions.Contains('\0') || Options.Model.Length > 160 || Options.Model.Any(char.IsControl) ||
        Options.Effort is not ("" or "auto" or "low" or "medium" or "high" or "xhigh" or "max"))
      throw new ArgumentException("Choose a chat, folder, account and model.");
  }
}
public sealed record ChatRecord(int Version, ChatDefinition Definition, string CreationKey, ChatEvent[] Events, ChatMessage[] Messages,
  long WorkerSequence = 0, bool Busy = false, string? ActiveClientId = null, string? ConversationId = null, string? Problem = null,
  DateTimeOffset? WaitingSince = null, bool Paused = false, bool Stopping = false, bool Ended = false,
  long AccountRevision = 0, string? LastAccountSwitch = null, bool HasCustomTitle = false);
public sealed record ChatSignal(long Sequence, string Kind, string Id = "", string Text = "", string? ClientId = null, JsonElement? Data = null);
public sealed record ChatDelivery(string ClientId, ChatMessageState State);

// A worker must journal the client id before touching stdin. A lost reply is
// reconciled with that same id; uncertain writes are retained and never replayed.
public interface IChatProcessKeeper : ISessionProcessKeeper
{
  ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken cancellationToken);
  ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, JsonElement input, CancellationToken cancellationToken);
  ValueTask InterruptAsync(ChatRecord chat, CancellationToken cancellationToken);
  IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, CancellationToken cancellationToken);
}
public interface IChatRecoveryJournal
{
  ValueTask<IReadOnlyList<ChatSignal>> ReadSavedSignalsAsync(ChatRecord chat, long after, CancellationToken cancellationToken);
}
public interface IChatHistory
{
  AppDataRoot? DataRoot => null;
  IReadOnlyList<ChatRecord> List();
  ChatRecord? Load(string id);
  void Save(ChatRecord chat);
  ValueTask<ChatMedia> AddImageAsync(string id, string name, string mimeType, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken cancellationToken);
  byte[] ReadMedia(string id, ChatMedia media);
  JsonElement ExternalizeData(string id, JsonElement data);
}
public interface IChatSessions
{
  AppDataRoot? DataRoot => null;
  IReadOnlyList<ChatRecord> List();
  ChatRecord Get(string id);
  ValueTask<ChatRecord> ReadAsync(string id, CancellationToken cancellationToken = default) => ValueTask.FromResult(Get(id));
  ValueTask<ChatRecord> CreateAsync(ChatDefinition definition, string? conversationId = null, CancellationToken cancellationToken = default);
  ValueTask<ChatRecord> CreateAsync(string provider, string folder, string accountId, ChatOptions? options = null, CancellationToken cancellationToken = default);
  ValueTask SendAsync(string id, string clientId, string text, ChatMedia[]? media = null, CancellationToken cancellationToken = default);
  ValueTask SendNowAsync(string id, string clientId, CancellationToken cancellationToken = default);
  ValueTask EditQueuedAsync(string id, string clientId, string text, CancellationToken cancellationToken = default);
  ValueTask RemoveQueuedAsync(string id, string clientId, CancellationToken cancellationToken = default);
  ValueTask AnswerAsync(string id, string requestId, bool allow, CancellationToken cancellationToken = default);
  ValueTask StopAsync(string id, CancellationToken cancellationToken = default);
  ValueTask ContinueWithoutResendingAsync(string id, CancellationToken cancellationToken = default);
  ValueTask EndAsync(string id, CancellationToken cancellationToken = default);
  ValueTask RetryAsync(string id, CancellationToken cancellationToken = default);
  ValueTask SetOptionsAsync(string id, ChatOptions options, CancellationToken cancellationToken = default);
  ValueTask SetAccountAsync(string id, string accountId, CancellationToken cancellationToken = default);
  ValueTask RenameAsync(string id, string title, CancellationToken cancellationToken = default) => ValueTask.FromException(new NotSupportedException("This chat cannot be renamed."));
  ValueTask SetPermissionAsync(string id, AiPermissionMode mode, CancellationToken cancellationToken = default) => ValueTask.FromException(new NotSupportedException("This chat cannot change permissions."));
  ValueTask<bool> CanSwitchAccountAsync(string id, string accountId, CancellationToken cancellationToken = default) => ValueTask.FromResult(false);
  ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string id, CancellationToken cancellationToken = default);
  IReadOnlyList<AccountProfile> Accounts(string id);
  ValueTask SignInAsync(string id, CancellationToken cancellationToken = default);
  ValueTask<ChatMedia> AddImageAsync(string id, string name, string mimeType, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken cancellationToken = default);
  byte[] ReadImage(string id, ChatMedia media);
  ValueTask<byte[]> ReadImageAsync(string id, ChatMedia media, CancellationToken cancellationToken = default) => ValueTask.FromResult(ReadImage(id, media));
  IAsyncEnumerable<ChatRecord> WatchAsync(string id, CancellationToken cancellationToken = default);
  ValueTask ReconnectAsync(string id, CancellationToken cancellationToken = default);
  ValueTask RecoverAsync(CancellationToken cancellationToken = default);
}
