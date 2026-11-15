using System.Globalization;
using System.Security.Cryptography;

namespace TerminalDeck.Core.Cloud;

// W3 engine (the Mac's CloudSyncEngine.swift, memory class only): capture → outbox → sealed, signed pack → push; pull →
// judged by THIS PC's trusted list (slice 2, CloudJudgedFeed) → apply, hold or refuse → recorded. No first upload: a
// device's baseline is its ordinary records in ordinary signed packs. Saved passwords (the secrets class) keep their
// own position and are not handled here; their feed positions are passed over by memory.

/// Where an incoming record came from. `DeviceId` is the verified signer, never the pack's own origin field.
public sealed record CloudImportOrigin(string DeviceId, ulong Seq, long? CommittedAt, bool Late);

/// One record kind's owner (Deck Memory here; projects and agents in W4). Every call is the owner's own narrow path.
public interface ICloudSyncAdapter
{
  /// The kinds (domains) this owner takes, e.g. `brain/memory/i05`.
  IReadOnlyCollection<string> Domains { get; }
  /// This PC's own new records since the last committed capture, in order. Ids are derived from content, so a capture
  /// repeated after a crash makes the same ids. `stampNow` is the service-corrected clock (ms).
  Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct);
  /// Applies one incoming record. Must be a no-op for a record it already holds (same op id): a crash between apply and
  /// the engine's record applies it again.
  Task ApplyAsync(CloudOperation operation, CloudImportOrigin origin, CancellationToken ct);
  /// Called once a pack's records were applied and before the engine records them as applied: the owner makes what it
  /// wrote durable here (once per pack, not once per record). A crash before it applies the pack again.
  Task SettleAsync(CancellationToken ct) => Task.CompletedTask;
  /// The engine read the whole feed (a pull ended without a failure). An owner that holds its first copy back until it
  /// has taken in what the devices it trusts already saved (the Mac's rule, hand-back 4) answers true the first time;
  /// the engine then captures and sends again in the same round.
  bool FeedRead() => false;
}
/// A capture: its records, and `Commit` that the engine calls once they are durably queued.
public sealed record CloudCapture(IReadOnlyList<CloudOperation> Operations, Action Commit)
{
  public static CloudCapture None { get; } = new([], () => { });
}

public enum CloudSyncPhase { Level, Sending, Receiving, Waiting, Idle }
/// What the Cloud page shows: "Level with your Cloud", "Sending n", "Receiving n", "Waiting: reason"; Idle when no record
/// kind on this PC syncs (no owner registered): nothing is sent or asked.
public sealed record CloudSyncState(CloudSyncPhase Phase, int Sending, int Receiving, string? Waiting, int HeldPacks, int HeldDevices, int RefusedPacks, int KindWaiting, int Parked)
{
  public string Line => Phase switch
  {
    CloudSyncPhase.Level => "Level with your Cloud",
    CloudSyncPhase.Sending => "Sending " + Sending.ToString(CultureInfo.InvariantCulture),
    CloudSyncPhase.Receiving => "Receiving " + Receiving.ToString(CultureInfo.InvariantCulture),
    CloudSyncPhase.Idle => NothingSyncs,
    _ => "Waiting: " + Waiting
  };
  public const string NothingSyncs = "Nothing on this PC syncs yet: this version only keeps the PC in your account.";
  public static CloudSyncState Idle { get; } = new(CloudSyncPhase.Idle, 0, 0, null, 0, 0, 0, 0, 0);
}

public sealed class CloudSyncEngine
{
  public const string FirstUploadPassedOver = "first-upload-passed-over";
  /// Sync-store key prefix of an incoming record its owner refused for good (value: the refusal code).
  public const string RefusedRecordPrefix = "refusedRecord.";
  public const int MaximumPackOps = 256, MaximumPackPlainBytes = 180_000;
  private readonly string subject, deviceId;
  private readonly CloudFeedClient client;
  private readonly CloudSyncStore store;
  private readonly ICloudDeviceTrust trust;
  private readonly Func<byte[], byte[]> sign;
  private readonly Dictionary<string, ICloudSyncAdapter> adapters = new(StringComparer.Ordinal);
  private readonly List<ICloudSyncAdapter> owners = [];
  private readonly Action<string> log;
  private readonly Func<long> now;
  private readonly SemaphoreSlim busy = new(1, 1);
  private readonly Dictionary<int, byte[]> keys = [];
  private readonly Dictionary<ulong, CloudChangeEntry> links = [];
  private ulong knownHead;
  private string? lastFailure;
  public CloudFeedLedger Ledger { get; }
  public CloudJudgedFeed Feed { get; }
  /// False when no record kind is registered here: every round is then a no-op that sends and asks nothing.
  public bool HasKinds => adapters.Count > 0;

