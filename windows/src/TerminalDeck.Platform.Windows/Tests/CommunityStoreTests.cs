using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Store;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class CommunityStoreTests
{
  [Fact] public async Task InstructionsInstallRealFilesAndRemovalKeepsLaterUnrelatedEdits()
  {
    var folder = Path.Combine(Path.GetTempPath(), "community-store-" + Guid.NewGuid().ToString("N")); var home = Path.Combine(folder, "home"); Directory.CreateDirectory(Path.Combine(home, ".codex")); var memory = Path.Combine(home, ".codex", "AGENTS.md"); await File.WriteAllTextAsync(memory, "Existing instructions\n");
    var manifest = new { terminaldeck = 1, publisher = "sample", id = "instructions", version = "1.0.0", kind = "instructions", install = new { file = "instructions.md" } };
    using var data = new MemoryStream(); using (var zip = new ZipArchive(data, ZipArchiveMode.Create, true))
    { using (var writer = new StreamWriter(zip.CreateEntry("terminaldeck.json").Open())) writer.Write(JsonSerializer.Serialize(manifest)); using (var writer = new StreamWriter(zip.CreateEntry("instructions.md").Open())) writer.Write("Check your work."); }
    var bytes = data.ToArray(); var raw = JsonSerializer.SerializeToElement(new { kind = "instructions", agents = new[] { "codex" }, install = new { file = "instructions.md" }, artifact = new { url = "https://example.test/item.zip", bytes = bytes.Length, sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) } });
    var entry = new StoreEntry("sample/instructions", "Instructions", "Standing instructions", "Community", "Instructions", "1.0.0", "community", "https://example.test", Manifest: raw);
    var root = AppDataRoot.Explicit(Path.Combine(folder, "data")); await using var mcp = new McpManager(new JsonStateStore<McpManagerState>(root, "mcp"), new Secrets(), root, new Commands(), new Factory());
    var owner = new CommunityStoreOperations(root.DirectoryPath, mcp, _ => { }, _ => { }, home); using var http = new HttpClient(new Download(bytes));
    try
    {
      var installed = await owner.InstallAsync(entry, new(Agents: ["codex"]), http, CancellationToken.None); Assert.Contains("Standing instructions:", await File.ReadAllTextAsync(memory)); Assert.Equal("Check your work.", await File.ReadAllTextAsync(Path.Combine(home, ".codex", "instructions", "sample.instructions.md")));
      await File.AppendAllTextAsync(memory, "\nA later personal instruction\n"); await owner.RemoveAsync(entry, installed.Receipt, CancellationToken.None);
      Assert.Equal("Existing instructions\n\nA later personal instruction\n", await File.ReadAllTextAsync(memory)); Assert.False(File.Exists(Path.Combine(home, ".codex", "instructions", "sample.instructions.md")));
    }
    finally { Directory.Delete(folder, true); }
  }
  private sealed class Download(byte[] bytes) : HttpMessageHandler
  {
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent(bytes) });
  }
  private sealed class Secrets : ISecretStore
  {
    public ValueTask<byte[]?> ReadAsync(string name, CancellationToken ct = default) => ValueTask.FromResult<byte[]?>(null);
    public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken ct = default) => ValueTask.CompletedTask;
    public ValueTask DeleteAsync(string name, CancellationToken ct = default) => ValueTask.CompletedTask;
  }
  private sealed class Commands : IMcpCommandResolver { public McpCommand Resolve(string commandLine) => new("unused.exe", []); }
  private sealed class Factory : IMcpConnectionFactory { public ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct) => throw new NotSupportedException(); }
}
