using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  private const string PairedProfilePrefix = "paired:";
  private static string PairedProfileId(string id) => id.StartsWith(PairedProfilePrefix, StringComparison.Ordinal) && id.Length > PairedProfilePrefix.Length
    ? id[PairedProfilePrefix.Length..] : throw new ArgumentException("Choose a paired device.");

  private ProfileDeviceActions ProfilePairedDevices() => new(
    () => runtime.Remote.Trust.List().Where(device => !runtime.Cloud.Snapshot.DeviceRows.Any(row => row.DeviceId == device.Id))
      .Select(device => new CloudDeviceRow(PairedProfilePrefix + device.Id, device.Name, false, device.PairedAt,
        device.Connected ? DateTimeOffset.UtcNow : device.LastSeen, Platform: device.Platform)).ToArray(),
    (id, name) => { runtime.Remote.Trust.Rename(PairedProfileId(id), name); return Task.CompletedTask; },
    id => { runtime.Remote.Trust.Revoke(PairedProfileId(id)); return Task.CompletedTask; },
    id => { var device = runtime.Remote.Trust.List().FirstOrDefault(row => row.Id == PairedProfileId(id)); if (device is not null) _ = ShowPhoneWorkspaceAsync(device); });
}
