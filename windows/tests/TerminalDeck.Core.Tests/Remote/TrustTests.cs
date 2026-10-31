using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class TrustTests
{
  [Fact]
  public void PairingDoesNotApproveAndAStoredDeviceSurvivesRestart()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store);
    using var phone = NoiseIdentity.Generate(); var code = trust.Pairing.Create();
    var receipt = trust.Redeem(code.Code, "Phone", "ios", phone.PublicKey);
    Assert.Empty(trust.List());
    Assert.Contains("waiting for approval", Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, phone.PublicKey)).Message);
    Assert.DoesNotContain(receipt.Credential, receipt.ToString());
    Assert.DoesNotContain(receipt.Credential, System.Text.Json.JsonSerializer.Serialize(store.Rows));
    trust.Approve(receipt.DeviceId, PhoneAccess.Work);
    var restarted = new DeviceTrust(store);
    Assert.Equal(PhoneAccess.Work, restarted.Authenticate(receipt.Credential, phone.PublicKey).Access);
    Assert.Single(restarted.List());
  }

  [Fact]
  public void CredentialIsBoundToKeyAndRevocationTakesEffectImmediately()
  {
    var trust = new DeviceTrust(new TestTrustStore());
    using var phone = NoiseIdentity.Generate(); using var stranger = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "android", phone.PublicKey);
    trust.Approve(receipt.DeviceId, PhoneAccess.Full);
    Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, stranger.PublicKey));
    Assert.Equal(receipt.DeviceId, trust.Authenticate(receipt.Credential, phone.PublicKey).Id);
    trust.Revoke(receipt.DeviceId);
    Assert.Throws<ProtocolException>(() => trust.RequireCurrent(receipt.DeviceId, phone.PublicKey));
    Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, phone.PublicKey));
    Assert.Empty(trust.KnownPeers);
  }

  [Fact]
  public void RePairingOneKeyKeepsOneDeviceAndRotatesItsCredential()
  {
    var trust = new DeviceTrust(new TestTrustStore()); using var phone = NoiseIdentity.Generate();
    var first = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(first.DeviceId, PhoneAccess.Look);
    var second = trust.Redeem(trust.Pairing.Create().Code, "New name", "ios", phone.PublicKey);
    Assert.Equal(first.DeviceId, second.DeviceId); Assert.Single(trust.List());
    Assert.NotEqual(first.Credential, second.Credential);
    Assert.Throws<ProtocolException>(() => trust.Authenticate(first.Credential, phone.PublicKey));
    Assert.Equal("New name", trust.Authenticate(second.Credential, phone.PublicKey).Name);
  }

  [Fact]
  public void FailedApprovalSaveCannotCreateAnInMemoryGrant()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    store.FailSave = true;
    Assert.Throws<IOException>(() => trust.Approve(receipt.DeviceId, PhoneAccess.Full));
    Assert.Empty(trust.List());
    Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, phone.PublicKey));
  }

  [Fact]
  public void AuthenticationFailuresHaveABoundedCooldown()
  {
    var clock = new TestClock(); var trust = new DeviceTrust(new TestTrustStore(), clock); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(receipt.DeviceId, PhoneAccess.Look);
    for (var i = 0; i < 5; i++) Assert.Throws<ProtocolException>(() => trust.Authenticate("not.a-credential", phone.PublicKey));
    Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, phone.PublicKey));
    clock.Now = clock.Now.AddMinutes(1);
    Assert.Equal(receipt.DeviceId, trust.Authenticate(receipt.Credential, phone.PublicKey).Id);
  }
}

internal sealed class TestTrustStore : IDeviceTrustPersistence
{
  public IReadOnlyList<StoredDevice> Rows { get; private set; } = [];
  public bool FailSave { get; set; }
  public IReadOnlyList<StoredDevice> Load() => Rows;
  public void Save(IReadOnlyList<StoredDevice> devices)
  {
    if (FailSave) throw new IOException("Synthetic storage failure");
    Rows = devices;
  }
}
