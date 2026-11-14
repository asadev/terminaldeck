using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// W3: the real feed on Windows against a fake service that applies the service's own checks (CloudFakeService):
// the transport, the crash-safe store, and the engine's judged pull (unknown signer held, trusted applies, bad
// signature refused, feed never stops, held released in order, restart mid-release resumes, back-off rules).
public sealed class CloudSyncW3Tests
{
  private const string DeviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", DeviceB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", DeviceC = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string Subject = CloudFakeService.Subject;

  private sealed class Peer
  {
    public required CloudTestDevice Device;
    public required CloudFeedClient Client;
    public required CloudSyncStore Store;
    public required CloudSyncEngine Engine;
    public required CloudTestAdapter Adapter;
    public required CloudTestTrust Trust;
    public required CloudMemorySlot State, Ledger;
    public readonly List<string> Lines = [];
  }
  private static Peer Make(CloudFakeService service, string id, CloudTestDevice? device = null, CloudMemorySlot? state = null, CloudMemorySlot? ledger = null,
    CloudTestTrust? trust = null, CloudTestAdapter? adapter = null, long skew = 0, IEnumerable<ICloudSyncAdapter>? extra = null)
  {
    device ??= new CloudTestDevice(id, service);
    state ??= new CloudMemorySlot(); ledger ??= new CloudMemorySlot(); trust ??= new CloudTestTrust();
    trust.Trusted.TryAdd(id, device.Jwk);
    adapter ??= new CloudTestAdapter(id);
    var store = new CloudSyncStore(state, ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now + skew,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var lines = new List<string>();
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [adapter, .. extra ?? []], lines.Add, () => service.Now);
    var peer = new Peer { Device = device, Client = client, Store = store, Engine = engine, Adapter = adapter, Trust = trust, State = state, Ledger = ledger };
    peer.Lines.AddRange(lines);
    return peer;
  }
  private static async Task Send(Peer peer, params string[] texts)
  {
    foreach (var text in texts) peer.Adapter.Add(text);
    await peer.Engine.CaptureAsync(default);
    await peer.Engine.FlushAsync(default);
  }

  // ---- Transport ----

