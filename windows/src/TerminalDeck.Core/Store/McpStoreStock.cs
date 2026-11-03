using System.Text.Json;

namespace TerminalDeck.Core.Store;

public static class McpStoreStock
{
  public static StoreEntry[] Read()
  {
    using var stream = typeof(McpStoreStock).Assembly.GetManifestResourceStream("Store.mcp-stock.json") ?? throw new IOException("The bundled MCP catalogue is missing.");
    using var document = JsonDocument.Parse(stream);
    return document.RootElement.EnumerateArray().Select(row => new StoreEntry("mcp/" + row.GetProperty("id").GetString(), row.GetProperty("name").GetString()!, row.GetProperty("summary").GetString()!, "MCP servers", row.GetProperty("category").GetString()!, row.GetProperty("version").GetString()!, "mcp-store", row.GetProperty("homepage").GetString()!, row.GetProperty("cost").GetString()!, Needs: [row.GetProperty("runtime").GetString()!], Manifest: row.Clone())).ToArray();
  }
}
