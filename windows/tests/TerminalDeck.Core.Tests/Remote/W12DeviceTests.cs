using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class W12DeviceTests
{
  [Fact]
  public void NewDeviceOffersFullControlButStillNeedsApprovalAndRePairKeepsChosenAccess()
  {
    var trust = new DeviceTrust(new TestTrustStore()); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "android", phone.PublicKey);
    Assert.Equal(PhoneAccess.Full, Assert.Single(trust.Pending()).Access);
    Assert.Throws<ProtocolException>(() => trust.Authenticate(receipt.Credential, phone.PublicKey));
    trust.Approve(receipt.DeviceId, PhoneAccess.Look);
    var second = trust.Redeem(trust.Pairing.Create().Code, "Phone", "android", phone.PublicKey);
    Assert.Equal(PhoneAccess.Look, trust.Authenticate(second.Credential, phone.PublicKey).Access);
  }

  [Fact]
  public void RenamePersistsWithoutChangingCredentialsOrApproval()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Rename(receipt.DeviceId, new string('N', 128));
    Assert.Empty(trust.List());
    trust.Approve(receipt.DeviceId, PhoneAccess.Look);
    Assert.Equal(new string('N', 128), new DeviceTrust(store).Authenticate(receipt.Credential, phone.PublicKey).Name);
  }

  [Theory]
  [InlineData("")]
  [InlineData(" \t ")]
  [InlineData("Misleading\u202ename")]
  public void InvalidRenameKeepsOriginal(string name)
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    Assert.Throws<ArgumentException>(() => trust.Rename(receipt.DeviceId, name));
    Assert.Equal("Phone", Assert.Single(trust.Pending()).Name);
  }

  [Fact]
  public void FailedRenameDoesNotChangeStoredOrVisibleName()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    store.FailSave = true;
    Assert.Throws<IOException>(() => trust.Rename(receipt.DeviceId, "New name"));
    Assert.Equal("Phone", Assert.Single(trust.Pending()).Name);
    Assert.Equal("Phone", Assert.Single(store.Rows).Name);
  }

  [Fact]
  public void DismissingOldPairingSheetCannotCancelANewerCode()
  {
    var pairing = new PairingWindow(TimeProvider.System);
    var current = pairing.Create();
    Assert.False(pairing.IsCurrent("invalid-old-code")); Assert.True(pairing.IsCurrent(current.Code));
    Assert.False(pairing.Cancel("invalid-old-code")); Assert.True(pairing.IsOpen);
    Assert.True(pairing.Cancel(current.Code)); Assert.False(pairing.IsOpen); Assert.False(pairing.IsCurrent(current.Code));
  }
  [Fact]
  public void DenyingAStalePendingRequestCannotRevokeAnApprovedDevice()
  {
    var trust = new DeviceTrust(new TestTrustStore()); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(receipt.DeviceId, PhoneAccess.Look);
    Assert.False(trust.DenyPending(receipt.DeviceId));
    Assert.Equal(PhoneAccess.Look, trust.Authenticate(receipt.Credential, phone.PublicKey).Access);
  }
  [Fact]
  public void FailedPendingDenialRetainsRequestAndNeverApprovesIt()
  {
    var store = new TestTrustStore(); var trust = new DeviceTrust(store); using var phone = NoiseIdentity.Generate();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    store.FailSave = true; Assert.Throws<IOException>(() => trust.DenyPending(receipt.DeviceId));
    Assert.Single(trust.Pending()); Assert.Empty(trust.List());
    store.FailSave = false; Assert.True(trust.DenyPending(receipt.DeviceId)); Assert.Empty(trust.Pending());
  }
}
