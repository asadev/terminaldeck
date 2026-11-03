namespace TerminalDeck.Core.Accounts;

public static class AccountEnvironment
{
  public static Dictionary<string, string> Apply(string provider, string home, IReadOnlyDictionary<string, string> inherited)
  {
    var variable = provider switch { "claude" => "CLAUDE_CONFIG_DIR", "codex" => "CODEX_HOME", "gemini" => "GEMINI_CLI_HOME", _ => throw new ArgumentException("Choose a coding AI.") };
    var result = new Dictionary<string, string>(inherited, StringComparer.OrdinalIgnoreCase);
    foreach (var key in result.Keys.Where(name => new[] { "ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_", "GEMINI_", "GOOGLE_" }.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))).ToArray()) result.Remove(key);
    result[variable] = home;
    return result;
  }
}