  /// `sign`: this device's ES256 signature (raw r||s, 64 bytes) over the given bytes. Windows: CloudDeviceKeys.
  public CloudSyncEngine(string subject, string deviceId, CloudFeedClient client, CloudSyncStore store, ICloudDeviceTrust trust,
    Func<byte[], byte[]> sign, IEnumerable<ICloudSyncAdapter> owners, Action<string>? log = null, Func<long>? now = null)
  {
    CloudBytes.TransportId(deviceId);
    if (store.Subject != subject) throw new CloudFailure("unsafe_configuration");
    this.subject = subject; this.deviceId = deviceId; this.client = client; this.store = store; this.trust = trust; this.sign = sign;
    this.log = log ?? (_ => { }); this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    foreach (var owner in owners)
    {
      this.owners.Add(owner);
      foreach (var domain in owner.Domains) if (!adapters.TryAdd(domain, owner)) throw new CloudFailure("invalid_request");
    }
    Ledger = new CloudFeedLedger(store.LedgerSlot, this.now);
    Feed = new CloudJudgedFeed(subject, "brain", new LinkedFeed(this), new Sink(this), trust, Ledger);
  }

  // ---- One round: capture, send, receive ----

  /// One round, serialised. Each failed step writes ONE plain line (`cloud sync: <what> failed: <kind>`) and the round
  /// goes on with the next step where that is safe.
  public async Task<CloudSyncState> SyncAsync(CancellationToken ct)
  {
    if (!HasKinds) return CloudSyncState.Idle;
    await busy.WaitAsync(ct);
    try
    {
      lastFailure = null;
      if (!client.Backoff.MaySend) return State();
      if (!await StepAsync("capture", () => CaptureAsync(ct), ct)) return State();
      await StepAsync("send", () => FlushAsync(ct), ct);
      if (client.Backoff.MaySend && await StepAsync("fetch", () => PullAsync(ct), ct))
      {
        var ready = false;
        foreach (var owner in owners) ready |= owner.FeedRead();
        if (ready && await StepAsync("capture", () => CaptureAsync(ct), ct)) await StepAsync("send", () => FlushAsync(ct), ct);
      }
      return State();
    }
    finally { busy.Release(); }
  }
  /// The person trusted devices in this PC's window: their waiting packs are released now, in their original order.
  public async Task ReleaseHeldAsync(IReadOnlyCollection<string> deviceIds, CancellationToken ct)
  {
    if (!HasKinds) return;
    await busy.WaitAsync(ct);
    try { await StepAsync("release", () => Feed.ReleaseHeldAsync(deviceIds, ct), ct); }
    finally { busy.Release(); }
  }

  private async Task<bool> StepAsync(string what, Func<Task> step, CancellationToken ct)
  {
    try { await step(); return true; }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
    catch (Exception error)
    {
      var kind = CloudRefusal.Classify(error);
      lastFailure = Reason(kind, error);
      log("cloud sync: " + what + " failed: " + CloudRefusal.Word(kind));
      return false;
    }
  }
  private static string Reason(CloudRefusalKind kind, Exception error) => kind switch
  {
    CloudRefusalKind.Account => "sign in to Cloud again",
    CloudRefusalKind.Budget => "Cloud's daily allowance; it resumes by itself",
    CloudRefusalKind.Gate => "Cloud is not on for this account",
    CloudRefusalKind.ClockSkew => "check this PC's date and time",
    CloudRefusalKind.Transient => "Cloud cannot be reached; retrying",
    _ => error is CloudFailure { Code: "unavailable" } ? "the memory key is not available yet" : "Cloud refused a step; retrying later"
  };

