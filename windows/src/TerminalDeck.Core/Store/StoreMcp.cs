using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Store;

public static class StoreMcp
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [new("store.catalog", "store_catalog", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"url":{"type":"string"},"sha256":{"type":"string"}},"required":["url","sha256"],"additionalProperties":false}""")),
   new("store.browse", "store_browse", McpTier.Read, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"department":{"type":"string"},"query":{"type":"string"},"category":{"type":"string"},"cost":{"type":"string"},"installed":{"type":"boolean"}},"additionalProperties":false}""")),
   new("store.change", "store_change", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"id":{"type":"string"},"action":{"enum":["install","update","remove"]},"options":{"type":"object","properties":{"folder":{"type":"string"},"agents":{"type":"array","items":{"enum":["claude","codex","gemini"]}},"values":{"type":"object","additionalProperties":{"type":"string"}}},"additionalProperties":false}},"required":["id","action"],"additionalProperties":false}""")),
   new("docker.catalog", "docker_catalog", McpTier.Read, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{},"additionalProperties":false}""")),
   new("docker.configure", "docker_configure", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"serverId":{"type":"string"},"action":{"enum":["preview","create","update","validate","pull","start","stop","restart","remove"]},"draft":{"type":"object","properties":{"name":{"type":"string"},"directory":{"type":"string"},"compose":{"type":"string"},"environment":{"type":"string"},"repository":{"type":"string"},"branch":{"type":"string"}},"required":["name","directory","compose","environment"],"additionalProperties":false}},"required":["serverId","action","draft"],"additionalProperties":false}"""))];
}
