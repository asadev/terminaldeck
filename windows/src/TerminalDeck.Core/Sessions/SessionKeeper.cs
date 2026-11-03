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
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SessionReplayBuffer> replayBuffers = new();
  private SessionLedger ledger;
  public Guid Instance { get; } = Guid.NewGuid();
  // Activity seen since this keeper started, for the update check (never saved).
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, (long Last, long RunStart)> outputSeen = new();
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, long> inputSeen = new();
  // The program each live lease runs, so the AI's own status file can be read.
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, (string Lease, int Pid, long StartedAt)> programs = new();
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, long> conversationChecked = new();
  public const long OutputRunGapMs = 3000;
  public const long ConversationCheckMs = 15000;
  public Func<long> Clock { get; init; } = () => Environment.TickCount64;
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

  private SessionRecord WithReplay(SessionRecord row) => replayBuffers.TryGetValue(row.Definition.Id, out var replay) ? row with { Replay = replay.Snapshot() } : row;
  public IReadOnlyList<SessionRecord> List() => Volatile.Read(ref ledger).Sessions.Select(WithReplay).ToArray();
  private SessionRecord RawGet(string id) => Volatile.Read(ref ledger).Sessions.FirstOrDefault(s => s.Definition.Id == id) ?? throw new KeyNotFoundException("That session was not found.");
  public SessionRecord Get(string id) => WithReplay(RawGet(id));

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
        var asked = existing.DeclaredConversation ? existing.Definition with { ConversationId = null } : existing.Definition;
        if (asked != definition) throw new InvalidOperationException("That session identity already belongs to another request.");
        return WithReplay(existing);
      }
      // A new Claude conversation is named here (claude --session-id), so every later
      // restart can resume exactly this conversation (the Mac does the same).
      var declare = definition.Provider == "claude" && definition.Purpose is null && definition.ConversationId is null && definition.ServerId is null;
      var resume = definition.ConversationId is not null;
      var row = new SessionRecord(declare ? definition with { ConversationId = Guid.NewGuid().ToString() } : definition, Guid.NewGuid().ToString("N"),
        SessionState.Starting, CreatedAt: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Resume: resume, DeclaredConversation: declare);
      Commit(row, "status"); // Identity is durable before the process can exist.
      return await EnsureAsync(row, resume, cancellationToken);
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
      {
        Remember(row, observation);
        Commit(Apply(row, observation), "status");
      }
      foreach (var (row, _) in observations.Where(p => p.Observation.Presence == ProcessPresence.Dead))
      {
        // The program has gone (a reboot, or its worker ended): its transcripts say
        // which conversation it was in last.
        var followed = row.HasStarted && row.Definition.Provider != "shell" ? FollowConversation(row, null) : row.Definition;
        if (!row.HasStarted)
        {
          var start = CatchUpHandedOver(row);
          await EnsureAsync(start.Resume ? FollowLogin(start) : start, start.Resume, cancellationToken);
        }
        else if (row.Definition.Provider != "shell" && followed.ConversationId is not null)
        {
          // A Claude conversation with nothing saved yet starts again under its own name.
          var resume = CanResume(followed);
          var pending = FollowLogin(row with { Definition = followed }) with { CreationKey = Guid.NewGuid().ToString("N"), State = SessionState.Starting, HasStarted = false, Resume = resume, LeaseIdentity = null };
          Commit(pending, "status");
          await EnsureAsync(pending, resume, cancellationToken);
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

  public static string UpdateNote(SessionDefinition definition) => UpdateNote(definition, definition.Provider != "shell" && definition.ConversationId is not null);
  public static string UpdateNote(SessionDefinition definition, bool resumes) => resumes
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
      var open = ledger.Sessions.Where(s => s.State != SessionState.Exited).Select(WithReplay).ToArray();
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
        // Read which conversation the AI is in now (it moves on /clear and /resume)
        // while its program still runs.
        var definition = row.Definition.Purpose is null ? FollowConversation(row, observation) : row.Definition;
        if (observation.Presence == ProcessPresence.Live && (observation.LeaseIdentity ?? row.LeaseIdentity) is { } lease)
          await processes.QuitAsync(lease, cancellationToken);
        programs.TryRemove(row.Definition.Id, out _);
        if (row.Definition.Purpose is not null) { Commit(row with { State = SessionState.Exited, LeaseIdentity = null }, "exit"); continue; }
        var resume = definition.Provider != "shell" && definition.ConversationId is not null && CanResume(definition);
        // A fresh restart never sends the session's first brief a second time. A Claude
        // conversation with nothing saved yet never ran it, so it starts again under its own name.
        if (!resume && !(definition.Provider == "claude" && definition.ConversationId is not null)) definition = definition with { InitialPrompt = null };
        var prefix = Tail(row.Replay + UpdateNote(definition, resume));
        Commit(row with { Definition = definition, CreationKey = Guid.NewGuid().ToString("N"), State = SessionState.Starting, HasStarted = false, Resume = resume,
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
      Remember(row, observation);
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
    try { CommitOutput(RawGet(id), text, durableNow: true); }
    finally { gate.Release(); }
  }

  // A durable worker owns replay across supervisor crashes. Replace, do not
  // append, its reconnect snapshot; otherwise output before the crash doubles.
  public async ValueTask RestoreWorkerReplayAsync(string id, string lease, string replay, bool exited, int? exitCode, CancellationToken cancellationToken = default, TerminalSize? replaySize = null)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = Get(id);
      if (row.LeaseIdentity != lease || row.State == SessionState.Exited && !exited) return;
      Commit(row with { Replay = Tail(row.ReplayPrefix + replay), State = exited ? SessionState.Exited : SessionState.Running,
        ExitCode = exitCode, LeaseIdentity = lease, ReplaySize = replaySize ?? row.ReplaySize }, "reset", Tail(row.ReplayPrefix + replay));
    }
    finally { gate.Release(); }
  }

  public async ValueTask RecordWorkerSizeAsync(string id, string lease, TerminalSize size, CancellationToken ct = default)
  {
    size.Validate(); await gate.WaitAsync(ct);
    try { var row = Get(id); if (row.LeaseIdentity == lease && row.ReplaySize != size) Commit(row with { ReplaySize = size }, "geometry", durableNow: false); }
    finally { gate.Release(); }
  }
  public async ValueTask WorkerConnectionLostAsync(string id, string lease, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try { var row = Get(id); if (row.LeaseIdentity == lease && row.State == SessionState.Running) Commit(row with { State = SessionState.Held }, "status"); }
    finally { gate.Release(); }
  }
  public async ValueTask AppendWorkerOutputAsync(string id, string lease, string text, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try { var row = RawGet(id); if (row.LeaseIdentity == lease) CommitOutput(row, text, durableNow: false); }
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

  // The AI reported (a hook) that this terminal is in another conversation now.
  public async ValueTask UpdateConversationAsync(string id, string conversation, CancellationToken cancellationToken = default)
  {
    if (!Guid.TryParse(conversation, out _)) throw new ArgumentException("Choose an exact conversation identity.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      var row = RawGet(id);
      if (row.Definition.Provider is not ("claude" or "codex" or "gemini") || row.Definition.Purpose is not null) throw new InvalidOperationException("Only an AI session has a conversation.");
      if (row.State == SessionState.Exited || row.Definition.ConversationId == conversation) return;
      var definition = row.Definition with { ConversationId = conversation };
      definition.Validate();
      Commit(row with { Definition = definition }, "status");
    }
    finally { gate.Release(); }
  }

  // For the update check: what each open terminal is doing right now.
  public IReadOnlyList<SessionActivity> Activity()
  {
    var now = Clock();
    return Volatile.Read(ref ledger).Sessions.Where(s => s.State != SessionState.Exited).Select(s =>
    {
      var id = s.Definition.Id; long? outputAge = null, run = null, inputAge = null; bool? busy = null;
      if (outputSeen.TryGetValue(id, out var output)) { outputAge = Math.Max(0, now - output.Last); run = output.Last - output.RunStart; }
      if (inputSeen.TryGetValue(id, out var typed)) inputAge = Math.Max(0, now - typed);
      if (conversationFiles is not null && programs.TryGetValue(id, out var program) && program.Lease == s.LeaseIdentity)
        busy = conversationFiles.Live(s.Definition, program.Pid, program.StartedAt)?.Busy;
      return new SessionActivity(id, s.Definition.Provider, s.Definition.Title, outputAge, run, inputAge, busy);
    }).ToArray();
  }

  private void Remember(SessionRecord row, ProcessObservation observation)
  {
    if (observation.Presence == ProcessPresence.Live && observation.ProcessId is int pid && (observation.LeaseIdentity ?? row.LeaseIdentity) is { } lease)
      programs[row.Definition.Id] = (lease, pid, observation.ProcessStartedAt ?? 0);
  }
  private bool CanResume(SessionDefinition definition) => conversationFiles?.CanResume(definition) != false;
  private HashSet<string> ClaimedByOthers(string id) => Volatile.Read(ref ledger).Sessions
    .Where(s => s.Definition.Id != id && s.State != SessionState.Exited && s.Definition.ConversationId is not null).Select(s => s.Definition.ConversationId!).ToHashSet();
  // The conversation an AI terminal is in now: what the running AI reports first,
  // else the one transcript it moved to. Unchanged when neither says.
  private SessionDefinition FollowConversation(SessionRecord row, ProcessObservation? observation)
  {
    var definition = row.Definition;
    if (conversationFiles is null || definition.Provider is not ("claude" or "codex" or "gemini") || definition.Purpose is not null) return definition;
    var found = observation is { Presence: ProcessPresence.Live, ProcessId: int pid } ? conversationFiles.Live(definition, pid, observation.ProcessStartedAt ?? 0)?.ConversationId : null;
    found ??= conversationFiles.Discover(row, ClaimedByOthers(definition.Id));
    if (found is null && definition.ConversationId is null && !FolderHeldByOther(row)) found = conversationFiles.Newest(row);
    return found is null || found == definition.ConversationId ? definition : definition with { ConversationId = found };
  }
  private bool FolderHeldByOther(SessionRecord row) => Volatile.Read(ref ledger).Sessions.Any(s => s.Definition.Id != row.Definition.Id && s.State != SessionState.Exited &&
    s.Definition.Provider == row.Definition.Provider && (s.Definition.AccountHome ?? s.Definition.AccountId) == (row.Definition.AccountHome ?? row.Definition.AccountId) &&
    string.Equals(s.Definition.Cwd.TrimEnd('\\', '/'), row.Definition.Cwd.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase));
  // An older keeper handed this AI terminal over for an update without saving its
  // conversation (before 2 Nov): find it once, so this update resumes it too.
  private SessionRecord CatchUpHandedOver(SessionRecord row)
  {
    if (row.HasStarted || row.Resume || row.Definition.ConversationId is not null || row.Definition.Purpose is not null ||
        row.Definition.Provider is not ("claude" or "codex") || !row.ReplayPrefix.Contains("[Terminal Deck was updated.", StringComparison.Ordinal)) return row;
    var found = FollowConversation(row, null);
    if (found.ConversationId is null || !CanResume(found)) return row;
    var next = row with { Definition = found, Resume = true };
    Commit(next, "status");
    return next;
  }
  // While a Claude terminal prints, look (at most every 15 s) whether it moved to
  // another conversation, so a crash or update between hooks still resumes the right one.
  private void FollowConversationSoon(SessionRecord row, long now)
  {
    var id = row.Definition.Id;
    if (conversationFiles is null || row.Definition.Provider != "claude" || row.Definition.Purpose is not null ||
        !programs.TryGetValue(id, out var program) || program.Lease != row.LeaseIdentity) return;
    if (conversationChecked.TryGetValue(id, out var last) && now - last < ConversationCheckMs) return;
    conversationChecked[id] = now;
    var files = conversationFiles; var before = row.Definition.ConversationId;
    _ = Task.Run(async () =>
    {
      var reported = files.Live(row.Definition, program.Pid, program.StartedAt)?.ConversationId;
      if (reported is null || reported == before) return;
      await gate.WaitAsync();
      try
      {
        var current = RawGet(id);
        if (current.LeaseIdentity == program.Lease && current.State != SessionState.Exited && current.Definition.ConversationId != reported)
          Commit(current with { Definition = current.Definition with { ConversationId = reported } }, "status");
      }
      catch (Exception ex) when (ex is KeyNotFoundException or IOException or UnauthorizedAccessException) { }
      finally { gate.Release(); }
    });
  }
  // Terminals answer focus changes by themselves (ESC [ I / ESC [ O); that is not a person typing.
  private static bool OnlyFocusReports(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Length == 0 || bytes.Length % 3 != 0) return false;
    for (var i = 0; i < bytes.Length; i += 3)
      if (bytes[i] != 0x1b || bytes[i + 1] != (byte)'[' || bytes[i + 2] is not ((byte)'I' or (byte)'O')) return false;
    return true;
  }

  public async ValueTask WriteAsync(string id, Guid expectedInstance, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
  {
    if (bytes.Length > KeeperWire.MaximumInputBytes) throw new ArgumentException("That input is too large.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      await processes.WriteAsync(RequireLease(id, expectedInstance), bytes, cancellationToken);
      if (!OnlyFocusReports(bytes.Span)) inputSeen[id] = Clock();
    }
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
      if (row.ReplaySize != size) Commit(row with { ReplaySize = size }, "geometry", durableNow: false);
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

  private void CommitOutput(SessionRecord row, string text, bool durableNow)
  {
    var now = Clock();
    outputSeen.AddOrUpdate(row.Definition.Id, _ => (now, now), (_, seen) => (now, now - seen.Last > OutputRunGapMs ? now : seen.RunStart));
    FollowConversationSoon(row, now);
    var buffer = replayBuffers.GetOrAdd(row.Definition.Id, _ => { var created = new SessionReplayBuffer(); created.Replace(row.Replay); return created; });
    buffer.Append(text);
    var next = ledger with { Sequence = checked(ledger.Sequence + 1) };
    if (durableNow) Save(next); else ScheduleSave();
    Volatile.Write(ref ledger, next);
    var change = new SessionEvent(next.Sequence, row.Definition.Id, "data", text, row.ExitCode, row.ReplaySize);
    foreach (var watcher in watchers.Where(w => w.Snapshot.Session.Definition.Id == change.Id && !w.Closed)) watcher.Publish(change);
  }
  private void Commit(SessionRecord row, string kind, string? text = null, bool durableNow = true)
  {
    if (kind == "reset") replayBuffers.GetOrAdd(row.Definition.Id, _ => new SessionReplayBuffer()).Replace(row.Replay);
    else row = WithReplay(row);
    var next = ledger with { Sequence = checked(ledger.Sequence + 1), Sessions = ledger.Sessions.Where(s => s.Definition.Id != row.Definition.Id).Append(row).OrderBy(s => s.CreatedAt).ToArray() };
    if (durableNow) Save(next); else ScheduleSave();
    Volatile.Write(ref ledger, next);
    var change = new SessionEvent(next.Sequence, row.Definition.Id, kind, text, row.ExitCode, row.ReplaySize);
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
    lock (saveGate) { if (next.Sequence <= savedSequence) return; store.Save(next with { Sessions = next.Sessions.Select(WithReplay).ToArray() }); savedSequence = next.Sequence; }
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
  private readonly SessionEventBuffer events = new();
  public SessionSnapshot Snapshot { get; }
  public bool Closed => events.Closed;
  internal SessionAttachment(SessionSnapshot snapshot) { Snapshot = snapshot; }
  internal void Publish(SessionEvent change) => events.TryPublish(change);
  public IAsyncEnumerable<SessionEvent> Events(CancellationToken cancellationToken = default) => events.ReadAllAsync(cancellationToken);
  public ValueTask DisposeAsync() { events.Complete(); return ValueTask.CompletedTask; }

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
