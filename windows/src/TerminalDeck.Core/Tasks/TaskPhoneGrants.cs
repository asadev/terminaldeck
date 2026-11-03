using System.Collections.Immutable;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tasks;

public sealed record TaskPhoneGrant(string DeviceId, ImmutableArray<string> ProjectIds);
public sealed record TaskPhoneGrantState(int Version, ImmutableArray<TaskPhoneGrant> Grants);
public sealed class TaskPhoneGrants
{
  private readonly object gate = new();
  private readonly IStateStore<TaskPhoneGrantState> store;
  private readonly IProjects projects;
  private TaskPhoneGrantState state;
  public TaskPhoneGrants(IStateStore<TaskPhoneGrantState> store, IProjects projects)
  {
    this.store = store; this.projects = projects;
    state = store.Load() ?? new(1, []);
    if (state.Version != 1 || state.Grants.IsDefault || state.Grants.Any(g => g.ProjectIds.IsDefault) || state.Grants.Select(g => g.DeviceId).Distinct().Count() != state.Grants.Length)
      throw new IOException("The saved phone task access could not be read safely.");
  }
  // The existing device settings/approval owner calls this after the person has
  // selected task projects. Pairing or a session grant never calls it implicitly.
  public void Set(TaskPhoneGrant grant)
  {
    if (string.IsNullOrWhiteSpace(grant.DeviceId) || grant.ProjectIds.IsDefault) throw new ArgumentException("Choose a device and its task projects.");
    foreach (var id in grant.ProjectIds) _ = projects.Get(id);
    lock (gate)
    {
      var next = state with { Grants = state.Grants.Where(g => g.DeviceId != grant.DeviceId).Append(grant with { ProjectIds = grant.ProjectIds.Distinct().ToImmutableArray() }).ToImmutableArray() };
      store.Save(next); state = next;
    }
  }
  public bool HasProject(ApprovedDevice device, string projectId)
  {
    lock (gate) return state.Grants.Any(g => g.DeviceId == device.Id && g.ProjectIds.Contains(projectId));
  }
  public bool Allows(ApprovedDevice device, string folder) => Allows(device, null, folder);
  // A folder is only one part of a task grant. Nested projects and Independent
  // tasks can share that path without sharing the owner's project selection.
  public bool Allows(ApprovedDevice device, string? projectId, string folder)
  {
    lock (gate)
    {
      var grant = state.Grants.FirstOrDefault(g => g.DeviceId == device.Id);
      if (grant is null) return false;
      return projects.List().Where(p => p.IsOpen && (projectId is null || p.Id == projectId) && grant.ProjectIds.Contains(p.Id)).SelectMany(p => p.Folders).Any(f => ProjectPaths.Contains(f, folder));
    }
  }
}
