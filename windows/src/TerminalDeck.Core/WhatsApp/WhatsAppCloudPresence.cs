using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.WhatsApp;

/// The presence door on Windows (the Mac's NativeWhatsAppPresence): this PC and the account's other computers from the
/// Cloud account's device list (its id, name and last-seen time). Signed out: this PC by its own name, and nobody else
/// is known (so no take-over happens, as on the Mac: a computer the account does not list is never taken over from).
public sealed class WhatsAppCloudPresence(Func<CloudSnapshot> snapshot, string? machineName = null) : IWhatsAppPresencePort
{
  private readonly string machine = machineName ?? Environment.MachineName;

  public WhatsAppComputer ThisComputer()
  {
    var now = snapshot();
    // Lower case, as the Mac writes device ids into the record.
    var id = now.ThisDeviceId is { Length: > 0 } d ? d.ToLowerInvariant() : "pc:" + machine.ToLowerInvariant();
    var name = now.ThisDeviceName is { Length: > 0 } n ? n : now.DeviceRows.FirstOrDefault(r => r.ThisDevice)?.Name ?? machine;
    return new WhatsAppComputer(id, name);
  }
  public Task<DateTimeOffset?> LastSeenAsync(string computerId) =>
    Task.FromResult(snapshot().DeviceRows.FirstOrDefault(r => string.Equals(r.DeviceId, computerId, StringComparison.OrdinalIgnoreCase))?.LastSeen);
  public Task<string?> NameAsync(string computerId) =>
    Task.FromResult(snapshot().DeviceRows.FirstOrDefault(r => string.Equals(r.DeviceId, computerId, StringComparison.OrdinalIgnoreCase))?.Name);
}
