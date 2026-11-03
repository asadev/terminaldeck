using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Sessions;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public string? HookDesktopStatus(SessionRecord session) => ProviderHookProjection.Desktop(session, HookSessionEvents.GetValueOrDefault(session.Definition.Id));
  public string? HookPhoneStatus(SessionRecord session) => ProviderHookProjection.Phone(session, HookSessionEvents.GetValueOrDefault(session.Definition.Id));
}
