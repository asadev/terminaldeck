namespace TerminalDeck.Core.WhatsApp;

/// The WhatsApp agents engine (DESIGN-WHATSAPP.md second version), a port of the Mac's BackendWhatsAppAgents.swift: the
/// profiles, their keys, where each is received, which computer reads it, and one WhatsAppLink per agent this computer
/// reads. What the screens and the tools call (IWhatsAppAgentsControlling). One engine per app.
public sealed class WhatsAppAgents : IWhatsAppAgentsControlling
{
  /// A computer that has been off this long gives its Hoot and agent receivers to one that is on (design section 5).
  public static readonly TimeSpan TakeOverAfter = TimeSpan.FromMinutes(10);
  /// The reader decision is looked at again this often (take-over, a key that arrived, a session that ended).
  public static readonly TimeSpan LookEvery = TimeSpan.FromSeconds(60);

  private readonly IWhatsAppTransport transport;
  private readonly IWhatsAppSettingsPort settings;
  private readonly IWhatsAppKeyKeeping keys;
  private readonly IWhatsAppPresencePort presence;
  private readonly IWhatsAppReceiverPort receivers;
  private readonly IWhatsAppClock clock;
  /// A key removed in the app goes everywhere through the saved passwords' delete rule; false = not handled there (saved
  /// passwords off) and the key is removed here only.
  private readonly Func<string, Task<bool>> removeEverywhere;

  private readonly Lock gate = new();
  private readonly Dictionary<string, WhatsAppLink> links = new(StringComparer.Ordinal);
  private Action<IReadOnlyList<WhatsAppAgentProfile>>? changed;
  private CancellationTokenSource? ticking;
  private bool started, reconciling, again;
  /// Tells the saved passwords a key was added or replaced here, so it travels at once.
  private Action? keysChanged;
  public void SetKeysChanged(Action? handler) { lock (gate) keysChanged = handler; }

  public WhatsAppAgents(IWhatsAppTransport transport, IWhatsAppSettingsPort settings, IWhatsAppKeyKeeping keys, IWhatsAppPresencePort presence,
    IWhatsAppReceiverPort receivers, IWhatsAppClock? clock = null, Func<string, Task<bool>>? removeEverywhere = null)
  {
    this.transport = transport; this.settings = settings; this.keys = keys; this.presence = presence; this.receivers = receivers;
    this.clock = clock ?? WhatsAppSystemClock.Shared; this.removeEverywhere = removeEverywhere ?? (_ => Task.FromResult(false));
  }

  /// Starts following the settings and reading the agents this computer reads. Safe to call twice.
  public async Task StartAsync()
  {
    CancellationToken token;
    lock (gate)
    {
      if (started) return;
      started = true;
      ticking = new CancellationTokenSource();
      token = ticking.Token;
    }
    settings.Observe(() => _ = ReconcileAsync());
    _ = Task.Run(async () =>
    {
      while (!token.IsCancellationRequested)
      {
        try { await clock.DelayAsync(LookEvery, token); } catch (OperationCanceledException) { return; }
        if (token.IsCancellationRequested) return;
        await ReconcileAsync();
      }
    });
    await ReconcileAsync();
  }
  public void Stop()
  {
    WhatsAppLink[] all;
    lock (gate)
    {
      ticking?.Cancel(); ticking = null;
      all = links.Values.ToArray(); links.Clear(); started = false;
    }
    foreach (var link in all) link.Stop();
  }

  // ---- Records ----

  private async Task<List<WhatsAppAgentRecord>> LiveAsync() =>
    (await settings.RecordsAsync()).Where(r => !r.Removed).OrderBy(r => r.AddedAt).ThenBy(r => r.Id, StringComparer.Ordinal).ToList();
  internal async Task<WhatsAppAgentRecord?> RecordAsync(string id) => (await settings.RecordsAsync()).FirstOrDefault(r => r.Id == id);
  private async Task ChangeAsync(string id, Func<WhatsAppAgentRecord, WhatsAppAgentRecord> edit)
  {
    if (await RecordAsync(id) is not { Removed: false } record) throw WhatsAppProblem.NotFound;
    await settings.SaveAsync(edit(record));
  }
  private WhatsAppLink? TakeLink(string id) { lock (gate) { if (links.Remove(id, out var l)) return l; return null; } }

  // ---- IWhatsAppAgentsControlling ----

