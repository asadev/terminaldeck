using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Platform;

// Registry snapshots are supplied per check. A long-lived GUI must not rely on
// the PATH it inherited before the person installed their CLI.
public static class WindowsAiSearch
{
  public static Dictionary<string, string> EnvironmentNow(IReadOnlyDictionary<string, string> process,
    IReadOnlyDictionary<string, string> machine, IReadOnlyDictionary<string, string> user)
  {
    var result = new Dictionary<string, string>(process, StringComparer.OrdinalIgnoreCase);
    foreach (var (key, value) in machine.Concat(user)) if (!key.Equals("PATH", StringComparison.OrdinalIgnoreCase)) result[key] = value;
    string Expand(string text)
    {
      for (var i = 0; i < 8; i++)
      {
        var next = Regex.Replace(text, "%([^%]+)%", m => result.GetValueOrDefault(m.Groups[1].Value, m.Value));
        if (next == text) break;
        text = next;
      }
      return text;
    }
    foreach (var key in result.Keys.Where(key => !key.Equals("PATH", StringComparison.OrdinalIgnoreCase)).ToArray())
      result[key] = Expand(result[key]);
    result["PATH"] = string.Join(';', new[] { machine.GetValueOrDefault("PATH"), user.GetValueOrDefault("PATH"), process.GetValueOrDefault("PATH") }
      .Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => Expand(p!)));
    return result;
  }

  public static AiInstallSearch Create(IReadOnlyDictionary<string, string> environment, string tools,
    Func<string, IEnumerable<string>> children)
  {
    var home = environment.GetValueOrDefault("USERPROFILE", "");
    var roaming = environment.GetValueOrDefault("APPDATA", Path.Combine(home, "AppData", "Roaming"));
    var local = environment.GetValueOrDefault("LOCALAPPDATA", Path.Combine(home, "AppData", "Local"));
    var directories = new List<string> { tools };
    directories.AddRange(environment.GetValueOrDefault("PATH", "").Split(';', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Trim().Trim('"')));
    directories.AddRange([Path.Combine(home, ".local", "bin"), Path.Combine(roaming, "npm"),
      Path.Combine(local, "Microsoft", "WinGet", "Links"), Path.Combine(home, "scoop", "shims")]);
    foreach (var parent in new[] { Path.Combine(local, "Programs"), environment.GetValueOrDefault("ProgramFiles", ""), environment.GetValueOrDefault("ProgramFiles(x86)", "") }.Where(p => p.Length > 0))
      foreach (var name in new[] { "Claude", "Claude Code", "Codex", "Gemini", "nodejs" })
      { directories.Add(Path.Combine(parent, name)); directories.Add(Path.Combine(parent, name, "bin")); }
    foreach (var parent in new[] { Path.Combine(home, "scoop", "apps"), Path.Combine(environment.GetValueOrDefault("ProgramData", Path.Combine(home, "AppData")), "scoop", "apps") })
      foreach (var name in new[] { "claude", "claude-code", "codex", "gemini-cli", "nodejs", "nodejs-lts" })
      { directories.Add(Path.Combine(parent, name, "current")); directories.Add(Path.Combine(parent, name, "current", "bin")); }
    foreach (var parent in new[] { Path.Combine(local, "Microsoft", "WinGet", "Packages"), Path.Combine(environment.GetValueOrDefault("ProgramFiles", ""), "WinGet", "Packages") })
      foreach (var package in children(parent).Where(p => new[] { "Anthropic.ClaudeCode", "OpenAI.Codex", "Google.Gemini" }.Any(name => Path.GetFileName(p).StartsWith(name, StringComparison.OrdinalIgnoreCase))))
      { directories.Add(package); directories.Add(Path.Combine(package, "bin")); directories.AddRange(children(package)); }
    var paths = directories.Where(Path.IsPathFullyQualified).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    return new(paths, paths.Select(p => Path.Combine(p, "node_modules")).ToArray(), paths);
  }
}
