using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Mcp;

public sealed class FakePermission : IMcpPermissionBroker
{
  public List<McpPermissionRequest> Requests { get; } = [];
  public Func<McpPermissionRequest, McpPermissionProof>? Answer { get; set; }
  public Func<ValueTask>? WhileWaiting { get; set; }
  public async ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct)
  {
    Requests.Add(request); if (WhileWaiting is not null) await WhileWaiting();
    return Answer?.Invoke(request) ?? new(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true);
  }
}
public sealed class TestSecretStore : ISecretStore
{
  public Dictionary<string, byte[]> Values { get; } = [];
  public ValueTask<byte[]?> ReadAsync(string name, CancellationToken ct = default) => ValueTask.FromResult(Values.GetValueOrDefault(name)?.ToArray());
  public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken ct = default) { Values[name] = value.ToArray(); return ValueTask.CompletedTask; }
  public ValueTask DeleteAsync(string name, CancellationToken ct = default) { Values.Remove(name); return ValueTask.CompletedTask; }
}
public sealed class FakeMcpFactory : IMcpConnectionFactory
{
  public List<FakeMcpConnection> Created { get; } = [];
  public ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct)
  { var connection = new FakeMcpConnection(); Created.Add(connection); return ValueTask.FromResult<IManagedMcpConnection>(connection); }
}
public sealed class FakeMcpConnection : IManagedMcpConnection
{
  public bool Disposed { get; private set; }
  public bool FailCall { get; set; }
  public ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<McpRemoteTool>>([new("echo", JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))]);
  public ValueTask<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken ct)
  { if (FailCall) throw new IOException("synthetic-private-value"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { ok = true })); }
  public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
}
public sealed class FakeCommandResolver : IMcpCommandResolver
{
  public McpCommand Resolve(string commandLine) => new(commandLine, []);
}

public sealed class McpTests
{
  private static JsonElement Args(string text = "{}") => JsonDocument.Parse(text).RootElement.Clone();
  public static McpGrant Grant(params string[] tools) => new("caller", "source", null, true, AiPermissionMode.Ask, tools, [McpTier.Read, McpTier.Act, McpTier.Alter], ["*"], DateTimeOffset.UtcNow.AddHours(1));
  private static McpRegistration Caller(McpDoor door, McpGrant grant, Func<bool>? allowed = null) => door.RegisterCaller(grant, (g, t, a, tier, ct) => ValueTask.FromResult(allowed?.Invoke() ?? true));

