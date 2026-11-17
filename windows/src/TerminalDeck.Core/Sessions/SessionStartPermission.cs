using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Sessions;

// The same explicit per-start choice as the New session composer. Omission preserves defaults.
public static class SessionStartPermission
{
  public static AiPermissionMode? Parse(JsonElement arguments, string provider)
  {
    if (!arguments.TryGetProperty("permission", out var value)) return null;
    if (value.ValueKind != JsonValueKind.String || !Enum.TryParse<AiPermissionMode>(value.GetString(), true, out var mode) || !Enum.IsDefined(mode))
      throw new McpRefusal("Choose a permission mode from sessions.new_choices.");
    Validate(provider, mode);
    return mode;
  }

  public static void Validate(string provider, AiPermissionMode mode)
  {
    if (!ChatPermissionModes.Supported(provider).Contains(mode))
      throw new McpRefusal("This AI does not support that permission mode. Choose a mode from sessions.new_choices.");
  }

  public static string? TerminalValue(AiPermissionMode? mode) => mode switch
  { null => null, AiPermissionMode.AcceptEdits => "acceptEdits", { } chosen => chosen.ToString().ToLowerInvariant() };
}
