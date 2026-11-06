using Microsoft.UI.Xaml;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

internal static class ChatMarkdownView
{
  public static FrameworkElement Render(string text, Action<string> copy, Action<string> error, string? folder = null, string? dataDirectory = null) =>
    new RichChatWebView(ChatRichContent.Html(text, folder), copy, error, dataDirectory);
}
