using System.Globalization;

namespace TerminalDeck.Core.Cloud;

// The judged-apply loop (the Mac's CloudSyncEngine judge / receive / releaseTrustedHeld / releasePass and
// CloudSyncTrustStore.swift). Every feed entry is judged BEFORE anything of it is downloaded: apply (its signature
// checks under the key this PC's own trusted list stores for the device the feed names), held (that device is not
// trusted here: the pack waits untouched and the feed goes on), or refused (bad signature, no device, malformed,
// repeats an applied pack: recorded and reported, the feed goes on). Held packs are released in their original feed
// order once their device is trusted, and a restart in the middle resumes the release where it stopped.
// W2 skeleton: the feed transport and the record adapters are W3 (`ICloudFeed`, `ICloudPackSink`).

/// One entry of the change feed as the service lists it. `Descriptor` is null when a stated field is missing.
public sealed record CloudFeedEntry(ulong Seq, string StorageClass, string? DeviceId, CloudSegmentDescriptor? Descriptor, bool Locked = false, long? CreatedAt = null);

/// W3: the service's feed, in order, after a position.
public interface ICloudFeed { Task<IReadOnlyList<CloudFeedEntry>> ChangesAsync(ulong after, int limit, CancellationToken ct); }

/// W3: downloads, checks against the signed hash, opens and applies a judged pack. `signer` is the verified device
/// (never the pack's own origin field); `late` marks a release out of feed order. Must be idempotent: a crash between
/// applying and recording applies the same pack again. Throw CloudFailure "checksum_mismatch" or "unsupported_format"
/// for a pack with a good signature that cannot be opened (a release then stops for that device only).
public interface ICloudPackSink { Task ApplyAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct); }

/// The verdict for one entry (CloudPackVerdict).
public abstract record CloudPackVerdict
{
  public sealed record Apply(CloudSegmentDescriptor Descriptor, string Signer) : CloudPackVerdict;
  public sealed record Held(string Device) : CloudPackVerdict;
  public sealed record Refused(string Reason) : CloudPackVerdict;
  public const string NoDevice = "no-device", Malformed = "malformed", BadSignature = "bad-signature";
  public const string RepeatedPack = "repeated-pack", PackIdReused = "pack-id-reused", PositionReused = "position-reused";
}

public sealed record CloudHeldDevice(string DeviceId, ulong? FirstSeq, int Packs, int Operations, long FirstSeenAt, bool Releasing);
public sealed record CloudRefusedPack(ulong Seq, string? DeviceId, string Reason, long FirstAt, int Checks);
public sealed record CloudAppliedPack(string SegmentId, ulong Seq, string Digest);

/// Where the feed's own rows are kept (W3: a file in this copy's data folder). `Read` returns null when nothing was saved.
public interface ICloudLedgerSlot { byte[]? Read(); void Write(byte[] bytes); }

/// This PC's position in one class's feed, its held devices, refused packs and applied packs. Every change is saved
/// at once in one write, so a pack is counted once and a restart resumes from what was saved.
public sealed class CloudFeedLedger
{
  public const int MaximumCount = 1_000_000;
  private readonly ICloudLedgerSlot slot;
  private readonly Func<long> now;
  public ulong Cursor { get; private set; }
  private readonly List<CloudHeldDevice> held = [];
  private readonly List<CloudRefusedPack> refused = [];
  private readonly List<CloudAppliedPack> applied = [];
  public IReadOnlyList<CloudHeldDevice> Held => held.OrderBy(h => h.FirstSeenAt).ThenBy(h => h.DeviceId, StringComparer.Ordinal).ToArray();
  public IReadOnlyList<CloudRefusedPack> Refused => refused.OrderBy(r => r.Seq).ToArray();
  public IReadOnlyList<CloudAppliedPack> Applied => applied.ToArray();

