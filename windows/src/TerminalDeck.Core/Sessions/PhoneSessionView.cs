using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Sessions;

// Everything: Full control on the device dialog — every session and chat on this PC, now
// and later, like the Mac. AnyAccount: sessions in the granted folders whatever account runs them.
public sealed record SessionGrant(string DeviceId, bool AllSessions, string[] SessionIds, string[] Folders, string[] AccountIds, bool Everything = false, bool AnyAccount = false);
public sealed record SessionGrantState(SessionGrant[] Grants);

public sealed class PhoneSessionGrants(IStateStore<SessionGrantState> store)
{
  private readonly object gate = new();
  private SessionGrantState state = store.Load() ?? new([]);
  public void Set(SessionGrant grant)
  {
    lock (gate)
    {
      var copy = grant with { SessionIds = [.. grant.SessionIds], Folders = [.. grant.Folders], AccountIds = [.. grant.AccountIds] };
      var next = new SessionGrantState(state.Grants.Where(g => g.DeviceId != grant.DeviceId).Append(copy).ToArray());
      store.Save(next); state = next;
    }
  }
  public bool Allows(ApprovedDevice device, SessionRecord session)
  {
    lock (gate)
    {
      var grant = state.Grants.FirstOrDefault(g => g.DeviceId == device.Id);
      if (grant is null) return false;
      if (grant.Everything) return true;
      var d = session.Definition;
      return (grant.AllSessions || grant.SessionIds.Contains(d.Id)) &&
        grant.Folders.Any(f => SameOrChild(d.Cwd, f)) &&
        (grant.AnyAccount || d.AccountId is null || grant.AccountIds.Contains(d.AccountId));
    }
  }
  public SessionGrant? Get(string deviceId) { lock (gate) return state.Grants.FirstOrDefault(g => g.DeviceId == deviceId); }
  // Folders a phone may start a session in: anywhere at Full control, else its granted folders.
  public bool MayStartIn(ApprovedDevice device, string folder)
  {
    lock (gate)
    {
      var grant = state.Grants.FirstOrDefault(g => g.DeviceId == device.Id);
      return grant is not null && (grant.Everything || grant.Folders.Any(f => SameOrChild(folder, f)));
    }
  }
  public static bool SameOrChild(string path, string folder)
  {
    // Windows paths are compared as Windows paths even in Mac tests. Never use a raw prefix.
    var p = path.Replace('\\', '/').TrimEnd('/');
    var f = folder.Replace('\\', '/').TrimEnd('/');
    if (p.Split('/').Any(s => s is "." or "..") || f.Split('/').Any(s => s is "." or "..") || f.Length == 0) return false;
    return p.Equals(f, StringComparison.OrdinalIgnoreCase) || p.StartsWith(f + "/", StringComparison.OrdinalIgnoreCase);
  }
}

public sealed class PhoneSessionView(SessionKeeper keeper, PhoneSessionGrants grants) : IPhoneSessionView
{
  public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => keeper.List().Where(s => grants.Allows(device, s)).Select(s => JsonSerializer.SerializeToElement(new
  {
    id = s.Definition.Id, provider = s.Definition.Provider, cwd = s.Definition.Cwd, title = s.Definition.Title,
    status = PhoneSessionRows.TerminalStatus(s, working: false), createdAt = s.CreatedAt
  })).ToArray();
}
