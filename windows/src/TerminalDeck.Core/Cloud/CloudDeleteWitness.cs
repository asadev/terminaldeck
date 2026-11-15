using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Cloud;

// The AI delete witness, ported from the Mac (td-mac-next2 BackendAIDeleteWitness.swift, BackendCloudDeleteWitness.swift)
// over the hook records Claude Code, Codex and Gemini send to this PC's app (the hook host forwards each accepted event
// with its tool name, tool input and working folder). It remembers, per Terminal Deck session, the recent AI commands
// that can remove files, with only the paths they name (never the command text), and answers one question for the Cloud
// engines: was this vanished file removed by an AI command running inside a Terminal Deck session on this PC?
// "By an AI" needs BOTH a time overlap AND a link between the command and the path. Anything it cannot know is by hand
// (the rule's own safe default): a wrong "by an AI" removes something from every device, a wrong "by hand" loses nothing.
// J-2: git, build and clean tools and inline code or scripts are never an AI's delete; the working-folder fallback
// counts only for plain removal commands whose targets cannot be read. Windows: the Git Bash words (rm, rmdir, unlink,
// mv, find -delete) as on the Mac, plus PowerShell and cmd (Remove-Item/ri/del/erase/rd, Move-Item/move/ren); a
// PowerShell or cmd script, `-Command`/`/c` text that cannot be read, or a script file = cannot know.

/// One accepted hook event (the hook host's raw fields). `ToolInput` is the `tool_input` object as it arrived.
public sealed record CloudHookToolEvent(string Provider, string Event, string? Session, string? ToolName, JsonElement? ToolInput, string? Cwd,
  string? ToolUseId, string? NotificationType, DateTimeOffset At);

/// The session's names as its row shows them: the title and the seat/agent, never the routing id.
public sealed record CloudWitnessSession(string? Title, string? Agent);

public sealed class CloudAiDeleteWitness : ICloudDeleteWitness
{
  public const double Tolerance = 2, MaxOpen = 3600, Keep = 86_400;
  public const int MaxWindows = 1000, FileVersion = 3;
  public const string FileName = "ai-delete-witness.json";

  public enum CoverKind { Path, Pattern, Folder }
  public sealed record Cover(CoverKind Kind, string Value, bool Subtree, string? Name = null, bool Caseless = false);
  public sealed class Window
  {
    public string Session { get; set; } = ""; public string Provider { get; set; } = ""; public string AgentName { get; set; } = ""; public string Tool { get; set; } = "";
    public string? ToolUseId { get; set; } public string Key { get; set; } = ""; public double Start { get; set; } public double? End { get; set; }
    public bool Background { get; set; } public List<Cover> Covers { get; set; } = []; public string Group { get; set; } = "";
    public string? SessionName { get; set; } public string? SeatName { get; set; } public bool Uncertain { get; set; }
    public bool Pending { get; set; } public bool Ran { get; set; } public bool StartUnseen { get; set; }
  }
  public enum Verdict { ByAi, ByHand, CannotKnow }
  private sealed class Saved { public int Version { get; set; } public List<Window> Windows { get; set; } = []; }

  private readonly object gate = new();
  private readonly string? file;
  private readonly string home;
  private List<Window> windows = [];
  public DateTimeOffset ListeningSince { get; }

  public CloudAiDeleteWitness(string? dataRoot, string home, DateTimeOffset now)
  {
    file = dataRoot is null ? null : Path.Combine(dataRoot, FileName);
    this.home = Normalize(home);
    ListeningSince = now;
    try
    {
      if (file is not null && File.Exists(file) && new FileInfo(file).Length < 4 * 1024 * 1024
        && JsonSerializer.Deserialize<Saved>(File.ReadAllBytes(file)) is { Version: FileVersion } saved)
      {
        windows = saved.Windows;
        Prune(now.ToUnixTimeMilliseconds() / 1000.0);
      }
    }
    catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
  }

  // ---- Answering ----

