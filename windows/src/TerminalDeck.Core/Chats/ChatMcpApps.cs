using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Chats;

public sealed record ChatMcpAppContent(string ServerId, string Tool, string ResourceUri, string Html, JsonElement Input, JsonElement Result, JsonElement Resource);

public static class ChatMcpApps
{
  private static readonly ConcurrentDictionary<string, (string ChatId, string RowId, ChatMcpAppContent App)> rendered = new();
  public static object[] RenderedBlocks(string chatId) => rendered.Values.Where(v => v.ChatId == chatId)
    .Select(v => (object)new { id = v.RowId, type = "mcp-app", source = v.App.Html, serverId = v.App.ServerId, resourceUri = v.App.ResourceUri }).ToArray();
  public static string? ResourceUri(JsonElement? meta)
  {
    if (meta is not { ValueKind: JsonValueKind.Object } value) return null;
    var uri = ChatLineProtocol.S(ChatLineProtocol.P(value, "ui"), "resourceUri");
    if (uri.Length == 0) uri = ChatLineProtocol.S(value, "ui/resourceUri");
    return uri.StartsWith("ui://", StringComparison.Ordinal) ? uri : null;
  }
  // Providers wrap results differently; retain the original MCP content and
  // structuredContent instead of flattening away the App's input/result.
  public static IEnumerable<JsonElement> Objects(JsonElement value, int depth = 0)
  {
    if (depth > 12) yield break;
    if (value.ValueKind == JsonValueKind.Object)
    {
      yield return value;
      foreach (var field in value.EnumerateObject()) foreach (var child in Objects(field.Value, depth + 1)) yield return child;
    }
    else if (value.ValueKind == JsonValueKind.Array)
      foreach (var item in value.EnumerateArray()) foreach (var child in Objects(item, depth + 1)) yield return child;
    else if (value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 1 and < 4000000 } text && (text.TrimStart().StartsWith('{') || text.TrimStart().StartsWith('[')))
    {
      JsonDocument? parsed = null;
      try { parsed = JsonDocument.Parse(text); } catch (JsonException) { }
      if (parsed is not null) { using (parsed) foreach (var child in Objects(parsed.RootElement, depth + 1)) yield return child.Clone(); }
    }
  }
  public sealed record Binding(string ServerId, string Tool);

  // Only provider-owned envelope fields identify a tool. Claude Data is ordinary
  // arguments, including when it happens to resemble a Codex item or MCP result.
  public static Binding? ResolveBinding(ChatRecord chat, string rowId, IReadOnlyList<McpServerView> servers)
  {
    var entries = chat.Events.Where(e => e.Id == rowId && e.Kind is "toolCall" or "toolResult").ToArray();
    if (!entries.Any(e => e.Kind == "toolCall")) return null;
    var identities = new List<(string Server, string Tool)>();
    foreach (var entry in entries)
    {
      if (chat.Definition.Provider == "claude" && entry.Kind == "toolCall")
      {
        var parts = entry.Text.Split("__", 3);
        if (parts.Length != 3 || parts[0] != "mcp" || parts[1].Length == 0 || parts[2].Length == 0) return null;
        identities.Add((parts[1], parts[2]));
      }
      else if (chat.Definition.Provider == "codex" && entry.Data is { } data)
      {
        if (ChatLineProtocol.S(data, "type") is not ("mcpToolCall" or "mcp_tool_call")) return null;
        var server = ChatLineProtocol.S(data, "server"); var tool = ChatLineProtocol.S(data, "tool"); var itemId = ChatLineProtocol.S(data, "id");
        // Stored row ids carry the connection scope ("scope:itemId"); the provider item id is the suffix.
        if (server.Length == 0 || tool.Length == 0 || itemId.Length == 0 || rowId != itemId && !rowId.EndsWith(":" + itemId, StringComparison.Ordinal)) return null;
        identities.Add((server, tool));
      }
      else if (entry.Kind == "toolCall") return null;
    }
    var distinct = identities.Distinct().ToArray();
    if (distinct.Length != 1) return null;
    var identity = distinct[0];
    var matches = servers.Where(s => s.Enabled && s.Name == identity.Server &&
      (s.Scope == "user" || s.Scope == "project" && s.Folder is { } folder && ProjectPaths.Contains(folder, chat.Definition.Cwd))).ToArray();
    return matches.Length == 1 ? new(matches[0].Id, identity.Tool) : null;
  }
  public static async Task<ChatMcpAppContent?> ResolveAsync(McpManager manager, ChatRecord chat, ChatRow row, CancellationToken ct)
  {
    var completed = chat.Events.LastOrDefault(e => e.Kind == "toolResult" && e.Id == row.Id);
    if (completed is null) return null;
    var binding = ResolveBinding(chat, row.Id, await manager.ListAsync(ct));
    if (binding is null) return null;
    var tool = binding.Tool;
    var values = new List<JsonElement>();
    // Result traversal supplies display content only, never server identity.
    if (completed.Data is { } data) values.AddRange(Objects(data));
    try { values.AddRange(Objects(JsonSerializer.Deserialize<JsonElement>(completed.Text))); } catch (JsonException) { }
    var tools = await manager.ConnectAsync(binding.ServerId, ct);
    var spec = tools.FirstOrDefault(t => t.Name == tool);
    if (ResourceUri(spec?.Meta) is not { } uri) return null;
    var resource = await manager.ReadUiResourceAsync(binding.ServerId, tool, uri, ct);
    var content = ChatLineProtocol.P(resource, "contents").EnumerateArray().FirstOrDefault(c => ChatLineProtocol.S(c, "uri") == uri && ChatLineProtocol.S(c, "mimeType") == "text/html;profile=mcp-app");
    if (content.ValueKind != JsonValueKind.Object) throw new IOException("The MCP App did not return its declared HTML resource.");
    var html = ChatLineProtocol.S(content, "text");
    if (html.Length == 0 && ChatLineProtocol.S(content, "blob") is { Length: > 0 } blob) html = Encoding.UTF8.GetString(Convert.FromBase64String(blob));
    if (html.Length is 0 or > 3000000) throw new IOException("The MCP App resource is empty or too large.");
    var input = JsonSerializer.SerializeToElement(new { });
    try { if (row.Input.Length > 0) input = JsonSerializer.Deserialize<JsonElement>(row.Input); } catch (JsonException) { }
    // Codex wraps the actual call arguments in the item envelope.
    if (input.ValueKind == JsonValueKind.Object && input.TryGetProperty("arguments", out var arguments)) input = arguments.Clone();
    var result = values.FirstOrDefault(v => ChatLineProtocol.P(v, "content").ValueKind == JsonValueKind.Array && (v.TryGetProperty("structuredContent", out _) || v.TryGetProperty("isError", out _)));
    if (result.ValueKind == JsonValueKind.Undefined) result = values.LastOrDefault(v => ChatLineProtocol.P(v, "content").ValueKind == JsonValueKind.Array);
    if (result.ValueKind == JsonValueKind.Undefined) result = JsonSerializer.SerializeToElement(new { content = new[] { new { type = "text", text = row.Output } } });
    var app = new ChatMcpAppContent(binding.ServerId, tool, uri, html, input, result, content.Clone());
    if (rendered.Count >= 64) rendered.TryRemove(rendered.Keys.First(), out _);
    rendered[chat.Definition.Id + ":" + row.Id] = (chat.Definition.Id, row.Id, app);
    return app;
  }
}
