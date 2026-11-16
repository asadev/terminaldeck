using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// Saved passwords as records (the Mac's CloudSecretsLogical.swift CloudSecretsLogicalAdapter, CloudSecretsPolicy.swift
// CloudSecretsContent, and the driving half of BackendCloudSecretsWiring.swift's graph). One source per adapter, under
// its own domain. Each record travels sealed TWICE: on its own (a saved-passwords envelope as the record's payload, a
// fresh id each time) and in a saved-passwords pack. "Already sent" is a keyed fingerprint per record, written only
// once the Cloud took the pack, kept per key generation and per outbox identity, so a new generation sends everything
// again by itself and a lost queue never leaves an unchanged secret skipped. A removal travels only as a typed removal
// inside the seal, for an owner with a sealed Bin (CloudSecretsBin); a put relabelled as an archive is never authority.

public enum CloudApplyStatus { Applied, AlreadyPresent, KeptBoth, Blocked }

/// One source's own store (servers, API keys, ...). `Merge` must keep an existing DIFFERENT local value atomically
/// (the incoming one is kept sealed beside it). Capture throws `secrets_locked` while the owner is not ready.
public interface ICloudSecretsStore
{
  string SourceId { get; }
  string InventoryRow { get; }
  string Domain { get; }
  Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync();
  Task ValidateAsync(CloudSecretRecord record);
  Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record);
  Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome);
}

