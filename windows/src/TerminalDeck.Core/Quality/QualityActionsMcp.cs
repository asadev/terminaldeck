using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Quality;

public static class QualityActionsMcp
{
  private static McpToolSpec Spec(string id, string name, McpTier tier, string schema) => new(id, name, tier, JsonSerializer.Deserialize<JsonElement>(schema));
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [
    Spec("quality.access", "quality_access", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"enabled":{"type":"boolean"}},"required":["folder","enabled"],"additionalProperties":false}"""),
    Spec("quality.provider-updates", "quality_provider_updates", McpTier.Read, """{"type":"object","properties":{"folder":{"type":"string"},"provider":{"enum":["claude","codex","gemini"]}},"required":["folder"],"additionalProperties":false}"""),
    Spec("quality.reviewed-fix", "quality_reviewed_fix", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"action":{"enum":["preview","apply","rollback","preview-command","apply-command"]},"fix":{"type":"string"},"token":{"type":"string"}},"required":["folder","action"],"additionalProperties":false}"""),
    Spec("quality.dismiss", "quality_dismiss", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"id":{"type":"string"},"hidden":{"type":"boolean"},"scope":{"enum":["project","machine"]}},"required":["folder","id","hidden"],"additionalProperties":false}"""),
    Spec("quality.report", "quality_report", McpTier.Read, """{"type":"object","properties":{"folder":{"type":"string"}},"required":["folder"],"additionalProperties":false}"""),
    Spec("quality.action", "quality_action", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"action":{"enum":["doctor","preview","setup","check","coverage","repair","mark-good","accept-diff","explain","intent"]},"finding":{"type":"string"},"reason":{"type":"string"},"summary":{"type":"string"},"touches":{"type":"array","items":{"type":"string"}},"force":{"type":"boolean"}},"required":["folder","action"],"additionalProperties":false}"""),
    Spec("quality.rule", "quality_rule", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"name":{"type":"string"},"because":{"type":"string"},"executable":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}}},"required":["folder","name","because","executable","arguments"],"additionalProperties":false}"""),
    Spec("quality.ai-fix", "quality_ai_fix", McpTier.Alter, """{"type":"object","properties":{"folder":{"type":"string"},"provider":{"enum":["claude","codex","gemini"]},"kind":{"enum":["readiness","staysfixed"]},"accountId":{"type":"string"},"model":{"type":"string"},"effort":{"type":"string"},"existingSessionId":{"type":"string"},"chat":{"type":"boolean"},"addRule":{"type":"boolean"}},"required":["folder","provider","kind"],"additionalProperties":false}""")
  ];
}
