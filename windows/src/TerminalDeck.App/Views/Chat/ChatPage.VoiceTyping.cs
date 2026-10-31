using Microsoft.UI.Xaml;
namespace TerminalDeck.App.Views.Chat;
public sealed partial class ChatPage
{
  private Task StartVoiceTypingAsync()
  {
    if (Model.Snapshot.Ended) return Task.CompletedTask;
    var sent = TerminalDeck.App.Shell.WindowsVoiceTyping.Start(composer);
    controlFeedback.Text = sent ? "Windows voice typing requested. Your words stay in the draft." : "Click in the message and press Win+H to open Windows voice typing.";
    controlFeedback.Visibility = Visibility.Visible;
    return Task.CompletedTask;
  }
}
