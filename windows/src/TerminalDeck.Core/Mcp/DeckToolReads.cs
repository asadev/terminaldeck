using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

// Reads run without asking in every permission mode; changes ask through the
// AI's own permission setting (Mac BackendHootChatStore.readsOnly/readingCall).
// A read-tier tool whose verb changes something ("do": "save") still asks.
public static class DeckToolReads
{
  public const string ServerPrefix = "mcp__deck-tools__";
  private static readonly Lazy<Dictionary<string, McpToolSpec>> ByWire = new(() => McpCatalogue.Load().GroupBy(s => s.Wire).ToDictionary(g => g.Key, g => g.First()));
  private static readonly HashSet<string> ReadingVerbs = ["list", "get", "read", "search", "describe", "show", "status", "preview", "progress", "comments",
    "activity", "routine", "trash", "history", "diff", "look", "find", "summary", "state", "snapshot", "fetch", "description_history", "recording", "screenshot"];
  public static bool Quiet(string toolName, JsonElement input)
  {
    if (!toolName.StartsWith(ServerPrefix, StringComparison.Ordinal) || !ByWire.Value.TryGetValue(toolName[ServerPrefix.Length..], out var spec)) return false;
    var arguments = input.ValueKind == JsonValueKind.Object ? input : JsonSerializer.SerializeToElement(new { });
    try { if (McpCatalogue.EffectiveTier(spec, arguments) != McpTier.Read) return false; }
    catch (Exception ex) when (ex is KeyNotFoundException or InvalidOperationException) { return false; }
    foreach (var key in new[] { "do", "action", "op", "verb", "operation" })
      if (arguments.TryGetProperty(key, out var verb) && (verb.ValueKind != JsonValueKind.String || !ReadingVerbs.Contains(verb.GetString()!))) return false;
    return true;
  }
}
