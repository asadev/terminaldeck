using TerminalDeck.Core.Hoot;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatPage
{
  public Func<ConversationHandoffRequest, Task>? HandoffRequested { get; init; }
  private async Task HandoffMessageAsync(TerminalDeck.Core.Chats.ChatRow row)
  {
    if (HandoffRequested is null) return;
    try { await HandoffRequested(ConversationHandoff.Through(Model.Snapshot, row.Id, row.Kind)); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
    { controlFeedback.Text = ex.Message; controlFeedback.Visibility = Microsoft.UI.Xaml.Visibility.Visible; }
  }
}
