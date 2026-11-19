using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.AiSetup;

/// ONE SETUP FOR EVERY AI (Asad, 19 Nov 2026: "Every time when we do some upgrade, all models should react same.
/// Everything should be same when we change the model."). Kept by the app, never by the person: no question, no setting.
/// The Mac's BackendAISetupKeeper (lane/setup-travels), written here to the same rules so both make the same bytes.
///
/// For one project folder it makes Claude Code, Codex and Gemini see the same setup:
/// - Skills: `.claude/skills`, `.agents/skills` (Codex and Gemini read it) and `.gemini/skills` (when the project has it)
///   hold the same skills, file for file. The newest copy of a skill wins; the replaced copy goes to the Recycle Bin.
/// - Rule files: a missing `AGENTS.md` or `GEMINI.md` is made as a marked pointer to `CLAUDE.md`.
/// - Agents: every `.claude/agents/<name>.md` gets `.codex/agents/<name>.toml` and `.gemini/agents/<name>.md`.
/// - Guards: every hook in `.claude/settings.json` gets its entry in `.codex/hooks.json` and `.gemini/settings.json`
///   where that AI has the same event.
///
/// A person's own file is never overwritten: the app only rewrites files (and hook entries) it marked as its own.
/// Everything it writes depends on the project's files alone, never on this PC, so a Mac and a PC make the same bytes and
/// the instruction-file sync (row I09) carries them without a ping-pong. Nothing here runs anything.
public static class AiSetupKeeper
{
  /// First line of every file the app keeps (Codex TOML comment, Gemini YAML comment, Markdown comment).
  public const string MarkerWords = "Terminal Deck keeps this file";
  /// Hook entries the app added: Codex `statusMessage`, Gemini `name`.
  public const string HookMarker = "Terminal Deck guard";
  /// The Mac's BackendSkillsMirror.marker: a skill copy the app keeps. Not part of a skill's contents.
  public const string SkillCopyMarker = ".terminaldeck-copy";

  /// Where a replaced or retired copy goes. The app: the Recycle Bin, where the person can take it back. Tests: a folder.
  public delegate void Discard(string path);
  public static readonly Discard ToRecycleBin = RecycleBin.Send;
  /// One line per change (the app writes them to `logs\ai-setup.log`). Never a file's contents.
  public static Action<string>? Log { get; set; }

  // ---- Entry points ----

  private static readonly object AlignGate = new();
  private static readonly Dictionary<string, DateTime> Recent = new(StringComparer.OrdinalIgnoreCase);
  private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

  /// For a session start: the project holding `cwd` is aligned on a background thread, at most once per project every
  /// 5 seconds (a tab restore opens several sessions in one project at once).
  public static void AlignSoon(string cwd)
  {
    if (string.IsNullOrEmpty(cwd) || ProjectRoot(cwd, Home) is not { } root) return;
    var now = DateTime.UtcNow;
    lock (Recent)
    {
      if (Recent.TryGetValue(root, out var last) && now - last < TimeSpan.FromSeconds(5)) return;
      Recent[root] = now;
    }
    _ = Task.Run(() =>
    {
      // The one boundary of a background run: a fault is written down, never lost and never thrown into nothing.
      try { Align(root); }
      catch (Exception e) { Log?.Invoke("AI setup: the project could not be aligned: " + e.GetType().Name + ": " + e.Message); }
    });
  }

  /// Every part, in an order where each one sees the others' results. Returns the log lines (one per change).
  public static IReadOnlyList<string> Align(string root, Discard? discard = null)
  {
    discard ??= ToRecycleBin;
    var lines = new List<string>();
    // A session start and a Cloud look may come at the same moment: one at a time, so two writers never meet.
    lock (AlignGate)
    {
      lines.AddRange(AlignSkills(root, discard));
      lines.AddRange(AlignRuleFiles(root));
      lines.AddRange(AlignAgents(root, discard));
      lines.AddRange(AlignGuards(root).Lines);
    }
    foreach (var line in lines) Log?.Invoke(line);
    return lines;
  }

