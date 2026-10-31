namespace TerminalDeck.App.Shell;

public sealed record SessionStatus(string Glyph, string Label, string Brush)
{
  public static SessionStatus From(string state) => state.ToLowerInvariant() switch
  {
    "working" => new("\uE895", "Working", "AccentFillColorDefaultBrush"),
    "needs-input" or "needs attention" or "held" => new("\uE7BA", state == "held" ? "Held — needs a look" : "Needs your input", "DeckProjectOrangeBrush"),
    "failed" => new("\uEA39", "Failed", "DeckStatusFailedBrush"),
    "completed" => new("\uE73E", "Completed", "DeckProjectGreenBrush"),
    "ended" or "exited" => new("\uE73E", "Ended", "DeckInkBrush"),
    "starting" => new("\uE895", "Starting", "DeckProjectYellowBrush"),
    "running" => new("\uEA3A", "Running", "DeckProjectGreenBrush"),
    "chat" or "ready" => new("\uEA3A", "Ready", "DeckProjectGreenBrush"),
    _ => new("\uEA3A", "Draft", "DeckInkBrush")
  };
}
