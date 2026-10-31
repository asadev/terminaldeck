using System.Text.Json;

namespace TerminalDeck.Core.Chats;

// The composer's "/" menu (Mac: HootSlashCommand). Typing "/" lists what this
// session can run: the AI's own reported commands (Claude's init slash_commands,
// with built-ins, plugins and loaded skills) plus the team's skills and commands
// on disk (project .claude, extra folders' skills, the account's own .claude),
// so /wrap and /catchup show before the first answer too. Sending "/name args"
// runs it in the AI; a few names open the app's own control instead.
public sealed record ChatSlashCommand(string Name, string Description = "", string ArgumentHint = "", string Source = "", string? Control = null);

public static class ChatSlashCommands
{
  // Only a terminal screen of the CLI's own: nothing to run in a chat (Mac list).
  public static readonly IReadOnlySet<string> TerminalOnly = new HashSet<string>(StringComparer.Ordinal) { "theme", "terminal-setup", "vim", "ide", "statusline", "upgrade", "hooks",
    "mcp", "agents", "memory", "bashes", "export", "privacy-settings", "exit", "quit", "rewind", "output-style",
    "install-github-app", "migrate-installer", "add-dir", "resume", "keybindings", "plugin" };
  // The app's own control for the same thing: picking it opens that control.
  public static readonly IReadOnlyDictionary<string, string> AppControls = new Dictionary<string, string>(StringComparer.Ordinal)
  { ["model"] = "model", ["effort"] = "effort", ["reasoning"] = "effort", ["permissions"] = "permission", ["approve"] = "permission" };
  private static readonly IReadOnlyDictionary<string, string> ControlNames = new Dictionary<string, string>(StringComparer.Ordinal)
  { ["model"] = "Opens the model picker", ["effort"] = "Opens the effort picker", ["permission"] = "Opens chat permissions" };
  // Claude's init list carries names only; these short lines describe its common built-ins.
  private static readonly IReadOnlyDictionary<string, string> BuiltIn = new Dictionary<string, string>(StringComparer.Ordinal)
  {
    ["clear"] = "Clear the conversation and start fresh", ["compact"] = "Summarise the conversation to free context",
    ["context"] = "Show what is using the context window", ["cost"] = "Show this session's cost", ["usage"] = "Show plan usage and limits",
    ["init"] = "Create a CLAUDE.md guide for this folder", ["review"] = "Review a pull request", ["code-review"] = "Review the current changes",
    ["security-review"] = "Security review of the pending changes", ["pr-comments"] = "Read a pull request's comments",
    ["release-notes"] = "Show the release notes", ["doctor"] = "Check the AI's installation", ["help"] = "List what the AI can do",
    ["status"] = "Show account and session status", ["config"] = "Show settings", ["rename"] = "Rename this conversation",
    ["recap"] = "Recap this session", ["simplify"] = "Simplify the recent changes", ["debug"] = "Debug a problem", ["loop"] = "Run a prompt on a repeat",
    ["schedule"] = "Schedule a recurring agent", ["fast"] = "Toggle fast mode", ["insights"] = "Show session insights", ["todos"] = "Show the to-do list",
  };

  public static IReadOnlyList<ChatSlashCommand> Catalogue(string provider, JsonElement? reportedFields, string? cwd, IReadOnlyList<string> extraFolders, string? userConfigDir)
  {
    var rows = new List<ChatSlashCommand>(); var seen = new HashSet<string>(StringComparer.Ordinal);
    void Add(ChatSlashCommand row)
    {
      if (row.Name.Length == 0 || TerminalOnly.Contains(row.Name) || !seen.Add(row.Name)) return;
      rows.Add(AppControls.TryGetValue(row.Name, out var control) ? row with { Control = control, Description = ControlNames[control] } : row);
    }
    var reported = Reported(reportedFields);
    var disk = provider == "claude" ? Disk(cwd, extraFolders, userConfigDir) : [];
    var reportedByName = reported.GroupBy(r => r.Name).ToDictionary(g => g.Key, g => g.First());
    // Team commands first (project, then the account's own), then everything else the AI reported.
    foreach (var row in disk)
      Add(reportedByName.TryGetValue(row.Name, out var said) && said.Description.Length > 0 && row.Description.Length == 0 ? row with { Description = said.Description } : row);
    foreach (var row in reported) Add(row.Description.Length > 0 ? row : row with { Description = BuiltIn.GetValueOrDefault(row.Name, "") });
    return rows;
  }

  // Claude reports names (strings); a richer handshake or Gemini reports objects.
  public static IReadOnlyList<ChatSlashCommand> Reported(JsonElement? fields)
  {
    if (fields is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty("slash_commands", out var list) || list.ValueKind != JsonValueKind.Array) return [];
    var rows = new List<ChatSlashCommand>();
    foreach (var item in list.EnumerateArray().Take(1000))
    {
      if (item.ValueKind == JsonValueKind.String) { var name = Clean(item.GetString()); if (name is not null) rows.Add(new(name, Source: "ai")); continue; }
      if (item.ValueKind != JsonValueKind.Object) continue;
      if (Clean(ChatLineProtocol.S(item, "name")) is not { } named || ChatLineProtocol.P(item, "terminalOnly").ValueKind == JsonValueKind.True) continue;
      rows.Add(new(named, OneLine(ChatLineProtocol.S(item, "description")), OneLine(ChatLineProtocol.S(item, "argumentHint")), "ai"));
    }
    return rows;
  }

