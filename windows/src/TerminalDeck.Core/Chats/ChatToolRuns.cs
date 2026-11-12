using System.Text.Json;

namespace TerminalDeck.Core.Chats;

public enum ChatToolKind { Command, Edit, Read, Memory, Search, Web, Plumbing, Tool }

// A stretch of the conversation: one row on its own, or a run of tool steps that folds into one row.
public sealed record ChatSegment<T>(IReadOnlyList<T> Items, bool IsRun);

// What the folded row says. Running: the step working now (its live words in Live).
public sealed record ChatToolRunSummary(string Text, int Plus, int Minus, int Failed, int Steps, ChatRow? Running, string Live);

// Asad, 6 Nov ("mobile version of chats is showing each bash as message"): consecutive tool steps
// between two messages fold into ONE compact row, "Ran 12 commands", with the running step's name
// while it works. The words follow the Mac's folded line (NativeHootSteps.swift HootStep.summary).
public static class ChatToolRuns
{
  // Decker, 8 Nov (D2): one step folds too ("Ran a command"), the same on all four apps.
  public const int Fold = 1;

  // Reasoning between two steps belongs to their run, so a turn that thinks between commands
  // still folds into one row. Messages, approvals, errors and stops always end a run. A step for
  // which `alone` is true (a failed step, Decker 8 Nov D1: a failure must stand out) is never
  // folded: it ends the run and stands as its own card, on all four apps.
  public static IReadOnlyList<ChatSegment<T>> Segments<T>(IReadOnlyList<T> items, Func<T, string> kind, Func<T, T, bool>? together = null, Func<T, bool>? alone = null)
  {
    var result = new List<ChatSegment<T>>();
    for (var start = 0; start < items.Count;)
    {
      if (kind(items[start]) != "tool" || alone?.Invoke(items[start]) == true) { result.Add(new([items[start]], false)); start++; continue; }
      var end = start;
      for (var next = start + 1; next < items.Count; next++)
      {
        var k = kind(items[next]);
        if (k == "tool" && alone?.Invoke(items[next]) == true) break;
        if (k == "tool" && (together is null || together(items[start], items[next]))) end = next;
        else if (k != "reasoning" || together is not null && !together(items[start], items[next])) break;
      }
      var run = items.Skip(start).Take(end - start + 1).ToArray();
      if (run.Count(i => kind(i) == "tool") >= Fold) result.Add(new(run, true));
      else foreach (var item in run) result.Add(new([item], false));
      start = end + 1;
    }
    return result;
  }
  public static IReadOnlyList<ChatSegment<ChatRow>> Segments(IReadOnlyList<ChatRow> rows) => Segments(rows, r => r.Kind, alone: Failed);

  private static readonly string[] Plumbing = ["toolsearch", "todowrite", "todoread", "exitplanmode", "enterplanmode", "task", "agent", "skill", "tools_describe", "tools_list"];
  private static readonly string[] Commands = ["bash", "shell", "exec_command", "run_shell_command", "local_shell", "bashoutput", "killshell", "run command"];
  private static readonly string[] Edits = ["edit", "multiedit", "write", "notebookedit", "apply_patch", "replace", "write_file", "update files"];
  private static readonly string[] Reads = ["read", "read_file", "read_many_files", "notebookread", "view"];
  private static readonly string[] Searches = ["grep", "glob", "ls", "search_file_content", "list_directory", "glob_files"];
  private static readonly string[] Web = ["webfetch", "websearch", "web_fetch", "google_web_search", "web_search"];

  private static JsonElement Input(ChatRow row)
  {
    if (row.Input.Length == 0 || row.Input[0] != '{') return default;
    try { using var parsed = JsonDocument.Parse(row.Input); return parsed.RootElement.Clone(); } catch (JsonException) { return default; }
  }
  public static string Bare(string name) => (name.Split("__").LastOrDefault() ?? name).Replace('.', '_');

