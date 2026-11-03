using System.Globalization;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Usage;

// The usage reading on a session's header (Mac: UsageBarModel.swift, BackendUsageModels.swift):
// the context window as a strip, and the account's plan limits behind a ring. Each opens a
// card on hover and holds it on a press. Times are Unix milliseconds, as on the Mac.

public enum UsageLevel { Ok, Warning, Critical }
public enum UsageWindow { FiveHour, Weekly, Monthly, Other }

/// Whose limits these are: the session's own login (provider + app account + its data folder).
public sealed record UsageAccount(string Provider, string? Id, string? Name, string? Home, bool ApiKey = false)
{
  public string Key => Provider + "/" + (Id ?? Home ?? "system");
}

/// One plan window (5-hour, weekly, a per-model week...). Used is a fraction (0.42 = 42%), null when not reported.
public sealed record UsageReading(string Id, UsageAccount Account, UsageWindow Window, double? WindowMinutes, string Label,
  double? Used, double? ResetAt, string? ResetText, double ObservedAt, double ReportedAt, string Source)
{
  public double? NominalMinutes => WindowMinutes ?? Window switch { UsageWindow.FiveHour => 300, UsageWindow.Weekly => 10_080, UsageWindow.Monthly => 43_200, _ => null };
  public static UsageWindow WindowOf(double? minutes) => minutes switch { 300 => UsageWindow.FiveHour, 10_080 => UsageWindow.Weekly, 43_200 => UsageWindow.Monthly, _ => UsageWindow.Other };

  /// `shortWindowName`.
  public string Short => Window switch
  {
    UsageWindow.FiveHour => "5h", UsageWindow.Weekly => "Week", UsageWindow.Monthly => "30d",
    _ => WindowMinutes is > 0 and var m ? ((int)m % 1440 == 0 ? (int)m / 1440 + "d" : (int)m % 60 == 0 ? (int)m / 60 + "h" : (int)m + "m") : Label.Length == 0 ? "Limit" : Label
  };
}

public sealed record UsageReport(string? SessionId, UsageAccount? Account, IReadOnlyList<UsageReading> Readings, string? Reason, double AssembledAt)
{
  /// Whose limits these are, when the report names someone.
  public UsageAccount? ReportedAccount => (Readings.FirstOrDefault()?.Account ?? Account) is { } a && (a.Id is not null || a.Name is not null) ? a : null;
}

/// The context window as the agent last wrote it (Mac `ContextReading`).
public sealed record ContextReading(string Provider, string State, double? Tokens, double? Window, double? Percent, string? WindowBasis,
  string? Model, string? ModelLabel, string? SourceSessionId, bool Inferred, int Rivals, double ReportedAt, double ObservedAt, string Detail)
{
  public const string Ok = "ok", NothingYet = "nothing-yet", NotReported = "not-reported";
  public static ContextReading Blank(string provider, string state, string detail, double now) => new(provider, state, null, null, null, null, null, null, null, false, 0, 0, now, detail);
  public bool Counted => State == Ok && Tokens is not null;
  /// `contextIsFresh`: only a figure written just now is drawn on the header.
  public bool IsFresh(double now) => Counted && UsageFormat.Age(ReportedAt, now) == "just now";
  /// `contextShare`: the strip's fill, clamped.
  public double? Share => State == Ok && Percent is { } p ? Math.Clamp(p, 0, 100) : null;
  public UsageLevel Level => UsageFormat.Level(State == Ok ? Percent : null);
  public string? Figure(bool compact = false)
  {
    if (!Counted || Tokens is not { } tokens) return null;
    var full = UsageFormat.Tokens(tokens);
    return compact ? Regex.Replace(full, @"\.\d+(?=[kMB]$)", "") : full;
  }
  public string Provenance(double now)
  {
    var parts = new List<string>();
    if (Model is not null) parts.Add("Model " + Model + ".");
    if (SourceSessionId is not null) parts.Add("Read from session " + SourceSessionId + (Inferred ? ", which this app picked as the folder’s most recent conversation rather than being told" : "") + ".");
    if (Rivals > 0) parts.Add(Rivals == 1 ? "One other conversation was active in this folder at the same time, so this may be that one’s." : Rivals + " other conversations were active in this folder at the same time, so this may be one of theirs.");
    if (WindowBasis == "observed") parts.Add("The window is larger than this app’s table for that model, and was taken from what the transcript proves it held.");
    if (WindowBasis == "reported") parts.Add("The window is the one the agent reports for itself.");
    var age = UsageFormat.Age(ReportedAt, now);
    if (age.Length > 0) parts.Add("The agent wrote this figure " + age + ".");
    return string.Join(" ", parts);
  }
  /// `contextPanel`: the used/free split, the facts and where it came from.
  public ContextPanel? Panel(double now)
  {
    if (!Counted || Tokens is not { } tokens) return null;
    var segments = new List<ContextPanel.Segment>();
    if (Window is { } window && window > 0)
    {
      var free = Math.Max(0, window - tokens);
      segments.Add(new("used", "Used", UsageFormat.Tokens(tokens), UsageFormat.Percent(tokens / window * 100), Math.Clamp(tokens / window * 100, 0, 100)));
      if (free > 0) segments.Add(new("free", "Free", UsageFormat.Tokens(free), UsageFormat.Percent(free / window * 100), Math.Clamp(free / window * 100, 0, 100)));
    }
    var facts = new List<ContextPanel.Fact>();
    if ((ModelLabel ?? Model) is { } name) facts.Add(new("Model", name));
    var age = UsageFormat.Age(ReportedAt, now);
    if (age.Length > 0 && age != "just now") facts.Add(new("Updated", age));
    return new(UsageFormat.Tokens(tokens), Window is { } w ? UsageFormat.Tokens(w) : null, Percent is { } p ? UsageFormat.Percent(p) : null, UsageFormat.Level(Percent), segments, facts, Provenance(now));
  }
  /// `contextSummary`: the strip's accessible name.
  public string? Summary(double now)
  {
    if (Panel(now) is not { } panel) return null;
    var head = panel.Window is { } w ? "Context " + panel.Used + " of " + w + (panel.Share is { } s ? " (" + s + ")" : "") : "Context " + panel.Used + " — no window reported";
    return panel.Provenance.Length == 0 ? head + "." : head + ". " + panel.Provenance;
  }
}

