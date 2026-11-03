using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.Core.Tests.Usage;

// Recorded payload shapes (30 Oct 2026, Claude Code 2.1.x and Codex 0.16x on the Mac), trimmed and with ids replaced.
public sealed class UsageMeterTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-usage-" + Guid.NewGuid().ToString("N"));
  private const double Now = 1_793_700_000_000; // 30 Oct 2026
  private static string Iso(double ms) => DateTimeOffset.FromUnixTimeMilliseconds((long)ms).ToString("O");
  public UsageMeterTests() => Directory.CreateDirectory(root);
  public void Dispose() { try { Directory.Delete(root, true); } catch (IOException) { } }
  private string Home(string name) { var path = Path.Combine(root, name); Directory.CreateDirectory(path); return path; }

  private static string ClaudeJson(double fetchedAt, string cachedUuid = "acct-1") => """
    {"oauthAccount":{"accountUuid":"acct-1","organizationType":"claude_max"},
     "cachedUsageUtilization":{"fetchedAtMs":FETCHED,"accountUuid":"CACHED","utilization":{
       "five_hour":{"utilization":10,"resets_at":"2026-10-30T19:10:00.442306+00:00","limit_dollars":null},
       "seven_day":{"utilization":3,"resets_at":"2026-11-06T10:00:00.442324+00:00"},
       "seven_day_oauth_apps":null,"seven_day_sonnet":null,
       "iguana_necktie":{"utilization":100,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":250}}}}
    """.Replace("FETCHED", fetchedAt.ToString(System.Globalization.CultureInfo.InvariantCulture)).Replace("CACHED", cachedUuid);
  private const string CodexRateLimitLine = """{"timestamp":"2026-10-30T01:49:16.289Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":77820698,"total_tokens":78074040},"last_token_usage":{"input_tokens":520121,"cached_input_tokens":519424,"output_tokens":328,"total_tokens":520449},"model_context_window":828400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1793776654},"secondary":{"used_percent":12.5,"window_minutes":300,"resets_at":1793710000},"plan_type":"pro"}}}""";
  private const string CodexEmptyLimitsLine = """{"timestamp":"2026-10-30T16:06:51.029Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false}}}}""";
  private const string CodexTotalOnlyLine = """{"timestamp":"2026-10-30T14:30:41.883Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":82542},"model_context_window":null},"rate_limits":null}}""";
  private const string ClaudeAssistantLine = """{"type":"assistant","isSidechain":false,"timestamp":"2026-10-30T16:47:43.053Z","sessionId":"conv-1","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1338,"cache_read_input_tokens":593577,"output_tokens":152,"cache_creation":{"ephemeral_1h_input_tokens":1338,"ephemeral_5m_input_tokens":0}}}}""";
  private const string ClaudeSidechainLine = """{"type":"assistant","isSidechain":true,"timestamp":"2026-10-30T16:48:00.000Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":900000}}}""";
  private const string ClaudeSyntheticLine = """{"type":"assistant","timestamp":"2026-10-30T16:49:00.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}""";

  [Fact] public void ClaudeCacheGivesTheSessionAndWeeklyWindowsOfThisLoginOnly()
  {
    var home = Home("claude"); var account = new UsageAccount("claude", "a1", "Work", home);
    File.WriteAllText(Path.Combine(home, ".claude.json"), ClaudeJson(Now - 60_000));
    var readings = UsageSources.ClaudeCache(account, UsageSources.ClaudeJsonFiles(home), Now);
    Assert.Equal(["Current session", "Current week (all models)"], readings.OrderBy(r => r.NominalMinutes).Select(r => r.Label));
    var session = readings.Single(r => r.Window == UsageWindow.FiveHour);
    Assert.Equal(0.10, session.Used!.Value, 3); Assert.Equal(DateTimeOffset.Parse("2026-10-30T19:10:00.442306+00:00").ToUnixTimeMilliseconds(), session.ResetAt);
    Assert.Equal("claude/a1/five-hour", session.Id);
    // Older than an hour, or written by another signed-in account: nothing rather than someone else's numbers.
    File.WriteAllText(Path.Combine(home, ".claude.json"), ClaudeJson(Now - 3_700_000));
    Assert.Empty(UsageSources.ClaudeCache(account, UsageSources.ClaudeJsonFiles(home), Now));
    File.WriteAllText(Path.Combine(home, ".claude.json"), ClaudeJson(Now - 60_000, "acct-2"));
    Assert.Empty(UsageSources.ClaudeCache(account, UsageSources.ClaudeJsonFiles(home), Now));
  }

  [Fact] public void UtilizationKeepsSonnetWeekOnlyForMaxOrTeamAndAddsScopedWeeks()
  {
    using var doc = JsonDocument.Parse("""{"five_hour":{"utilization":40},"seven_day_sonnet":{"utilization":20},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Opus"}},"percent":55,"resets_at":"2026-11-02T00:00:00Z"}]}""");
    Assert.DoesNotContain(UsageSources.Utilization(doc.RootElement, "pro"), l => l.Label.Contains("Sonnet"));
    var max = UsageSources.Utilization(doc.RootElement, "max");
    Assert.Contains(max, l => l.Id == "week:sonnet"); Assert.Contains(max, l => l.Id == "week:opus" && l.Percent == 55); Assert.Contains(max, l => l.Id == "session");
  }

  [Fact] public void CodexPlanLimitsComeFromTheNewestRolloutThatCarriesThemAndSkipEmptyOnes()
  {
    var home = Home("codex"); var day = Directory.CreateDirectory(Path.Combine(home, "sessions", "2026", "10", "30")).FullName;
    File.WriteAllLines(Path.Combine(day, "rollout-a.jsonl"), [CodexRateLimitLine, CodexEmptyLimitsLine]);
    var readings = UsageSources.CodexRateLimits(new("codex", "c1", "Codex work", home), Now).OrderBy(r => r.NominalMinutes).ToArray();
    Assert.Equal(["5-hour limit", "Weekly limit"], readings.Select(r => r.Label));
    Assert.Equal(1.0, readings[1].Used); Assert.Equal(1_793_776_654_000, readings[1].ResetAt); Assert.Equal(0.125, readings[0].Used);
    Assert.Equal(DateTimeOffset.Parse("2026-10-30T01:49:16.289Z").ToUnixTimeMilliseconds(), readings[0].ReportedAt);
  }

  [Fact] public void CodexContextReadsTheFolderRolloutAndAcceptsATotalOnlyTurn()
  {
    var home = Home("codex-ctx"); var cwd = Path.Combine(root, "project"); Directory.CreateDirectory(cwd);
    var day = Directory.CreateDirectory(Path.Combine(home, "sessions", "2026", "10", "30")).FullName;
    var meta = JsonSerializer.Serialize(new { timestamp = "2026-10-30T10:00:00Z", type = "session_meta", payload = new { id = "conv-x", cwd } });
    File.WriteAllLines(Path.Combine(day, "rollout-1.jsonl"), [meta, CodexRateLimitLine]);
    var reading = UsageSources.ReadContext("codex", home, cwd, "conv-x", m => m, Now);
    Assert.Equal(ContextReading.Ok, reading.State); Assert.Equal(520121, reading.Tokens); Assert.Equal(828400, reading.Window); Assert.Equal(62.8, reading.Percent!.Value, 1);
    Assert.Equal("reported", reading.WindowBasis); Assert.Equal("conv-x", reading.SourceSessionId);
    File.AppendAllLines(Path.Combine(day, "rollout-1.jsonl"), [CodexTotalOnlyLine]);
    var latest = UsageSources.ReadContext("codex", home, cwd, null, m => m, Now);
    Assert.Equal(82542, latest.Tokens); Assert.Null(latest.Percent); Assert.Null(latest.Share);
    // A folder Codex never worked in has nothing yet (never a number from another folder).
    Assert.Equal(ContextReading.NothingYet, UsageSources.ReadContext("codex", home, Path.Combine(root, "elsewhere"), null, m => m, Now).State);
  }

  [Fact] public void ClaudeContextIsTheLastMainReplyPromptOfThisSessionsTranscript()
  {
    var home = Home("claude-ctx"); var cwd = Path.Combine(root, "My Project");
    var folder = Directory.CreateDirectory(Path.Combine(home, "projects", UsageSources.ClaudeProjectFolder(cwd))).FullName;
    Assert.DoesNotContain(folder.Split(Path.DirectorySeparatorChar)[^1], c => !char.IsLetterOrDigit(c) && c != '-');
    File.WriteAllLines(Path.Combine(folder, "conv-1.jsonl"), [ClaudeAssistantLine, ClaudeSidechainLine, ClaudeSyntheticLine]);
    var reading = UsageSources.ReadContext("claude", home, cwd, "conv-1", m => m == "claude-opus-5-5" ? "Opus 5.5" : m, Now);
    Assert.Equal(594917, reading.Tokens); Assert.Equal(1_000_000, reading.Window); Assert.Equal("model", reading.WindowBasis); Assert.Equal("Opus 5.5", reading.ModelLabel);
    Assert.False(reading.Inferred);
    var panel = reading.Panel(DateTimeOffset.Parse("2026-10-30T16:48:00Z").ToUnixTimeMilliseconds())!;
    Assert.Equal("594.9k / 1M (59%)", panel.Headline); Assert.Equal(["Used", "Free"], panel.Segments.Select(s => s.Label)); Assert.Equal("Opus 5.5", panel.Facts[0].Value);
    Assert.Equal(ContextReading.NothingYet, UsageSources.ReadContext("claude", home, cwd, "conv-other", m => m, Now).State);
  }

  [Fact] public void ChatContextComesFromTheTurnUsageOfTheCurrentWorker()
  {
    var definition = new ChatDefinition(Guid.NewGuid().ToString(), "claude", root, "chat", new string('a', 32), new string('a', 32), new());
    JsonElement Data(object value) => JsonSerializer.SerializeToElement(value);
    var at = DateTimeOffset.FromUnixTimeMilliseconds((long)Now);
    var chat = new ChatRecord(1, definition, "worker-1", [
      new(1, "requestStarted", "m1", Data: Data(new { creationKey = "worker-1", model = "claude-sonnet-4-5-20250929", usage = new { input_tokens = 3, cache_read_input_tokens = 150_000, cache_creation_input_tokens = 5_000 } }), At: at),
      new(2, "requestUsage", "m1", Data: Data(new { creationKey = "worker-1", usage = new { output_tokens = 40 } }), At: at),
    ], [], ConversationId: "conv-chat");
    var reading = UsageSources.ChatContext(chat, m => "Sonnet 4.5", Now + 1000);
    Assert.Equal(155_003, reading.Tokens); Assert.Equal(200_000, reading.Window); Assert.True(reading.IsFresh(Now + 1000)); Assert.Equal("155k", reading.Figure(compact: true));
    Assert.Equal(UsageLevel.Warning, reading.Level);
    Assert.Equal(ContextReading.NothingYet, UsageSources.ChatContext(chat with { CreationKey = "worker-2" }, m => m, Now).State);
    var gemini = UsageSources.ChatContext(chat with { Definition = definition with { Provider = "gemini" } }, m => m, Now);
    Assert.Equal(ContextReading.NotReported, gemini.State); Assert.Null(gemini.Figure());
  }

  [Fact] public void ProbeConversationAsksInitializeThenGetUsageAndReadsTheAnswer()
  {
    var talk = new ClaudeUsageConversation();
    Assert.Contains("\"initialize\"", ClaudeUsageConversation.Initialize());
    Assert.Null(talk.Feed("""{"type":"system","subtype":"init"}"""));
    var ask = talk.Feed("""{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}""");
    Assert.Contains("\"get_usage\"", ask); Assert.False(talk.Finished);
    talk.Feed("""{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":64,"resets_at":"2026-10-30T19:10:00Z"},"seven_day":{"utilization":91,"resets_at":"2026-11-06T10:00:00Z"}}}}}""");
    Assert.True(talk.Finished);
    var outcome = ClaudeUsageConversation.Interpret(new("claude", "a1", "Work", root), talk.Usage, talk.Error, Now - 900, Now);
    Assert.Equal("ok", outcome.Kind); Assert.Equal(2, outcome.Readings.Count);
    var worst = UsageBarRules.Worst(outcome.Readings.Select(r => UsageReadout.Of(r, Now)))!;
    Assert.Equal("Current week (all models)", worst.Name); Assert.Equal(UsageLevel.Critical, worst.Level); Assert.Equal("91%", worst.Value);
    using var signedOut = JsonDocument.Parse("""{"rate_limits_available":false}""");
    Assert.Equal("signed-out", ClaudeUsageConversation.Interpret(new("claude", "a1", null, root), signedOut.RootElement, null, Now, Now).Kind);
    using var api = JsonDocument.Parse("""{"subscription_type":"api","rate_limits_available":false}""");
    Assert.Equal("no-limits", ClaudeUsageConversation.Interpret(new("claude", "a1", null, root), api.RootElement, null, Now, Now).Kind);
    Assert.Equal("unreadable", ClaudeUsageConversation.Interpret(new("claude", "a1", null, root), null, null, Now, Now).Kind);
  }

  private sealed class FakeProbe(Func<UsageAccount, UsageProbeOutcome> answer) : IUsageProbe
  {
    public int Runs;
    public TaskCompletionSource? Gate;
    public async ValueTask<UsageProbeOutcome> RunAsync(UsageAccount account, CancellationToken cancellationToken)
    { Interlocked.Increment(ref Runs); if (Gate is { } gate) await gate.Task; return answer(account); }
  }

  [Fact] public async Task RefreshAsksOncePerLoginRespectsTheFloorAndUsesFreshFigures()
  {
    var home = Home("svc"); var clock = Now; var account = new UsageAccount("claude", "a1", "Work", home);
    var reading = PlanLimit.Make("Current session", 30, "2026-10-30T19:10:00Z");
    var probe = new FakeProbe(a => new("ok", "read", [reading.Reading(a, clock, clock, "claude-usage-api", true)], true, 5)) { Gate = new() };
    using var usage = new UsageService(id => new UsageSubject(id, "claude", root, account), () => [account], probe, clock: () => clock, watchFiles: false);
    var changed = 0; usage.Changed += _ => changed++;
    var first = usage.RefreshAsync("s1", false).AsTask(); var second = usage.RefreshAsync("s2", false).AsTask();
    probe.Gate.SetResult(); await Task.WhenAll(first, second);
    Assert.Equal(1, probe.Runs); Assert.Equal("ok", (await first).Kind);
    Assert.Single(usage.Read("s1").Readings); Assert.Equal(2, changed);
    // Fresh within five minutes: answered from what is held, nothing started.
    clock += 60_000; Assert.Equal("cached", (await usage.RefreshAsync("s1", false)).Kind); Assert.Equal(1, probe.Runs);
    // "Check again" (force) goes past both.
    Assert.Equal("ok", (await usage.RefreshAsync("s1", true)).Kind); Assert.Equal(2, probe.Runs);
  }

  [Fact] public async Task NoLimitsIsRememberedAndTheFloorStopsRepeatAsks()
  {
    var home = Home("svc2"); var clock = Now; var account = new UsageAccount("claude", "a1", "Work", home);
    var kind = "unreadable"; var probe = new FakeProbe(_ => new(kind, "x", [], true, 1));
    using var usage = new UsageService(id => new UsageSubject(id, "claude", root, account), () => [account], probe, clock: () => clock, watchFiles: false);
    await usage.RefreshAsync("s", false);
    Assert.Equal(UsageService.RecentlyRead, (await usage.RefreshAsync("s", false)).Detail); Assert.Equal(1, probe.Runs);
    clock += 61_000; kind = "no-limits"; await usage.RefreshAsync("s", false);
    clock += 61_000; Assert.Equal("settled", (await usage.RefreshAsync("s", false)).Kind); Assert.Equal(2, probe.Runs);
    Assert.True(UsageBarRules.Settled("settled"));
  }

  [Fact] public async Task ApiServerGeminiAndUnknownSessionsShowNoFigures()
  {
    var probe = new FakeProbe(_ => throw new InvalidOperationException("must not be asked"));
    var subjects = new Dictionary<string, UsageSubject>
    {
      ["api"] = new("api", "claude", root, new("claude", "k", "Key", Home("api"), ApiKey: true)),
      ["server"] = new("server", "shell", root, null, OnServer: true),
      ["gemini"] = new("gemini", "gemini", root, new("gemini", "g", "G", Home("gem"))),
      ["shell"] = new("shell", "shell", root, null),
    };
    using var usage = new UsageService(id => subjects.GetValueOrDefault(id), () => [], probe, watchFiles: false);
    Assert.Equal(UsageService.ApiUsageNote, usage.Read("api").Reason); Assert.Equal("no-limits", (await usage.RefreshAsync("api", false)).Kind);
    Assert.Equal(UsageBarRules.ServerWithheld, usage.Read("server").Reason); Assert.Equal(ContextReading.NotReported, usage.Context("server").State);
    Assert.Empty(usage.Read("gemini").Readings); Assert.Equal(ContextReading.NotReported, usage.Context("gemini").State);
    Assert.Equal(ContextReading.NotReported, usage.Context("shell").State); Assert.Null(usage.Context("missing").Figure());
    Assert.Equal(0, probe.Runs);
  }

  [Fact] public void ReadoutsRenewAgeAndExpireLikeTheMac()
  {
    var account = new UsageAccount("claude", "a1", "Work", root);
    string Fixed(double at, double now) => "7:10 PM";
    var live = UsageReadout.Of(new("x", account, UsageWindow.FiveHour, null, "Current session", 0.64, Now + 3_600_000, null, Now, Now, "claude-usage-api"), Now, Fixed);
    Assert.Equal(("live", "64%", UsageLevel.Ok), (live.State, live.Value, live.Level)); Assert.Equal("Renews 7:10 PM · read just now", live.Facts);
    var aged = UsageReadout.Of(new("x", account, UsageWindow.FiveHour, null, "Current session", 0.75, Now + 3_600_000, null, Now - 30 * 60_000, Now - 30 * 60_000, "claude-usage-api"), Now, Fixed);
    Assert.Equal(("aged", UsageLevel.Warning), (aged.State, aged.Level));
    var expired = UsageReadout.Of(new("x", account, UsageWindow.Weekly, null, "Weekly limit", 0.5, Now - 1, null, Now - 1, Now - 1, "codex-rollout"), Now, Fixed);
    Assert.Equal(("expired", "Not reported", false), (expired.State, expired.Value, expired.Bar)); Assert.Null(UsageBarRules.Worst([expired]));
    Assert.Equal("<1%", UsageFormat.Percent(0.4)); Assert.Equal("1.25M", UsageFormat.Tokens(1_250_000)); Assert.Equal("12m ago", UsageFormat.Age(Now - 12 * 60_000, Now));
  }

  [Fact] public void HoverOpensPressPinsAndOpeningThePlanCardIsTheRefresh()
  {
    var shut = UsagePanelState.Shut; var hover = shut.Hover(UsagePanel.Plan);
    Assert.True(UsagePanelState.OpensPlan(shut, hover)); Assert.False(hover.Pinned); Assert.Equal(UsagePanelState.Shut, hover.Leave());
    var pinned = hover.Press(UsagePanel.Plan); Assert.True(pinned.Pinned); Assert.Equal(pinned, pinned.Leave()); Assert.Equal(pinned, pinned.Hover(UsagePanel.Context));
    Assert.Equal(UsagePanelState.Shut, pinned.Press(UsagePanel.Plan)); Assert.False(UsagePanelState.OpensPlan(hover, pinned));
  }

  [Fact] public void UsagePanelAndLimitWarningsOnClaudesScreenAreRead()
  {
    var panel = UsageSources.ParseScreen("\u001b[1mCurrent session\u001b[0m\n████▌ 42% used\nResets 7pm (Asia/Dubai)\n\nCurrent week (all models)\n█ 9% used\nResets Nov 6, 10am\n")!.Value;
    Assert.Equal("usage-panel", panel.Source); Assert.Equal([42.0, 9.0], panel.Limits.Select(l => l.Percent!.Value));
    Assert.Equal("7pm (Asia/Dubai)", panel.Limits[0].ResetsAt);
    var warning = UsageSources.ParseScreen("some output\nYou've used 91% of your weekly limit · resets Nov 6\n")!.Value;
    Assert.Equal(("warning", "week"), (warning.Source, warning.Limits[0].Scope));
    Assert.Equal("subscription", UsageSources.Billing("  Opus 5.5 with high effort · Claude Max"));
    Assert.Null(UsageSources.ParseScreen("plain output"));
  }

  [Fact] public async Task ACliFileChangeRaisesChangedForTheWatchedSessionAfterItSettles()
  {
    var home = Home("watch"); File.WriteAllText(Path.Combine(home, ".claude.json"), "{}");
    var account = new UsageAccount("claude", "a1", "Work", home);
    using var usage = new UsageService(id => new UsageSubject(id, "claude", root, account), () => [account]);
    var seen = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously); usage.Changed += id => seen.TrySetResult(id);
    using (usage.Watch("s1"))
    {
      await Task.Delay(300); File.WriteAllText(Path.Combine(home, ".claude.json"), ClaudeJson(UsageFormat.Now()));
      var done = await Task.WhenAny(seen.Task, Task.Delay(10_000));
      Assert.Same(seen.Task, done); Assert.Equal("s1", await seen.Task);
      Assert.Equal(2, usage.Read("s1").Readings.Count);
    }
  }

  [Fact] public void ToolViewCarriesLimitsAndContextWithoutUnknownWords()
  {
    var home = Home("tool"); File.WriteAllText(Path.Combine(home, ".claude.json"), ClaudeJson(UsageFormat.Now() - 1000));
    var account = new UsageAccount("claude", "a1", "Work", home);
    using var usage = new UsageService(id => new UsageSubject(id, "claude", root, account), () => [account], watchFiles: false);
    var json = JsonSerializer.Serialize(usage.ToolView("s1"));
    Assert.Contains("\"usedPercent\":10", json); Assert.Contains("\"contextWindow\"", json); Assert.DoesNotContain("Unknown", json, StringComparison.OrdinalIgnoreCase);
  }
}