  public static ChatToolKind Kind(ChatRow row)
  {
    var input = Input(row);
    // Codex reports the item type; Gemini reports a tool kind with its call id.
    switch (ChatLineProtocol.S(input, "type"))
    {
      case "commandExecution" or "command_execution": return ChatToolKind.Command;
      case "fileChange" or "file_change": return ChatToolKind.Edit;
      case "mcpToolCall" or "mcp_tool_call": return ChatToolKind.Tool;
    }
    if (ChatLineProtocol.S(input, "toolCallId").Length > 0)
      return ChatLineProtocol.S(input, "kind") switch
      {
        "execute" => ChatToolKind.Command, "edit" or "delete" or "move" => ChatToolKind.Edit, "read" => ChatToolKind.Read,
        "search" => ChatToolKind.Search, "fetch" => ChatToolKind.Web, "think" => ChatToolKind.Plumbing, _ => ChatToolKind.Tool
      };
    var name = Bare(row.Text).ToLowerInvariant();
    if (Plumbing.Contains(name)) return ChatToolKind.Plumbing;
    if (Commands.Contains(name)) return ChatToolKind.Command;
    if (Edits.Contains(name)) return ChatToolKind.Edit;
    if (Reads.Contains(name)) return (Path(row) ?? "").Replace('\\', '/').Contains("/memory/") ? ChatToolKind.Memory : ChatToolKind.Read;
    if (Searches.Contains(name)) return ChatToolKind.Search;
    if (Web.Contains(name)) return ChatToolKind.Web;
    // Codex exec names the step by its command line; tool names never hold spaces.
    if (!row.Text.StartsWith("mcp__", StringComparison.Ordinal) && !row.Text.Contains(" / ") && row.Text.Trim().Contains(' ')) return ChatToolKind.Command;
    return ChatToolKind.Tool;
  }

  private static string? Path(ChatRow row)
  {
    var input = Input(row);
    foreach (var key in new[] { "file_path", "path", "notebook_path", "absolute_path" })
      if (ChatLineProtocol.S(input, key) is { Length: > 0 } path) return path;
    var raw = ChatLineProtocol.P(input, "rawInput");
    foreach (var key in new[] { "file_path", "path", "absolute_path" })
      if (ChatLineProtocol.S(raw, key) is { Length: > 0 } path) return path;
    return Paths(input).FirstOrDefault();
  }
  private static IEnumerable<string> Paths(JsonElement input)
  {
    foreach (var key in new[] { "changes", "locations" })
      if (ChatLineProtocol.P(input, key) is { ValueKind: JsonValueKind.Array } list)
        foreach (var item in list.EnumerateArray()) if (ChatLineProtocol.S(item, "path") is { Length: > 0 } path) yield return path;
  }
  private static string FileName(string path) => path.Replace('\\', '/').TrimEnd('/').Split('/').Last() is { Length: > 0 } name ? name : path;
  // The files a step touched (Codex can change several in one step).
  public static IReadOnlyList<string> Files(ChatRow row)
  {
    var input = Input(row); var many = Paths(input).Select(FileName).Distinct().ToArray();
    if (many.Length > 1) return many;
    return Path(row) is { } path ? [FileName(path)] : many;
  }
  private static string File(ChatRow row) => Files(row).FirstOrDefault() ?? "a file";

  // Lines added and removed by an edit (+N −N), when the AI reported the text.
  public static (int Plus, int Minus) Diff(ChatRow row)
  {
    var input = Input(row);
    static int Lines(string text) => text.Length == 0 ? 0 : text.Split('\n').Length;
    if (ChatLineProtocol.P(input, "edits") is { ValueKind: JsonValueKind.Array } edits)
      return edits.EnumerateArray().Aggregate((0, 0), (sum, e) => (sum.Item1 + Lines(ChatLineProtocol.S(e, "new_string")), sum.Item2 + Lines(ChatLineProtocol.S(e, "old_string"))));
    if (ChatLineProtocol.S(input, "content") is { Length: > 0 } content) return (Lines(content), 0);
    return (Lines(ChatLineProtocol.S(input, "new_string")), Lines(ChatLineProtocol.S(input, "old_string")));
  }

