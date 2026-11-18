using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Cloud;

public sealed class CloudSubscriptionTests
{
  private static readonly string[] BeforeTools = ["cloud.status", "cloud.profile", "cloud.devices", "cloud.folder", "cloud.folder_add", "cloud.artifacts", "cloud.project_secrets", "cloud.reach.status", "remote.manage", "remote.status", "computers.services", "phone.screen", "ai_apps.internet", "mcp.remote", "sessions.send", "tasks.list", "agents.list", "whatsapp.agents"];
  private static readonly string[] BeforeCommands = ["devices", "cloud", "cloud-page", "settings:cloud", "settings:devices", "join-remote", "cloud-session:example", "cloud-earlier:example", "new-session", "settings:profile", "whatsapp", "servers"];
  private static CloudSubscriptionSnapshot Snapshot(string paywall, string state, bool offer = false) => new(new(paywall, state, Offer: offer), true);

  [Theory]
  [InlineData("paid", false)] [InlineData("none", false)] [InlineData("gift", true)] [InlineData("lapsed", true)]
  public void Paywall_off_has_no_difference_across_every_declared_place_tool_and_command(string state, bool offer)
  {
    var off = Snapshot("off", state, offer);
    Assert.True(off.AllowsCloudServices); Assert.False(off.ShowsSubscription);
    Assert.Equal(16, Enum.GetValues<CloudPaidPlace>().Length);
    foreach (var place in Enum.GetValues<CloudPaidPlace>())
    {
      Assert.True(off.Offers(place, true));
      Assert.False(off.Offers(place, false));
    }
    Assert.Equal(BeforeTools, BeforeTools.Where(t => CloudPaidInventory.ShowsTool(off, t)));
    Assert.Equal(BeforeCommands, BeforeCommands.Where(c => CloudPaidInventory.ShowsCommand(off, c)));
    Assert.False(CloudPaidInventory.ShowsTool(off, CloudSubscriptionTools.Id));
  }

  [Theory]
  [InlineData("none")] [InlineData("lapsed")]
  public void Unpaid_hides_paid_places_and_tools_but_keeps_local_accounts_and_WhatsApp(string state)
  {
    var unpaid = Snapshot("on", state);
    Assert.False(unpaid.AllowsCloudServices); Assert.True(unpaid.ShowsSubscription);
    Assert.All(Enum.GetValues<CloudPaidPlace>(), place => Assert.False(unpaid.Offers(place)));
    Assert.Equal(new[] { "cloud.profile", "sessions.send", "tasks.list", "agents.list", "whatsapp.agents" }, BeforeTools.Where(t => CloudPaidInventory.ShowsTool(unpaid, t)));
    Assert.Equal(new[] { "new-session", "settings:profile", "whatsapp", "servers" }, BeforeCommands.Where(c => CloudPaidInventory.ShowsCommand(unpaid, c)));
    Assert.True(CloudPaidInventory.ShowsTool(unpaid, CloudSubscriptionTools.Id));
  }

  [Theory] [InlineData("paid")] [InlineData("gift")]
  public void Paid_and_gift_use_existing_capabilities_without_adding_one(string state)
  {
    var value = Snapshot("on", state);
    Assert.True(value.AllowsCloudServices); Assert.True(value.ShowsSubscription);
    Assert.All(Enum.GetValues<CloudPaidPlace>(), place => Assert.False(value.Offers(place, false)));
    Assert.Equal(BeforeTools, BeforeTools.Where(t => CloudPaidInventory.ShowsTool(value, t)));
  }

  [Fact]
  public void Old_or_unavailable_service_keeps_facts_and_disables_only_enforcement()
  {
    var answer = new CloudSubscription("on", "paid", "yearly", 1, "apple");
    var paid = CloudSubscriptionSnapshot.Unknown.Received(answer);
    Assert.True(paid.AllowsCloudServices); // The computer's date never invents a lapse.
    var unavailable = Snapshot("on", "lapsed").Received(null);
    Assert.False(unavailable.Available); Assert.Equal("lapsed", unavailable.LastAnswer?.State);
    Assert.True(unavailable.AllowsCloudServices); Assert.False(unavailable.ShowsSubscription);
    Assert.True(CloudSubscriptionSnapshot.Unknown.AllowsCloudServices);
    Assert.False(CloudSubscriptionSnapshot.Unknown.ShowsSubscription);
    Assert.Throws<JsonException>(() => CloudSubscription.Read("{\"paywall\":\"on\",\"state\":\"manual\"}"u8.ToArray()));
  }

