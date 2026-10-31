using TerminalDeck.Platform.Windows.Receiver;

namespace TerminalDeck.Chat.Windows.Tests;

public sealed class ReceiverArtifactOpenerTests
{
  [Theory]
  [InlineData("script.js")]
  [InlineData("script.py")]
  [InlineData("source.html")]
  public void ScriptOpenUsesFixedWindowsEditorWithOneLiteralFileArgument(string name)
  {
    var path = Path.Combine(@"C:\TD\scratch", "space & text", name);
    var start = WindowsArtifactOpener.TextEditorStartInfo(path);
    Assert.Equal(Path.Combine(Environment.SystemDirectory, "notepad.exe"), start.FileName);
    Assert.False(start.UseShellExecute); Assert.Equal(path, Assert.Single(start.ArgumentList)); Assert.Equal("", start.Arguments);
    Assert.Throws<ArgumentException>(() => WindowsArtifactOpener.TextEditorStartInfo(@"C:\TD\scratch\program.exe"));
    Assert.Throws<ArgumentException>(() => WindowsArtifactOpener.TextEditorStartInfo(@"C:\TD\scratch\photo.png"));
  }
}
