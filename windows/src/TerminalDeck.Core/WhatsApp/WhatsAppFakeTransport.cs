namespace TerminalDeck.Core.WhatsApp;

/// A scriptable stand-in for WhatsApp, for everyone's tests (engine, screens, tools). A port of the Mac's
/// WhatsAppFakeTransport.swift, name for name, so the engine's tests port across unchanged.
///
/// - Messages: Deliver puts new messages after the head (what an offset-less poll returns); AddBacklog puts messages
///   before the head (only offset 0 or an older offset sees them). Each entry has a sequence number from 1;
///   a poll returns up to 50 entries at or after its offset and Next = the last one's number + 1, as WhatsApp does.
/// - Outcomes: ScriptPolls / ScriptSends / ScriptReads / ScriptChecks queue answers that are used first, in order
///   (nothing, replaced, key refused, back off, failed ...). Refuse(key) refuses a key everywhere.
/// - Records: Polls, Sent, Reads, Checks, MediaFetches, each with the virtual time it happened.
/// - Virtual time: Now starts at 0 and moves only by Advance or a poll that finds nothing (by its timeout),
///   so tests never sleep. Thread-safe.
public sealed class WhatsAppFakeTransport(string? creator = "user:1000") : IWhatsAppTransport
{
  public sealed record PollCall(string Key, long? Offset, int Timeout, double At);
  public sealed record SentText(string Key, string To, string Text, double At);
  public sealed record ReadMark(string Key, string MessageId, bool Typing, double At);

  private readonly object gate = new();
  private readonly List<(long Seq, WhatsAppInbound Message)> log = [];
  private readonly List<PollCall> polls = [];
  private readonly List<SentText> sent = [];
  private readonly List<ReadMark> reads = [];
  private readonly List<string> checks = [];
  private readonly List<string> mediaFetches = [];
  private readonly HashSet<string> refused = new(StringComparer.Ordinal);
  private readonly Queue<WhatsAppPoll> pollScript = new();
  private readonly Queue<WhatsAppSent> sendScript = new();
  private readonly Queue<WhatsAppSent> readScript = new();
  private readonly Queue<WhatsAppKeyCheck> checkScript = new();
  private readonly Dictionary<string, WhatsAppMedia> stored = new(StringComparer.Ordinal);
  private readonly Dictionary<string, List<double>> windows = new(StringComparer.Ordinal);
  private long nextSeq = 1;
  private long head = 1;
  private double now;
  private string? creator = creator;
  private bool limitsEnforced;

  public double Now { get { lock (gate) return now; } }
  public IReadOnlyList<PollCall> Polls { get { lock (gate) return polls.ToArray(); } }
  public IReadOnlyList<SentText> Sent { get { lock (gate) return sent.ToArray(); } }
  public IReadOnlyList<ReadMark> Reads { get { lock (gate) return reads.ToArray(); } }
  public IReadOnlyList<string> Checks { get { lock (gate) return checks.ToArray(); } }
  public IReadOnlyList<string> MediaFetches { get { lock (gate) return mediaFetches.ToArray(); } }
  /// When set, a send to anyone else answers NotCreator (as WhatsApp's 403 131005).
  public string? Creator { get { lock (gate) return creator; } }
  /// When true, the manual's per-key limits answer BackOff (12 sends, 12 status calls, 15 polls a minute).
  public bool LimitsEnforced { get { lock (gate) return limitsEnforced; } }
  /// The texts sent, in order (any key).
  public IReadOnlyList<string> SentTexts { get { lock (gate) return sent.Select(s => s.Text).ToArray(); } }
  /// The sequence number the next delivered message gets (= the Next a poll would give after it).
  public long NextOffset { get { lock (gate) return nextSeq; } }

  public override string ToString() => nameof(WhatsAppFakeTransport);

  // ---- scripting ------------------------------------------------------------------------------------------

  public void Deliver(IEnumerable<WhatsAppInbound> messages) { lock (gate) foreach (var m in messages) Append(m); }
  public void Deliver(params WhatsAppInbound[] messages) => Deliver((IEnumerable<WhatsAppInbound>)messages);
  /// Messages already there before the agent was connected: behind the head.
  public void AddBacklog(IEnumerable<WhatsAppInbound> messages) { lock (gate) { foreach (var m in messages) Append(m); head = nextSeq; } }
  public void ScriptPolls(IEnumerable<WhatsAppPoll> outcomes) { lock (gate) foreach (var o in outcomes) pollScript.Enqueue(o); }
  public void ScriptSends(IEnumerable<WhatsAppSent> outcomes) { lock (gate) foreach (var o in outcomes) sendScript.Enqueue(o); }
  public void ScriptReads(IEnumerable<WhatsAppSent> outcomes) { lock (gate) foreach (var o in outcomes) readScript.Enqueue(o); }
  public void ScriptChecks(IEnumerable<WhatsAppKeyCheck> outcomes) { lock (gate) foreach (var o in outcomes) checkScript.Enqueue(o); }
  /// The next poll answers Replaced, as when another computer started reading this agent.
  public void ReplaceNextPoll() { lock (gate) pollScript.Enqueue(WhatsAppPoll.ReplacedByNewer); }
  public void Refuse(string key) { lock (gate) refused.Add(key); }
  public void Accept(string key) { lock (gate) refused.Remove(key); }
  public void SetCreator(string? value) { lock (gate) creator = value; }
  public void EnforceLimits(bool on = true) { lock (gate) limitsEnforced = on; }
  public void SetMedia(string id, WhatsAppMedia media) { lock (gate) stored[id] = media; }
  public void Advance(double seconds) { lock (gate) now += Math.Max(seconds, 0); }

