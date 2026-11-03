using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class SessionStatusTests
{
  [Fact] public void ReadyRunningAndInputNeededAreDistinctTruthfulStates()
  {
    Assert.Equal("Running", SessionStatus.From("running").Label);
    Assert.Equal("Ready", SessionStatus.From("ready").Label);
    Assert.Equal("Needs your input", SessionStatus.From("needs-input").Label);
    Assert.NotEqual(SessionStatus.From("ready").Glyph, SessionStatus.From("needs-input").Glyph);
    Assert.Equal("Ended", SessionStatus.From("exited").Label);
  }
}
