namespace TerminalDeck.Core.Cloud;

// The sync engine's secrets class (the Mac's CloudSyncEngine secretsDomains / secretsContent / pullSecretsOwned /
// retireOlderEpochProtected / reportApplied). Saved passwords share the feed but have their OWN position and their own
// judged loop (ledger `ledger-secrets.json`): memory goes on while they wait, and they never move memory's position.
// Their packs are sealed with the saved-passwords key (CloudSecretEnvelope, purpose of the kind: "secret", "browser",
// "ai-subscription"), at the key's generation; each record inside is itself sealed the same way. A pack of an older
// generation is recorded once as superseded (nobody can open it any more); a pack the service shows as locked to this PC
// is parked and looked at again. Nothing is read, sealed or sent while this PC does not hold the confirmed key.

/// What the engine needs for saved passwords: the content port (the confirmed key), the source owners, the slot of
/// the secrets feed's own ledger, and the lane that drives the hand-over (forgotten with the engine's keys).
public sealed record CloudSecretsClass(CloudSecretsContent Content, IReadOnlyList<CloudSecretsLogicalAdapter> Owners, ICloudLedgerSlot LedgerSlot,
  CloudSecretsLane? Lane = null);

public sealed partial class CloudSyncEngine
{
  public const string Superseded = "superseded", LockedHere = "locked";
  private readonly Dictionary<string, ICloudSyncAdapter> secretAdapters = new(StringComparer.Ordinal);
  private readonly List<ICloudSyncAdapter> secretOwners = [];
  private readonly HashSet<string> secretDomains = new(StringComparer.Ordinal);
  private CloudSecretsClass? secrets;
  /// The saved-passwords loop (null when this PC takes no saved passwords).
  public CloudJudgedFeed? SecretsFeed { get; private set; }

  private void UseSecrets(CloudSecretsClass? value)
  {
    if (value is null) return;
    secrets = value;
    foreach (var owner in value.Owners)
    {
      secretOwners.Add(owner);
      foreach (var domain in owner.Domains)
      {
        if (!CloudSecretsDomains.All.Contains(domain) || adapters.ContainsKey(domain) || !secretAdapters.TryAdd(domain, owner)) throw new CloudFailure("invalid_request");
        secretDomains.Add(domain);
      }
    }
    SecretsFeed = new CloudJudgedFeed(subject, "secrets", new LinkedFeed(this), new SecretsSink(this), trust, new CloudFeedLedger(value.LedgerSlot, now), PassOverSecret);
  }
  /// Whether an operation is still in this PC's outbox (gone = the Cloud took it).
  public bool StillQueued(string opId) => store.Outbox.Any(r => r.OpId == opId);

  /// A saved-password entry this PC must not judge: sealed under a key generation the current one replaced (recorded
  /// once, never retried), or shown locked to this PC (parked, looked at again).
  private string? PassOverSecret(CloudFeedEntry entry)
  {
    if (entry.Locked) return LockedHere;
    var current = secrets?.Content.State() is { Available: true } state ? state.Epoch : 0;
    return entry.Descriptor is { } d && current > 0 && d.KeyEpoch < current ? Superseded : null;
  }

  /// Nothing unsealed or of another class in the queue: every saved-password record is its own sealed envelope.
  private static void CheckSecretRecords(IEnumerable<CloudOperation> operations)
  {
    foreach (var op in operations)
    {
      var envelope = CloudContentEnvelope.FromJson(op.Payload);
      if (envelope.StorageClass != "secrets" || !CloudStorage.Permits(envelope.Purpose, "secrets") || envelope.Epoch <= 0
        || envelope.Purpose != CloudSecretsDomains.Purpose(op.Domain)) throw new CloudFailure("unsupported_format");
    }
  }
  private static string SecretsPackPurpose(IReadOnlyList<CloudOperation> batch)
  {
    var purposes = batch.Select(o => CloudContentEnvelope.FromJson(o.Payload).Purpose).Distinct().ToArray();
    return purposes.Length == 1 ? purposes[0] : throw new CloudFailure("unsupported_format");
  }

  /// The generation saved passwords are sent under now (0: they wait). Work sealed under an older generation is
  /// retired first: its packs are dropped unsent and its records leave the queue (the owners send them again under
  /// the new key by themselves, their "already sent" marks being per generation).
  private int SecretsEpochForSending()
  {
    if (secrets is null || secrets.Content.State() is not { Available: true } state) return 0;
    var current = state.Epoch;
    var old = store.Outbox.Where(r => secretDomains.Contains(r.Domain)).Where(r =>
    {
      try { return CloudContentEnvelope.FromJson(r.Operation.Payload).Epoch < current; } catch (CloudFailure) { return true; }
    }).Select(r => r.OpId).ToHashSet(StringComparer.Ordinal);
    while (store.Unacknowledged(s => s.Descriptor.StorageClass == "secrets" && s.Descriptor.KeyEpoch < current) is { } stale)
      store.RetireSegment(stale.Descriptor.SegmentId);
    if (old.Count > 0) store.DropQueued(r => old.Contains(r.OpId));
    return current;
  }

