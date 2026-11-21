using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 21 Nov 2026, the Mac 0.23.3 disk fault checked on Windows: project folders never record under 5 GB free, never run
// more than the cap ahead of the upload, hand the sync small batches (a large file over several captures, the very same
// records), the sync takes batch after batch in one round, and a received pack lets its sealed bytes go. Scratch only.
public sealed class ProjectFoldersDiskTests
{
  /// "p" + the first 16 hex of SHA-256("td-project-folders\nproject-deck") (as ProjectFoldersTravelTests).
  private const string Key = "p402830051885cc4d";
  private const string DeviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6";

  private static string Project(CloudFolderFixture f) => Path.Combine(f.Base, "a", "home", "My Project");
  private static CloudFolderOwner Owner(CloudFolderFixture f, CloudFileKind kind, Func<long?> free)
  {
    Directory.CreateDirectory(Project(f));
    var clock = f.Clock;
    var owner = new CloudFolderOwner(f.DeviceA, Path.Combine(f.Base, "a", "data", "root"), Path.Combine(f.Base, "a", "data", "project-folders"), f.Keeper("a"),
      () => true, kind, freeDisk: free, now: () => clock.Ms, roots: new CloudFolderRoots(new Dictionary<string, string> { [Key] = Project(f) }));
    owner.SetDeleteRuleAnnounced(_ => false);
    owner.MarkCloudRead();
    return owner;
  }
  private static void Write(CloudFolderFixture f, string path, byte[] bytes)
  {
    var full = CloudFolderDisk.Full(Project(f), path);
    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
    File.WriteAllBytes(full, bytes);
    File.SetLastWriteTimeUtc(full, DateTime.UnixEpoch.AddMilliseconds(f.Clock.Ms));
  }
  private static byte[] Bytes(int size, int seed) => Enumerable.Range(0, size).Select(i => (byte)((i * 7 + seed) % 251)).ToArray();
  private static int Rows(CloudFolderOwner owner) => owner.Core().JournalAfter(0).Count;
  private static string Wire(CloudOperation op) => Convert.ToBase64String(CloudCanonical.Encode(op.ToJson()));

  [Fact]
  public void Project_folders_keep_5_GB_free_stay_256_MB_ahead_and_go_in_2_MB_batches()
  {
    Assert.Equal(5L * 1_073_741_824, CloudFileKind.ProjectFolders.RecordFloorBytes);
    Assert.Equal(256L * 1_048_576, CloudFileKind.ProjectFolders.UnsentCapBytes);
    Assert.Equal(2L * 1_048_576, CloudFileKind.ProjectFolders.CaptureBytes);
    // The Cloud folder and artifacts are unchanged.
    Assert.Null(CloudFileKind.CloudFolder.RecordFloorBytes);
    Assert.Null(CloudFileKind.Artifacts.CaptureBytes);
  }

  [Fact]
  public async Task Under_5_GB_free_nothing_new_is_recorded_and_one_line_says_so()
  {
    using var f = new CloudFolderFixture();
    // Just over the floor, but not with the file's two more copies (the private copy and the retained bytes).
    long free = 5L * 1_073_741_824 + 100_000;
    Write(f, "notes/plan.bin", Bytes(60_000, 1));
    var owner = Owner(f, CloudFileKind.ProjectFolders, () => free);
    await f.Settle(owner);
    Assert.Equal(0, Rows(owner));
    Assert.Contains(CloudFolderOwner.RecordDiskLowLine, owner.PageLines());
    Assert.False(File.Exists(CloudFolderDisk.Full(owner.CopyRoot, Key + "/notes/plan.bin")));
    // Room again: it is recorded at the next look and the line goes.
    free = 500_000_000_000;
    f.Clock.Advance(4_000);
    await f.Settle(owner);
    Assert.Equal(1, Rows(owner));
    Assert.DoesNotContain(CloudFolderOwner.RecordDiskLowLine, owner.PageLines());
  }

  [Fact]
  public async Task Recording_waits_while_the_cap_is_not_yet_handed_to_the_sync()
  {
    using var f = new CloudFolderFixture();
    var kind = CloudFileKind.ProjectFolders with { UnsentCapBytes = 100_000, CaptureBytes = null };
    Write(f, "notes/one.bin", Bytes(60_000, 1));
    Write(f, "notes/two.bin", Bytes(60_000, 2));
    Write(f, "notes/three.bin", Bytes(60_000, 3));
    var owner = Owner(f, kind, () => 500_000_000_000);
    await f.Settle(owner);
    // The first file goes (the queue was empty); the next two would pass the cap.
    Assert.Equal(1, Rows(owner));
    // Handed to the sync: the next one is recorded, the last still waits.
    var capture = await owner.CaptureAsync(() => f.Clock.Ms, default);
    Assert.NotEmpty(capture.Operations);
    capture.Commit();
    f.Clock.Advance(4_000);
    await f.Settle(owner);
    Assert.Equal(2, Rows(owner));
  }

