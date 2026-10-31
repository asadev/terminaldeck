using System.Text;
using System.Threading.Channels;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Sessions;

public sealed class SessionKeeper
{
  public const int MaximumReplayBytes = 1024 * 1024;
  private readonly IStateStore<SessionLedger> store;
  private readonly ISessionProcessKeeper processes;
  private readonly IConversationFiles? conversationFiles;
  private readonly SemaphoreSlim gate = new(1);
  private readonly List<SessionAttachment> watchers = [];
  private SessionLedger ledger;
  public Guid Instance { get; } = Guid.NewGuid();
  private volatile bool updating;
  public bool Updating => updating;
  // Signing in again can move an account's login to a newer folder (the old one
  // is signed out). Returns the account's current login folder for a definition,
  // or null when unknown/signed out, so restarted sessions follow it like chats do.
  public Func<SessionDefinition, string?>? CurrentLogin { get; init; }
  public void CancelUpdate() => updating = false;

  public SessionKeeper(IStateStore<SessionLedger> store, ISessionProcessKeeper processes, IConversationFiles? conversationFiles = null)
  {
    this.store = store; this.processes = processes; this.conversationFiles = conversationFiles;
    ledger = store.Load() ?? new(1, 0, []);
    if (ledger.Version != 1 || ledger.Sessions.Select(s => s.Definition.Id).Distinct().Count() != ledger.Sessions.Length)
      throw new IOException("The saved sessions could not be read safely.");
    foreach (var row in ledger.Sessions) row.Definition.Validate();
  }

  public IReadOnlyList<SessionRecord> List() => Volatile.Read(ref ledger).Sessions.ToArray();
  public SessionRecord Get(string id) => List().FirstOrDefault(s => s.Definition.Id == id) ?? throw new KeyNotFoundException("That session was not found.");

  public async ValueTask<SessionRecord> CreateAsync(SessionDefinition definition, CancellationToken cancellationToken = default)
  {
    definition.Validate();
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (updating) throw new InvalidOperationException("Terminal Deck is updating. Start the session again after it reopens.");
      var existing = ledger.Sessions.FirstOrDefault(s => s.Definition.Id == definition.Id);
      if (existing is not null)
      {
        if (existing.Definition != definition) throw new InvalidOperationException("That session identity already belongs to another request.");
        return existing;
      }
      var row = new SessionRecord(definition, Guid.NewGuid().ToString("N"), SessionState.Starting, CreatedAt: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
      Commit(row, "status"); // Identity is durable before the process can exist.
      return await EnsureAsync(row, resume: definition.ConversationId is not null, cancellationToken);
    }
    finally { gate.Release(); }
  }