  [Fact] public void CatalogueDoesNotAdvertiseUnregisteredContractsAndUsesSourceSchemas()
  {
    var door = new McpDoor(new FakePermission()); var caller = Caller(door, Grant("sessions.list")); Assert.Empty(door.List(caller.Id));
    door.Register("sessions.list", (c, a, ct) => ValueTask.FromResult(Args())); var spec = Assert.Single(door.List(caller.Id));
    Assert.Equal("sessions_list", spec.Wire); Assert.False(spec.InputSchema.GetProperty("additionalProperties").GetBoolean());
    Assert.Throws<InvalidOperationException>(() => door.Register("sessions.list", (c, a, ct) => ValueTask.FromResult(Args())));
    Assert.Throws<ArgumentException>(() => door.Register("made.up", (c, a, ct) => ValueTask.FromResult(Args())));
  }
  [Fact] public async Task ReadsAreFreeAndAliasesCallTheSameHandler()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var caller = Caller(door, Grant("sessions.list")); var calls = 0;
    door.Register("sessions.list", (c, a, ct) => { calls++; return ValueTask.FromResult(Args()); });
    await door.CallAsync(caller.Id, "sessions_list", Args()); Assert.Equal(1, calls); Assert.Empty(permission.Requests);
  }
  [Fact] public async Task ExactApprovalIsSingleUseAndNotReplaceableByArguments()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var caller = Caller(door, Grant("sessions.rename")); var calls = 0;
    door.Register("sessions.rename", (c, a, ct) => { calls++; return ValueTask.FromResult(Args()); });
    var proofId = Guid.NewGuid(); permission.Answer = r => new(proofId, r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true);
    var args = Args("{\"sessionId\":\"s\",\"title\":\"New\"}"); await door.CallAsync(caller.Id, "sessions.rename", args);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.rename", args));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.rename", Args("{\"sessionId\":\"s\",\"title\":\"New\",\"caller\":\"owner\"}"))); Assert.Equal(1, calls);
  }
  [Theory] [InlineData("wrong-caller")] [InlineData("wrong-action")] [InlineData("expired")] [InlineData("denied")]
  public async Task ApprovalMustMatchCallerActionAndExpiry(string fault)
  {
    var permission = new FakePermission { Answer = r => new(Guid.NewGuid(), fault == "wrong-caller" ? "other" : r.CallerId, fault == "wrong-action" ? "other" : r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(fault == "expired" ? -1 : 1), fault != "denied") };
    var door = new McpDoor(permission); var caller = Caller(door, Grant("sessions.rename")); door.Register("sessions.rename", (c, a, ct) => throw new Exception("Must not run."));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.rename", Args("{\"sessionId\":\"s\",\"title\":\"New\"}")));
  }
  [Fact] public async Task RevocationWhileApprovalWaitsPreventsTheEffect()
  {
    var permitted = true; var permission = new FakePermission { WhileWaiting = () => { permitted = false; return ValueTask.CompletedTask; } }; var door = new McpDoor(permission);
    var caller = Caller(door, Grant("sessions.rename"), () => permitted); var ran = false; door.Register("sessions.rename", (c, a, ct) => { ran = true; return ValueTask.FromResult(Args()); });
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.rename", Args("{\"sessionId\":\"s\",\"title\":\"New\"}"))); Assert.False(ran);
  }
  [Fact] public async Task RevocationDuringAReadPreventsItsResultEscaping()
  {
    var permitted = true; var door = new McpDoor(new FakePermission()); var caller = Caller(door, Grant("sessions.list"), () => permitted);
    door.Register("sessions.list", (c, a, ct) => { permitted = false; return ValueTask.FromResult(Args("{\"private\":true}")); });
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.list", Args()));
  }
  [Fact] public async Task BypassStillCannotCrossLiveGrantsAndPlanCannotChangeAnything()
  {
    var permission = new FakePermission(); var door = new McpDoor(permission); var bypass = Caller(door, Grant("sessions.rename") with { PermissionMode = AiPermissionMode.Bypass }, () => false);
    var plan = Caller(door, Grant("sessions.rename") with { PermissionMode = AiPermissionMode.Plan }); door.Register("sessions.rename", (c, a, ct) => ValueTask.FromResult(Args()));
    var args = Args("{\"sessionId\":\"s\",\"title\":\"New\"}"); await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(bypass.Id, "sessions.rename", args)); await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(plan.Id, "sessions.rename", args)); Assert.Empty(permission.Requests);
  }
  [Theory] [InlineData("sessions.account", "switch", McpTier.Alter)] [InlineData("sessions.account", "cancel", McpTier.Act)] [InlineData("sessions.account", "plan", McpTier.Read)] [InlineData("browser.windows", "attach", McpTier.Alter)] [InlineData("browser.windows", "open", McpTier.Act)] [InlineData("browser.page", "recordclear", McpTier.Alter)] [InlineData("browser.profiles", "activate", McpTier.Alter)]
  public void ActionTiersMatchTheRuntimeSource(string id, string action, McpTier expected)
  { var spec = McpCatalogue.Load().Single(t => t.Id == id); Assert.Equal(expected, McpCatalogue.EffectiveTier(spec, JsonSerializer.SerializeToElement(new { action }))); }
  [Fact] public void SessionOwnershipAndCanonicalArgumentsAreBackendFacts()
  {
    var spec = McpCatalogue.Load().Single(t => t.Id == "sessions.send"); Assert.Equal(McpTier.Alter, McpCatalogue.EffectiveTier(spec, Args())); Assert.Equal(McpTier.Act, McpCatalogue.EffectiveTier(spec, Args(), true));
    Assert.Equal(McpDoor.ActionDigest("c", "t", Args("{\"b\":2,\"a\":1}"), McpTier.Act), McpDoor.ActionDigest("c", "t", Args("{\"a\":1,\"b\":2}"), McpTier.Act));
  }
  [Theory] [InlineData("{\"sessionId\":7,\"title\":\"x\"}")] [InlineData("{\"sessionId\":\"s\"}")] [InlineData("{\"sessionId\":\"s\",\"title\":\"a\",\"title\":\"b\"}")]
  public void SchemaRefusesWrongMissingAndRepeatedFields(string json)
  { var spec = McpCatalogue.Load().Single(t => t.Id == "sessions.rename"); Assert.Throws<McpRefusal>(() => McpSchema.Validate(spec.InputSchema, Args(json))); }

  [Fact] public async Task SessionAndAccountHandlersUseRealCoreAndFilterPrivateRows()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper()); var first = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\work", "A")); await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\secret", "B"));
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]); var account = await accounts.CreateAsync("codex", "Work");
    var door = new McpDoor(new FakePermission()); DeckCoreTools.RegisterSessions(door, keeper, accounts); DeckCoreTools.RegisterAccounts(door, accounts, keeper);
    var caller = Caller(door, Grant("sessions.list", "sessions.rename", "accounts.list") with { Resources = ["sessions:" + first.Definition.Id] });
    Assert.Single((await door.CallAsync(caller.Id, "sessions.list", Args())).EnumerateArray()); Assert.Empty((await door.CallAsync(caller.Id, "accounts.list", Args())).EnumerateArray());
    await door.CallAsync(caller.Id, "sessions.rename", JsonSerializer.SerializeToElement(new { sessionId = first.Definition.Id, title = "Changed" })); Assert.Equal("Changed", keeper.Get(first.Definition.Id).Definition.Title); Assert.NotNull(account);
  }

  [Fact] public async Task ManagerProtectsSecretsAndTracksOnlyItsOwnConnections()
  {
    var secrets = new TestSecretStore(); var factory = new FakeMcpFactory(); var store = new MemoryState<McpManagerState>(); await using var manager = Manager(store, secrets, factory);
    var row = await manager.AddAsync(new() { Name = "echo", Scope = "user", Transport = "stdio", Command = "echo.exe", Environment = new() { ["TOKEN"] = "synthetic-private-value" } });
    Assert.DoesNotContain("synthetic-private-value", JsonSerializer.Serialize(store.Value)); Assert.False(Assert.Single(await manager.ListAsync()).Connected);
    await manager.ConnectAsync(row.Id); await manager.ConnectAsync(row.Id); Assert.Single(factory.Created); Assert.True(Assert.Single(await manager.ListAsync()).Connected);
    var exported = await manager.ExportAsync(row.Id); Assert.DoesNotContain("synthetic-private-value", exported.GetRawText()); Assert.DoesNotContain("echo.exe", exported.GetRawText());
    await manager.DisconnectAsync(row.Id); Assert.True(factory.Created[0].Disposed); Assert.Single(secrets.Values);
    await manager.RemoveAsync(row.Id); Assert.Empty(secrets.Values); Assert.Empty(await manager.ListAsync());
  }
  [Fact] public async Task ManagerPatchKeepsOmittedCredentialsAndStopsItsOwnConnection()
  {
    var secrets = new TestSecretStore(); var factory = new FakeMcpFactory(); await using var manager = Manager(new MemoryState<McpManagerState>(), secrets, factory);
    var row = await manager.AddAsync(new() { Name = "echo", Scope = "user", Transport = "stdio", Command = "echo.exe", Environment = new() { ["TOKEN"] = "synthetic" } });
    await manager.ConnectAsync(row.Id); await manager.EditPatchAsync(row.Id, Args("{\"name\":\"renamed\"}")); Assert.True(factory.Created[0].Disposed); Assert.Single(secrets.Values); Assert.Equal("user:renamed", Assert.Single(await manager.ListAsync()).Id);
    await manager.EditPatchAsync("user:renamed", Args("{\"env\":{}}")); Assert.Empty(secrets.Values);
  }
  [Fact] public async Task ManagerRejectsUnknownToolsAndRedactsRemoteErrors()
  {
    var factory = new FakeMcpFactory(); await using var manager = Manager(new MemoryState<McpManagerState>(), new TestSecretStore(), factory);
    var row = await manager.AddAsync(new() { Name = "echo", Scope = "user", Transport = "http", Url = "https://example.test/mcp" });
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.CallAsync(row.Id, "echo", Args())); await manager.ConnectAsync(row.Id);
    await Assert.ThrowsAsync<McpRefusal>(async () => await manager.CallAsync(row.Id, "absent", Args())); factory.Created[0].FailCall = true;
    var error = await Assert.ThrowsAsync<McpRefusal>(async () => await manager.CallAsync(row.Id, "echo", Args())); Assert.DoesNotContain("synthetic-private-value", error.Message);
  }
  [Fact] public async Task FailedManagerSaveCleansUpNewSecretReferences()
  {
    var store = new MemoryState<McpManagerState> { FailSave = true }; var secrets = new TestSecretStore(); await using var manager = Manager(store, secrets, new FakeMcpFactory());
    await Assert.ThrowsAsync<IOException>(async () => await manager.AddAsync(new() { Name = "echo", Scope = "user", Transport = "stdio", Command = "echo.exe", Headers = new() { ["Authorization"] = "synthetic" } })); Assert.Empty(secrets.Values); Assert.Empty(await manager.ListAsync());
  }
  [Fact] public async Task ImportIsReadOnlyAndReturnsNoSecretOrCommandValues()
  {
    var door = new McpDoor(new FakePermission()); await using var manager = Manager(new MemoryState<McpManagerState>(), new TestSecretStore(), new FakeMcpFactory()); DeckCoreTools.RegisterManager(door, manager); var caller = Caller(door, Grant("mcp.import"));
    var preview = await door.CallAsync(caller.Id, "mcp.import", JsonSerializer.SerializeToElement(new { text = "{\"mcpServers\":{\"echo\":{\"command\":\"private-command\",\"env\":{\"TOKEN\":\"private-value\"}}}}" }));
    Assert.False(preview.GetProperty("applied").GetBoolean()); Assert.DoesNotContain("private-", preview.GetRawText()); Assert.Empty(await manager.ListAsync());
  }
  [Fact] public async Task HttpBoundaryNegotiatesAndRefusesOriginWrongHostAndBadTokens()
  {
    var door = new McpDoor(new FakePermission()); var caller = Caller(door, Grant("sessions.list")); door.Register("sessions.list", (c, a, ct) => ValueTask.FromResult(Args())); var endpoint = new McpHttpEndpoint(door, new("http://127.0.0.1:4321/mcp"), "test");
    var init = await endpoint.HandleAsync(Request(caller.Token, "initialize", new { protocolVersion = "2025-03-26" })); using var result = JsonDocument.Parse(init.Body); Assert.Equal("deck-control", result.RootElement.GetProperty("result").GetProperty("serverInfo").GetProperty("name").GetString());
    Assert.Equal("2025-03-26", result.RootElement.GetProperty("result").GetProperty("protocolVersion").GetString());
    var list = await endpoint.HandleAsync(Request(caller.Token, "tools/list", new { })); Assert.Contains("sessions_list", Encoding.UTF8.GetString(list.Body));
    Assert.Equal(403, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }, origin: "null"))).Status);
    Assert.Equal(403, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }, host: "example.test:4321"))).Status);
    Assert.Equal(401, (await endpoint.HandleAsync(Request("incorrect", "ping", new { }))).Status);
    door.Revoke(caller.Id); Assert.Equal(401, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }))).Status);
  }
  [Fact] public async Task HttpCancellationStopsOnlyThatCallAndReleasesItsSlot()
  {
    var door = new McpDoor(new FakePermission()); var caller = Caller(door, Grant("sessions.list")); var began = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    door.Register("sessions.list", async (c, a, ct) => { began.SetResult(); await Task.Delay(Timeout.Infinite, ct); return Args(); }); var endpoint = new McpHttpEndpoint(door, new("http://127.0.0.1:4321/mcp"), "test");
    await endpoint.HandleAsync(Request(caller.Token, "initialize", new { protocolVersion = "2025-06-18" }));
    var call = endpoint.HandleAsync(Request(caller.Token, "tools/call", new { name = "sessions_list", arguments = new { } }, id: 2)).AsTask(); await began.Task.WaitAsync(TimeSpan.FromSeconds(2));
    await endpoint.HandleAsync(Request(caller.Token, "notifications/cancelled", new { requestId = 2 }, id: null));
    var response = await call.WaitAsync(TimeSpan.FromSeconds(2)); Assert.Contains("cancelled", Encoding.UTF8.GetString(response.Body)); Assert.Equal(200, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }))).Status);
  }
  [Fact] public async Task HttpHasPerCallerRateAndInputBounds()
  {
    var door = new McpDoor(new FakePermission()); var caller = Caller(door, Grant()); var endpoint = new McpHttpEndpoint(door, new("http://127.0.0.1:4321/mcp"), "test");
    for (var i = 0; i < 120; i++) Assert.Equal(200, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }))).Status);
    Assert.Equal(429, (await endpoint.HandleAsync(Request(caller.Token, "ping", new { }))).Status);
    Assert.Equal(413, (await endpoint.HandleAsync(new() { Method = "POST", Path = "/mcp", Host = "127.0.0.1:4321", Authorization = "Bearer " + caller.Token, Body = new byte[65537] })).Status);
  }
  [Fact] public void RelayReplyUsesActualFirstByteFlagsAndOnlyTheFirstSliceHasAHead()
  {
    var body = new byte[70_000]; Random.Shared.NextBytes(body); var chunks = McpRelayCodec.EncodeReply(new(200, body)); Assert.Equal(2, chunks.Count); Assert.Equal(1, chunks[0][0]); Assert.Equal(2, chunks[1][0]);
    var length = BinaryPrimitives.ReadUInt16BigEndian(chunks[0].AsSpan(1)); using var head = JsonDocument.Parse(chunks[0].AsMemory(3, length)); Assert.Equal(200, head.RootElement.GetProperty("status").GetInt32());
    Assert.Equal(body, chunks[0][(3 + length)..].Concat(chunks[1][1..]).ToArray());
  }
  [Fact] public void RelayRequestHasTwoByteHeadAndNoLocalHttpAssumption()
  {
    var head = Encoding.UTF8.GetBytes("{\"v\":1,\"pathKey\":\"opaque-key\",\"authorization\":\"synthetic\"}"); var bytes = new byte[2 + head.Length + 2]; BinaryPrimitives.WriteUInt16BigEndian(bytes, (ushort)head.Length); head.CopyTo(bytes, 2); bytes[^2] = 1; bytes[^1] = 2;
    var decoded = McpRelayCodec.DecodeRequest(bytes); Assert.Equal("opaque-key", decoded.Head.PathKey); Assert.Equal(new byte[] { 1, 2 }, decoded.Body); Assert.DoesNotContain("synthetic", decoded.Head.ToString());
    Assert.Throws<McpRefusal>(() => McpRelayCodec.DecodeRequest(new byte[] { 255, 255 }));
  }
  [Fact] public async Task DeferredSwitchWaitsForBackgroundChildrenAndChecksCurrentAuthority()
  {
    var provider = new FakeAccountProvider("codex"); var accounts = new AccountService(new MemoryState<AccountState>(), [provider]); var account = await accounts.CreateAsync("codex", "Work"); provider.Statuses[account.Id] = new(true, "person@example.test");
    var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), process); var session = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "codex", "C:\\work", "A"));
    var runtime = new FakeAccountRuntime { Binding = new(session.Definition.Id, "chat", "vendor-chat", "codex", "old", "old-home", 1) };
    var authorization = new DeferredAuthorization(); var tools = new AccountSwitchTools(new(accounts, runtime, new MemoryState<AccountSwitchJournal>()), runtime, keeper, accounts, new MemoryState<DeferredSwitchState>(), authorization);
    var door = new McpDoor(new FakePermission()); tools.Register(door); var caller = Caller(door, Grant("sessions.account"));
    await door.CallAsync(caller.Id, "sessions.account", JsonSerializer.SerializeToElement(new { action = "later", sessionId = session.Definition.Id, account = account.Id }));
    process.Observations[session.Definition.Id] = new(ProcessPresence.Live, session.LeaseIdentity, false, 1); Assert.False(await tools.OnIdleAsync(session.Definition.Id)); Assert.Equal("old", runtime.Binding.AccountId);
    process.Observations[session.Definition.Id] = new(ProcessPresence.Live, session.LeaseIdentity); authorization.Allowed = false;
    Assert.False(await tools.OnIdleAsync(session.Definition.Id)); Assert.Equal("old", runtime.Binding.AccountId);
    Assert.Empty((await door.CallAsync(caller.Id, "sessions.account", Args("{\"action\":\"armed\"}"))).EnumerateArray());
  }
  private sealed class DeferredAuthorization : IDeferredSwitchAuthorizer
  {
    public bool Allowed { get; set; } = true;
    public ValueTask<bool> StillAllowedAsync(DeferredAccountSwitch change, CancellationToken ct) => ValueTask.FromResult(Allowed);
  }
  private static McpManager Manager(MemoryState<McpManagerState> state, TestSecretStore secrets, FakeMcpFactory factory) => new(state, secrets, AppDataRoot.Explicit("/tmp/td-w2-mcp"), new FakeCommandResolver(), factory);
  private static McpHttpRequest Request(string token, string method, object args, int? id = 1, string? origin = null, string host = "127.0.0.1:4321") => new()
  { Method = "POST", Path = "/mcp", Host = host, Origin = origin, Authorization = "Bearer " + token, Body = JsonSerializer.SerializeToUtf8Bytes(new { jsonrpc = "2.0", id, method, @params = args }, new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }) };
}
