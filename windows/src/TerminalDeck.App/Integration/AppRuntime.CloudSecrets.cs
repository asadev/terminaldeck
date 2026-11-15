using TerminalDeck.Core.Cloud;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

/// Saved passwords and the keys that ride them (lane S). The saved-passwords key arrives by itself from one of his
/// devices (no code, no click) and is kept in this copy's own protected slots; his saved values travel sealed with it.
/// Per account: `cloud\accounts\<account>\secrets` (keyed marks, the sealed Bins, kept conflicts; no value in clear).
/// The integrator adds `Secrets: CloudSecretsPlatform()` to the CloudSyncPlatform in AppRuntime.Cloud.cs.
public sealed partial class AppRuntime
{
  private CloudSecretsPlatform CloudSecretsPlatform() => new(
    (subject, deviceId) => new WindowsCloudSecretsSlots(Root, subject, deviceId),
    subject => Path.Combine(CloudAccountFolder(subject), "secrets"),
    CloudSecretStores);

  /// The travelling stores of this version, each under the delete rule (commit 2 of the lane adds them).
  private IReadOnlyList<ICloudSecretsStore> CloudSecretStores(string subject, string deviceId, Func<long?> serviceNow) => [];
}
