using TerminalDeck.Core.Code;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// GUI launches resolve the same bundled/user-installed CLI as real sessions;
// they do not assume that an interactive terminal's PATH is visible here.
public sealed class ReadinessProcessRunner(AppDataRoot root) : ICodeProcessRunner
{
  public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
  {
    if (executable is not ("claude" or "codex" or "gemini")) return new CodeProcessRunner().RunAsync(executable, arguments, workingDirectory, timeout, ct, input);
    try
    {
      var launch = new WindowsProviderLaunchPlanner(root, WindowsProviderLaunchPlanner.BundledToolsDirectory).Resolve(executable, arguments, Accounts.WindowsAiEnvironment.Read(), workingDirectory);
      return new CodeProcessRunner(launch.Environment.ToDictionary(k => k.Key, v => (string?)v.Value)).RunAsync(launch.Executable, launch.Arguments, workingDirectory, timeout, ct, input);
    }
    catch (IOException) { return Task.FromResult(new CodeProcessResult(-1, "", "", Missing: true)); }
  }
}