  [Fact]
  public async Task A_large_file_goes_in_batches_of_the_very_same_records_and_a_crash_repeats_the_batch()
  {
    using var f = new CloudFolderFixture();
    var kind = CloudFileKind.ProjectFolders with { CaptureBytes = 2L * CloudMemoryFormat.PartBytes };
    Write(f, "logs/big.bin", Bytes(5 * CloudMemoryFormat.PartBytes - 100, 3));
    Write(f, "notes/small.md", Bytes(10, 4));
    var owner = Owner(f, kind, () => 500_000_000_000);
    await f.Settle(owner);
    var engine = owner.Core();
    var expected = engine.JournalAfter(0).SelectMany(engine.Operations).Select(Wire).ToArray();
    Assert.Equal(6, expected.Length);
    Assert.True(owner.MoreToCapture);

    // A capture never committed (the app stopped before the queue was saved) gives the same batch again.
    var lost = await owner.CaptureAsync(() => f.Clock.Ms, default);
    var got = new List<string>();
    var sizes = new List<int>();
    for (var i = 0; i < 10 && owner.MoreToCapture; i++)
    {
      var capture = await owner.CaptureAsync(() => f.Clock.Ms, default);
      if (i == 0) Assert.Equal(lost.Operations.Select(Wire), capture.Operations.Select(Wire));
      sizes.Add(capture.Operations.Count);
      got.AddRange(capture.Operations.Select(Wire));
      capture.Commit();
    }
    Assert.Equal([2, 2, 2], sizes);
    Assert.Equal(expected, got);
    Assert.False(owner.MoreToCapture);
    Assert.Empty((await owner.CaptureAsync(() => f.Clock.Ms, default)).Operations);
  }

  /// A batched kind: one record per capture, more while any is left.
  private sealed class Batched(string deviceId) : ICloudSyncAdapter
  {
    private readonly List<CloudOperation> queued = [];
    public IReadOnlyCollection<string> Domains => ["brain/batch"];
    public long? CaptureBytes => 1;
    public bool MoreToCapture => queued.Count > 0;
    public int Left => queued.Count;
    public void Add(string text) => queued.Add(CloudOperation.Create(deviceId, "brain/batch", "entity-" + text, [], "put", new("test", text), 1_763_000_000_000,
      CloudJson.Obj(("text", CloudJson.From(text)))));
    public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
    {
      var taken = queued.Take(1).ToArray();
      return Task.FromResult(new CloudCapture(taken, () => queued.RemoveAll(taken.Contains)));
    }
    public Task ApplyAsync(CloudOperation operation, CloudImportOrigin origin, CancellationToken ct) => Task.CompletedTask;
  }

  [Fact]
  public async Task One_round_takes_batch_after_batch_while_the_queue_empties()
  {
    var service = new CloudFakeService();
    var device = new CloudTestDevice(DeviceA, service);
    var trust = new CloudTestTrust();
    trust.Trusted.TryAdd(DeviceA, device.Jwk);
    var store = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), CloudFakeService.Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), CloudFakeService.Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var batched = new Batched(DeviceA);
    foreach (var text in new[] { "one", "two", "three", "four", "five" }) batched.Add(text);
    var engine = new CloudSyncEngine(CloudFakeService.Subject, DeviceA, client, store, trust, device.Sign, [new CloudTestAdapter(DeviceA), batched], _ => { },
      () => service.Now);
    await engine.SyncAsync(default);
    Assert.Equal(0, batched.Left);
    Assert.Equal(5, service.Segments);
    Assert.Equal(0, store.QueuedCount);
  }

  [Fact]
  public void The_queue_counts_its_bytes_and_a_received_pack_lets_its_sealed_bytes_go()
  {
    var state = new CloudMemorySlot(); var ledger = new CloudMemorySlot();
    var store = new CloudSyncStore(state, ledger, CloudFakeService.Subject);
    CloudOperation[] ops = [CloudOperation.Create(DeviceA, "brain/test", "entity-one", [], "put", new("test", "one"), 1_763_000_000_000,
      CloudJson.Obj(("text", CloudJson.From("one"))))];
    store.Enqueue(ops);
    Assert.Equal(store.Outbox.Sum(r => (long)r.Bytes.Length), store.QueuedBytes(["brain/test"]));
    Assert.Equal(0, store.QueuedBytes(["project-folders"]));
    var sealedBytes = new byte[] { 1, 2, 3 };
    var descriptor = new CloudSegmentDescriptor(CloudBytes.NewTransportId(), CloudBytes.NewTransportId(), "brain", "brain", ["brain/test"], 1,
      CloudBytes.Sha256Hex(sealedBytes), sealedBytes.Length, 1, CloudPackFormat.Name, "");
    store.SaveSegment(new(descriptor, sealedBytes, [ops[0].OpId]));
    Assert.Equal(sealedBytes, store.Unacknowledged()!.Ciphertext);
    store.Acknowledge(descriptor.SegmentId, 7);
    Assert.Equal(0, store.QueuedBytes(["brain/test"]));
    Assert.Empty(store.Segment(descriptor.SegmentId)!.Ciphertext);
    var reloaded = new CloudSyncStore(state, ledger, CloudFakeService.Subject);
    Assert.Equal(7UL, reloaded.Segment(descriptor.SegmentId)!.ReceiptSeq);
    Assert.Empty(reloaded.Segment(descriptor.SegmentId)!.Ciphertext);
    Assert.True(reloaded.IsApplied(ops[0].OpId));
  }
}
