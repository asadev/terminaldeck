using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Sessions;
namespace TerminalDeck.Core.Tests.Hooks;
public sealed class ProviderHookProjectionTests
{
  [Theory] [InlineData("UserPromptSubmit", "working", "working")] [InlineData("PermissionRequest", "needs-input", "waiting")] [InlineData("Stop", "completed", "idle")] [InlineData("StopFailure", "failed", "waiting")]
  public void ActualHookEventsProjectToDesktopAndExistingPhoneStatusVocabulary(string eventName, string desktop, string phone)
  {
    var at = DateTimeOffset.UtcNow; var definition = new SessionDefinition(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Scratch");
    var session = new SessionRecord(definition, "key", SessionState.Running, CreatedAt: at.AddSeconds(-1).ToUnixTimeMilliseconds());
    var observed = new ProviderHookEvent("claude", eventName, definition.Id, null, definition.Cwd, at);
    Assert.Equal(desktop, ProviderHookProjection.Desktop(session, observed)); Assert.Equal(phone, ProviderHookProjection.Phone(session, observed));
    Assert.Null(ProviderHookProjection.Desktop(session with { State = SessionState.Exited }, observed));
    Assert.Null(ProviderHookProjection.Desktop(session, observed with { At = at.AddSeconds(-2) }));
    Assert.Null(ProviderHookProjection.Desktop(session, observed with { Provider = "codex" }));
    Assert.Null(ProviderHookProjection.Desktop(session with { Definition = definition with { Purpose = "sign-in" } }, observed));
  }
}