  // ---- Capture ----

  public async Task CaptureAsync(CancellationToken ct)
  {
    foreach (var owner in owners)
    {
      var capture = await owner.CaptureAsync(client.ServiceNow, ct);
      if (capture.Operations.Count > 0)
      {
        if (capture.Operations.Any(o => !owner.Domains.Contains(o.Domain) || o.OriginDevice != deviceId)) throw new CloudFailure("invalid_request");
        store.Enqueue(capture.Operations);
      }
      capture.Commit();
    }
  }

  // ---- Send ----

  /// Seals queued records into packs (one kind per pack, at most 256 records and 180 000 plain bytes), signs and sends
  /// them. A pack is saved before its first send, so a crash resends the same signed bytes. A pack the service refuses
  /// for good is split (each record alone) or, alone, parked; three refusals in a row stop sending for a timed wait.
  public async Task FlushAsync(CancellationToken ct)
  {
    if (store.GetLong("sendStoppedUntil") > now()) return;
    var refusedInARow = store.GetLong("sendStopStreak") > 0 ? 2 : 0;
    while (true)
    {
      ct.ThrowIfCancellationRequested();
      if (store.Unacknowledged() is { } segment)
      {
        CloudCommitReceipt receipt;
        var firstSend = !segment.SentOnce;
        if (firstSend) store.MarkSentOnce(segment.Descriptor.SegmentId);
        var sentAt = now();
        try { receipt = await client.CommitAsync(segment.Descriptor, segment.Ciphertext, ct); }
        catch (CloudFailure refused) when (CloudRefusal.Classify(refused, packScoped: true) == CloudRefusalKind.PackOnly)
        {
          store.RetireSegment(segment.Descriptor.SegmentId);
          if (++refusedInARow >= 3)
          {
            var streak = (int)Math.Min(store.GetLong("sendStopStreak") + 1, 64);
            store.SetLong("sendStopStreak", streak);
            store.SetLong("sendStoppedUntil", now() + Math.Min(21_600_000, 60_000L << Math.Min(streak - 1, 20)));
            throw;
          }
          if (segment.OpIds.Count > 1) store.MarkAlone(segment.OpIds);
          else store.Park(segment.OpIds[0], "The service refused this edit (" + refused.Code + "); it is kept here and retried later.", now());
          continue;
        }
        // The service's commit time teaches its clock, from a pack's FIRST send only (a retried commit returns the
        // first commit's old time).
        if (firstSend && client.ServiceOffset is null) store.SetLong("signingClockOffset", receipt.CommittedAt - (sentAt + Math.Max(0, now() - sentAt) / 2));
        // The service checked the bytes against the signed hash before it answered (feed.ts commit); the feed's own
        // listing at the receipt's position must name this very pack.
        var check = await client.ChangesAsync(receipt.Seq - 1, 1, ct);
        if (check.Segments.FirstOrDefault() is not { } listed || listed.Seq != receipt.Seq || listed.SegmentId != segment.Descriptor.SegmentId
          || listed.Sha256 != segment.Descriptor.Sha256) throw new CloudFailure("checksum_mismatch");
        store.Acknowledge(segment.Descriptor.SegmentId, receipt.Seq);
        refusedInARow = 0;
        store.SetLong("sendStopStreak", null); store.SetLong("sendStoppedUntil", null);
        knownHead = Math.Max(knownHead, receipt.HeadSeq);
        continue;
      }
      var pending = store.Pending(now());
      if (pending.Count == 0) return;
      var first = pending[0];
      var batch = new List<CloudOperation>(); var bytes = 2;
      if (first.Bytes.Length + 2 > MaximumPackPlainBytes) { store.Park(first.OpId, "This edit is larger than one upload can carry; it is kept here.", now()); continue; }
      foreach (var row in pending.Where(r => r.Domain == first.Domain))
      {
        if (batch.Count >= MaximumPackOps || first.Alone && batch.Count > 0 || batch.Count > 0 && row.Alone) break;
        var added = row.Bytes.Length + (batch.Count == 0 ? 0 : 1);
        if (bytes + added > MaximumPackPlainBytes) break;
        batch.Add(row.Operation); bytes += added;
      }
      var plain = CloudPackFormat.Encode(batch);
      if (plain.Length != bytes) throw new CloudFailure("unsupported_format");
      var (epoch, key) = await KeyAsync(null, ct);
      var id = CloudBytes.NewTransportId();
      var envelope = CloudBrainContent.Seal(plain, id, "brain", epoch, "gzip", subject, key);
      var sealedBytes = envelope.Canonical();
      if (sealedBytes.Length > CloudFeedClient.MaximumSegmentBytes) throw new CloudFailure("invalid_request");
      var unsigned = new CloudSegmentDescriptor(id, CloudBytes.NewTransportId(), "brain", "brain", [first.Domain], epoch, CloudBytes.Sha256Hex(sealedBytes),
        sealedBytes.Length, batch.Count, CloudPackFormat.Name, "");
      var signature = sign(unsigned.SigningBytes(subject));
      if (signature.Length != 64) throw new CloudFailure("invalid_request");
      store.SaveSegment(new(unsigned with { Signature = CloudBytes.Base64Url(signature) }, sealedBytes, batch.Select(o => o.OpId).ToArray()));
    }
  }