  /// The saved-passwords loop: only while this PC holds the confirmed key. Parked (locked) packs are looked at again.
  private async Task PullSecretsAsync(CancellationToken ct)
  {
    if (secrets is null || SecretsFeed is null || secrets.Content.State() is not { Available: true } state) return;
    await RetryParkedSecretsAsync(state.Epoch, ct);
    await SecretsFeed.PullAsync(ct);
  }
  private async Task RetryParkedSecretsAsync(int epoch, CancellationToken ct)
  {
    foreach (var row in SecretsFeed!.Ledger.Refused.Where(r => r.Reason == LockedHere && r.Checks < 24).Take(16).ToArray())
    {
      var page = await client.ChangesAsync(row.Seq - 1, 1, ct);
      if (page.Segments.FirstOrDefault() is not { } fresh || fresh.Seq != row.Seq) continue;
      links[fresh.Seq] = fresh;
      var entry = fresh.ToFeedEntry();
      if (PassOverSecret(entry) is { } reason) { SecretsFeed.Ledger.Refuse(row.Seq, row.DeviceId, reason, null); continue; }
      switch (SecretsFeed.Judge(entry))
      {
        case CloudPackVerdict.Apply apply:
          try { await ApplySecretsPackAsync(entry, apply.Descriptor, apply.Signer, late: true, ct); SecretsFeed.Ledger.MarkApplied(apply.Descriptor, row.Seq, null); }
          catch (CloudFailure failure) when (failure.Code is "checksum_mismatch" or "unsupported_format") { SecretsFeed.Ledger.Refuse(row.Seq, row.DeviceId, LockedHere, null); }
          break;
        case CloudPackVerdict.Refused refused: SecretsFeed.Ledger.Refuse(row.Seq, row.DeviceId, refused.Reason, null); break;
        case CloudPackVerdict.Held held: SecretsFeed.Ledger.Hold(held.Device, row.Seq, entry.Descriptor?.OpCount ?? 0, null); break;
      }
    }
  }

  private sealed class SecretsSink(CloudSyncEngine engine) : ICloudPackSink
  {
    public Task ApplyAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct) =>
      engine.ApplySecretsPackAsync(entry, descriptor, signer, late, ct);
  }

  /// One judged saved-password pack: checked against its signed hash, opened with the saved-passwords key, every record
  /// itself a sealed saved-password envelope of a domain this PC takes, applied by its owner. Idempotent.
  private async Task ApplySecretsPackAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct)
  {
    var content = secrets?.Content ?? throw new CloudFailure("secrets_locked");
    if (descriptor.StorageClass != "secrets" || !CloudStorage.Permits(descriptor.Purpose, "secrets") || descriptor.Domains.Count == 0 || descriptor.KeyEpoch <= 0
      || descriptor.Bytes is <= 0 or > CloudFeedClient.MaximumSegmentBytes || descriptor.OpCount is < 1 or > MaximumPackOps || descriptor.Format != CloudPackFormat.Name
      || descriptor.Domains.Any(d => !secretAdapters.ContainsKey(d))) throw new CloudFailure("unsupported_format");
    var bytes = await PackBytesAsync(entry, descriptor, ct);
    if (bytes.LongLength != descriptor.Bytes || CloudBytes.Sha256Hex(bytes) != descriptor.Sha256) throw new CloudFailure("checksum_mismatch");
    CloudContentEnvelope envelope;
    try { envelope = CloudContentEnvelope.Parse(bytes); } catch (CloudFailure) { throw new CloudFailure("unsupported_format"); }
    if (envelope.BlobId != descriptor.SegmentId || envelope.Epoch != descriptor.KeyEpoch || envelope.StorageClass != "secrets" || envelope.Purpose != descriptor.Purpose)
      throw new CloudFailure("checksum_mismatch");
    var operations = CloudPackFormat.Decode(content.Open(envelope));
    try { CheckSecretRecords(operations); } catch (CloudFailure) { throw new CloudFailure("unsupported_format"); }
    if (operations.Count != descriptor.OpCount || !operations.Select(o => o.Domain).ToHashSet().SetEquals(descriptor.Domains)
      || operations.Any(o => !secretAdapters.ContainsKey(o.Domain))) throw new CloudFailure("checksum_mismatch");
    var origin = new CloudImportOrigin(signer, entry.Seq, entry.CreatedAt, late);
    var done = new List<string>();
    var touched = new List<ICloudSyncAdapter>();
    foreach (var op in operations)
    {
      if (store.IsApplied(op.OpId)) continue;
      var owner = secretAdapters[op.Domain];
      if (!touched.Contains(owner)) touched.Add(owner);
      try { await owner.ApplyAsync(op, origin, ct); }
      catch (CloudFailure refused) when (refused.Code is "id_reused" or "invalid_request")
      {
        store.Set(RefusedRecordPrefix + op.OpId, refused.Code);
        log("cloud sync: a saved-password record was refused: " + refused.Code);
      }
      done.Add(op.OpId);
    }
    foreach (var owner in touched) await owner.SettleAsync(ct);
    store.MarkApplied(done);
  }

  /// POST /applied: both positions. While this PC is not approved for saved passwords, memory's is reported alone.
  private async Task ReportAppliedAsync(CancellationToken ct)
  {
    var cursor = adapters.Count > 0 ? Ledger.Cursor : (ulong)store.GetLong("reportedSeq");
    var secretsCursor = SecretsFeed?.Ledger.Cursor ?? 0;
    var reported = (ulong)store.GetLong("reportedSeq"); var reportedSecrets = (ulong)store.GetLong("reportedSecretsSeq");
    if (cursor <= reported && secretsCursor <= reportedSecrets) return;
    try
    {
      await client.AppliedAsync(cursor, Math.Max(secretsCursor, reportedSecrets), null, ct);
      store.SetLong("reportedSeq", (long)cursor); store.SetLong("reportedSecretsSeq", (long)Math.Max(secretsCursor, reportedSecrets));
    }
    catch (CloudFailure locked) when (CloudRefusal.Classify(locked) == CloudRefusalKind.SecretsLocked)
    {
      if (cursor <= reported) return;
      try { await client.AppliedAsync(cursor, reportedSecrets, null, ct); store.SetLong("reportedSeq", (long)cursor); } catch (CloudFailure) { }
    }
  }
}