  public async ValueTask RecoverAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      foreach (var pending in ledger.Sessions.Where(s => s.PendingAccount is not null).ToArray())
        await FinishAccountSwitchAsync(pending, cancellationToken);
      // Discover/adopt every live lease before any provider resume is allowed.
      var observations = new List<(SessionRecord Row, ProcessObservation Observation)>();
      foreach (var row in ledger.Sessions.Where(s => s.State != SessionState.Exited))
        observations.Add((row, await processes.ObserveAsync(row, cancellationToken)));
      foreach (var (row, observation) in observations.Where(p => p.Observation.Presence != ProcessPresence.Dead))
        Commit(Apply(row, observation), "status");
      foreach (var (row, _) in observations.Where(p => p.Observation.Presence == ProcessPresence.Dead))
      {
        if (!row.HasStarted)
          await EnsureAsync(row.Resume ? FollowLogin(row) : row, row.Resume, cancellationToken);
        else if (row.Definition.Provider != "shell" && row.Definition.ConversationId is not null)
        {
          var pending = FollowLogin(row) with { CreationKey = Guid.NewGuid().ToString("N"), State = SessionState.Starting, HasStarted = false, Resume = true, LeaseIdentity = null };
          Commit(pending, "status");
          await EnsureAsync(pending, resume: true, cancellationToken);
        }
        else Commit(row with { State = SessionState.Exited, LeaseIdentity = null }, "status");
      }
    }
    finally { gate.Release(); }
  }

  // A restarted AI session moves to its account's current login folder, carrying
  // its saved conversation; if the conversation cannot move it keeps the old folder.
  private SessionRecord FollowLogin(SessionRecord row)
  {
    var definition = row.Definition;
    if (definition.Provider == "shell" || definition.Purpose is not null || definition.AccountId is null || CurrentLogin is null) return row;
    string? home;
    try { home = CurrentLogin(definition); } catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException) { return row; }
    if (home is null || home == definition.AccountHome) return row;
    var moved = definition with { AccountHome = home };
    if (definition.ConversationId is not null && conversationFiles is not null)
      try { conversationFiles.Copy(definition, moved); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or UnauthorizedAccessException) { return row; }
    var next = row with { Definition = moved };
    Commit(next, "status");
    return next;
  }

  public static string UpdateNote(SessionDefinition definition) => definition.Provider != "shell" && definition.ConversationId is not null
    ? "\r\n[Terminal Deck was updated. This session continues its conversation.]\r\n"
    : "\r\n[Terminal Deck was updated. This terminal restarted in " + definition.Cwd + ".]\r\n";

  // Update handover: retire every worker so the package files are free, and
  // save each open session as a fresh lease that the next keeper starts. AI
  // sessions resume their saved conversation; terminals restart in their folder
  // with a note. A worker that cannot be reached safely stops the whole update.
  public async ValueTask<int> PrepareUpdateAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var open = ledger.Sessions.Where(s => s.State != SessionState.Exited).ToArray();
      var observed = new List<(SessionRecord Row, ProcessObservation Observation)>();
      foreach (var row in open)
      {
        var observation = await processes.ObserveAsync(row, cancellationToken);
        if (observation.Presence == ProcessPresence.Unknown)
          throw new IOException("A session could not be reached safely, so the update was not applied. Nothing was stopped.");
        observed.Add((row, observation));
      }
      updating = true;
      foreach (var (row, observation) in observed)
      {
        if (observation.Presence == ProcessPresence.Live && (observation.LeaseIdentity ?? row.LeaseIdentity) is { } lease)
          await processes.QuitAsync(lease, cancellationToken);
        if (row.Definition.Purpose is not null) { Commit(row with { State = SessionState.Exited, LeaseIdentity = null }, "exit"); continue; }
        var resume = row.Definition.Provider != "shell" && row.Definition.ConversationId is not null;
        var prefix = Tail(row.Replay + UpdateNote(row.Definition));
        Commit(row with { CreationKey = Guid.NewGuid().ToString("N"), State = SessionState.Starting, HasStarted = false, Resume = resume,
          LeaseIdentity = null, ExitCode = null, ReplayPrefix = prefix, Replay = prefix }, "reset", prefix);
      }
      return observed.Count;
    }
    catch { updating = false; throw; }
    finally { gate.Release(); }
  }

  private async ValueTask<SessionRecord> EnsureAsync(SessionRecord row, bool resume, CancellationToken cancellationToken)
  {
    try
    {
      var observation = await processes.EnsureAsync(row, resume, cancellationToken);
      var next = Apply(row, observation);
      Commit(next, "status");
      return next;
    }
    catch
    {
      // Keep the creation key even if launching succeeded and its reply was lost.
      Commit(row with { State = SessionState.Held }, "status");
      throw;
    }
  }

  private static SessionRecord Apply(SessionRecord row, ProcessObservation observation) => row with
  {
    State = observation.Presence == ProcessPresence.Live && !string.IsNullOrEmpty(observation.LeaseIdentity) ? SessionState.Running : SessionState.Held,
    HasStarted = row.HasStarted || observation.Presence == ProcessPresence.Live,
    LeaseIdentity = observation.LeaseIdentity ?? row.LeaseIdentity
  };

  public async ValueTask<SessionAttachment> AttachAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = Get(id);
      var attachment = new SessionAttachment(new(ledger.Sequence, row, row.Replay));
      watchers.RemoveAll(w => w.Closed);
      watchers.Add(attachment);
      return attachment;
    }
    finally { gate.Release(); }
  }

  public async ValueTask AppendOutputAsync(string id, string text, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { var row = Get(id); Commit(row with { Replay = Tail(row.Replay + text) }, "data", text); }
    finally { gate.Release(); }
  }

  // A durable worker owns replay across supervisor crashes. Replace, do not
  // append, its reconnect snapshot; otherwise output before the crash doubles.
  public async ValueTask RestoreWorkerReplayAsync(string id, string lease, string replay, bool exited, int? exitCode, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = Get(id);
      if (row.LeaseIdentity != lease || row.State == SessionState.Exited && !exited) return;
      Commit(row with { Replay = Tail(row.ReplayPrefix + replay), State = exited ? SessionState.Exited : SessionState.Running,
        ExitCode = exitCode, LeaseIdentity = lease }, "reset", Tail(row.ReplayPrefix + replay));
    }
    finally { gate.Release(); }
  }

  public async ValueTask AppendWorkerOutputAsync(string id, string lease, string text, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try { var row = Get(id); if (row.LeaseIdentity == lease) Commit(row with { Replay = Tail(row.Replay + text) }, "data", text, durableNow: false); }
    finally { gate.Release(); }
  }

  public async ValueTask<SessionRecord> SwitchAccountAsync(SessionDefinition destination, long revision, string transaction, CancellationToken ct = default)
  {
    destination.Validate();
    if (!Guid.TryParseExact(transaction, "N", out _) || destination.Provider == "shell" || destination.Purpose is not null ||
        destination.AccountId is null || destination.AccountHome is null || !Guid.TryParse(destination.ConversationId, out _))
      throw new ArgumentException("Choose a saved conversation and account before switching.");
    await gate.WaitAsync(ct);
    try
    {
      var row = Get(destination.Id);
      if (row.LastAccountSwitch == transaction)
      {
        if (row.Definition != destination) throw new InvalidOperationException("This switch identity already belongs to another request.");
        return row;
      }
      if (row.PendingAccountSwitch == transaction && row.PendingAccount == destination) return await FinishAccountSwitchAsync(row, ct);
      if (row.PendingAccount is not null || row.AccountRevision != revision || row.Definition.Cwd != destination.Cwd || row.Definition.Provider != destination.Provider || row.Definition.Purpose is not null)
        throw new InvalidOperationException("The session changed. Prepare its account switch again.");
      // Persist the intent while the old lease is still named. Recovery retires
      // that exact lease before it can start the replacement.
      conversationFiles?.Validate(row.Definition with { ConversationId = destination.ConversationId }, destination);
      var pending = row with { PendingAccount = destination, PendingAccountSwitch = transaction, State = SessionState.Held };
      Commit(pending, "status");
      return await FinishAccountSwitchAsync(pending, ct);
    }
    finally { gate.Release(); }
  }
  public async ValueTask<SessionRecord> RollbackAccountAsync(SessionDefinition original, string transaction, CancellationToken ct = default)
  {
    original.Validate();
    await gate.WaitAsync(ct);
    try
    {
      var row = Get(original.Id);
      if (row.LastAccountSwitch != transaction && row.PendingAccountSwitch != transaction) throw new InvalidOperationException("This switch is no longer current.");
      if (original.Provider != row.Definition.Provider || original.Cwd != row.Definition.Cwd || !Guid.TryParse(original.ConversationId, out _)) throw new ArgumentException("The original conversation does not match this session.");
      var pending = row with { PendingAccount = original, PendingAccountSwitch = Guid.NewGuid().ToString("N"), AccountRollback = true, State = SessionState.Held };
      Commit(pending, "status"); return await FinishAccountSwitchAsync(pending, ct);
    }
    finally { gate.Release(); }
  }
  private async ValueTask<SessionRecord> FinishAccountSwitchAsync(SessionRecord row, CancellationToken ct)
  {
    if (row.LeaseIdentity is not null)
    {
      var observation = await processes.ObserveAsync(row, ct);
      if (observation.Presence == ProcessPresence.Unknown) throw new IOException("The current terminal cannot be reached safely. Its account was kept.");
      if (observation.Presence == ProcessPresence.Live) await processes.QuitAsync(row.LeaseIdentity, ct);
    }
    if (!row.AccountRollback) conversationFiles?.Copy(row.Definition with { ConversationId = row.PendingAccount!.ConversationId }, row.PendingAccount!);
    var next = row with { Definition = row.PendingAccount!, CreationKey = row.PendingAccountSwitch!, LastAccountSwitch = row.PendingAccountSwitch,
      PendingAccount = null, PendingAccountSwitch = null, AccountRollback = false, AccountRevision = row.AccountRevision + 1,
      LeaseIdentity = null, HasStarted = false, Resume = true, State = SessionState.Starting, ReplayPrefix = row.Replay };
    Commit(next, "status");
    return await EnsureAsync(next, true, ct);
  }

  public async ValueTask RenameAsync(string id, string title, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = Get(id);
      var definition = row.Definition with { Title = title };
      definition.Validate();
      Commit(row with { Definition = definition }, "status");
    }
    finally { gate.Release(); }
  }

  public async ValueTask UpdateConversationAsync(string id, string conversation, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = Get(id);
      var definition = row.Definition with { ConversationId = conversation };
      definition.Validate();
      Commit(row with { Definition = definition }, "status");
    }
    finally { gate.Release(); }
  }

  public async ValueTask WriteAsync(string id, Guid expectedInstance, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
  {
    if (bytes.Length > KeeperWire.MaximumInputBytes) throw new ArgumentException("That input is too large.");
    await gate.WaitAsync(cancellationToken);
    try { await processes.WriteAsync(RequireLease(id, expectedInstance), bytes, cancellationToken); }
    finally { gate.Release(); }
  }

  public async ValueTask ResizeAsync(string id, Guid expectedInstance, TerminalSize size, CancellationToken cancellationToken = default)
  {
    size.Validate();
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (expectedInstance != Instance) throw new InvalidOperationException("The keeper restarted. Reconnect before resizing a session.");
      var row = Get(id);
      // WebView fits when a retained terminal becomes visible, including after
      // exit or while held. That visual update is not a broken connection.
      if (row.State != SessionState.Running || row.LeaseIdentity is null) return;
      await processes.ResizeAsync(row.LeaseIdentity, size, cancellationToken);
    }
    finally { gate.Release(); }
  }

  public async ValueTask StopAsync(string id, Guid expectedInstance, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (expectedInstance != Instance) throw new InvalidOperationException("The keeper restarted. Reconnect before closing a session.");
      var row = Get(id);
      var lease = row.State == SessionState.Exited && row.LeaseIdentity is not null ? row.LeaseIdentity : RequireLease(id, expectedInstance);
      await processes.QuitAsync(lease, cancellationToken);
      Commit(Get(id) with { State = SessionState.Exited, LeaseIdentity = null }, "exit");
    }
    finally { gate.Release(); }
  }

  public async ValueTask<bool> IsIdleAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { return (await processes.ObserveAsync(Get(id), cancellationToken)).Idle; }
    finally { gate.Release(); }
  }

  private string RequireLease(string id, Guid expectedInstance)
  {
    if (expectedInstance != Instance) throw new InvalidOperationException("The keeper restarted. Reconnect before sending input.");
    var row = Get(id);
    if (row.State != SessionState.Running || row.LeaseIdentity is null) throw new InvalidOperationException("This session is waiting to reconnect.");
    return row.LeaseIdentity;
  }

  private void Commit(SessionRecord row, string kind, string? text = null, bool durableNow = true)
  {
    var next = ledger with { Sequence = checked(ledger.Sequence + 1), Sessions = ledger.Sessions.Where(s => s.Definition.Id != row.Definition.Id).Append(row).OrderBy(s => s.CreatedAt).ToArray() };
    if (durableNow) Save(next); else ScheduleSave();
    Volatile.Write(ref ledger, next);
    var change = new SessionEvent(next.Sequence, row.Definition.Id, kind, text, row.ExitCode);
    foreach (var watcher in watchers.Where(w => w.Snapshot.Session.Definition.Id == change.Id && !w.Closed)) watcher.Publish(change);
  }

  // Worker output arrives in many small chunks and the worker itself keeps the
  // replay across a supervisor crash. Rewriting and flushing the whole ledger
  // (every session's replay) for each chunk made the keeper fall behind busy
  // sessions as replays grew, overflowing the watch buffers; every overflow
  // forced a full screen replay in the app, which could leave the cursor a cell
  // away from where typing lands. Output is now saved at most once per interval;
  // every state change still saves synchronously and includes it.
  public static readonly TimeSpan OutputSaveInterval = TimeSpan.FromSeconds(2);
  private readonly object saveGate = new();
  private ulong savedSequence;
  private int saveScheduled;
  private void Save(SessionLedger next)
  {
    lock (saveGate) { if (next.Sequence <= savedSequence) return; store.Save(next); savedSequence = next.Sequence; }
  }
  private void ScheduleSave()
  {
    if (Interlocked.Exchange(ref saveScheduled, 1) != 0) return;
    _ = Task.Run(async () =>
    {
      await Task.Delay(OutputSaveInterval);
      Interlocked.Exchange(ref saveScheduled, 0);
      FlushOutput();
    });
  }
  /// <summary>Saves output received since the last save. Safe to call at any time.</summary>
  public void FlushOutput()
  {
    try { Save(Volatile.Read(ref ledger)); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ScheduleSave(); }
  }

  private static string Tail(string value)
  {
    if (Encoding.UTF8.GetByteCount(value) <= MaximumReplayBytes) return value;
    var bytes = 0; var start = value.Length;
    while (start > 0)
    {
      var width = start >= 2 && char.IsSurrogatePair(value[start - 2], value[start - 1]) ? 2 : 1;
      var count = Encoding.UTF8.GetByteCount(value.AsSpan(start - width, width));
      if (bytes + count > MaximumReplayBytes) break;
      start -= width; bytes += count;
    }
    return value[start..];
  }
}

