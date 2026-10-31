using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Usage;

// Where the figures come from (Mac: BackendUsageModels/Codex/Service, BackendCostTranscript):
// - Claude plan limits: Claude Code's own get_usage answer (the probe) and the cache it keeps in .claude.json.
// - Codex plan limits: the rate_limits Codex writes into its rollout files after each turn.
// - Context: the prompt size of the last reply in the session's own transcript (Claude) or the
//   token_count Codex records per turn; for chats, the usage the AI reports with each turn.
// Every read is bounded, read-only, never follows links and stays inside the account's own folder.

public sealed record PlanLimit(string Id, string Label, string Scope, double? Percent, string? ResetsAt)
{
  public static (string Id, string Scope) Identify(string label)
  {
    var lower = label.ToLowerInvariant();
    foreach (var model in new[] { "opus", "sonnet", "haiku", "fable", "mythos" })
      if (lower.Contains(model) && (lower.Contains("week") || lower.Contains("limit"))) return ("week:" + model, "week");
    if (lower.Contains("week")) return ("week", "week");
    if (lower.Contains("session") || lower.Contains("5-hour") || lower.Contains("five-hour")) return ("session", "session");
    if (lower.Contains("credit")) return ("other:usage-credit", "other");
    return ("other:" + Regex.Replace(lower, "[^a-z0-9]+", "-").Trim('-'), "other");
  }
  public static PlanLimit Make(string label, double? percent, string? resetsAt)
  {
    var identity = Identify(label);
    return new(identity.Id, label, identity.Scope, percent is >= 0 and <= 999 ? percent : null, resetsAt);
  }
  /// `apiReset`: the reset is an ISO instant (the usage API), not words copied off a screen.
  public UsageReading Reading(UsageAccount account, double observedAt, double reportedAt, string source, bool apiReset = false)
  {
    var window = Scope == "session" ? UsageWindow.FiveHour : Scope == "week" ? UsageWindow.Weekly : UsageWindow.Other;
    var colon = Id.IndexOf(':'); var qualifier = colon >= 0 ? Id[(colon + 1)..] : null;
    var windowName = window switch { UsageWindow.FiveHour => "five-hour", UsageWindow.Weekly => "weekly", _ => "other" };
    double? at = null; string? text = ResetsAt;
    if (apiReset) { text = null; var epoch = UsageSources.Timestamp(ResetsAt); at = epoch > 0 ? epoch : null; }
    return new(account.Key + "/" + windowName + (qualifier is null ? "" : ":" + qualifier), account, window, null, Label,
      Percent is { } p ? p / 100 : null, at, text, observedAt, reportedAt, source);
  }
}

public static class UsageSources
{
  public const long CodexHeadBytes = 32_768;
  private static readonly int[] ContextSteps = [256 * 1024, 1024 * 1024, 8 * 1024 * 1024];
  public const double RivalWindowMs = 10 * 60 * 1000;

  // ---- Plan limits ---------------------------------------------------------------------------

  /// The usage API's `rate_limits` / `.claude.json` `cachedUsageUtilization.utilization` object.
  public static IReadOnlyList<PlanLimit> Utilization(JsonElement raw, string? subscription)
  {
    if (raw.ValueKind != JsonValueKind.Object) return [];
    var rows = new List<PlanLimit>();
    foreach (var (key, title) in new[] { ("five_hour", "Current session"), ("seven_day", "Current week (all models)"), ("seven_day_sonnet", "Current week (Sonnet only)") })
    {
      if (key == "seven_day_sonnet" && subscription is not null && subscription is not ("max" or "team")) continue;
      var window = P(raw, key); if (Num(P(window, "utilization")) is not { } percent) continue;
      rows.Add(PlanLimit.Make(title, percent, Str(P(window, "resets_at"))));
    }
    if (P(raw, "limits") is { ValueKind: JsonValueKind.Array } limits)
      foreach (var row in limits.EnumerateArray())
      {
        if (Str(P(row, "kind")) != "weekly_scoped") continue;
        if (Str(P(P(P(row, "scope"), "model"), "display_name")) is not { Length: > 0 } model || Num(P(row, "percent")) is not { } percent) continue;
        rows.Add(PlanLimit.Make("Current week (" + model + ")", percent, Str(P(row, "resets_at"))));
      }
    var unique = new Dictionary<string, PlanLimit>(); foreach (var row in rows) unique[row.Id] = row;
    return unique.Values.OrderBy(r => r.Id, StringComparer.Ordinal).ToArray();
  }