  /// The project folder for a session's folder: the nearest folder (itself first) holding `CLAUDE.md` or `.claude`,
  /// strictly below the home folder. Null when there is none.
  public static string? ProjectRoot(string cwd, string home)
  {
    string path, homePath;
    try
    {
      if (!Path.IsPathFullyQualified(cwd) || !Path.IsPathFullyQualified(home)) return null;
      path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(cwd));
      homePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home));
    }
    catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    while (path.StartsWith(homePath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
    {
      if (RegularFile(Path.Combine(path, "CLAUDE.md")) || RealFolder(Path.Combine(path, ".claude"))) return path;
      if (Path.GetDirectoryName(path) is not { } parent || parent.Length >= path.Length) return null;
      path = Path.TrimEndingDirectorySeparator(parent);
    }
    return null;
  }

  // ---- 3a Skills ----

  internal static readonly string[] SkillRoots = [".claude/skills", ".agents/skills", ".gemini/skills"];

  /// The skill folders of every root are made identical. A root that is a link is left alone, and two roots that are the
  /// same folder count once. `.gemini/skills` takes part only when the project already has it.
  internal static List<string> AlignSkills(string root, Discard discard)
  {
    var roots = new List<string>();
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var relative in SkillRoots)
    {
      var path = At(root, relative);
      if (IsLink(path) || IsLink(Parent(path))) continue;
      var exists = RealFolder(path);
      if (!exists && relative == ".gemini/skills") continue;
      if (exists && !seen.Add(Path.GetFullPath(path))) continue;
      roots.Add(path);
    }
    if (roots.Count <= 1) return [];
    var names = new HashSet<string>(StringComparer.Ordinal);
    foreach (var path in roots.Where(RealFolder))
      foreach (var name in Names(path).Where(n => !n.StartsWith('.')))
      {
        var folder = Path.Combine(path, name);
        if (RealFolder(folder) && RegularFile(Path.Combine(folder, "SKILL.md"))) names.Add(name);
      }
    var lines = new List<string>();
    foreach (var name in names.OrderBy(n => n, StringComparer.Ordinal))
    {
      // Each root's copy: fingerprint and newest time. A link or a non-folder under the name is left alone.
      var copies = new List<(string Root, string? Print, DateTime Newest)>();
      var blocked = false;
      foreach (var path in roots)
      {
        var folder = Path.Combine(path, name);
        if (IsLink(folder) || (Exists(folder) && !RealFolder(folder))) { blocked = true; break; }
        var scan = Fingerprint(folder);
        // A copy that is there but cannot be read whole is never taken for absent: the skill is left as it is.
        if (scan is null && Exists(folder)) { blocked = true; break; }
        copies.Add(scan is { } s ? (path, s.Print, s.Newest) : (path, null, DateTime.MinValue));
      }
      if (blocked) continue;
      var present = copies.Where(c => c.Print is not null).ToList();
      if (present.Count == 0) continue;
      // The newest copy; an exact tie goes to `.claude/skills`, then `.agents/skills`.
      var winner = present.Aggregate((best, c) => c.Newest > best.Newest || (c.Newest == best.Newest && Rank(c.Root) < Rank(best.Root)) ? c : best);
      var behind = copies.Where(c => !string.Equals(c.Print, winner.Print, StringComparison.Ordinal)).ToList();
      if (behind.Count == 0) continue;
      var source = Path.Combine(winner.Root, name);
      var done = new List<string>();
      foreach (var copy in behind)
        if (ReplaceSkill(source, Path.Combine(copy.Root, name), discard)) done.Add(RelativeName(copy.Root, root));
      if (done.Count > 0)
        lines.Add("AI setup: skill \"" + name + "\" made the same for every AI (newest copy from " + RelativeName(winner.Root, root)
          + ", copied to " + string.Join(", ", done) + ").");
    }
    return lines;
  }

  /// `.claude/skills` wins an exact tie, then `.agents/skills`.
  private static int Rank(string path)
  {
    var p = path.Replace('\\', '/');
    if (p.EndsWith("/.claude/skills", StringComparison.Ordinal)) return 0;
    if (p.EndsWith("/.agents/skills", StringComparison.Ordinal)) return 1;
    return 2;
  }

  /// What a skill folder holds (paths and contents, the app's own marker and Finder files left out) and its newest file
  /// time. Null when the folder is absent or any part of it cannot be read. Windows has no run bit: every file counts as
  /// not runnable.
  internal static (string Print, DateTime Newest)? Fingerprint(string folder)
  {
    if (!RealFolder(folder)) return null;
    var entries = new List<string>();
    var newest = DateTime.MinValue;
    var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = false };
    IEnumerable<FileInfo> files;
    try { files = new DirectoryInfo(folder).EnumerateFiles("*", options).ToArray(); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return null; }
    var basePath = Path.GetFullPath(folder);
    foreach (var file in files)
    {
      if (file.Name is SkillCopyMarker or ".DS_Store") continue;
      byte[] data;
      try { data = File.ReadAllBytes(file.FullName); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
      var relative = file.FullName[basePath.Length..].Replace('\\', '/');
      if (!relative.StartsWith('/')) relative = "/" + relative;
      entries.Add(relative + "\t-\t" + Convert.ToHexStringLower(SHA256.HashData(data)));
      if (file.LastWriteTimeUtc > newest) newest = file.LastWriteTimeUtc;
    }
    entries.Sort(StringComparer.Ordinal);
    return (string.Join('\n', entries), newest);
  }

  /// Copies the winning skill over one other root's copy: staged beside it, the old copy to the Recycle Bin, then moved
  /// in. The app's marker is kept when the old copy had it. False when nothing changed.
  internal static bool ReplaceSkill(string source, string target, Discard discard)
  {
    var parent = Parent(target);
    var stage = Path.Combine(parent, ".terminaldeck-stage-" + Guid.NewGuid().ToString("D").ToUpperInvariant());
    try
    {
      Directory.CreateDirectory(parent);
      CopyFolder(source, stage);
      var ownMarker = Path.Combine(stage, SkillCopyMarker);
      var hadMarker = RegularFile(Path.Combine(target, SkillCopyMarker));
      if (hadMarker && !RegularFile(ownMarker))
        File.WriteAllBytes(ownMarker, Encoding.UTF8.GetBytes("A copy Terminal Deck keeps of " + Path.GetFileName(source) + " for every AI.\n"));
      else if (!hadMarker && RegularFile(ownMarker)) File.Delete(ownMarker);
      // The replaced copy is never destroyed: it goes to the Recycle Bin, where the person can take it back.
      if (Exists(target)) discard(target);
      Directory.Move(stage, target);
      return true;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PlatformNotSupportedException
      or System.ComponentModel.Win32Exception)
    {
      Log?.Invoke("AI setup: a skill copy could not be made the same: " + e.Message);
      return false;
    }
    finally
    {
      try { if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log?.Invoke("AI setup: a staging folder was left beside a skill: " + e.Message); }
    }
  }

  /// A plain copy of a folder: real files and folders only; a link inside is not copied (never followed).
  private static void CopyFolder(string from, string to)
  {
    Directory.CreateDirectory(to);
    foreach (var info in new DirectoryInfo(from).EnumerateFileSystemInfos())
    {
      if ((info.Attributes & FileAttributes.ReparsePoint) != 0) continue;
      var destination = Path.Combine(to, info.Name);
      if (info is DirectoryInfo) CopyFolder(info.FullName, destination);
      else File.Copy(info.FullName, destination, overwrite: false);
    }
  }

  // ---- 3b Rule files ----

  public static string Pointer(string file)
  {
    var ai = file == "GEMINI.md" ? "Gemini" : "Codex";
    var text = "<!-- " + MarkerWords + " for " + ai + ": it points to CLAUDE.md. Write your own text here and Terminal Deck leaves it alone. -->\n";
    text += "# " + file + "\n\nRead `CLAUDE.md` in this folder: it holds this project's rules for every AI.\n";
    // Gemini reads the rules in directly with its import line.
    if (file == "GEMINI.md") text += "\n@./CLAUDE.md\n";
    return text;
  }

  /// A missing `AGENTS.md` / `GEMINI.md` beside a `CLAUDE.md` is made as a pointer. An existing file (his, or a link) is
  /// never touched.
  internal static List<string> AlignRuleFiles(string root)
  {
    if (!RegularFile(Path.Combine(root, "CLAUDE.md"))) return [];
    var lines = new List<string>();
    foreach (var file in new[] { "AGENTS.md", "GEMINI.md" })
    {
      var path = Path.Combine(root, file);
      if (Exists(path) || IsLink(path)) continue;
      if (CreateOnly(path, Encoding.UTF8.GetBytes(Pointer(file)))) lines.Add("AI setup: " + file + " made, pointing to CLAUDE.md.");
    }
    return lines;
  }

  // ---- 3c Agents ----

  public sealed record ClaudeAgent(string File, string Name, string Description, string Body);

  /// `---` front matter with one-line `key: value` pairs, then the body. Null when the file has no front matter. Read
  /// the way the Mac reads it (Swift compares whole characters: a CR LF pair is one character, so a file with CR LF line
  /// ends has no front matter there, and has none here either).
  public static ClaudeAgent? ParseAgent(string file, string text)
  {
    var body = text.StartsWith('\uFEFF') ? text[1..] : text;
    var lines = SwiftLines(body);
    if (SwiftTrim(lines[0], newlines: false) != "---") return null;
    var fields = new Dictionary<string, string>(StringComparer.Ordinal);
    int? end = null;
    for (var index = 1; index < lines.Count; index++)
    {
      var line = lines[index];
      if (SwiftTrim(line, newlines: false) == "---") { end = index; break; }
      var characters = Characters(line);
      var colon = characters.IndexOf(":");
      if (colon < 0 || characters.Count > 0 && characters[0] is " " or "\t") continue;
      var key = SwiftTrim(string.Concat(characters.Take(colon)), newlines: false);
      var value = SwiftTrim(string.Concat(characters.Skip(colon + 1)), newlines: false);
      var valueCharacters = Characters(value);
      if (valueCharacters.Count >= 2 && valueCharacters[0] is "\"" or "'" && valueCharacters[^1] == valueCharacters[0])
        value = string.Concat(valueCharacters.Skip(1).Take(valueCharacters.Count - 2));
      fields[key] = value;
    }
    if (end is not { } last) return null;
    var stem = file.LastIndexOf('.') is var dot and > 0 ? file[..dot] : file;
    var rest = string.Join('\n', lines.Skip(last + 1));
    var trimmed = rest.StartsWith('\n') ? rest[1..] : rest;
    return new ClaudeAgent(stem, fields.TryGetValue("name", out var name) && name.Length > 0 ? name : stem,
      fields.TryGetValue("description", out var description) ? description : "", trimmed);
  }

  public static string TomlBasic(string text)
  {
    var output = new StringBuilder("\"");
    foreach (var r in text.EnumerateRunes())
      switch (r.Value)
      {
        case '\\': output.Append("\\\\"); break;
        case '"': output.Append("\\\""); break;
        case '\n': output.Append("\\n"); break;
        case '\t': output.Append("\\t"); break;
        case '\r': output.Append("\\r"); break;
        case < 0x20 or 0x7f: output.Append("\\u").Append(r.Value.ToString("X4", CultureInfo.InvariantCulture)); break;
        default: output.Append(r.ToString()); break;
      }
    return output.Append('"').ToString();
  }
  public static string TomlMultiline(string text)
  {
    var output = new StringBuilder("\"\"\"\n");
    foreach (var r in text.EnumerateRunes())
      switch (r.Value)
      {
        case '\\': output.Append("\\\\"); break;
        case '"': output.Append("\\\""); break; // never three quotes in a row
        case '\n' or '\t': output.Append((char)r.Value); break;
        case '\r': output.Append("\\r"); break;
        case < 0x20 or 0x7f: output.Append("\\u").Append(r.Value.ToString("X4", CultureInfo.InvariantCulture)); break;
        default: output.Append(r.ToString()); break;
      }
    return output.Append("\"\"\"").ToString();
  }

  private static bool AsciiWord(Rune r, bool space) => r.IsAscii && (char.IsAsciiLetterOrDigit((char)r.Value) || r.Value is '-' or '_' || space && r.Value == ' ');

  /// Codex: a role file. Its name may hold only ASCII letters, digits, spaces, hyphens and underscores, and its
  /// instructions may not be blank.
  public static string CodexAgent(ClaudeAgent agent)
  {
    var cleaned = string.Concat(agent.Name.EnumerateRunes().Select(r => AsciiWord(r, space: true) ? r.ToString() : "-"));
    var body = SwiftTrim(agent.Body, newlines: true).Length == 0 ? agent.Description : agent.Body;
    var text = "# " + MarkerWords + " for Codex, the same as .claude/agents/" + agent.File + ".md. Change that file; this one follows it.\n";
    text += "name = " + TomlBasic(cleaned) + "\n";
    text += "description = " + TomlBasic(agent.Description) + "\n";
    text += "developer_instructions = " + TomlMultiline(body.Length == 0 ? agent.Name : body) + "\n";
    return text;
  }

  public static string YamlQuoted(string text) =>
    "\"" + text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal)
      .Replace("\n", "\\n", StringComparison.Ordinal).Replace("\t", "\\t", StringComparison.Ordinal) + "\"";

  /// Gemini: a local agent. Its name is a slug (lower-case letters, digits, hyphens and underscores). Model and tools are
  /// not copied: Claude's names mean nothing to Gemini, so the agent uses Gemini's own model and every tool.
  public static string GeminiAgent(ClaudeAgent agent)
  {
    var slug = string.Concat(SwiftLower(agent.Name).EnumerateRunes().Select(r => AsciiWord(r, space: false) ? r.ToString() : "-"));
    if (slug.Length == 0) slug = "agent";
    var text = "---\n# " + MarkerWords + " for Gemini, the same as .claude/agents/" + agent.File + ".md. Change that file; this one follows it.\n";
    text += "name: " + slug + "\n";
    text += "description: " + YamlQuoted(agent.Description.Length == 0 ? agent.Name : agent.Description) + "\n";
    text += "---\n\n" + agent.Body;
    // Whole characters, like the Mac: a text that ends in CR LF does not end in LF there.
    if (!(text.EndsWith('\n') && !text.EndsWith("\r\n", StringComparison.Ordinal))) text += "\n";
    return text;
  }

  /// True when the file at `path` is one the app made (its marker in the first 400 bytes).
  internal static bool AppMade(string path)
  {
    if (!RegularFile(path)) return false;
    try
    {
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      var head = new byte[400];
      var read = stream.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
      return Encoding.UTF8.GetString(head, 0, read).Contains(MarkerWords, StringComparison.Ordinal);
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
  }

  internal static List<string> AlignAgents(string root, Discard discard)
  {
    var claude = At(root, ".claude/agents");
    var agents = new List<ClaudeAgent>();
    if (RealFolder(claude))
      foreach (var file in Names(claude).Where(f => f.EndsWith(".md", StringComparison.Ordinal) && !f.StartsWith('.')).OrderBy(f => f, StringComparer.Ordinal))
      {
        var path = Path.Combine(claude, file);
        if (!RegularFile(path) || ReadText(path) is not { } text || ParseAgent(file, text) is not { } agent) continue;
        agents.Add(agent);
      }
    var lines = new List<string>();
    var targets = new (string Folder, string Ext, string Ai, Func<ClaudeAgent, string> Make)[]
      { (".codex/agents", "toml", "Codex", CodexAgent), (".gemini/agents", "md", "Gemini", GeminiAgent) };
    foreach (var target in targets)
    {
      var folder = At(root, target.Folder);
      if (IsLink(folder) || IsLink(Parent(folder))) continue;
      int made = 0, removed = 0;
      // Windows names ignore letter case: an app copy under another spelling is the same file, never retired.
      var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach (var agent in agents)
      {
        var path = Path.Combine(folder, agent.File + "." + target.Ext);
        wanted.Add(Path.GetFileName(path));
        var bytes = Encoding.UTF8.GetBytes(target.Make(agent));
        if (Exists(path) || IsLink(path))
        {
          // His own file under that name: left exactly as it is.
          if (!AppMade(path) || ReadBytes(path) is { } held && held.AsSpan().SequenceEqual(bytes)) continue;
          if (ReplaceFile(path, bytes)) made++;
        }
        else if (CreateOnly(path, bytes)) made++;
      }
      // The app's own copy of an agent that is no longer in `.claude/agents` goes (his own files never do).
      if (RealFolder(folder))
        foreach (var file in Names(folder).Where(f => f.EndsWith("." + target.Ext, StringComparison.Ordinal) && !wanted.Contains(f)))
        {
          var path = Path.Combine(folder, file);
          if (!AppMade(path)) continue;
          try { discard(path); removed++; }
          catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or PlatformNotSupportedException
            or System.ComponentModel.Win32Exception)
          { Log?.Invoke("AI setup: " + target.Ai + " agent " + file + " could not go to the Recycle Bin: " + e.Message); }
        }
      if (made > 0) lines.Add("AI setup: " + made + " agent" + (made == 1 ? "" : "s") + " made the same for " + target.Ai + ".");
      if (removed > 0) lines.Add("AI setup: " + removed + " " + target.Ai + " agent" + (removed == 1 ? "" : "s") + " removed (gone from .claude/agents).");
    }
    return lines;
  }

  // ---- 3d Guards ----

  /// Claude's hook events and their name for each AI (the Mac's tables: Codex 0.159.3's built-in hook schemas; Gemini CLI
  /// 0.63.0 `docs/hooks/reference.md`). Absent = that AI has no such event.
  public static readonly IReadOnlyDictionary<string, string> CodexEvents = new Dictionary<string, string>
  {
    ["PreToolUse"] = "PreToolUse", ["PostToolUse"] = "PostToolUse", ["PermissionRequest"] = "PermissionRequest", ["UserPromptSubmit"] = "UserPromptSubmit",
    ["Stop"] = "Stop", ["SessionStart"] = "SessionStart", ["SessionEnd"] = "SessionEnd", ["PreCompact"] = "PreCompact", ["PostCompact"] = "PostCompact",
    ["SubagentStart"] = "SubagentStart", ["SubagentStop"] = "SubagentStop"
  };
  public static readonly IReadOnlyDictionary<string, string> GeminiEvents = new Dictionary<string, string>
  {
    ["PreToolUse"] = "BeforeTool", ["PostToolUse"] = "AfterTool", ["UserPromptSubmit"] = "BeforeAgent", ["Stop"] = "AfterAgent",
    ["SessionStart"] = "SessionStart", ["SessionEnd"] = "SessionEnd", ["Notification"] = "Notification", ["PreCompact"] = "PreCompress"
  };
  /// Claude tool names and Gemini's built-in names for the same tools (Gemini `docs/reference/tools.md`).
  public static readonly IReadOnlyDictionary<string, string> GeminiTools = new Dictionary<string, string>
  {
    ["Bash"] = "run_shell_command", ["Edit"] = "replace", ["MultiEdit"] = "replace", ["Write"] = "write_file", ["Read"] = "read_file", ["Glob"] = "glob",
    ["Grep"] = "grep_search", ["LS"] = "list_directory", ["WebFetch"] = "web_fetch", ["WebSearch"] = "google_web_search"
  };
  /// Codex's names for its shell tool, matched beside Claude's `Bash` and told to the guard as Bash.
  public static readonly string[] CodexShellNames = ["shell", "local_shell", "exec_command"];
  private static readonly HashSet<string> ToolEvents = ["PreToolUse", "PostToolUse", "PermissionRequest"];

  /// The guard is told what Claude would tell it: tool and event names in Claude's words, so a guard written for Claude
  /// works unchanged. POSIX `sed`; the same bytes on every device.
  internal static List<string> Translator(IEnumerable<(string From, string To)> pairs, string field) =>
    pairs.Select(p => "-e 's/\"" + field + "\"[[:space:]]*:[[:space:]]*\"" + p.From + "\"/\"" + field + "\":\"" + p.To + "\"/g'").ToList();
  internal static string Wrap(string command, IReadOnlyList<string> translate, bool findProject)
  {
    var output = "";
    // Codex gives hooks no project folder: the nearest folder holding `.codex/hooks.json` is it (no path of this PC).
    if (findProject)
      output += "d=\"$PWD\"; while [ \"$d\" != / ] && [ ! -f \"$d/.codex/hooks.json\" ]; do d=\"$(dirname \"$d\")\"; done; export CLAUDE_PROJECT_DIR=\"$d\"; ";
    if (translate.Count == 0) return output + command;
    return output + "sed -E " + string.Join(' ', translate) + " | { " + command + "\n}";
  }

  /// Swift's `split(separator: "|")`: empty pieces left out; each piece trimmed of spaces and tabs.
  private static List<string> MatcherTokens(string matcher) =>
    matcher.Split('|').Where(t => t.Length > 0).Select(t => SwiftTrim(t, newlines: false)).ToList();

  internal static string? MatcherForGemini(string matcher, string @event)
  {
    if (!ToolEvents.Contains(@event)) return matcher.Length == 0 ? "*" : matcher;
    if (matcher.Length == 0 || matcher == "*") return "*";
    var mapped = new List<string>();
    foreach (var token in MatcherTokens(matcher))
    {
      if (GeminiTools.TryGetValue(token, out var name)) { if (!mapped.Contains(name)) mapped.Add(name); }
      else if (token.StartsWith("mcp__", StringComparison.Ordinal))
      {
        // Claude `mcp__server__tool` is Gemini `mcp_server_tool`.
        var mcp = "mcp_" + token[5..].Replace("__", "_", StringComparison.Ordinal);
        if (!mapped.Contains(mcp)) mapped.Add(mcp);
      }
    }
    return mapped.Count == 0 ? null : string.Join('|', mapped);
  }
  internal static string MatcherForCodex(string matcher, string @event)
  {
    if (!ToolEvents.Contains(@event) || matcher.Length == 0 || matcher == "*") return matcher;
    var tokens = MatcherTokens(matcher);
    if (tokens.Contains("Bash")) foreach (var name in CodexShellNames) if (!tokens.Contains(name)) tokens.Add(name);
    return string.Join('|', tokens);
  }

  public sealed class GuardResult
  {
    public List<string> Lines { get; } = [];
    /// "<AI>: <Claude event>" for each hook event that AI has no equivalent for.
    public List<string> NoEquivalent { get; } = [];
  }

  /// The hook groups for one AI, built from Claude's settings.
  internal static Dictionary<string, List<SetupJson.Obj>> Groups(SetupJson.Obj claudeHooks, string ai, GuardResult result)
  {
    var output = new Dictionary<string, List<SetupJson.Obj>>(StringComparer.Ordinal);
    foreach (var @event in claudeHooks.Keys.OrderBy(k => k, StringComparer.Ordinal))
    {
      if (SetupJson.ObjectList(claudeHooks[@event]) is not { } list) continue;
      var mapped = ai == "Codex" ? CodexEvents.GetValueOrDefault(@event) : GeminiEvents.GetValueOrDefault(@event);
      if (mapped is null) { result.NoEquivalent.Add(ai + ": " + @event); continue; }
      foreach (var group in list)
      {
        var matcher = group.GetValueOrDefault("matcher") as string ?? "";
        string targetMatcher;
        if (ai == "Codex") targetMatcher = MatcherForCodex(matcher, @event);
        else
        {
          if (MatcherForGemini(matcher, @event) is not { } m) { result.NoEquivalent.Add(ai + ": " + @event + " " + matcher); continue; }
          targetMatcher = m;
        }
        var handlers = new List<object?>();
        foreach (var handler in SetupJson.ObjectList(group.GetValueOrDefault("hooks")) ?? [])
        {
          if ((handler.GetValueOrDefault("type") as string ?? "command") != "command" || handler.GetValueOrDefault("command") is not string { Length: > 0 } command) continue;
          var made = new SetupJson.Obj { ["type"] = "command" };
          var timeout = SetupJson.NumberValue(handler.GetValueOrDefault("timeout"));
          if (ai == "Codex")
          {
            var translate = ToolEvents.Contains(@event) ? Translator(CodexShellNames.Select(n => (n, "Bash")), "tool_name") : new List<string>();
            made["command"] = Wrap(command, translate, findProject: command.Contains("CLAUDE_PROJECT_DIR", StringComparison.Ordinal));
            if (timeout is { } seconds && SetupJson.Rounded(seconds) is { } whole) made["timeout"] = whole;
            made["statusMessage"] = HookMarker;
          }
          else
          {
            var pairs = ToolEvents.Contains(@event)
              ? GeminiTools.OrderBy(t => t.Key, StringComparer.Ordinal).Where(t => t.Key != "MultiEdit").Select(t => (t.Value, t.Key)).ToList()
              : new List<(string, string)>();
            var translate = Translator(pairs, "tool_name");
            translate.AddRange(Translator(GeminiEvents.OrderBy(e => e.Key, StringComparer.Ordinal).Where(e => e.Key != e.Value).Select(e => (e.Value, e.Key)), "hook_event_name"));
            made["command"] = Wrap(command, translate, findProject: false);
            // Gemini counts milliseconds; Claude seconds.
            if (timeout is { } seconds && SetupJson.Rounded(seconds * 1000) is { } ms) made["timeout"] = ms;
            made["name"] = HookMarker;
          }
          handlers.Add(made);
        }
        if (handlers.Count == 0) continue;
        var groupMade = new SetupJson.Obj { ["hooks"] = handlers };
        if (targetMatcher.Length > 0) groupMade["matcher"] = targetMatcher;
        if (!output.TryGetValue(mapped, out var groups)) output[mapped] = groups = [];
        groups.Add(groupMade);
      }
    }
    return output;
  }

  /// Removes the app's own handlers (by marker) from a hooks object, then adds `generated`. His entries stay as they are.
  internal static SetupJson.Obj Merged(SetupJson.Obj existing, Dictionary<string, List<SetupJson.Obj>> generated, string markerKey)
  {
    var hooks = new SetupJson.Obj();
    foreach (var (@event, value) in existing)
    {
      if (value is not List<object?> list) { hooks[@event] = value; continue; }
      var kept = new List<object?>();
      foreach (var item in list)
      {
        if (item is not SetupJson.Obj group || group.GetValueOrDefault("hooks") is not List<object?> handlers) { kept.Add(item); continue; }
        var left = handlers.Where(h => !(h is SetupJson.Obj o && o.GetValueOrDefault(markerKey) is string s && s == HookMarker)).ToList();
        if (left.Count == handlers.Count) { kept.Add(item); continue; }
        if (left.Count == 0) continue;
        var changed = new SetupJson.Obj(group) { ["hooks"] = left };
        kept.Add(changed);
      }
      if (kept.Count > 0) hooks[@event] = kept;
    }
    foreach (var (@event, groups) in generated)
    {
      var list = hooks.GetValueOrDefault(@event) as List<object?> ?? [];
      hooks[@event] = list.Concat(groups).ToList();
    }
    return hooks;
  }

  internal static (bool Exists, SetupJson.Obj? Object) ReadJsonObject(string path)
  {
    if (!Exists(path) && !IsLink(path)) return (false, new SetupJson.Obj());
    if (!RegularFile(path) || ReadBytes(path) is not { } data) return (true, null);
    if (data.Length == 0) return (true, new SetupJson.Obj());
    return (true, SetupJson.Parse(data) as SetupJson.Obj);
  }

  internal static GuardResult AlignGuards(string root)
  {
    var result = new GuardResult();
    var settings = At(root, ".claude/settings.json");
    var claudeHooks = new SetupJson.Obj();
    if (RegularFile(settings))
    {
      if (ReadBytes(settings) is not { } data || SetupJson.Parse(data) is not SetupJson.Obj parsed)
      {
        result.Lines.Add("AI setup: .claude/settings.json could not be read; the guards of Codex and Gemini are left as they are.");
        return result;
      }
      claudeHooks = parsed.GetValueOrDefault("hooks") as SetupJson.Obj ?? new SetupJson.Obj();
    }
    var targets = new (string Path, string Ai, string Marker)[] { (".codex/hooks.json", "Codex", "statusMessage"), (".gemini/settings.json", "Gemini", "name") };
    foreach (var target in targets)
    {
      var path = At(root, target.Path);
      if (IsLink(path) || IsLink(Parent(path))) continue;
      var generated = Groups(claudeHooks, target.Ai, result);
      var current = ReadJsonObject(path);
      if (current.Object is not { } obj)
      {
        result.Lines.Add("AI setup: " + target.Path + " is not plain settings; its guards are left as they are.");
        continue;
      }
      // Nothing to add and nothing of the app's there: an absent file stays absent.
      if (!current.Exists && generated.Count == 0) continue;
      var before = new SetupJson.Obj(obj);
      var hooks = Merged(obj.GetValueOrDefault("hooks") as SetupJson.Obj ?? new SetupJson.Obj(), generated, target.Marker);
      if (hooks.Count == 0) obj.Remove("hooks"); else obj["hooks"] = hooks;
      var bytes = Encoding.UTF8.GetBytes(SetupJson.Pretty(obj) + "\n");
      if (current.Exists)
      {
        // Unchanged in meaning: his file is not rewritten (not even reformatted).
        if (SetupJson.SameMeaning(before, obj)) continue;
        if (ReplaceFile(path, bytes)) result.Lines.Add("AI setup: the guards in " + target.Path + " made the same as Claude's.");
      }
      else if (CreateOnly(path, bytes)) result.Lines.Add("AI setup: " + target.Path + " made with Claude's guards.");
    }
    return result;
  }

  // ---- Swift's view of text (the Mac reads whole characters) ----

  /// Lines split at LF, where a CR LF pair is one character and never a split (Swift `split(separator: "\n")`).
  private static List<string> SwiftLines(string text)
  {
    var lines = new List<string>();
    var start = 0;
    for (var i = 0; i < text.Length; i++)
      if (text[i] == '\n' && (i == 0 || text[i - 1] != '\r')) { lines.Add(text[start..i]); start = i + 1; }
    lines.Add(text[start..]);
    return lines;
  }
  /// The text's user-perceived characters (extended grapheme clusters, as Swift's Character).
  private static List<string> Characters(string text)
  {
    var list = new List<string>();
    var e = StringInfo.GetTextElementEnumerator(text);
    while (e.MoveNext()) list.Add(e.GetTextElement());
    return list;
  }
  /// Foundation's `trimmingCharacters(in: .whitespaces)` (Zs and tab), or `.whitespacesAndNewlines` (all Z, LF to CR,
  /// NEL) when `newlines`.
  private static string SwiftTrim(string text, bool newlines)
  {
    bool Space(char c)
    {
      var category = char.GetUnicodeCategory(c);
      if (c == '\t' || category == UnicodeCategory.SpaceSeparator) return true;
      return newlines && (c is >= '\n' and <= '\r' || c == '\u0085' || category is UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator);
    }
    int start = 0, end = text.Length;
    while (start < end && Space(text[start])) start++;
    while (end > start && Space(text[end - 1])) end--;
    return text[start..end];
  }
  /// Swift's `lowercased()`: full lower-case mapping, letter by letter (only U+0130 becomes two letters).
  private static string SwiftLower(string text)
  {
    var output = new StringBuilder();
    foreach (var r in text.EnumerateRunes())
    {
      if (r.Value == 0x130) output.Append("i\u0307");
      else output.Append(Rune.ToLowerInvariant(r).ToString());
    }
    return output.ToString();
  }

  // ---- Files ----

  private static string At(string root, string relative) => Path.Combine([root, .. relative.Split('/')]);
  private static string Parent(string path) => Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(path)) ?? path;
  private static FileAttributes? Attributes(string path)
  {
    try { return File.GetAttributes(path); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  internal static bool Exists(string path) => Attributes(path) is not null;
  internal static bool IsLink(string path) => Attributes(path) is { } a && (a & FileAttributes.ReparsePoint) != 0;
  internal static bool RegularFile(string path) => Attributes(path) is { } a && (a & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0;
  internal static bool RealFolder(string path) => Attributes(path) is { } a && (a & FileAttributes.Directory) != 0 && (a & FileAttributes.ReparsePoint) == 0;
  private static string[] Names(string folder)
  {
    try { return new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = true }).Select(i => i.Name).ToArray(); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return []; }
  }
  private static byte[]? ReadBytes(string path)
  {
    try { return File.ReadAllBytes(path); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  private static string? ReadText(string path)
  {
    if (ReadBytes(path) is not { } bytes) return null;
    try { return new UTF8Encoding(false, true).GetString(bytes); }
    catch (DecoderFallbackException) { return null; }
  }
  private static string RelativeName(string path, string root)
  {
    var full = Path.GetFullPath(path);
    var basePath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
    return full.StartsWith(basePath, StringComparison.OrdinalIgnoreCase) ? full[basePath.Length..].Replace('\\', '/') : Path.GetFileName(path);
  }

  /// A new file: written beside, then moved into place; never over anything that appeared meanwhile.
  internal static bool CreateOnly(string path, byte[] bytes)
  {
    var folder = Parent(path);
    var temporary = Path.Combine(folder, ".terminaldeck-" + Guid.NewGuid().ToString("D").ToUpperInvariant());
    try
    {
      Directory.CreateDirectory(folder);
      using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Write(bytes);
      File.Move(temporary, path, overwrite: false);
      return true;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
    {
      Log?.Invoke("AI setup: " + Path.GetFileName(path) + " could not be made: " + e.Message);
      return false;
    }
    finally
    {
      try { if (File.Exists(temporary)) File.Delete(temporary); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log?.Invoke("AI setup: a temporary file was left beside " + Path.GetFileName(path) + ": " + e.Message); }
    }
  }
  /// Replaces a file the app may change, in one move.
  internal static bool ReplaceFile(string path, byte[] bytes)
  {
    if (!RegularFile(path)) return false;
    var temporary = Path.Combine(Parent(path), ".terminaldeck-" + Guid.NewGuid().ToString("D").ToUpperInvariant());
    try
    {
      using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Write(bytes);
      File.Move(temporary, path, overwrite: true);
      return true;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
    {
      Log?.Invoke("AI setup: " + Path.GetFileName(path) + " could not be updated: " + e.Message);
      return false;
    }
    finally
    {
      try { if (File.Exists(temporary)) File.Delete(temporary); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log?.Invoke("AI setup: a temporary file was left beside " + Path.GetFileName(path) + ": " + e.Message); }
    }
  }
}
