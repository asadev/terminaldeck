using System.Text.Json;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Hooks;
public static class ProviderHooksTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    new("hooks.status", "hooks_status", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false })),
    new("hooks.change", "hooks_change", McpTier.Alter, JsonDocument.Parse("""{"type":"object","properties":{"accountId":{"type":"string","maxLength":128},"install":{"type":"boolean"}},"required":["accountId","install"],"additionalProperties":false}""").RootElement.Clone())
  ];
}
