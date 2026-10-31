using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserAddressCompletionTests
{
  [Theory] [InlineData("example", 15)] [InlineData("https://example", 15)]
  public void CompletesTheWholeVisitedHttpsUrlWithoutDroppingItsPath(string input, int caret)
  {
    var result = BrowserAddressCompletion.Complete(input, false, ["https://example.test/a/path?query=yes#part"]);
    Assert.NotNull(result); Assert.Equal("https://example.test/a/path?query=yes#part", result.Url); Assert.Equal(caret, result.SelectionStart); Assert.Equal(result.Url.Length - caret, result.SelectionLength);
  }
  [Fact] public void BackspaceAndDeleteNeverReinsertCompletion() => Assert.Null(BrowserAddressCompletion.Complete("example", true, ["https://example.test/a"]));
  [Fact] public void PreservesAnHttpVisitAndRejectsSearchTextAndUnsafeVisits()
  {
    Assert.Equal("http://localhost:5199/path", BrowserAddressCompletion.Complete("localhost", false, ["http://localhost:5199/path"])!.Url);
    Assert.Null(BrowserAddressCompletion.Complete("two words", false, ["https://two.test/words"]));
    Assert.Null(BrowserAddressCompletion.Complete("example", false, ["https://user:pass@example.test", "file:///example"]));
  }
}
