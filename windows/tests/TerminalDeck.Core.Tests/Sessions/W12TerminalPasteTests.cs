using TerminalDeck.Core.Sessions;
namespace TerminalDeck.Core.Tests.Sessions;
public sealed class W12TerminalPasteTests
{
  [Fact] public void PathsAreQuotedForTheActualShellWithoutAnAddedReturn()
  {
    Assert.Equal("'C:\\O''Brien\\notes.txt' 'C:\\two words.txt'", TerminalPaste.Paths(["C:\\O'Brien\\notes.txt", "C:\\two words.txt"], true));
    Assert.Equal("\"C:\\two words.txt\"", TerminalPaste.Paths(["C:\\two words.txt"], false));
    Assert.DoesNotContain('\r', TerminalPaste.Paths(["C:\\notes.txt"], true));
    Assert.Throws<ArgumentException>(() => TerminalPaste.Paths(["C:\\bad\nname"], true));
    Assert.Throws<ArgumentException>(() => TerminalPaste.Paths([], true));
  }
}
