using System.Text.Json;

namespace TerminalDeck.App.Views.Chat;

internal static class ChatBranchActions
{
  internal static Func<string, string, JsonElement, CancellationToken, Task<JsonElement>>? Invoke { get; set; }
}