  public async Task<IReadOnlyList<WhatsAppAgentProfile>> AgentsAsync()
  {
    var me = presence.ThisComputer();
    var output = new List<WhatsAppAgentProfile>();
    foreach (var record in await LiveAsync())
    {
      var state = record.Refused ? WhatsAppAgentState.Refused : record.Creator is not null ? WhatsAppAgentState.Connected : WhatsAppAgentState.Waiting;
      string? reader = null;
      if (record.ReaderId is { } rid) reader = rid == me.Id ? me.Name : (await presence.NameAsync(rid) ?? record.ReaderName);
      var nowhere = record.Receiver.Kind == WhatsAppReceiverKind.Nowhere;
      output.Add(new WhatsAppAgentProfile(record.Id, record.Name, state, record.Receiver, nowhere ? null : reader,
        record.ReaderId == me.Id && !nowhere, record.TakenOver,
        record.LastMessageAt is double ms ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms) : null, record.IsSending));
    }
    return output;
  }
  public Task ObserveAsync(Action<IReadOnlyList<WhatsAppAgentProfile>>? changed) { lock (gate) this.changed = changed; return Task.CompletedTask; }

  private async Task<string> CheckedAsync(string key)
  {
    var clean = key.Trim();
    if (!WhatsAppAgentIds.PlausibleKey(clean)) throw WhatsAppProblem.KeyRefused;
    return await transport.CheckAsync(clean) switch
    {
      WhatsAppKeyCheck.Accepted => clean,
      WhatsAppKeyCheck.Refused => throw WhatsAppProblem.KeyRefused,
      _ => throw WhatsAppProblem.Unreachable,
    };
  }
  public static string CleanName(string name, IEnumerable<string> taken)
  {
    var line = (name ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
    if (line.Length == 0) return WhatsAppAgentsLimits.DefaultName(taken);
    return Cloud.CloudKeysTravel.Prefix(line, WhatsAppAgentsLimits.MaximumNameLength);
  }

  public async Task<WhatsAppAgentProfile> AddAsync(string name, string key)
  {
    var existing = await LiveAsync();
    // The same key added twice is the same agent: the one row it already has. Looked at BEFORE the check, because
    // WhatsApp's key check replaces a reader already running for that key (one reader per agent).
    var typed = (key ?? "").Trim();
    foreach (var record in existing)
    {
      string? held;
      try { held = await keys.KeyAsync(record.Id); } catch (Exception) { held = null; }
      if (held == typed && (await AgentsAsync()).FirstOrDefault(p => p.Id == record.Id) is { } same) return same;
    }
    var clean = await CheckedAsync(typed);
    var me = presence.ThisComputer();
    var id = WhatsAppAgentIds.Make();
    // The first agent he adds is received by Hoot; later ones wait for him to choose.
    var receiver = existing.Count == 0 ? WhatsAppReceiver.Hoot : WhatsAppReceiver.Nowhere;
    var nowhere = receiver.Kind == WhatsAppReceiverKind.Nowhere;
    var made = new WhatsAppAgentRecord
    {
      Id = id, Name = CleanName(name, existing.Select(r => r.Name)), Receiver = receiver,
      ReaderId = nowhere ? null : me.Id, ReaderName = nowhere ? null : me.Name,
      AddedAt = clock.Now.ToUnixTimeMilliseconds(), KeyId = WhatsAppAgentIds.Fingerprint(clean),
    };
    try { await keys.SetKeyAsync(clean, id); } catch (Exception) { throw WhatsAppProblem.NotReady; }
    await settings.SaveAsync(made);
    KeysChanged();
    await ReconcileAsync();
    return (await AgentsAsync()).FirstOrDefault(p => p.Id == id) ?? new WhatsAppAgentProfile(id, made.Name, WhatsAppAgentState.Waiting, receiver);
  }
  private void KeysChanged() { Action? k; lock (gate) k = keysChanged; k?.Invoke(); }

  public async Task RenameAsync(string id, string name)
  {
    var taken = (await LiveAsync()).Where(r => r.Id != id).Select(r => r.Name).ToArray();
    await ChangeAsync(id, r => r with { Name = CleanName(name, taken) });
    await TellAsync();
  }
  public async Task ReplaceKeyAsync(string id, string key)
  {
    if (await RecordAsync(id) is null) throw WhatsAppProblem.NotFound;
    // This computer stops reading it first: the check replaces any reader of that key.
    TakeLink(id)?.Stop();
    string clean;
    try { clean = await CheckedAsync(key ?? ""); } catch (Exception) { await ReconcileAsync(); throw; }
    try { await keys.SetKeyAsync(clean, id); } catch (Exception) { throw WhatsAppProblem.NotReady; }
    // A new key: its own fingerprint; sender and position start fresh (every computer drops the old reader).
    var print = WhatsAppAgentIds.Fingerprint(clean);
    await ChangeAsync(id, r => r with { Refused = false, Offset = null, Creator = null, LastMessageAt = null, KeyId = print });
    KeysChanged();
    await ReconcileAsync();
  }
  public async Task RemoveAsync(string id)
  {
    TakeLink(id)?.Stop();
    await ChangeAsync(id, r => r with { Removed = true, Receiver = WhatsAppReceiver.Nowhere, ReaderId = null });
    if (!await removeEverywhere(id)) { try { await keys.RemoveAsync(id, null); } catch (Exception) { } }
    await TellAsync();
  }
  public async Task SetReceiverAsync(string id, WhatsAppReceiver receiver)
  {
    var me = presence.ThisComputer();
    var nowhere = receiver.Kind == WhatsAppReceiverKind.Nowhere;
    // A new receiver replaces the old session's Cloud id (the Mac's setReceiver): a session's own, anything else none.
    var cloud = receiver.Kind == WhatsAppReceiverKind.Session ? await receivers.CloudSessionIdAsync(receiver.Id) : null;
    // Moving the receiver moves the reader: the computer where he attached it. Attaching turns the switch on.
    await ChangeAsync(id, r => r with
    {
      Receiver = receiver, ReaderId = nowhere ? null : me.Id, ReaderName = nowhere ? null : me.Name,
      TakenOver = false, EndedSession = false, Sending = true, CloudSessionId = cloud,
    });
    TakeLink(id)?.Stop();
    await ReconcileAsync();
  }
  public async Task SetSendingAsync(bool on, string agentId)
  {
    await ChangeAsync(agentId, r => r with { Sending = on });
    await TellAsync();
  }
  public async Task OffAsync(WhatsAppReceiver receiver)
  {
    foreach (var record in await LiveAsync())
      if (record.Receiver.SameTarget(receiver)) await SetReceiverAsync(record.Id, WhatsAppReceiver.Nowhere);
  }

  // ---- Sessions and tools ----

  /// A session that ended or was closed: its WhatsApp agents go to "Nowhere"; the next message is answered once.
  public async Task SessionEndedAsync(string sessionId)
  {
    foreach (var record in await LiveAsync())
      if (record.Receiver.SameTarget(WhatsAppReceiver.Session(sessionId, "")))
        try { await ChangeAsync(record.Id, r => r with { Receiver = WhatsAppReceiver.Nowhere, EndedSession = true }); } catch (WhatsAppProblem) { }
    await ReconcileAsync();
  }
  /// The WhatsApp agents attached to this session (the tools' "the calling session is the attached one").
  public async Task<IReadOnlyList<string>> AttachedAsync(string sessionId) =>
    (await LiveAsync()).Where(r => r.Receiver.SameTarget(WhatsAppReceiver.Session(sessionId, ""))).Select(r => r.Id).ToArray();

  /// True when a tool call carrying sessionId comes from the place this WhatsApp agent is received: then
  /// whatsapp.receive, whatsapp.send and whatsapp.sending do not ask.
  public async Task<bool> IsFromAsync(string? sessionId, string id)
  {
    if (string.IsNullOrEmpty(sessionId) || await RecordAsync(id) is not { Removed: false } record) return false;
    if (record.Receiver.SameTarget(WhatsAppReceiver.Session(sessionId, ""))) return true;
    WhatsAppLink? link; lock (gate) links.TryGetValue(id, out link);
    if (link?.CurrentTarget is not { } target) return false;
    return target.SessionId == sessionId || await receivers.IsToolSessionAsync(target, sessionId);
  }

  /// One text to him on that WhatsApp agent (whatsapp.send). Only ever to its creator.
  public async Task SendAsync(string id, string text)
  {
    if (await RecordAsync(id) is not { Removed: false } record) throw WhatsAppProblem.NotFound;
    if (record.Creator is not { } creator)
      throw new WhatsAppProblem("He has not written to this WhatsApp agent yet, and WhatsApp only lets an agent answer its creator.");
    string? key;
    try { key = await keys.KeyAsync(id); } catch (Exception) { key = null; }
    if (record.Refused || key is null) throw WhatsAppProblem.KeyRefused;
    WhatsAppLink? link; lock (gate) links.TryGetValue(id, out link);
    if (link is not null) { link.Send(text, creator); await link.FlushedAsync(); return; }
    // Read by another computer: one send from here, in pieces, one after another.
    foreach (var piece in WhatsAppText.Split(WhatsAppText.Format(text)))
    {
      switch (await transport.SendAsync(key, creator, piece))
      {
        case WhatsAppSent.Sent: continue;
        case WhatsAppSent.KeyRefused: throw WhatsAppProblem.KeyRefused;
        case WhatsAppSent.BackOff: throw new WhatsAppProblem("WhatsApp asked to slow down. Try again in a minute.");
        default: throw new WhatsAppProblem("WhatsApp did not take this message.");
      }
    }
  }

  // ---- One reader per agent ----

  /// Whether THIS computer reads the agent now, taking it over from a computer that has been off for 10 minutes.
  internal async Task<bool> DecideAsync(WhatsAppAgentRecord record, WhatsAppComputer me)
  {
    if (record.Removed || record.Refused || record.Receiver.Kind == WhatsAppReceiverKind.Nowhere && !record.EndedSession) return false;
    if (record.ReaderId == me.Id) return true;
    if (!record.Receiver.CanMoveComputer) return false;
    bool off;
    if (record.ReaderId is { } reader)
    {
      if (await presence.LastSeenAsync(reader) is not { } seen) return false;
      off = clock.Now - seen > TakeOverAfter;
    }
    else off = true;
    if (!off) return false;
    try { await ChangeAsync(record.Id, r => r with { ReaderId = me.Id, ReaderName = me.Name, TakenOver = true }); } catch (WhatsAppProblem) { return false; }
    return true;
  }

  /// One decision at a time: a change arriving meanwhile runs one more pass after it (never two passes at once).
  public async Task ReconcileAsync()
  {
    lock (gate) { if (reconciling) { again = true; return; } reconciling = true; }
    try
    {
      while (true)
      {
        lock (gate) again = false;
        await PassAsync();
        lock (gate) { if (!again) { reconciling = false; return; } }
      }
    }
    catch (Exception)
    {
      lock (gate) reconciling = false;
    }
  }

  private async Task PassAsync()
  {
    var me = presence.ThisComputer();
    var wanted = new HashSet<string>(StringComparer.Ordinal);
    foreach (var record in await LiveAsync())
    {
      if (!await DecideAsync(record, me)) continue;
      // Fault 1: only with the key this record belongs to (a replaced key that has not arrived here: not yet).
      string? key;
      try { key = await keys.KeyAsync(record.Id); } catch (Exception) { continue; }
      if (key is null) continue;
      var print = WhatsAppAgentIds.Fingerprint(key);
      if (record.KeyId != print) continue;
      wanted.Add(record.Id);
      WhatsAppLink? stale = null, made = null;
      var id = record.Id; var meId = me.Id;
      lock (gate)
      {
        if (links.TryGetValue(id, out var runningLink) && runningLink.KeyId != print) { stale = runningLink; links.Remove(id); }
        if (!links.ContainsKey(id))
        {
          made = new WhatsAppLink(id, key, transport, receivers, clock,
            read: () => RecordAsync(id),
            update: edit => LinkChangeAsync(id, print, edit),
            stopped: why => LinkStoppedAsync(id, why),
            stillReader: async () =>
            {
              // Fault 2: messages are handled only while the record still names THIS computer with this key.
              return await RecordAsync(id) is { Removed: false } r && r.ReaderId == meId && r.KeyId == print;
            });
          links[id] = made;
        }
      }
      stale?.Stop();
      made?.Start();
    }
    WhatsAppLink[] gone;
    lock (gate)
    {
      gone = links.Where(l => !wanted.Contains(l.Key)).Select(l => l.Value).ToArray();
      foreach (var l in gone) links.Remove(l.AgentId);
    }
    foreach (var l in gone) l.Stop();
    await TellAsync();
  }

  /// A link's write is dropped once the record belongs to another key (fault 1).
  private async Task LinkChangeAsync(string id, string keyId, Func<WhatsAppAgentRecord, WhatsAppAgentRecord> edit)
  {
    if (await RecordAsync(id) is not { } current || current.KeyId != keyId) return;
    try { await ChangeAsync(id, edit); } catch (WhatsAppProblem) { }
    await TellAsync();
  }
  /// The link stopped (no longer the reader, or the key refused): the settings decide again.
  private async Task LinkStoppedAsync(string id, WhatsAppLink.StopReason why)
  {
    TakeLink(id)?.Stop();
    await ReconcileAsync();
  }
  private async Task TellAsync()
  {
    Action<IReadOnlyList<WhatsAppAgentProfile>>? c; lock (gate) c = changed;
    if (c is null) return;
    c(await AgentsAsync());
  }

  /// Test seam: the link reading this agent here, if any.
  internal WhatsAppLink? Link(string id) { lock (gate) return links.GetValueOrDefault(id); }
  /// Test seam: the agents read here now.
  internal IReadOnlyList<string> ReadHere() { lock (gate) return links.Keys.Order(StringComparer.Ordinal).ToArray(); }
}
