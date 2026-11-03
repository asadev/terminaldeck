using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Settings;

public static class TerminalAppearanceMcp
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [new("terminal.appearance.read", "terminal_appearance_read", McpTier.Read, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"export":{"type":"string"}},"additionalProperties":false}""")),
   new("terminal.appearance.set", "terminal_appearance_set", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"scheme":{"type":"string"},"fontFamily":{"type":"string","maxLength":500},"fontSize":{"type":"integer","minimum":9,"maximum":24},"reset":{"type":"boolean"}},"additionalProperties":false}""")),
   new("terminal.palette.change", "terminal_palette_change", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"action":{"enum":["copy","import","edit","remove"]},"id":{"type":"string"},"name":{"type":"string","maxLength":48},"json":{"type":"string","maxLength":65536},"colors":{"type":"object","additionalProperties":{"type":"string"}}},"required":["action"],"additionalProperties":false}"""))];
}