/// Keys a store needs beyond sealing (CloudSecretsStoreKeys): `Shared` is the same on every device holding this
/// generation's key (no device id in it); `Local` is this device's own AES key for what it keeps on its disk.
public sealed class CloudSecretsStoreKeys(int epoch, byte[] shared, byte[] local)
{
  public int Epoch { get; } = epoch;
  public byte[] Local { get; } = local;
  public string Shared(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(HMACSHA256.HashData(shared, bytes));
  public override string ToString() => "<saved-passwords store keys>";
}

/// A store whose record ids or local holdings need the account's keys. Null while the key is not here.
public interface ICloudSecretsKeyedStore { void UseKeys(CloudSecretsStoreKeys? keys); }

/// Only owners with a sealed local Bin take part in removals (CloudSecretsDeletingStore).
public interface ICloudSecretsDeletingStore : ICloudSecretsStore, ICloudSecretsKeyedStore
{
  Task<string?> VersionForUploadAsync(CloudSecretRecord record);
  Task<CloudApplyStatus> MergeVersionedAsync(CloudSecretRecord record, string version, string? removalGroup);
  Task<string?> RepublicationAsync(string recordId);
  Task<IReadOnlyList<CloudSecretRemoval>> CaptureRemovalsAsync();
  Task ValidateRemovalAsync(CloudSecretRemoval removal);
  Task<CloudApplyStatus> MergeRemovalAsync(CloudSecretRemoval removal);
  Task<bool> VerifyRemovalAsync(CloudSecretRemoval removal, CloudApplyStatus outcome);
}

/// Seals and opens with the confirmed key of the Cloud's current generation (CloudSecretsContent). Never while the key
/// waits for the Cloud's confirmation, never while the Cloud is at a newer generation, never one id twice.
public sealed class CloudSecretsContent(string subject, string deviceId, CloudSecretsHandover handover)
{
  private readonly HashSet<string> sealedIds = new(StringComparer.Ordinal);
  public sealed record ContentState(bool Available, int Epoch, string? Reason);
  public ContentState State()
  {
    if (handover.UsableKey() is { } key) return new(true, key.Epoch, null);
    var newer = handover.NewerCloudEpoch();
    return new(false, newer, newer > 0
      ? "Saved passwords were started anew on another device. They open again by themselves once one of your devices hands this PC the new key."
      : "Unlock saved passwords");
  }
  private CloudSecretsLocalKey Key(int? epoch) => handover.UsableKey(epoch) ?? throw new CloudFailure("secrets_locked");
  public CloudContentEnvelope Seal(byte[] bytes, string blobId, string purpose, int epoch, string codec)
  {
    if (!CloudStorage.Permits(purpose, "secrets")) throw new CloudFailure("unsupported_format");
    var key = Key(epoch);
    if (!sealedIds.Add(CloudBytes.Base64Url(CloudBytes.Uuid(blobId)))) throw new CloudFailure("id_reused");
    return CloudSecretEnvelope.Seal(bytes, key.Root, subject, blobId, purpose, epoch, codec);
  }
  public byte[] Open(CloudContentEnvelope envelope) => CloudSecretEnvelope.Open(envelope, Key(envelope.Epoch).Root, subject, envelope.Epoch);
  private static byte[] Derive(byte[] root, string info) => HKDF.DeriveKey(HashAlgorithmName.SHA256, root, 32, [], Encoding.UTF8.GetBytes(info));
  /// Keyed fingerprints for "already sent": derived per device id, source and generation, so a mark kept on disk is no
  /// oracle for guessing a short password, and marks of an earlier device id never match.
  public Func<byte[], string> Fingerprinter(string label, int epoch)
  {
    var key = Derive(Key(epoch).Root, $"TD-CLOUD-FINGERPRINT-2\n{deviceId}\n{label}\n{epoch.ToString(CultureInfo.InvariantCulture)}");
    return bytes => Convert.ToHexStringLower(HMACSHA256.HashData(key, bytes));
  }
  public CloudSecretsStoreKeys StoreKeys(string label, int epoch)
  {
    var root = Key(epoch).Root;
    return new(epoch, Derive(root, $"TD-CLOUD-SHARED-ID-1\n{label}\n{epoch.ToString(CultureInfo.InvariantCulture)}"),
      Derive(root, $"TD-CLOUD-DEVICE-HOLD-1\n{deviceId}\n{label}\n{epoch.ToString(CultureInfo.InvariantCulture)}"));
  }
}

/// AES-256-GCM in the combined form (12-byte nonce | ciphertext | 16-byte tag) under a device-local key: the sealed
/// holdings this PC keeps on its disk (the Bin, waiting arrivals). Only ciphertext is persisted.
public static class CloudSecretsLocalSeal
{
  public static byte[] Seal(ReadOnlySpan<byte> plain, byte[] key)
  {
    var nonce = RandomNumberGenerator.GetBytes(12);
    var (ciphertext, tag) = CloudContentCrypto.Seal(plain, key, nonce, []);
    return [.. nonce, .. ciphertext, .. tag];
  }
  public static byte[] Open(byte[] combined, byte[] key)
  {
    if (combined.Length < 28) throw new CloudFailure("checksum_mismatch");
    return CloudContentCrypto.Open(key, combined[..12], combined[12..^16], combined[^16..], []);
  }
}

/// Durable "already sent" marks per keyed slot and generation: keyed ids to keyed record fingerprints, plus records
/// queued but not yet taken by the Cloud. Neither a record, its id nor the source name is stored in clear.
public sealed class CloudSecretsKnownStore(string folder)
{
  private string Path(string slot) => System.IO.Path.Combine(folder, slot + ".json");
  public (Dictionary<string, string> Entries, Dictionary<string, string> Pending)? Load(string slot, int epoch)
  {
    try
    {
      if (!File.Exists(Path(slot)) || CloudJson.Parse(File.ReadAllBytes(Path(slot))) is not CloudJson.Object o || o["epoch"]?.AsInteger != epoch) return null;
      static Dictionary<string, string> Map(CloudJson? v) => v is CloudJson.Object m
        ? m.Members.Where(x => x.Value.AsString is not null).ToDictionary(x => x.Key, x => x.Value.AsString!, StringComparer.Ordinal) : new(StringComparer.Ordinal);
      return (Map(o["entries"]), Map(o["pending"]));
    }
    catch (Exception) { return null; }
  }
  public void Save(string slot, int epoch, IReadOnlyDictionary<string, string> entries, IReadOnlyDictionary<string, string> pending)
  {
    static CloudJson Obj(IReadOnlyDictionary<string, string> m) => CloudJson.Obj(m.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => (x.Key, (CloudJson?)CloudJson.From(x.Value))).ToArray());
    new CloudFileSlot(Path(slot)).Write(CloudCanonical.Encode(CloudJson.Obj(("epoch", CloudJson.From(epoch)), ("entries", Obj(entries)), ("pending", Obj(pending)))));
  }
}

