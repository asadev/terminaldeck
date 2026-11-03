using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class ProtectedArgumentsTests
{
  [Fact] public async Task SecretArgumentNeverEntersLedgerSettingsExportsOrProjectFilesAndResolvesOnlyAtLaunch()
  {
    using var folder = new Scratch(); var store = new JsonStateStore<McpManagerState>(folder.Root, "mcp"); var secrets = new TestSecretStore(); var commands = new Commands(); await using var manager = new McpManager(store, secrets, folder.Root, commands, new FakeMcpFactory());
    var row = await manager.AddAsync(new() { Name = "private-db", Scope = "project", Folder = folder.Path, Transport = "stdio", Command = "fake", SecretArguments = new() { [1] = "private-db-credential" } });
    var config = store.Load()!.Servers.Single(); Assert.Equal("[protected]", config.Arguments[1]); Assert.Single(config.ArgumentReferences!);
    Assert.DoesNotContain("private-db-credential", await File.ReadAllTextAsync(System.IO.Path.Combine(folder.Root.DirectoryPath, "state", "mcp.json")));
    Assert.DoesNotContain("private-db-credential", await File.ReadAllTextAsync(System.IO.Path.Combine(folder.Path, ".mcp.json")));
    Assert.DoesNotContain("private-db-credential", JsonSerializer.Serialize(await manager.SettingsAsync(row.Id))); Assert.DoesNotContain("private-db-credential", (await manager.ExportAsync(row.Id)).GetRawText());
    var resolved = await ManagedMcpFactory.ResolveArgumentsAsync(config, secrets); Assert.Equal(new[] { "public", "private-db-credential" }, resolved); Assert.Equal("[protected]", config.Arguments[1]);
    await manager.RemoveAsync(row.Id); Assert.Empty(secrets.Values);
  }
  [Fact] public async Task NonCommandEditsPreserveProtectedArgumentsAndReplacingThemRetiresOldReferences()
  {
    using var folder = new Scratch(); var store = new JsonStateStore<McpManagerState>(folder.Root, "mcp"); var secrets = new TestSecretStore(); var commands = new Commands(); await using var manager = new McpManager(store, secrets, folder.Root, commands, new FakeMcpFactory());
    var row = await manager.AddAsync(new() { Name = "private-db", Scope = "user", Transport = "stdio", Command = "fake", SecretArguments = new() { [1] = "old-secret" } });
    var original = store.Load()!.Servers.Single().ArgumentReferences![1];
    await manager.EditPatchAsync(row.Id, JsonSerializer.SerializeToElement(new { enabled = false })); Assert.True(secrets.Values.ContainsKey(original));
    commands.Arguments = ["public", "[protected]"];
    await manager.EditAsync(row.Id, new() { Name = "private-db", Scope = "user", Transport = "stdio", Command = "fake" }); Assert.Equal(original, store.Load()!.Servers.Single().ArgumentReferences![1]); Assert.True(secrets.Values.ContainsKey(original));
    await manager.EditAsync(row.Id, new() { Name = "private-db", Scope = "user", Transport = "stdio", Command = "fake", SecretArguments = new() { [1] = "new-secret" } }); Assert.False(secrets.Values.ContainsKey(original)); Assert.Equal("new-secret", (await ManagedMcpFactory.ResolveArgumentsAsync(store.Load()!.Servers.Single(), secrets))[1]);
    commands.Arguments = ["public", "ordinary"];
    await manager.EditPatchAsync(row.Id, JsonSerializer.SerializeToElement(new { command = "fake" })); Assert.Empty(secrets.Values); Assert.Empty(store.Load()!.Servers.Single().ArgumentReferences!);
  }
  [Fact] public async Task InvalidSecretArgumentPositionsAreRefusedBeforeAnyCredentialWrite()
  {
    using var folder = new Scratch(); var secrets = new TestSecretStore(); await using var manager = new McpManager(new JsonStateStore<McpManagerState>(folder.Root, "mcp"), secrets, folder.Root, new Commands(), new FakeMcpFactory());
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.AddAsync(new() { Name = "private-db", Scope = "user", Transport = "stdio", Command = "fake", SecretArguments = new() { [9] = "not-written" } })); Assert.Empty(secrets.Values);
  }
  private sealed class Commands : IMcpCommandResolver { public string[] Arguments = ["public", "placeholder"]; public McpCommand Resolve(string commandLine) => new("fake.exe", Arguments); }
  private sealed class Scratch : IDisposable
  {
    public string Path { get; } = System.IO.Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : System.IO.Path.GetTempPath(), "mcp-argv-" + Guid.NewGuid().ToString("N"));
    public AppDataRoot Root { get; }
    public Scratch() { Directory.CreateDirectory(Path); Root = AppDataRoot.Explicit(System.IO.Path.Combine(Path, "data")); }
    public void Dispose() => Directory.Delete(Path, true);
  }
}
