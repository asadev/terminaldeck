using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Platform.Windows.Servers;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private ServerSigninAttempts? serverSignin;
  public event Action<ServerSigninState>? ServerSigninChanged;
  public ServerSigninState? ReadServerSigninState(string serverId) => serverSignin?.State(serverId);
  private void InitializeServerSignin(WindowsOpenSshRuntime runtime)
  {
    var transport = new WindowsServerSigninTransport(runtime,
      request => Sessions.Any(s => s.Definition.Id == request.SessionId && s.State is SessionState.Starting or SessionState.Running && s.Definition.ServerId == request.Server.Id && s.Definition.ServerCodingTask?.AttemptId == request.Task.AttemptId),
      async (request, ct) =>
      {
        // A stale attempt can never stop a reused or unrelated terminal.
        var current = Sessions.FirstOrDefault(s => s.Definition.Id == request.SessionId);
        if (current?.Definition.ServerId == request.Server.Id && current.Definition.ServerCodingTask?.AttemptId == request.Task.AttemptId) await Keeper.StopAsync(request.SessionId, ct);
      },
      async (address, ct) =>
      {
        ct.ThrowIfCancellationRequested();
        // The operating-system URI broker opens only the validated provider URL;
        // no URL or OAuth state is written into a command line or app history.
        try { if (!await Windows.System.Launcher.LaunchUriAsync(address)) throw new IOException("Windows could not open the coding AI sign-in page."); }
        catch (System.Runtime.InteropServices.COMException) { throw new IOException("Windows could not open the coding AI sign-in page."); }
      });
    serverSignin = new((id, caller) => Servers.Get(id, caller), transport);
    serverSignin.Changed += OnServerSigninChanged;
    ((ServerService)Servers).SigninAttempts = serverSignin;
    ((ServerService)Servers).SettingsChanged += OnServerSigninServerChanged;
    Changed += OnServerSigninSessionsChanged;
  }
  private void OnServerSigninServerChanged(SavedServer server) => serverSignin?.ServerChanged(server);
  private void OnServerSigninSessionsChanged() => serverSignin?.RefreshSessions();
  private void OnServerSigninChanged(ServerSigninState state) { ServerSigninChanged?.Invoke(state); Changed?.Invoke(); }
  private async ValueTask DisposeServerSigninAsync()
  {
    if (serverSignin is not { } owner) return;
    serverSignin = null; owner.Changed -= OnServerSigninChanged;
    Changed -= OnServerSigninSessionsChanged;
    if (Servers is ServerService service) { service.SigninAttempts = null; service.SettingsChanged -= OnServerSigninServerChanged; }
    await owner.DisposeAsync();
  }
}
