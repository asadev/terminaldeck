using System.Globalization;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// W3 sync store (the Mac's CloudSyncStore.swift / sync.sqlite): the outbox, the sealed packs waiting for their receipt,
// the ops already applied here, packs waiting for a kind this PC does not take yet, the feed ledger's slot and small
// metadata (request ids, back-off, clock correction).
//
// DECISION (W3, 13 Nov): no SQLite. The Windows solution has no database provider (its stores are JSON files written
// by atomic replace, Storage/StateStore.cs), and adding one means native e_sqlite3 binaries in the WinUI package. The
// store is therefore one canonical JSON document per account folder, written whole by write-temp, flush-to-disk,
// rename on every change: after a crash the file is either the old or the new state, never a mix. A failed write
// reloads the last saved state, so memory and disk never disagree. The feed ledger keeps its own file (its slot).
//
// Idempotent apply: an op id is recorded as applied only AFTER its record was written; a crash in between applies the
// same op again, and every adapter's apply is a no-op for an op it already holds (same op id, same bytes).

/// Atomic file slot (write temp, flush to disk, replace). Read returns null when nothing was saved.
public sealed class CloudFileSlot(string path) : ICloudLedgerSlot, ICloudTrustSlot
{
  public string Path { get; } = path;
  public byte[]? Read() => File.Exists(Path) ? File.ReadAllBytes(Path) : null;
  public void Write(byte[] bytes)
  {
    Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
    var temporary = Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      {
        file.Write(bytes);
        file.Flush(flushToDisk: true);
      }
      File.Move(temporary, Path, overwrite: true);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
}

public enum CloudOutboxState { Queued, Sealed, Sent, Parked, Retired }
public sealed record CloudOutboxRow(string OpId, string Domain, byte[] Bytes, CloudOutboxState State, string? Reason = null, bool Alone = false, long ParkedUntil = 0, int ParkedAttempts = 0)
{
  public CloudOperation Operation => CloudOperation.FromJson(CloudJson.Parse(Bytes));
}
public sealed record CloudSealedSegment(CloudSegmentDescriptor Descriptor, byte[] Ciphertext, IReadOnlyList<string> OpIds, ulong? ReceiptSeq = null, bool Retired = false, bool SentOnce = false);
public sealed record CloudKindWaiting(ulong Seq, string DeviceId, IReadOnlyList<string> Domains);

public sealed class CloudSyncStore : ICloudSyncMetadata
{
  private readonly ICloudLedgerSlot slot;
  private readonly object gate = new();
  private Dictionary<string, string> metadata = new(StringComparer.Ordinal);
  private List<CloudOutboxRow> outbox = [];
  private List<CloudSealedSegment> segments = [];
  private HashSet<string> applied = new(StringComparer.Ordinal);
  private List<CloudKindWaiting> kindWaiting = [];
  private SortedSet<ulong> otherClass = [];

  /// The feed ledger's own slot (CloudFeedLedger), beside this store.
  public ICloudLedgerSlot LedgerSlot { get; }
  public string Subject { get; }

  public CloudSyncStore(ICloudLedgerSlot slot, ICloudLedgerSlot ledgerSlot, string subject)
  {
    this.slot = slot; LedgerSlot = ledgerSlot; Subject = subject;
    Load();
  }
  /// `<account folder>/sync/state.json` and `ledger.json`. The account folder is Cloud's own, per signed-in account.
  public static CloudSyncStore InFolder(string accountFolder, string subject) =>
    new(new CloudFileSlot(System.IO.Path.Combine(accountFolder, "sync", "state.json")), new CloudFileSlot(System.IO.Path.Combine(accountFolder, "sync", "ledger.json")), subject);