  /// The account's memory key for an epoch (null: current). Kept in memory only.
  private async Task<(int Epoch, byte[] Key)> KeyAsync(int? epoch, CancellationToken ct)
  {
    if (epoch is { } wanted && keys.TryGetValue(wanted, out var known)) return (wanted, known);
    if (epoch is null && store.GetLong("brainEpoch") is > 0 and var current && keys.TryGetValue((int)current, out var held)) return ((int)current, held);
    var (answered, key) = await client.BrainKeyAsync(epoch, ct);
    keys[answered] = key;
    if (epoch is null) store.SetLong("brainEpoch", answered);
    return (answered, key);
  }
  /// Sign-out: forget the keys held in memory.
  public void Forget() { foreach (var key in keys.Values) CryptographicOperations.ZeroMemory(key); keys.Clear(); }

  // ---- Receive ----

  public async Task PullAsync(CancellationToken ct)
  {
    // The switch: a first upload that sits in slot 1 (the only slot the service gives one) is passed over, never
    // imported, so it cannot stall this PC at position 0.
    if (Ledger.Cursor == 0)
    {
      var peek = await client.ChangesAsync(0, 1, ct);
      knownHead = Math.Max(knownHead, peek.HeadSeq);
      if (peek.Segments.FirstOrDefault()?.Seq == 2 || peek.Segments.Count == 0 && !peek.HasMore && peek.HeadSeq == 1)
      {
        var checkpoint = await client.CheckpointAsync(ct) ?? throw new CloudFailure("invalid_request");
        store.Set("ignoredFirstUpload", checkpoint.CheckpointId);
        Ledger.Refuse(1, null, FirstUploadPassedOver, 1);
      }
    }
    await Feed.PullAsync(ct);
    await RetryKindWaitingAsync(ct);
    var cursor = Ledger.Cursor;
    if (cursor > (ulong)store.GetLong("reportedSeq"))
    {
      await client.AppliedAsync(cursor, (ulong)store.GetLong("reportedSecretsSeq"), null, ct);
      store.SetLong("reportedSeq", (long)cursor);
    }
  }

  /// The judged loop's feed: pages from the service, their one-minute links kept for the sink. Entries of the other
  /// storage class are noted (they are saved passwords, read by their own position) so the page does not count them.
  private sealed class LinkedFeed(CloudSyncEngine engine) : ICloudFeed
  {
    public async Task<IReadOnlyList<CloudFeedEntry>> ChangesAsync(ulong after, int limit, CancellationToken ct)
    {
      var page = await engine.client.ChangesAsync(after, Math.Min(limit, CloudFeedClient.FeedPageLimit), ct);
      engine.knownHead = Math.Max(engine.knownHead, page.HeadSeq);
      foreach (var entry in page.Segments)
      {
        engine.links[entry.Seq] = entry;
        if (entry.StorageClass != "brain") engine.store.NoteOtherClass(entry.Seq);
      }
      if (engine.links.Count > 4 * CloudFeedClient.FeedPageLimit)
        foreach (var old in engine.links.Keys.Where(k => k + 2 * CloudFeedClient.FeedPageLimit < after).ToArray()) engine.links.Remove(old);
      return page.Segments.Select(e => e.ToFeedEntry()).ToArray();
    }
  }