  /// Claude Code's own screen: the /usage panel ("Current session … 42% used … Resets 3pm") or a limit warning.
  public static (IReadOnlyList<PlanLimit> Limits, string Source)? ParseScreen(string screen)
  {
    var clean = Regex.Replace(screen, "\u001B\\[[0-?]*[ -/]*[@-~]", "");
    var lines = clean.Replace("\r", "\n").Split('\n').Select(l => l.Trim()).ToArray();
    var heading = new Regex(@"^Current\s+(session|week)\b(?:\s*\(([^)]*)\))?\s*$", RegexOptions.IgnoreCase);
    var limits = new List<PlanLimit>(); var seen = new HashSet<string>();
    for (var index = 0; index < lines.Length; index++)
    {
      var found = heading.Match(lines[index]); if (!found.Success) continue;
      var qualifier = found.Groups[2].Value; var label = "Current " + found.Groups[1].Value + (qualifier.Length == 0 ? "" : " (" + qualifier + ")");
      double? percent = null; string? reset = null; var cursor = index;
      for (var next = index + 1; next < Math.Min(lines.Length, index + 5); next++)
      {
        if (heading.IsMatch(lines[next])) break;
        var m = Regex.Match(lines[next], @"(\d{1,3})%\s+used\b", RegexOptions.IgnoreCase);
        if (m.Success) { percent = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture); cursor = next; break; }
      }
      if (percent is null) continue;
      for (var next = cursor + 1; next < Math.Min(lines.Length, cursor + 5); next++)
      {
        if (heading.IsMatch(lines[next])) break;
        var m = Regex.Match(lines[next], @"^Resets\b\s*(.*)$", RegexOptions.IgnoreCase);
        if (m.Success) { reset = m.Groups[1].Value; break; }
      }
      var row = PlanLimit.Make(label, percent, reset); if (seen.Add(row.Id)) limits.Add(row);
    }
    if (limits.Count > 0) return (limits, "usage-panel");
    static bool Valid(string label) => Regex.IsMatch(label, @"\blimits?\b", RegexOptions.IgnoreCase) && Regex.IsMatch(label, @"\b(session|weekly|week|5-hour|five-hour|opus|sonnet|haiku|fable|mythos|credits?)\b", RegexOptions.IgnoreCase);
    foreach (var line in lines.Reverse())
    {
      var used = Regex.Match(line, @"you['’]ve used\s+(\d{1,3})%\s+of your\s+(.+)$", RegexOptions.IgnoreCase);
      if (used.Success)
      {
        var rest = used.Groups[2].Value; var cut = Regex.Match(rest, @"\bresets\b", RegexOptions.IgnoreCase);
        var label = (cut.Success ? rest[..cut.Index] : rest.Split('·')[0]).Trim(' ', '·', ',', ';', ':', '-');
        if (Valid(label)) return ([PlanLimit.Make(label, double.Parse(used.Groups[1].Value, CultureInfo.InvariantCulture), cut.Success ? rest[(cut.Index + cut.Length)..].Trim() : null)], "warning");
      }
      foreach (var pattern in new[] { @"^\W*your\s+(.+?)\s+resets\s+(.+)$", @"(?:approaching|you['’]re close to your|you['’]ve hit your)\s+(.+)$" })
      {
        var m = Regex.Match(line, pattern, RegexOptions.IgnoreCase);
        if (m.Success && Valid(m.Groups[1].Value)) return ([PlanLimit.Make(m.Groups[1].Value, null, m.Groups.Count > 2 && m.Groups[2].Success ? m.Groups[2].Value : null)], "warning");
      }
    }
    return null;
  }

  /// "subscription" / "api" from Claude Code's banner ("… with Opus 5.5 · Claude Max"), else null.
  public static string? Billing(string screen)
  {
    foreach (var line in screen.Split('\n'))
    {
      var m = Regex.Match(line, @"\bwith\s+\S+(?:\s+effort)?\s*·\s*([^·│]+?)\s*(?:·|│|$)"); if (!m.Success) continue;
      var label = m.Groups[1].Value.Trim();
      if (Regex.IsMatch(label, "^Claude (Max|Pro|Team|Enterprise)$")) return "subscription";
      if (label is "Claude API" or "API Usage Billing" or "Bedrock" or "Bedrock Mantle" or "Vertex AI" or "Gateway" or "Foundry") return "api";
    }
    return null;
  }

  /// The usage cache Claude Code keeps in its `.claude.json` (at most an hour old, same signed-in account).
  public static IReadOnlyList<UsageReading> ClaudeCache(UsageAccount account, IEnumerable<string> files, double now)
  {
    var best = (Readings: (IReadOnlyList<UsageReading>)[], FetchedAt: 0.0);
    foreach (var file in files)
    {
      var data = BoundedRead(file, account.Home, 4 * 1024 * 1024); if (data is null) continue;
      try
      {
        using var json = JsonDocument.Parse(data); var raw = json.RootElement; var cache = P(raw, "cachedUsageUtilization");
        if (Num(P(cache, "fetchedAtMs")) is not { } fetchedAt || now - fetchedAt > 3_600_000 || fetchedAt <= best.FetchedAt) continue;
        if (Str(P(P(raw, "oauthAccount"), "accountUuid")) is { } original && Str(P(cache, "accountUuid")) is { } cached && original != cached) continue;
        var organization = Str(P(P(raw, "oauthAccount"), "organizationType")) is { } o ? Regex.Replace(o, "^claude_", "") : null;
        best = (Utilization(P(cache, "utilization"), organization).Select(l => l.Reading(account, now, fetchedAt, "claude-usage-api", apiReset: true)).ToArray(), fetchedAt);
      }
      catch (JsonException) { }
    }
    return best.Readings;
  }
  /// Where Claude Code keeps `.claude.json` for this login: inside its config folder; the computer's
  /// own login (`%USERPROFILE%\.claude`) may also keep it beside that folder.
  public static IEnumerable<string> ClaudeJsonFiles(string home)
  {
    yield return Path.Combine(home, ".claude.json");
    if (string.Equals(Path.GetFileName(Path.TrimEndingDirectorySeparator(home)), ".claude", StringComparison.OrdinalIgnoreCase) && Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(home)) is { } parent)
      yield return Path.Combine(parent, ".claude.json");
  }

  /// The newest rollouts (last five day folders, plus archived) under a Codex home.
  public static IReadOnlyList<(string Path, double Modified)> CodexRollouts(string home)
  {
    var found = new List<(string, double)>(); var days = 0;
    IEnumerable<DirectoryInfo> Dirs(string path, string pattern) => SafeDirs(path).Where(d => Regex.IsMatch(d.Name, pattern)).OrderByDescending(d => d.Name, StringComparer.Ordinal);
    foreach (var year in Dirs(Path.Combine(home, "sessions"), @"^\d{4}$"))
    {
      foreach (var month in Dirs(year.FullName, @"^\d{2}$"))
      {
        foreach (var day in Dirs(month.FullName, @"^\d{2}$"))
        { if (days++ >= 5) break; found.AddRange(SafeFiles(day.FullName, "*.jsonl")); }
        if (days >= 5) break;
      }
      if (days >= 5) break;
    }
    found.AddRange(SafeFiles(Path.Combine(home, "archived_sessions"), "*.jsonl"));
    return found.OrderByDescending(f => f.Item2).Take(8).ToArray();
  }

  /// Codex's plan windows from the newest `rate_limits` it wrote into a rollout.
  public static IReadOnlyList<UsageReading> CodexRateLimits(UsageAccount account, double now)
  {
    if (account.Home is not { } home) return [];
    (JsonElement Raw, double At)? best = null; var examined = 0;
    foreach (var file in CodexRollouts(home))
    {
      examined++;
      foreach (var limit in new[] { 256 * 1024, 4 * 1024 * 1024 })
      {
        if (Tail(file.Path, home, limit) is not { } tail) break;
        var found = false;
        foreach (var line in tail.Text.Split('\n').Reverse())
        {
          if (!line.Contains("\"rate_limits\"")) continue;
          if (Parse(line) is not { } row) continue;
          var windows = P(P(row, "payload"), "rate_limits");
          if (windows.ValueKind != JsonValueKind.Object || !new[] { "primary", "secondary" }.Any(k => Num(P(P(windows, k), "used_percent")) is not null)) continue;
          var stamped = Timestamp(Str(P(row, "timestamp"))); var at = stamped > 0 ? stamped : tail.Modified;
          if (best is null || best.Value.At < at) best = (windows.Clone(), at);
          found = true; break;
        }
        if (found) break;
      }
      if (best is not null && examined >= 3) break;
    }
    if (best is not { } chosen) return [];
    var result = new List<UsageReading>(); var seen = new HashSet<double>();
    foreach (var key in new[] { "primary", "secondary" })
    {
      var window = P(chosen.Raw, key); if (Num(P(window, "used_percent")) is not { } percent) continue;
      var minutes = Num(P(window, "window_minutes")) is { } m && m > 0 && m <= 1_000_000 ? m : (double?)null;
      if (minutes is { } mm && !seen.Add(mm)) continue;
      var kind = UsageReading.WindowOf(minutes);
      var label = kind switch
      {
        UsageWindow.FiveHour => "5-hour limit", UsageWindow.Weekly => "Weekly limit", UsageWindow.Monthly => "30-day limit",
        _ => minutes is { } x ? (x % 1440 == 0 ? (int)(x / 1440) + "-day limit" : x % 60 == 0 ? (int)(x / 60) + "-hour limit" : (int)x + "-minute limit") : "Usage limit"
      };
      var windowName = kind switch { UsageWindow.FiveHour => "five-hour", UsageWindow.Weekly => "weekly", UsageWindow.Monthly => "monthly", _ => "other" };
      var resets = Num(P(window, "resets_at")) is { } r && r > 0 ? Math.Round(r < 1_000_000_000_000 ? r * 1000 : r) : (double?)null;
      result.Add(new(account.Key + "/" + windowName + (kind == UsageWindow.Other && minutes is { } q ? ":" + q.ToString(CultureInfo.InvariantCulture) : ""), account, kind, minutes, label,
        percent is >= 0 and <= 999 ? percent / 100 : null, resets, null, now, chosen.At, "codex-rollout"));
    }
    return result;
  }

  // ---- Context window ------------------------------------------------------------------------

  public static string NormalizeModel(string model)
  {
    var result = model.Trim().ToLowerInvariant();
    foreach (var pattern in new[] { @"^(us|eu|apac|global)\.", @"^anthropic\.", @"\[1m\]", @"@\d{8}$", @"-v\d+:\d+$", @"-\d{8}$" }) result = Regex.Replace(result, pattern, "");
    return result;
  }
  /// The model's context window as this app's table knows it.
  public static double ContextWindow(string model)
  {
    var normalized = Regex.Replace(NormalizeModel(model), "-fast$", "");
    var large = new[] { "claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6" };
    return large.Any(normalized.StartsWith) ? 1_000_000 : 200_000;
  }
  /// A transcript that already held more than the table allows proves the larger window.
  public static double EffectiveWindow(string model, double observed)
  {
    var baseWindow = ContextWindow(model); if (observed <= baseWindow) return baseWindow;
    return new[] { 200_000.0, 1_000_000.0 }.FirstOrDefault(w => w >= observed && w >= baseWindow) is var w && w > 0 ? w : observed;
  }
  /// The prompt a Claude turn put in the context: fresh input + cache writes + cache reads.
  public static double ClaudePrompt(JsonElement usage)
  {
    double Count(JsonElement value) => Num(value) is { } n ? Math.Min(1e12, Math.Max(0, Math.Floor(n))) : 0;
    var write5 = Count(P(P(usage, "cache_creation"), "ephemeral_5m_input_tokens")); var write1h = Count(P(P(usage, "cache_creation"), "ephemeral_1h_input_tokens"));
    write5 += Math.Max(0, Count(P(usage, "cache_creation_input_tokens")) - write5 - write1h);
    return Count(P(usage, "input_tokens")) + write5 + write1h + Count(P(usage, "cache_read_input_tokens"));
  }
  /// Claude Code's folder name for a project: every character that is not a letter or digit becomes "-".
  public static string ClaudeProjectFolder(string cwd) => Regex.Replace(Path.TrimEndingDirectorySeparator(cwd), "[^a-zA-Z0-9]", "-");

  public static IReadOnlyList<(string Path, string Id, double Modified)> ClaudeTranscripts(string home, string cwd, string? conversationId)
  {
    var projects = Path.Combine(home, "projects"); var name = ClaudeProjectFolder(cwd);
    var folder = Path.Combine(projects, name);
    if (!Directory.Exists(folder) && name.Length > 200)
      folder = SafeDirs(projects).FirstOrDefault(d => d.Name.StartsWith(name[..200], StringComparison.Ordinal))?.FullName ?? folder;
    var files = SafeFiles(folder, "*.jsonl").Select(f => (f.Path, Id: Path.GetFileNameWithoutExtension(f.Path), f.Modified));
    if (conversationId is not null) files = files.Where(f => string.Equals(f.Id, conversationId, StringComparison.OrdinalIgnoreCase));
    return files.OrderByDescending(f => f.Modified).Take(64).ToArray();
  }

  public static IReadOnlyList<(string Path, string Id, double Modified)> CodexProjectRollouts(string home, string cwd, string? conversationId, int byteBudget = 16 * 1024 * 1024)
  {
    var files = new List<(string Path, double Modified)>();
    foreach (var sub in new[] { "sessions", "archived_sessions" })
    {
      var root = Path.Combine(home, sub); if (!Directory.Exists(root) || IsLink(root)) continue;
      var options = new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 4, AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = true };
      foreach (var path in Directory.EnumerateFiles(root, "*.jsonl", options).Take(100_000)) files.Add((path, Modified(path)));
    }
    var wanted = conversationId is null ? 8 : 1; var bytes = 0; var result = new List<(string, string, double)>();
    foreach (var file in files.OrderByDescending(f => f.Modified))
    {
      if (result.Count >= wanted || bytes >= byteBudget) break;
      var head = Head(file.Path, home, (int)CodexHeadBytes); if (head is null) continue; bytes += head.Length;
      var first = head.Split('\n')[0];
      if (Parse(first) is not { } meta || Str(P(meta, "type")) != "session_meta") continue;
      var payload = P(meta, "payload");
      if (Str(P(payload, "cwd")) is not { } recorded || !SamePath(recorded, cwd)) continue;
      var id = Str(P(payload, "id"));
      if (conversationId is not null && !string.Equals(id, conversationId, StringComparison.OrdinalIgnoreCase)) continue;
      result.Add((file.Path, id ?? Path.GetFileNameWithoutExtension(file.Path), file.Modified));
    }
    return result;
  }

  /// One Codex rollout line: a `token_count` event's last input tokens, the window it reported and when.
  public static (double Tokens, double? Window, double At)? CodexContextLine(string line, double fallbackAt)
  {
    if (!line.Contains("\"token_count\"") || Parse(line) is not { } raw || Str(P(P(raw, "payload"), "type")) != "token_count") return null;
    var info = P(P(raw, "payload"), "info");
    // Newer Codex builds sometimes write a turn's size only as total_tokens (input 0); that total is the context then.
    var last = P(info, "last_token_usage");
    var tokens = Num(P(last, "input_tokens")) is { } input && input > 0 ? input : Num(P(last, "total_tokens")) is { } total && total > 0 ? total : (double?)null;
    if (tokens is not { } count) return null;
    var stamp = Timestamp(Str(P(raw, "timestamp")));
    return (count, Num(P(info, "model_context_window")), stamp > 0 ? stamp : fallbackAt);
  }
  /// One Claude transcript line: the prompt its reply was given. Sub-agents, interrupts and lines with no usage are not it.
  public static (double Tokens, string Model, double At)? ClaudePromptLine(string line)
  {
    if (!line.Contains("usage") || Parse(line) is not { } raw || Str(P(raw, "type")) != "assistant" || P(raw, "isSidechain").ValueKind == JsonValueKind.True) return null;
    var message = P(raw, "message");
    if (P(message, "usage").ValueKind != JsonValueKind.Object || Str(P(message, "model")) is not { } model) return null;
    var id = NormalizeModel(model); if (id.Length == 0 || id == "<synthetic>") return null;
    return (ClaudePrompt(P(message, "usage")), model, Timestamp(Str(P(raw, "timestamp"))));
  }

  /// The context reading from a terminal session's own transcript (Mac `contextReading`).
  public static ContextReading ReadContext(string provider, string home, string cwd, string? conversationId, Func<string, string> modelLabel, double now)
  {
    ContextReading Blank(string state, string detail) => ContextReading.Blank(provider, state, detail, now);
    if (provider == "codex")
    {
      var rollouts = CodexProjectRollouts(home, cwd, conversationId);
      foreach (var candidate in rollouts)
      {
        (double Tokens, double? Window, double At)? found = null;
        var size = Size(candidate.Path);
        foreach (var amount in ContextSteps)
        {
          if (Tail(candidate.Path, home, amount) is not { } tail) break;
          foreach (var line in tail.Text.Split('\n').Reverse()) if (CodexContextLine(line, tail.Modified) is { } parsed) { found = parsed; break; }
          if (found is not null || Math.Min(amount, size) >= size) break;
        }
        if (found is not { } f) continue;
        var rivals = conversationId is null ? rollouts.Count(r => r.Path != candidate.Path && Math.Abs(r.Modified - candidate.Modified) <= RivalWindowMs) : 0;
        var percent = f.Window is > 0 ? f.Tokens / f.Window * 100 : null;
        var detail = f.Window is { } window && percent is { } p
          ? UsageFormat.Grouped(f.Tokens) + " of " + UsageFormat.Grouped(window) + " tokens — " + (int)Math.Round(p) + "% of the context window Codex reports for this model."
          : UsageFormat.Grouped(f.Tokens) + " tokens in context. Codex did not record how large its window is on this turn, so there is no share to show.";
        if (rivals > 0) detail += " Read from the most recent rollout Codex filed for this folder, and " + (rivals == 1 ? "one other Codex conversation" : rivals + " other Codex conversations") + " here " + (rivals == 1 ? "was" : "were") + " active at the same time — if you have more than one session here this may be the other one's.";
        return new("codex", ContextReading.Ok, f.Tokens, f.Window, percent, f.Window is null ? null : "reported", null, null, candidate.Id, rivals > 0, rivals, f.At, now, detail);
      }
      return Blank(ContextReading.NothingYet, "Codex has not completed a turn in this folder yet. It records the size of its context at the end of each turn, so the figure appears after the first reply.");
    }
    var candidates = ClaudeTranscripts(home, cwd, conversationId); var named = conversationId is not null;
    var liveAfter = (candidates.FirstOrDefault().Modified) - RivalWindowMs; var budget = 16 * 1024 * 1024;
    ((string Path, string Id, double Modified) Candidate, (double Tokens, string Model, double At) Latest, double High)? best = null;
    foreach (var candidate in candidates)
    {
      if (budget <= 0 || best is not null && candidate.Modified < liveAfter) break;
      var size = Size(candidate.Path);
      foreach (var amount in ContextSteps)
      {
        if (Tail(candidate.Path, home, amount) is not { } tail) break;
        budget -= tail.Text.Length;
        var prompts = tail.Text.Split('\n').Select(ClaudePromptLine).OfType<(double Tokens, string Model, double At)>().ToArray();
        if (prompts.Length > 0)
        {
          var latest = prompts[^1];
          if (best is null || latest.At > best.Value.Latest.At) best = (candidate, latest, prompts.Max(p => p.Tokens));
          break;
        }
        if (Math.Min(amount, size) >= size) break;
      }
    }
    if (best is not { } b)
      return Blank(ContextReading.NothingYet, named
        ? "This session has not written a reply yet. The figure is read from its own transcript, so it says nothing about any other session open in this folder."
        : "Claude Code has not written a reply in this folder yet. The figure appears as soon as it answers once — it comes from the transcript it writes as it goes, not from anything this app has to ask for.");
    var table = ContextWindow(b.Latest.Model); var windowSize = EffectiveWindow(b.Latest.Model, b.High);
    var others = named ? 0 : candidates.Count(c => c.Path != b.Candidate.Path && Math.Abs(c.Modified - b.Candidate.Modified) <= RivalWindowMs);
    var head = UsageFormat.Grouped(b.Latest.Tokens) + " of " + UsageFormat.Grouped(windowSize) + " tokens — " + (int)Math.Round(b.Latest.Tokens / windowSize * 100) + "% of the context window";
    var text = named || others == 0 ? head + "." : head + ". Read from the most recently updated transcript in this folder, and " + (others == 1 ? "one other conversation" : others + " other conversations") + " here " + (others == 1 ? "was" : "were") + " active at the same time — if you have more than one session open here, this may be the other one's.";
    return new(provider, ContextReading.Ok, b.Latest.Tokens, windowSize, b.Latest.Tokens / windowSize * 100, windowSize > table ? "observed" : "model",
      b.Latest.Model, modelLabel(b.Latest.Model), b.Candidate.Id, !named, others, b.Latest.At > 0 ? b.Latest.At : b.Candidate.Modified, now, text);
  }

  /// A chat's context from the usage its AI reported with each turn (no files read).
  public static ContextReading ChatContext(ChatRecord chat, Func<string, string> modelLabel, double now)
  {
    var provider = chat.Definition.Provider;
    if (provider == "codex")
    {
      var reading = Chats.ChatContext.Read(chat);
      var last = chat.Events.LastOrDefault(e => e.Kind == "usage" && e.Data is { } d && ChatLineProtocol.S(d, "creationKey") == chat.CreationKey);
      if (reading.Tokens is not { } tokens || last is null) return ContextReading.Blank(provider, ContextReading.NothingYet, "Codex has not finished a turn in this chat yet. It reports the size of its context at the end of each turn.", now);
      double? window = reading.Window; var percent = window is > 0 ? tokens / window * 100 : null;
      return new(provider, ContextReading.Ok, tokens, window, percent, window is null ? null : "reported", null, null, chat.ConversationId, false, 0, Ms(last.At), now,
        window is { } w ? UsageFormat.Grouped(tokens) + " of " + UsageFormat.Grouped(w) + " tokens — " + (int)Math.Round(percent ?? 0) + "% of the context window Codex reports for this model." : UsageFormat.Grouped(tokens) + " tokens in context.");
    }
    if (provider != "claude") return ContextReading.Blank(provider, ContextReading.NotReported, provider == "gemini" ? GeminiNote : "This agent does not report how full its context window is.", now);
    (double Tokens, string Model, ChatEvent Event)? latest = null; double high = 0; string? model = null;
    foreach (var entry in chat.Events)
    {
      if (entry.Kind is not ("requestStarted" or "requestUsage") || entry.Data is not { } data || ChatLineProtocol.S(data, "creationKey") != chat.CreationKey) continue;
      if (ChatLineProtocol.S(data, "model") is { Length: > 0 } named) model = named;
      var usage = ChatLineProtocol.P(data, "usage");
      if (usage.ValueKind != JsonValueKind.Object || !usage.TryGetProperty("input_tokens", out _) || model is null || NormalizeModel(model) == "<synthetic>") continue;
      var prompt = ClaudePrompt(usage); if (prompt <= 0) continue;
      latest = (prompt, model, entry); high = Math.Max(high, prompt);
    }
    if (latest is not { } l) return ContextReading.Blank(provider, ContextReading.NothingYet, "Claude has not answered in this chat yet. The figure appears with its first reply.", now);
    var table = ContextWindow(l.Model); var size = EffectiveWindow(l.Model, high);
    return new(provider, ContextReading.Ok, l.Tokens, size, l.Tokens / size * 100, size > table ? "observed" : "model", l.Model, modelLabel(l.Model), chat.ConversationId, false, 0, Ms(l.Event.At), now,
      UsageFormat.Grouped(l.Tokens) + " of " + UsageFormat.Grouped(size) + " tokens — " + (int)Math.Round(l.Tokens / size * 100) + "% of the context window.");
  }
  public const string GeminiNote = "Gemini does not record how full its context window is. Its session files hold the conversation and no token counts at all, so there is nothing here to read.";

  // ---- Bounded file reads ----------------------------------------------------------------------

  public static (string Text, double Modified)? Tail(string path, string? root, int bytes)
  {
    try
    {
      if (!Inside(path, root) || IsLink(path)) return null;
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      var count = (int)Math.Min(stream.Length, bytes); var offset = stream.Length - count; stream.Seek(offset, SeekOrigin.Begin);
      var buffer = new byte[count]; var read = 0; while (read < count) { var n = stream.Read(buffer, read, count - read); if (n == 0) break; read += n; }
      var start = 0;
      if (offset > 0) { var cut = Array.IndexOf(buffer, (byte)10, 0, read); start = cut < 0 ? read : cut + 1; }
      return (Encoding.UTF8.GetString(buffer, start, read - start), Modified(path));
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private static string? Head(string path, string root, int bytes)
  {
    try
    {
      if (!Inside(path, root) || IsLink(path)) return null;
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      var buffer = new byte[Math.Min(bytes, (int)Math.Min(int.MaxValue, stream.Length))]; var read = stream.Read(buffer, 0, buffer.Length);
      return Encoding.UTF8.GetString(buffer, 0, read);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private static byte[]? BoundedRead(string path, string? root, int maximum)
  {
    try
    {
      // The computer's own login keeps .claude.json beside its folder, so the account root is its parent there.
      var allowed = root is null ? null : Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(root));
      if (!File.Exists(path) || !Inside(path, allowed ?? root) || IsLink(path) || new FileInfo(path).Length > maximum) return null;
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      var buffer = new byte[stream.Length]; var read = 0; while (read < buffer.Length) { var n = stream.Read(buffer, read, buffer.Length - read); if (n == 0) break; read += n; }
      return buffer[..read];
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private static long Size(string path) { try { return new FileInfo(path).Length; } catch (IOException) { return 0; } }
  private static double Modified(string path) { try { return new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds(); } catch (IOException) { return 0; } }
  private static bool IsLink(string path) { try { return File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint); } catch (IOException) { return true; } catch (UnauthorizedAccessException) { return true; } }
  private static bool Inside(string path, string? root)
  {
    if (root is null) return false;
    var full = Path.GetFullPath(path); var baseDir = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
    return full.StartsWith(baseDir, StringComparison.OrdinalIgnoreCase);
  }
  public static bool SamePath(string a, string b)
  {
    try { return string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase); }
    catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return false; }
  }
  private static IEnumerable<DirectoryInfo> SafeDirs(string path)
  {
    try { return Directory.Exists(path) && !IsLink(path) ? new DirectoryInfo(path).EnumerateDirectories().Where(d => !d.Attributes.HasFlag(FileAttributes.ReparsePoint)).Take(10_000).ToArray() : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
  }
  private static IEnumerable<(string Path, double Modified)> SafeFiles(string path, string pattern)
  {
    try { return Directory.Exists(path) && !IsLink(path) ? new DirectoryInfo(path).EnumerateFiles(pattern).Where(f => !f.Attributes.HasFlag(FileAttributes.ReparsePoint)).Take(10_000).Select(f => (f.FullName, (double)new DateTimeOffset(f.LastWriteTimeUtc).ToUnixTimeMilliseconds())).ToArray() : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
  }

  // ---- JSON helpers --------------------------------------------------------------------------

  internal static JsonElement? Parse(string line)
  {
    if (line.Length == 0 || line.Length > 8 * 1024 * 1024) return null;
    try { using var doc = JsonDocument.Parse(line); return doc.RootElement.Clone(); } catch (JsonException) { return null; }
  }
  internal static JsonElement P(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var child) ? child : default;
  internal static string? Str(JsonElement value) => value.ValueKind == JsonValueKind.String ? value.GetString() : null;
  internal static double? Num(JsonElement value) => value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var n) && double.IsFinite(n) ? n : null;
  public static double Timestamp(string? text) => text is not null && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at) ? at.ToUnixTimeMilliseconds() : 0;
  private static double Ms(DateTimeOffset at) => at == default ? 0 : at.ToUnixTimeMilliseconds();
}
