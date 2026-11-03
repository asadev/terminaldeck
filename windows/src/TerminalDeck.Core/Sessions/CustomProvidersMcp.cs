using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Sessions;

public static class CustomProvidersMcp
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [new("terminal.providers", "terminal_providers", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""
  {"type":"object","properties":{"action":{"type":"string","enum":["list","save","remove","start"]},"id":{"type":"string"},"name":{"type":"string","maxLength":80},"executable":{"type":"string"},"arguments":{"type":"array","maxItems":128,"items":{"type":"string","maxLength":8192}},"environment":{"type":"object","additionalProperties":{"type":"string"}},"enabled":{"type":"boolean"},"inheritEnvironment":{"type":"boolean"},"cwd":{"type":"string"},"title":{"type":"string","maxLength":120}},"required":["action"],"additionalProperties":false}
  """))];
}
