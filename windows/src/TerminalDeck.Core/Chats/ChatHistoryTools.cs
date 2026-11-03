using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Chats;

public sealed class ChatHistoryTools(IChatSessions chats)
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  public JsonElement Read(McpCallContext context, JsonElement arguments, bool list)
  {
    var folder = arguments.GetProperty("cwd").GetString() ?? throw new McpRefusal("Choose a folder."); context.Require("folders", folder);
    var available = chats.List().Where(c => c.Definition.Cwd.Equals(folder, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)
      && context.Has("sessions", c.Definition.Id) && context.Has("accounts", c.Definition.AccountId)).ToArray();
    var limit = arguments.TryGetProperty("limit", out var requested) ? Math.Clamp(requested.GetInt32(), 1, 200) : 40;
    if (list) return JsonSerializer.SerializeToElement(available.TakeLast(Math.Min(limit, 100)).Select(c => new
      { id = c.Definition.Id, title = c.Definition.Title, transcriptPath = "chat:" + c.Definition.Id, exportPath = "chat:" + c.Definition.Id + ":export:0", promptPath = "chat:" + c.Definition.Id + ":prompts:0", draftPath = "chat:" + c.Definition.Id + ":draft:0", usagePath = "chat:" + c.Definition.Id + ":usage", inspectorPath = "chat:" + c.Definition.Id + ":inspector", sideQuestionPath = "chat:" + c.Definition.Id + ":sideQuestion", mode = "chat" }), Json);
    var locator = arguments.TryGetProperty("transcriptPath", out var path) ? path.GetString() : null;
    var parts = locator?.Split(':');
    var chat = parts is { Length: >= 2 } && parts[0] == "chat" ? available.FirstOrDefault(c => c.Definition.Id == parts[1]) : locator is null ? available.LastOrDefault() : null;
    if (chat is null) throw new McpRefusal("Choose a chat from chats.list in this folder.");
    if (parts is { Length: 3 } && parts[2] == "sideQuestion")
    {
      var side = ChatDraftWorkspace.Require(chat.Definition.Id).SideQuestion; var snapshot = side.Read(); string? problem = null;
      try { _ = side.ForCopy(chat); } catch (InvalidOperationException ex) { problem = ex.Message; }
      return JsonSerializer.SerializeToElement(new { snapshot.Question, snapshot.Revision, snapshot.Brief, canCopy = problem is null, problem }, Json);
    }
    if (parts is { Length: 3 } && parts[2] == "inspector") return JsonSerializer.SerializeToElement(ChatInspector.Read(chat), Json);
    if (parts is { Length: 3 } && parts[2] == "usage")
      return JsonSerializer.SerializeToElement(new { source = "Provider-reported figures, not account limits or your bill", reports = chat.Events.Where(e => e.Kind == "usage").GroupBy(e => e.Id).Select(g => g.Last()) }, Json);
    if (parts is { Length: 4 } && parts[2] is "export" or "prompts" or "draft")
    {
      if (!int.TryParse(parts[3], out var offset) || offset < 0) throw new McpRefusal("Choose a valid text offset.");
      var draft = parts[2] == "draft" ? ChatDraftWorkspace.Read(chat.Definition.Id) ?? throw new McpRefusal("Open this chat’s composer before reading its unsent draft.") : null;
      var text = parts[2] == "export" ? ChatText.Export(chat) : draft?.Text ?? string.Join("\n\n", ChatText.Prompts(chat));
      if (offset > text.Length) throw new McpRefusal("Choose a valid text offset.");
      if (offset < text.Length && offset > 0 && char.IsLowSurrogate(text[offset]) && char.IsHighSurrogate(text[offset - 1])) throw new McpRefusal("Use the text offset from the previous page.");
      var count = Math.Min(16000, text.Length - offset);
      if (count > 0 && offset + count < text.Length && char.IsHighSurrogate(text[offset + count - 1]) && char.IsLowSurrogate(text[offset + count])) count--;
      return JsonSerializer.SerializeToElement(new { text = text.Substring(offset, count), revision = draft?.Revision, offset, totalCharacters = text.Length,
        nextTranscriptPath = offset + count < text.Length ? $"chat:{chat.Definition.Id}:{parts[2]}:{offset + count}" : null }, Json);
    }
    if (parts is { Length: >= 4 } && parts[2] == "media")
    {
      var media = chat.Messages.Where(m => m.State != ChatMessageState.Removed).SelectMany(m => m.Media).FirstOrDefault(m => m.Id == parts[3]) ?? throw new McpRefusal("Choose an image attached to this chat.");
      var offset = parts.Length == 6 && parts[4] == "at" && int.TryParse(parts[5], out var parsedOffset) ? parsedOffset : 0;
      var bytes = chats.ReadImage(chat.Definition.Id, media);
      if (offset < 0 || offset > bytes.Length) throw new McpRefusal("Choose a valid image offset.");
      var count = Math.Min(4 * 1024 * 1024, bytes.Length - offset);
      return JsonSerializer.SerializeToElement(new { media.MimeType, data = Convert.ToBase64String(bytes, offset, count), bytes = bytes.Length,
        nextTranscriptPath = offset + count < bytes.Length ? $"chat:{chat.Definition.Id}:media:{media.Id}:at:{offset + count}" : null }, Json);
    }
    var before = parts is { Length: 4 } && parts[2] == "before" && long.TryParse(parts[3], out var cursor) ? cursor : long.MaxValue;
    var events = chat.Events.Where(e => e.Sequence < before).TakeLast(limit).ToArray();
    var oldest = events.FirstOrDefault()?.Sequence ?? 0;
    return JsonSerializer.SerializeToElement(new { sessionId = chat.Definition.Id, events,
      media = chat.Messages.Where(m => m.State != ChatMessageState.Removed).SelectMany(m => m.Media).DistinctBy(m => m.Id).Select(m => new { m.Id, m.Name, m.MimeType, transcriptPath = $"chat:{chat.Definition.Id}:media:{m.Id}" }),
      nextTranscriptPath = chat.Events.Any(e => e.Sequence < oldest) ? $"chat:{chat.Definition.Id}:before:{oldest}" : null }, Json);
  }
}
