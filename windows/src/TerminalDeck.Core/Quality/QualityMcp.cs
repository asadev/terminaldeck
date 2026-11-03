using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Quality;

public static class QualityMcp
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } = StaysFixedService.Specs.Concat(new[]
  {
    new McpToolSpec("deployments.read", "deployments_read", McpTier.Read, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"projectId":{"type":"string"},"sessionId":{"type":"string"}},"additionalProperties":false}""")),
    new McpToolSpec("deployments.report", "deployments_report", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"projectId":{"type":"string"},"sessionId":{"type":"string"},"runId":{"type":"string"},"title":{"type":"string","minLength":1,"maxLength":160},"steps":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"tool":{"type":"string"},"state":{"type":"string","enum":["waiting","running","done","failed","skipped"]},"result":{"type":"string"},"passed":{"type":"integer","minimum":0},"failed":{"type":"integer","minimum":0}},"required":["id","name","tool","state"],"additionalProperties":false}}},"required":["projectId","title","steps"],"additionalProperties":false}""")),
    new McpToolSpec("quality.readiness", "quality_readiness", McpTier.Read, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"folder":{"type":"string"},"provider":{"enum":["claude","codex","gemini"]}},"required":["folder"],"additionalProperties":false}""")),
    new McpToolSpec("quality.fix", "quality_fix", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"folder":{"type":"string"},"action":{"type":"string","enum":["preview","apply"]},"fix":{"type":"string","enum":["instructions","readme","ignore"]},"token":{"type":"string"}},"required":["folder","action"],"additionalProperties":false}"""))
  }).ToArray();
}