  [Fact]
  public async Task Requests_carry_the_device_proof_the_service_checks_and_a_commit_round_trips()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    await Send(a, "one", "two");
    Assert.Equal(1, service.Segments);
    var page = await a.Client.ChangesAsync(0, 128, default);
    var entry = Assert.Single(page.Segments);
    Assert.Equal(DeviceA, entry.DeviceId);
    Assert.Equal(CloudSignatureCheck.Valid, entry.Descriptor!.Check(a.Device.Jwk, Subject));
    Assert.Equal(1UL, page.HeadSeq);
    Assert.Equal(CloudSyncPhase.Receiving, a.Engine.State().Phase);
    // Its own pack is read from the feed like any other (judged under its own stored key), never downloaded again.
    var downloads = service.Log.Count(l => l.Contains("/transfers/"));
    await a.Engine.PullAsync(default);
    Assert.Equal(downloads, service.Log.Count(l => l.Contains("/transfers/")));
    Assert.Empty(a.Adapter.Applied);
    Assert.Equal(CloudSyncPhase.Level, a.Engine.State().Phase);
  }

  [Fact]
  public async Task A_lost_commit_answer_is_retried_with_the_same_request_and_gets_the_same_receipt()
  {
    var service = new CloudFakeService { LoseNextCommitAnswer = true };
    var a = Make(service, DeviceA);
    a.Adapter.Add("one");
    await a.Engine.CaptureAsync(default);
    await Assert.ThrowsAsync<CloudFailure>(() => a.Engine.FlushAsync(default));
    Assert.Equal(1, a.Client.Backoff.Failures);
    await a.Engine.FlushAsync(default);
    Assert.Equal(1, service.Segments);
    Assert.Equal(0, a.Store.QueuedCount);
    Assert.Equal(0, a.Client.Backoff.Failures);
  }

  [Fact]
  public async Task A_wrong_clock_is_corrected_from_the_services_answer_and_kept()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA, skew: -300_000);
    var page = await a.Client.ChangesAsync(0, 1, default);
    Assert.Equal(0UL, page.HeadSeq);
    Assert.NotNull(a.Client.ServiceOffset);
    Assert.InRange(a.Client.ServiceNow() - service.Now, -1000, 1000);
    var before = service.Requests;
    await a.Client.ChangesAsync(0, 1, default);
    Assert.Equal(before + 1, service.Requests);
  }

  [Fact]
  public async Task Refusals_are_typed_and_only_the_right_ones_pace_the_account()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    service.Tokens[DeviceA] = "other";
    var refused = await Assert.ThrowsAsync<CloudFailure>(() => a.Client.ChangesAsync(0, 1, default));
    Assert.Equal(CloudRefusalKind.Account, CloudRefusal.Classify(refused));
    Assert.Equal("auth", a.Client.Backoff.Blocked);
    Assert.False(a.Client.Backoff.MaySend);
    a.Client.Backoff.Resume(signedIn: true);
    Assert.True(a.Client.Backoff.MaySend);
    Assert.Equal(CloudRefusalKind.PackOnly, CloudRefusal.Classify(new CloudFailure("checksum_mismatch", 422), packScoped: true));
    Assert.Equal(CloudRefusalKind.SecretsLocked, CloudRefusal.Classify(new CloudFailure("secrets_locked", 403)));
    Assert.Equal(CloudRefusalKind.Budget, CloudRefusal.Classify(new CloudFailure("budget_paused", 429)));
    Assert.Equal(CloudRefusalKind.Transient, CloudRefusal.Classify(new HttpRequestException()));
    Assert.Equal(CloudRefusalKind.Cancelled, CloudRefusal.Classify(new OperationCanceledException()));
  }

  [Fact]
  public async Task Back_off_counts_failures_ignores_own_cancellation_and_is_cleared_by_a_success()
  {
    var service = new CloudFakeService { FailNext = 2 };
    var a = Make(service, DeviceA);
    await Assert.ThrowsAsync<CloudFailure>(() => a.Client.ChangesAsync(0, 1, default));
    Assert.Equal(1, a.Client.Backoff.Failures);
    Assert.Equal(service.Now + 1000, a.Client.Backoff.RetryAt);
    await Assert.ThrowsAsync<CloudFailure>(() => a.Client.ChangesAsync(0, 1, default));
    Assert.Equal(2, a.Client.Backoff.Failures);
    Assert.Equal(service.Now + 2000, a.Client.Backoff.RetryAt);
    using var cancelled = new CancellationTokenSource();
    await cancelled.CancelAsync();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => a.Client.ChangesAsync(0, 1, cancelled.Token));
    Assert.Equal(2, a.Client.Backoff.Failures);
    a.Client.Backoff.Failed(new OperationCanceledException());
    Assert.Equal(2, a.Client.Backoff.Failures);
    await a.Client.ChangesAsync(0, 1, default);
    Assert.Equal(0, a.Client.Backoff.Failures);
    Assert.Equal(0, a.Client.Backoff.RetryAt);
  }

  [Fact]
  public async Task Five_failures_wait_for_the_network_and_an_engine_round_writes_one_plain_line()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    var lines = new List<string>();
    var engine = new CloudSyncEngine(Subject, DeviceA, a.Client, a.Store, a.Trust, a.Device.Sign, [a.Adapter], lines.Add, () => service.Now);
    a.Adapter.Add("one");
    service.FailNext = 1;
    var state = await engine.SyncAsync(default);
    Assert.Equal(["cloud sync: send failed: network"], lines);
    Assert.Equal(CloudSyncPhase.Waiting, state.Phase);
    for (var i = 0; i < 4; i++) a.Client.Backoff.Failed(new CloudFailure("unavailable", 503, true));
    Assert.Equal("network", a.Client.Backoff.Blocked);
    service.Now += 120_000;
    a.Client.Backoff.Resume(networkOrWake: true);
    state = await engine.SyncAsync(default);
    Assert.Equal(CloudSyncPhase.Level, state.Phase);
    Assert.Equal("Level with your Cloud", state.Line);
  }

  [Fact]
  public async Task An_expired_pack_link_is_renewed_once_and_the_pack_still_applies()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    var b = Make(service, DeviceB);
    b.Trust.Trusted[DeviceA] = a.Device.Jwk;
    await Send(a, "one");
    service.ExpiredLinks.Add(1);
    await b.Engine.PullAsync(default);
    Assert.Equal(["one"], b.Adapter.Applied.Select(x => x.Text));
    Assert.Empty(service.ExpiredLinks);
  }

  // ---- Store ----

  [Fact]
  public void The_store_survives_a_failed_write_and_a_reload_from_disk()
  {
    var folder = Path.Combine(Path.GetTempPath(), "td-w3-" + Guid.NewGuid().ToString("N"));
    try
    {
      var store = CloudSyncStore.InFolder(folder, Subject);
      var op = CloudOperation.Create(DeviceA, "brain/test", "e", [], "put", new("t", "1"), 1, CloudJson.Obj(("text", CloudJson.From("x"))));
      Assert.Equal(1, store.Enqueue([op]));
      Assert.Equal(0, store.Enqueue([op]));
      store.SetLong("reportedSeq", 7);
      var again = CloudSyncStore.InFolder(folder, Subject);
      Assert.Equal(1, again.QueuedCount);
      Assert.True(again.IsApplied(op.OpId));
      Assert.Equal(7, again.GetLong("reportedSeq"));
      Assert.Empty(Directory.GetFiles(Path.Combine(folder, "sync"), "*.tmp"));
      Assert.Throws<CloudFailure>(() => CloudSyncStore.InFolder(folder, "another-account"));

      var slot = new CloudMemorySlot();
      var memory = new CloudSyncStore(slot, new CloudMemorySlot(), Subject);
      memory.Enqueue([op]);
      slot.FailWrites = true;
      Assert.Throws<IOException>(() => memory.MarkApplied(["5d7b1c2e-8f4a-4b1e-9c3d-2a6f8e9b0c1d"]));
      Assert.False(memory.IsApplied("5d7b1c2e-8f4a-4b1e-9c3d-2a6f8e9b0c1d"));
      Assert.Equal(1, memory.QueuedCount);
    }
    finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
  }

  [Fact]
  public async Task A_crash_between_applying_and_recording_never_applies_twice()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    await Send(a, "one", "two");
    var state = new CloudMemorySlot(); var ledger = new CloudMemorySlot(); var trust = new CloudTestTrust();
    var bDevice = new CloudTestDevice(DeviceB, service);
    trust.Trusted[DeviceA] = a.Device.Jwk;
    var adapter = new CloudTestAdapter(DeviceB) { CrashOn = op => ((CloudJson.Object)op.Payload)["text"]!.AsString == "two" };
    var b = Make(service, DeviceB, bDevice, state, ledger, trust, adapter);
    await Assert.ThrowsAsync<InvalidOperationException>(() => b.Engine.PullAsync(default));
    Assert.Equal(["one"], adapter.Applied.Select(x => x.Text));
    Assert.Equal(0UL, b.Engine.Ledger.Cursor);
    adapter.CrashOn = null;
    var restarted = Make(service, DeviceB, bDevice, state, ledger, trust, adapter);
    await restarted.Engine.PullAsync(default);
    Assert.Equal(["one", "two"], adapter.Applied.Select(x => x.Text));
    Assert.Equal(1UL, restarted.Engine.Ledger.Cursor);
    Assert.Equal((DeviceB, 1UL), service.LastApplied);
  }

  // ---- Engine: the judged pull ----

  [Fact]
  public async Task Unknown_signer_is_held_trusted_applies_bad_signature_is_refused_and_the_feed_goes_on()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    var c = Make(service, DeviceC);
    var b = Make(service, DeviceB);
    b.Trust.Trusted[DeviceA] = a.Device.Jwk;
    await Send(a, "a1");
    await Send(c, "c1");
    await Send(a, "a2");
    await Send(a, "a3-forged");
    // The listing at 4 names A but carries a signature A never made.
    service.Tamper[4] = entry => CloudJson.Obj(entry.Members.Select(m => (m.Key, (CloudJson?)(m.Key == "signature" ? CloudJson.From(CloudBytes.Base64Url(new byte[64])) : m.Value))).ToArray());
    await Send(a, "a4");
    await b.Engine.PullAsync(default);
    Assert.Equal(["a1", "a2", "a4"], b.Adapter.Applied.Select(x => x.Text));
    Assert.Equal(5UL, b.Engine.Ledger.Cursor);
    var held = Assert.Single(b.Engine.Ledger.Held);
    Assert.Equal((DeviceC, 2UL, 1), (held.DeviceId, held.FirstSeq!.Value, held.Packs));
    var refused = Assert.Single(b.Engine.Ledger.Refused);
    Assert.Equal((4UL, CloudPackVerdict.BadSignature), (refused.Seq, refused.Reason));
    var state = b.Engine.State();
    Assert.Equal(CloudSyncPhase.Waiting, state.Phase);
    Assert.Equal(1, state.HeldPacks);
    Assert.Equal(1, state.RefusedPacks);
  }

  [Fact]
  public async Task Held_packs_are_released_in_their_original_order_after_trust_and_a_restart_mid_release_resumes()
  {
    var service = new CloudFakeService();
    var a = Make(service, DeviceA);
    var c = Make(service, DeviceC);
    await Send(c, "c1"); await Send(a, "a1"); await Send(c, "c2"); await Send(c, "c3");
    var state = new CloudMemorySlot(); var ledger = new CloudMemorySlot(); var trust = new CloudTestTrust();
    var bDevice = new CloudTestDevice(DeviceB, service);
    trust.Trusted[DeviceA] = a.Device.Jwk;
    var adapter = new CloudTestAdapter(DeviceB);
    var b = Make(service, DeviceB, bDevice, state, ledger, trust, adapter);
    await b.Engine.PullAsync(default);
    Assert.Equal(["a1"], adapter.Applied.Select(x => x.Text));
    Assert.Equal(3, b.Engine.Ledger.HeldRow(DeviceC)!.Packs);

    // The person trusts C; the app stops while the release applies c2.
    trust.Trusted[DeviceC] = c.Device.Jwk;
    adapter.CrashOn = op => ((CloudJson.Object)op.Payload)["text"]!.AsString == "c2";
    await b.Engine.ReleaseHeldAsync([DeviceC], default);
    Assert.Equal(["a1", "c1"], adapter.Applied.Select(x => x.Text));
    Assert.True(b.Engine.Ledger.HeldRow(DeviceC)!.Releasing);

    adapter.CrashOn = null;
    var restarted = Make(service, DeviceB, bDevice, state, ledger, trust, adapter);
    await restarted.Engine.PullAsync(default);
    Assert.Equal(["a1", "c1", "c2", "c3"], adapter.Applied.Select(x => x.Text));
    Assert.True(adapter.Applied.Where(x => x.Text.StartsWith('c')).All(x => x.Origin.Late && x.Origin.DeviceId == DeviceC));
    Assert.Equal([1UL, 3UL, 4UL], adapter.Applied.Where(x => x.Text.StartsWith('c')).Select(x => x.Origin.Seq));
    Assert.Null(restarted.Engine.Ledger.HeldRow(DeviceC));
    Assert.Equal(CloudSyncPhase.Level, restarted.Engine.State().Phase);
  }

  [Fact]
  public async Task A_first_upload_in_slot_one_is_passed_over_never_imported()
  {
    var service = new CloudFakeService { FirstSeq = 2, Checkpoint = "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f" };
    var a = Make(service, DeviceA);
    var b = Make(service, DeviceB);
    b.Trust.Trusted[DeviceA] = a.Device.Jwk;
    await Send(a, "after-first-upload");
    await b.Engine.PullAsync(default);
    Assert.Equal(["after-first-upload"], b.Adapter.Applied.Select(x => x.Text));
    Assert.Equal(2UL, b.Engine.Ledger.Cursor);
    Assert.Equal(CloudSyncEngine.FirstUploadPassedOver, Assert.Single(b.Engine.Ledger.Refused).Reason);
    Assert.Equal(0, b.Engine.State().RefusedPacks);
  }

  [Fact]
  public async Task A_pack_of_a_kind_this_PC_does_not_take_waits_and_applies_late_once_taken()
  {
    var service = new CloudFakeService();
    var other = new CloudTestAdapter(DeviceA, "brain/other");
    var a = Make(service, DeviceA, extra: [other]);
    other.Add("x1");
    await Send(a, "t1");
    var state = new CloudMemorySlot(); var ledger = new CloudMemorySlot(); var trust = new CloudTestTrust();
    var bDevice = new CloudTestDevice(DeviceB, service);
    trust.Trusted[DeviceA] = a.Device.Jwk;
    var b = Make(service, DeviceB, bDevice, state, ledger, trust);
    await b.Engine.PullAsync(default);
    Assert.Equal(["t1"], b.Adapter.Applied.Select(x => x.Text));
    Assert.Single(b.Store.KindWaiting);
    Assert.Equal(2UL, b.Engine.Ledger.Cursor);

    var taken = new CloudTestAdapter(DeviceB, "brain/other");
    var later = Make(service, DeviceB, bDevice, state, ledger, trust, extra: [taken]);
    await later.Engine.PullAsync(default);
    var applied = Assert.Single(taken.Applied);
    Assert.True(applied.Origin.Late);
    Assert.Empty(later.Store.KindWaiting);
  }

  [Fact]
  public async Task Three_refused_packs_in_a_row_stop_sending_for_a_timed_wait_and_keep_the_records()
  {
    var service = new CloudFakeService { RefuseCommitsWith = "unsupported_format" };
    var a = Make(service, DeviceA);
    a.Adapter.Add("one"); a.Adapter.Add("two");
    await a.Engine.CaptureAsync(default);
    await Assert.ThrowsAsync<CloudFailure>(() => a.Engine.FlushAsync(default));
    Assert.Equal(2, a.Store.QueuedCount + a.Store.Parked.Count);
    Assert.True(a.Store.GetLong("sendStoppedUntil") > service.Now);
    Assert.Equal(CloudSyncPhase.Waiting, a.Engine.State().Phase);
    Assert.Null(a.Client.Backoff.Blocked);
  }
}
