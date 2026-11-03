using TerminalDeck.Core.Servers;

namespace TerminalDeck.App.Views.Servers
{
  internal interface IServerSigninUiHost
  {
    ServerSigninState? ReadServerSigninState(string serverId);
    event Action<ServerSigninState>? ServerSigninChanged;
  }
}

namespace TerminalDeck.App.Views
{
  public sealed partial class ShellWindow : Servers.IServerSigninUiHost
  {
    ServerSigninState? Servers.IServerSigninUiHost.ReadServerSigninState(string serverId) => Runtime.ReadServerSigninState(serverId);
    event Action<ServerSigninState>? Servers.IServerSigninUiHost.ServerSigninChanged
    {
      add => Runtime.ServerSigninChanged += value;
      remove => Runtime.ServerSigninChanged -= value;
    }
  }
}
