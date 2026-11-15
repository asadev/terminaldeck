using System.Text.Json;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Cloud;

/// Sessions in the Cloud (the Mac's BackendCloudChatsArchive.swift; owner, 15 Nov: "I want to keep all the chat
/// histories, no matter how big they are ... inside the cloud"): the chats of Terminal Deck's OWN past sessions on this
/// PC, which no side panel lists any more. They go up in the background after the listed sessions' catch-up and become
/// "Earlier chats" of their project.
/// - Where: every AI login folder Terminal Deck made (`<data>\accounts\<id>\claude|codex|gemini\.gemini`) and the app's
///   saved chats (`<data>\chats\<id>\chat.json`) that are no longer listed. Never the plain `%USERPROFILE%\.claude`,
///   `.codex`, `.gemini` homes (AI chats run outside Terminal Deck).
/// - A HISTORY vs a HELPER-AGENT history (left out):
///   - Claude Code: a history is a `.jsonl` DIRECTLY in `projects\<folder>\`. A helper agent's lives one level deeper
///     (`<conversation>\subagents\agent-*.jsonl`) or, in older Claude versions, is named `agent-*.jsonl` and its lines say
///     `"isSidechain": true`. Only the first is taken.
///   - Codex: `sessions\**\rollout-*.jsonl` (or `archived_sessions\`) whose first line, `session_meta`, does NOT name a
///     parent thread (`payload.source.subagent`).
///   - Gemini: `tmp\<project>\chats\*.json`.
/// - Its project from the folder the history belongs to; its name from what the app still knows (its kept title), else
///   the first words he typed; its dates from the history itself (first and last real turn).
/// Sizes and the first lines only are read to find this; the copying itself is the uploader's.
public static class CloudChatsArchive
{
  public sealed record Found(string Path, [property: JsonConverter(typeof(JsonStringEnumConverter))] CloudChatsReadable.Format Format, string Provider,
    string? Conversation, string? Cwd, string Name, long? StartedAt, long LastUsedAt);
  /// How much of a history's start is read to learn its folder, its first words and when it began.
  public const int HeadBytes = 256 * 1024;

