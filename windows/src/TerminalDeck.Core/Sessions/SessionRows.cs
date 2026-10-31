using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Sessions;

// sessions_list returns one short row per session. Transcripts stay behind
// chats_* / sessions_transcript so a listing fits an AI's tool-result limit.
public static class SessionRows
{
  public const int Limit = 200;
  // "Only sessions in this folder": any Windows spelling, including subfolders.
  public static bool InFolder(JsonElement arguments, string cwd) =>
    !arguments.TryGetProperty("cwd", out var folder) || folder.GetString() is not { Length: > 0 } wanted || McpCallerScopes.Within(wanted, cwd);
  public static object Chat(ChatRecord chat) => new
  {
    id = chat.Definition.Id, provider = chat.Definition.Provider, mode = "chat", cwd = chat.Definition.Cwd, title = chat.Definition.Title,
    accountId = chat.Definition.AccountId, status = chat.Ended ? "ended" : chat.Stopping ? "stopping" : chat.Busy ? "working" : "idle",
    problem = chat.Problem, lastActivity = chat.Events.LastOrDefault()?.At, messages = chat.Messages.Count(m => m.State != ChatMessageState.Removed)
  };
}
