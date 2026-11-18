using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// Per-process only: no account, user, project or system configuration is edited.
public static class AgentAddonLaunch
{
  public static IReadOnlyList<string> Restrict(string provider, string home)
  {
    if (provider == "claude") return ["--strict-mcp-config", "--disable-slash-commands"];
    if (provider == "gemini") return ["--allowed-mcp-server-names", "deck-tools", "--extensions", "none"];
    if (provider != "codex") throw new InvalidOperationException("Extra add-ons cannot be excluded for this coding AI.");
    return CodexConfigured(home).Where(s => s != "deck-tools").Order(StringComparer.Ordinal).SelectMany(s => new[] { "-c", "mcp_servers." + s + ".enabled=false" }).ToArray();
  }
  public static IReadOnlySet<string> CodexConfigured(string home, string? folder = null)
  {
    var plugins = Path.Combine(home, "plugins");
    if (Directory.Exists(plugins) && Directory.EnumerateFileSystemEntries(plugins).Any())
      throw new InvalidOperationException("Codex plugin add-ons cannot be turned off for one session. Turn them off in Codex or keep Extra add-ons on.");
    var servers = new HashSet<string>(StringComparer.Ordinal);
    var paths = new List<string> { Path.Combine(home, "config.toml") };
    for (var cursor = folder is null ? null : new DirectoryInfo(Path.GetFullPath(folder)); cursor is not null; cursor = cursor.Parent)
    {
      if (paths.Count > 64) throw new IOException("There are too many inherited Codex config layers.");
      paths.Add(Path.Combine(cursor.FullName, ".codex", "config.toml"));
    }
    foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
      if (File.Exists(path)) servers.UnionWith(Configured(FileText(path)));
    return servers;
  }
  private static string FileText(string config)
  {
    if (new FileInfo(config).Length > 4 * 1024 * 1024 || File.GetAttributes(config).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("The coding AI's add-on configuration cannot be checked safely.");
    return File.ReadAllText(config);
  }
  private static IReadOnlySet<string> Configured(string text)
  {
    if (Regex.IsMatch(text, @"(?m)^\s*\[+plugins(?:\.|\])")) throw new InvalidOperationException("Codex plugin add-ons cannot be turned off for one session. Turn them off in Codex or keep Extra add-ons on.");
    var servers = new HashSet<string>(StringComparer.Ordinal);
    foreach (Match section in Regex.Matches(text, @"(?m)^\s*\[mcp_servers\.([^\]\r\n]+)\]"))
    {
      var raw = section.Groups[1].Value.Trim();
      string name;
      if (raw.StartsWith('"'))
      {
        var quoted = Regex.Match(raw, "^\"(?:[^\"\\\\]|\\\\.)*\"");
        if (!quoted.Success) throw new InvalidOperationException("A Codex MCP server name could not be read.");
        name = JsonSerializer.Deserialize<string>(quoted.Value) ?? "";
      }
      else if (raw.StartsWith('\'')) { var end = raw.IndexOf('\'', 1); if (end < 0) throw new InvalidOperationException("A Codex MCP server name could not be read."); name = raw[1..end]; }
      else name = raw.Split('.')[0].Trim();
      if (!Regex.IsMatch(name, "^[A-Za-z0-9_-]+$")) throw new InvalidOperationException("An MCP server name cannot be restricted for one Codex session.");
      servers.Add(name);
    }
    if (text.Contains("mcp_servers", StringComparison.Ordinal) && servers.Count == 0) throw new InvalidOperationException("This Codex MCP configuration cannot be restricted for one session.");
    return servers;
  }

  public static IReadOnlyList<string> OwnTools(AppDataRoot root, string provider, string sessionId)
  {
    var executable = Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe");
    if (!File.Exists(executable)) throw new IOException("The app's own tools are unavailable. Keep these settings and repair this installation before starting the agent.");
    var args = new[] { "--root", root.DirectoryPath, "--chat", sessionId };
    if (provider == "claude")
    {
      var folder = Path.Combine(root.DirectoryPath, "mcp", "agent-launch"); WindowsPrivateDirectory.Ensure(folder);
      var file = Path.Combine(folder, sessionId + ".json");
      File.WriteAllText(file, JsonSerializer.Serialize(new { mcpServers = new Dictionary<string, object> { ["deck-tools"] = new { command = executable, args } } }));
      return ["--mcp-config", file];
    }
    if (provider == "codex") return ["-c", "mcp_servers.deck-tools.command=" + JsonSerializer.Serialize(executable), "-c", "mcp_servers.deck-tools.args=" + JsonSerializer.Serialize(args)];
    if (provider == "gemini")
    {
      // Gemini reads the supplied MCP definition in addition to its normal settings; allowed-mcp-server-names fences the others.
      return [];
    }
    throw new InvalidOperationException("This coding AI has no app-tools launch adapter.");
  }
}

public static class AgentGeminiTools
{
  public static IReadOnlyDictionary<string, string> EnvironmentFor(AppDataRoot root, string id, IReadOnlyDictionary<string, string> environment, bool addonsOff)
  {
    var executable = Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe");
    if (!File.Exists(executable)) throw new IOException("The app's own tools are unavailable in this installation.");
    var original = environment.GetValueOrDefault("GEMINI_CLI_SYSTEM_SETTINGS_PATH") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "gemini-cli", "settings.json");
    var defaults = environment.GetValueOrDefault("GEMINI_CLI_SYSTEM_DEFAULTS_PATH") ?? Path.Combine(Path.GetDirectoryName(original)!, "system-defaults.json");
    System.Text.Json.Nodes.JsonObject config;
    if (File.Exists(original))
    {
      if (new FileInfo(original).Length > 4 * 1024 * 1024 || File.GetAttributes(original).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Gemini's system settings cannot be checked safely.");
      config = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllBytes(original), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })?.AsObject() ?? throw new IOException("Gemini's system settings could not be read.");
    }
    else config = new();
    if (config["mcp"] is not null and not System.Text.Json.Nodes.JsonObject || config["mcpServers"] is not null and not System.Text.Json.Nodes.JsonObject) throw new IOException("Gemini's system MCP policy cannot be read safely.");
    var mcp = config["mcp"] as System.Text.Json.Nodes.JsonObject ?? new();
    if (mcp["allowed"] is not null and not System.Text.Json.Nodes.JsonArray || mcp["excluded"] is not null and not System.Text.Json.Nodes.JsonArray) throw new IOException("Gemini's MCP restrictions cannot be read safely.");
    if (mcp["allowed"] is System.Text.Json.Nodes.JsonArray allowed && !allowed.Any(n => n?.GetValue<string>() == "deck-tools")
      || mcp["excluded"] is System.Text.Json.Nodes.JsonArray excluded && excluded.Any(n => n?.GetValue<string>() == "deck-tools")) throw new InvalidOperationException("Gemini's system policy does not allow this app's tools.");
    var servers = config["mcpServers"] as System.Text.Json.Nodes.JsonObject ?? new();
    if (servers.ContainsKey("deck-tools")) throw new InvalidOperationException("Gemini's system policy already defines deck-tools. Keep that policy unchanged and resolve the name before starting this agent.");
    servers["deck-tools"] = JsonSerializer.SerializeToNode(new { command = executable, args = new[] { "--root", root.DirectoryPath, "--chat", id } });
    if (addonsOff) mcp["allowed"] = new System.Text.Json.Nodes.JsonArray("deck-tools");
    if (config["mcp"] is null) config["mcp"] = mcp;
    if (config["mcpServers"] is null) config["mcpServers"] = servers;
    var folder = Path.Combine(root.DirectoryPath, "mcp", "agent-launch"); WindowsPrivateDirectory.Ensure(folder);
    var file = Path.Combine(folder, id + "-gemini.json"); File.WriteAllText(file, config.ToJsonString());
    var result = new Dictionary<string, string>(environment, StringComparer.OrdinalIgnoreCase)
    { ["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = file, ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"] = defaults };
    return result;
  }
}