/// One source owner. The engine calls it in the secrets class only (capture while the key is here, apply from
/// saved-passwords packs it opened). `queue`: the outbox's identity; `stillQueued`: whether an operation is still in
/// this PC's outbox (gone = the Cloud took it). `conflicts`: where an incoming value kept beside a different local one
/// is retained, still sealed.
public sealed class CloudSecretsLogicalAdapter : ICloudSyncAdapter
{
  public const int MaximumRecordPayloadBytes = 65_536, MaximumRecordBytes = 179_998;
  public const string OlderEpochWords = "Items saved before \"Start new saved passwords\" were skipped. They belong to the older archive.";
  public const string NotAppliedWords = "A removal from another device could not be checked, so nothing was removed here.";
  private readonly ICloudSecretsStore store;
  private readonly CloudSecretsContent content;
  private readonly string deviceId;
  private readonly CloudSecretsKnownStore? knownStore;
  private readonly Func<string?> queue;
  private readonly Func<string, bool> stillQueued;
  private readonly Action<CloudOperation> retainConflict;
  private readonly Action<string> log;
  private Dictionary<string, string> known = new(StringComparer.Ordinal);
  private int? knownEpoch; private string? knownQueue; private string? knownSlot; private bool knownDirty;
  private readonly Dictionary<string, (string Key, string Digest, int Epoch, string? Queue)> inFlight = new(StringComparer.Ordinal);
  private readonly Dictionary<string, string> tooLarge = new(StringComparer.Ordinal);
  private readonly Dictionary<string, int> notes = new(StringComparer.Ordinal);
  private readonly HashSet<string> settled = new(StringComparer.Ordinal);
  private string? failure;
  public string SourceId => store.SourceId;
  public string Domain => store.Domain;
  public IReadOnlyCollection<string> Domains { get; }

  public CloudSecretsLogicalAdapter(ICloudSecretsStore store, CloudSecretsContent content, string deviceId, CloudSecretsKnownStore? knownStore,
    Func<string?> queue, Func<string, bool> stillQueued, Action<CloudOperation>? retainConflict = null, Action<string>? log = null)
  {
    if (!CloudSecretsDomains.Admitted(store.SourceId, store.Domain)) throw new CloudFailure("invalid_request");
    this.store = store; this.content = content; this.deviceId = deviceId; this.knownStore = knownStore; this.queue = queue; this.stillQueued = stillQueued;
    this.retainConflict = retainConflict ?? (_ => { }); this.log = log ?? (_ => { });
    Domains = [store.Domain];
  }

  /// Plain words for records left on this PC (too large), and why the last capture did not go through.
  public IReadOnlyList<string> Gaps() => tooLarge.Values.Distinct().Order(StringComparer.Ordinal).Concat(failure is null ? [] : [failure]).ToArray();
  /// Plain reasons, with counts, for incoming items closed here without being applied.
  public IReadOnlyDictionary<string, int> Notices() => notes;
  public void ClearNotices() => notes.Clear();

  private sealed class Digest(Func<byte[], string> keyed)
  {
    public string Id(string recordId) => keyed([.. "id\n"u8, .. Encoding.UTF8.GetBytes(recordId)]);
    public string Slot(string sourceId) => keyed([.. "source\n"u8, .. Encoding.UTF8.GetBytes(sourceId)]);
    public string Record(byte[] plain) => keyed([.. "record\n"u8, .. plain]);
  }
  private Digest Marks(int epoch) => new(content.Fingerprinter(queue() is { } q ? SourceId + "\nqueue:" + q : SourceId, epoch));
  private static string WordsTooLarge(string domain) => (domain switch
  {
    CloudSecretsDomains.ApiKey => "An API key", CloudSecretsDomains.Server => "A server password or key", CloudSecretsDomains.Ssh => "An SSH file",
    CloudSecretsDomains.Mcp => "An MCP server", CloudSecretsDomains.TaskConnection => "A task connection token", CloudSecretsDomains.Receiver => "The Receiver's secrets",
    CloudSecretsDomains.BrowserCookies => "A browser sign-in", CloudSecretsDomains.BrowserPassword => "A saved browser password",
    CloudSecretsDomains.Project => "A project's secret settings", CloudSecretsDomains.App => "An app sign-in",
    CloudSecretsDomains.WhatsApp => "A WhatsApp agent's key", _ => "An AI subscription sign-in"
  }) + " is too large to save in Cloud. It stays on this PC.";

