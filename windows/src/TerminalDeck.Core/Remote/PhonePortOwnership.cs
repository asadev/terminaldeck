namespace TerminalDeck.Core.Remote;

public sealed record PhonePortRoot(int ProcessId, long StartedUtcTicks, string SessionId);
public sealed record PhonePortProcess(int ProcessId, int ParentId, long StartedUtcTicks);

public static class PhonePortOwnership
{
  // The composition supplies ONLY session roots currently granted to this
  // device. A shared folder alone cannot authorize an unrelated PC service.
  public static bool Allows(PhoneAccess access, IReadOnlyList<int> owners, IReadOnlyList<PhonePortRoot> grantedRoots, Func<int, PhonePortProcess?> process)
  {
    if (access == PhoneAccess.Full) return true;
    if (access != PhoneAccess.Work || owners.Count == 0 || grantedRoots.Count == 0) return false;
    return owners.Distinct().All(Owned);
    bool Owned(int pid)
    {
      var seen = new HashSet<int>(); var childStarted = long.MaxValue;
      for (var hop = 0; hop < 64 && pid > 0 && seen.Add(pid); hop++)
      {
        var current = process(pid);
        if (current is null || current.StartedUtcTicks <= 0 || current.StartedUtcTicks > childStarted) return false;
        if (grantedRoots.Any(r => r.ProcessId == pid && r.StartedUtcTicks == current.StartedUtcTicks)) return true;
        childStarted = current.StartedUtcTicks; pid = current.ParentId;
      }
      return false;
    }
  }
}
