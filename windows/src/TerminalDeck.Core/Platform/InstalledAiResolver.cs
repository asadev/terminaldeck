namespace TerminalDeck.Core.Platform;

public sealed class ProviderUnavailableException(string message) : IOException(message);

public sealed record AiInstallSearch(string[] Directories, string[] PackageRoots, string[] NodeDirectories);

// Resolve supported layouts, never execute a .cmd/.ps1 through a shell. npm's
// known package entry points get Node plus a separate, safely quoted argv.
public static class InstalledAiResolver
{
  public static (string Executable, string[] Prefix) Resolve(string provider, AiInstallSearch search)
  {
    if (provider is not ("claude" or "codex" or "gemini")) throw new ArgumentException("Choose an installed AI.");
    foreach (var directory in search.Directories.Distinct(StringComparer.OrdinalIgnoreCase))
    {
      var executable = Path.Combine(directory, provider + ".exe");
      if (File.Exists(executable)) return (executable, []);
    }
    var nativePaths = provider switch
    {
      "claude" => new[] { "@anthropic-ai/claude-code/bin/claude.exe", "@anthropic-ai/claude-code-win32-x64/claude.exe" },
      "codex" => new[] {
        "@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe",
        "@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe",
        "@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe",
        "@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe" },
      _ => Array.Empty<string>()
    };
    var roots = search.PackageRoots.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    foreach (var root in roots)
      foreach (var relative in nativePaths)
      {
        var executable = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(executable)) return (executable, []);
      }
    var node = search.NodeDirectories.Concat(search.Directories).Distinct(StringComparer.OrdinalIgnoreCase)
      .Select(directory => Path.Combine(directory, "node.exe")).FirstOrDefault(File.Exists);
    var entries = provider switch
    {
      "claude" => new[] { "@anthropic-ai/claude-code/cli.js" },
      "codex" => new[] { "@openai/codex/bin/codex.js" },
      _ => new[] { "@google/gemini-cli/dist/index.js", "@google/gemini-cli/bundle/gemini.js" }
    };
    if (node is not null)
      foreach (var root in roots)
        foreach (var relative in entries)
        {
          var entry = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
          if (File.Exists(entry)) return (node, [entry]);
        }
    var name = provider == "claude" ? "Claude Code" : provider == "codex" ? "Codex" : "Gemini CLI";
    throw new ProviderUnavailableException($"{name} isn’t installed. Install it from Coding AIs.");
  }
}