  private void Load()
  {
    metadata = new(StringComparer.Ordinal); outbox = []; segments = []; applied = new(StringComparer.Ordinal); kindWaiting = []; otherClass = [];
    if (slot.Read() is not { } bytes) return;
    if (CloudJson.Parse(bytes) is not CloudJson.Object o || o["v"]?.AsInteger != 1) throw new CloudFailure("unsupported_format");
    if (o["subject"]?.AsString != Subject) throw new CloudFailure("unsafe_configuration");
    foreach (var m in Obj(o["metadata"]).Members) metadata[m.Key] = m.Value.AsString ?? throw new CloudFailure("unsupported_format");
    foreach (var r in Arr(o["outbox"]))
      outbox.Add(new(Text(r, "opId"), Text(r, "domain"), Convert.FromBase64String(Text(r, "bytes")), Enum.Parse<CloudOutboxState>(Text(r, "state")),
        r["reason"]?.AsString, r["alone"] is CloudJson.Bool { Value: true }, r["parkedUntil"]?.AsInteger ?? 0, (int)(r["parkedAttempts"]?.AsInteger ?? 0)));
    foreach (var r in Arr(o["segments"]))
      segments.Add(new(CloudSegmentDescriptor.FromJson(r["descriptor"]!), Convert.FromBase64String(Text(r, "ciphertext")),
        Strings(r["opIds"]), r["receiptSeq"]?.AsString is { } s ? ulong.Parse(s, CultureInfo.InvariantCulture) : null,
        r["retired"] is CloudJson.Bool { Value: true }, r["sentOnce"] is CloudJson.Bool { Value: true }));
    foreach (var a in ((CloudJson.Array)o["applied"]!).Items) applied.Add(a.AsString!);
    foreach (var r in Arr(o["kindWaiting"]))
      kindWaiting.Add(new(ulong.Parse(Text(r, "seq"), CultureInfo.InvariantCulture), Text(r, "deviceId"), Strings(r["domains"])));
    foreach (var s in ((CloudJson.Array)o["otherClass"]!).Items) otherClass.Add(ulong.Parse(s.AsString!, CultureInfo.InvariantCulture));
  }
  private static string[] Strings(CloudJson? v) => (v as CloudJson.Array ?? throw new CloudFailure("unsupported_format")).Items.Select(i => i.AsString ?? throw new CloudFailure("unsupported_format")).ToArray();
  private static CloudJson.Object Obj(CloudJson? v) => v as CloudJson.Object ?? throw new CloudFailure("unsupported_format");
  private static IEnumerable<CloudJson.Object> Arr(CloudJson? v) => (v as CloudJson.Array ?? throw new CloudFailure("unsupported_format")).Items.Select(Obj);
  private static string Text(CloudJson.Object o, string k) => o[k]?.AsString ?? throw new CloudFailure("unsupported_format");
  private static CloudJson S(ulong v) => CloudJson.From(v.ToString(CultureInfo.InvariantCulture));

  private byte[] Encode() => CloudCanonical.Encode(CloudJson.Obj(("v", CloudJson.From(1)), ("subject", CloudJson.From(Subject)),
    ("metadata", CloudJson.Obj(metadata.Select(m => (m.Key, (CloudJson?)CloudJson.From(m.Value))).ToArray())),
    ("outbox", CloudJson.Arr(outbox.Select(r => (CloudJson)CloudJson.Obj(("opId", CloudJson.From(r.OpId)), ("domain", CloudJson.From(r.Domain)),
      ("bytes", CloudJson.From(Convert.ToBase64String(r.Bytes))), ("state", CloudJson.From(r.State.ToString())), ("reason", r.Reason is { } why ? CloudJson.From(why) : null),
      ("alone", r.Alone ? CloudJson.From(true) : null), ("parkedUntil", r.ParkedUntil > 0 ? CloudJson.From(r.ParkedUntil) : null),
      ("parkedAttempts", r.ParkedAttempts > 0 ? CloudJson.From(r.ParkedAttempts) : null))))),
    ("segments", CloudJson.Arr(segments.Select(s => (CloudJson)CloudJson.Obj(("descriptor", s.Descriptor.ToJson()), ("ciphertext", CloudJson.From(Convert.ToBase64String(s.Ciphertext))),
      ("opIds", CloudJson.Arr(s.OpIds.Select(i => CloudJson.From(i)))), ("receiptSeq", s.ReceiptSeq is { } q ? S(q) : null),
      ("retired", s.Retired ? CloudJson.From(true) : null), ("sentOnce", s.SentOnce ? CloudJson.From(true) : null))))),
    ("applied", CloudJson.Arr(applied.Order(StringComparer.Ordinal).Select(a => CloudJson.From(a)))),
    ("kindWaiting", CloudJson.Arr(kindWaiting.Select(k => (CloudJson)CloudJson.Obj(("seq", S(k.Seq)), ("deviceId", CloudJson.From(k.DeviceId)),
      ("domains", CloudJson.Arr(k.Domains.Select(d => CloudJson.From(d)))))))),
    ("otherClass", CloudJson.Arr(otherClass.Select(S)))));

