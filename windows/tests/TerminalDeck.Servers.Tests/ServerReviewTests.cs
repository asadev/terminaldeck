using System.Text.Json;
using TerminalDeck.App.ViewModels.Servers;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerReviewTests
{
  private static JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
  private static McpGrant Grant(string server) => new("hoot:test", "chat", null, true, AiPermissionMode.Ask,
    ServersMcp.Specs.Select(s => s.Id).ToArray(), [McpTier.Read, McpTier.Act, McpTier.Alter],
    ["settings:servers", "servers:" + server], DateTimeOffset.UtcNow.AddMinutes(5), ServerManagement: true);
  private static McpCallContext Context(McpGrant grant, Func<CancellationToken, ValueTask>? current = null) => new(grant, current ?? (_ => ValueTask.CompletedTask), _ => { });

  [Theory]
  [InlineData("expired")]
  [InlineData("Hoot settings changed")]
  public async Task LiveCallerInvalidatedWhileServerApprovalWaitsCannotWrite(string reason)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var clock = new Clock(); var mcp = new ServersMcp(f.Service);
    var live = true; var door = new McpDoor(new Broker(clock), clock); mcp.Register(door);
    var connection = door.RegisterCaller(Grant(row.Id), (grant, spec, args, _, _) => ValueTask.FromResult(live && mcp.Preflight(grant, spec, args)));
    f.Approval.During = () =>
    {
      if (reason == "expired") clock.Now = clock.Now.AddMinutes(10); else live = false;
      return ValueTask.CompletedTask;
    };
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(connection.Id, "servers.control", Args(new { serverId = row.Id, cardId = Runtime.AppId, action = "restart" })));
    Assert.Single(f.Approval.Actions);
    Assert.All(f.Runtime.Commands, c => Assert.StartsWith("docker ps ", c.Script));
  }
  [Fact] public async Task LiveCallerInvalidatedDuringSaveApprovalCannotSaveOrImportKey()
  {
    using var f = new Fixture(); var mcp = new ServersMcp(f.Service, new Picker("/person/chosen/key")); var live = true;
    var context = Context(Grant("unused"), _ => live ? ValueTask.CompletedTask : ValueTask.FromException(new McpRefusal("expired")));
    var receipt = (await mcp.CallAsync("servers.pick_key", context, Args(new { }), default)).GetProperty("keyReceipt").GetString();
    f.Approval.During = () => { live = false; return ValueTask.CompletedTask; };
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.add", context, Args(new { name = "Chosen", host = "example.test", user = "tester", keyReceipt = receipt }), default));
    Assert.Empty(f.Store.List()); Assert.Empty(f.Secrets.Values); Assert.Empty(f.Runtime.Imported);
  }
  [Fact] public async Task NonOwnerServerManagerCanManageOnlyGrantedServersWithSeparateApproval()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var other = await f.AddAsync(); var mcp = new ServersMcp(f.Service);
    var grant = Grant(row.Id); var spec = ServersMcp.Specs.Single(s => s.Id == "servers.access");
    var args = Args(new { serverId = row.Id, lookOnly = true, folders = new[] { "/srv/test" }, aiApps = Array.Empty<string>() });
    Assert.False(grant.OwnerApplication); Assert.True(mcp.Preflight(grant, spec, args));
    Assert.False(mcp.Preflight(grant with { ServerManagement = false }, spec, args));
    Assert.False(mcp.Preflight(grant with { Resources = ["servers:" + row.Id] }, spec, args));
    Assert.False(mcp.Preflight(grant with { DeviceId = "phone" }, spec, args));
    Assert.False(mcp.Preflight(grant, spec, Args(new { serverId = other.Id })));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.access", Context(grant with { PermissionMode = AiPermissionMode.Plan }), args, default));
    Assert.Empty(f.Approval.Actions);
    await mcp.CallAsync("servers.access", Context(grant), args, default);
    Assert.Single(f.Approval.Actions); Assert.Equal("/srv/test", Assert.Single(f.Store.Get(row.Id).Access.Folders));
    await mcp.CallAsync("servers.trust_host", Context(grant), Args(new { serverId = row.Id, publicKey = "fixture public key" }), default);
    Assert.Single(f.Runtime.Trusted);
    await mcp.CallAsync("servers.remove", Context(grant), Args(new { serverId = row.Id, confirmName = row.Name }), default);
    Assert.Equal(other.Id, Assert.Single(f.Store.List()).Id);
  }
  [Fact] public async Task NonOwnerManagerCanFinishNewServerSetupWithoutAccessToOtherServers()
  {
    using var f = new Fixture(); var other = await f.AddAsync(); var mcp = new ServersMcp(f.Service);
    var grant = Grant("not-a-saved-server"); var context = Context(grant);
    var added = await mcp.CallAsync("servers.add", context, Args(new { name = "New server", host = "example.test", user = "tester", password = "synthetic" }), default);
    var id = added.GetProperty("id").GetString()!;
    await mcp.CallAsync("servers.host_key", context, Args(new { serverId = id }), default);
    await mcp.CallAsync("servers.access", context, Args(new { serverId = id, lookOnly = true, folders = new[] { "/srv/new" }, aiApps = Array.Empty<string>() }), default);
    Assert.Equal("/srv/new", Assert.Single(f.Store.Get(id).Access.Folders));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.host_key", context, Args(new { serverId = other.Id }), default));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.host_key", Context(grant with { SessionId = "different" }), Args(new { serverId = id }), default));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.host_key", Context(grant with { ServerManagement = false }), Args(new { serverId = id }), default));
  }
  [Fact] public async Task KeyImportNeedsPersonPickerReceiptAndNamesFileInApproval()
  {
    using var f = new Fixture(); var picker = new Picker("/person/chosen/private-key"); var mcp = new ServersMcp(f.Service, picker);
    var context = Context(Grant("unused"));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.add", context, Args(new { name = "Test", host = "example.test", user = "tester", keyPath = "/unpicked/key" }), default));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Imported);
    var picked = await mcp.CallAsync("servers.pick_key", context, Args(new { }), default);
    Assert.Equal("private-key", picked.GetProperty("fileName").GetString()); Assert.DoesNotContain("/person", picked.GetRawText(), StringComparison.Ordinal);
    var receipt = picked.GetProperty("keyReceipt").GetString();
    var add = Args(new { name = "Test", host = "example.test", user = "tester", keyReceipt = receipt });
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.add", Context(Grant("unused") with { CallerId = "other" }), add, default));
    await mcp.CallAsync("servers.add", context, add, default);
    Assert.Contains("/person/chosen/private-key", Assert.Single(f.Approval.Actions).Target, StringComparison.Ordinal);
    Assert.Equal("/person/chosen/private-key", Assert.Single(f.Runtime.Imported)); Assert.True(Assert.Single(f.Store.List()).Access.LookOnly);
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.add", context, add, default));
  }
  [Fact] public async Task CancelledOrExpiredKeySelectionCannotBeUsedForImport()
  {
    using var f = new Fixture(); var clock = new Clock(); var picker = new Picker(null); var mcp = new ServersMcp(f.Service, picker, clock); var context = Context(Grant("unused"));
    Assert.True((await mcp.CallAsync("servers.pick_key", context, Args(new { }), default)).GetProperty("cancelled").GetBoolean());
    picker.Path = "/person/key";
    var receipt = (await mcp.CallAsync("servers.pick_key", context, Args(new { }), default)).GetProperty("keyReceipt").GetString();
    clock.Now = clock.Now.AddMinutes(6);
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.add", context, Args(new { name = "Test", host = "example.test", user = "tester", keyReceipt = receipt }), default));
    Assert.Empty(f.Runtime.Imported); Assert.Empty(f.Approval.Actions);
  }
  [Theory]
  [InlineData("banner before json")]
  [InlineData("{}")]
  [InlineData("{\"path\":\"/srv/test\",\"entries\":null,\"more\":false}")]
  [InlineData("{\"path\":\"/srv/test\",\"entries\":[{\"name\":\"jump\",\"path\":\"/outside\",\"kind\":\"file\",\"size\":0,\"modified\":0}],\"more\":false}")]
  public async Task MalformedFileListingIsVisibleRequestFailure(string output)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); f.Runtime.Reply = _ => new(0, output); var model = new ServersViewModel(f.Service); model.Select(row.Id);
    Assert.False(await model.LoadFilesAsync()); Assert.True(model.IsError); Assert.Null(model.Files); Assert.False(model.IsBusy); Assert.DoesNotContain(output, model.Message, StringComparison.Ordinal);
  }
  [Theory]
  [InlineData("{\"path\":\"/srv/test/readme\",\"base64\":\"bad!\",\"truncated\":false}")]
  [InlineData("{\"path\":\"/srv/test/readme\",\"base64\":null,\"truncated\":false}")]
  public async Task MalformedFileContentCannotPreviewOrCreateDownload(string output)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); f.Runtime.Reply = _ => new(0, output); var model = new ServersViewModel(f.Service); model.Select(row.Id);
    Assert.False(await model.ReadAsync(new("readme", "/srv/test/readme", "file", 0, 0))); Assert.True(model.IsError); Assert.Empty(model.Preview);
    await Assert.ThrowsAsync<IOException>(async () => await f.Service.DownloadAsync(row.Id, "/srv/test/readme", f.Path + "/download", ServerCaller.Person));
    Assert.False(File.Exists(f.Path + "/download")); Assert.Empty(Directory.GetFiles(f.Path, "*.partial"));
  }
  [Theory]
  [InlineData("Login banner")]
  [InlineData("{\"ID\":3}")]
  [InlineData("null")]
  public async Task MalformedDockerOutputIsVisibleRequestFailure(string output)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); f.Runtime.Reply = _ => new(0, output); var model = new ServersViewModel(f.Service); model.Select(row.Id);
    Assert.False(await model.LoadAppsAsync()); Assert.True(model.IsError); Assert.Null(model.Apps); Assert.False(model.IsBusy);
  }
  private sealed class Picker(string? path) : IServerKeyPicker
  {
    public string? Path { get; set; } = path;
    public ValueTask<string?> PickAsync(CancellationToken ct) => ValueTask.FromResult(Path);
  }
  private sealed class Broker(Clock clock) : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct) => ValueTask.FromResult(
      new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, clock.Now.AddMinutes(1), true));
  }
  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
  }
}
