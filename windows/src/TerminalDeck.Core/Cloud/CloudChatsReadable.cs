using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;

namespace TerminalDeck.Core.Cloud;

/// Sessions in the Cloud (the Mac's BackendCloudChatsReadable.swift on Windows): the `read` stream of a session's chat,
/// the readable messages as the SAME event lines the phones already draw (version-1 chat events, one JSON object per
/// line, each line ending in "\n"). The service never parses a history; phones and the web reuse their chat view.
/// - Claude Code (`.jsonl`): the transcript rules (no tool traffic, no private reasoning, no CLI tags, no side chains).
/// - Codex (`rollout-*.jsonl`): `response_item` messages of the person and the assistant only; the context Codex puts in
///   front of the first message is not a message.
/// - Gemini (one JSON file, rewritten whole): its `messages`, the person's and Gemini's.
/// - The app's own chats (`chat.json`) and Hoot (`state\hoot.json`): their own events as the phones get them, streamed
///   pieces left out.
public static class CloudChatsReadable
{
  public enum Format { Claude, Codex, Gemini, AppChat, Hoot }
  public static string Word(Format format) => format switch
  {
    Format.Claude => "claude", Format.Codex => "codex", Format.Gemini => "gemini", Format.AppChat => "appChat", _ => "hoot"
  };
  public static Format? Parse(string? word) => word switch
  {
    "claude" => Format.Claude, "codex" => Format.Codex, "gemini" => Format.Gemini, "appChat" => Format.AppChat, "hoot" => Format.Hoot, _ => null
  };

  /// The largest line of a line-based history read at once; a bigger line (a huge pasted file) is skipped.
  public const int MaximumLineBytes = 8 * 1_048_576;
  /// A message's text as phones take it.
  public const int MaximumTextBytes = 65_536;

  public enum Role { Person, Ai }
  public sealed record Message(Role Role, string Id, string Text, double At);

  /// The event line for one message: `sequence` counts from 1 within the stream's generation.
  public static byte[] Line(Message message, string conversation, long sequence, string provider)
  {
    var text = message.Text;
    if (Encoding.UTF8.GetByteCount(text) > MaximumTextBytes) text = Cut(text, MaximumTextBytes);
    var id = conversation.Length == 0 ? "chat" : conversation;
    return EventLine(id, provider, sequence, (long)message.At, message.Role == Role.Person ? "user" : "message", message.Id, new JsonObject { ["text"] = text });
  }

  internal static byte[] EventLine(string conversation, string provider, long sequence, long at, string kind, string messageId, JsonObject value, string turnId = "")
  {
    var line = new JsonObject
    {
      ["version"] = 1, ["id"] = conversation + ":" + sequence.ToString(CultureInfo.InvariantCulture), ["conversationId"] = conversation, ["turnId"] = turnId,
      ["sequence"] = sequence, ["provider"] = provider, ["kind"] = kind, ["messageId"] = messageId.Length <= 480 ? messageId : messageId[..480],
      ["value"] = value, ["at"] = at
    };
    return [.. JsonSerializer.SerializeToUtf8Bytes(line), (byte)'\n'];
  }

  private static string Cut(string text, int bytes)
  {
    var raw = Encoding.UTF8.GetBytes(text);
    var end = Math.Min(bytes, raw.Length);
    while (end > 0 && (raw[end - 1] & 0xC0) == 0x80) end--;
    if (end > 0 && raw[end - 1] >= 0xC0) end--;
    return Encoding.UTF8.GetString(raw, 0, end);
  }

  // ---- Line-based histories (Claude Code, Codex) ----

  public static IReadOnlyList<Message> Messages(ReadOnlySpan<byte> line, Format format) => format switch
  {
    Format.Claude => Claude(line),
    Format.Codex => Codex(line),
    _ => []
  };

  private static readonly Regex CliTag = new(@"^\s*<(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr|task-notification|user-prompt-submit-hook|system-reminder|user-memory-input|ide-opened-file|ide-selection)[\s>]", RegexOptions.CultureInvariant);
  private static readonly Regex Reminders = new(@"<system-reminder>[\s\S]*?</system-reminder>", RegexOptions.CultureInvariant);
  private static readonly Regex SpacedType = new(@"""type""\s*:\s*""(?:user|assistant)""", RegexOptions.CultureInvariant);
  private static string Trim(string text) => text.Trim().Trim('﻿').Trim();