  private sealed class NoApproval : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct) => throw new InvalidOperationException("This read must not ask.");
  }

  [Fact]
  public async Task Door_hides_off_subscription_and_rechecks_paid_tools_after_account_changes()
  {
    var state = Snapshot("off", "none", offer: true);
    var door = new McpDoor(new NoApproval()) { ToolOffered = id => CloudPaidInventory.ShowsTool(state, id) };
    door.Register("cloud.status", (_, _, _) => ValueTask.FromResult(JsonSerializer.SerializeToElement(new { available = true })));
    door.Register(CloudSubscriptionTools.Id, (_, _, _) => ValueTask.FromResult(JsonSerializer.SerializeToElement(new { state = "none" })));
    var registration = door.RegisterCaller(new McpGrant("test", null, null, true, AiPermissionMode.Ask, ["cloud.status", CloudSubscriptionTools.Id], [McpTier.Read], ["settings:workspace"], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.Equal(new[] { "cloud.status" }, door.List(registration.Id).Select(t => t.Id));
    state = Snapshot("on", "none");
    Assert.Equal(new[] { CloudSubscriptionTools.Id }, door.List(registration.Id).Select(t => t.Id));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(registration.Id, "cloud_status", JsonSerializer.SerializeToElement(new { })));
    state = Snapshot("on", "gift");
    _ = await door.CallAsync(registration.Id, "cloud_status", JsonSerializer.SerializeToElement(new { }));
  }

  [Fact]
  public void Existing_relay_token_loses_only_relay_admission_and_can_resume_without_reissuing_a_key()
  {
    var allowed = true;
    var door = new McpDoor(new NoApproval()) { RelayAllowed = () => allowed };
    var registration = door.RegisterCaller(new McpGrant("test", null, null, true, AiPermissionMode.Ask, [], [McpTier.Read], [], DateTimeOffset.UtcNow.AddMinutes(5), AllowRelay: true), (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.True(door.AllowsRelay(registration.Token));
    allowed = false;
    Assert.False(door.AllowsRelay(registration.Token));
    Assert.Equal(registration.Id, door.Authenticate(registration.Token));
    allowed = true;
    Assert.True(door.AllowsRelay(registration.Token));
  }

  [Theory]
  [InlineData("chat-watch", McpTier.Read)] [InlineData("chat-unwatch", McpTier.Read)] [InlineData("chat-options", McpTier.Read)]
  [InlineData("chat-set", McpTier.Alter)] [InlineData("chat-send", McpTier.Alter)] [InlineData("chat-interrupt", McpTier.Alter)] [InlineData("chat-answer", McpTier.Alter)]
  public void Remote_chat_actions_use_existing_read_and_change_approval_tiers(string action, McpTier expected)
  {
    var spec = McpCatalogue.Load().Single(s => s.Id == "computers.services");
    Assert.Equal(expected, McpCatalogue.EffectiveTier(spec, JsonSerializer.SerializeToElement(new { action })));
  }

  [Theory]
  [InlineData("list", McpTier.Read)] [InlineData("read", McpTier.Read)] [InlineData("save", McpTier.Alter)] [InlineData("assign", McpTier.Alter)] [InlineData("unassign", McpTier.Alter)]
  public void Agent_library_writes_keep_existing_approval_policy(string action, McpTier expected)
  {
    var spec = McpCatalogue.Load().Single(s => s.Id == "agents.library");
    Assert.Equal(expected, McpCatalogue.EffectiveTier(spec, JsonSerializer.SerializeToElement(new { action })));
  }

  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Utc = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Utc;
  }
  private sealed class MemoryAccount : ICloudSecretStore
  {
    private byte[]? bytes;
    public bool Exists => bytes is not null;
    public byte[]? Read() => bytes?.ToArray();
    public void Write(ReadOnlySpan<byte> value) => bytes = value.ToArray();
    public void Remove() => bytes = null;
  }
  private sealed class SubscriptionHttp : ICloudHttp
  {
    public readonly CloudServiceFake Account = new();
    public CloudSubscription? Answer = new("off", "none");
    public int Reads;
    public Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
    {
      if (request.Url.AbsolutePath != "/v1/subscription") return Account.SendAsync(request, ct);
      Assert.Equal(HttpMethod.Get, request.Method);
      Assert.Empty(request.Body);
      Assert.StartsWith("Bearer ", request.Headers["Authorization"]);
      Reads++;
      return Task.FromResult(Answer is null ? new CloudHttpResponse(404, []) : new CloudHttpResponse(200, JsonSerializer.SerializeToUtf8Bytes(Answer, CloudWire.Json)));
    }
  }

  [Fact]
  public async Task Existing_refresh_reads_subscription_without_registration_or_identity_changes_and_old_service_adds_no_entitlement()
  {
    var http = new SubscriptionHttp(); var clock = new Clock();
    using var account = new CloudAccountClient(CloudConfiguration.Today("PC", "1"), new MemoryAccount(), http, new CountingRandom(), new FakeBrowser(), clock);
    var start = await account.BeginSignInAsync();
    var query = start.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
    Assert.True(await account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{query["callback"]}?code=Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19&state={query["state"]}")));
    var identity = account.SyncIdentity;
    Assert.NotNull(identity); Assert.False(account.Snapshot.Subscription.ShowsSubscription);
    await account.RefreshAsync(); Assert.Equal(1, http.Reads);
    clock.Utc += TimeSpan.FromMinutes(5); http.Answer = new("on", "none");
    await account.RefreshAsync();
    Assert.Null(account.SyncIdentity); Assert.Equal(CloudPhase.NotAllowed, account.Snapshot.Phase);
    Assert.NotNull(account.Snapshot.Email);
    clock.Utc += TimeSpan.FromMinutes(5); http.Answer = new("on", "gift", Source: "gift");
    await account.RefreshAsync(); Assert.Equal(identity, account.SyncIdentity);
    Assert.Single(http.Account.Requests, r => r.Method == HttpMethod.Post && r.Url.AbsolutePath == "/v1/devices");
    clock.Utc += TimeSpan.FromMinutes(5); http.Answer = null; http.Account.Entitled = false;
    await account.RefreshAsync();
    Assert.False(account.Snapshot.Subscription.Available);
    Assert.Equal("gift", account.Snapshot.Subscription.LastAnswer?.State);
    Assert.True(account.Snapshot.Subscription.AllowsCloudServices);
    Assert.Null(account.SyncIdentity); Assert.Equal(CloudPhase.NotAllowed, account.Snapshot.Phase);
  }

}
