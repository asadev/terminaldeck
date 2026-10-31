using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Sessions;

public sealed record SessionGrant(string DeviceId, bool AllSessions, string[] SessionIds, string[] Folders, string[] AccountIds);
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
      var d = session.Definition;
      return (grant.AllSessions || grant.SessionIds.Contains(d.Id)) &&
        grant.Folders.Any(f => SameOrChild(d.Cwd, f)) &&
        (d.AccountId is null || grant.AccountIds.Contains(d.AccountId));
    }
  }
  private static bool SameOrChild(string path, string folder)
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
    status = s.State switch { SessionState.Running => "waiting", SessionState.Exited => "exited", _ => "restoring" },
    createdAt = s.CreatedAt
  })).ToArray();
}
