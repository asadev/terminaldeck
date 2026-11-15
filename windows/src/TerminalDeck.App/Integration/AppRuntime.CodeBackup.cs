using TerminalDeck.Core.Code;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.App.Integration;

/// Lane K: the Code page's backup to GitHub (the Mac's BackendCodeBackupHolder install at start). One live
/// CodeBackupActions for the GitHub page's rows and the code.* tools, using the GitHub CLI sign-in this copy already uses
/// (a test copy gets its own gh folder, never the person's), its ledger in this copy's data folder, and Automatic looks
/// every 5 minutes on a normal (not metered) network.
public sealed partial class AppRuntime
{
  private CodeBackupActions? codeBackup;

  /// Builds, installs and starts the Code page's backup, and registers its tools. Called once at start, after Projects
  /// and the tool door exist (the join adds the one start-up line).
  public CodeBackupActions StartCodeBackup()
  {
    if (codeBackup is not null) return codeBackup;
    var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var realCopy = GitHubClient.IsRealCopy(Root.DirectoryPath, AppContext.BaseDirectory, profile);
    var account = CodeBackupGhAccount.ForCopy(Root.DirectoryPath, realCopy);
    var git = new CodeBackupGitRunner(profile);
    var ledger = new CodeBackupLedger(Path.Combine(Root.DirectoryPath, CodeBackupLedger.FileName));
    var reader = new CodeBackupReader(git, coverage: ledger.Coverage);
    var projects = new CodeBackupProjects(() => Task.FromResult<IReadOnlyList<CodeBackupProjectRef>>(Projects.List()
      .Where(p => p.Id != ProjectIdentity.IndependentId)
      .Select(p => new CodeBackupProjectRef(p.Id, p.Name, p.Folders.IsDefaultOrEmpty ? [] : p.Folders.ToArray())).ToList()), reader, new CodeBackupGitHub(account));
    codeBackup = new CodeBackupActions(projects, ledger, account, git, network: NormalNetwork);
    CodeBackupHolder.Installed = codeBackup;
    new CodeBackupTools(() => CodeBackupHolder.Installed).Register(Door);
    codeBackup.Start();
    return codeBackup;
  }

  /// A normal network: connected to the internet, not metered (the Mac's "not Low Data, not a phone hotspot").
  private static bool NormalNetwork()
  {
    try
    {
      var profile = Windows.Networking.Connectivity.NetworkInformation.GetInternetConnectionProfile();
      if (profile is null || profile.GetNetworkConnectivityLevel() != Windows.Networking.Connectivity.NetworkConnectivityLevel.InternetAccess) return false;
      var cost = profile.GetConnectionCost();
      return cost.NetworkCostType is Windows.Networking.Connectivity.NetworkCostType.Unrestricted or Windows.Networking.Connectivity.NetworkCostType.Unknown
        && !cost.Roaming && !cost.OverDataLimit && !cost.ApproachingDataLimit;
    }
    catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { return false; }
  }
}
