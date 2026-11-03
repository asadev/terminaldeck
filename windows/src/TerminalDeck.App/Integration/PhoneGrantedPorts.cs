using TerminalDeck.Core.Remote;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private PhoneLocalhostFeatures CreateGrantedPhonePorts(PhoneSessionsHost host)
  {
    var ownership = new WindowsPhonePorts(Root,
      device => Sessions.Where(s => host.Visible(device, s) && Remote.Grants.MayStartIn(device, s.Definition.Cwd)).ToArray(),
      device => Chats.List().Where(c => host.Visible(device, c) && Remote.Grants.MayStartIn(device, c.Definition.Cwd)).ToArray());
    return new(ownership.Allows, ReservedPhonePorts);
  }
}
