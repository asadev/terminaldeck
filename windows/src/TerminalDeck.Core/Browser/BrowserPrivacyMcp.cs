using System.Text.Json;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Browser;
public static class BrowserPrivacyMcp
{
  public static IReadOnlyList<McpToolSpec> Specs => [new("browser.privacy", "browser_privacy", McpTier.Alter, JsonDocument.Parse("""{"type":"object","properties":{"action":{"enum":["list","preferences","cookies-import","cookies-clear","password-save","password-copy","password-fill","password-forget"]},"profile":{"type":"string"},"persistSignIns":{"type":"boolean"},"savePasswords":{"type":"boolean"},"file":{"type":"string"},"id":{"type":"string"},"site":{"type":"string"},"username":{"type":"string"},"password":{"type":"string"}},"required":["action","profile"],"additionalProperties":false}""").RootElement.Clone())];
}