  private sealed class Sink(CloudSyncEngine engine) : ICloudPackSink
  {
    public Task ApplyAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct) =>
      engine.ApplyPackAsync(entry, descriptor, signer, late, ct, kindsChecked: false);
  }

  private async Task ApplyPackAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct, bool kindsChecked)
  {
    // N2: a trusted pack of a kind this PC does not take WAITS (nothing downloaded), kept by position, applied as a
    // late arrival once every kind it names is taken here. It stops nothing.
    if (!kindsChecked && descriptor.Domains.Any(d => !adapters.ContainsKey(d)))
    {
      store.WaitForKind(new(entry.Seq, signer, descriptor.Domains));
      return;
    }
    if (descriptor.Purpose != "brain" || descriptor.Domains.Count == 0 || descriptor.KeyEpoch <= 0 || descriptor.Bytes is <= 0 or > CloudFeedClient.MaximumSegmentBytes
      || descriptor.OpCount is < 1 or > MaximumPackOps || descriptor.Format != CloudPackFormat.Name) throw new CloudFailure("unsupported_format");
    var bytes = await PackBytesAsync(entry, descriptor, ct);
    if (bytes.LongLength != descriptor.Bytes || CloudBytes.Sha256Hex(bytes) != descriptor.Sha256) throw new CloudFailure("checksum_mismatch");
    CloudContentEnvelope envelope;
    try { envelope = CloudContentEnvelope.Parse(bytes); } catch (CloudFailure) { throw new CloudFailure("unsupported_format"); }
    if (envelope.BlobId != descriptor.SegmentId || envelope.Epoch != descriptor.KeyEpoch || envelope.StorageClass != entry.StorageClass || envelope.Purpose != descriptor.Purpose)
      throw new CloudFailure("checksum_mismatch");
    var (_, key) = await KeyAsync(descriptor.KeyEpoch, ct);
    var operations = CloudPackFormat.Decode(CloudBrainContent.Open(envelope, subject, key));
    if (operations.Count != descriptor.OpCount || !operations.Select(o => o.Domain).ToHashSet().SetEquals(descriptor.Domains)
      || operations.Any(o => !adapters.ContainsKey(o.Domain))) throw new CloudFailure("checksum_mismatch");
    var origin = new CloudImportOrigin(signer, entry.Seq, entry.CreatedAt, late);
    var done = new List<string>();
    var touched = new List<ICloudSyncAdapter>();
    foreach (var op in operations)
    {
      if (store.IsApplied(op.OpId)) continue;
      // Mac X1(b), 13 Nov: a record its owner refuses for good (an id already used for other content, a record that
      // does not hold together) is noted and passed over; the rest of the pack applies and the feed moves on. The same
      // content arriving again is not a refusal: the owner takes it as already present.
      var owner = adapters[op.Domain];
      if (!touched.Contains(owner)) touched.Add(owner);
      try { await owner.ApplyAsync(op, origin, ct); }
      catch (CloudFailure refused) when (refused.Code is "id_reused" or "invalid_request")
      {
        store.Set(RefusedRecordPrefix + op.OpId, refused.Code);
        log("cloud sync: a record was refused: " + refused.Code);
      }
      done.Add(op.OpId);
    }
    foreach (var owner in touched) await owner.SettleAsync(ct);
    store.MarkApplied(done);
  }

  /// A pack this PC sent and the service acknowledged at this very position is not downloaded again.
  private async Task<byte[]> PackBytesAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, CancellationToken ct)
  {
    if (store.Segment(descriptor.SegmentId) is { ReceiptSeq: { } seq } own && seq == entry.Seq && own.Descriptor.Sha256 == descriptor.Sha256) return own.Ciphertext;
    if (!links.TryGetValue(entry.Seq, out var link) || link.GetUrl is null || link.SegmentId != descriptor.SegmentId) link = await RenewAsync(entry, descriptor, ct);
    try { return await client.DownloadAsync(link.GetUrl!, CloudFeedClient.MaximumSegmentBytes, ct); }
    catch (CloudFailure expired) when (expired.Code == "read_expired")
    {
      link = await RenewAsync(entry, descriptor, ct);
      return await client.DownloadAsync(link.GetUrl!, CloudFeedClient.MaximumSegmentBytes, ct);
    }
  }
  private async Task<CloudChangeEntry> RenewAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, CancellationToken ct)
  {
    var page = await client.ChangesAsync(entry.Seq - 1, CloudFeedClient.FeedPageLimit, ct);
    foreach (var fresh in page.Segments) links[fresh.Seq] = fresh;
    if (!links.TryGetValue(entry.Seq, out var renewed) || renewed.SegmentId != descriptor.SegmentId || renewed.Sha256 != descriptor.Sha256 || renewed.GetUrl is null)
      throw new CloudFailure("checksum_mismatch");
    return renewed;
  }

  /// Packs that waited for a kind now taken here are judged again under the stored key and applied, late, in order.
  private async Task RetryKindWaitingAsync(CancellationToken ct)
  {
    foreach (var row in store.KindWaiting)
    {
      if (row.Domains.Any(d => !adapters.ContainsKey(d))) continue;
      var page = await client.ChangesAsync(row.Seq - 1, 1, ct);
      if (page.Segments.FirstOrDefault() is not { } entry || entry.Seq != row.Seq) throw new CloudFailure("invalid_response");
      links[entry.Seq] = entry;
      switch (Feed.Judge(entry.ToFeedEntry()))
      {
        case CloudPackVerdict.Apply apply:
          await ApplyPackAsync(entry.ToFeedEntry(), apply.Descriptor, apply.Signer, late: true, ct, kindsChecked: true);
          store.KindTaken(row.Seq);
          break;
        case CloudPackVerdict.Refused refused:
          Ledger.Refuse(row.Seq, row.DeviceId, refused.Reason, null);
          store.KindTaken(row.Seq);
          break;
        default: break; // Trust was withdrawn meanwhile: it goes on waiting.
      }
    }
  }

  // ---- State for the page ----

  public CloudSyncState State()
  {
    if (!HasKinds) return CloudSyncState.Idle;
    var sending = store.QueuedCount;
    var cursor = Ledger.Cursor;
    var receiving = knownHead > cursor ? (int)Math.Min(int.MaxValue, knownHead - cursor) : 0;
    var held = Ledger.Held;
    var refused = Ledger.Refused.Count(r => r.Reason != FirstUploadPassedOver && !store.IsOtherClass(r.Seq));
    var waiting = store.KindWaiting.Count;
    var parked = store.Parked.Count;
    var heldPacks = held.Sum(h => h.Packs);
    string? reason = null;
    if (!client.Backoff.MaySend || lastFailure is not null)
      reason = client.Backoff.Blocked switch
      {
        "auth" => "sign in to Cloud again",
        "budget" => "Cloud's daily allowance; it resumes by itself",
        "rate" => "Cloud asked to slow down; it resumes by itself",
        "gate" => "Cloud is not on for this account",
        "remote" => "Cloud refused a step; press Try again",
        "network" => "Cloud cannot be reached; it retries when the network returns",
        _ => lastFailure ?? "retrying shortly"
      };
    else if (store.GetLong("sendStoppedUntil") > now()) reason = "Cloud refused three uploads in a row; sending resumes by itself";
    else if (heldPacks > 0) reason = heldPacks.ToString(CultureInfo.InvariantCulture) + " changes from devices this PC does not trust yet";
    if (reason is not null) return new(CloudSyncPhase.Waiting, sending, receiving, reason, heldPacks, held.Count, refused, waiting, parked);
    if (sending > 0) return new(CloudSyncPhase.Sending, sending, receiving, null, heldPacks, held.Count, refused, waiting, parked);
    if (receiving > 0) return new(CloudSyncPhase.Receiving, sending, receiving, null, heldPacks, held.Count, refused, waiting, parked);
    return new(CloudSyncPhase.Level, 0, 0, null, heldPacks, held.Count, refused, waiting, parked);
  }
}
