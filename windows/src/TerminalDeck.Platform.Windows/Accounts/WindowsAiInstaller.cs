using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Accounts;

public static class WindowsAiInstaller
{
  public static string Command(string provider) => provider switch
  {
    "claude" => "irm https://claude.ai/install.ps1 | iex",
    "codex" => "npm install -g @openai/codex",
    "gemini" => "npm install -g @google/gemini-cli",
    _ => throw new ArgumentException("Choose a coding AI.")
  };
  public static ProcessLaunch Plan(string provider, AppDataRoot root, string homeId)
  {
    _ = Command(provider);
    var home = new WindowsProviderLaunchPlanner(root, WindowsProviderLaunchPlanner.BundledToolsDirectory).AccountHome(provider, homeId);
    if (homeId != AccountHomes.ExistingLogin) WindowsPrivateDirectory.Ensure(home);
    var cwd = root.DirectoryPath;
    var environment = AccountEnvironment.Apply(provider, home, WindowsAiEnvironment.Read());
    if (provider == "claude") return new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
      ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", Command(provider)], environment, cwd);
    var search = WindowsAiEnvironment.Search(WindowsProviderLaunchPlanner.BundledToolsDirectory, environment);
    var node = search.NodeDirectories.Select(p => Path.Combine(p, "node.exe")).FirstOrDefault(File.Exists);
    var npm = search.Directories.SelectMany(p => new[] { Path.Combine(p, "node_modules", "npm", "bin", "npm-cli.js"), Path.Combine(p, "..", "node_modules", "npm", "bin", "npm-cli.js") }).FirstOrDefault(File.Exists);
    if (node is null || npm is null) throw new ProviderUnavailableException("Install Node.js LTS from nodejs.org, then try Install again. This AI’s official Windows installer uses npm.");
    return new(node, [npm, "install", "-g", provider == "codex" ? "@openai/codex" : "@google/gemini-cli"], environment, cwd);
  }
}