  public CloudFeedLedger(ICloudLedgerSlot slot, Func<long>? now = null)
  {
    this.slot = slot; this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    if (slot.Read() is not { } bytes) return;
    if (CloudJson.Parse(bytes) is not CloudJson.Object o || CloudFields.Integer(o, "v") != 1) throw new CloudFailure("unsupported_format");
    Cursor = Seq(CloudFields.Text(o, "cursor"));
    foreach (var row in Rows(o, "held"))
      held.Add(new(CloudFields.Text(row, "deviceId"), CloudFields.OptionalText(row, "firstSeq") is { } f ? Seq(f) : null, (int)CloudFields.Integer(row, "packs"),
        (int)CloudFields.Integer(row, "operations"), CloudFields.Integer(row, "firstSeenAt"), row["releasing"] is CloudJson.Bool { Value: true }));
    foreach (var row in Rows(o, "refused"))
      refused.Add(new(Seq(CloudFields.Text(row, "seq")), CloudFields.OptionalText(row, "deviceId"), CloudFields.Text(row, "reason"), CloudFields.Integer(row, "firstAt"), (int)CloudFields.Integer(row, "checks")));
    foreach (var row in Rows(o, "applied"))
      applied.Add(new(CloudFields.Text(row, "segmentId"), Seq(CloudFields.Text(row, "seq")), CloudFields.Text(row, "digest")));
  }
  private static IEnumerable<CloudJson.Object> Rows(CloudJson.Object o, string key) =>
    o[key] is CloudJson.Array a ? a.Items.Select(i => i as CloudJson.Object ?? throw new CloudFailure("unsupported_format")) : throw new CloudFailure("unsupported_format");
  /// A feed position as text (CloudSequence): digits, no leading zero.
  private static ulong Seq(string text) =>
    text.Length > 0 && text.All(char.IsAsciiDigit) && (text == "0" || text[0] != '0') && ulong.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : throw new CloudFailure("invalid_request");
  private static CloudJson Text(ulong seq) => CloudJson.From(seq.ToString(CultureInfo.InvariantCulture));
  private void Save()
  {
    slot.Write(CloudCanonical.Encode(CloudJson.Obj(("v", CloudJson.From(1)), ("cursor", Text(Cursor)),
      ("held", CloudJson.Arr(held.Select(h => (CloudJson)CloudJson.Obj(("deviceId", CloudJson.From(h.DeviceId)), ("firstSeq", h.FirstSeq is { } f ? Text(f) : null),
        ("packs", CloudJson.From(h.Packs)), ("operations", CloudJson.From(h.Operations)), ("firstSeenAt", CloudJson.From(h.FirstSeenAt)), ("releasing", CloudJson.From(h.Releasing)))))),
      ("refused", CloudJson.Arr(refused.Select(r => (CloudJson)CloudJson.Obj(("seq", Text(r.Seq)), ("deviceId", r.DeviceId is { } d ? CloudJson.From(d) : null),
        ("reason", CloudJson.From(r.Reason)), ("firstAt", CloudJson.From(r.FirstAt)), ("checks", CloudJson.From(r.Checks)))))),
      ("applied", CloudJson.Arr(applied.Select(a => (CloudJson)CloudJson.Obj(("segmentId", CloudJson.From(a.SegmentId)), ("seq", Text(a.Seq)), ("digest", CloudJson.From(a.Digest)))))))));
  }
  private void Move(ulong? cursor) { if (cursor is { } c) Cursor = c; }

  public CloudHeldDevice? HeldRow(string deviceId) => held.FirstOrDefault(h => h.DeviceId == deviceId);
  /// One more waiting pack of `deviceId` at `seq`: only the device's row changes (first waiting position, counters);
  /// nothing of the pack itself is kept. `cursor` moves the position in the same write.
  public void Hold(string deviceId, ulong seq, int operations, ulong? cursor)
  {
    var old = HeldRow(deviceId);
    var row = new CloudHeldDevice(deviceId, Math.Min(old?.FirstSeq ?? seq, seq), Math.Min(MaximumCount, (old?.Packs ?? 0) + 1),
      Math.Min(MaximumCount, (old?.Operations ?? 0) + Math.Clamp(operations, 0, MaximumCount)), old?.FirstSeenAt ?? now(), old?.Releasing ?? false);
    Replace(old, row); Move(cursor); Save();
  }
  /// Records a refused pack once per position; judging the same position again only counts the check.
  public void Refuse(ulong seq, string? deviceId, string reason, ulong? cursor)
  {
    var index = refused.FindIndex(r => r.Seq == seq);
    if (index >= 0) refused[index] = refused[index] with { Checks = refused[index].Checks + 1, Reason = reason };
    else refused.Add(new(seq, deviceId, reason, now(), 1));
    Move(cursor); Save();
  }
  public void MarkApplied(CloudSegmentDescriptor descriptor, ulong seq, ulong? cursor)
  {
    if (!IsApplied(descriptor.SegmentId, seq, descriptor.Sha256)) applied.Add(new(descriptor.SegmentId, seq, descriptor.Sha256));
    Move(cursor); Save();
  }
  public bool IsApplied(string segmentId, ulong seq, string digest) => applied.Any(a => a.SegmentId == segmentId && a.Seq == seq && a.Digest == digest);
  /// Why a verified pack must not be applied because of what this PC already applied, or null (also for the very same
  /// pack at its own position: it is simply applied already).
  public string? RepeatedPackReason(string segmentId, ulong seq, string digest)
  {
    if (applied.FirstOrDefault(a => a.SegmentId == segmentId) is { } previous)
      return previous.Seq == seq && previous.Digest == digest ? null : previous.Digest == digest ? CloudPackVerdict.RepeatedPack : CloudPackVerdict.PackIdReused;
    return applied.Any(a => a.Seq == seq) ? CloudPackVerdict.PositionReused : null;
  }
  public void SetReleasing(IEnumerable<string> devices, bool on)
  {
    var changed = false;
    foreach (var device in devices) if (HeldRow(device) is { } row && row.Releasing != on) { Replace(row, row with { Releasing = on }); changed = true; }
    if (changed) Save();
  }
  /// A release handled the device's pack at `seq`: its first waiting position moves to `seq + 1` (so a restart resumes
  /// there) and its counters go down, never below zero.
  public void Released(string deviceId, ulong seq, int operations)
  {
    if (HeldRow(deviceId) is not { } row) return;
    Replace(row, row with { FirstSeq = seq + 1, Packs = Math.Max(0, row.Packs - 1), Operations = Math.Max(0, row.Operations - Math.Clamp(operations, 0, MaximumCount)) });
    Save();
  }
  /// Sets a device's first waiting position (trust was removed or a pack could not be opened during a release), or
  /// with null removes its row (the release reached this PC's position).
  public void SetHeldPosition(string deviceId, ulong? position)
  {
    if (HeldRow(deviceId) is not { } row) return;
    if (position is null) held.Remove(row); else Replace(row, row with { FirstSeq = position, Releasing = false });
    Save();
  }
  private void Replace(CloudHeldDevice? old, CloudHeldDevice row)
  {
    var index = old is null ? -1 : held.IndexOf(old);
    if (index >= 0) held[index] = row; else held.Add(row);
  }
}

