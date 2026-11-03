using System.Collections.Immutable;
using System.Security.Cryptography;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Hoot;

// Keeper owns this service. Views attach; they never own or restart its AI.
public sealed class HootService : IHoot, IAsyncDisposable
{
  private readonly IStateStore<HootState> store;
  private readonly IChatSessions chats;
  private readonly AccountService accounts;
  private readonly IHootSessionHandoff handoff;
  private readonly TimeProvider clock;
  private readonly Func<string, CancellationToken, ValueTask>? prepareTools;
  private readonly HootReady? ready;
  private readonly SemaphoreSlim gate = new(1);
  private readonly CancellationTokenSource lifetime = new();
  private HootState state;
  private readonly Dictionary<string, Task> followers = [];
  private bool started;
  private int disposed;
  public event Action<HootState>? Changed;
  public HootService(IStateStore<HootState> store, IChatSessions chats, AccountService accounts, IHootSessionHandoff handoff, TimeProvider? time = null, Func<string, CancellationToken, ValueTask>? prepareTools = null, HootReady? ready = null)
  {
    this.ready = ready;
    this.store = store; this.chats = chats; this.accounts = accounts; this.handoff = handoff; clock = time ?? TimeProvider.System;
    this.prepareTools = prepareTools;
    state = store.Load() ?? HootState.Empty;
    if (state.Version != 1 || state.Turns.IsDefault || state.Lines.IsDefault || state.Memory.Board.IsDefault || state.History.IsDefault || state.History.Any(h => h is null || h.Lines.IsDefault || h.Turns.IsDefault))
      throw new IOException("Hoot's saved conversation could not be read safely.");
  }
  public HootState Read() => Volatile.Read(ref state);
  private DateTimeOffset Now => clock.GetUtcNow();
  private void Save(HootState next)
  {
    store.Save(next); Volatile.Write(ref state, next);
    // UI listeners cannot turn a committed send into an apparent failure.
    foreach (var listener in Changed?.GetInvocationList() ?? [])
      try { ((Action<HootState>)listener)(next); } catch (Exception) { }
  }
  private void Turn(HootTurn turn)
  {
    if (turn.State is HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped) turn = turn with { Attachments = [] };
    if (state.Turns.FirstOrDefault(t => t.Id == turn.Id) != turn) Save(state with { Turns = state.Turns.Select(t => t.Id == turn.Id ? turn : t).ToImmutableArray() }); }
  private void Line(string kind, string id, string text, string? turn = null, string? request = null, bool waiting = false, string details = "")
  {
    var existing = state.Lines.FirstOrDefault(l => l.Id == id);
    var line = new HootLine(existing?.Sequence ?? (state.Lines.LastOrDefault()?.Sequence ?? 0) + 1, kind, id, text, existing?.At ?? Now, turn, request, waiting, details, state.Revision + 1);
    if (existing is not null && line with { Revision = existing.Revision } == existing) return;
    Save(state with { Revision = line.Revision, Lines = existing is null ? state.Lines.Add(line) : state.Lines.Select(l => l.Id == id ? line : l).ToImmutableArray() });
  }
  public async ValueTask StartAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (started) return;
      started = true;
      ReadyLocked();
      if (state.ChatId is { } prior && state.Settings is { } savedSettings && chats.Get(prior).Definition.PermissionMode != savedSettings.PermissionMode)
      {
        // Reconnect can drain the chat's own queue. Retire an older permission
        // before reconnecting, so recovery cannot send under that older mode.
        await RetireAsync(cancellationToken);
        var inFlight = state.Turns.Any(t => t.ChatId == prior && t.State is HootTurnState.Dispatching or HootTurnState.Running);
        Save(state with { ChatId = null, Paused = state.Paused || inFlight,
          Problem = inFlight ? "Hoot's permission changed during recovery. Review the earlier turn before continuing." : state.Problem,
          Turns = state.Turns.Select(t => t.ChatId == prior && t.State is HootTurnState.Dispatching or HootTurnState.Running
            ? t with { State = HootTurnState.Uncertain, Problem = "The earlier turn was kept without another send." } : t).ToImmutableArray() });
      }
      if (state.ChatId is { } id) { await chats.ReconnectAsync(id, cancellationToken); Project(chats.Get(id)); Follow(id); }
      // A crash during dispatch is checked against the existing chat receipt,
      // never sent afresh to a different conversation.
      foreach (var turn in state.Turns.Where(t => t.State == HootTurnState.Dispatching).ToArray())
        if (turn.ChatId is null || !chats.Get(turn.ChatId).Messages.Any(m => m.ClientId == turn.Id))
          Turn(turn with { State = HootTurnState.Uncertain, Problem = "Delivery could not be confirmed. It was not sent again." });
      if (state.Turns.Any(t => t.State == HootTurnState.Uncertain)) Save(state with { Paused = true, Problem = "An earlier turn has uncertain delivery. It was kept without another send." });
      await DispatchAsync(cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string accountId, CancellationToken cancellationToken = default) =>
    (await accounts.ModelsAsync(accountId, cancellationToken: cancellationToken)).Models;
  public async ValueTask ConfigureAsync(HootSettings settings, CancellationToken cancellationToken = default)
  {
    if (settings is null || settings.Options is null || settings.Folder is null || !Path.IsPathFullyQualified(settings.Folder) || !Directory.Exists(settings.Folder))
      throw new ArgumentException("Choose Hoot's working folder.");
    var account = accounts.Get(settings.AccountId);
    if (account.Provider != settings.Provider) throw new ArgumentException("Choose Hoot's account for this coding AI.");
    new ChatDefinition(Guid.NewGuid().ToString(), settings.Provider, settings.Folder, "Hoot", account.Id, account.HomeId, settings.Options, PermissionMode: settings.PermissionMode).Validate();
    if (settings.Options.Model.Length > 0 && !(await accounts.ModelsAsync(account.Id, cancellationToken: cancellationToken)).Models.Any(m => m.Id == settings.Options.Model))
      throw new ArgumentException("Choose a model offered by Hoot's account.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireIdle();
      if (state.ChatId is { } id && state.Settings is { } prior &&
          prior.Provider == settings.Provider && prior.AccountId == settings.AccountId &&
          prior.Folder == settings.Folder && prior.PermissionMode == settings.PermissionMode)
      {
        if (prior.Options != settings.Options) await chats.SetOptionsAsync(id, settings.Options, cancellationToken);
        Save(state with { Settings = settings with { RefreshMinutes = 0, RefreshAfterTurns = 0 }, Problem = null });
        return;
      }
      await RetireAsync(cancellationToken);
      Save(state with { Settings = settings with { RefreshMinutes = 0, RefreshAfterTurns = 0 }, ChatId = null, Problem = null });
    }
    finally { gate.Release(); }
  }
  public async ValueTask EnsureReadyAsync(CancellationToken cancellationToken = default)
  { await gate.WaitAsync(cancellationToken); try { ReadyLocked(); } finally { gate.Release(); } }
  // No chat is created here; the first turn starts Hoot's chat as usual.
  private void ReadyLocked()
  {
    if (state.Settings is not null || ready is null) return;
    try { if (ready.Settings(accounts) is { } settings) Save(state with { Settings = settings, Problem = null }); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
  }
  public ValueTask SayAsync(string clientId, string text, HootSource? source = null, CancellationToken cancellationToken = default) =>
    EnqueueAsync(clientId, text, source ?? new("person"), null, cancellationToken);
  public ValueTask SayWithAttachmentsAsync(string clientId, string text, ChatAttachmentData[] attachments, HootSource? source = null, CancellationToken cancellationToken = default) =>
    EnqueueAsync(clientId, text, source ?? new("person"), null, cancellationToken, attachments);
  public async ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken cancellationToken = default)
  {
    if (reason is not ("task" or "handoff" or "dev-test" or "background")) throw new ArgumentException("Choose a task, handoff or background turn.");
    HootDesk.ValidateText(sourceId, 128, "the source", false); HootDesk.ValidateText(title, 200, "a short title", false);
    await EnqueueAsync(clientId, text, new(reason, sourceId, title), compactLine ?? (reason == "task" ? $"Working on task “{title}”" : null), cancellationToken);
    return clientId;
  }
  private async ValueTask EnqueueAsync(string id, string text, HootSource source, string? compact, CancellationToken ct, ChatAttachmentData[]? attachments = null)
  {
    if (!Guid.TryParse(id, out _)) throw new ArgumentException("Keep one message id for this send.");
    attachments = (attachments ?? []).Select(f => f with { Data = f.Data.ToArray() }).ToArray();
    var keys = attachments.Select(f => f.Name + ":" + f.MimeType + ":" + Convert.ToHexString(SHA256.HashData(f.Data))).ToArray();
    if (attachments.Length > 8 || attachments.Sum(f => (long)f.Data.Length) > 4 * 1024 * 1024) throw new ArgumentException("Send up to eight attachments totalling at most 4 MB to Hoot.");
    HootDesk.ValidateText(text, 64000, "a message", attachments.Length > 0); HootDesk.ValidateText(compact ?? "", 300, "a short background line");
    HootDesk.ValidateText(source.Kind, 32, "a source", false); HootDesk.ValidateText(source.Id, 128, "a source id");
    await gate.WaitAsync(ct);
    try
    {
      ReadyLocked();
      if (state.Settings is null) throw new InvalidOperationException(ready is null ? "Choose Hoot's coding AI, account and folder first." : HootReady.SignInLine);
      if (state.Turns.FirstOrDefault(t => t.Id == id) is { } existing)
      {
        if (existing.Text != text || existing.Source != source || existing.CompactLine != compact || !existing.AttachmentKeys.SequenceEqual(keys)) throw new InvalidOperationException("That message id already belongs to another request.");
        return;
      }
      foreach (var file in attachments) file.Validate(state.Settings.Provider);
      if (state.Turns.Where(t => t.State is HootTurnState.Queued or HootTurnState.Dispatching or HootTurnState.Running or HootTurnState.Uncertain).Sum(t => t.Attachments.Sum(f => (long)f.Data.Length)) + attachments.Sum(f => (long)f.Data.Length) > 32 * 1024 * 1024) throw new InvalidOperationException("Hoot’s attachment queue is full. Wait for a turn to finish.");
      if (state.Waiting >= 100) throw new InvalidOperationException("Hoot's queue is full. Wait for a turn to finish.");
      var turn = new HootTurn(id, text, source, HootTurnState.Queued, Now, CompactLine: compact) { Attachments = attachments, AttachmentKeys = keys };
      Save(state with { Turns = state.Turns.Add(turn), Problem = state.Paused ? state.Problem : null });
      if (source.Kind == "person") Line("user", "user:" + id, text, id);
      else if (compact is not null) Line("background", "bg:" + id, compact, id);
      else if (source.Kind == "session") Line("context", "source:" + id, source.Title.Length > 0 ? source.Title : "A note from a session", id);
      await DispatchAsync(ct);
    }
    finally { gate.Release(); }
  }
  private async ValueTask DispatchAsync(CancellationToken ct)
  {
    if (state.Busy || state.Paused || state.Turns.Any(t => t.State == HootTurnState.Uncertain)) return;
    if (state.Turns.FirstOrDefault(t => t.State == HootTurnState.Queued) is not { } turn || state.Settings is not { } settings) return;
    var permission = turn.Source.Restricted ? TerminalDeck.Core.Mcp.AiPermissionMode.Ask : settings.PermissionMode;
    ChatPermissionModes.Validate(settings.Provider, permission);
    var previousCaller = state.Turns.LastOrDefault(t => t.ChatId == state.ChatId && t.Id != turn.Id)?.Source.DeviceId;
    if (state.ChatId is { } savedChat && (chats.Get(savedChat).Definition.PermissionMode != permission || previousCaller != turn.Source.DeviceId))
    {
      await RetireAsync(ct); Save(state with { ChatId = null });
    }
    if (state.ChatId is null)
    {
      var account = accounts.Get(settings.AccountId);
      var desk = HootDesk.Snapshot(state, Now);
      var chat = await chats.CreateAsync(new(Guid.NewGuid().ToString(), settings.Provider, settings.Folder, "Hoot", account.Id, account.HomeId,
        settings.Options, HootDesk.Instructions + "\n\n<deck-memory>\n" + desk.Text + "\n</deck-memory>", permission), cancellationToken: ct);
      Save(state with { ChatId = chat.Definition.Id, Memory = state.Memory with { Desks = state.Memory.Desks.Add(desk) } });
      Follow(chat.Definition.Id);
    }
    var id = state.ChatId!; turn = turn with { ChatId = id, State = HootTurnState.Dispatching }; Turn(turn);
    try
    {
      if (prepareTools is not null) await prepareTools(id, ct);
      if (state.Settings != settings || chats.Get(id).Definition.PermissionMode != permission)
        throw new InvalidOperationException("Hoot’s permission changed before this turn could start.");
      var media = new List<ChatMedia>();
      foreach (var file in turn.Attachments)
      {
        file.Validate(settings.Provider);
        media.Add(await chats.AddImageAsync(id, file.Name, file.MimeType, file.Data, file.Width, file.Height, ct));
      }
      if (media.Count > 0 && prepareTools is not null) await prepareTools(id, ct);
      await chats.SendAsync(id, turn.Id, HootDesk.Message(state, turn), media.ToArray(), ct); Project(chats.Get(id));
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException)
    {
      Turn(turn with { State = HootTurnState.Uncertain, Problem = "Delivery could not be confirmed. It was not sent again." });
      Save(state with { Problem = "Hoot needs attention. Check the saved turn before continuing.", Paused = true });
      if (ex is OperationCanceledException) throw;
    }
  }
  private void Follow(string id)
  {
    if (followers.ContainsKey(id)) return;
    followers[id] = Task.Run(async () =>
    {
      try
      {
        await foreach (var chat in chats.WatchAsync(id, lifetime.Token))
        {
          await gate.WaitAsync(lifetime.Token);
          try
          {
            if (state.ChatId != id) return;
            Project(chat);
            await DispatchAsync(lifetime.Token);
          }
          finally { gate.Release(); }
        }
      }
      catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or KeyNotFoundException)
      { await gate.WaitAsync(); try { Save(state with { Problem = "Hoot lost its connection. Saved turns were kept.", Paused = true }); } finally { gate.Release(); } }
    });
  }
  private void Project(ChatRecord chat)
  {
    var next = state;
    void PutLine(string kind, string id, string text, string turnId, string? request = null, bool waiting = false, string details = "")
    {
      var prior = next.Lines.FirstOrDefault(l => l.Id == id);
      var line = new HootLine(prior?.Sequence ?? (next.Lines.LastOrDefault()?.Sequence ?? 0) + 1, kind, id, text, prior?.At ?? Now, turnId, request, waiting, details, next.Revision + 1);
      if (prior is null || line with { Revision = prior.Revision } != prior) next = next with { Revision = line.Revision, Lines = prior is null ? next.Lines.Add(line) : next.Lines.Select(l => l.Id == id ? line : l).ToImmutableArray() };
    }
    foreach (var original in state.Turns.Where(t => t.ChatId == chat.Definition.Id && t.State is HootTurnState.Dispatching or HootTurnState.Running or HootTurnState.Uncertain).ToArray())
    {
      var message = chat.Messages.FirstOrDefault(m => m.ClientId == original.Id); if (message is null) continue;
      var events = chat.Events.Where(e => e.ClientId == original.Id).ToArray();
      var completion = events.LastOrDefault(e => e.Kind is "complete" or "error" or "exit" or "connectionLost");
      var rows = ChatProjection.Rows(chat).Where(r => r.ClientId == original.Id || events.Any(e => e.Id == r.Id)).ToArray();
      var answer = rows.LastOrDefault(r => r.Kind == "assistant")?.Text ?? original.Answer;
      var uncertain = message.State == ChatMessageState.Uncertain || message.State == ChatMessageState.Dispatching && !chat.Busy;
      var status = completion?.Kind == "complete" ? HootTurnState.Finished : completion is not null || message.State == ChatMessageState.Failed ? HootTurnState.Failed : uncertain ? HootTurnState.Uncertain : HootTurnState.Running;
      if (events.Any(e => e.Kind == "stopped")) status = HootTurnState.Stopped;
      var turn = original with { State = status, Answer = answer, Problem = status is HootTurnState.Failed or HootTurnState.Uncertain ? chat.Problem ?? "Hoot stopped before it finished." : null };
      if (status is HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped) turn = turn with { Attachments = [] };
      if (turn != original) next = next with { Turns = next.Turns.Select(t => t.Id == turn.Id ? turn : t).ToImmutableArray() };
      if (original.Source.Kind is "person" or "session")
        foreach (var row in rows.Where(r => r.Kind is "assistant" or "tool" or "error"))
          PutLine(row.Kind, chat.Definition.Id + ":" + original.Id + ":" + row.Id, row.Text, original.Id, details: row.Details);
      // Quiet turns still surface the provider's own permission cards.
      foreach (var row in rows.Where(r => r.Kind == "approval"))
        PutLine("approval", chat.Definition.Id + ":" + original.Id + ":approval:" + row.Id, row.Text, original.Id, row.Id, row.Waiting, row.Details);
      if (status is HootTurnState.Failed or HootTurnState.Uncertain)
        next = next with { Problem = chat.Problem ?? "Hoot needs attention before continuing.", Paused = true };
    }
    // A completion and its final words become visible together. Task consumers
    // can safely use the finished event without racing the answer projection.
    if (next != state) Save(next);
  }
  public async ValueTask RefreshAsync(CancellationToken cancellationToken = default)
  { await gate.WaitAsync(cancellationToken); try { RequireIdle(); await RefreshLockedAsync(cancellationToken); } finally { gate.Release(); } }
  private async ValueTask RefreshLockedAsync(CancellationToken ct)
  {
    if (state.ChatId is null && state.Lines.IsEmpty && state.Turns.IsEmpty) return;
    var desk = HootDesk.Snapshot(state, Now); await RetireAsync(ct);
    Save(state with { ConversationId = Guid.NewGuid().ToString(), ChatId = null, Lines = [], Turns = [], Paused = false, Problem = null,
      History = state.History.Add(new(state.ConversationId, state.Lines, state.Turns, Now)),
      Memory = state.Memory with { Desks = state.Memory.Desks.Add(desk) } });
  }
  private ValueTask RetireAsync(CancellationToken ct) => state.ChatId is { } id ? chats.EndAsync(id, ct) : ValueTask.CompletedTask;
  private void RequireIdle()
  { if (state.Busy || state.Waiting > 0 || state.Turns.Any(t => t.State == HootTurnState.Uncertain)) throw new InvalidOperationException("Wait for Hoot's current and queued turns to finish first."); }
  public async ValueTask KeepUnconfirmedAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var uncertain = state.Turns.Where(t => t.State == HootTurnState.Uncertain).ToArray();
      if (uncertain.Length == 0) throw new InvalidOperationException("There is no unconfirmed turn to keep.");
      // Explicit acknowledgement retires the exact old worker before a fresh
      // desk can be made. The uncertain request itself is never replayed.
      await RetireAsync(cancellationToken);
      foreach (var turn in uncertain) Turn(turn with { State = HootTurnState.Stopped, Problem = "Kept without resending. Delivery remains uncertain." });
      Save(state with { ChatId = null, Paused = true, Problem = null });
    }
    finally { gate.Release(); }
  }
  public async ValueTask ContinueAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (state.Turns.Any(t => t.State == HootTurnState.Uncertain)) throw new InvalidOperationException("An earlier turn has uncertain delivery. Check its saved chat before continuing.");
      Save(state with { Paused = false, Problem = null }); await DispatchAsync(cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask StopAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      Save(state with { Paused = true });
      if (state.Active is { ChatId: { } id, Source.Kind: "person" or "session" }) await chats.StopAsync(id, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask CancelBackgroundAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var turn = state.Turns.FirstOrDefault(t => t.Id == id) ?? throw new ArgumentException("Choose a background turn.");
      if (turn.Source.Kind is "person" or "session") throw new ArgumentException("Use Stop for a chat answer.");
      if (turn.State == HootTurnState.Queued) Turn(turn with { State = HootTurnState.Stopped });
      else if (turn.State is HootTurnState.Running or HootTurnState.Dispatching && turn.ChatId is { } chatId)
        await chats.StopAsync(chatId, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask AnswerAsync(string requestId, bool allow, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { await chats.AnswerAsync(state.ChatId ?? throw new InvalidOperationException("Hoot is not waiting for an answer."), requestId, allow, cancellationToken); }
    finally { gate.Release(); }
  }
  public async ValueTask SaveMemoryAsync(string card, string playbook, CancellationToken cancellationToken = default)
  {
    HootDesk.ValidateText(card, 16000, "Hoot's memory"); HootDesk.ValidateText(playbook, 16000, "the playbook");
    await gate.WaitAsync(cancellationToken);
    try { Save(state with { Memory = state.Memory with { Card = card, Playbook = playbook } }); } finally { gate.Release(); }
  }
  public async ValueTask SaveBoardAsync(HootBoardRow row, CancellationToken cancellationToken = default)
  {
    HootDesk.ValidateText(row.Id, 128, "a board id", false); HootDesk.ValidateText(row.Title, 200, "a title", false); HootDesk.ValidateText(row.Detail, 2000, "a board note");
    if (row.State is not ("queued" or "working" or "waiting" or "done")) throw new ArgumentException("Choose queued, working, waiting or done.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (state.Memory.Board.Length >= 200 && !state.Memory.Board.Any(r => r.Id == row.Id)) throw new InvalidOperationException("Hoot's board has 200 rows. Update an existing row first.");
      Save(state with { Memory = state.Memory with { Board = state.Memory.Board.Where(r => r.Id != row.Id).Append(row with { UpdatedAt = Now }).ToImmutableArray() } });
    }
    finally { gate.Release(); }
  }
  public async ValueTask<HootHandoff> HandoffAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken = default)
  {
    if (!Guid.TryParse(clientId, out _) || !Guid.TryParse(sessionId, out _)) throw new ArgumentException("Choose a session and keep this handoff id.");
    HootDesk.ValidateText(text, 7000, "the context handoff", false);
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (state.Memory.Handoffs.FirstOrDefault(h => h.Id == clientId) is { } old)
      {
        if (old.SessionId != sessionId || old.Text != text) throw new InvalidOperationException("That handoff id belongs to another note.");
        return old; // An unconfirmed delivery must never be sent twice.
      }
      var item = new HootHandoff(clientId, sessionId, text, Now);
      Save(state with { Memory = state.Memory with { Handoffs = state.Memory.Handoffs.Add(item) } });
      await handoff.SendAsync(clientId, sessionId, text, cancellationToken);
      item = item with { Sent = true };
      Save(state with { Memory = state.Memory with { Handoffs = state.Memory.Handoffs.Select(h => h.Id == clientId ? item : h).ToImmutableArray() } }); return item;
    }
    finally { gate.Release(); }
  }
  public async ValueTask DisposeAsync()
  {
    if (Interlocked.Exchange(ref disposed, 1) != 0) return;
    lifetime.Cancel();
    try { await Task.WhenAll(followers.Values); } catch (OperationCanceledException) { }
    lifetime.Dispose(); gate.Dispose();
  }
}