  /// A text message from `from`, `seconds` after 1 Jan 2026, for quick scripts.
  public static WhatsAppInbound Text(string body, string id, string from = "user:1000", double seconds = 0) =>
    new(id, from, DateTimeOffset.FromUnixTimeSeconds(1_767_225_600).AddSeconds(seconds), WhatsAppInboundKind.Text, Text: body);

  // ---- the protocol ---------------------------------------------------------------------------------------

  public Task<WhatsAppKeyCheck> CheckAsync(string key, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    lock (gate)
    {
      checks.Add(key);
      if (refused.Contains(key)) return Task.FromResult(WhatsAppKeyCheck.Refused);
      return Task.FromResult(checkScript.TryDequeue(out var scripted) ? scripted : WhatsAppKeyCheck.Accepted);
    }
  }

  public Task<WhatsAppPoll> PollAsync(string key, long? offset, int timeout, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    lock (gate)
    {
      polls.Add(new(key, offset, timeout, now));
      if (refused.Contains(key)) return Task.FromResult(WhatsAppPoll.Refused);
      if (OverLimit(key + "#poll", WhatsAppLimits.PollsPerMinute) is double wait) return Task.FromResult<WhatsAppPoll>(new WhatsAppPoll.BackOff(wait));
      if (pollScript.TryDequeue(out var scripted)) return Task.FromResult(scripted);
      var from = offset is long o ? Math.Max(o, 0) : head;
      var found = log.Where(e => e.Seq >= from).Take(WhatsAppLimits.PollBatch).ToArray();
      if (found.Length == 0)
      {
        now += Math.Clamp(timeout, 0, WhatsAppLimits.PollTimeoutMaxSeconds);
        return Task.FromResult(WhatsAppPoll.NothingNew);
      }
      return Task.FromResult<WhatsAppPoll>(new WhatsAppPoll.Messages(found.Select(e => e.Message).ToArray(), found[^1].Seq + 1));
    }
  }

  public Task<WhatsAppSent> MarkReadAsync(string key, string messageId, bool typing, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    lock (gate)
    {
      if (refused.Contains(key)) return Task.FromResult(WhatsAppSent.Refused);
      if (OverLimit(key + "#status", WhatsAppLimits.StatusesPerMinute) is double wait) return Task.FromResult<WhatsAppSent>(new WhatsAppSent.BackOff(wait));
      if (readScript.TryDequeue(out var scripted)) return Task.FromResult(scripted);
      reads.Add(new(key, messageId, typing, now));
      return Task.FromResult(WhatsAppSent.Done);
    }
  }

  public Task<WhatsAppSent> SendAsync(string key, string to, string text, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    lock (gate)
    {
      if (refused.Contains(key)) return Task.FromResult(WhatsAppSent.Refused);
      if (creator is not null && to != creator) return Task.FromResult(WhatsAppSent.NotTheCreator);
      if (string.IsNullOrEmpty(text) || text.Length > WhatsAppText.Limit)
        return Task.FromResult<WhatsAppSent>(new WhatsAppSent.Failed($"The message is longer than WhatsApp allows ({WhatsAppText.Limit} characters)."));
      if (OverLimit(key + "#send", WhatsAppLimits.SendsPerMinute) is double wait) return Task.FromResult<WhatsAppSent>(new WhatsAppSent.BackOff(wait));
      if (sendScript.TryDequeue(out var scripted) && scripted is not WhatsAppSent.Sent) return Task.FromResult(scripted);
      sent.Add(new(key, to, text, now));
      return Task.FromResult(WhatsAppSent.Done);
    }
  }

  public Task<WhatsAppMedia?> MediaAsync(string key, string id, long limit, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    lock (gate)
    {
      mediaFetches.Add(id);
      if (refused.Contains(key) || !stored.TryGetValue(id, out var media) || media.Data.LongLength > limit) return Task.FromResult<WhatsAppMedia?>(null);
      return Task.FromResult<WhatsAppMedia?>(media);
    }
  }

  // ---- private --------------------------------------------------------------------------------------------

  private void Append(WhatsAppInbound message) { log.Add((nextSeq, message)); nextSeq++; }

  /// With limits on: records the call, or gives the seconds until the rolling minute has room.
  private double? OverLimit(string window, int most)
  {
    if (!limitsEnforced) return null;
    if (!windows.TryGetValue(window, out var recent)) windows[window] = recent = [];
    recent.RemoveAll(t => now - t >= 60);
    if (recent.Count >= most) return Math.Max(60 - (now - recent[0]), 0.001);
    recent.Add(now);
    return null;
  }
}
