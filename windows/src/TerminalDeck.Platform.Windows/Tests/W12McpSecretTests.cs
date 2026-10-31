using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class W12McpSecretTests
{
  [Fact]
  public async Task SecureValueReplacementKeepsOtherValuesHiddenAndRemovalDeletesOnlyOwnedValues()
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD-SettingsProof", "mcp-secret-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath);
    var store = new JsonStateStore<McpManagerState>(root, "mcp"); var vault = new WindowsCredentialStore(root);
    await using var manager = new McpManager(store, vault, root, new Commands(), new NeverConnect());
    McpServerView? server = null;
    var secret = "synthetic-" + Guid.NewGuid().ToString("N");
    try
    {
      server = await manager.AddAsync(new() { Name = "secret-test", Scope = "user", Transport = "stdio", Command = "fixture.exe", Environment = new() { ["TOKEN"] = secret, ["OTHER"] = secret + "-other" } });
      Assert.DoesNotContain(secret, JsonSerializer.Serialize(store.Load()));
      Assert.DoesNotContain(secret, JsonSerializer.Serialize(await manager.SettingsAsync(server.Id)));
      var old = store.Load()!.Servers[0].EnvironmentReferences;
      await manager.SetSecretAsync(server.Id, "TOKEN", secret + "-new", false);
      var current = store.Load()!.Servers[0].EnvironmentReferences;
      Assert.Equal(old["OTHER"], current["OTHER"]);
      Assert.Null(await vault.ReadAsync(old["TOKEN"]));
      var bytes = await vault.ReadAsync(current["TOKEN"]);
      try { Assert.Equal(secret + "-new", System.Text.Encoding.UTF8.GetString(bytes!)); }
      finally { if (bytes is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
      await manager.RemoveAsync(server.Id); server = null;
      Assert.Null(await vault.ReadAsync(current["TOKEN"])); Assert.Null(await vault.ReadAsync(current["OTHER"]));
    }
    finally { if (server is not null) await manager.RemoveAsync(server.Id); }
  }
  private sealed class Commands : IMcpCommandResolver
  { public McpCommand Resolve(string commandLine) => new(commandLine, []); }
  private sealed class NeverConnect : IMcpConnectionFactory
  { public ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct) => throw new InvalidOperationException("This test never starts a server."); }
}
