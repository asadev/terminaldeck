using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  // This runs only for a fresh browser key admitted by an explicit desktop click.
  // Reopening an existing browser never overwrites its selected projects or Hoot.
  private void EnrollWebWorkspace(string deviceId) => SetPhoneWorkspace(deviceId,
    Projects.List().Where(p => p.IsOpen).Select(p => p.Id).ToArray(),
    Hoot.Read().Settings is not null, PhoneAccess.Full);
}