/// The loop for one storage class. Single caller at a time (the sync owner serialises pulls and trust presses).
public sealed class CloudJudgedFeed(string subject, string storageClass, ICloudFeed feed, ICloudPackSink sink, ICloudDeviceTrust trust, CloudFeedLedger ledger)
{
  public const int PageLimit = 100;
  public CloudFeedLedger Ledger { get; } = ledger;

  /// Judged before anything of the pack is downloaded. The device the service names selects the stored key; the
  /// signature under that key decides. "Own" is nothing special: an entry carrying this PC's id applies only if it
  /// checks under the key the list stores for that id. No field inside the pack is read.
  public CloudPackVerdict Judge(CloudFeedEntry entry)
  {
    if (entry.DeviceId is not { } device || !CloudBytes.IsTransportId(device)) return new CloudPackVerdict.Refused(CloudPackVerdict.NoDevice);
    if (trust.TrustedSigningKey(device) is not { } key) return new CloudPackVerdict.Held(device);
    if (entry.Locked || entry.Descriptor is not { } descriptor || descriptor.StorageClass != entry.StorageClass) return new CloudPackVerdict.Refused(CloudPackVerdict.Malformed);
    switch (descriptor.Check(key, subject))
    {
      case CloudSignatureCheck.Valid:
        return Ledger.RepeatedPackReason(descriptor.SegmentId, entry.Seq, descriptor.Sha256) is { } reason
          ? new CloudPackVerdict.Refused(reason) : new CloudPackVerdict.Apply(descriptor, device);
      // The stored key cannot be read: nothing is wrong with the pack, so it WAITS.
      case CloudSignatureCheck.BadKey: return new CloudPackVerdict.Held(device);
      default: return new CloudPackVerdict.Refused(CloudPackVerdict.BadSignature);
    }
  }

  /// One pull: waiting packs of devices trusted now are released first (and a release a restart cut short resumes),
  /// then the feed is read from this PC's position to the end. No entry ever stops the feed except a trusted pack
  /// that cannot be opened (the position stays there, as on the Mac).
  public async Task PullAsync(CancellationToken ct)
  {
    await ReleaseTrustedHeldAsync(null, ct);
    while (true)
    {
      var page = await feed.ChangesAsync(Ledger.Cursor, PageLimit, ct);
      if (page.Count == 0) return;
      foreach (var entry in page)
      {
        if (entry.Seq != Ledger.Cursor + 1) throw new CloudFailure("invalid_request");
        if (entry.StorageClass != storageClass) { Ledger.Refuse(entry.Seq, entry.DeviceId, CloudPackVerdict.Malformed, entry.Seq); continue; }
        await ReceiveAsync(entry, ct);
      }
    }
  }

  /// After the person trusted devices (a press in this PC's window), their waiting packs are released at once.
  public Task ReleaseHeldAsync(IReadOnlyCollection<string> deviceIds, CancellationToken ct) => ReleaseTrustedHeldAsync(deviceIds.ToHashSet(StringComparer.Ordinal), ct);

