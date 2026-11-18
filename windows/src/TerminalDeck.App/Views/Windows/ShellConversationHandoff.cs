using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Hoot;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task StartConversationHandoffAsync(ConversationHandoffRequest request)
  {
    if (hootPage is null) throw new InvalidOperationException("Hoot is still starting. Try Handoff again in a moment.");
    var turnId = Guid.NewGuid().ToString();
    // Hoot's background owner checks readiness. A handoff never changes Hoot's settings.
    Model.Page = ShellPage.Hoot; hootPage.OpenHandoffDocument(turnId);
    try { await Runtime.Hoot.BackgroundTurnAsync(turnId, "handoff", request.SessionId, request.Title, request.Prompt); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { hootPage.FailHandoffDocument(ex.Message); }
  }
}
