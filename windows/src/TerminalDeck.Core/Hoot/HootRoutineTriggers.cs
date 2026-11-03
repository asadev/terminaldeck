using System.Collections.Concurrent;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Hoot;

public sealed partial class HootRoutines
{
  private readonly List<FileSystemWatcher> watchers = [];
  private readonly ConcurrentDictionary<string, CancellationTokenSource> fileDebounce = new();
  public static string[] DocumentTriggers(string text)
  {
    var lines = text.Split('\n');
    if (!lines.Any(l => l.Trim() == "---")) return [];
    var headers = lines.FirstOrDefault()?.Trim() == "---" ? lines.Skip(1) : lines.AsEnumerable();
    return headers.TakeWhile(l => l.Trim() != "---").Where(l => l.TrimStart().StartsWith("when:", StringComparison.OrdinalIgnoreCase))
      .Select(l => l[(l.IndexOf(':') + 1)..].Trim().Trim('"', '\'')).Take(10).ToArray();
  }
  public static void ValidateTrigger(string text)
  {
    if (text.Length is 0 or > 256 || text.Any(char.IsControl)) throw new ArgumentException("Choose a usable routine trigger.");
    var parts = text.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries); var kind = parts[0]; var argument = parts.Length == 2 ? parts[1] : "";
    if (kind == "schedule") { _ = Scheduled(argument, DateTimeOffset.UtcNow); return; }
    if (kind == "session-idle") { _ = Duration(argument); return; }
    if (kind is "session-finished" or "session-failed" or "task-created" or "task-finished" or "manual" or "git-change") return;
    if (kind == "file-change" && argument.Length <= 200 && !argument.Contains("..", StringComparison.Ordinal) && !Path.IsPathRooted(argument)) return;
    if (kind == "alert" && (argument.Length == 0 || Regex.IsMatch(argument, "^[a-z][a-z-]{0,40}$"))) return;
    throw new ArgumentException("Choose session-finished, session-failed, task-created, task-finished, session-idle, alert, git-change, file-change, schedule or manual.");
  }
  private static TimeSpan Duration(string text)
  {
    var match = Regex.Match(text, "^([0-9]{1,5})(s|m|h|d)$");
    if (!match.Success) throw new ArgumentException("Use a duration such as 15m or 2h.");
    var seconds = int.Parse(match.Groups[1].Value) * (match.Groups[2].Value switch { "m" => 60d, "h" => 3600d, "d" => 86400d, _ => 1d });
    if (seconds < 1 || seconds > 604800) throw new ArgumentException("Use an interval no longer than one week.");
    return TimeSpan.FromSeconds(seconds);
  }
  private static DateTimeOffset Scheduled(string text, DateTimeOffset from)
  {
    if (text.StartsWith("every ", StringComparison.Ordinal))
    {
      var interval = Duration(text[6..]); if (interval < TimeSpan.FromMinutes(5)) throw new ArgumentException("Scheduled routines run no faster than every five minutes.");
      return from + interval;
    }
    var parts = text.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
    if (parts.Length == 0 || !TimeOnly.TryParseExact(parts[0], ["H:mm", "HH:mm"], System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var time)) throw new ArgumentException("Use a time such as 09:00 or every 2h.");
    var days = new HashSet<DayOfWeek>();
    if (parts.Length > 1)
      foreach (var word in parts[1].Split([',', ' '], StringSplitOptions.RemoveEmptyEntries))
      {
        if (word == "weekdays") { foreach (var day in new[] { DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday }) days.Add(day); }
        else if (word == "weekends") { days.Add(DayOfWeek.Saturday); days.Add(DayOfWeek.Sunday); }
        else if (Enum.GetValues<DayOfWeek>().FirstOrDefault(d => d.ToString().StartsWith(word, StringComparison.OrdinalIgnoreCase)) is var day && word.Length >= 3 && day.ToString().StartsWith(word, StringComparison.OrdinalIgnoreCase)) days.Add(day);
        else throw new ArgumentException("Choose valid days for this routine.");
      }
    var local = TimeZoneInfo.ConvertTime(from, TimeZoneInfo.Local);
    for (var offset = 0; offset <= 7; offset++)
    {
      var date = DateOnly.FromDateTime(local.DateTime).AddDays(offset);
      var candidate = date.ToDateTime(time, DateTimeKind.Unspecified);
      if (days.Count > 0 && !days.Contains(candidate.DayOfWeek) || TimeZoneInfo.Local.IsInvalidTime(candidate)) continue;
      var result = new DateTimeOffset(candidate, TimeZoneInfo.Local.GetUtcOffset(candidate)); if (result > from) return result;
    }
    throw new ArgumentException("No upcoming routine time could be scheduled.");
  }
  private static DateTimeOffset? NextDue(HootRoutine routine, DateTimeOffset from)
  {
    if (routine.Triggers.Length == 0) return from.AddMinutes(routine.EveryMinutes);
    var candidates = routine.Triggers.Where(t => t.StartsWith("schedule ", StringComparison.Ordinal)).Select(t => Scheduled(t[9..], from)).ToArray();
    return candidates.Length == 0 ? null : candidates.Min();
  }
  public async ValueTask TriggerAsync(string kind, string? folder = null, string? argument = null, CancellationToken ct = default)
  {
    HootRoutine[] candidates;
    lock (gate) candidates = state.Routines.Where(r => r.Enabled && (folder is null || string.Equals(Path.GetFullPath(r.Folder), Path.GetFullPath(folder), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) &&
      r.Triggers.Any(trigger => Matches(trigger, kind, argument))).ToArray();
    foreach (var routine in candidates) await RequestAsync(routine.Id, kind + (argument is null ? "" : " " + argument), ct);
  }
  private static bool Matches(string trigger, string kind, string? argument)
  {
    var parts = trigger.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries); if (parts[0] != kind) return false;
    if (kind == "file-change")
    {
      var glob = parts.Length > 1 ? parts[1] : "**/*";
      var pattern = "^" + Regex.Escape(glob.Replace('\\', '/')).Replace("\\*\\*/", "(?:.*/)?").Replace("\\*\\*", ".*").Replace("\\*", "[^/]*").Replace("\\?", ".") + "$";
      return Regex.IsMatch(argument?.Replace('\\', '/') ?? "", pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
    }
    return parts.Length == 1 || kind == "session-idle" || parts[1] == argument;
  }
  public ValueTask RunAsync(string id, CancellationToken ct = default) => RequestAsync(id, "manual", ct);
  private ValueTask RequestAsync(string id, string cause, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    lock (gate)
    {
      var routine = state.Routines.SingleOrDefault(r => r.Id == id && r.Enabled) ?? throw new InvalidOperationException("Enable this routine before running it.");
      if (routine.RecoveryHold)
      {
        if (cause != "manual") return ValueTask.CompletedTask;
        Update(id, r => r with { RecoveryHold = false, Runs = r.Runs.Select(run => run.State == "queued" ? run with { State = "stopped", Problem = "Kept after recovery; not replayed." } : run).ToArray() });
      }
      QueueLocked(id, cause, clock.GetUtcNow()); Schedule();
    }
    KickReady(); return ValueTask.CompletedTask;
  }
  public void Complete(string id, bool success, string? problem = null)
  { lock (gate) if (state.Routines.Any(r => r.Id == id)) Update(id, r => r with { LastOutcome = success ? "ok" : "failed", Problem = problem }); }
  private static HootRoutine DocumentOptions(HootRoutine routine)
  {
    var lines = routine.Text.Split('\n');
    if (!lines.Any(l => l.Trim() == "---")) return routine;
    var headers = (lines.FirstOrDefault()?.Trim() == "---" ? lines.Skip(1) : lines.AsEnumerable()).TakeWhile(l => l.Trim() != "---");
    var next = routine with { Triggers = routine.Triggers.Length == 0 ? DocumentTriggers(routine.Text) : routine.Triggers };
    foreach (var line in headers)
    {
      var at = line.IndexOf(':'); if (at <= 0) continue; var key = line[..at].Trim(); var value = line[(at + 1)..].Trim().Trim('"', '\'');
      int Count(int max) => int.TryParse(value, out var number) && number >= 1 && number <= max ? number : throw new ArgumentException("Invalid routine " + key + ".");
      next = key switch
      {
        "agent-id" => next with { AgentId = value }, "overlap" => next with { Overlap = value }, "catch-up" => next with { CatchUp = value },
        "max-pending" => next with { MaxPending = Count(100) }, "max-catch-up" => next with { MaxCatchUp = Count(50) },
        "max-runs-per-hour" => next with { MaxRunsPerHour = Count(1000) }, "max-runs-per-day" => next with { MaxRunsPerDay = Count(10000) },
        "quiet-for" => next with { QuietSeconds = (int)Duration(value).TotalSeconds }, "expect-every" => next with { ExpectEverySeconds = (int)Duration(value).TotalSeconds },
        _ => next
      };
    }
    return next;
  }
  private void RebuildWatchers()
  {
    foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear();
    foreach (var folder in state.Routines.Where(r => r.Enabled && r.Triggers.Any(t => t.StartsWith("file-change", StringComparison.Ordinal) || t == "git-change")).Select(r => r.Folder).Distinct().Where(Directory.Exists))
    {
      var watcher = new FileSystemWatcher(folder) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.DirectoryName };
      FileSystemEventHandler changed = (_, e) => QueueFile(folder, e.FullPath);
      watcher.Changed += changed; watcher.Created += changed; watcher.Deleted += changed; watcher.Renamed += (_, e) => QueueFile(folder, e.FullPath);
      watcher.EnableRaisingEvents = true; watchers.Add(watcher);
    }
  }
  private void QueueFile(string folder, string path)
  {
    if (fileDebounce.Count >= 256) return;
    var key = folder + ":" + path; var next = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
    fileDebounce.AddOrUpdate(key, next, (_, old) => { old.Cancel(); return next; });
    _ = Task.Run(async () =>
    {
      try { await Task.Delay(500, next.Token); var relative = Path.GetRelativePath(folder, path).Replace('\\', '/'); await TriggerAsync(relative.StartsWith(".git/", StringComparison.Ordinal) ? "git-change" : "file-change", folder, relative, next.Token); }
      catch (Exception e) when (e is OperationCanceledException or IOException or InvalidOperationException or ArgumentException) { }
      finally { if (fileDebounce.TryGetValue(key, out var kept) && ReferenceEquals(kept, next)) fileDebounce.TryRemove(key, out _); next.Dispose(); }
    });
  }
}
