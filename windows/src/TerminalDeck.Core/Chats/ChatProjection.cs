using System.Text.Json;

namespace TerminalDeck.Core.Chats;

public sealed record ChatRow(string Kind, string Id, string Text, string Details = "", bool Waiting = false, string? ClientId = null, string Status = "", string Input = "", string Output = "");
public static class ChatProjection
{
  public static IReadOnlyList<ChatRow> Rows(ChatRecord chat)
  {
    var rows = new List<ChatRow>(); var positions = new Dictionary<string, int>();
    foreach (var entry in chat.Events)
    {
      var key = (entry.Kind is "textDelta" or "message" ? "assistant" : entry.Kind is "toolCall" or "toolInputDelta" or "toolResult" ? "tool" : entry.Kind is "reasoningDelta" or "reasoning" ? "reasoning" : entry.Kind) + ":" + entry.Id;
      positions.TryGetValue(key, out var position); var exists = positions.ContainsKey(key);
      ChatRow? row = entry.Kind switch
      {
        "user" => new("user", entry.Id, entry.Text, ClientId: entry.ClientId),
        "textDelta" => new("assistant", entry.Id, (exists ? rows[position].Text : "") + entry.Text, ClientId: entry.ClientId),
        "message" => new("assistant", entry.Id, entry.Text, ClientId: entry.ClientId),
        "toolCall" => ToolCall(entry, exists ? rows[position] : null),
        "toolInputDelta" => ToolInput(entry, exists ? rows[position] : null),
        "toolResult" => ToolResult(entry, exists ? rows[position] : null),
        "reasoningDelta" => new("reasoning", entry.Id, (exists ? rows[position].Text : "") + entry.Text),
        "reasoning" => new("reasoning", entry.Id, entry.Text),
        "approval" => new("approval", entry.Id, entry.Text, entry.Data?.GetRawText() ?? "", !chat.Events.Any(e => e.Kind is "approvalResolved" or "approvalSending" && e.Id == entry.Id), Status: chat.Events.LastOrDefault(e => e.Kind == "approvalResolved" && e.Id == entry.Id)?.Text ?? chat.Events.LastOrDefault(e => e.Kind == "approvalSending" && e.Id == entry.Id)?.Text ?? "Waiting for you"),
        "error" => new("error", entry.Id.Length > 0 ? entry.Id : "error:" + entry.Sequence, entry.Text, ClientId: entry.ClientId),
        "stopped" => new("status", entry.Id, entry.Text),
        _ => null
      };
      if (row is null) continue;
      if (exists) rows[position] = row; else { positions[key] = rows.Count; rows.Add(row); }
    }
    foreach (var message in chat.Messages.Where(m => m.State is ChatMessageState.Failed or ChatMessageState.Uncertain or ChatMessageState.Dispatching))
      if (!rows.Any(r => r.Kind == "user" && r.ClientId == message.ClientId)) rows.Add(new("user", message.ClientId, message.Text, ClientId: message.ClientId));
    return rows;
  }
  private static string ToolDetails(string input, string output) => (input.Length > 0 ? "Input\n" + input : "Input was not reported.") + (output.Length > 0 ? "\n\nOutput\n" + output : "");
  private static ChatRow ToolCall(ChatEvent entry, ChatRow? previous)
  {
    var input = entry.Data is { ValueKind: JsonValueKind.Object } data ? data.GetRawText() : previous?.Input ?? "";
    var output = previous?.Output ?? ""; var finished = previous is { Waiting: false, Status.Length: > 0 };
    return new("tool", entry.Id, entry.Text.Length > 0 ? entry.Text : previous?.Text ?? ReportedToolName(entry.Data, "Tool"), ToolDetails(input, output), !finished, Status: previous?.Status ?? "", Input: input, Output: output);
  }
  private static ChatRow ToolInput(ChatEvent entry, ChatRow? previous)
  {
    // Current providers send the assembled input once, after any initial {}.
    // Retain support for an actual fragment without prefixing a second object.
    var input = entry.Text;
    try { using var parsed = JsonDocument.Parse(input); }
    catch (JsonException) { input = (previous?.Input ?? "") + input; }
    var output = previous?.Output ?? "";
    return new("tool", entry.Id, previous?.Text ?? "Tool", ToolDetails(input, output), previous?.Waiting ?? true, Status: previous?.Status ?? "", Input: input, Output: output);
  }
  private static ChatRow ToolResult(ChatEvent entry, ChatRow? previous)
  {
    var input = previous?.Input ?? "";
    var data = entry.Data ?? default;
    var failed = ChatLineProtocol.P(data, "is_error").ValueKind == JsonValueKind.True || ChatLineProtocol.S(data, "status") is "failed" or "declined";
    var exitCode = ChatLineProtocol.P(data, "exitCode");
    if (exitCode.ValueKind == JsonValueKind.Number && exitCode.TryGetInt32(out var exit) && exit != 0) failed = true;
    var output = entry.Text.Length > 0 ? entry.Text : entry.Data?.GetRawText() ?? "";
    return new("tool", entry.Id, previous?.Text ?? ReportedToolName(entry.Data, "Tool result"), ToolDetails(input, output), false, Status: failed ? "Failed" : "Done", Input: input, Output: output);
  }

  private static string ReportedToolName(JsonElement? value, string fallback)
  {
    var data = value ?? default;
    return ChatLineProtocol.S(data, "type") switch
    {
      "fileChange" or "file_change" => "Update files",
      "commandExecution" or "command_execution" => ChatLineProtocol.S(data, "command") is { Length: > 0 } command ? command : "Run command",
      "mcpToolCall" => string.Join(" / ", new[] { ChatLineProtocol.S(data, "server"), ChatLineProtocol.S(data, "tool") }.Where(s => s.Length > 0)) is { Length: > 0 } label ? label : "MCP tool",
      _ => fallback
    };
  }

}
