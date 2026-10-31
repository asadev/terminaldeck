using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Usage;

/// A session as the usage service reads it: its AI, folder, its OWN login (never another
/// account's), its conversation, and for a chat the record whose turns carry the usage.
public sealed record UsageSubject(string SessionId, string Provider, string Cwd, UsageAccount? Account, string? ConversationId = null,
  bool OnServer = false, ChatRecord? Chat = null, string? Screen = null);

/// One place that owns usage readings (Mac `BackendUsageService`): a pool of plan windows per login,
/// seeded from what each CLI already wrote (at most every 30 s), refreshed on demand by the probe
/// (with a 60 s floor, five-minute cache and one probe per login at a time), and re-read when the
/// CLI's own files change. No timer polls; file changes are debounced.
public sealed class UsageService : IDisposable
{
  public const string ApiUsageNote = "This account uses API billing. This view reads CLI subscription limits; API spend, credits and balance are not reported here.";
  public const string RecentlyRead = "This login was read a moment ago and had nothing to report.";
  private readonly Func<string, UsageSubject?> subject;
  private readonly Func<IReadOnlyList<UsageAccount>> accounts;
  private readonly IUsageProbe? probe;
  private readonly Func<string, string> modelLabel;
  private readonly Func<double> clock;
  private readonly bool watchFiles;
  private readonly object gate = new();
  private readonly Dictionary<string, UsageReading> pool = [];
  private readonly Dictionary<string, double> seededAt = [], lastProbeAt = [];
  private readonly HashSet<string> noLimits = [];
  private readonly Dictionary<string, string> billing = [];
  private readonly Dictionary<string, Task<UsageProbeOutcome>> inFlight = [];
  private readonly Dictionary<string, FileWatch> watches = [];
  private bool disposed;

  public UsageService(Func<string, UsageSubject?> subject, Func<IReadOnlyList<UsageAccount>> accounts, IUsageProbe? probe = null,
    Func<string, string>? modelLabel = null, Func<double>? clock = null, bool watchFiles = true)
  {
    this.subject = subject; this.accounts = accounts; this.probe = probe; this.watchFiles = watchFiles;
    this.modelLabel = modelLabel ?? (id => ModelNames.Display(id, []));
    this.clock = clock ?? UsageFormat.Now;
  }

  /// A reading changed for this session (its account's files, its transcript, or a finished refresh).
  public event Action<string>? Changed;

  public UsageReport Read(string? sessionId)
  {
    var now = clock();
    if (sessionId is null)
    {
      var all = accounts().Where(a => a.Provider is "claude" or "codex" && !a.ApiKey && a.Home is not null).Take(64).ToArray();
      var failed = new List<string>();
      foreach (var each in all) { try { Seed(each); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failed.Add((each.Name ?? each.Key) + ": " + ex.Message); } }
      var valid = all.Select(a => a.Key).ToHashSet();
      lock (gate) return new(null, null, pool.Values.Where(r => valid.Contains(r.Account.Key)).OrderBy(Minutes).ThenBy(r => r.Id, StringComparer.Ordinal).ToArray(),
        failed.Count == 0 ? "No account has reported a subscription usage reading yet." : string.Join("; ", failed), now);
    }
    var session = subject(sessionId);
    if (session is null) return new(sessionId, null, [], "That session is not running here, so its account is unknown.", now);
    if (session.OnServer) return new(sessionId, null, [], UsageBarRules.ServerWithheld, now);
    if (session.Account is not { } account || account.Provider is not ("claude" or "codex" or "gemini")) return new(sessionId, null, [], "That session has no established agent account on this computer.", now);
    if (account.ApiKey) return new(sessionId, account, [], ApiUsageNote, now);
    if (account.Provider == "gemini") return new(sessionId, account, [], "Gemini CLI does not write down any plan limits, so there is nothing to show for this login.", now);
    string? failure = null;
    try { Seed(account); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failure = ex.Message; }
    if (account.Provider == "claude" && session.Screen is { } screen) Capture(account, screen, now);
    UsageReading[] readings;
    lock (gate) readings = account.Home is null ? [] : pool.Values.Where(r => r.Account.Key == account.Key).OrderBy(Minutes).ThenBy(r => r.Id, StringComparer.Ordinal).ToArray();
    return new(sessionId, account, readings, readings.Length > 0 ? null : failure ?? (account.Home is null
      ? "The running agent's login has not been established, so another account's limits are not shown."
      : account.Provider == "codex" ? "Codex has not recorded a rate limit under this account yet; it records one when a turn completes."
      : "No subscription usage has been reported under this account yet."), now);
  }

