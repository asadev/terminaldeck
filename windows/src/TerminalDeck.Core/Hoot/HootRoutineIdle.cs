namespace TerminalDeck.Core.Hoot;

public sealed partial class HootRoutines
{
  private sealed record SessionIdle(string Folder, DateTimeOffset? Since, HashSet<string> Fired);
  private readonly Dictionary<string, SessionIdle> idleSessions = [];
  public void ObserveSession(string id, string folder, bool busy, bool ended = false)
  {
    lock (gate)
    {
      if (ended) idleSessions.Remove(id);
      else if (!idleSessions.TryGetValue(id, out var prior) || busy || prior.Since is null)
        idleSessions[id] = new(folder, busy ? null : clock.GetUtcNow(), []);
      Schedule();
    }
  }
  private DateTimeOffset? IdleNext()
  {
    DateTimeOffset? earliest = null;
    foreach (var routine in state.Routines.Where(r => r.Enabled))
      foreach (var trigger in routine.Triggers.Where(t => t.StartsWith("session-idle ", StringComparison.Ordinal)))
        foreach (var session in idleSessions.Values.Where(s => s.Since is not null && !s.Fired.Contains(routine.Id) && SameFolder(s.Folder, routine.Folder)))
        {
          var due = session.Since!.Value + Duration(trigger[13..]);
          if (earliest is null || due < earliest) earliest = due;
        }
    return earliest;
  }
  private async ValueTask DispatchIdleAsync(CancellationToken ct)
  {
    var pending = new HashSet<string>();
    lock (gate)
      foreach (var routine in state.Routines.Where(r => r.Enabled))
        foreach (var trigger in routine.Triggers.Where(t => t.StartsWith("session-idle ", StringComparison.Ordinal)))
          foreach (var session in idleSessions.Values.Where(s => s.Since is not null && !s.Fired.Contains(routine.Id) && SameFolder(s.Folder, routine.Folder)))
            if (session.Since!.Value + Duration(trigger[13..]) <= clock.GetUtcNow()) { session.Fired.Add(routine.Id); pending.Add(routine.Id); }
    foreach (var id in pending) await RunAsync(id, ct);
  }
  private static bool SameFolder(string a, string b) => string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}
