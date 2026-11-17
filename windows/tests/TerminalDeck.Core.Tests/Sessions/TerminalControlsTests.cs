using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class TerminalControlsTests
{
  private static SessionRecord Terminal(string replay, string provider = "claude", SessionState state = SessionState.Running) =>
    new(new(Guid.NewGuid().ToString(), provider, @"C:\work", "Control test"), "test", state, Replay: replay);

  [Theory]
  [InlineData("❯ ")]
  [InlineData("\u001b[32m❯ \u001b[0m")]
  [InlineData("Previous reply\r\n────────────────\r\n❯ \u001b7\r\n────────────────\r\n  ? for shortcuts\u001b8")]
  public void Sends_cli_commands_only_at_empty_prompt(string screen)
  {
    Assert.Equal("/model claude-opus-5-5[1m]\r", TerminalControls.Command(Terminal(screen), "model", "claude-opus-5-5[1m]"));
    Assert.Equal("/effort xhigh\r", TerminalControls.Command(Terminal(screen), "effort", "xhigh"));
    Assert.Equal("/fast off\r", TerminalControls.Command(Terminal(screen), "fast", "off"));
  }

  [Theory]
  [InlineData("❯ unfinished draft")]
  [InlineData("❯ \r\nWorking… (esc to interrupt)")]
  [InlineData("❯ \r\nDo you want to proceed?")]
  [InlineData("Shell > ")]
  public void Refuses_drafts_busy_output_and_approval_questions(string screen) =>
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal(screen), "model", "opus"));

  [Fact]
  public void Uses_current_cursor_line_after_full_screen_redraw()
  {
    var replay = "❯ old draft\u001b[2J\u001b[HClaude Code\u001b[10;1H❯ \u001b[s\u001b[12;1H⏵⏵ auto mode on\u001b[u";
    Assert.Equal("/effort high\r", TerminalControls.Command(Terminal(replay), "effort", "high"));
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal(replay + "typed"), "effort", "high"));
    Assert.Equal("/effort high\r", TerminalControls.Command(Terminal(replay + "typed\u001b[10;3H\u001b[K"), "effort", "high"));
  }

  [Fact]
  public void Handles_conpty_scroll_regions_and_line_erases()
  {
    var replay = "\u001b[2J\u001b[1;20r\u001b[20;1HWorking\r\nDone\u001b[1S\u001b[18;1H❯ draft\u001b[18;3H\u001b[K\u001b[?25h";
    Assert.Equal("/model opus\r", TerminalControls.Command(Terminal(replay), "model", "opus"));
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal(replay + "draft\u001b[18;3H"), "model", "opus"));
  }

  [Theory]
  [InlineData("codex", SessionState.Running)]
  [InlineData("gemini", SessionState.Running)]
  [InlineData("shell", SessionState.Running)]
  [InlineData("claude", SessionState.Exited)]
  public void Refuses_unsupported_and_ended_sessions(string provider, SessionState state) =>
    Assert.Throws<InvalidOperationException>(() => TerminalControls.Command(Terminal("❯ ", provider, state), "effort", "high"));

  [Theory]
  [InlineData("model", "opus\rmalicious")]
  [InlineData("model", "../opus")]
  [InlineData("effort", "ultra")]
  [InlineData("fast", "maybe")]
  [InlineData("permission", "bypass")]
  public void Refuses_unoffered_commands_and_control_characters(string control, string value) =>
    Assert.Throws<ArgumentException>(() => TerminalControls.Command(Terminal("❯ "), control, value));
}