  public ContextReading Context(string sessionId)
  {
    var now = clock(); var session = subject(sessionId);
    if (session is null) return ContextReading.Blank("", ContextReading.NotReported, "That session is not running here, so its folder and transcript are unknown.", now);
    if (session.OnServer) return ContextReading.Blank(session.Provider, ContextReading.NotReported, UsageBarRules.ServerWithheld, now);
    if (session.Chat is { } chat) return UsageSources.ChatContext(chat, modelLabel, now);
    if (session.Provider is not ("claude" or "codex"))
      return ContextReading.Blank(session.Provider, ContextReading.NotReported, session.Provider == "gemini" ? UsageSources.GeminiNote
        : session.Provider == "shell" ? "This tab is a plain shell, so there is no model and no context window to measure." : "This agent does not write down how full its context window is, so there is nothing to read.", now);
    if (session.Account?.Home is not { } home)
      return ContextReading.Blank(session.Provider, ContextReading.NothingYet, "This app does not know which account this session runs as, so it cannot find the transcript that would carry the figure.", now);
    return UsageSources.ReadContext(session.Provider, home, session.Cwd, session.ConversationId, modelLabel, now);
  }

  /// Opening the plan card is the refresh. Claude asks Claude Code itself (bounded, never in a session);
  /// Codex re-reads what it wrote after its last turn.
  public async ValueTask<UsageProbeOutcome> RefreshAsync(string sessionId, bool force, CancellationToken cancellationToken = default)
  {
    var start = clock();
    UsageProbeOutcome Answer(string kind, string detail) => new(kind, detail, [], false, clock() - start);
    var session = subject(sessionId);
    if (session?.Account is not { } account) return Answer("unwatched", "That session's login has not been established here.");
    if (account.ApiKey) return Answer("no-limits", ApiUsageNote);
    if (account.Home is not { } home) return Answer("unwatched", "That session's login has not been established here.");
    if (account.Provider == "codex")
    {
      lock (gate) seededAt.Remove(account.Key);
      try { Seed(account); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return Answer("unreadable", ex.Message); }
      Changed?.Invoke(sessionId);
      lock (gate) return pool.Values.Any(r => r.Account.Key == account.Key)
        ? Answer("cached", "Read from what Codex wrote after its last turn — nothing was started.")
        : Answer("nothing", "Codex has not recorded a rate limit under this account yet; it records one when a turn completes.");
    }
    if (account.Provider != "claude") return Answer("unwatched", "This session runs another agent, so its login has no Claude limits to read.");
    lock (gate) seededAt.Remove(account.Key);
    try { Seed(account); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* a corrupt cache cannot stop a fresh request */ }
    if (session.Screen is { } screen) Capture(account, screen, clock());
    Task<UsageProbeOutcome>? running;
    lock (gate)
    {
      var newest = pool.Values.Where(r => r.Account.Key == account.Key).Select(r => r.ReportedAt).DefaultIfEmpty(0).Max();
      if (!force && newest > 0 && start - newest < 300_000) return Answer("cached", "Claude Code fetched this less than five minutes ago; its newest figure is already available.");
      if (!force && noLimits.Contains(home)) return Answer("settled", "This login has no subscription limits, so there is nothing to read.");
      if (!force && billing.GetValueOrDefault(account.Key) == "api") { noLimits.Add(home); return Answer("no-limits", "This login is billed through the Claude API, which has no subscription limits to read."); }
      if (!force && start - lastProbeAt.GetValueOrDefault(home) < 60_000) return Answer("unreadable", RecentlyRead);
      if (probe is null) return Answer("no-binary", UsageBarRules.OutcomeMessage("no-binary"));
      if (!inFlight.TryGetValue(account.Key, out running))
      {
        running = probe.RunAsync(account, cancellationToken).AsTask();
        inFlight[account.Key] = running;
      }
    }
    UsageProbeOutcome result;
    try { result = await running.ConfigureAwait(false); }
    finally { lock (gate) { if (inFlight.TryGetValue(account.Key, out var current) && current == running) inFlight.Remove(account.Key); lastProbeAt[home] = clock(); } }
    lock (gate)
    {
      if (disposed) return result;
      Merge(result.Readings);
      if (result.Kind == "ok") noLimits.Remove(home);
      else if (result.Kind == "no-limits") noLimits.Add(home);
    }
    Changed?.Invoke(sessionId);
    return result;
  }

