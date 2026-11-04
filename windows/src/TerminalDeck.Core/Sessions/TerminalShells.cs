namespace TerminalDeck.Core.Sessions;

// The shells a terminal tab can run on Windows. Settings → General picks one for
// new terminal tabs and each session keeps the one it started with. Null means
// Windows PowerShell for saved sessions; new user-created terminals resolve the
// configured preference before reaching the keeper.
public static class TerminalShells
{
  public const string WindowsPowerShell = "powershell", PowerShell7 = "pwsh", CommandPrompt = "cmd";
  public static string[] All { get; } = [WindowsPowerShell, PowerShell7, CommandPrompt];
  public static bool IsKnown(string? shell) => shell is null || All.Contains(shell);
  // Tab titles and sidebar subtitles. Windows PowerShell keeps its original "PowerShell".
  public static string Label(string? shell) => shell switch { PowerShell7 => "PowerShell 7", CommandPrompt => "Command Prompt", _ => "PowerShell" };
  // The settings list names Windows PowerShell in full, to tell it from PowerShell 7.
  public static string Name(string? shell) => shell is null or WindowsPowerShell ? "Windows PowerShell" : Label(shell);
}
