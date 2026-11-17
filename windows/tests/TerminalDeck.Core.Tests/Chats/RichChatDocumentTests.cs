using System.Text;
using TerminalDeck.App.Views.Chat;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class RichChatDocumentTests
{
  [Fact]
  public void Own_unicode_document_can_navigate_and_send_native_messages()
  {
    const string html = "<!doctype html><main>Hello ❯ مرحبا</main>";
    var source = RichChatDocument.Source(html);
    Assert.Equal(html, Encoding.UTF8.GetString(Convert.FromBase64String(source[(source.IndexOf(',') + 1)..])));
    Assert.True(RichChatDocument.AllowsNavigation(source, source));
    Assert.True(RichChatDocument.IsMessageSource(source, source));
    Assert.True(RichChatDocument.AllowsNavigation("about:blank", source));
    Assert.True(RichChatDocument.IsMessageSource("about:blank", source));
  }

  [Theory]
  [InlineData("data:text/html,<script>untrusted</script>")]
  [InlineData("https://rich-chat.deck.invalid/chat.js")]
  [InlineData("https://example.com")]
  [InlineData("about:srcdoc")]
  [InlineData("javascript:alert(1)")]
  public void Other_documents_cannot_navigate_the_host_or_send_native_messages(string source)
  {
    var expected = RichChatDocument.Source("<main>Trusted message</main>");
    Assert.False(RichChatDocument.AllowsNavigation(source, expected));
    Assert.False(RichChatDocument.IsMessageSource(source, expected));
    Assert.False(RichChatDocument.IsMessageSource("", ""));
  }
}