  /// Keep this session's figures live while something shows them: the CLI's own files are watched
  /// (no polling) and every change, after a short settle, raises `Changed` for the session.
  public IDisposable Watch(string sessionId)
  {
    lock (gate)
    {
      if (disposed || !watchFiles) return new Release(() => { });
      if (watches.TryGetValue(sessionId, out var existing)) { existing.Count++; return new Release(() => Unwatch(sessionId)); }
    }
    var session = subject(sessionId); var paths = new List<(string Folder, string Filter, bool Deep)>();
    if (session is { OnServer: false, Account: { Home: { } home, ApiKey: false } account })
    {
      if (account.Provider == "claude")
      {
        foreach (var file in UsageSources.ClaudeJsonFiles(home)) if (Path.GetDirectoryName(file) is { } folder) paths.Add((folder, ".claude.json", false));
        paths.Add((Directory.Exists(Path.Combine(home, "projects")) ? Path.Combine(home, "projects") : home, "*.jsonl", true));
      }
      else if (account.Provider == "codex") paths.Add((Directory.Exists(Path.Combine(home, "sessions")) ? Path.Combine(home, "sessions") : home, "*.jsonl", true));
    }
    var watch = new FileWatch(this, sessionId, session?.Account?.Key);
    foreach (var (folder, filter, deep) in paths.Distinct())
    {
      if (!Directory.Exists(folder)) continue;
      try
      {
        var watcher = new FileSystemWatcher(folder, filter) { IncludeSubdirectories = deep, NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName, InternalBufferSize = 16 * 1024 };
        watcher.Changed += (_, _) => watch.Poke(); watcher.Created += (_, _) => watch.Poke(); watcher.Renamed += (_, _) => watch.Poke(); watcher.Error += (_, _) => watch.Poke();
        watcher.EnableRaisingEvents = true; watch.Watchers.Add(watcher);
      }
      catch (Exception ex) when (ex is IOException or ArgumentException or PlatformNotSupportedException or UnauthorizedAccessException) { }
    }
    lock (gate)
    {
      if (watches.TryGetValue(sessionId, out var raced)) { watch.Dispose(); raced.Count++; }
      else watches[sessionId] = watch;
    }
    return new Release(() => Unwatch(sessionId));
  }
  private void Unwatch(string sessionId)
  {
    FileWatch? ended = null;
    lock (gate) if (watches.TryGetValue(sessionId, out var watch) && --watch.Count <= 0) { watches.Remove(sessionId); ended = watch; }
    ended?.Dispose();
  }
  private void Settled(string sessionId, string? accountKey)
  {
    if (accountKey is not null) lock (gate) seededAt.Remove(accountKey);
    Changed?.Invoke(sessionId);
  }

  /// A chat reports usage with its turns, not in files: the chat service says when any chat changed.
  public void ChatsChanged()
  {
    string[] watched; lock (gate) watched = watches.Keys.ToArray();
    foreach (var id in watched) if (subject(id)?.Chat is not null) Changed?.Invoke(id);
  }

