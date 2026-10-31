using System.Collections.Immutable;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Hoot;

public enum HootTurnState { Queued, Dispatching, Running, Finished, Failed, Stopped, Uncertain }
public sealed record HootSettings(string Provider, string AccountId, string Folder, ChatOptions Options,
  int RefreshMinutes = 0, int RefreshAfterTurns = 0, AiPermissionMode PermissionMode = AiPermissionMode.Ask);
public sealed record HootSource(string Kind, string Id = "", string Title = "");
public sealed record HootLine(long Sequence, string Kind, string Id, string Text, DateTimeOffset At,
  string? TurnId = null, string? RequestId = null, bool Waiting = false, string Details = "", long Revision = 0);
public sealed record HootTurn(string Id, string Text, HootSource Source, HootTurnState State, DateTimeOffset At,
  string? ChatId = null, string Answer = "", string? Problem = null, string? CompactLine = null);
public sealed record HootBoardRow(string Id, string Title, string State, string Detail, string? SessionId, DateTimeOffset UpdatedAt);
public sealed record HootDeskSnapshot(string Id, DateTimeOffset At, string Text, long ThroughSequence);
public sealed record HootHandoff(string Id, string SessionId, string Text, DateTimeOffset At, bool Sent = false);
public sealed record HootMemory(string Card, string Playbook, ImmutableArray<HootBoardRow> Board,
  ImmutableArray<HootDeskSnapshot> Desks, ImmutableArray<HootHandoff> Handoffs)
{
  public static HootMemory Empty { get; } = new("", "", [], [], []);
}
public sealed record HootConversation(string Id, ImmutableArray<HootLine> Lines, ImmutableArray<HootTurn> Turns, DateTimeOffset ArchivedAt);
public sealed record HootState(int Version, string ConversationId, HootSettings? Settings, string? ChatId,
  ImmutableArray<HootLine> Lines, ImmutableArray<HootTurn> Turns, HootMemory Memory, string? Problem = null, bool Paused = false, long Revision = 0)
{
  public ImmutableArray<HootConversation> History { get; init; } = [];
  public static HootState Empty { get; } = new(1, Guid.NewGuid().ToString(), null, null, [], [], HootMemory.Empty);
  public HootTurn? Active => Turns.FirstOrDefault(t => t.State is HootTurnState.Dispatching or HootTurnState.Running);
  public bool Busy => Active is not null;
  public int Waiting => Turns.Count(t => t.State == HootTurnState.Queued);
  public string Status => Problem is not null ? "Needs attention" : Active?.Source.Kind == "person" ? "Thinking…" : Busy ? "Working in the background" : "Awake";
}
public interface IHoot
{
  HootState Read();
  event Action<HootState>? Changed;
  ValueTask StartAsync(CancellationToken cancellationToken = default);
  ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string accountId, CancellationToken cancellationToken = default) => ValueTask.FromException<IReadOnlyList<ProviderModel>>(new InvalidOperationException("The model catalogue is not connected yet."));
  ValueTask ConfigureAsync(HootSettings settings, CancellationToken cancellationToken = default);
  // Fills in an unconfigured Hoot from the signed-in accounts; saved choices stay.
  ValueTask EnsureReadyAsync(CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
  ValueTask SayAsync(string clientId, string text, HootSource? source = null, CancellationToken cancellationToken = default);
  ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken cancellationToken = default);
  ValueTask CancelBackgroundAsync(string id, CancellationToken cancellationToken = default);
  ValueTask StopAsync(CancellationToken cancellationToken = default);
  ValueTask AnswerAsync(string requestId, bool allow, CancellationToken cancellationToken = default);
  ValueTask RefreshAsync(CancellationToken cancellationToken = default);
  ValueTask KeepUnconfirmedAsync(CancellationToken cancellationToken = default);
  ValueTask ContinueAsync(CancellationToken cancellationToken = default);
  ValueTask SaveMemoryAsync(string card, string playbook, CancellationToken cancellationToken = default);
  ValueTask SaveBoardAsync(HootBoardRow row, CancellationToken cancellationToken = default);
  ValueTask<HootHandoff> HandoffAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken = default);
}
public interface IHootSessionHandoff
{
  ValueTask SendAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken);
}
public interface IHootSurface
{
  ValueTask OpenAsync(CancellationToken cancellationToken);
}
public static class HootStorage
{
  public static JsonStateStore<HootState> At(AppDataRoot root) => new(root, "hoot");
}