public sealed record ContextPanel(string Used, string? Window, string? Share, UsageLevel Level, IReadOnlyList<ContextPanel.Segment> Segments, IReadOnlyList<ContextPanel.Fact> Facts, string Provenance)
{
  public sealed record Segment(string Key, string Label, string Amount, string Share, double Width);
  public sealed record Fact(string Label, string Value);
  /// The header row's value: "142k / 1M (14%)".
  public string Headline => (Window is { } w ? Used + " / " + w : Used) + (Share is { } s ? " (" + s + ")" : "");
}

public static class UsageFormat
{
  public static UsageLevel Level(double? percent) => percent is not { } p || !double.IsFinite(p) ? UsageLevel.Ok : p >= 90 ? UsageLevel.Critical : p >= 70 ? UsageLevel.Warning : UsageLevel.Ok;
  public static string Percent(double value) => !double.IsFinite(value) ? "—" : value is > 0 and < 1 ? "<1%" : (int)Math.Round(value, MidpointRounding.AwayFromZero) + "%";
  public static string Tokens(double value)
  {
    var abs = Math.Abs(value); var c = CultureInfo.InvariantCulture;
    static string Trim(string text) => Regex.Replace(text, @"\.?0+$", "");
    if (abs >= 999_950_000) return Trim((value / 1_000_000_000).ToString("F2", c)) + "B";
    if (abs >= 999_950) return Trim((value / 1_000_000).ToString("F2", c)) + "M";
    if (abs >= 1000) return Regex.Replace((value / 1000).ToString("F1", c), @"\.0$", "") + "k";
    return ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(c);
  }
  /// `describeAge`.
  public static string Age(double capturedAt, double now)
  {
    if (capturedAt <= 0) return "";
    var age = now - capturedAt; const double minute = 60_000, hour = 3_600_000;
    if (age < 2 * minute) return "just now";
    if (age < hour) return (int)Math.Round(age / minute) + "m ago";
    if (age < 24 * hour) return (int)Math.Round(age / hour) + "h ago";
    return (int)Math.Round(age / (24 * hour)) + "d ago";
  }
  public static string Grouped(double value) => value.ToString("N0", CultureInfo.GetCultureInfo("en-US"));
  /// `formatResetInstant`: the time when within 18 hours, else the date and the time.
  public static string ResetInstant(double at, double now)
  {
    var local = DateTimeOffset.FromUnixTimeMilliseconds((long)at).ToLocalTime();
    var time = local.ToString("t", CultureInfo.CurrentCulture);
    return Math.Abs(at - now) < 18 * 3_600_000 ? time : local.ToString("d MMM", CultureInfo.CurrentCulture) + ", " + time;
  }
  public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// One window's line (Mac `UsageReadout`).
public sealed record UsageReadout(UsageReading Reading, string State, bool Bar, double? Percent, UsageLevel Level, string Value, string? Reset, string Age, string Detail)
{
  public string Name => Reading.Label.Length == 0 ? Reading.Short : Reading.Label;
  public string Facts => string.Join(" · ", new[] { Reset is null ? null : "Renews " + Reset, Age.Length == 0 ? null : "read " + Age }.OfType<string>());
  public static UsageReadout Of(UsageReading reading, double now, Func<double, double, string>? format = null)
  {
    format ??= UsageFormat.ResetInstant;
    var reset = reading.ResetAt is { } at ? format(at, now) : reading.ResetText;
    var age = UsageFormat.Age(reading.ReportedAt, now);
    if (reading.ResetAt is { } expiredAt && expiredAt <= now)
    {
      var last = reading.Used is { } u ? "Last " + UsageFormat.Percent(u * 100) + (age.Length == 0 ? "" : " " + age) : "";
      return new(reading, "expired", false, null, UsageLevel.Ok, "Not reported", reset, age, Join(last, reset is null ? "window reset" : "reset " + reset));
    }
    if (reading.Used is not { } fraction) return new(reading, "unmeasured", false, null, UsageLevel.Ok, "Not reported", reset, age, reset is null ? "" : "Renews " + reset);
    var percent = fraction * 100; var shown = UsageFormat.Percent(percent);
    if (reset is null) return new(reading, "no-reset", true, percent, UsageFormat.Level(percent), shown, null, age, Join(shown + " used", age.Length == 0 ? "" : "read " + age));
    var drifted = reading.NominalMinutes is { } minutes && now - reading.ReportedAt > minutes * 60_000 / 12;
    return new(reading, drifted ? "aged" : "live", true, percent, UsageFormat.Level(percent), shown, reset, age, Join(shown + " used", "renews " + reset, age.Length == 0 ? "" : "read " + age));
  }
  private static string Join(params string[] parts) => string.Join(" · ", parts.Where(p => p.Length > 0));
}

/// The two cards behind the header's controls (`nextPanelState`): hover opens, a press pins.
public enum UsagePanel { Context, Plan }
public readonly record struct UsagePanelState(UsagePanel? Open, bool Pinned)
{
  public static readonly UsagePanelState Shut = new(null, false);
  public UsagePanelState Hover(UsagePanel panel) => Pinned ? this : new(panel, false);
  public UsagePanelState Press(UsagePanel panel) => Open == panel && Pinned ? Shut : new(panel, true);
  public UsagePanelState Leave() => Pinned ? this : Shut;
  /// Opening the plan card is the refresh.
  public static bool OpensPlan(UsagePanelState before, UsagePanelState after) => after.Open == UsagePanel.Plan && before.Open != UsagePanel.Plan;
}

public static class UsageBarRules
{
  public const double RefreshCapSeconds = 18;
  public const string GaveUp = "The check did not come back, so the figures below are the last ones that were read. Opening this again asks once more.";
  public const string ServerWithheld = "This session is a terminal on a server, which is not running this app. There is no account signed in there to have limits and no transcript here to read a context window from, so nothing is shown rather than this computer’s own figures.";
  public static string OutcomeMessage(string outcome) => outcome switch
  {
    "ok" => "Read from Claude Code, in this app’s own process — no session was touched.",
    "cached" => "Read from what Claude Code had already written down — nothing was started.",
    "no-limits" or "settled" => "This login has no subscription limits, so there is nothing to read.",
    "signed-out" => "That account is not signed in to Claude Code, so it has no plan limits to report.",
    "no-binary" => "Claude Code could not be started here, so its usage could not be read.",
    "unwatched" => "This session runs a different agent, so it has no Claude limits to read.",
    _ => "Claude Code’s usage could not be read just now."
  };
  public static bool Settled(string outcome) => outcome is "no-limits" or "settled" or "signed-out" or "no-binary";
  /// The ⓘ beside whose limits these are, only when there is no figure to explain.
  public static string? PanelNote(string? withheld, string? blocked, bool failed, string? detail, string? reason, int rows) =>
    withheld is { Length: > 0 } ? withheld : blocked ?? (failed && detail is not null ? detail : rows == 0 ? reason : null);
  /// The plan control's accessible name.
  public static string Title(IReadOnlyList<UsageReadout> readouts, string whose, string? withheld, string? blocked, UsageReport? report)
  {
    var nothing = withheld ?? blocked ?? (report is null ? "Asking this session what it has used…" : report.Reason ?? "Nothing has been reported for this session yet.");
    var sentence = readouts.Count == 0 ? nothing : string.Join(" ", readouts.Select(r => r.Detail));
    return whose.Length == 0 ? sentence : whose + " — " + sentence;
  }
  /// The window filled furthest, for the ring and its colour.
  public static UsageReadout? Worst(IEnumerable<UsageReadout> readouts) => readouts.Where(r => r.Percent is not null).MaxBy(r => r.Percent);
}
