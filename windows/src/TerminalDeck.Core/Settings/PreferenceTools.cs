using System.Text.Json;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Settings;
public static class PreferenceTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    new("settings.preferences.read", "settings_preferences_read", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false })),
    new("settings.preferences.reset", "settings_preferences_reset", McpTier.Alter, JsonDocument.Parse("""{"type":"object","properties":{"confirmed":{"type":"boolean","const":true}},"required":["confirmed"],"additionalProperties":false}""").RootElement.Clone()),
    new("settings.preferences.open_path", "settings_preferences_open_path", McpTier.Alter, JsonDocument.Parse("""{"type":"object","properties":{"key":{"type":"string","enum":["data","state","logs","general","appearance","terminal","notifications"]}},"required":["key"],"additionalProperties":false}""").RootElement.Clone())
  ];
}