  /// Switch to `epoch` and the current queue: load their durable marks. Marks persist only with a queue identity.
  private void UseKnown(int epoch, Digest marks)
  {
    var q = queue();
    if (knownEpoch == epoch && knownQueue == q) return;
    knownEpoch = epoch; knownQueue = q; known = new(StringComparer.Ordinal); knownDirty = false; inFlight.Clear();
    knownSlot = q is null ? null : marks.Slot(SourceId);
    if (knownStore is null || knownSlot is null || knownStore.Load(knownSlot, epoch) is not { } saved) return;
    known = saved.Entries;
    foreach (var (op, value) in saved.Pending)
      if (value.Split('\n') is [var key, var digest]) inFlight[op] = (key, digest, epoch, q);
  }
  private void SetKnown(string key, string? value)
  {
    if (known.TryGetValue(key, out var old) ? old == value : value is null) return;
    if (value is null) known.Remove(key); else known[key] = value;
    knownDirty = true;
  }
  private void PersistKnown()
  {
    if (!knownDirty || knownStore is null || knownEpoch is not { } epoch || knownSlot is null) return;
    try { knownStore.Save(knownSlot, epoch, known, inFlight.ToDictionary(p => p.Key, p => p.Value.Key + "\n" + p.Value.Digest)); knownDirty = false; }
    catch (Exception) { }
  }
  /// The Cloud took these (they left the outbox): only now is "already sent" written.
  private void Confirm()
  {
    foreach (var (op, saved) in inFlight.ToArray())
    {
      if (stillQueued(op)) continue;
      inFlight.Remove(op); knownDirty = true;
      if (knownEpoch == saved.Epoch && knownQueue == saved.Queue) SetKnown(saved.Key, saved.Digest);
    }
  }

  private void ProvideKeys(CloudSecretsContent.ContentState state)
  {
    if (store is not ICloudSecretsKeyedStore keyed) return;
    CloudSecretsStoreKeys? keys = null;
    if (state.Available) try { keys = content.StoreKeys(SourceId, state.Epoch); } catch (CloudFailure) { }
    keyed.UseKeys(keys);
  }
  private void Check(CloudSecretRecord record)
  {
    if (record.SourceId != SourceId || record.Domain != Domain || record.RecordId.Length == 0) throw new CloudFailure("invalid_request");
  }
  private async Task<byte[]> EncodedAsync(CloudSecretRecord record)
  {
    if (store is ICloudSecretsDeletingStore owner && await owner.VersionForUploadAsync(record) is { } version)
      return CloudCanonical.Encode(new CloudSecretVersionedPut(record, version, await owner.RepublicationAsync(record.RecordId)).ToJson());
    return record.Canonical();
  }
  private static bool Fits(CloudOperation op) => CloudCanonical.Encode(op.Payload).Length <= MaximumRecordPayloadBytes && CloudCanonical.Encode(op.ToJson()).Length <= MaximumRecordBytes;

  /// What this source exports now, checked (the sealed shelf and the counts read this too). Locked: throws.
  public async Task<IReadOnlyList<CloudSecretRecord>> ExportRecordsAsync()
  {
    var state = content.State();
    ProvideKeys(state);
    if (!state.Available) throw new CloudFailure("secrets_locked");
    var records = await store.CaptureAsync();
    if (records.Select(r => r.RecordId).Distinct(StringComparer.Ordinal).Count() != records.Count) throw new CloudFailure("id_reused");
    foreach (var record in records) { Check(record); await store.ValidateAsync(record); }
    return records;
  }

