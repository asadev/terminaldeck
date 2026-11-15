using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Servers;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

/// Saved passwords and the keys that ride them (lane S). The saved-passwords key arrives by itself from one of his
/// devices (no code, no click) and is kept in this copy's own protected slots; his saved values travel sealed with it.
/// Per account: `cloud\accounts\<account>\secrets` (keyed marks, the sealed Bins, kept conflicts; no value in clear).
/// Integrator lines (shared files): `Secrets: CloudSecretsPlatform()` on the CloudSyncPlatform in AppRuntime.Cloud.cs, and
/// `CloudSecretsDeleteRuleOpen = () => <lane D's CloudAnnounce>.DeleteRuleIsOpen();` once lane D's announcer exists.
public sealed partial class AppRuntime
{
  /// The delete rule's gate (every computer announced it). Closed until lane D's announcer is wired: no removal of a
  /// saved password is made or sent, exactly as on a Mac while the gate is closed.
  public Func<bool> CloudSecretsDeleteRuleOpen { get; set; } = () => false;
  /// The saved-password stores of the signed-in account (the Your Cloud page lists their items by name).
  private IReadOnlyList<ICloudSecretsStore> cloudSecretStores = [];

  private CloudSecretsPlatform CloudSecretsPlatform() => new(
    (subject, deviceId) => new WindowsCloudSecretsSlots(Root, subject, deviceId),
    subject => Path.Combine(CloudAccountFolder(subject), "secrets"),
    CloudSecretStores);

  /// The travelling stores of this version, each under the delete rule. Server sign-ins today; see the lane's result
  /// file for the kinds still to come.
  private IReadOnlyList<ICloudSecretsStore> CloudSecretStores(string subject, string deviceId, Func<long?> serviceNow)
  {
    var state = Path.Combine(CloudAccountFolder(subject), "secrets");
    // ONE server store for server sign-ins and SSH keys: the app's live one.
    var serverStore = LiveServerStore ?? new ServerStore(Root, new WindowsCredentialStore(Root));
    var servers = new CloudSecretsServerStore(serverStore, Path.Combine(state, "server-ids.json"));
    string? DeviceName(string id) => Cloud.Snapshot.DeviceRows.FirstOrDefault(d => string.Equals(d.DeviceId, id, StringComparison.OrdinalIgnoreCase))?.Name;
    var serversOwner = new CloudSecretsDeleteOwner(servers, Path.Combine(state, "servers"), () => CloudSecretsDeleteRuleOpen(), CloudSecretsServerStore.Name, servers.RemoveAsync,
      deviceName: DeviceName, serviceClock: serviceNow);
    // Lane S2: API keys, MCP servers (Claude's user list), server SSH keys; same state folder, gate and names.
    string ThisName() => Cloud.Snapshot.DeviceRows.FirstOrDefault(d => d.ThisDevice)?.Name ?? Environment.MachineName;
    Func<bool> gate = () => CloudSecretsDeleteRuleOpen();
    var apiStore = new CloudKeysApiStore(ApiAccounts.CloudDoor(account => Sessions.Any(s => s.Definition.AccountId == account && s.State != SessionState.Exited)
      || Chats.List().Any(c => c.Definition.AccountId == account && !c.Ended)), state, ThisName);
    var api = apiStore.DeleteRuleOwner(state, gate, DeviceName, serviceNow, CloudSecretsVanished.IdentityOnly(() => deviceId, ThisName));
    var claudeHome = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } dir ? dir : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var mcp = new CloudKeysMcpStore(new ClaudeMcpUserList(() => Path.Combine(claudeHome, ".claude.json"), new ReadinessProcessRunner(Root), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)), ThisName)
      .DeleteRuleOwner(state, gate, DeviceName, serviceNow, CloudKeysMcpStore.Witness(CloudWitness!, () => deviceId, ThisName));
    var sshFolder = new CloudKeysSshFolder(Path.Combine(state, "ssh-travelled"), TerminalDeck.Platform.Windows.Servers.WindowsOwnerOnly.Protect);
    CloudSshTravelledBox.Shared.Set(sshFolder);
    var ssh = new CloudKeysSshStore(serverStore, id => Path.Combine(Root.DirectoryPath, "servers", id), sshFolder, Path.Combine(state, "ssh-server-ids.json"))
      .DeleteRuleOwner(state, gate, DeviceName, serviceNow);
    CloudKeysRemovals.Shared.Set(CloudKeysRemovals.Through(new Dictionary<string, CloudSecretsDeleteOwner> { ["api"] = api },
      () => serviceNow() is { } at ? new CloudDeleteActor(CloudDeleteBy.Person, deviceId, ThisName(), null, null, at, Guid.NewGuid().ToString("D")) : null));
    // Lane S3: project secret files (its own delete owner, not wrapped); gate = every device announced `projectsecrets`.
    var fileState = Path.Combine(state, "project-files");
    var files = new CloudProjectSecretFilesStore(fileState,
      () => Projects.List().Select(p => new CloudProjectSecretFilesProject(p.Id, p.Name, p.Folders)).ToArray(),
      () => Cloud.Snapshot.ThisDeviceName ?? Environment.MachineName,
      () => Cloud.Snapshot.UseCloud != true ? CloudProjectSecretFilesGate.CloudMemoryOff
        : cloudAnnounce?.EveryDeviceUnderstands(CloudProjectSecretFilesRules.Feature, CloudProjectSecretFilesRules.Format) == true
          ? CloudProjectSecretFilesGate.Open : CloudProjectSecretFilesGate.WaitingForDevices,
      deleteGate: () => CloudSecretsDeleteRuleOpen(), deleteStamp: serviceNow, deleteDevice: () => deviceId, deleteMacName: DeviceName,
      witness: CloudDeleteWitnessSlot.Shared);
    CloudProjectSecretFilesHolder.Shared.Store = files; CloudProjectSecretFilesHolder.Shared.StateRoot = fileState;
    cloudSecretStores = [serversOwner, api, mcp, ssh, files];
    return cloudSecretStores;
  }
}
