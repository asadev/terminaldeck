using System.Globalization;
using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class WorkspaceTextTests
{
  [Theory]
  [InlineData("Chosen name", "person@example.test", "Chosen name")]
  [InlineData("person@example.test", "person@example.test", "person")]
  [InlineData(null, "person@example.test", "person")]
  public void HeaderAccountUsesTheChosenNameWithoutAnEmail(string? name, string email, string expected)
    => Assert.Equal(expected, WorkspaceText.AccountIdentity("claude", true, email, name));

  [Fact] public void FolderLocationKeepsItsPathAndOnlyShortensTheActualHome()
  {
    Assert.Equal("~\\Deck Dev", WorkspaceText.HomePath("C:\\Users\\Asad\\Deck Dev", "C:\\Users\\Asad"));
    Assert.Equal("D:\\Deck Dev", WorkspaceText.HomePath("D:\\Deck Dev", "C:\\Users\\Asad"));
    Assert.Equal("C:\\Users\\Asad2\\Deck Dev", WorkspaceText.HomePath("C:\\Users\\Asad2\\Deck Dev", "C:\\Users\\Asad"));
  }

  private static double Measure(string value) => new StringInfo(value).LengthInTextElements;
  [Fact] public void MiddlePathKeepsBothIdentityEndsWithoutCuttingAGrapheme()
  {
    const string path = "C:\\Projects\\Family 👨‍👩‍👧‍👦\\release.txt";
    var result = WorkspaceText.MiddlePath(path, 20, Measure);
    Assert.StartsWith("C:", result); Assert.EndsWith("release.txt", result); Assert.Contains("…", result); Assert.True(Measure(result) <= 20);
    Assert.Equal(path, WorkspaceText.MiddlePath(path, 100, Measure)); Assert.Equal("", WorkspaceText.MiddlePath(path, 0, Measure));
  }
}