  private static string FirstLine(string text) { var line = text.Trim(); var cut = line.IndexOf('\n'); return cut < 0 ? line : line[..cut].TrimEnd() + " …"; }
  private static string CommandWords(ChatRow row)
  {
    var input = Input(row);
    if (ChatLineProtocol.S(input, "description") is { Length: > 0 } description) return FirstLine(description);
    if (ChatLineProtocol.S(input, "command") is { Length: > 0 } command) return FirstLine(command);
    if (ChatLineProtocol.P(input, "command") is { ValueKind: JsonValueKind.Array } argv) return FirstLine(string.Join(' ', argv.EnumerateArray().Select(a => a.ValueKind == JsonValueKind.String ? a.GetString() : a.GetRawText())));
    return row.Text.Length > 0 && !Commands.Contains(Bare(row.Text).ToLowerInvariant()) ? FirstLine(row.Text) : "";
  }

  // One compact line for a step (done, or its live words while it runs).
  public static string Title(ChatRow row, bool live = false)
  {
    switch (Kind(row))
    {
      case ChatToolKind.Command:
        var words = CommandWords(row);
        return words.Length > 0 ? words + (live ? "…" : "") : live ? "Running a command…" : "Ran a command";
      case ChatToolKind.Edit: return (live ? "Editing " : "Edited ") + (Files(row) is { Count: > 1 } files ? files.Count + " files" : File(row));
      case ChatToolKind.Read: return (live ? "Reading " : "Read ") + File(row);
      case ChatToolKind.Memory: return live ? "Recalling a memory…" : "Recalled a memory";
      case ChatToolKind.Search: return live ? "Searching files…" : "Searched files";
      case ChatToolKind.Web: return live ? "Looking on the web…" : "Looked on the web";
      default: return ToolTitle(row.Text, live) + (live ? "…" : "");
    }
  }

  private static readonly Dictionary<string, (string Done, string Live)> Verbs = new()
  {
    ["list"] = ("Listed", "Listing"), ["get"] = ("Read", "Reading"), ["read"] = ("Read", "Reading"), ["start"] = ("Started", "Starting"),
    ["send"] = ("Sent", "Sending"), ["stop"] = ("Stopped", "Stopping"), ["create"] = ("Created", "Creating"), ["update"] = ("Updated", "Updating"),
    ["delete"] = ("Deleted", "Deleting"), ["search"] = ("Searched", "Searching"), ["run"] = ("Ran", "Running"), ["open"] = ("Opened", "Opening"),
    ["set"] = ("Set", "Setting"), ["tap"] = ("Tapped", "Tapping"), ["type"] = ("Typed into", "Typing into"), ["screenshot"] = ("Took a screenshot of", "Taking a screenshot of"),
    ["comment"] = ("Commented on", "Commenting on"), ["wait"] = ("Waited for", "Waiting for"), ["find"] = ("Found", "Finding"), ["record"] = ("Recorded", "Recording")
  };
  // An MCP tool in plain words: "mcp__deck-control__sessions_list" → "Listed sessions".
  public static string ToolTitle(string name, bool live = false)
  {
    var label = name.Contains(" / ") ? name[(name.LastIndexOf(" / ", StringComparison.Ordinal) + 3)..] : name;
    var words = Bare(label).Replace('-', '_').Split('_', StringSplitOptions.RemoveEmptyEntries).ToList();
    if (words.Count == 0) return live ? "Using a tool" : "Used a tool";
    // Names with spaces (Gemini titles, "Update files") are already words.
    if (label.Contains(' ')) return FirstLine(label);
    var index = words.FindLastIndex(w => Verbs.ContainsKey(w.ToLowerInvariant()));
    if (index < 0) return (live ? "Using " : "Used ") + string.Join(' ', words);
    var verb = Verbs[words[index].ToLowerInvariant()]; words.RemoveAt(index);
    return (live ? verb.Live : verb.Done) + (words.Count == 0 ? "" : " " + string.Join(' ', words));
  }

  public static bool Failed(ChatRow row) => row.Status == "Failed";
  public static bool Running(ChatRow row) => row.Kind == "tool" && row.Waiting;

