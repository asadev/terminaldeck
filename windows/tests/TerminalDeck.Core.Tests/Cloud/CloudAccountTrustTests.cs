using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// "How this PC trusts your other devices" (owner, 13 Nov): automatically with the account (default) or ask for each.
public sealed class CloudAccountTrustTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-trust-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private sealed class MemorySlot : ICloudTrustSlot
  {
    public byte[]? Bytes; public bool Broken;
    public byte[]? Read() => Broken ? throw new IOException("unreadable") : Bytes?.ToArray();
    public void Write(byte[] bytes) { if (Broken) throw new IOException("unreadable"); Bytes = bytes.ToArray(); }
  }
  private sealed record Setup(CloudAccountClient Account, CloudServiceFake Http, MemorySlot List, MemorySlot Mode, List<string> Log, Func<CloudTrustStore> Store);
  private bool refuse;
  private Setup Make(string? mode = null)
  {
    var http = new CloudServiceFake();
    http.Others.Add((CloudDeviceKeys.Fresh().Registration("Home laptop", "0.22.0", "windows"), "active", 1_762_500_000_000L));
    http.Others.Add((CloudDeviceKeys.Fresh().Registration("Old tablet", "0.21.0", "macos"), "revoked", 1_760_000_000_000L));
    var list = new MemorySlot(); var modeSlot = new MemorySlot { Bytes = mode is null ? null : Encoding.UTF8.GetBytes(mode) };
    var log = new List<string>();
    var ports = new CloudTrustPorts((_, _) => list, modeSlot, () => refuse);
    var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"),
      new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new XorProtector()), http, new CountingRandom(), new FakeBrowser(), trust: ports) { StageLog = log.Add };
    return new(account, http, list, modeSlot, log, () => new CloudTrustStore(CloudWire.Issuer, CloudServiceFake.UserId, list, () => false));
  }

  [Fact] public async Task AutomaticTrustAddsExactlyTheListedActiveDevices()
  {
    var c = Make();
    await CloudJoinTests.SignInAsync(c.Account);
    var stored = c.Store().List().Devices;
    var active = c.Http.Others.Where(o => o.Status == "active").Select(o => o.Device).ToArray();
    Assert.Equal(3, stored.Count);
    Assert.Equal("self", stored.Single(d => d.DeviceId == c.Http.Registered!.DeviceId).How);
    foreach (var device in active)
    {
      var entry = stored.Single(d => d.DeviceId == device.DeviceId);
      Assert.Equal(("trusted", "account"), (entry.Trust, entry.How));
      Assert.Equal(device.SignPublicJwk, entry.SignKey);
    }
    Assert.DoesNotContain(stored, d => d.DeviceId == c.Http.Others[2].Device.DeviceId);
    Assert.Equal("account", Encoding.UTF8.GetString(c.Mode.Bytes!));
    Assert.Equal(CloudTrustMode.Account, c.Account.Snapshot.TrustMode);
    Assert.Contains("cloud sign-in: device trust ok: 2 added", c.Log);
    var page = CloudPageText.For(c.Account.Snapshot);
    Assert.Equal(CloudTrustMode.Account, page.TrustMode);
    Assert.Equal(["“Asad's Mac mini” joined your account and is now trusted on this PC.", "“Home laptop” joined your account and is now trusted on this PC."],
      page.Notices!.Select(n => n.Text).Order(StringComparer.Ordinal).ToArray());
    Assert.All(page.Notices!, n => Assert.Equal(("Remove", CloudNoticeAction.Remove), (n.Button, n.Action)));
    Assert.DoesNotContain(page.Devices, d => d.CanTrust);
    // A second check adds nothing more.
    await c.Account.RefreshAsync();
    Assert.Equal(3, c.Store().List().Devices.Count);
  }

  [Fact] public async Task AChangedKeyIsHeldUntilTrustItAgain()
  {
    var c = Make();
    await CloudJoinTests.SignInAsync(c.Account);
    var (laptop, status, added) = c.Http.Others[1];
    var oldKey = laptop.SignPublicJwk;
    var newKey = CloudDeviceKeys.Fresh().Registration("x", "1").SignPublicJwk;
    c.Http.Others[1] = (laptop with { SignPublicJwk = newKey }, status, added);
    await c.Account.RefreshAsync();
    Assert.Equal(oldKey, c.Store().TrustedSigningKey(laptop.DeviceId));
    var notice = Assert.Single(CloudPageText.For(c.Account.Snapshot).Notices!, n => n.Action == CloudNoticeAction.TrustAgain);
    Assert.Equal("Trust it again", notice.Button);
    Assert.Equal("“Home laptop” now signs its changes differently than when it joined. Its changes wait on this PC until you trust it again.", notice.Text);
    // A press refused as remote input changes nothing.
    refuse = true;
    await Assert.ThrowsAsync<CloudTrustRefusal>(() => c.Account.TrustAgainAsync(laptop.DeviceId));
    Assert.Equal(oldKey, c.Store().TrustedSigningKey(laptop.DeviceId));
    refuse = false;
    await c.Account.TrustAgainAsync(laptop.DeviceId);
    Assert.Equal(newKey, c.Store().TrustedSigningKey(laptop.DeviceId));
    Assert.Equal("click", c.Store().Entry(laptop.DeviceId)!.How);
    Assert.DoesNotContain(CloudPageText.For(c.Account.Snapshot).Notices!, n => n.Action == CloudNoticeAction.TrustAgain);
  }

  [Fact] public async Task RemoveStopsTrustAndTheDeviceIsNeverAddedAgain()
  {
    var c = Make();
    await CloudJoinTests.SignInAsync(c.Account);
    var laptop = c.Http.Others[1].Device.DeviceId;
    await c.Account.RemoveJoinedDeviceAsync(laptop);
    await c.Account.RefreshAsync();
    Assert.Null(c.Store().TrustedSigningKey(laptop));
    Assert.Equal(("stopped", "removed"), (c.Store().Entry(laptop)!.Trust, c.Store().Entry(laptop)!.StopReason));
    Assert.DoesNotContain(CloudPageText.For(c.Account.Snapshot).Notices!, n => n.DeviceId == laptop);
    // This PC itself can never be removed this way.
    await Assert.ThrowsAsync<CloudFailure>(() => c.Account.RemoveJoinedDeviceAsync(c.Http.Registered!.DeviceId));
  }

  [Fact] public async Task ADeviceTheAccountRemovedLeavesTheList()
  {
    var c = Make();
    await CloudJoinTests.SignInAsync(c.Account);
    var (laptop, _, added) = c.Http.Others[1];
    c.Http.Others[1] = (laptop, "revoked", added);
    await c.Account.RefreshAsync();
    Assert.Null(c.Store().TrustedSigningKey(laptop.DeviceId));
    Assert.Equal("left account", c.Store().Entry(laptop.DeviceId)!.StopReason);
    Assert.NotNull(c.Store().TrustedSigningKey(c.Http.Others[0].Device.DeviceId));
  }

  [Fact] public async Task AskModeBehavesAsBefore()
  {
    var c = Make(mode: "ask");
    await CloudJoinTests.SignInAsync(c.Account);
    Assert.Equal([c.Http.Registered!.DeviceId], c.Store().List().Devices.Select(d => d.DeviceId));
    Assert.DoesNotContain(c.Log, l => l.Contains("device trust ok:", StringComparison.Ordinal));
    var page = CloudPageText.For(c.Account.Snapshot);
    Assert.Equal(CloudTrustMode.Ask, page.TrustMode); Assert.Empty(page.Notices!);
    var mac = c.Http.Others[0].Device;
    Assert.True(page.Devices.Single(d => d.DeviceId == mac.DeviceId).CanTrust);
    Assert.False(page.Devices.Single(d => d.DeviceId == c.Http.Others[2].Device.DeviceId).CanTrust);
    // The compare dialog shows the code of exactly the key a press stores.
    var captured = c.Account.CaptureForDialog(mac.DeviceId)!;
    Assert.Equal(CloudDeviceCode.Code(mac.DeviceId, mac.SignPublicJwk), captured.Code);
    Assert.Equal(CloudDeviceCode.Code(c.Http.Registered.DeviceId, c.Http.Registered.SignPublicJwk), c.Account.ThisPcCode);
    refuse = true;
    var refusal = await Assert.ThrowsAsync<CloudTrustRefusal>(() => c.Account.TrustNewDeviceAsync(captured));
    Assert.Equal(CloudTrustRefusalKind.RemoteInput, refusal.Kind);
    Assert.Null(c.Store().Entry(mac.DeviceId));
    refuse = false;
    await c.Account.TrustNewDeviceAsync(captured);
    Assert.Equal(("trusted", "click"), (c.Store().Entry(mac.DeviceId)!.Trust, c.Store().Entry(mac.DeviceId)!.How));
    Assert.Null(c.Store().Entry(c.Http.Others[1].Device.DeviceId));
  }

  [Fact] public async Task TheChoiceIsStoredInItsProtectedSlotAndAnUnreadableSlotIsAsk()
  {
    var c = Make();
    await CloudJoinTests.SignInAsync(c.Account);
    refuse = true;
    await Assert.ThrowsAsync<CloudTrustRefusal>(() => c.Account.SetTrustModeAsync(CloudTrustMode.Ask));
    Assert.Equal("account", Encoding.UTF8.GetString(c.Mode.Bytes!));
    refuse = false;
    await c.Account.SetTrustModeAsync(CloudTrustMode.Ask);
    Assert.Equal("ask", Encoding.UTF8.GetString(c.Mode.Bytes!));
    Assert.Equal(CloudTrustMode.Ask, c.Account.Snapshot.TrustMode);
    Assert.Equal(CloudTrustMode.Ask, new CloudTrustModeStore(new MemorySlot { Broken = true }).Load());
    Assert.Equal(CloudTrustMode.Ask, CloudTrustModeStore.From("something else"));
    Assert.Equal(CloudTrustMode.Account, new CloudTrustModeStore(new MemorySlot()).Load());
    Assert.False(File.Exists(Path.Combine(folder, "cloud", "trust-mode")));
  }
}