  /// The cheap look before a line is decoded: tool results never carry chat.
  public static bool MayCarryChat(string line)
  {
    if (line.Contains("\"tool_use_id\"", StringComparison.Ordinal)) return false;
    if (line.Contains("\"type\":\"user\"", StringComparison.Ordinal) || line.Contains("\"type\":\"assistant\"", StringComparison.Ordinal)) return true;
    return SpacedType.IsMatch(line);
  }

  /// One Claude Code line as a person's or the AI's message (the Mac's NativeChatTranscriptParsing.parse).
  public static Message? ClaudeLine(string line)
  {
    try
    {
      using var doc = JsonDocument.Parse(Trim(line));
      var raw = doc.RootElement;
      if (raw.ValueKind != JsonValueKind.Object || Str(raw, "type") is not ("user" or "assistant") || !raw.TryGetProperty("message", out var message)
        || message.ValueKind != JsonValueKind.Object) return null;
      foreach (var flag in new[] { "isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly" })
        if (raw.TryGetProperty(flag, out var f) && f.ValueKind == JsonValueKind.True) return null;
      var uuid = NonEmpty(Str(raw, "uuid"));
      var at = Str(raw, "timestamp") is { } stamp ? IsoMs(stamp) ?? 0 : 0;
      if (Str(raw, "type") == "assistant")
      {
        if (Str(message, "model") == "<synthetic>" || raw.TryGetProperty("isApiErrorMessage", out var e) && e.ValueKind == JsonValueKind.True
          || !message.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) return null;
        var text = TextBlocks(content);
        if (text.Length == 0) return null;
        var key = NonEmpty(Str(message, "id")) ?? uuid ?? "";
        return new(Role.Ai, uuid ?? key, text, at);
      }
      var origin = raw.TryGetProperty("origin", out var o) && o.ValueKind == JsonValueKind.Object ? NonEmpty(Str(o, "kind")) : null;
      if (origin is not null && origin != "human") return null;
      string said;
      if (!message.TryGetProperty("content", out var body)) return null;
      if (body.ValueKind == JsonValueKind.String)
      {
        var plain = body.GetString()!;
        if (CliTag.IsMatch(plain)) return null;
        said = CleanPrompt(plain);
      }
      else if (body.ValueKind == JsonValueKind.Array)
      {
        if (origin != "human" || body.EnumerateArray().Any(b => b.ValueKind == JsonValueKind.Object && Str(b, "type") == "tool_result")) return null;
        var joined = TextBlocks(body);
        if (CliTag.IsMatch(joined)) return null;
        said = CleanPrompt(joined);
      }
      else return null;
      if (said.Length == 0) return null;
      return new(Role.Person, uuid ?? at.ToString("F0", CultureInfo.InvariantCulture), said, at);
    }
    catch (JsonException) { return null; }
  }
  private static string CleanPrompt(string text) => Trim(Reminders.Replace(text, ""));
  private static string TextBlocks(JsonElement content) => string.Join("\n\n", content.EnumerateArray()
    .Where(b => b.ValueKind == JsonValueKind.Object && Str(b, "type") == "text" && Str(b, "text") is not null)
    .Select(b => Trim(Str(b, "text")!)).Where(t => t.Length > 0));

  private static IReadOnlyList<Message> Claude(ReadOnlySpan<byte> line)
  {
    string text;
    try { text = new UTF8Encoding(false, true).GetString(line); } catch (ArgumentException) { return []; }
    return MayCarryChat(text) && ClaudeLine(text) is { } made ? [made] : [];
  }

  /// What Codex puts in front of the person's first message: context, not something he wrote.
  public static readonly string[] CodexContextPrefixes = ["<environment_context>", "<user_instructions>", "<permissions instructions>",
    "# AGENTS.md instructions", "<user_shell_command>", "<turn_aborted>"];

