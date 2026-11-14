using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Cloud;

/// Projects and agents for one signed-in account on this PC (the Mac's BackendCloudLeanRecords.make), built in one call.
/// Bookkeeping per account in `cloud\accounts\<account>\records\` (one small file per record, saved once per pack); this
/// PC's own ledgers (never sent) beside the account folders. Projects come first: a project is on this PC before the
/// agents that name it (the Mac's rule G: projects and agents go before anything else queued).
public sealed class CloudRecordsForAccount
{
  public CloudRecordStore Store { get; }
  public CloudProjectsOwner Projects { get; }
  public CloudAgentsOwner Agents { get; }
  /// In sending order: projects, then agents. Register them before every other owner.
  public IReadOnlyList<CloudRecordAdapter> Adapters { get; }

  /// `accountFolder`: `cloud\accounts\<account>`. `fullAccess`: true while the trust setting is "Automatically, with my
  /// account". `projectsAdded`: a project became known here (project memory that waited is placed).
  public CloudRecordsForAccount(string accountFolder, string account, string deviceId, IProjects projects, IAgents agents, CloudProjectFolders? folders,
    Func<bool?>? fullAccess = null, Action? projectsAdded = null, Func<long>? clock = null)
  {
    var accounts = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(accountFolder)) ?? accountFolder;
    Store = new CloudRecordStore(Path.Combine(accountFolder, "records"), clock);
    var origins = new CloudRecordOrigins(accounts, account);
    Projects = new CloudProjectsOwner(projects, folders, fullAccess, projectsAdded, Path.Combine(accountFolder, "records", "project-ids.json"));
    Agents = new CloudAgentsOwner(agents, projects, fullAccess, Path.Combine(accountFolder, "records", "agent-ledger.json"), now: clock);
    Adapters = [Projects.Adapter(Store, account, deviceId, origins), Agents.Adapter(Store, account, deviceId, origins)];
  }
}
