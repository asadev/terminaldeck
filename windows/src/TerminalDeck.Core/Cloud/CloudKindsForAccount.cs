using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Cloud;

/// Tasks (I12) and settings (I21) for one signed-in account on this PC (the Mac's BackendCloudKinds.make), built in one call.
/// The Mac keeps these apart from projects and agents, so they have their OWN record store, `cloud\accounts\<account>\kinds`
/// (the join marks of one never end the other's join), and their own origins file `cloud\accounts\kinds-origins.json`.
/// A change is handed on once it has stayed the same for `quiet` milliseconds (the Mac's 2 seconds).
public sealed class CloudKindsForAccount
{
  public const double Quiet = 2_000;
  public CloudRecordStore Store { get; }
  public CloudKindsKept Kept { get; }
  public CloudTasksOwner Tasks { get; }
  public CloudSettingsOwner Settings { get; }
  /// In sending order: tasks, then settings. Register them after projects, agents and memory.
  public IReadOnlyList<CloudRecordAdapter> Adapters { get; }

  /// `settings`: CloudSettingsOwner.ForWindows(...) in the app. `fullAccess`: true while the trust setting is "Automatically,
  /// with my account". `tasksChanged` / `settingsChanged`: display only, after an import.
  public CloudKindsForAccount(string accountFolder, string account, string deviceId, TaskStore tasks, IProjects projects, IEnumerable<CloudSetting> settings,
    Func<bool?>? fullAccess = null, Func<long>? clock = null, double quiet = Quiet, Action? tasksChanged = null, Action? settingsChanged = null)
  {
    var accounts = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(accountFolder)) ?? accountFolder;
    var own = Path.Combine(accountFolder, "kinds");
    var now = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    Store = new CloudRecordStore(own, clock);
    var origins = new CloudRecordOrigins(accounts, account, "kinds-origins.json");
    Kept = new CloudKindsKept(Path.Combine(own, "replaced-values.json"), now);
    double Local() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    Tasks = new CloudTasksOwner(tasks, projects, new CloudRecordsDeleteLedger(accountFolder, own, "tasks", clock), Kept, new CloudKindsSettle(quiet, Local), Path.Combine(own, "task-ledger.json"), now, tasksChanged);
    Settings = new CloudSettingsOwner(settings, fullAccess, Kept, new CloudKindsSettle(quiet, Local), Path.Combine(own, "settings-chosen.json"), settingsChanged);
    Adapters = [Tasks.Adapter(Store, account, deviceId, origins), Settings.Adapter(Store, account, deviceId, origins)];
  }
  /// The delete rule for tasks (see CloudRecordsForAccount.ConfigureDeleteRule).
  public void ConfigureDeleteRule(Func<bool> gate, Func<string, string?> deviceName, Func<long?>? serviceNow = null) => Tasks.ConfigureDeleteRule(gate, deviceName, serviceNow);
}
