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

  private CloudSecretsPlatform CloudSecretsPlatform() => new(
    (subject, deviceId) => new WindowsCloudSecretsSlots(Root, subject, deviceId),
    subject => Path.Combine(CloudAccountFolder(subject), "secrets"),
    CloudSecretStores);

  /// The travelling stores of this version, each under the delete rule. Server sign-ins today; see the lane's result
  /// file for the kinds still to come.
  private IReadOnlyList<ICloudSecretsStore> CloudSecretStores(string subject, string deviceId, Func<long?> serviceNow)
  {
    var state = Path.Combine(CloudAccountFolder(subject), "secrets");
    var servers = new CloudSecretsServerStore(LiveServerStore ?? new ServerStore(Root, new WindowsCredentialStore(Root)), Path.Combine(state, "server-ids.json"));
    string? DeviceName(string id) => Cloud.Snapshot.DeviceRows.FirstOrDefault(d => string.Equals(d.DeviceId, id, StringComparison.OrdinalIgnoreCase))?.Name;
    return [new CloudSecretsDeleteOwner(servers, Path.Combine(state, "servers"), () => CloudSecretsDeleteRuleOpen(), CloudSecretsServerStore.Name, servers.RemoveAsync,
      deviceName: DeviceName, serviceClock: serviceNow)];
  }
}
