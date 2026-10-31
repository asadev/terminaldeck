using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerMcpTests
{
  private static McpGrant Grant(string server, string caller = "connected-ai", bool owner = false, McpTier[]? tiers = null) => new(caller, null, null, true, AiPermissionMode.Ask,
    ServersMcp.Specs.Select(s => s.Id).ToArray(), tiers ?? [McpTier.Read, McpTier.Act, McpTier.Alter], ["servers:" + server], DateTimeOffset.UtcNow.AddMinutes(5), OwnerApplication: owner);
  private static JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
  [Fact] public async Task LookOnlyPreflightRefusesBeforeTheSharedDoorAsks()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var mcp = new ServersMcp(f.Service);
    var spec = ServersMcp.Specs.Single(s => s.Id == "servers.control");
    Assert.False(mcp.Preflight(Grant(row.Id, owner: true), spec, Args(new { serverId = row.Id, cardId = Runtime.AppId, action = "restart" })));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task CallerAccessResourceAndTierAllHaveToMatch()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var mcp = new ServersMcp(f.Service);
    var spec = ServersMcp.Specs.Single(s => s.Id == "servers.control"); var args = Args(new { serverId = row.Id, cardId = Runtime.AppId, action = "restart" });
    Assert.True(mcp.Preflight(Grant(row.Id), spec, args));
    Assert.False(mcp.Preflight(Grant(row.Id, "other-ai"), spec, args));
    Assert.False(mcp.Preflight(Grant("different-server"), spec, args));
    Assert.False(mcp.Preflight(Grant(row.Id, tiers: [McpTier.Act]), spec, args));
    Assert.False(mcp.Preflight(Grant(row.Id) with { DeviceId = "phone" }, spec, args));
  }
  [Fact] public async Task HandlerRechecksRevocationAndUsesTheServerApprovalDesk()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var mcp = new ServersMcp(f.Service);
    var current = 0; var ctx = new McpCallContext(Grant(row.Id), _ => { current++; return ValueTask.CompletedTask; }, _ => { });
    var result = await mcp.CallAsync("docker.containers.restart", ctx, Args(new { target = row.Id, id = Runtime.AppId }), default);
    Assert.True(result.GetProperty("ok").GetBoolean()); Assert.Single(f.Approval.Actions); Assert.True(current >= 2);
    await f.Store.SetAccessAsync(row.Id, row.Access with { AiApps = [] }, default);
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("docker.containers.restart", ctx, Args(new { target = row.Id, id = Runtime.AppId }), default));
    Assert.Single(f.Approval.Actions);
  }
  [Fact] public async Task SchemaRefusesArbitraryCommandsAndLocalTransfersNeedFolderGrant()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var mcp = new ServersMcp(f.Service);
    var ctx = new McpCallContext(Grant(row.Id), _ => ValueTask.CompletedTask, _ => { });
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.control", ctx, Args(new { serverId = row.Id, cardId = Runtime.AppId, action = "restart", command = "reboot" }), default));
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.files_change", ctx, Args(new { serverId = row.Id, path = "/srv/test/readme", @do = "download", localPath = f.Path + "/local" }), default));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task ListNeverIncludesAnUngrantedServer()
  {
    using var f = new Fixture(); var first = await f.AddAsync(true); var second = await f.AddAsync(true); var mcp = new ServersMcp(f.Service);
    var ctx = new McpCallContext(Grant(first.Id), _ => ValueTask.CompletedTask, _ => { });
    var result = await mcp.CallAsync("servers.look", ctx, Args(new { }), default);
    Assert.Equal(first.Id, Assert.Single(result.GetProperty("servers").EnumerateArray()).GetProperty("id").GetString());
    Assert.DoesNotContain(second.Id, result.GetRawText(), StringComparison.Ordinal);
  }
  [Fact] public void ContributionsRetainMacWireNamesAndRegisterIntegratedCatalogue()
  {
    using var f = new Fixture(); var mcp = new ServersMcp(f.Service);
    Assert.Equal(23, mcp.Contributions().Count); Assert.Equal(McpTier.Act, ServersMcp.Specs.Single(s => s.Id == "servers.control").Tier);
    Assert.Equal("servers_files_read", ServersMcp.Specs.Single(s => s.Id == "servers.files_read").Wire);
    Assert.All(ServersMcp.Specs.Where(s => s.Id.StartsWith("docker.containers.", StringComparison.Ordinal) && !s.Id.EndsWith("list", StringComparison.Ordinal)), s => Assert.Equal(McpTier.Alter, s.Tier));
    var door = new McpDoor(new RefuseBroker()); mcp.Register(door);
    var caller = door.RegisterCaller(Grant("unused"), (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.Equal(ServersMcp.Specs.Select(s => s.Id).Order(), door.List(caller.Id).Select(s => s.Id).Order());
  }
  private sealed class RefuseBroker : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken cancellationToken) => throw new InvalidOperationException("No approvals expected");
  }
}
