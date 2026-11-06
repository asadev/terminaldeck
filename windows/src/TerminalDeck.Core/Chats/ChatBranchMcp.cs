using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Chats;

public static class ChatBranchMcp
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [new("sessions.chat_fork", "sessions_chat_fork", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""
  {"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["fork","rewind","worktree-chat","worktree-status","worktree-remove","location"]},"messageId":{"type":"string"},"throughTurn":{"type":"string"},"worktree":{"type":"boolean"},"title":{"type":"string","maxLength":120},"session":{"type":"string"}},"required":["sessionId","do"],"additionalProperties":false}
  """))];
}
