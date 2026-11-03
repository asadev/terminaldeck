using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class W12McpPolicyTests
{
  private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
  private static McpManager Manager(MemoryState<McpManagerState> state, TestSecretStore secrets, FakeMcpFactory factory) =>
    new(state, secrets, AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w12-mcp")), new FakeCommandResolver(), factory);
  private static McpServerInput Input() => new() { Name = "echo", Scope = "user", Transport = "stdio", Command = "echo.exe", Environment = new() { ["TOKEN"] = "private-one", ["OTHER"] = "private-two" } };

  [Fact]
  public async Task OffPolicySurvivesReloadAndConnectionTestDoesNotTurnItOn()
  {
    var store = new MemoryState<McpManagerState>(); var secrets = new TestSecretStore(); var factory = new FakeMcpFactory();
    await using var manager = Manager(store, secrets, factory); var server = await manager.AddAsync(Input());
    await manager.ConnectAsync(server.Id);
    await manager.EditPatchAsync(server.Id, Json(new { enabled = false }));
    Assert.True(factory.Created[0].Disposed);
    Assert.Single(await manager.TestAsync(server.Id)); Assert.True(factory.Created[1].Disposed);
    Assert.False(Assert.Single(await manager.ListAsync()).Enabled); Assert.False(Assert.Single(await manager.ListAsync()).Connected);
    await using var reloaded = Manager(store, secrets, factory);
    await Assert.ThrowsAsync<McpRefusal>(async () => await reloaded.ConnectAsync(server.Id));
  }

  [Fact]
  public async Task DisabledToolIsEnforcedAfterReconnectAndCanBeRestored()
  {
    await using var manager = Manager(new(), new(), new()); var server = await manager.AddAsync(Input());
    await manager.EditPatchAsync(server.Id, Json(new { disabledTools = new[] { "echo" } }));
    await manager.ConnectAsync(server.Id);
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.CallAsync(server.Id, "echo", Json(new { })));
    await manager.EditPatchAsync(server.Id, Json(new { disabledTools = Array.Empty<string>() }));
    await manager.ConnectAsync(server.Id);
    Assert.True((await manager.CallAsync(server.Id, "echo", Json(new { }))).GetProperty("untrusted").GetBoolean());
  }

  [Fact]
  public async Task FailedPolicySaveKeepsPriorPolicyAndSafeSecretUpdatePreservesOtherValues()
  {
    var store = new MemoryState<McpManagerState>(); var secrets = new TestSecretStore();
    await using var manager = Manager(store, secrets, new()); var server = await manager.AddAsync(Input());
    store.FailSave = true;
    await Assert.ThrowsAsync<IOException>(async () => await manager.EditPatchAsync(server.Id, Json(new { enabled = false, disabledTools = new[] { "echo" } })));
    Assert.True(Assert.Single(await manager.ListAsync()).Enabled); Assert.Empty((await manager.SettingsAsync(server.Id)).DisabledTools);
    await Assert.ThrowsAsync<IOException>(async () => await manager.SetSecretAsync(server.Id, "TOKEN", "private-new", false));
    Assert.Equal(2, secrets.Values.Count);
    store.FailSave = false;
    var oldOther = store.Value!.Servers[0].EnvironmentReferences["OTHER"];
    await manager.SetSecretAsync(server.Id, "TOKEN", "private-new", false);
    Assert.Equal(2, secrets.Values.Count); Assert.Equal(oldOther, store.Value.Servers[0].EnvironmentReferences["OTHER"]);
    Assert.Equal("private-new", System.Text.Encoding.UTF8.GetString(secrets.Values[store.Value.Servers[0].EnvironmentReferences["TOKEN"]]));
    Assert.DoesNotContain("private-", (await manager.ExportAsync(server.Id)).GetRawText());
  }

  [Fact]
  public async Task PolicyAndTestWorkThroughDoorAndPolicyChangesRequireApproval()
  {
    await using var manager = Manager(new(), new(), new()); var server = await manager.AddAsync(Input());
    var permission = new FakePermission(); var door = new McpDoor(permission); DeckCoreTools.RegisterManager(door, manager);
    var caller = door.RegisterCaller(McpTests.Grant("mcp.edit", "mcp.connect", "mcp.call", "mcp.export"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "mcp.edit", Json(new { name = "echo", scope = "user", next = new { enabled = false } }));
    Assert.Single(permission.Requests);
    await door.CallAsync(caller.Id, "mcp.connect", Json(new { serverId = server.Id, test = true }));
    Assert.False(Assert.Single(await manager.ListAsync()).Enabled);
    var count = permission.Requests.Count;
    var result = await door.CallAsync(caller.Id, "mcp.export", Json(new { name = "echo", scope = "user" }));
    Assert.Equal(count, permission.Requests.Count); Assert.False(result.GetProperty("Enabled").GetBoolean());
    var scoped = door.RegisterCaller(McpTests.Grant("mcp.edit") with { Resources = ["mcp:user:other"] }, (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(scoped.Id, "mcp.edit", Json(new { name = "echo", scope = "user", next = new { enabled = true } })));
    Assert.False(Assert.Single(await manager.ListAsync()).Enabled);
  }

  [Fact]
  public async Task DiagnosticLogNeverStoresRemotePrivateErrors()
  {
    var factory = new FakeMcpFactory(); await using var manager = Manager(new(), new(), factory); var server = await manager.AddAsync(Input());
    await manager.ConnectAsync(server.Id); factory.Created[0].FailCall = true;
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.CallAsync(server.Id, "echo", Json(new { })));
    var exported = await manager.ExportAsync(server.Id);
    Assert.Single(exported.GetProperty("log").EnumerateArray()); Assert.DoesNotContain("synthetic-private-value", exported.GetRawText());
  }
  [Fact]
  public async Task EditingServerInvalidatesThePreviouslyReadToolCount()
  {
    await using var manager = Manager(new(), new(), new()); var server = await manager.AddAsync(Input());
    await manager.TestAsync(server.Id); Assert.Equal(1, Assert.Single(await manager.ListAsync()).ToolCount);
    await manager.EditPatchAsync(server.Id, Json(new { command = "different.exe" }));
    Assert.Null(Assert.Single(await manager.ListAsync()).ToolCount);
  }
  [Fact]
  public async Task SharedScopeCannotPretendToCreateAProjectFileOrWriteSecrets()
  {
    var secrets = new TestSecretStore(); await using var manager = Manager(new(), secrets, new());
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.AddAsync(new() { Name = "shared", Scope = "project", Folder = @"C:\project", Transport = "stdio", Command = "fixture.exe", Environment = new() { ["TOKEN"] = "must-not-store" } }));
    Assert.Empty(await manager.ListAsync()); Assert.Empty(secrets.Values);
    var local = await manager.AddAsync(new() { Name = "private", Scope = "local", Folder = @"C:\project", Transport = "stdio", Command = "fixture.exe" });
    Assert.Equal("local", local.Scope);
  }
  [Fact]
  public async Task RenamingLegacyProjectNamespaceCreatesRealSharedFileInTheChosenFolder()
  {
    var folder = Directory.CreateDirectory(Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-legacy-project-" + Guid.NewGuid().ToString("N"))).FullName;
    try
    {
      var store = new MemoryState<McpManagerState>();
      var id = "project:" + folder + ":legacy";
      store.Save(new(1, [new(id, "legacy", "project", folder, "stdio", "fixture.exe", [], null, [], [])]));
      await using var manager = Manager(store, new(), new());
      await manager.EditPatchAsync(id, Json(new { name = "renamed" }));
      var saved = Assert.Single(await manager.ListAsync()); Assert.Equal("project", saved.Scope); Assert.Equal("renamed", saved.Name);
      Assert.Contains("renamed", File.ReadAllText(Path.Combine(folder, ".mcp.json")));
    }
    finally { Directory.Delete(folder, true); }
  }
}
