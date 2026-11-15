using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Cloud;

/// Lane R2's routing of the app's and the tools' deletes: while this PC is signed in (the account's record owners exist)
/// an agent or project removed here goes through its owner, so the removal travels (Everywhere, into every Bin for 30
/// days); signed out it is the plain local removal, as before. Set by the app when the owners are built.
public static class CloudRecordDeletes
{
  public static Func<CloudRecordsForAccount?>? Current { get; set; }

  public static void RemoveAgent(IAgents agents, string id, string? aiSession = null, bool byAi = false)
  {
    if (Current?.Invoke() is { } records)
      records.Agents.RemoveByApp(id, byAi ? records.Agents.Deletes.Actor(CloudDeleteBy.Ai, session: aiSession) : null);
    else agents.Remove(id);
  }

  /// `remove_empty`: the caller's own checks ran first (no folders, no lead); the owner's removal runs the project
  /// service's remaining checks.
  public static void RemoveEmptyProject(IProjects projects, string id, string? aiSession = null)
  {
    if (Current?.Invoke() is { } records)
    {
      var p = projects.List().First(p => p.Id == id);
      if (!p.Folders.IsEmpty || p.Lead is not null) throw new ArgumentException("This project still has folders or a lead. Use the project removal action instead.");
      records.Projects.RemoveByApp(id, records.Projects.Deletes.Actor(CloudDeleteBy.Ai, session: aiSession));
    }
    else projects.RemoveEmpty(id);
  }
}