  private async Task ReceiveAsync(CloudFeedEntry entry, CancellationToken ct)
  {
    switch (Judge(entry))
    {
      case CloudPackVerdict.Held held: Ledger.Hold(held.Device, entry.Seq, entry.Descriptor?.OpCount ?? 0, entry.Seq); return;
      case CloudPackVerdict.Refused refused: Ledger.Refuse(entry.Seq, entry.DeviceId, refused.Reason, entry.Seq); return;
      case CloudPackVerdict.Apply apply:
        // R6: nothing of a device is applied while its older packs still wait here. Their release runs first; if
        // they still wait (trust withdrawn, a pack that cannot be opened), this pack waits with them.
        if (Ledger.HeldRow(apply.Signer)?.FirstSeq is not null)
        {
          await ReleaseTrustedHeldAsync(new HashSet<string>(StringComparer.Ordinal) { apply.Signer }, ct);
          if (Ledger.HeldRow(apply.Signer)?.FirstSeq is not null) { Ledger.Hold(apply.Signer, entry.Seq, apply.Descriptor.OpCount, entry.Seq); return; }
        }
        await sink.ApplyAsync(entry, apply.Descriptor, apply.Signer, late: false, ct);
        Ledger.MarkApplied(apply.Descriptor, entry.Seq, entry.Seq);
        return;
    }
  }

  private async Task ReleaseTrustedHeldAsync(HashSet<string>? named, CancellationToken ct)
  {
    // Whom to ask the list about: the named devices; or, at the start of a pull, the devices whose release already
    // began (resumed first after a restart) and every other waiting device.
    var resuming = Ledger.Held.Where(h => h.Releasing).Select(h => h.DeviceId).ToHashSet(StringComparer.Ordinal);
    var candidates = named ?? Ledger.Held.Select(h => h.DeviceId).ToHashSet(StringComparer.Ordinal);
    var devices = new HashSet<string>(StringComparer.Ordinal); var withdrawn = new List<string>();
    foreach (var device in candidates)
    {
      if (trust.TrustedSigningKey(device) is null) { if (resuming.Contains(device)) withdrawn.Add(device); continue; }
      if (Ledger.HeldRow(device)?.FirstSeq is not null) devices.Add(device);
    }
    if (withdrawn.Count > 0) Ledger.SetReleasing(withdrawn, false);
    if (devices.Count == 0) return;
    Ledger.SetReleasing(devices, true);
    await ReleasePassAsync(devices, ct);
  }

  /// ONE pass over the feed, in feed order, from the lowest first waiting position among `devices` up to this PC's
  /// position. Each waiting pack is judged under the stored key at that moment and applied with its ORIGINAL position,
  /// marked late; one that does not check is refused. The device's row moves forward pack by pack, so a restart
  /// resumes where the pass stopped; when the pass reaches this PC's position the row is removed.
  private async Task ReleasePassAsync(HashSet<string> devices, CancellationToken ct)
  {
    var active = new Dictionary<string, ulong>(StringComparer.Ordinal);
    foreach (var row in Ledger.Held) if (devices.Contains(row.DeviceId) && row.FirstSeq is { } first) active[row.DeviceId] = first;
    if (active.Count == 0) return;
    var start = active.Values.Min();
    if (start == 0) throw new CloudFailure("invalid_request");
    var end = Ledger.Cursor; var cursor = start - 1;
    while (cursor < end && active.Count > 0)
    {
      var page = await feed.ChangesAsync(cursor, PageLimit, ct);
      if (page.Count == 0) throw new CloudFailure("invalid_request");
      foreach (var entry in page)
      {
        if (entry.Seq != cursor + 1) throw new CloudFailure("invalid_request");
        if (entry.Seq > end) { cursor = end; break; }
        cursor = entry.Seq;
        if (entry.StorageClass != storageClass || entry.DeviceId is not { } device || !active.TryGetValue(device, out var first) || entry.Seq < first) continue;
        var stopped = false;
        switch (Judge(entry))
        {
          case CloudPackVerdict.Held: stopped = true; break;
          case CloudPackVerdict.Refused refused: Ledger.Refuse(entry.Seq, entry.DeviceId, refused.Reason, null); break;
          case CloudPackVerdict.Apply apply:
            if (Ledger.IsApplied(apply.Descriptor.SegmentId, entry.Seq, apply.Descriptor.Sha256)) break;
            try { await sink.ApplyAsync(entry, apply.Descriptor, apply.Signer, late: true, ct); Ledger.MarkApplied(apply.Descriptor, entry.Seq, null); }
            catch (CloudFailure failure) when (failure.Code is "checksum_mismatch" or "unsupported_format") { stopped = true; }
            break;
        }
        if (stopped)
        {
          // This pack and the device's later ones go on waiting, in order.
          Ledger.SetHeldPosition(device, entry.Seq);
          active.Remove(device);
        }
        else Ledger.Released(device, entry.Seq, entry.Descriptor?.OpCount ?? 0);
      }
    }
    // The pass reached this PC's position: nothing of these devices waits any more.
    foreach (var device in active.Keys) Ledger.SetHeldPosition(device, null);
  }
}
