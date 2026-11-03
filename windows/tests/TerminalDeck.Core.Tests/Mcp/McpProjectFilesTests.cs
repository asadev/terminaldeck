using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Tests.Mcp;
public sealed class McpProjectFilesTests : IDisposable
{
  private readonly string folder = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-project-mcp-" + Guid.NewGuid().ToString("N"));
  private McpServerConfig Server(string name = "ours") => new("project:" + folder + ":" + name, name, "project", folder, "http", null, [], "https://example.com/mcp", [], new() { ["Authorization"] = "private-reference" });
  [Fact] public void SharedProjectAddEditDisableRemovePreserveForeignEntriesAndNeverWriteProtectedValues()
  {
    Directory.CreateDirectory(folder); var file = Path.Combine(folder, ".mcp.json");
    File.WriteAllText(file, """{"outside":true,"mcpServers":{"foreign":{"command":"example","args":["one"]}}}""");
    var foreign = JsonNode.Parse(File.ReadAllText(file))!["mcpServers"]!["foreign"]!.DeepClone(); var config = Server();
    var first = new McpManagerState(1, [config]); McpProjectFiles.Apply(McpProjectFiles.Prepare(new(1, []), first), () => { });
    var added = File.ReadAllText(file); Assert.DoesNotContain("private-reference", added); Assert.Contains("${TD_MCP_", added);
    Assert.True(JsonNode.DeepEquals(foreign, JsonNode.Parse(added)!["mcpServers"]!["foreign"]));
    var editedConfig = config with { Url = "https://example.com/next" }; var edited = new McpManagerState(1, [editedConfig]);
    McpProjectFiles.Apply(McpProjectFiles.Prepare(first, edited), () => { }); Assert.Contains("/next", File.ReadAllText(file));
    var disabled = new McpManagerState(1, [editedConfig with { Enabled = false }]); McpProjectFiles.Apply(McpProjectFiles.Prepare(edited, disabled), () => { });
    Assert.Null(JsonNode.Parse(File.ReadAllText(file))!["mcpServers"]!["ours"]);
    McpProjectFiles.Apply(McpProjectFiles.Prepare(disabled, new(1, [])), () => { }); Assert.True(JsonNode.DeepEquals(foreign, JsonNode.Parse(File.ReadAllText(file))!["mcpServers"]!["foreign"]));
  }
  [Fact] public void ConflictingForeignEntryRefusedAndLedgerFailureRollsBackExactProjectBytes()
  {
    Directory.CreateDirectory(folder); var file = Path.Combine(folder, ".mcp.json"); const string bytes = """{"custom":42,"mcpServers":{"foreign":{"command":"own"}}}"""; File.WriteAllText(file, bytes);
    Assert.Throws<McpRefusal>(() => McpProjectFiles.Prepare(new(1, []), new(1, [Server("foreign")]))); Assert.Equal(bytes, File.ReadAllText(file));
    var changes = McpProjectFiles.Prepare(new(1, []), new(1, [Server()]));
    Assert.Throws<IOException>(() => McpProjectFiles.Apply(changes, () => throw new IOException("Synthetic ledger disk failure"))); Assert.Equal(bytes, File.ReadAllText(file));
    File.WriteAllText(file, "{\"editedElsewhere\":true}"); Assert.Throws<McpRefusal>(() => McpProjectFiles.Apply(changes, () => { })); Assert.Equal("{\"editedElsewhere\":true}", File.ReadAllText(file));
  }
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
}
