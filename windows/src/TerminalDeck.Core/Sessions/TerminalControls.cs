using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Sessions;

// Terminal choices are CLI commands, not edits to the saved launch definition.
// Keep this gate shared by the desktop header and the existing MCP controls.
public static partial class TerminalControls
{
  public static string? Unavailable(SessionRecord row)
  {
    if (row.State != SessionState.Running) return "This session is not running.";
    if (row.Definition.Purpose is not null || row.Definition.ServerId is not null || row.Definition.Provider == "shell") return "There is no coding AI control in this terminal.";
    if (row.Definition.Provider != "claude") return "Change model and effort in this coding AI's own terminal menu.";
    // Only an empty prompt can accept a command. A prompt with a draft, an
    // approval question or an old prompt followed by output must never receive it.
    return TerminalControlScreen.AtEmptyPrompt(row) ? null : "Wait for Claude's empty prompt before changing its controls. Your typed text is kept.";
  }

  public static string Command(SessionRecord row, string control, string value)
  {
    if (Unavailable(row) is { } reason) throw new InvalidOperationException(reason);
    return control switch
    {
      "model" when ModelId().IsMatch(value) => "/model " + value + "\r",
      "effort" when value is "low" or "medium" or "high" or "xhigh" or "max" => "/effort " + value + "\r",
      "fast" when value is "on" or "off" => "/fast " + value + "\r",
      _ => throw new ArgumentException("Choose an offered model, effort or fast-mode value.")
    };
  }

  [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._\-\[\]]{0,127}$")]
  private static partial Regex ModelId();
}