  public async Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    var state = content.State();
    if (!state.Available) return CloudCapture.None;
    IReadOnlyList<CloudSecretRecord> rows;
    try { rows = await ExportRecordsAsync(); failure = null; }
    catch (CloudFailure locked) when (locked.Code == "secrets_locked") { return CloudCapture.None; }
    catch (Exception error) when (error is not OperationCanceledException)
    {
      // Never stops the other sources: this one is named on the page and tried again at the next round.
      failure = "Not saved to Cloud from this PC: " + SourceId + ". It is tried again at the next sync.";
      log("saved passwords: a source could not be read: " + SourceId);
      return CloudCapture.None;
    }
    var marks = Marks(state.Epoch);
    UseKnown(state.Epoch, marks);
    Confirm();
    foreach (var id in tooLarge.Keys.ToArray()) if (rows.All(r => r.RecordId != id)) tooLarge.Remove(id);
    var waiting = inFlight.Values.Where(v => v.Epoch == state.Epoch && v.Queue == knownQueue).Select(v => v.Key + "\n" + v.Digest).ToHashSet(StringComparer.Ordinal);
    var operations = new List<CloudOperation>();
    var outgoing = new Dictionary<string, (string Key, string Digest)>(StringComparer.Ordinal);
    var at = stampNow();
    var purpose = CloudSecretsDomains.Purpose(Domain);
    foreach (var record in rows)
    {
      var plain = await EncodedAsync(record);
      var key = marks.Id(record.RecordId); var value = marks.Record(plain);
      if (known.TryGetValue(key, out var k) && k == value || waiting.Contains(key + "\n" + value)) continue;
      var op = Operation(record.RecordId, "put", plain, purpose, state.Epoch, at);
      if (!Fits(op)) { tooLarge[record.RecordId] = WordsTooLarge(Domain); continue; }
      tooLarge.Remove(record.RecordId);
      outgoing[op.OpId] = (key, value); operations.Add(op);
    }
    if (store is ICloudSecretsDeletingStore owner)
    {
      foreach (var removal in await owner.CaptureRemovalsAsync())
      {
        await owner.ValidateRemovalAsync(removal);
        var plain = removal.Canonical();
        var key = marks.Id(removal.RecordId); var value = marks.Record(plain);
        if (known.TryGetValue(key, out var k) && k == value || waiting.Contains(key + "\n" + value)) continue;
        var op = Operation(removal.RecordId, "archive", plain, purpose, state.Epoch, at);
        if (!Fits(op)) throw new CloudFailure("invalid_request");
        outgoing[op.OpId] = (key, value); operations.Add(op);
      }
    }
    PersistKnown();
    var epoch = state.Epoch; var q = knownQueue;
    return new(operations, () =>
    {
      // Queued is not sent: the mark waits for the Cloud (Confirm). A record queued for another queue or generation is
      // simply sent again.
      foreach (var (op, saved) in outgoing) if (knownEpoch == epoch && knownQueue == q) { inFlight[op] = (saved.Key, saved.Digest, epoch, q); knownDirty = true; }
      PersistKnown();
    });
  }
  private CloudOperation Operation(string recordId, string kind, byte[] plain, string purpose, int epoch, long at)
  {
    var envelope = content.Seal(plain, CloudBytes.NewTransportId(), purpose, epoch, "identity");
    var payload = envelope.ToJson();
    var id = CloudBytes.NewTransportId();
    return new(1, id, deviceId, Domain, recordId, id, [], kind, null, null, new(SourceId, recordId), at, payload, CloudOperation.PayloadHashOf(payload));
  }

  private void Note(string reason) => notes[reason] = notes.GetValueOrDefault(reason) + 1;

  public async Task ApplyAsync(CloudOperation op, CloudImportOrigin origin, CancellationToken ct)
  {
    var state = content.State();
    ProvideKeys(state);
    if (!state.Available) throw new CloudFailure("secrets_locked");
    if (op.V != 1 || op.Domain != Domain || op.Source.SourceId != SourceId || op.EntityId != op.Source.RecordId
      || CloudOperation.PayloadHashOf(op.Payload) != op.PayloadHash) throw new CloudFailure("invalid_request");
    var marks = Marks(state.Epoch);
    UseKnown(state.Epoch, marks);
    var purpose = CloudSecretsDomains.Purpose(Domain);
    if (op.Kind != "put")
    {
      // Every other kind and EVERY failure while opening a removal ends with a final "not applied": nothing runs and the
      // feed never stalls. Only "locked right now" retries. A removal is authority only when it opens under the
      // saved-passwords key as a typed removal of this source, for an owner with a sealed Bin.
      if (op.Kind != "archive" || store is not ICloudSecretsDeletingStore owner) { Note(NotAppliedWords); return; }
      CloudSecretRemoval removal; byte[] plain;
      try
      {
        var envelope = CloudContentEnvelope.FromJson(op.Payload);
        if (envelope.StorageClass != "secrets" || envelope.Purpose != purpose) throw new CloudFailure("invalid_request");
        if (envelope.Epoch < state.Epoch) { Note(OlderEpochWords); return; }
        plain = content.Open(envelope);
        removal = CloudSecretRemoval.FromJson(CloudJson.Parse(plain));
        if (removal.SourceId != SourceId || removal.Domain != Domain || removal.RecordId != op.EntityId) throw new CloudFailure("invalid_request");
        await owner.ValidateRemovalAsync(removal);
      }
      catch (CloudFailure locked) when (locked.Code == "secrets_locked") { throw; }
      catch (Exception error) when (error is not OperationCanceledException) { Note(NotAppliedWords); return; }
      settled.Remove(removal.RecordId);
      CloudApplyStatus outcome;
      try
      {
        outcome = await owner.MergeRemovalAsync(removal);
        if (outcome == CloudApplyStatus.Blocked || !await owner.VerifyRemovalAsync(removal, outcome)) throw new CloudFailure("checksum_mismatch");
      }
      catch (CloudFailure locked) when (locked.Code == "secrets_locked") { throw; }
      catch (Exception error) when (error is not OperationCanceledException) { Note(NotAppliedWords); return; }
      SetKnown(marks.Id(removal.RecordId), marks.Record(removal.Canonical()));
      PersistKnown();
      return;
    }
    var sealedEnvelope = CloudContentEnvelope.FromJson(op.Payload);
    if (sealedEnvelope.StorageClass != "secrets" || sealedEnvelope.Purpose != purpose) throw new CloudFailure("invalid_request");
    if (sealedEnvelope.Epoch < state.Epoch) { Note(OlderEpochWords); return; }
    var opened = content.Open(sealedEnvelope);
    var parsed = CloudJson.Parse(opened);
    CloudSecretRecord record;
    var versioned = CloudSecretVersionedPut.TryFromJson(parsed);
    if (versioned is not null)
    {
      if (store is not ICloudSecretsDeletingStore || !CloudDeleteText.IsUuid(versioned.Version) || versioned.RemovalGroup is { } g && !CloudDeleteText.IsUuid(g))
      { Note(NotAppliedWords); return; }
      record = versioned.Record;
    }
    else record = CloudSecretRecord.FromJson(parsed);
    if (record.RecordId != op.EntityId) throw new CloudFailure("invalid_request");
    Check(record);
    await store.ValidateAsync(record);
    var result = versioned is not null && store is ICloudSecretsDeletingStore deleting
      ? await deleting.MergeVersionedAsync(record, versioned.Version, versioned.RemovalGroup) : await store.MergeAsync(record);
    if (result == CloudApplyStatus.Blocked || !await store.VerifyAsync(record, result)) throw new CloudFailure("checksum_mismatch");
    if (result == CloudApplyStatus.KeptBoth)
    {
      // The incoming value stays sealed beside his; his own value goes up again at the next capture (its mark differs).
      retainConflict(op);
      return;
    }
    SetKnown(marks.Id(record.RecordId), marks.Record(opened));
    settled.Add(record.RecordId);
    PersistKnown();
  }

  /// After a pack: an owner may keep an imported value in its own normal form, so what is now on this PC is remembered
  /// and not sent back as a change; an entry that is gone is forgotten (never "already sent").
  public async Task SettleAsync(CancellationToken ct)
  {
    if (settled.Count == 0) return;
    var ids = settled.ToArray(); settled.Clear();
    var state = content.State();
    if (!state.Available || knownEpoch != state.Epoch) return;
    var marks = Marks(state.Epoch);
    IReadOnlyList<CloudSecretRecord> rows;
    try { rows = await store.CaptureAsync(); } catch (Exception) { return; }
    foreach (var id in ids)
    {
      if (rows.FirstOrDefault(r => r.RecordId == id) is { } row) SetKnown(marks.Id(id), marks.Record(await EncodedAsync(row)));
      else if (store is not ICloudSecretsDeletingStore) SetKnown(marks.Id(id), null);
    }
    PersistKnown();
  }

  /// Signed out, Cloud off, or the key changed hands: nothing stays in memory.
  public void Seal()
  {
    (store as ICloudSecretsKeyedStore)?.UseKeys(null);
    known.Clear(); inFlight.Clear(); tooLarge.Clear(); notes.Clear(); settled.Clear(); knownEpoch = null; knownQueue = null; knownSlot = null;
  }
}

