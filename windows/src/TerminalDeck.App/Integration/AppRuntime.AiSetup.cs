using TerminalDeck.Core.AiSetup;

namespace TerminalDeck.App.Integration;

/// ONE SETUP FOR EVERY AI (Asad, 19 Nov 2026): a project's skills, rule files, agents and guards are kept the same for
/// Claude, Codex and Gemini (AiSetupKeeper, the Mac's BackendAISetupKeeper). It runs when a session or chat opens in a
/// project (in the background, at most once per project every 5 s) and before the Cloud looks at a project's instruction
/// files. No watcher, no timer, no question. Each change is one line in `logs\ai-setup.log` of this copy's data folder.
public sealed partial class AppRuntime
{
  private readonly object aiSetupLogGate = new();

  private void OpeningInFolder(string folder)
  {
    AiSetupKeeper.Log ??= WriteAiSetupLog;
    AiSetupKeeper.AlignSoon(folder);
  }

  private void AlignAiSetup(string projectFolder)
  {
    AiSetupKeeper.Log ??= WriteAiSetupLog;
    // The Cloud's look goes on whatever happens here: a fault is one log line, never a stopped sync.
    try { AiSetupKeeper.Align(projectFolder); }
    catch (Exception e) { WriteAiSetupLog("AI setup: the project could not be aligned: " + e.GetType().Name + ": " + e.Message); }
  }

  private void WriteAiSetupLog(string line)
  {
    try
    {
      lock (aiSetupLogGate)
      {
        var logs = Path.Combine(Root.DirectoryPath, "logs");
        Directory.CreateDirectory(logs);
        File.AppendAllText(Path.Combine(logs, "ai-setup.log"), DateTimeOffset.UtcNow.ToString("O") + " " + line + Environment.NewLine);
      }
    }
    // A line that cannot be written is dropped: the log has nowhere else to say so (as cloud.log).
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }
}