  public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt)
  {
    var (verdict, window) = Assessment(removedPath, lastSeen, seenGoneAt, DateTimeOffset.UtcNow);
    return Task.FromResult(verdict switch
    {
      // Names are captured at the command's start, not looked up after a rename or session removal.
      Verdict.ByAi when window is { SessionName: { } name } && CloudDeleteText.IsUuid(window.Group) =>
        CloudDeleteWitnessAnswer.Ai(name, window.SeatName, DateTimeOffset.FromUnixTimeMilliseconds((long)(window.Start * 1000)), window.Group),
      Verdict.ByHand => CloudDeleteWitnessAnswer.NotAi,
      _ => CloudDeleteWitnessAnswer.CannotKnow
    });
  }

  public (Verdict Verdict, Window? Window) Assessment(string path, DateTimeOffset lastSeen, DateTimeOffset goneAt, DateTimeOffset now)
  {
    var target = Normalize(path);
    if (!Rooted(target)) return (Verdict.CannotKnow, null);
    double from = Math.Min(lastSeen.ToUnixTimeMilliseconds(), goneAt.ToUnixTimeMilliseconds()) / 1000.0, to = Math.Max(lastSeen.ToUnixTimeMilliseconds(), goneAt.ToUnixTimeMilliseconds()) / 1000.0;
    var clock = now.ToUnixTimeMilliseconds() / 1000.0;
    Window[] snapshot;
    lock (gate) snapshot = windows.ToArray();
    (int Strength, Window Window)? best = null;
    bool uncertain = false, unseenLink = false;
    foreach (var window in snapshot)
    {
      // Asked for permission and never seen running: refused, denied, or not run yet. Never counts.
      if (window.Pending) continue;
      var end = window.End ?? Math.Min(clock, window.Start + MaxOpen);
      if (!(window.Start - Tolerance <= to && end + Tolerance >= from)) continue;
      if (window.Uncertain) uncertain = true;
      var strength = window.Covers.Select(c => Strength(c, target)).DefaultIfEmpty(0).Max();
      if (strength <= 0) continue;
      if (window.StartUnseen) { unseenLink = true; continue; }
      if (best is { } b && (b.Strength > strength || b.Strength == strength && (b.Window.Start > window.Start
        || b.Window.Start == window.Start && string.CompareOrdinal(b.Window.Session, window.Session) >= 0))) continue;
      best = (strength, window);
    }
    // A script supplies no path evidence; an independently named target still counts.
    if (best is { } found && (!uncertain || found.Strength > 1)) return (Verdict.ByAi, found.Window);
    if (uncertain || unseenLink) return (Verdict.CannotKnow, null);
    if (from < ListeningSince.ToUnixTimeMilliseconds() / 1000.0 || from < clock - Keep) return (Verdict.CannotKnow, null);
    return (Verdict.ByHand, null);
  }

  // ---- Feeding ----

  public void Accept(CloudHookToolEvent e, CloudWitnessSession? row)
  {
    if (e.Session is not { } session) return;
    var time = e.At.ToUnixTimeMilliseconds() / 1000.0;
    switch (e.Event)
    {
      case "PreToolUse" or "BeforeTool":
      {
        if (e.ToolName is not { } tool || Reading(tool, e.ToolInput, e.Cwd, home) is not { } reading) return;
        var window = NewWindow(e, session, tool, reading, time, row);
        Mutate(time, list => { if (OpenMatch(list, session, tool, e.ToolUseId, reading.Key, pendingOnly: true) is null) list.Add(window); });
        break;
      }
      case "PermissionRequest":
      {
        if (e.ToolName is not { } tool || Reading(tool, e.ToolInput, e.Cwd, home) is not { } reading) return;
        var window = NewWindow(e, session, tool, reading, time, row);
        window.Pending = true;
        Mutate(time, list => { if (OpenMatch(list, session, tool, e.ToolUseId, reading.Key) is { } m) list[m].Pending = true; else list.Add(window); });
        break;
      }
      case "Notification":
      {
        if ((e.NotificationType ?? "").ToLowerInvariant() is not ("toolpermission" or "permission_prompt")) return;
        Mutate(time, list => { var i = list.FindLastIndex(w => w.Session == session && w.End is null && !w.Ran); if (i >= 0) list[i].Pending = true; });
        break;
      }
      case "PostToolUse" or "PostToolUseFailure" or "AfterTool":
      {
        if (e.ToolName is not { } tool || Reading(tool, e.ToolInput, e.Cwd, home) is not { } reading) return;
        var failed = e.Event == "PostToolUseFailure";
        Mutate(time, list =>
        {
          if (OpenMatch(list, session, tool, e.ToolUseId, reading.Key) is { } m)
          {
            list[m].Ran = true;
            if (!failed) list[m].Pending = false;
            if (!list[m].Background) list[m].End = time;
          }
          else
          {
            // The start was never seen: its paths are cannot-know, never a backdated "by an AI" window.
            var w = NewWindow(e, session, tool, reading, time, row);
            w.Start = Math.Min(Math.Max(ListeningSince.ToUnixTimeMilliseconds() / 1000.0, time - MaxOpen), time);
            w.End = time; w.Uncertain = false; w.Ran = true; w.StartUnseen = true;
            list.Add(w);
          }
        });
        break;
      }
      case "Stop" or "StopFailure" or "AfterAgent": Close(session, time, background: false); break;
      case "SessionEnd": Close(session, time, background: true); break;
    }
  }
  /// The session exited or was removed: nothing it started is counted after this.
  public void SessionEnded(string session, DateTimeOffset at) => Close(session, at.ToUnixTimeMilliseconds() / 1000.0, background: true);

  private static Window NewWindow(CloudHookToolEvent e, string session, string tool, ReadingResult r, double time, CloudWitnessSession? row) => new()
  {
    Session = session, Provider = e.Provider, AgentName = AgentName(row, e.Provider), Tool = tool, ToolUseId = string.IsNullOrEmpty(e.ToolUseId) ? null : e.ToolUseId,
    Key = r.Key, Start = time, Background = r.Background, Covers = r.Covers, Group = Guid.NewGuid().ToString("D").ToUpperInvariant(),
    SessionName = Clean(row?.Title), SeatName = SeatName(row), Uncertain = r.Uncertain
  };
  private static int? OpenMatch(List<Window> list, string session, string tool, string? id, string key, bool pendingOnly = false)
  {
    var open = Enumerable.Range(0, list.Count).Where(i => list[i].Session == session && list[i].End is null && list[i].Tool == tool && (!pendingOnly || list[i].Pending)).ToArray();
    if (!string.IsNullOrEmpty(id) && open.FirstOrDefault(i => list[i].ToolUseId == id, -1) is >= 0 and var byId) return byId;
    return open.FirstOrDefault(i => list[i].Key == key, -1) is >= 0 and var byKey ? byKey : null;
  }
  private void Close(string session, double time, bool background) =>
    Mutate(time, list => { foreach (var w in list.Where(w => w.Session == session && w.End is null && (background || !w.Background))) w.End = time; });
  private void Mutate(double time, Action<List<Window>> change)
  {
    lock (gate)
    {
      change(windows);
      Prune(time);
      Save();
    }
  }
  private void Prune(double now)
  {
    windows.RemoveAll(w => (w.End ?? w.Start + MaxOpen) < now - Keep);
    if (windows.Count > MaxWindows) windows.RemoveRange(0, windows.Count - MaxWindows);
  }
  private void Save()
  {
    if (file is null) return;
    try { new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(new Saved { Version = FileVersion, Windows = windows })); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
  }

  private static string? Clean(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
  public static string AgentName(CloudWitnessSession? row, string provider) => Clean(row?.Agent) ?? provider switch
  {
    "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini", _ => provider
  };
  public static string? SeatName(CloudWitnessSession? row) =>
    Clean(row?.Agent) is { } agent && agent.ToLowerInvariant() is not ("claude" or "claude code" or "codex" or "gemini") ? agent : null;

  // ---- Reading one tool call (paths only) ----

  public sealed record ReadingResult(List<Cover> Covers, bool Background, string Key, bool Uncertain);
  public static readonly IReadOnlySet<string> ShellTools = new HashSet<string> { "bash", "shell", "exec_command", "local_shell", "shell_command", "unified_exec",
    "run_shell_command", "container.exec", "powershell" };
  public static readonly IReadOnlySet<string> DeleteTools = new HashSet<string> { "delete_file", "remove_file", "deletefile", "removefile", "delete_path", "remove_path" };
  private static bool DeleteTool(string name) => DeleteTools.Contains(name) || DeleteTools.Any(t => name.StartsWith("mcp__", StringComparison.Ordinal) && name.EndsWith("__" + t, StringComparison.Ordinal));

  private static string? Str(JsonElement? o, string key) =>
    o is { ValueKind: JsonValueKind.Object } v && v.TryGetProperty(key, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
  private static bool Flag(JsonElement? o, string key) => o is { ValueKind: JsonValueKind.Object } v && v.TryGetProperty(key, out var p) && p.ValueKind == JsonValueKind.True;

  public static ReadingResult? Reading(string tool, JsonElement? input, string? cwd, string home)
  {
    var name = tool.ToLowerInvariant();
    var root = cwd is null ? null : Normalize(Expand(cwd, home)) is var c && Rooted(c) ? c : null;
    foreach (var key in new[] { "workdir", "dir_path", "directory", "cwd" })
    {
      if (Str(input, key) is not { Length: > 0 } value) continue;
      var expanded = Expand(value, home);
      root = Rooted(Normalize(expanded)) ? Normalize(expanded) : root is null ? null : Normalize(root + "/" + expanded);
      break;
    }
    if (ShellTools.Contains(name))
    {
      if (CommandText(input) is not { } command) return null;
      var parsed = ShellCovers(command, root, home, 0, powershell: name == "powershell");
      if (parsed.Covers.Count == 0 && !parsed.Uncertain) return null;
      return new(parsed.Covers, parsed.Background || Flag(input, "run_in_background") || Flag(input, "is_background"), Hash(name + "\0" + command), parsed.Uncertain);
    }
    if (DeleteTool(name))
    {
      foreach (var key in new[] { "file_path", "notebook_path", "absolute_path", "path", "filePath" })
        if (Str(input, key) is { Length: > 0 } value && Resolve(value, root, home) is { } resolved)
          return new([new(CoverKind.Path, resolved, false)], false, Hash(name + "\0" + resolved), false);
      return null;
    }
    if (name is "apply_patch" or "applypatch")
    {
      var text = Str(input, "patch") ?? Str(input, "input") ?? Str(input, "command");
      if (text is null && input is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty("command", out var arr) && arr.ValueKind == JsonValueKind.Array)
        text = arr.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).FirstOrDefault(x => x.Contains("*** Begin Patch", StringComparison.Ordinal));
      if (text is null) return null;
      var covers = new List<Cover>();
      string? updating = null;
      foreach (var raw in text.Split('\n'))
      {
        var line = raw.Trim();
        if (line.StartsWith("*** Delete File:", StringComparison.Ordinal)) { if (Resolve(line[16..].Trim(), root, home) is { } r) covers.Add(new(CoverKind.Path, r, false)); }
        else if (line.StartsWith("*** Update File:", StringComparison.Ordinal)) updating = Resolve(line[16..].Trim(), root, home);
        else if (line.StartsWith("*** Move to:", StringComparison.Ordinal) && updating is not null) covers.Add(new(CoverKind.Path, updating, false));
        else if (line.StartsWith("*** Add File:", StringComparison.Ordinal)) updating = null;
      }
      return covers.Count == 0 ? null : new(covers, false, Hash(name + "\0" + text), false);
    }
    return null;
  }

  public static string? CommandText(JsonElement? input)
  {
    if ((Str(input, "command") ?? Str(input, "cmd")) is { Length: > 0 } text) return text;
    if (input is not { ValueKind: JsonValueKind.Object } o) return null;
    JsonElement arr = default;
    if (!(o.TryGetProperty("command", out arr) && arr.ValueKind == JsonValueKind.Array) && !(o.TryGetProperty("cmd", out arr) && arr.ValueKind == JsonValueKind.Array)) return null;
    var parts = arr.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray();
    if (parts.Length == 0) return null;
    // Codex's argv form: ["bash", "-lc", "<script>"] carries the script as one element.
    if (parts.Length >= 3 && Shells.Contains(Leaf(parts[0])) && parts[1].StartsWith('-') && parts[1].Contains('c')) return parts[2];
    return string.Join(" ", parts.Select(p => "'" + p.Replace("'", "'\\''") + "'"));
  }

  // ---- Shell text -> covers ----

  public sealed record Word(string Text, string Pattern, bool Dynamic, bool Glob);
  private sealed record Chunk(List<Word> Words, bool Background, bool Grouped);

  private static readonly HashSet<string> Removers = ["rm", "rmdir", "unlink", "trash", "trash-put", "srm", "shred", "rimraf", "del", "del-cli", "erase", "rd",
    "remove-item", "ri", "rmdir.exe", "del.exe"];
  private static readonly HashSet<string> FlatRemovers = ["unlink", "shred"];
  private static readonly HashSet<string> Movers = ["mv", "move", "move-item", "mi", "ren", "rename", "rename-item", "rni"];
  private static readonly HashSet<string> Wrappers = ["sudo", "command", "builtin", "exec", "nohup", "time", "nice", "setsid", "noglob", "env", "doas", "start", "start-process"];
  private static readonly HashSet<string> Detachers = ["nohup", "setsid", "disown", "start", "start-process"];
  private static readonly HashSet<string> Cleaners = ["make", "gmake", "cargo", "go", "swift", "xcodebuild", "gradle", "gradlew", "mvn", "dotnet", "flutter", "npm", "yarn",
    "pnpm", "bun", "ant", "msbuild", "nuget", "cmake", "ninja", "pip", "winget", "choco"];
  private static readonly HashSet<string> Interpreters = ["python", "python3", "py", "node", "perl", "ruby", "deno", "php", "osascript", "wscript", "cscript"];
  private static readonly HashSet<string> FolderFallback = ["rm", "unlink", "trash", "mv", "del", "erase", "remove-item", "ri", "move", "move-item", "mi"];
  private static readonly HashSet<string> Keywords = ["if", "then", "else", "elif", "while", "until", "do", "!", "{", "foreach", "for"];
  private static readonly HashSet<string> Shells = ["bash", "sh", "zsh", "dash", "bash.exe", "sh.exe"];
  private static readonly HashSet<string> PowerShells = ["powershell", "pwsh", "powershell.exe", "pwsh.exe"];
  private static readonly HashSet<string> Cmds = ["cmd", "cmd.exe"];

  private static string Leaf(string text) { var t = text.Replace('\\', '/'); return t[(t.LastIndexOf('/') + 1)..].ToLowerInvariant(); }
  private static bool Script(string verb) => Interpreters.Contains(verb) || verb.StartsWith("python", StringComparison.Ordinal)
    || new[] { ".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".cjs", ".rb", ".pl", ".php", ".ps1", ".psm1", ".bat", ".cmd", ".vbs" }.Any(x => verb.EndsWith(x, StringComparison.Ordinal));

  public static (List<Cover> Covers, bool Background, bool Uncertain) ShellCovers(string command, string? start, string home, int depth, bool powershell = false, bool cmd = false)
  {
    var covers = new List<Cover>();
    bool background = false, uncertain = false;
    var cwd = start;
    foreach (var chunk in Chunks(command, powershell ? 1 : cmd ? 2 : 0))
    {
      var words = chunk.Words.ToList();
      var detached = chunk.Background;
      while (words.Count > 0)
      {
        var first = words[0];
        var name = Leaf(first.Text);
        if (!first.Dynamic && Regex.IsMatch(first.Text, "^[A-Za-z_][A-Za-z0-9_]*=")) { words.RemoveAt(0); continue; }
        if (first.Dynamic || !Wrappers.Contains(name)) break;
        if (Detachers.Contains(name)) detached = true;
        words.RemoveAt(0);
        if (name == "nice" && words.Count > 1 && words[0].Text == "-n") words.RemoveRange(0, 2);
        while (words.Count > 0 && words[0].Text.StartsWith('-') && words[0].Text != "-") words.RemoveAt(0);
      }
      if (words.Count > 0 && Keywords.Contains(words[0].Text.ToLowerInvariant()))
      {
        if (words.SkipWhile(w => Keywords.Contains(w.Text.ToLowerInvariant())).FirstOrDefault() is { } v && Leaf(v.Text) is "cd" or "pushd" or "popd" or "set-location" or "sl" or "chdir") cwd = null;
        continue;
      }
      if (words.Count == 0) continue;
      var head = words[0];
      if (head.Dynamic) continue;
      var verb = Leaf(head.Text);
      var args = words.Skip(1).ToList();
      if (Detachers.Contains(verb)) { background = true; continue; }
      if (verb is "cd" or "pushd" or "popd" or "set-location" or "sl" or "chdir")
      {
        var operands = args.Where(a => !a.Text.StartsWith('-') || a.Text == "-").Where(a => !a.Text.StartsWith('/') || Rooted(Normalize(a.Text))).ToList();
        if (verb == "popd" || chunk.Grouped) { cwd = null; continue; }
        if (operands.FirstOrDefault() is { } target)
        {
          var unsure = target.Text == "-" || target.Text.StartsWith('+') || target.Glob || target.Dynamic;
          cwd = unsure ? null : Resolve(target.Text, cwd, home);
        }
        else cwd = verb == "cd" ? Normalize(home) : null;
        continue;
      }
      // Inner shell text: bash -c, cmd /c, powershell -Command. Text that cannot be read = cannot know.
      string? inner = null;
      bool innerPowershell = false, innerCmd = false;
      if (Shells.Contains(verb) && args.FindIndex(a => a.Text.StartsWith('-') && !a.Text.StartsWith("--", StringComparison.Ordinal) && a.Text.Contains('c')) is >= 0 and var f && f + 1 < args.Count)
        inner = args[f + 1].Dynamic ? null : args[f + 1].Text;
      else if (Cmds.Contains(verb) && args.FindIndex(a => a.Text.Equals("/c", StringComparison.OrdinalIgnoreCase) || a.Text.Equals("/k", StringComparison.OrdinalIgnoreCase)) is >= 0 and var g && g + 1 < args.Count)
      { inner = args.Skip(g + 1).Any(a => a.Dynamic) ? null : string.Join(" ", args.Skip(g + 1).Select(a => a.Text)); innerCmd = true; }
      else if (PowerShells.Contains(verb) && args.FindIndex(a => a.Text.ToLowerInvariant() is "-c" or "-command" or "-co" or "-com") is >= 0 and var h && h + 1 < args.Count)
      { inner = args.Skip(h + 1).Any(a => a.Dynamic) ? null : string.Join(" ", args.Skip(h + 1).Select(a => a.Text)); innerPowershell = true; }
      if (Shells.Contains(verb) || Cmds.Contains(verb) || PowerShells.Contains(verb))
      {
        if (inner is not null && depth < 3)
        {
          var nested = ShellCovers(inner, cwd, home, depth + 1, innerPowershell, innerCmd);
          covers.AddRange(nested.Covers);
          uncertain |= nested.Uncertain;
          if ((nested.Background || detached) && (nested.Covers.Count > 0 || nested.Uncertain)) background = true;
        }
        else { uncertain = true; if (detached) background = true; }
        continue;
      }
      // Scripts and inline code can remove arbitrary paths. Keep only uncertainty.
      if (Script(verb) || verb == "swift" && args.FirstOrDefault(a => !a.Text.StartsWith('-'))?.Text.EndsWith(".swift", StringComparison.Ordinal) == true
        || !Removers.Contains(verb) && !Movers.Contains(verb) && !Cleaners.Contains(verb) && verb is not ("git" or "find" or "rsync" or "xargs" or "npx" or "pnpx" or "bunx")
        && (head.Text.Contains('/') || head.Text.Contains('\\')))
      {
        uncertain = true;
        if (detached) background = true;
        continue;
      }
      var found = Classify(verb, args, cwd, home, true);
      if (found.Count > 0) { covers.AddRange(found); if (detached) background = true; }
    }
    return (covers.Distinct().ToList(), background, uncertain);
  }

  private static bool IsFlag(string text) => text.Length > 1 && (text[0] == '-' || text[0] == '/' && text.Length <= 3 && char.IsLetter(text[1]));

  public static List<Cover> Classify(string verb, List<Word> args, string? cwd, string home, bool allowFallback)
  {
    List<Word> NonFlags(IEnumerable<Word> words)
    {
      var outList = new List<Word>();
      var ended = false;
      var skipNext = false;
      foreach (var w in words)
      {
        if (skipNext) { skipNext = false; continue; }
        if (!ended && w.Text == "--" && !w.Dynamic) { ended = true; continue; }
        if (!ended && IsFlag(w.Text))
        {
          // PowerShell parameters that take a value which is not a target.
          if (w.Text.ToLowerInvariant() is "-credential" or "-stream" or "-destination") skipNext = true;
          continue;
        }
        outList.Add(w);
      }
      return outList;
    }
    List<Cover> Wide(string? at) => at is null ? [] : [new(CoverKind.Folder, at, true)];
    List<Cover> Targets(List<Word> operands, bool subtree, string? at, bool fallback = false)
    {
      var outList = new List<Cover>();
      foreach (var word in operands)
      {
        if (word.Dynamic || CoverOf(word, at, home, subtree) is not { } cover) return [.. outList, .. fallback && allowFallback ? Wide(at) : []];
        outList.Add(cover);
      }
      return outList;
    }
    var lowered = args.Select(a => a.Text.ToLowerInvariant()).ToList();
    var flags = args.Where(a => a.Text.StartsWith('-') && !a.Text.StartsWith("--", StringComparison.Ordinal)).Select(a => a.Text).ToList();
    var recursive = verb is "remove-item" or "ri"
      ? lowered.Any(t => t.Length >= 2 && "-recurse".StartsWith(t, StringComparison.Ordinal))
      : flags.Any(f => f.Contains('r') || f.Contains('R')) || lowered.Contains("--recursive") || lowered.Contains("/s");
    if (Removers.Contains(verb))
    {
      // A filter makes the removed names unreadable from the text: only the working-folder fallback.
      if (lowered.Any(t => t is "-include" or "-exclude" or "-filter")) return allowFallback ? Wide(cwd) : [];
      // rm, PowerShell's Remove-Item and cmd's del/erase remove a folder's contents only when told to recurse.
      var flat = FlatRemovers.Contains(verb) || verb is "rmdir" or "rmdir.exe" || verb is "rm" or "remove-item" or "ri" or "del" or "erase" or "del.exe" && !recursive;
      var found = Targets(NonFlags(args), !flat, cwd, FolderFallback.Contains(verb));
      // rmdir/rd remove an (empty) folder: written-out paths only.
      return verb is "rmdir" or "rmdir.exe" || verb == "rd" && !recursive ? found.Where(c => c.Kind == CoverKind.Path).ToList() : found;
    }
    if (Movers.Contains(verb))
    {
      var operands = NonFlags(args);
      if (args.Any(a => a.Text == "-t" || a.Text.StartsWith("--target-directory", StringComparison.Ordinal))) return Targets(operands.Skip(1).ToList(), true, cwd, true);
      if (operands.Count < 2) return verb is "move-item" or "mi" && operands.Count == 1 ? Targets(operands, true, cwd, true) : [];
      return Targets(operands.Take(operands.Count - 1).ToList(), true, cwd, true);
    }
    switch (verb)
    {
      case "xargs":
      {
        var rest = args.ToList();
        while (rest.Count > 0 && rest[0].Text.StartsWith('-'))
        {
          var w = rest[0].Text; rest.RemoveAt(0);
          if (w is "-n" or "-I" or "-L" or "-P" or "-d" or "-E" or "-s" or "-J" && rest.Count > 0) rest.RemoveAt(0);
        }
        if (rest.Count == 0 || rest[0].Dynamic) return [];
        return Classify(Leaf(rest[0].Text), rest.Skip(1).ToList(), cwd, home, false);
      }
      case "npx" or "pnpx" or "bunx":
      {
        var at = args.FindIndex(a => !a.Text.StartsWith('-'));
        if (at < 0 || args[at].Dynamic) return [];
        return Classify(Leaf(args[at].Text), args.Skip(at + 1).ToList(), cwd, home, false);
      }
      case "find":
      {
        var texts = args.Select(a => a.Text).ToList();
        var removing = texts.Contains("-delete") || Enumerable.Range(0, texts.Count).Any(i => texts[i] is "-exec" or "-execdir" or "-ok" or "-okdir" && i + 1 < texts.Count
          && (Removers.Contains(Leaf(texts[i + 1])) || Leaf(texts[i + 1]) == "mv"));
        if (!removing) return [];
        var starts = args.TakeWhile(a => !a.Text.StartsWith('-') && a.Text != "(" && a.Text != "!").ToList();
        var fallback = texts.Contains("-delete");
        if (fallback && FindName(args) is { } name)
        {
          List<Cover> Named(List<Cover> c) => c.Select(x => x with { Subtree = true, Name = name.Name, Caseless = name.Caseless }).ToList();
          return starts.Count == 0 ? Named(allowFallback ? Wide(cwd) : []) : Named(Targets(starts, true, cwd, true));
        }
        return starts.Count == 0 ? (fallback && allowFallback ? Wide(cwd) : []) : Targets(starts, true, cwd, fallback);
      }
      case "rsync":
      {
        var deleting = lowered.Any(t => t.StartsWith("--delete", StringComparison.Ordinal));
        var moving = lowered.Contains("--remove-source-files");
        if (!deleting && !moving) return [];
        var operands = NonFlags(args);
        if (operands.Count == 0 || operands[^1].Text.Contains(':')) return [];
        var outList = new List<Cover>();
        if (deleting) outList.AddRange(Targets([operands[^1]], true, cwd));
        if (moving) outList.AddRange(Targets(operands.Take(operands.Count - 1).ToList(), true, cwd));
        return outList;
      }
      // Git, build and clean tools own their side effects (J-2): never an AI's delete.
      default: return [];
    }
  }

  private static (string Name, bool Caseless)? FindName(List<Word> args)
  {
    var texts = args.Select(a => a.Text).ToList();
    if (texts.Any(t => t is "-o" or "-or" or "!" or "-not" or "," or "-prune")) return null;
    var i = texts.FindIndex(t => t is "-name" or "-iname");
    if (i < 0 || i + 1 >= args.Count || args[i + 1].Dynamic || args[i + 1].Text.Length == 0 || args[i + 1].Text.Contains('/')) return null;
    return (args[i + 1].Text, texts[i] == "-iname");
  }

  private static Cover? CoverOf(Word word, string? cwd, string home, bool subtree)
  {
    if (word.Dynamic) return null;
    if (!word.Glob) return Resolve(word.Text, cwd, home) is { } resolved ? new(CoverKind.Path, resolved, subtree) : null;
    var pattern = word.Pattern.Replace('\\', '/');
    if (pattern.StartsWith("~/", StringComparison.Ordinal)) pattern = Escape(Normalize(home)) + pattern[1..];
    else if (!Rooted(pattern)) { if (cwd is null) return null; pattern = Escape(cwd) + "/" + pattern; }
    while (pattern.EndsWith('/') && pattern.Length > 1) pattern = pattern[..^1];
    return new(CoverKind.Pattern, pattern, subtree);
  }

  // ---- Tokens ----

  /// `shell`: 0 bash (a backslash escapes), 1 PowerShell (a backslash is a letter, `$x` is a variable), 2 cmd (a
  /// backslash is a letter, `%x%` is a variable).
  private static List<Chunk> Chunks(string source, int shell)
  {
    var powershell = shell == 1;
    var literalBackslash = shell != 0;
    var chunks = new List<Chunk>();
    var words = new List<Word>();
    var text = new StringBuilder(); var pattern = new StringBuilder();
    bool inWord = false, dynamic = false, glob = false, grouped = false;
    void EndWord()
    {
      if (inWord) words.Add(new(text.ToString(), pattern.ToString(), dynamic, glob));
      text.Clear(); pattern.Clear(); inWord = false; dynamic = false; glob = false;
    }
    void EndChunk(bool background)
    {
      EndWord();
      if (words.Count > 0) chunks.Add(new(words, background, grouped));
      words = [];
    }
    void Literal(char c) { inWord = true; text.Append(c); pattern.Append("*?[]\\".Contains(c) ? "\\" + c : c.ToString()); }
    var i = 0;
    while (i < source.Length)
    {
      var c = source[i];
      char? Peek(int o) => i + o < source.Length ? source[i + o] : null;
      if (c == '\'')
      {
        var end = source.IndexOf('\'', i + 1);
        if (end < 0) end = source.Length;
        foreach (var ch in source[(i + 1)..end]) Literal(ch);
        inWord = true; i = end + 1; continue;
      }
      if (c == '"')
      {
        i++; inWord = true;
        while (i < source.Length && source[i] != '"')
        {
          if (source[i] == '\\' && !literalBackslash && i + 1 < source.Length && "\"\\$`".Contains(source[i + 1])) { Literal(source[i + 1]); i += 2; continue; }
          if (source[i] is '$' or '`' && !(powershell && source[i] == '`') || source[i] == '%' && source.IndexOf('%', i + 1) > i + 1) dynamic = true;
          Literal(source[i]); i++;
        }
        i++; continue;
      }
      if (!literalBackslash && c == '\\' && i + 1 < source.Length)
      {
        if (source[i + 1] == '\n') { i += 2; continue; }
        Literal(source[i + 1]); i += 2; continue;
      }
      if (c is '$' or '`' && !(powershell && c == '`') || c == '%' && source.IndexOf('%', i + 1) > i + 1 && shell != 1)
      {
        dynamic = true; inWord = true; text.Append(c); pattern.Append(c);
        if (c == '$' && Peek(1) == '(')
        {
          // $( ... ): skip to the matching parenthesis.
          var level = 0;
          for (; i < source.Length; i++) { text.Append(source[i]); if (source[i] == '(') level++; else if (source[i] == ')' && --level == 0) break; }
        }
        i++; continue;
      }
      if (c is '*' or '?' || c == '[' && source.IndexOf(']', i + 1) > i) { inWord = true; glob = true; text.Append(c); pattern.Append(c); i++; continue; }
      if (c is ' ' or '\t') { EndWord(); i++; continue; }
      if (c is '\n' or ';' or '\r') { EndChunk(false); grouped = false; i++; continue; }
      if (c == '&')
      {
        if (Peek(1) == '&') { EndChunk(false); i += 2; continue; }
        if (powershell && words.Count == 0 && !inWord) { i++; continue; } // the call operator
        EndChunk(true); i++; continue;
      }
      if (c == '|') { EndChunk(false); i += Peek(1) == '|' ? 2 : 1; continue; }
      if (c == '(' && !inWord && words.Count == 0) { grouped = true; i++; continue; }
      if (c == ')' && !inWord) { EndChunk(false); grouped = false; i++; continue; }
      if (c is '>' or '<')
      {
        // A file-descriptor number in front of a redirection (`2>&1`) is not a word.
        if (inWord && text.Length > 0 && text.ToString().All(char.IsAsciiDigit)) { text.Clear(); pattern.Clear(); inWord = false; dynamic = false; glob = false; }
        EndWord(); i++;
        while (i < source.Length && source[i] is '>' or '&' or ' ') i++;
        while (i < source.Length && source[i] is not (' ' or '\n' or ';' or '&' or '|')) i++;
        continue;
      }
      if (c == '#' && !inWord) { while (i < source.Length && source[i] != '\n') i++; continue; }
      if (c == '~' && !inWord) { inWord = true; text.Append(c); pattern.Append(c); i++; continue; }
      Literal(c); i++;
    }
    EndChunk(false);
    return chunks;
  }

  // ---- Linking ----

  /// 3 = names the path; 2 = names a folder above it and removes recursively; 1 = ran in a folder above it with targets
  /// the text does not show; 0 = no link.
  public static int Strength(Cover cover, string path)
  {
    if (cover.Name is { } name)
    {
      if (!GlobMatch(name, path[(path.LastIndexOf('/') + 1)..], pathname: false, caseless: true)) return 0;
      return Math.Min(Strength(cover with { Name = null, Caseless = false }, path), 2);
    }
    switch (cover.Kind)
    {
      case CoverKind.Path:
        if (Same(path, cover.Value)) return 3;
        return cover.Subtree && Within(path, cover.Value) ? 2 : 0;
      case CoverKind.Pattern:
        if (GlobMatch(cover.Value, path, pathname: true, caseless: true)) return 3;
        if (!cover.Subtree) return 0;
        for (var ancestor = Parent(path); ancestor is not null; ancestor = Parent(ancestor))
          if (GlobMatch(cover.Value, ancestor, pathname: true, caseless: true)) return 2;
        return 0;
      default:
        return Same(path, cover.Value) || Within(path, cover.Value) ? 1 : 0;
    }
  }
  private static string? Parent(string path)
  {
    var cut = path.LastIndexOf('/');
    if (cut <= 0) return null;
    var parent = path[..cut];
    return parent.Length == 2 && parent[1] == ':' ? null : parent;
  }
  private static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
  private static bool Within(string path, string folder) =>
    folder == "/" ? path.StartsWith('/') && path != "/" : path.StartsWith(folder.TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase);

  /// fnmatch: `*` and `?` never cross a `/` when `pathname`; `[...]` classes; `\` escapes.
  public static bool GlobMatch(string pattern, string text, bool pathname, bool caseless)
  {
    bool Eq(char a, char b) => caseless ? char.ToLowerInvariant(a) == char.ToLowerInvariant(b) : a == b;
    bool Match(int p, int t)
    {
      while (p < pattern.Length)
      {
        var c = pattern[p];
        if (c == '*')
        {
          while (p < pattern.Length && pattern[p] == '*') p++;
          if (p == pattern.Length) return !pathname || text.IndexOf('/', t) < 0;
          for (var k = t; k <= text.Length; k++)
          {
            if (Match(p, k)) return true;
            if (k < text.Length && pathname && text[k] == '/') return false;
          }
          return false;
        }
        if (t >= text.Length) return false;
        if (c == '?') { if (pathname && text[t] == '/') return false; p++; t++; continue; }
        if (c == '[' && pattern.IndexOf(']', p + 2) is > 0 and var close)
        {
          var set = pattern[(p + 1)..close];
          var negate = set.StartsWith('!') || set.StartsWith('^');
          if (negate) set = set[1..];
          var hit = false;
          for (var k = 0; k < set.Length; k++)
            if (k + 2 < set.Length && set[k + 1] == '-') { if (text[t] >= set[k] && text[t] <= set[k + 2] || caseless && char.ToLowerInvariant(text[t]) >= char.ToLowerInvariant(set[k]) && char.ToLowerInvariant(text[t]) <= char.ToLowerInvariant(set[k + 2])) hit = true; k += 2; }
            else if (Eq(set[k], text[t])) hit = true;
          if (hit == negate || pathname && text[t] == '/') return false;
          p = close + 1; t++; continue;
        }
        if (c == '\\' && p + 1 < pattern.Length) { p++; c = pattern[p]; }
        if (!Eq(c, text[t])) return false;
        p++; t++;
      }
      return t == text.Length;
    }
    return Match(0, 0);
  }
  private static string Escape(string literal)
  {
    var sb = new StringBuilder();
    foreach (var c in literal) { if ("*?[]\\".Contains(c)) sb.Append('\\'); sb.Append(c); }
    return sb.ToString();
  }

  // ---- Paths ----

  /// Rooted: `/x` (a POSIX or Git Bash path) or `C:/x`.
  public static bool Rooted(string path) => path.StartsWith('/') || path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '/';
  private static string Expand(string path, string home) => path == "~" ? home : path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal) ? home + path[1..] : path;
  public static string? Resolve(string raw, string? cwd, string home)
  {
    var text = Expand(raw, home).Replace('\\', '/');
    if (text.StartsWith('~')) return null;
    if (Rooted(Normalize(text))) return Normalize(text);
    if (cwd is null || !Rooted(cwd)) return null;
    return Normalize(cwd + "/" + text);
  }
  /// One spelling for a path: `/` separators, `.`/`..` folded, no trailing slash, a drive letter in capitals, Git
  /// Bash's `/c/x` as `C:/x`.
  public static string Normalize(string path)
  {
    var text = path.Replace('\\', '/');
    var drive = "";
    if (text.Length >= 2 && char.IsAsciiLetter(text[0]) && text[1] == ':') { drive = char.ToUpperInvariant(text[0]) + ":"; text = text[2..]; if (!text.StartsWith('/')) return path; }
    else if (Regex.IsMatch(text, "^/[A-Za-z](/|$)")) { drive = char.ToUpperInvariant(text[1]) + ":"; text = text[2..]; if (text.Length == 0) text = "/"; }
    else if (!text.StartsWith('/')) return path;
    var parts = new List<string>();
    foreach (var part in text.Split('/', StringSplitOptions.RemoveEmptyEntries))
    {
      if (part == ".") continue;
      if (part == "..") { if (parts.Count > 0) parts.RemoveAt(parts.Count - 1); continue; }
      parts.Add(part);
    }
    return drive + "/" + string.Join('/', parts);
  }
  /// FNV-1a: pairs a start with its end without keeping the command text.
  private static string Hash(string text)
  {
    ulong value = 0xcbf29ce484222325;
    foreach (var b in Encoding.UTF8.GetBytes(text)) { value ^= b; value *= 0x100000001b3; }
    return value.ToString("x");
  }
}