  /// Usage for an MCP caller (`usage.read`): the limits and, for one session, its context window.
  public object ToolView(string? sessionId)
  {
    var limits = Read(sessionId);
    var view = new Dictionary<string, object?> { ["limits"] = ReportView(limits) };
    if (sessionId is not null) { view["sessionId"] = sessionId; view["contextWindow"] = ContextView(Context(sessionId)); }
    return view;
  }
  public static object ReportView(UsageReport report) => new
  {
    sessionId = report.SessionId,
    account = report.Account is { } a ? new { provider = a.Provider, id = a.Id, name = a.Name } : null,
    readings = report.Readings.Select(r => new
    {
      id = r.Id, window = r.Window switch { UsageWindow.FiveHour => "five-hour", UsageWindow.Weekly => "weekly", UsageWindow.Monthly => "monthly", _ => "other" },
      windowMinutes = r.WindowMinutes, label = r.Label, usedPercent = r.Used is { } u ? Math.Round(u * 100, 1) : (double?)null,
      resetsAt = r.ResetAt is { } at ? DateTimeOffset.FromUnixTimeMilliseconds((long)at).ToString("O") : null, resets = r.ResetText,
      reportedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)r.ReportedAt).ToString("O"), source = r.Source,
      account = new { provider = r.Account.Provider, id = r.Account.Id, name = r.Account.Name }
    }).ToArray(),
    reason = report.Reason
  };
  public static object ContextView(ContextReading c) => new
  {
    provider = c.Provider, state = c.State, tokens = c.Tokens, window = c.Window, percent = c.Percent is { } p ? Math.Round(p, 1) : (double?)null,
    windowBasis = c.WindowBasis, model = c.Model, modelLabel = c.ModelLabel, conversation = c.SourceSessionId, inferred = c.Inferred, rivals = c.Rivals,
    reportedAt = c.ReportedAt > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)c.ReportedAt).ToString("O") : null, detail = c.Detail
  };

  public void Dispose()
  {
    FileWatch[] all;
    lock (gate) { disposed = true; all = watches.Values.ToArray(); watches.Clear(); }
    foreach (var watch in all) watch.Dispose();
  }

  private void Seed(UsageAccount account)
  {
    if (account.ApiKey || account.Home is null) return;
    var now = clock();
    lock (gate) if (seededAt.TryGetValue(account.Key, out var checkedAt) && now - checkedAt < 30_000) return;
    IReadOnlyList<UsageReading> found = account.Provider switch
    {
      "claude" => UsageSources.ClaudeCache(account, UsageSources.ClaudeJsonFiles(account.Home), now),
      "codex" => UsageSources.CodexRateLimits(account, now),
      _ => []
    };
    lock (gate) { Merge(found); seededAt[account.Key] = now; }
  }
  private void Capture(UsageAccount account, string screen, double now)
  {
    if (account.Home is null) return;
    if (UsageSources.Billing(screen) is { } seen) lock (gate) billing[account.Key] = seen;
    if (UsageSources.ParseScreen(screen) is not { } parsed) return;
    lock (gate) Merge(parsed.Limits.Select(l => l.Reading(account, now, now, parsed.Source == "warning" ? "claude-warning" : "claude-usage-panel")));
  }
  private void Merge(IEnumerable<UsageReading> readings)
  {
    foreach (var reading in readings) if (!pool.TryGetValue(reading.Id, out var held) || held.ReportedAt <= reading.ReportedAt) pool[reading.Id] = reading;
  }
  private static double Minutes(UsageReading r) => r.NominalMinutes ?? double.MaxValue;

  private sealed class FileWatch(UsageService owner, string sessionId, string? accountKey) : IDisposable
  {
    public readonly List<FileSystemWatcher> Watchers = [];
    public int Count = 1;
    private Timer? settle;
    private readonly object timerGate = new();
    public void Poke()
    {
      lock (timerGate)
      {
        settle ??= new Timer(_ => owner.Settled(sessionId, accountKey));
        settle.Change(750, Timeout.Infinite);
      }
    }
    public void Dispose()
    {
      foreach (var watcher in Watchers) { watcher.EnableRaisingEvents = false; watcher.Dispose(); }
      lock (timerGate) { settle?.Dispose(); settle = null; }
    }
  }
  private sealed class Release(Action release) : IDisposable
  {
    private int done;
    public void Dispose() { if (Interlocked.Exchange(ref done, 1) == 0) release(); }
  }
}
