using System.Globalization;
using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class WorkspaceTextTests
{
  private static double Measure(string value) => new StringInfo(value).LengthInTextElements;
  [Fact] public void MiddlePathKeepsBothIdentityEndsWithoutCuttingAGrapheme()
  {
    const string path = "C:\\Projects\\Family 👨‍👩‍👧‍👦\\release.txt";
    var result = WorkspaceText.MiddlePath(path, 20, Measure);
    Assert.StartsWith("C:", result); Assert.EndsWith("release.txt", result); Assert.Contains("…", result); Assert.True(Measure(result) <= 20);
    Assert.Equal(path, WorkspaceText.MiddlePath(path, 100, Measure)); Assert.Equal("", WorkspaceText.MiddlePath(path, 0, Measure));
  }
}
