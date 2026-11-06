using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views.Chat;

public sealed record ChatMcpNavigation(McpManager Manager, Func<string, string, JsonElement, CancellationToken, Task<JsonElement>> Call);