  /// One change, saved at once in one write. A failed write puts the last saved state back and rethrows.
  private T Change<T>(Func<T> change)
  {
    lock (gate)
    {
      try { var result = change(); slot.Write(Encode()); return result; }
      catch { Load(); throw; }
    }
  }
  private void Change(Action change) => Change(() => { change(); return 0; });

  // ---- Metadata ----
  public string? Get(string key) { lock (gate) return metadata.TryGetValue(key, out var v) ? v : null; }
  public void Set(string key, string? value)
  {
    lock (gate) { if (metadata.TryGetValue(key, out var old) ? old == value : value is null) return; }
    Change(() => { if (value is null) metadata.Remove(key); else metadata[key] = value; });
  }
  public long GetLong(string key) => long.TryParse(Get(key), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;
  public void SetLong(string key, long? value) => Set(key, value?.ToString(CultureInfo.InvariantCulture));

  // ---- Outbox ----
  /// Queues this PC's own records, in order. A record already queued (same op id) is kept as first queued: a capture
  /// repeated after a crash makes the same ids, and the first copy (with its first stamp) is the one that travels.
  /// Own records count as applied here at once (this PC wrote them).
  public int Enqueue(IEnumerable<CloudOperation> operations)
  {
    var list = operations.ToArray();
    CloudPackFormat.Validate(list);
    return Change(() =>
    {
      var known = outbox.Select(r => r.OpId).ToHashSet(StringComparer.Ordinal);
      var added = 0;
      foreach (var op in list)
      {
        if (!known.Add(op.OpId)) continue;
        outbox.Add(new(op.OpId, op.Domain, CloudCanonical.Encode(op.ToJson()), CloudOutboxState.Queued));
        applied.Add(op.OpId);
        added++;
      }
      return added;
    });
  }
  public IReadOnlyList<CloudOutboxRow> Outbox { get { lock (gate) return outbox.ToArray(); } }
  public int QueuedCount { get { lock (gate) return outbox.Count(r => r.State is CloudOutboxState.Queued or CloudOutboxState.Sealed); } }
  /// Queued records ready to seal, in queue order (parked ones whose wait has passed come back first).
  public IReadOnlyList<CloudOutboxRow> Pending(long now) { lock (gate) return outbox.Where(r => r.State == CloudOutboxState.Queued || r.State == CloudOutboxState.Parked && r.ParkedUntil <= now && r.ParkedUntil > 0).ToArray(); }
  public void MarkAlone(IEnumerable<string> opIds) { var ids = opIds.ToHashSet(); Change(() => outbox = outbox.Select(r => ids.Contains(r.OpId) ? r with { Alone = true } : r).ToList()); }
  /// A record the service refused alone: kept, reported, retried later (one minute doubling to six hours).
  public void Park(string opId, string reason, long now) => Change(() => outbox = outbox.Select(r => r.OpId != opId ? r : r with
  {
    State = CloudOutboxState.Parked, Reason = reason, ParkedAttempts = r.ParkedAttempts + 1,
    ParkedUntil = now + Math.Min(21_600_000, 60_000L << Math.Min(r.ParkedAttempts, 20))
  }).ToList());
  public IReadOnlyList<CloudOutboxRow> Parked { get { lock (gate) return outbox.Where(r => r.State == CloudOutboxState.Parked).ToArray(); } }

  // ---- Sealed packs ----
  /// Saved before the first send, with its records marked sealed, in one write: a crash after this resends the very
  /// same signed bytes (same pack id, same request id), never a second pack of the same records.
  public void SaveSegment(CloudSealedSegment segment) => Change(() =>
  {
    var ids = segment.OpIds.ToHashSet(StringComparer.Ordinal);
    if (outbox.Count(r => ids.Contains(r.OpId) && r.State is CloudOutboxState.Queued or CloudOutboxState.Parked) != ids.Count) throw new CloudFailure("invalid_request");
    segments.Add(segment);
    outbox = outbox.Select(r => ids.Contains(r.OpId) ? r with { State = CloudOutboxState.Sealed } : r).ToList();
  });
  public CloudSealedSegment? Unacknowledged() { lock (gate) return segments.FirstOrDefault(s => s.ReceiptSeq is null && !s.Retired); }
  public CloudSealedSegment? Segment(string segmentId) { lock (gate) return segments.FirstOrDefault(s => s.Descriptor.SegmentId == segmentId); }
  public void MarkSentOnce(string segmentId) => Change(() => segments = segments.Select(s => s.Descriptor.SegmentId == segmentId ? s with { SentOnce = true } : s).ToList());
  /// The service's receipt for a pack: its records leave the queue. Older acknowledged packs keep only what the pull
  /// needs to recognise them (it does not download this PC's own packs again).
  public void Acknowledge(string segmentId, ulong seq) => Change(() =>
  {
    var segment = segments.FirstOrDefault(s => s.Descriptor.SegmentId == segmentId) ?? throw new CloudFailure("invalid_request");
    var ids = segment.OpIds.ToHashSet(StringComparer.Ordinal);
    segments = segments.Select(s => s == segment ? s with { ReceiptSeq = seq } : s).ToList();
    outbox = outbox.Where(r => !ids.Contains(r.OpId)).ToList();
    // Keep the newest 64 acknowledged packs for the pull's own-pack shortcut; older ones are forgotten.
    var acknowledged = segments.Where(s => s.ReceiptSeq is not null).ToList();
    if (acknowledged.Count > 64) segments = segments.Except(acknowledged.Take(acknowledged.Count - 64)).ToList();
  });
  /// The service refused this pack for good: the pack is retired and its records go back to the queue.
  public void RetireSegment(string segmentId) => Change(() =>
  {
    var segment = segments.FirstOrDefault(s => s.Descriptor.SegmentId == segmentId) ?? throw new CloudFailure("invalid_request");
    var ids = segment.OpIds.ToHashSet(StringComparer.Ordinal);
    segments = segments.Select(s => s == segment ? s with { Retired = true } : s).ToList();
    outbox = outbox.Select(r => ids.Contains(r.OpId) && r.State == CloudOutboxState.Sealed ? r with { State = CloudOutboxState.Queued } : r).ToList();
  });

  // ---- Applied ops (idempotent apply) ----
  public bool IsApplied(string opId) { lock (gate) return applied.Contains(opId); }
  public void MarkApplied(IEnumerable<string> opIds) { var ids = opIds.ToArray(); if (ids.Length > 0) Change(() => { foreach (var id in ids) applied.Add(id); }); }

  // ---- Packs waiting for a kind this PC does not take yet ----
  public IReadOnlyList<CloudKindWaiting> KindWaiting { get { lock (gate) return kindWaiting.ToArray(); } }
  public void WaitForKind(CloudKindWaiting row) => Change(() => { if (!kindWaiting.Any(k => k.Seq == row.Seq)) kindWaiting.Add(row); kindWaiting.Sort((a, b) => a.Seq.CompareTo(b.Seq)); });
  public void KindTaken(ulong seq) => Change(() => kindWaiting.RemoveAll(k => k.Seq == seq));

  // ---- Feed positions of the other storage class (saved passwords: their own cursor, never memory's) ----
  public void NoteOtherClass(ulong seq) { lock (gate) if (otherClass.Contains(seq)) return; Change(() => otherClass.Add(seq)); }
  public bool IsOtherClass(ulong seq) { lock (gate) return otherClass.Contains(seq); }
}