/// Where an incoming value kept beside a different local one is retained, still sealed (it is never discarded).
public sealed class CloudSecretsKeptConflicts(string folder)
{
  public void Keep(CloudOperation op)
  {
    try { new CloudFileSlot(Path.Combine(folder, op.OpId + ".json")).Write(CloudCanonical.Encode(op.ToJson())); } catch (Exception) { }
  }
}

/// The driving half (the Mac's BackendCloudSecretsGraph): at start, on the account's notices (`hello`, `vault`,
/// `approval`, `devices`) and on each sync round, never on a timer of its own. Saved passwords are ON by default: the
/// account's FIRST device makes the key by itself; any later device asks by itself and opens when one answers; a
/// device holding the key answers every request that passes the checks; a key change is taken or made.
public sealed class CloudSecretsLane(CloudSecretsHandover handover, IReadOnlyList<CloudSecretsLogicalAdapter> adapters, Action poke, Func<long>? now = null,
  Action<string>? log = null)
{
  private readonly Func<long> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
  private readonly Action<string> log = log ?? (_ => { });
  private readonly SemaphoreSlim gate = new(1, 1);
  public CloudSecretsHandover Handover { get; } = handover;
  public IReadOnlyList<CloudSecretsLogicalAdapter> Adapters { get; } = adapters;
  private bool startSaid;

  private async Task Serial(Func<Task> work)
  {
    await gate.WaitAsync();
    try { await work(); }
    catch (OperationCanceledException) { }
    catch (Exception error) when (error is not OutOfMemoryException) { log("saved passwords: a step did not finish: " + CloudAccountClient.Kind(error)); }
    finally { gate.Release(); }
  }

  /// At start: finish an unconfirmed key, or (key here) send what changed and answer waiting requests, or open.
  public Task CatchUpAsync() => Serial(async () =>
  {
    switch (Handover.Protection())
    {
      case CloudSecretsProtection.WaitingForCloud: if (await Handover.ConfirmPendingAcknowledgementAsync()) poke(); break;
      case CloudSecretsProtection.Protected: await LookAtKeyChangeAsync(); poke(); await Handover.AnswerAllAsync(); break;
      default: await OpenBySelfAsync(); break;
    }
    if (!startSaid) { startSaid = true; log("saved passwords: at start: " + Handover.Protection().ToString().ToLowerInvariant()); }
  });

  /// Every sync round: a PC still without the key asks again by itself once its request ran out.
  public Task RoundAsync() => Serial(async () =>
  {
    if (Handover.Protection() == CloudSecretsProtection.Locked) await OpenBySelfAsync();
  });

  /// The account's notices, on the signed-in, device-proved socket only.
  public Task EventAsync(string type, CloudJson payload) => Serial(async () =>
  {
    if (type is "approval" or "devices")
    {
      if (type == "devices")
      {
        if (Handover.Protection() == CloudSecretsProtection.Locked) await OpenBySelfAsync();
        await LookAtKeyChangeAsync();
      }
      await AnswerSoonAsync();
      return;
    }
    if (type == "hello")
    {
      switch (Handover.Protection())
      {
        case CloudSecretsProtection.Protected: await LookAtKeyChangeAsync(); poke(); await Handover.AnswerAllAsync(); break;
        case CloudSecretsProtection.Locked: await OpenBySelfAsync(); break;
      }
      return;
    }
    if (type != "vault") return;
    if (payload is CloudJson.Object o && o["epoch"]?.AsInteger is { } epoch and > 0) Handover.NoteCloudEpoch((int)epoch);
    switch (Handover.Protection())
    {
      case CloudSecretsProtection.Locked:
        try { if (await Handover.ReceiveApprovalAsync()) poke(); }
        catch (Exception error) when (error is not OperationCanceledException)
        {
          if (Handover.WaitingRequest is not null) log("saved passwords: taking the answer did not finish: " + CloudAccountClient.Kind(error));
        }
        break;
      case CloudSecretsProtection.WaitingForCloud: if (await Handover.ConfirmPendingAcknowledgementAsync()) poke(); break;
      default:
        // This PC asked for the NEW key after a key change (no copy was sealed for it): the notice is its answer.
        if (await Handover.KeyBehindAsync() && Handover.WaitingRequest is not null)
        {
          try { if (await Handover.ReceiveApprovalAsync()) poke(); }
          catch (Exception error) when (error is not OperationCanceledException) { log("saved passwords: taking the new key did not finish: " + CloudAccountClient.Kind(error)); }
        }
        await LookAtKeyChangeAsync();
        break;
    }
  });

  /// A request or a device change: answer now, and look twice more a moment later when something was left (this PC's
  /// trusted list takes in a newly joined device a few seconds after the service lists it).
  internal Func<long, Task> Pause { get; set; } = ms => Task.Delay(TimeSpan.FromMilliseconds(ms));
  private async Task AnswerSoonAsync()
  {
    for (var attempt = 0; attempt < 3; attempt++)
    {
      if (!await Handover.AnswerAllAsync()) break;
      if (attempt < 2) await Pause(5_000);
    }
  }

  /// The account's first device makes the key by itself; otherwise this PC's own unfinished set-up opens, or it asks.
  private async Task OpenBySelfAsync()
  {
    CloudSecretsStatus status;
    try { status = await Handover.StatusAsync(); } catch (Exception) { return; }
    if (status.State == CloudSecretsStatus.Unset)
    {
      log("saved passwords: turning on: nothing in Cloud yet, this PC sets the Cloud copy up");
      try { await Handover.SetupSilentlyAsync(); poke(); await Handover.AnswerAllAsync(); return; }
      catch (Exception error) when (error is not OperationCanceledException)
      {
        log("saved passwords: turning on did not finish: " + CloudAccountClient.Kind(error));
        try { if ((await Handover.StatusAsync()).State != CloudSecretsStatus.Ready || Handover.Protection() != CloudSecretsProtection.Locked) return; }
        catch (Exception) { return; }
      }
    }
    try { if (await Handover.ReopenOwnCopyAsync()) { poke(); await Handover.AnswerAllAsync(); return; } } catch (Exception) { }
    await AskBySelfAsync();
  }
  /// One request at a time, asked again by itself after it ran out (10 minutes), never a sheet.
  private async Task AskBySelfAsync()
  {
    if (Handover.Protection() != CloudSecretsProtection.Locked) return;
    if (Handover.WaitingRequest is { } waiting && waiting.ExpiresAt > now()) return;
    try { await Handover.RequestApprovalAsync(); log("saved passwords: asked your other devices; waiting for one to answer by itself"); }
    catch (Exception error) when (error is not OperationCanceledException) { log("saved passwords: asking your other devices did not go out: " + CloudAccountClient.Kind(error)); }
  }
  /// Take the new key's copy, or make the due key change here; behind with no copy: ask, as a new device does.
  private async Task LookAtKeyChangeAsync()
  {
    if (Handover.Protection() != CloudSecretsProtection.Protected) return;
    try
    {
      switch (await Handover.KeyChangeAsync())
      {
        case CloudSecretsKeyChange.Rotated or CloudSecretsKeyChange.TookCopy: poke(); break;
        default:
          if (!await Handover.KeyBehindAsync() || Handover.WaitingRequest is { } w && w.ExpiresAt > now()) return;
          try { await Handover.RequestApprovalAsync(); log("saved passwords: asked your other devices for the new key"); }
          catch (Exception error) when (error is not OperationCanceledException) { log("saved passwords: asking for the new key did not go out: " + CloudAccountClient.Kind(error)); }
          break;
      }
    }
    catch (OperationCanceledException) { }
    catch (Exception error) { log("saved passwords: the key change did not finish: " + CloudAccountClient.Kind(error)); }
  }

  /// Signed out, Cloud off: every adapter forgets what it holds in memory.
  public void Seal() { foreach (var adapter in Adapters) adapter.Seal(); }
}