  /// True for a Claude Code history the person had (not a helper agent's): directly in `projects\<folder>\`.
  public static bool IsClaudeHistory(string file, string projects)
  {
    if (!file.EndsWith(".jsonl", StringComparison.Ordinal) || System.IO.Path.GetFileName(file).StartsWith("agent-", StringComparison.Ordinal)) return false;
    var parent = System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(file)));
    return parent is not null && string.Equals(System.IO.Path.TrimEndingDirectorySeparator(parent), System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(projects)), StringComparison.OrdinalIgnoreCase);
  }

  private static IEnumerable<string> Children(string folder, bool directories)
  {
    if (!Directory.Exists(folder)) return [];
    try
    {
      return (directories ? Directory.EnumerateDirectories(folder) : Directory.EnumerateFiles(folder))
        .Where(p => !System.IO.Path.GetFileName(p).StartsWith('.') && !File.GetAttributes(p).HasFlag(FileAttributes.ReparsePoint)).ToArray();
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
  }

  /// Every past history under Terminal Deck's own homes and every saved app chat, minus `skip` (paths already copied or
  /// listed). `knownNames`: the app's kept titles by conversation id. Folders only; at most 20,000 files looked at.
  public static IReadOnlyList<Found> Scan(IEnumerable<string> homes, string? chats, IReadOnlySet<string> skip, IReadOnlyDictionary<string, string>? knownNames = null)
  {
    var names = knownNames ?? new Dictionary<string, string>();
    var found = new List<Found>(); var looked = 0;
    bool More() => ++looked <= 20_000;
    foreach (var home in homes.Where(Directory.Exists))
    {
      // Claude Code: projects\<folder>\<conversation>.jsonl
      var projects = System.IO.Path.Combine(home, "projects");
      foreach (var folder in Children(projects, true))
        foreach (var file in Children(folder, false).Where(f => IsClaudeHistory(f, projects) && !skip.Contains(f)))
        {
          if (!More()) return found;
          if (Claude(file, names) is { } made) found.Add(made);
        }
      // Codex: sessions\**\rollout-*.jsonl and archived_sessions\**.
      foreach (var name in new[] { "sessions", "archived_sessions" })
      {
        var root = System.IO.Path.Combine(home, name);
        if (!Directory.Exists(root)) continue;
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(root, "rollout-*.jsonl", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.ReparsePoint }).ToArray(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
        foreach (var file in files.Where(f => !skip.Contains(f)))
        {
          if (!More()) return found;
          if (Codex(file, names) is { } made) found.Add(made);
        }
      }
      // Gemini: tmp\<project>\chats\*.json
      foreach (var project in Children(System.IO.Path.Combine(home, "tmp"), true))
        foreach (var file in Children(System.IO.Path.Combine(project, "chats"), false).Where(f => f.EndsWith(".json", StringComparison.Ordinal) && !skip.Contains(f)))
        {
          if (!More()) return found;
          if (Gemini(file, names) is { } made) found.Add(made);
        }
    }
    // The app's saved chats that no listed session holds.
    if (chats is not null)
      foreach (var folder in Children(chats, true).Where(f => Guid.TryParseExact(System.IO.Path.GetFileName(f), "N", out _)))
      {
        var file = System.IO.Path.Combine(folder, "chat.json");
        if (CloudChats.Look(file) is null || skip.Contains(file)) continue;
        if (!More()) return found;
        if (AppChat(file, names) is { } made) found.Add(made);
      }
    return found;
  }

  /// The first words he typed, as a name: at most 8 words and 60 characters.
  public static string? NameFromFirstWords(string? text)
  {
    var words = string.Join(' ', (text ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Take(8));
    if (words.Length == 0) return null;
    return words.Length <= 60 ? words : words[..59] + "…";
  }
  private static byte[]? Head(string file) => CloudChats.Read(file, 0, HeadBytes);
  private static long Modified(string file) => (long)((CloudChats.Look(file)?.Mtime ?? 0) * 1000);
  private static IEnumerable<byte[]> Lines(byte[] bytes)
  {
    var start = 0;
    while (start < bytes.Length)
    {
      var end = Array.IndexOf(bytes, (byte)'\n', start);
      if (end < 0) end = bytes.Length;
      if (end > start) yield return bytes[start..end];
      start = end + 1;
    }
  }
  private static JsonElement? Object(byte[] line)
  {
    try { using var doc = JsonDocument.Parse(line); return doc.RootElement.ValueKind == JsonValueKind.Object ? doc.RootElement.Clone() : null; }
    catch (JsonException) { return null; }
  }

  private static Found? Claude(string file, IReadOnlyDictionary<string, string> names)
  {
    if (Head(file) is not { Length: > 0 } head) return null;
    string? cwd = null, first = null, title = null; long? started = null;
    var conversation = System.IO.Path.GetFileNameWithoutExtension(file);
    foreach (var line in Lines(head).Take(4_000))
    {
      if (Object(line) is not { } raw) continue;
      var type = CloudChatsReadable.Str(raw, "type");
      // A helper agent's history written beside the person's (older Claude): its lines are side chains.
      if (type is "user" or "assistant" && raw.TryGetProperty("isSidechain", out var side) && side.ValueKind == JsonValueKind.True && first is null) return null;
      if (cwd is null && CloudChatsReadable.Str(raw, "cwd") is { Length: > 0 } c) cwd = c;
      if (started is null && CloudChatsReadable.Str(raw, "timestamp") is { } stamp && CloudChatsReadable.IsoMs(stamp) is { } at) started = (long)at;
      if (title is null && type is "summary" or "custom-title") title = CloudChatsReadable.Str(raw, "summary") ?? CloudChatsReadable.Str(raw, "customTitle");
      if (first is null)
      {
        var text = System.Text.Encoding.UTF8.GetString(line);
        if (CloudChatsReadable.MayCarryChat(text) && CloudChatsReadable.ClaudeLine(text) is { Role: CloudChatsReadable.Role.Person } said) first = said.Text;
      }
      if (cwd is not null && started is not null && first is not null) break;
    }
    if (first is null && title is null) return null; // nothing he wrote: not a chat
    var last = LastTurn(file, raw => CloudChatsReadable.Str(raw, "type") is "user" or "assistant") ?? Modified(file);
    var name = names.GetValueOrDefault(conversation) ?? Clean(title) ?? NameFromFirstWords(first) ?? "Chat";
    return new(file, CloudChatsReadable.Format.Claude, "claude", conversation, cwd, name, started, last);
  }

  /// The last real turn: the newest timestamped line in the file's last 512 KB.
  private static long? LastTurn(string file, Func<JsonElement, bool> real)
  {
    if (CloudChats.Look(file)?.Size is not { } size || CloudChats.Read(file, Math.Max(0, size - 512 * 1024), 512 * 1024) is not { } tail) return null;
    foreach (var line in Lines(tail).Reverse().Take(2_000))
      if (Object(line) is { } raw && real(raw) && CloudChatsReadable.Str(raw, "timestamp") is { } stamp && CloudChatsReadable.IsoMs(stamp) is { } at) return (long)at;
    return null;
  }

  private static Found? Codex(string file, IReadOnlyDictionary<string, string> names)
  {
    if (Head(file) is not { } head || Lines(head).FirstOrDefault() is not { } metaLine || Object(metaLine) is not { } meta
      || CloudChatsReadable.Str(meta, "type") != "session_meta" || !meta.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object) return null;
    // A helper thread started by another Codex thread names its parent: left out.
    if (payload.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.Object && source.TryGetProperty("subagent", out _)) return null;
    var conversation = CloudChatsReadable.Str(payload, "id");
    var started = (CloudChatsReadable.Str(payload, "timestamp") ?? CloudChatsReadable.Str(meta, "timestamp")) is { } stamp && CloudChatsReadable.IsoMs(stamp) is { } at ? (long?)at : null;
    string? first = null;
    foreach (var line in Lines(head).Skip(1).Take(4_000))
    {
      if (CloudChatsReadable.Messages(line, CloudChatsReadable.Format.Codex).FirstOrDefault() is { Role: CloudChatsReadable.Role.Person } message) { first = message.Text; break; }
    }
    if (first is null) return null;
    var last = LastTurn(file, raw => CloudChatsReadable.Str(raw, "type") == "response_item");
    var name = (conversation is null ? null : names.GetValueOrDefault(conversation)) ?? NameFromFirstWords(first) ?? "Chat";
    return new(file, CloudChatsReadable.Format.Codex, "codex", conversation, CloudChatsReadable.Str(payload, "cwd"), name, started, last ?? Modified(file));
  }

  private static Found? Gemini(string file, IReadOnlyDictionary<string, string> names)
  {
    if (CloudChats.Look(file)?.Size is not { } size || size > 64 * 1_048_576 || CloudChats.Read(file, 0, (int)size) is not { } data
      || CloudChatsReadable.Gemini(data) is not { } parsed || parsed.Messages.FirstOrDefault(m => m.Role == CloudChatsReadable.Role.Person) is not { } first) return null;
    var conversation = parsed.Conversation.Length == 0 ? null : parsed.Conversation;
    var times = parsed.Messages.Select(m => m.At).Where(t => t > 0).ToArray();
    var name = (conversation is null ? null : names.GetValueOrDefault(conversation)) ?? NameFromFirstWords(first.Text) ?? "Chat";
    return new(file, CloudChatsReadable.Format.Gemini, "gemini", conversation, null, name, times.Length > 0 ? (long)times.Min() : null,
      times.Length > 0 ? (long)times.Max() : Modified(file));
  }

  private static Found? AppChat(string file, IReadOnlyDictionary<string, string> names)
  {
    if (CloudChats.Look(file)?.Size is not { } size || size > 512L * 1_048_576 || CloudChats.Read(file, 0, (int)size) is not { } data) return null;
    ChatRecord? chat;
    try { chat = JsonSerializer.Deserialize<ChatRecord>(data, CloudChatsReadable.ChatJson); }
    catch (JsonException) { return null; }
    if (chat?.Definition is null || chat.Events is null || chat.Events.FirstOrDefault(e => e.Kind == "user") is not { } first) return null;
    var conversation = chat.Definition.Id;
    var times = chat.Events.Select(e => e.At.ToUnixTimeMilliseconds()).Where(t => t > 0).ToArray();
    var name = names.GetValueOrDefault(conversation) ?? (chat.HasCustomTitle ? Clean(chat.Definition.Title) : null) ?? NameFromFirstWords(first.Text)
      ?? Clean(chat.Definition.Title) ?? "Chat";
    return new(file, CloudChatsReadable.Format.AppChat, chat.Definition.Provider, conversation, chat.Definition.Cwd, name,
      times.Length > 0 ? times.Min() : null, times.Length > 0 ? times.Max() : Modified(file));
  }
  private static string? Clean(string? text)
  {
    var trimmed = text?.Trim() ?? "";
    if (trimmed.Length == 0) return null;
    return trimmed.Length <= 60 ? trimmed : trimmed[..59] + "…";
  }

  /// The list row an earlier chat is put with: its project from its folder, its name and dates, "ended".
  public static CloudChats.Row RowFor(Found found, string id, IReadOnlyList<TerminalDeck.Core.Projects.Project> projects) =>
    new(id, CloudChats.Clip(found.Name, 200) ?? "Chat", found.LastUsedAt, CloudChats.ProjectFor(null, found.Cwd, projects), CloudChats.Clip(found.Cwd, 512),
      found.Provider, null, found.Format == CloudChatsReadable.Format.AppChat ? "chat" : "terminal", "ended", found.StartedAt, CloudChats.Clip(found.Conversation, 128));
  /// The source the uploader copies an earlier chat from (no tool-results side files: only the history itself).
  public static CloudChats.Source SourceOf(Found found) => found.Format == CloudChatsReadable.Format.AppChat
    ? new(Readable: CloudChatsReadable.Format.AppChat, Snap: found.Path, Provider: found.Provider)
    : new(found.Path, Readable: found.Format, Provider: found.Provider);
}
