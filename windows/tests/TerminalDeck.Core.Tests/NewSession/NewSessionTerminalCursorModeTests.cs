using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.NewSession;

public sealed class NewSessionTerminalCursorModeTests
{
  private static SessionRecord Terminal(string replay) => new(
    new(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Own terminal replay"), "creation", SessionState.Running,
    Replay: replay, ReplaySize: new(137, 47));

  [Theory]
  [InlineData("\u001b[25l")]
  [InlineData("\u001b[25h")]
  [InlineData("\u001b[25l\u001b[25h")]
  public void Conpty_cursor_visibility_does_not_poison_a_later_empty_prompt(string cursorMode)
  {
    // Minimized from the own-session Claude 2.1.327 replay: mode 25 follows the
    // last full clear, then the prompt/status redraw ends at row 45, column 3.
    var replay = "\u001b[2J\u001b[HClaude Code\r\nPrevious answer\r\n" + cursorMode +
      "\u001b[45;1H>\u00a0\u001b[K\u001b[46;1H────────────────\u001b[47;1Hplan mode on\u001b[K\u001b[45;3H\u001b[?25h";
    Assert.Equal("/effort high\r", TerminalControls.Command(Terminal(replay), "effort", "high"));
  }

  [Theory]
  [InlineData("> unfinished draft")]
  [InlineData("> \r\nWorking… (esc to interrupt)")]
  [InlineData("> \r\nDo you want to proceed?")]
  public void Cursor_mode_never_makes_a_draft_working_turn_or_question_eligible(string content)
  {
    var replay = "\u001b[2J\u001b[25l\u001b[45;1H" + content + "\u001b[25h";
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal(replay), "effort", "high"));
  }

  [Theory]
  [InlineData("\u001b[4h")]
  [InlineData("\u001b[4l")]
  [InlineData("\u001b[20h")]
  [InlineData("\u001b[20l")]
  [InlineData("\u001b#8")]
  public void Other_unimplemented_modes_still_refuse_even_after_cursor_visibility_changes(string unsupported)
  {
    var replay = "\u001b[2J" + unsupported + "\u001b[25l\u001b[45;1H> \u001b[25h";
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal(replay), "effort", "high"));
  }
}