  private static IReadOnlyList<Message> Codex(ReadOnlySpan<byte> line)
  {
    if (line.Length > MaximumLineBytes) return [];
    try
    {
      var reader = new Utf8JsonReader(line);
      using var doc = JsonDocument.ParseValue(ref reader);
      var raw = doc.RootElement;
      if (raw.ValueKind != JsonValueKind.Object || Str(raw, "type") != "response_item" || !raw.TryGetProperty("payload", out var payload)
        || payload.ValueKind != JsonValueKind.Object || Str(payload, "type") != "message" || Str(payload, "role") is not ("user" or "assistant") || !payload.TryGetProperty("content", out var content)
        || content.ValueKind != JsonValueKind.Array) return [];
      var role = Str(payload, "role")!;
      var wanted = role == "user" ? "input_text" : "output_text";
      var text = string.Join("\n\n", content.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.Object && Str(p, "type") == wanted && Str(p, "text") is not null)
        .Select(p => Str(p, "text")!.Trim()).Where(t => t.Length > 0));
      if (text.Length == 0) return [];
      if (role == "user" && CodexContextPrefixes.Any(p => text.StartsWith(p, StringComparison.Ordinal))) return [];
      var at = Str(raw, "timestamp") is { } stamp ? IsoMs(stamp) ?? 0 : 0;
      var id = Str(payload, "id") ?? "codex-" + at.ToString("F0", CultureInfo.InvariantCulture);
      return [new(role == "user" ? Role.Person : Role.Ai, id, text, at)];
    }
    catch (JsonException) { return []; }
  }

  /// One window of a line-based history: the event lines for every WHOLE line in `window` (bytes from the stream's
  /// source offset), and how many bytes those whole lines took. A line still being written stays for the next look.
  public sealed record Window(byte[] Lines, int Events, int Consumed);
  public static Window Read(ReadOnlySpan<byte> window, Format format, string conversation, string provider, long nextSequence,
    int maxOutput = 1_048_576, bool atEnd = false)
  {
    var lines = new MemoryStream(); var events = 0; var consumed = 0;
    void Take(ReadOnlySpan<byte> line, int consumedTo)
    {
      if (line.Length <= MaximumLineBytes)
        foreach (var message in Messages(line, format))
        {
          lines.Write(Line(message, conversation, nextSequence + events, provider));
          events++;
        }
      consumed = consumedTo;
    }
    var start = 0;
    while (start < window.Length)
    {
      var newline = window[start..].IndexOf((byte)'\n');
      if (newline < 0)
      {
        // A last line with no newline is whole only when the file has not grown for a while (`atEnd`).
        if (atEnd) Take(window[start..], window.Length);
        break;
      }
      Take(window.Slice(start, newline), start + newline + 1);
      start += newline + 1;
      if (lines.Length >= maxOutput) break;
    }
    return new(lines.ToArray(), events, consumed);
  }

  // ---- Whole-file histories (Gemini, the app's chats, Hoot) ----

  public static (string Conversation, IReadOnlyList<Message> Messages)? Gemini(ReadOnlySpan<byte> file)
  {
    try
    {
      var reader = new Utf8JsonReader(file);
      using var doc = JsonDocument.ParseValue(ref reader);
      var raw = doc.RootElement;
      if (raw.ValueKind != JsonValueKind.Object || !raw.TryGetProperty("messages", out var list) || list.ValueKind != JsonValueKind.Array) return null;
      var conversation = Str(raw, "sessionId") ?? "";
      var made = new List<Message>(); var index = -1;
      foreach (var entry in list.EnumerateArray())
      {
        index++;
        if (entry.ValueKind != JsonValueKind.Object || Str(entry, "type") is not ("user" or "gemini") || !entry.TryGetProperty("content", out var content)) continue;
        string text;
        if (content.ValueKind == JsonValueKind.String) text = content.GetString()!;
        else if (content.ValueKind == JsonValueKind.Array)
          text = string.Join("\n\n", content.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.Object && Str(p, "text") is not null).Select(p => Str(p, "text")!));
        else continue;
        var trimmed = text.Trim();
        if (trimmed.Length == 0) continue;
        var at = Str(entry, "timestamp") is { } stamp ? IsoMs(stamp) ?? 0 : 0;
        made.Add(new(Str(entry, "type") == "user" ? Role.Person : Role.Ai, Str(entry, "id") ?? "gemini-" + index.ToString(CultureInfo.InvariantCulture), trimmed, at));
      }
      return (conversation, made);
    }
    catch (JsonException) { return null; }
  }

  /// An app chat's saved file (`chat.json`, this PC's ChatRecord): its conversation (the chat's id, as the phones get it)
  /// and its events as the phones get them, streamed pieces and private reasoning left out, oldest first, each with its
  /// own `sequence`.
  public static (string Conversation, IReadOnlyList<(long Sequence, byte[] Line)> Events)? AppChat(ReadOnlySpan<byte> file)
  {
    ChatRecord? chat;
    try { chat = JsonSerializer.Deserialize<ChatRecord>(file, ChatJson); }
    catch (JsonException) { return null; }
    if (chat?.Definition is null || chat.Events is null) return null;
    var conversation = chat.Definition.Id;
    var provider = chat.Definition.Provider;
    var made = new List<(long, byte[])>();
    foreach (var e in chat.Events.OrderBy(e => e.Sequence))
    {
      var at = e.At.ToUnixTimeMilliseconds();
      (string Kind, JsonObject Value)? shaped = e.Kind switch
      {
        "user" => ("user", new JsonObject { ["text"] = e.Text }),
        "message" => ("message", new JsonObject { ["text"] = e.Text }),
        "toolCall" => ("toolCall", new JsonObject { ["text"] = "", ["name"] = Clip(e.Text, 200), ["toolId"] = Clip(e.Id, 500), ["status"] = "running",
          ["input"] = Clip(e.Data is { ValueKind: JsonValueKind.Object } d ? d.GetRawText() : "", 2000) }),
        "toolResult" => ("toolResult", new JsonObject { ["text"] = Clip(e.Text.Length > 0 ? e.Text : e.Data?.GetRawText() ?? "", 6000), ["toolId"] = Clip(e.Id, 500),
          ["status"] = e.Data is { } r && (ChatLineProtocol.P(r, "is_error").ValueKind == JsonValueKind.True || ChatLineProtocol.S(r, "status") is "failed" or "declined") ? "failed" : "done" }),
        "approval" => ("approval", new JsonObject { ["text"] = Clip(e.Text, 6000), ["requestId"] = Clip(e.Id, 500) }),
        "approvalResolved" => ("approvalResolved", new JsonObject { ["text"] = Clip(e.Text, 6000), ["requestId"] = Clip(e.Id, 500) }),
        "error" => ("error", new JsonObject { ["text"] = Clip(e.Text, 6000), ["isError"] = true, ["status"] = "failed" }),
        "stopped" => ("interrupted", new JsonObject { ["text"] = Clip(e.Text, 6000) }),
        _ => null
      };
      if (shaped is not { } s) continue;
      if (s.Value["text"] is JsonValue t && Encoding.UTF8.GetByteCount(t.GetValue<string>()) > MaximumTextBytes) continue;
      var line = EventLine(conversation, provider, e.Sequence, at, s.Kind, e.Id.Length > 0 ? e.Id : s.Kind + ":" + e.Sequence.ToString(CultureInfo.InvariantCulture), s.Value);
      if (line.Length > 1_048_576) continue;
      made.Add((e.Sequence, line));
    }
    return (conversation, made);
  }

  /// Hoot's saved state on this PC: its conversation and its lines as the phones get them. While Hoot is busy its newest
  /// answer is still being written, so nothing of the open turn is taken (the finished line comes with the next look).
  public static (string Conversation, IReadOnlyList<(long Sequence, byte[] Line)> Events)? Hoot(ReadOnlySpan<byte> file)
  {
    HootState? state;
    try { state = JsonSerializer.Deserialize<HootState>(file, ChatJson); }
    catch (JsonException) { return null; }
    if (state is null || state.Lines.IsDefault) return null;
    var provider = state.Settings?.Provider is "claude" or "codex" or "gemini" ? state.Settings.Provider : "claude";
    var open = state.Busy ? state.Active?.Id : null;
    var made = new List<(long, byte[])>();
    foreach (var line in state.Lines.OrderBy(l => l.Sequence))
    {
      if (open is not null && line.TurnId == open) break;
      var kind = line.Kind switch { "user" => "user", "assistant" => "message", "tool" => "toolResult", "approval" => line.Waiting ? "approval" : "approvalResolved", "error" => "error", _ => "message" };
      if (Encoding.UTF8.GetByteCount(line.Text) > MaximumTextBytes) continue;
      made.Add((line.Sequence, EventLine(state.ConversationId, provider, line.Sequence, line.At.ToUnixTimeMilliseconds(), kind, line.Id,
        new JsonObject { ["text"] = Clip(line.Text, 6000) }, line.TurnId ?? "")));
    }
    return (state.ConversationId, made);
  }

  internal static readonly JsonSerializerOptions ChatJson = new() { PropertyNameCaseInsensitive = true };
  private static string Clip(string? value, int limit) => value is null ? "" : value.Length <= limit ? value : value[..limit] + "\n[Read the rest on the computer.]";

  internal static string? Str(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
  private static string? NonEmpty(string? text) => string.IsNullOrEmpty(text) ? null : text;
  /// An ISO-8601 time as milliseconds since 1970.
  public static double? IsoMs(string stamp) =>
    DateTimeOffset.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at) ? at.ToUnixTimeMilliseconds() : null;
}
