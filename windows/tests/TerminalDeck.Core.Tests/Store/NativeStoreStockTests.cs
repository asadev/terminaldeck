using System.Text.Json;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Core.Tests.Store;

public sealed class NativeStoreStockTests
{
  [Fact] public void NativeDepartmentsAndCompiledRecipesAreTheSameProductStock()
  {
    Assert.Equal(new[] { "Browser tools", "MCP servers", "Community" }, AppStoreService.Departments);
    Assert.Equal(new[] { "page-images", "page-data", "page-links", "page-tables", "page-article", "page-feeds" }, NativeStoreStock.BuiltIns.Select(e => e.Id));
    Assert.All(NativeStoreStock.BuiltIns, e => { Assert.Equal("browser-tool", e.Delivery); Assert.Equal("Browser tools", e.Department); Assert.Null(e.Artifact); });
  }
  [Fact] public void CuratedMcpStockContainsNativeRowsWithoutRetiredChromeEntries()
  {
    var rows = McpStoreStock.Read(); Assert.Equal(37, rows.Length); Assert.Contains(rows, row => row.Id == "mcp/filesystem"); Assert.Contains(rows, row => row.Id == "mcp/github"); Assert.DoesNotContain(rows, row => row.Id is "mcp/chrome-devtools" or "mcp/puppeteer"); Assert.All(rows, row => Assert.Equal("mcp-store", row.Delivery));
  }
  [Fact] public void ProductionCatalogRefusesUnsignedOrWrongKeyMaterial()
  {
    var data = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, alg = "ed25519", keyId = "td-store-dev-1", signed = Convert.ToBase64String("{}"u8), sig = Convert.ToBase64String(new byte[64]) });
    Assert.Throws<IOException>(() => SignedCommunityCatalog.Verify(data));
  }
}