public sealed class SessionAttachment : IAsyncDisposable
{
  // Deep enough to ride out a slow or briefly paused app window; an overflow
  // closes the watch and costs the app a full replay.
  public const int EventBuffer = 4096;
  private readonly Channel<SessionEvent> events = Channel.CreateBounded<SessionEvent>(new BoundedChannelOptions(EventBuffer) { FullMode = BoundedChannelFullMode.Wait });
  private int closed;
  public SessionSnapshot Snapshot { get; }
  public bool Closed => Volatile.Read(ref closed) != 0;
  internal SessionAttachment(SessionSnapshot snapshot) { Snapshot = snapshot; }
  internal void Publish(SessionEvent change)
  {
    if (!events.Writer.TryWrite(change))
    {
      Interlocked.Exchange(ref closed, 1);
      events.Writer.TryComplete(new IOException("The session changed too quickly. Reattach for a fresh snapshot."));
    }
  }
  public IAsyncEnumerable<SessionEvent> Events(CancellationToken cancellationToken = default) => events.Reader.ReadAllAsync(cancellationToken);
  public ValueTask DisposeAsync() { Interlocked.Exchange(ref closed, 1); events.Writer.TryComplete(); return ValueTask.CompletedTask; }
}

// Buffering before the snapshot arrives is safe; events at/below its boundary are discarded.
public sealed class SessionReplay
{
  private readonly SortedDictionary<ulong, SessionEvent> buffered = [];
  private ulong sequence;
  private bool ready;
  private string? id;
  public string Text { get; private set; } = "";
  public void Receive(SessionEvent change)
  {
    if (ready && change.Id != id) return;
    if (ready && change.Sequence <= sequence) return;
    if (!ready) { if (buffered.Count >= 256) throw new IOException("Reattach for a fresh session snapshot."); buffered[change.Sequence] = change; return; }
    Apply(change);
  }
  public void Restore(SessionSnapshot snapshot)
  {
    id = snapshot.Session.Definition.Id; sequence = snapshot.Sequence; Text = snapshot.Replay; ready = true;
    foreach (var change in buffered.Values.Where(e => e.Id == id && e.Sequence > sequence).ToArray()) Apply(change);
    buffered.Clear();
  }
  private void Apply(SessionEvent change) { sequence = change.Sequence; if (change.Kind == "data") Text += change.Text; else if (change.Kind == "reset") Text = change.Text ?? ""; }
}
