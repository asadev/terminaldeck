using System.Text;

namespace TerminalDeck.App.Views.Chat;

internal static class RichChatDocument
{
  // WinUI's NavigateToString uses a data URI, rather than the about:blank used
  // by the other WebView2 projection. Name our document explicitly so navigation
  // and native messages can both be checked against the exact trusted source.
  internal static string Source(string html) => "data:text/html;charset=utf-8;base64," + Convert.ToBase64String(Encoding.UTF8.GetBytes(html));
  // WinUI reports the committed string document's messages as about:blank even
  // though NavigationStarting names its data URI. The per-document token is
  // still required by RichChatWebView before it handles any native message.
  internal static bool IsMessageSource(string source, string expected) => expected.Length > 0 && (source == "about:blank" || string.Equals(source, expected, StringComparison.Ordinal));
  internal static bool AllowsNavigation(string source, string expected) => source == "about:blank" || IsMessageSource(source, expected);
}
