using System.Globalization;

namespace TerminalDeck.Core.Tasks;

public static class TaskDates
{
  public static bool TryTime(string? value, out TimeOnly time) => TimeOnly.TryParseExact(value, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out time);
  public static void RequireTime(string? value)
  {
    if (value is not null && (value.Length != 5 || !TryTime(value, out _))) throw new ArgumentException("Use a time such as 09:30, or clear it.");
  }
  public static bool Overdue(DeckTask task, DateTimeOffset now)
  {
    if (task.Status == "Done" || !DateOnly.TryParseExact(task.DueDate, "yyyy-MM-dd", out var due)) return false;
    var today = DateOnly.FromDateTime(now.DateTime);
    return due < today || due == today && TryTime(task.DueTime, out var time) && time < TimeOnly.FromDateTime(now.DateTime);
  }
  public static string Label(string? date, string? time, string fallback) => date is null ? fallback : date + (time is null ? "" : " " + time);
}
