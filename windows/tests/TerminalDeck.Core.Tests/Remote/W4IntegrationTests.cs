using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using System.Text.Json;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class W4IntegrationTests
{
  [Fact]
  public void PendingDeviceIsVisibleWithoutGrantingSessionAccess()
  {
    var trust = new DeviceTrust(new TestTrustStore()); var changes = 0;
    trust.Changed += () => changes++;
    using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "W4 Android", "android", phone.PublicKey);
    Assert.Equal(receipt.DeviceId, Assert.Single(trust.Pending()).Id);
    Assert.Empty(trust.List());
    trust.Approve(receipt.DeviceId, PhoneAccess.Look);
    Assert.Empty(trust.Pending()); Assert.Single(trust.List());
    trust.Revoke(receipt.DeviceId);
    Assert.Empty(trust.Pending()); Assert.Empty(trust.List()); Assert.Equal(3, changes);
  }

  [Fact]
  public void FailedDeviceSaveDoesNotPublishAFalseUiChange()
  {
    var store = new TestTrustStore { FailSave = true }; var trust = new DeviceTrust(store); var changes = 0;
    trust.Changed += () => changes++;
    using var phone = NoiseIdentity.Generate();
    Assert.Throws<IOException>(() => trust.Redeem(trust.Pairing.Create().Code, "W4 Android", "android", phone.PublicKey));
    Assert.Empty(trust.Pending()); Assert.Equal(0, changes);
  }

  [Fact]
  public async Task RendezvousClientCanBeComposedWithoutExposingItsSecret()
  {
    using var identity = PairingCode.Derive("123456");
    var beacon = new RendezvousBeacon(new(RelayEndpoint.Default, identity.HostId, identity.Keys.PublicKey, "PC", "win32"), DateTimeOffset.UtcNow.AddMinutes(1), TimeProvider.System);
    using var client = RelayHostClient.ForRendezvous(RelayEndpoint.Default, identity, beacon);
    using var stop = new CancellationTokenSource(); stop.Cancel();
    await client.RunAsync(stop.Token);
    Assert.DoesNotContain("123456", identity.ToString());
  }

  [Fact]
  public void BrowserToolbarSizeAndSendAreValidatedActTools()
  {
    var page = McpCatalogue.Load().Single(t => t.Id == "browser.page");
    var size = JsonSerializer.SerializeToElement(new { action = "size", width = 390, height = 844 });
    McpSchema.Validate(page.InputSchema, size);
    Assert.Equal(McpTier.Act, McpCatalogue.EffectiveTier(page, size));
    McpSchema.Validate(page.InputSchema, JsonSerializer.SerializeToElement(new { action = "send" }));
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(page.InputSchema, JsonSerializer.SerializeToElement(new { action = "size", width = 1, height = 844 })));
  }

  [Fact]
  public void SignInPurposeCannotCarryAnUnknownWorkerMode()
  {
    var definition = new SessionDefinition(Guid.NewGuid().ToString(), "codex", @"C:\scratch", "Sign in", Purpose: "sign-in");
    definition.Validate();
    Assert.Throws<ArgumentException>(() => (definition with { Purpose = "unknown" }).Validate());
  }
  [Fact]
  public async Task UiDispatchCannotBypassTheExistingPermissionGate()
  {
    var dispatched = 0; var handled = 0;
    var door = new McpDoor(new RefusingBroker(), wrap: (_, handler) => async (c, a, ct) => { dispatched++; return await handler(c, a, ct); });
    door.Register("sessions.list", (c, a, ct) => { handled++; return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { })); });
    McpGrant Grant(string id) => new(id, null, null, true, AiPermissionMode.Ask, ["sessions.list"], [McpTier.Read], [], DateTimeOffset.UtcNow.AddMinutes(1));
    var refused = door.RegisterCaller(Grant("refused"), (_, _, _, _, _) => ValueTask.FromResult(false));
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(refused.Id, "sessions.list", JsonSerializer.SerializeToElement(new { })).AsTask());
    Assert.Equal(0, dispatched); Assert.Equal(0, handled);
    var allowed = door.RegisterCaller(Grant("allowed"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(allowed.Id, "sessions.list", JsonSerializer.SerializeToElement(new { }));
    Assert.Equal(1, dispatched); Assert.Equal(1, handled);
  }
  private sealed class RefusingBroker : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest r, CancellationToken ct) => ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false));
  }

}
