using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Receiver;

public static class ReceiverSourceMcp
{
  private static McpToolSpec Spec(string id, string name, McpTier tier, string schema) => new(id, name, tier, JsonSerializer.Deserialize<JsonElement>(schema));
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [Spec("receiver.source.read", "receiver_source_read", McpTier.Read, """{"type":"object","properties":{"id":{"type":"string"}},"additionalProperties":false}"""),
   Spec("receiver.source.create", "receiver_source_create", McpTier.Alter, """{"type":"object","properties":{"name":{"type":"string"},"projectId":{"type":"string"},"preset":{"type":"string"}},"required":["name","projectId","preset"],"additionalProperties":false}"""),
   Spec("receiver.source.save", "receiver_source_save", McpTier.Alter, """{"type":"object","properties":{"configuration":{"type":"object"}},"required":["configuration"],"additionalProperties":false}"""),
   Spec("receiver.source.credential", "receiver_source_credential", McpTier.Alter, """{"type":"object","properties":{"id":{"type":"string"},"value":{"type":"string","maxLength":4096},"reply":{"type":"boolean"},"generateAndCopy":{"type":"boolean"},"copySaved":{"type":"boolean"}},"required":["id"],"additionalProperties":false}"""),
   Spec("receiver.source.preview", "receiver_source_preview", McpTier.Read, """{"type":"object","properties":{"id":{"type":"string"},"payload":{"type":"string","maxLength":81920},"headers":{"type":"object","additionalProperties":{"type":"string"}}},"required":["id","payload"],"additionalProperties":false}"""),
   Spec("receiver.source.learn", "receiver_source_learn", McpTier.Read, """{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"""),
   Spec("receiver.source.preset", "receiver_source_preset", McpTier.Alter, """{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id","name"],"additionalProperties":false}""")];
}