  // Skills and commands Claude Code loads from disk: <cwd>/.claude/{skills,commands},
  // skills in extra (--add-dir) folders, and the account's own config folder.
  public static IReadOnlyList<ChatSlashCommand> Disk(string? cwd, IReadOnlyList<string> extraFolders, string? userConfigDir)
  {
    var rows = new List<ChatSlashCommand>();
    if (cwd is { Length: > 0 }) { Skills(Path.Combine(cwd, ".claude", "skills"), "project", rows); Commands(Path.Combine(cwd, ".claude", "commands"), "project", rows); }
    foreach (var folder in extraFolders) Skills(Path.Combine(folder, ".claude", "skills"), "project", rows);
    if (userConfigDir is { Length: > 0 }) { Skills(Path.Combine(userConfigDir, "skills"), "user", rows); Commands(Path.Combine(userConfigDir, "commands"), "user", rows); }
    return rows;
  }

  // The whole box is one "/word" so far (nil otherwise): the menu is open.
  public static string? Query(string text) => text.StartsWith('/') && !text.Any(char.IsWhiteSpace) ? text[1..] : null;

  // Exact name first (Enter never runs a longer one), then names starting with it, then names or descriptions containing it.
  public static IReadOnlyList<ChatSlashCommand> Matches(IReadOnlyList<ChatSlashCommand> commands, string query)
  {
    if (query.Length == 0) return commands;
    var exact = commands.Where(c => c.Name.Equals(query, StringComparison.OrdinalIgnoreCase));
    var starts = commands.Where(c => c.Name.StartsWith(query, StringComparison.OrdinalIgnoreCase) && !c.Name.Equals(query, StringComparison.OrdinalIgnoreCase));
    var contains = commands.Where(c => !c.Name.StartsWith(query, StringComparison.OrdinalIgnoreCase) &&
      (c.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || c.Description.Contains(query, StringComparison.OrdinalIgnoreCase)));
    return exact.Concat(starts).Concat(contains).ToArray();
  }

  // What picking a command puts in the box: ready for arguments when it takes them, else runnable as is.
  public static string Text(ChatSlashCommand command) => "/" + command.Name + (command.ArgumentHint.Length > 0 ? " " : "");

  private static void Skills(string folder, string source, List<ChatSlashCommand> rows)
  {
    foreach (var dir in SafeDirectories(folder).Take(300))
    {
      var file = Path.Combine(dir, "SKILL.md"); if (!File.Exists(file)) continue;
      var (name, description, hint) = Read(file);
      if (Clean(name ?? Path.GetFileName(dir)) is { } clean) rows.Add(new(clean, description, hint, source));
    }
  }
  // Subfolders organise commands; the command keeps its file name (Claude Code rule).
  private static void Commands(string folder, string source, List<ChatSlashCommand> rows)
  {
    IEnumerable<string> files;
    try { files = Directory.Exists(folder) ? Directory.EnumerateFiles(folder, "*.md", new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 3, IgnoreInaccessible = true }).Take(300).ToArray() : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return; }
    foreach (var file in files.OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
    {
      var (_, description, hint) = Read(file);
      if (Clean(Path.GetFileNameWithoutExtension(file)) is { } name) rows.Add(new(name, description, hint, source));
    }
  }
  private static IEnumerable<string> SafeDirectories(string folder)
  {
    try { return Directory.Exists(folder) ? Directory.EnumerateDirectories(folder).OrderBy(d => d, StringComparer.OrdinalIgnoreCase).ToArray() : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
  }

  // Front matter name/description/argument-hint; else the first plain line describes it.
  public static (string? Name, string Description, string Hint) Parse(string text)
  {
    string? name = null; var description = ""; var hint = "";
    var lines = text.Replace("\r\n", "\n").Split('\n'); var start = 0;
    if (lines.Length > 0 && lines[0].Trim() == "---")
    {
      var end = Array.FindIndex(lines, 1, l => l.Trim() == "---");
      if (end > 0)
      {
        for (var i = 1; i < end; i++)
        {
          var colon = lines[i].IndexOf(':'); if (colon <= 0 || char.IsWhiteSpace(lines[i][0])) continue;
          var key = lines[i][..colon].Trim(); var value = Unquote(lines[i][(colon + 1)..].Trim());
          if (key == "description" && value is "|" or ">" or "|-" or ">-")
            value = string.Join(" ", lines.Skip(i + 1).Take(end - i - 1).TakeWhile(l => l.Length > 0 && char.IsWhiteSpace(l[0])).Select(l => l.Trim()));
          if (key == "name") name = value; else if (key == "description") description = value; else if (key == "argument-hint") hint = value;
        }
        start = end + 1;
      }
    }
    if (description.Length == 0)
      description = lines.Skip(start).Select(l => l.Trim().TrimStart('#').Trim()).FirstOrDefault(l => l.Length > 0) ?? "";
    return (name, OneLine(description), OneLine(hint));
  }
  private static (string? Name, string Description, string Hint) Read(string file)
  {
    try
    {
      using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      var buffer = new char[8192]; using var reader = new StreamReader(stream); var count = reader.ReadBlock(buffer, 0, buffer.Length);
      return Parse(new string(buffer, 0, count));
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return (null, "", ""); }
  }
  private static string Unquote(string value) => value.Length >= 2 && (value[0] == '"' && value[^1] == '"' || value[0] == '\'' && value[^1] == '\'') ? value[1..^1] : value;
  private static string OneLine(string text)
  {
    var line = string.Join(" ", text.Split((char[])['\r', '\n', '\t'], StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim())).Trim();
    return line.Length > 160 ? line[..157] + "…" : line;
  }
  private static string? Clean(string? name)
  {
    name = name?.Trim().TrimStart('/');
    return name is { Length: > 0 and <= 80 } && name.All(c => char.IsLetterOrDigit(c) || c is '-' or '_' or ':' or '.') ? name : null;
  }
}