  // The folded line: "Recalled a memory, ran 4 commands, edited ChatPage.cs".
  public static ChatToolRunSummary Summarize(IReadOnlyList<ChatRow> rows)
  {
    var tools = rows.Where(r => r.Kind == "tool").ToArray();
    var running = tools.LastOrDefault(Running);
    var finished = tools.Where(t => !Running(t)).ToArray();
    var kinds = finished.Select(t => (Row: t, Kind: Kind(t))).ToArray();
    ChatRow[] Count(ChatToolKind kind) => kinds.Where(t => t.Kind == kind).Select(t => t.Row).ToArray();
    var parts = new List<string>();
    var memory = Count(ChatToolKind.Memory); var commands = Count(ChatToolKind.Command); var reads = Count(ChatToolKind.Read);
    var searches = Count(ChatToolKind.Search); var web = Count(ChatToolKind.Web); var others = Count(ChatToolKind.Tool); var edits = Count(ChatToolKind.Edit);
    if (memory.Length > 0) parts.Add(memory.Length == 1 ? "recalled a memory" : "recalled " + memory.Length + " memories");
    if (commands.Length > 0) parts.Add(commands.Length == 1 ? "ran a command" : "ran " + commands.Length + " commands");
    if (reads.Length > 0) parts.Add(reads.Length == 1 ? "read " + File(reads[0]) : "read " + reads.Length + " files");
    if (searches.Length > 0) parts.Add("searched files");
    if (web.Length > 0) parts.Add("looked on the web");
    if (others.Length > 0) parts.Add(others.Length == 1 ? Lower(ToolTitle(others[0].Text)) : "used " + others.Length + " tools");
    int plus = 0, minus = 0;
    if (edits.Length > 0)
    {
      var files = edits.SelectMany(e => Files(e)).Distinct().ToArray();
      parts.Add(files.Length == 1 ? "edited " + files[0] : files.Length == 0 ? edits.Length == 1 ? "edited a file" : "edited " + edits.Length + " files" : "edited " + files.Length + " files");
      foreach (var edit in edits) { var change = Diff(edit); plus += change.Plus; minus += change.Minus; }
    }
    if (parts.Count == 0 && finished.Length > 0) parts.Add("looked up tools");
    var text = string.Join(", ", parts);
    text = text.Length == 0 ? "" : char.ToUpperInvariant(text[0]) + text[1..];
    return new(text, plus, minus, tools.Count(Failed), tools.Length, running, running is null ? "" : Title(running, true));
  }
  private static string Lower(string text) => text.Length == 0 ? text : char.ToLowerInvariant(text[0]) + text[1..];

  // The folded row in one line, for screen readers and the header text.
  public static string Header(ChatToolRunSummary summary) => Line(summary) + (summary.Failed == 0 ? "" : " · " + summary.Failed + " failed");
  // Done: "Ran 12 commands". Working: "Ran 11 commands · npm test…".
  public static string Line(ChatToolRunSummary summary) =>
    summary.Running is null ? summary.Text : summary.Text.Length > 0 ? summary.Text + " · " + summary.Live : summary.Live;

  // A step's detail: what it was given and what came back, with an MCP-style result read as its text.
  public static string Detail(ChatRow row)
  {
    var output = OutputText(row.Output);
    return (row.Input.Length > 0 ? "Input\n" + row.Input : "Input was not reported.") + (output.Length > 0 ? "\n\nOutput\n" + output : "");
  }
  public static string OutputText(string output)
  {
    var trimmed = output.TrimStart();
    if (!trimmed.StartsWith('[') && !trimmed.StartsWith('{')) return output;
    try
    {
      using var parsed = JsonDocument.Parse(trimmed);
      var root = parsed.RootElement;
      var content = root.ValueKind == JsonValueKind.Array ? root : ChatLineProtocol.P(root, "content");
      if (content.ValueKind != JsonValueKind.Array) return output;
      var texts = content.EnumerateArray().Where(c => ChatLineProtocol.S(c, "type") == "text").Select(c => ChatLineProtocol.S(c, "text")).Where(t => t.Length > 0).ToArray();
      return texts.Length > 0 ? string.Join("\n\n", texts) : output;
    }
    catch (JsonException) { return output; }
  }

  // Command output and other plain text stay in the step's detail. Pictures, links and drawings
  // (```visual, ```svg, ```mermaid) are still drawn in the chat, like MCP Apps.
  public static bool Drawable(string text) =>
    text.Contains("](", StringComparison.Ordinal) && text.Contains("![", StringComparison.Ordinal) ||
    text.Contains("```", StringComparison.Ordinal) && ChatRichContent.Blocks(text).Any(b => b.Type is "visual" or "svg" or "mermaid");
}
