using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerCapabilitiesTests
{
  private sealed class Terminal : IServerTerminal
  {
    public bool SupportsCodingTasks => true;
    public List<ServerTerminalRequest> Requests = [];
    public ValueTask<string> OpenAsync(ServerTerminalRequest request, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Requests.Add(request); return ValueTask.FromResult("synthetic-session"); }
  }
  private static string Coding(bool canRemove = false) => JsonSerializer.Serialize(new[] {
    new ServerCodingAi("claude", "Claude Code", true, "/home/tester/.local/bin/claude", "1.2.3", "yes", true, null, canRemove),
    new ServerCodingAi("codex", "Codex CLI", true, "/home/tester/.local/bin/codex", "1.2.3", "no", true, null, canRemove),
    new ServerCodingAi("gemini", "Gemini CLI", false, "", "", "unknown", false, "Node is missing", false, false, false) });
  [Fact] public async Task TypedSetupRequiresWritableApprovalAndReturnsRealOwnedTerminalReceipt()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var terminal = new Terminal(); var owner = new ServerService(f.Store, f.Runtime, f.Approval, terminal);
    f.Runtime.Reply = _ => new(0, Coding());
    var result = await owner.ChangeCodingAiAsync(server.Id, "codex", "signin", ServerCaller.Person);
    Assert.Equal("synthetic-session", result.SessionId); var request = Assert.Single(terminal.Requests);
    Assert.Equal(new ServerCodingTask("codex", "signin"), request.CodingTask); Assert.Single(f.Approval.Actions);
    Assert.Contains("coding AI", f.Approval.Actions[0].Operation); Assert.All(f.Runtime.Commands, command => Assert.Equal(65536, command.MaxOutputBytes));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "claude", "remove", ServerCaller.Person)); Assert.Single(terminal.Requests);
  }
  [Fact] public async Task LookOnlyUnknownActionsAndPairedDevicesNeverReachSetupTransport()
  {
    using var f = new Fixture(); var server = await f.AddAsync(); var terminal = new Terminal(); var owner = new ServerService(f.Store, f.Runtime, f.Approval, terminal);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "codex", "install", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "codex; touch /tmp/no", "install", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "codex", "shell", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.CodingAisAsync(server.Id, new("phone", Owner: true, PairedDevice: true)));
    Assert.Empty(f.Runtime.Commands); Assert.Empty(f.Approval.Actions); Assert.Empty(terminal.Requests);
  }
  [Fact] public async Task ApprovalRevocationAndReplacementPreventTerminalLaunch()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var terminal = new Terminal(); var owner = new ServerService(f.Store, f.Runtime, f.Approval, terminal); f.Runtime.Reply = _ => new(0, Coding());
    f.Approval.During = async () => await f.Store.SetAccessAsync(server.Id, server.Access with { LookOnly = true }, default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "codex", "signin", ServerCaller.Person)); Assert.Empty(terminal.Requests);
    await f.Store.SetAccessAsync(server.Id, server.Access, default);
    f.Approval.During = () => { f.Runtime.Reply = _ => new(0, Coding().Replace("1.2.3", "9.9.9", StringComparison.Ordinal)); return ValueTask.CompletedTask; };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.ChangeCodingAiAsync(server.Id, "codex", "signin", ServerCaller.Person)); Assert.Empty(terminal.Requests);
  }
  [Fact] public async Task WebsiteReadsReturnOnlyCurrentValidatedInventoryAddresses()
  {
    using var f = new Fixture(); var server = await f.AddAsync();
    f.Runtime.Reply = _ => new(0, "[{\"id\":\"site:example.test\",\"name\":\"example.test\",\"detail\":\"Served by nginx\",\"url\":\"https://example.test\"}]");
    var site = await f.Service.WebsiteAsync(server.Id, "site:example.test", ServerCaller.Person); Assert.Equal("https://example.test", site.Url); Assert.Empty(f.Approval.Actions);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.WebsiteAsync(server.Id, "site:unlisted.test", ServerCaller.Person));
    f.Runtime.Reply = _ => new(0, "[{\"id\":\"site:example.test\",\"name\":\"example.test\",\"detail\":\"Served by nginx\",\"url\":\"file:///etc/passwd\"}]");
    await Assert.ThrowsAsync<IOException>(async () => await f.Service.WebsitesAsync(server.Id, ServerCaller.Person));
    f.Runtime.Reply = _ => { f.Store.SetAccessAsync(server.Id, server.Access with { Folders = ["/changed"] }, default).AsTask().GetAwaiter().GetResult(); return new(0, "[]"); };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.WebsitesAsync(server.Id, ServerCaller.Person));
  }
  [Fact] public async Task CapabilityMcpEnforcesResourceTierCurrentGrantAndFixedSchema()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var mcp = new ServerCapabilitiesMcp(f.Service);
    var grant = new McpGrant("connected-ai", null, null, true, AiPermissionMode.Ask, ServerCapabilitiesMcp.Specs.Select(s => s.Id).ToArray(), [McpTier.Read], ["servers:" + server.Id], DateTimeOffset.UtcNow.AddMinutes(5));
    var args = JsonSerializer.SerializeToElement(new { serverId = server.Id }); var spec = ServerCapabilitiesMcp.Specs.Single(s => s.Id == "servers.websites");
    Assert.True(mcp.Preflight(grant, spec, args)); Assert.False(mcp.Preflight(grant with { Resources = [] }, spec, args)); Assert.False(mcp.Preflight(grant with { DeviceId = "phone" }, spec, args));
    var ctx = new McpCallContext(grant, _ => ValueTask.FromException(new McpRefusal("Retired")), _ => { });
    await Assert.ThrowsAsync<McpRefusal>(async () => await mcp.CallAsync("servers.websites", ctx, args, default)); Assert.Empty(f.Runtime.Commands);
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(ServerCapabilitiesMcp.Specs.Single(s => s.Id == "servers.coding_ai").InputSchema, JsonSerializer.SerializeToElement(new { serverId = server.Id, provider = "codex", action = "shell", command = "arbitrary" })));
  }
  [Fact] public void SetupSessionCarriesOnlyValidatedTypedIntentAndCommandRunsAfterSshAuthentication()
  {
    var task = new ServerCodingTask("codex", "signin"); var command = task.RemoteCommand();
    Assert.Contains("codex login --device-auth", command); Assert.Contains("exec", command);
    Assert.Throws<ServerRefusal>(() => new ServerCodingTask("codex; echo wrong", "signin").RemoteCommand());
    Assert.Throws<ServerRefusal>(() => new ServerCodingTask("claude", "arbitrary").Validate());
    Assert.Throws<ArgumentException>(() => new SessionDefinition(Guid.NewGuid().ToString(), "shell", "/scratch", "Setup") { ServerCodingTask = task }.Validate());
  }
}
