using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class W12DevicePresenceTests
{
  [Fact]
  public async Task PresenceFollowsAuthenticatedChannelLifecycleAndSurvivesRestartAsLastSeenOnly()
  {
    var clock = new TestClock(); var store = new TestTrustStore(); var trust = new DeviceTrust(store, clock);
    using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Audit phone", "android", phone.PublicKey);
    Assert.Equal(clock.Now, Assert.Single(trust.Pending()).PairedAt);
    trust.Approve(receipt.DeviceId, PhoneAccess.Full);
    var link = new PhoneLink(trust, "Audit computer", "test", new EmptySessions());
    var hello = JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token = receipt.Credential, device = new { name = "Audit phone", platform = "android" } });
    await link.ReceiveAsync("first", phone.PublicKey, hello, CancellationToken.None);
    await link.ReceiveAsync("second", phone.PublicKey, hello, CancellationToken.None);
    Assert.True(Assert.Single(trust.List()).Connected);
    clock.Now = clock.Now.AddMinutes(1);
    await link.DisconnectedAsync("first"); Assert.True(Assert.Single(trust.List()).Connected);
    await link.DisconnectedAsync("second"); Assert.False(Assert.Single(trust.List()).Connected);
    var restored = Assert.Single(new DeviceTrust(store, clock).List());
    Assert.Equal(clock.Now, restored.LastSeen); Assert.False(restored.Connected);
  }
  [Fact]
  public async Task PresenceSaveFailureDoesNotChangeTrustOrRefuseAnOtherwiseValidConnection()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(receipt.DeviceId, PhoneAccess.Look); store.FailSave = true;
    var link = new PhoneLink(trust, "Audit computer", "test", new EmptySessions());
    await link.ReceiveAsync("first", phone.PublicKey, JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token = receipt.Credential, device = new { name = "Phone", platform = "ios" } }), CancellationToken.None);
    Assert.True(Assert.Single(trust.List()).Connected); Assert.Equal(PhoneAccess.Look, Assert.Single(trust.List()).Access);
    await link.DisconnectedAsync("first"); Assert.False(Assert.Single(trust.List()).Connected);
  }
  private sealed class EmptySessions : IPhoneSessionView
  { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => []; }
}
