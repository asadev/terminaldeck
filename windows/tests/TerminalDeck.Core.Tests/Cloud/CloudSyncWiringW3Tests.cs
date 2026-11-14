using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// W3 wiring and the two hand-back fixes: device proofs sign PUT (file uploads); saved-password entries of the feed are
// passed over without a refused record; the bridge builds nothing while signed out or with Cloud off, stays idle and
// silent with no record kind, syncs when one is registered, and trusting a device releases what waited from it.
public sealed class CloudSyncWiringW3Tests
{
  private const string Subject = CloudFakeService.Subject;
  private const string DeviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", DeviceB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e";

  [Fact]
  public void Device_proof_signs_put_for_uploads_and_still_refuses_other_methods()
  {
    var keys = CloudDeviceKeys.Fresh();
    var body = Encoding.UTF8.GetBytes("sealed bytes");
    var proof = keys.Proof("PUT", "/v1/transfers/abc?t=1", body, 1_763_000_000_000, "f1c1c3c4-0000-4000-8000-000000000001");
    var jwk = keys.Registration("PC", "0").SignPublicJwk;
    using var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new() { X = CloudWire.FromBase64Url(jwk.X)!, Y = CloudWire.FromBase64Url(jwk.Y)! } });
    var message = Encoding.UTF8.GetBytes("TD-CLOUD-1\nPUT\n/v1/transfers/abc?t=1\n1763000000000\nf1c1c3c4-0000-4000-8000-000000000001\n" + CloudWire.Sha256Hex(body));
    Assert.True(key.VerifyData(message, CloudWire.FromBase64Url(proof["X-TD-Signature"])!, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    Assert.Throws<CloudFailure>(() => keys.Proof("DELETE", "/v1/devices", [], 1, "x"));
    Assert.Throws<CloudFailure>(() => keys.Proof("PUT", "/elsewhere", [], 1, "x"));
    // The pack signature the engine uses is the same key over the given bytes.
    Assert.True(key.VerifyData(body, keys.Sign(body), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
  }

  private sealed class ListFeed(List<CloudFeedEntry> entries) : ICloudFeed
  {
    public Task<IReadOnlyList<CloudFeedEntry>> ChangesAsync(ulong after, int limit, CancellationToken ct) =>
      Task.FromResult<IReadOnlyList<CloudFeedEntry>>(entries.Where(e => e.Seq > after).OrderBy(e => e.Seq).Take(limit).ToArray());
  }
  private sealed class NoSink : ICloudPackSink
  {
    public Task ApplyAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct) => Task.CompletedTask;
  }

  [Fact]
  public async Task Saved_password_entries_are_passed_over_without_a_refused_record()
  {
    var entries = new List<CloudFeedEntry>
    {
      new(1, "secrets", DeviceB, null, Locked: true),
      new(2, "secrets", DeviceA, null),
      new(3, "brain", DeviceB, null),
      new(4, "elsewhere", DeviceB, null)
    };
    var slot = new CloudMemorySlot();
    var feed = new CloudJudgedFeed(Subject, "brain", new ListFeed(entries), new NoSink(), new CloudTestTrust(), new CloudFeedLedger(slot));
    await feed.PullAsync(default);
    Assert.Equal(4UL, feed.Ledger.Cursor);
    // Only the unknown class is refused; the saved-password positions leave no row at all.
    var refused = Assert.Single(feed.Ledger.Refused);
    Assert.Equal((4UL, CloudPackVerdict.Malformed), (refused.Seq, refused.Reason));
    Assert.Equal(DeviceB, Assert.Single(feed.Ledger.Held).DeviceId);
    // The position is saved: a restart resumes after the last entry.
    Assert.Equal(4UL, new CloudFeedLedger(slot).Cursor);
  }

  // ---- The bridge ----

  private sealed class FakeAccount(CloudTestDevice device, CloudTestTrust trust) : ICloudSyncAccount
  {
    public CloudSnapshot Snapshot { get; private set; } = CloudSnapshot.Dormant;
    public event Action<CloudSnapshot>? Changed;
    public bool On;
    public int Refreshes;
    public (string Subject, string DeviceId)? SyncIdentity => On ? (Subject, device.DeviceId) : null;
    public byte[] SignPack(byte[] bytes) => device.Sign(bytes);
    public ICloudDeviceTrust SyncTrust => trust;
    public Task RefreshAsync(CancellationToken ct = default) { Refreshes++; return Task.CompletedTask; }
    public Task<CloudSyncCredentials> CredentialsAsync(CancellationToken ct) => device.CredentialsAsync(ct);
    public IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId) =>
      device.Proof(method, pathAndQuery, body, timeMs, requestId);
    public void Set(CloudPhase phase, bool on, params CloudDeviceRow[] rows)
    {
      On = on; Snapshot = new(phase, "a@example.test", null, device.DeviceId, "PC", rows);
      Changed?.Invoke(Snapshot);
    }
  }
  private sealed class QuietSockets : ICloudSyncSocketFactory
  {
    public int Connects;
    public async Task<ICloudSyncSocket> ConnectAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
      Interlocked.Increment(ref Connects);
      await Task.Delay(Timeout.Infinite, ct);
      throw new OperationCanceledException();
    }
  }
  private sealed class World
  {
    public required CloudFakeService Service;
    public required FakeAccount Account;
    public required CloudTestTrust Trust;
    public required CloudMemorySlot State, Ledger;
    public required QuietSockets Sockets;
    public required CloudSyncBridge Bridge;
    public int StoresMade, HttpMade;
  }
  private static World Make(CloudFakeService service, params ICloudSyncAdapter[] owners)
  {
    var device = new CloudTestDevice(DeviceA, service);
    var trust = new CloudTestTrust(); trust.Trusted[DeviceA] = device.Jwk;
    var account = new FakeAccount(device, trust);
    var state = new CloudMemorySlot(); var ledger = new CloudMemorySlot(); var sockets = new QuietSockets();
    World? world = null;
    var platform = new CloudSyncPlatform(subject => { world!.StoresMade++; return new CloudSyncStore(state, ledger, subject); },
      () => { world!.HttpMade++; return service; }, sockets, new CloudSyncEndpoint(CloudFakeService.Base, test: true), () => owners, () => service.Now);
    var bridge = new CloudSyncBridge(account, platform, null, (_, ct) => Task.Delay(Timeout.Infinite, ct));
    world = new World { Service = service, Account = account, Trust = trust, State = state, Ledger = ledger, Sockets = sockets, Bridge = bridge };
    return world;
  }
  private static CloudDeviceRow Row(string deviceId, CloudTrustStanding standing) =>
    new(deviceId, "Other", false, null, null, new CloudTrustRow(deviceId, "Other", standing, null, null, null, null, false));

  [Fact]
  public void Signed_out_or_with_Cloud_off_the_bridge_builds_and_sends_nothing()
  {
    var w = Make(new CloudFakeService(), new CloudTestAdapter(DeviceA));
    w.Bridge.Start();
    Assert.Null(w.Bridge.Status);
    w.Account.Set(CloudPhase.SignedOut, on: false);
    w.Account.Set(CloudPhase.Paused, on: false);
    w.Account.Set(CloudPhase.NotAllowed, on: false);
    Assert.Null(w.Bridge.Status);
    Assert.Null(w.Bridge.Engine);
    Assert.Equal((0, 0, 0, 0), (w.StoresMade, w.HttpMade, w.Service.Requests, w.Sockets.Connects));
    w.Bridge.Dispose();
  }

  [Fact]
  public async Task With_no_record_kind_the_engine_stays_idle_and_silent_and_says_so()
  {
    var w = Make(new CloudFakeService());
    w.Bridge.Start();
    w.Account.Set(CloudPhase.SignedIn, on: true, Row(DeviceB, CloudTrustStanding.New));
    Assert.NotNull(w.Bridge.Engine);
    Assert.Equal(CloudSyncPhase.Idle, w.Bridge.Status!.Phase);
    Assert.Equal("Nothing on this PC syncs yet: this version only keeps the PC in your account.", CloudPageText.SyncLine(w.Bridge.Status));
    Assert.False(CloudPageText.CanSyncNow(w.Bridge.Status));
    Assert.Equal(CloudSyncPhase.Idle, (await w.Bridge.SyncNowAsync())!.Phase);
    // Trusting a device changes nothing either.
    w.Account.Set(CloudPhase.SignedIn, on: true, Row(DeviceB, CloudTrustStanding.Trusted));
    await Task.Delay(50);
    Assert.Equal((0, 0, 0), (w.HttpMade, w.Service.Requests, w.Sockets.Connects));
    Assert.Null(w.State.Bytes); Assert.Null(w.Ledger.Bytes);
    // Cloud off: the engine is dropped and the line goes.
    w.Account.Set(CloudPhase.Paused, on: false);
    Assert.Null(w.Bridge.Engine);
    Assert.Null(w.Bridge.Status);
    w.Bridge.Dispose();
  }

  [Fact]
  public async Task With_a_record_kind_Sync_now_sends_and_the_line_follows_the_engine()
  {
    var service = new CloudFakeService();
    var adapter = new CloudTestAdapter(DeviceA);
    var w = Make(service, adapter);
    w.Bridge.Start();
    w.Account.Set(CloudPhase.SignedIn, on: true);
    adapter.Add("one");
    var state = await w.Bridge.SyncNowAsync();
    Assert.Equal(CloudSyncPhase.Level, state!.Phase);
    Assert.Equal("Level with your Cloud", CloudPageText.SyncLine(w.Bridge.Status));
    Assert.True(CloudPageText.CanSyncNow(w.Bridge.Status));
    Assert.Equal(1, service.Segments);
    Assert.Equal(1, w.HttpMade);
    w.Account.Set(CloudPhase.SignedOut, on: false);
    Assert.Null(w.Bridge.Status);
    w.Bridge.Dispose();
  }

  [Fact]
  public async Task Trusting_a_device_releases_what_was_held_from_it()
  {
    var service = new CloudFakeService();
    // Device B sends one record before this PC trusts it.
    var bDevice = new CloudTestDevice(DeviceB, service);
    var bTrust = new CloudTestTrust(); bTrust.Trusted[DeviceB] = bDevice.Jwk;
    var bStore = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), Subject);
    var bClient = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, bDevice, service, bStore, () => service.Now);
    var bAdapter = new CloudTestAdapter(DeviceB);
    var b = new CloudSyncEngine(Subject, DeviceB, bClient, bStore, bTrust, bDevice.Sign, [bAdapter], null, () => service.Now);
    bAdapter.Add("from-b");
    await b.CaptureAsync(default); await b.FlushAsync(default);

    var adapter = new CloudTestAdapter(DeviceA);
    var w = Make(service, adapter);
    w.Bridge.Start();
    w.Account.Set(CloudPhase.SignedIn, on: true, Row(DeviceB, CloudTrustStanding.New));
    var waiting = await w.Bridge.SyncNowAsync();
    Assert.Equal(CloudSyncPhase.Waiting, waiting!.Phase);
    Assert.StartsWith("Waiting: 1 changes from devices this PC does not trust yet", waiting.Line);
    Assert.Empty(adapter.Applied);

    w.Trust.Trusted[DeviceB] = bDevice.Jwk;
    w.Account.Set(CloudPhase.SignedIn, on: true, Row(DeviceB, CloudTrustStanding.Trusted));
    for (var i = 0; i < 200 && adapter.Applied.Count == 0; i++) await Task.Delay(25);
    var applied = Assert.Single(adapter.Applied);
    Assert.Equal(("from-b", DeviceB, true), (applied.Text, applied.Origin.DeviceId, applied.Origin.Late));
    Assert.Empty(w.Bridge.Engine!.Ledger.Held);
    w.Bridge.Dispose();
  }
}
