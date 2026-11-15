using System.Security.Cryptography;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// W2: this PC's trusted-device list and the judged-apply loop, mirroring the Mac's P1/P2 proofs: an unknown device is
// held, a trusted one applies, an own-key claim with a wrong signature is refused, the feed never stops, held packs
// are released in their original order after trust, and a restart in the middle of a release resumes it.
// Keys are the golden vectors' test-only constants.
public sealed class CloudTrustStoreTests
{
  private const string Issuer = CloudWire.Issuer, Subject = "38fdae8d-01e6-432d-b2c9-d40fe9996b5f";
  private const string DeviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", DeviceB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", DeviceC = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private static readonly byte[] SignA = Convert.FromHexString("7111ce810a88d633693a92c43ec8c87c7d5d6159d2c7a2da3ca10e7b7bf778c1");
  private static readonly byte[] SignB = Convert.FromHexString("e37ecad29cfda4fcf0b6252fe421aaf112e101d65147dcc69e2f8e7423058a7b");
  private static readonly byte[] SignC = Convert.FromHexString("8f310222e8c47399caa554f9ae9d40a95716c4080b3fa4e9d051bf730bc9b9d0");

  private sealed class MemorySlot : ICloudTrustSlot, ICloudLedgerSlot
  {
    public byte[]? Bytes;
    public bool FailWrites;
    public byte[]? Read() => Bytes?.ToArray();
    public void Write(byte[] bytes) { if (FailWrites) throw new IOException("disk full"); Bytes = bytes.ToArray(); }
  }
  private sealed class Feed(List<CloudFeedEntry> entries) : ICloudFeed
  {
    public Task<IReadOnlyList<CloudFeedEntry>> ChangesAsync(ulong after, int limit, CancellationToken ct) =>
      Task.FromResult<IReadOnlyList<CloudFeedEntry>>(entries.Where(e => e.Seq > after).OrderBy(e => e.Seq).Take(limit).ToArray());
  }
  private sealed class Sink : ICloudPackSink
  {
    public readonly List<(ulong Seq, string Signer, bool Late)> Applied = [];
    public ulong? CrashAt;
    public ulong? CannotOpen;
    public Task ApplyAsync(CloudFeedEntry entry, CloudSegmentDescriptor descriptor, string signer, bool late, CancellationToken ct)
    {
      if (entry.Seq == CrashAt) throw new InvalidOperationException("the app stopped here");
      if (entry.Seq == CannotOpen) throw new CloudFailure("checksum_mismatch");
      Applied.Add((entry.Seq, signer, late));
      return Task.CompletedTask;
    }
  }

  private static CloudDeviceRegistration Registration(string deviceId, byte[] sign) =>
    new(deviceId, "Golden " + deviceId[..4], "windows", "0.0.0", CloudP256.PublicKey(sign), CloudP256.PublicKey(sign));
  /// A pack entry at `seq` that the feed attributes to `device`, signed with `signer`.
  private static CloudFeedEntry Pack(ulong seq, string device, byte[] signer, string subject = Subject)
  {
    var unsigned = new CloudSegmentDescriptor(CloudBytes.NewTransportId(), CloudBytes.NewTransportId(), "brain", "brain", ["memory"], 1,
      Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)), 1515, 2, "td-ops-1", "");
    using var key = CloudP256.Signer(signer);
    return new(seq, "brain", device, unsigned.Sign(subject, key));
  }
  private static CloudTrustStore Trust(MemorySlot slot, Func<bool>? pressRefused = null) => new(Issuer, Subject, slot, pressRefused ?? (() => false), () => 1_763_000_000_000);
  private static void Press(CloudTrustStore store, string deviceId, byte[] sign) =>
    store.Trust([CloudTrustCapture.Shown(deviceId, "Golden", CloudP256.PublicKey(sign))!], restore: false, latest: null);

  private sealed record World(MemorySlot TrustSlot, MemorySlot LedgerSlot, CloudTrustStore Store, List<CloudFeedEntry> Entries, Sink Sink, CloudJudgedFeed Engine);
  /// This PC is device A: its own key joins the list at sign-in.
  private static World NewWorld()
  {
    var trustSlot = new MemorySlot(); var ledgerSlot = new MemorySlot();
    var store = Trust(trustSlot);
    store.AddSelf(Registration(DeviceA, SignA));
    var entries = new List<CloudFeedEntry>(); var sink = new Sink();
    return new(trustSlot, ledgerSlot, store, entries, sink, new(Subject, "brain", new Feed(entries), sink, store, new CloudFeedLedger(ledgerSlot)));
  }
  private static CloudJudgedFeed Restarted(World world, Sink sink) =>
    new(Subject, "brain", new Feed(world.Entries), sink, Trust(world.TrustSlot), new CloudFeedLedger(world.LedgerSlot));

  [Fact]
  public async Task UnknownDeviceIsHeldUntouchedAndTheFeedGoesOn()
  {
    var w = NewWorld();
    w.Entries.AddRange([Pack(1, DeviceB, SignB), Pack(2, DeviceA, SignA)]);
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { (2UL, DeviceA, false) }, w.Sink.Applied);
    var held = Assert.Single(w.Engine.Ledger.Held);
    Assert.Equal((DeviceB, (ulong?)1UL, 1), (held.DeviceId, held.FirstSeq, held.Packs));
    Assert.Equal(2UL, w.Engine.Ledger.Cursor);
    Assert.Empty(w.Engine.Ledger.Refused);
  }

  [Fact]
  public async Task TrustedDeviceApplies()
  {
    var w = NewWorld();
    Press(w.Store, DeviceB, SignB);
    w.Entries.Add(Pack(1, DeviceB, SignB));
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { (1UL, DeviceB, false) }, w.Sink.Applied);
    Assert.Empty(w.Engine.Ledger.Held);
    Assert.Equal("click", w.Store.Entry(DeviceB)!.How);
    Assert.True(w.Store.HasDeviceTrustedByPress());
  }

  [Fact]
  public async Task OwnKeyClaimWithAWrongSignatureIsRefusedAndReported()
  {
    var w = NewWorld();
    // The feed names this PC's own device id, but C signed it; then a pack signed for another account; then a good one.
    w.Entries.AddRange([Pack(1, DeviceA, SignC), Pack(2, DeviceA, SignA, subject: DeviceB), Pack(3, DeviceA, SignA)]);
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { (3UL, DeviceA, false) }, w.Sink.Applied);
    Assert.Equal(new[] { (1UL, "bad-signature"), (2UL, "bad-signature") }, w.Engine.Ledger.Refused.Select(r => (r.Seq, r.Reason)));
    Assert.Empty(w.Engine.Ledger.Held);
  }

  [Fact]
  public async Task TheFeedNeverStops()
  {
    var w = NewWorld();
    Press(w.Store, DeviceB, SignB);
    var first = Pack(5, DeviceA, SignA);
    w.Entries.AddRange([
      Pack(1, DeviceC, SignC),                                // unknown device: held
      new CloudFeedEntry(2, "brain", null, null),             // no device: refused
      Pack(3, DeviceB, SignB) with { Descriptor = null },     // malformed: refused
      Pack(4, DeviceB, SignC),                                // trusted device, wrong key: refused
      first,
      Pack(6, DeviceA, SignA) with { Descriptor = first.Descriptor },  // the same pack at a new position: refused
      Pack(7, DeviceB, SignB),                                // trusted: applied
    ]);
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { 5UL, 7UL }, w.Sink.Applied.Select(a => a.Seq));
    Assert.Equal(new[] { (2UL, "no-device"), (3UL, "malformed"), (4UL, "bad-signature"), (6UL, "repeated-pack") }, w.Engine.Ledger.Refused.Select(r => (r.Seq, r.Reason)));
    Assert.Equal(DeviceC, Assert.Single(w.Engine.Ledger.Held).DeviceId);
    Assert.Equal(7UL, w.Engine.Ledger.Cursor);
    // Judging a refused position again only counts the check.
    await w.Engine.PullAsync(default);
    Assert.Equal(4, w.Engine.Ledger.Refused.Count);
  }

  [Fact]
  public async Task HeldPacksAreReleasedInTheirOriginalOrderAfterTrust()
  {
    var w = NewWorld();
    w.Entries.AddRange([Pack(1, DeviceB, SignB), Pack(2, DeviceA, SignA), Pack(3, DeviceB, SignB), Pack(4, DeviceA, SignA), Pack(5, DeviceB, SignB)]);
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { 2UL, 4UL }, w.Sink.Applied.Select(a => a.Seq));
    Assert.Equal(3, w.Engine.Ledger.HeldRow(DeviceB)!.Packs);

    Press(w.Store, DeviceB, SignB);
    await w.Engine.ReleaseHeldAsync([DeviceB], default);
    Assert.Equal(new[] { (1UL, DeviceB, true), (3UL, DeviceB, true), (5UL, DeviceB, true) }, w.Sink.Applied.Skip(2));
    Assert.Empty(w.Engine.Ledger.Held);

    w.Entries.Add(Pack(6, DeviceB, SignB));
    await w.Engine.PullAsync(default);
    Assert.Equal((6UL, DeviceB, false), w.Sink.Applied[^1]);
    Assert.Equal(6, w.Sink.Applied.Count);
  }

  [Fact]
  public async Task ANewerPackOfAWaitingDeviceReleasesTheOlderOnesFirst()
  {
    var w = NewWorld();
    w.Entries.AddRange([Pack(1, DeviceB, SignB), Pack(2, DeviceB, SignB)]);
    await w.Engine.PullAsync(default);
    // Trusted without a release call from the wiring: the next pull finds it.
    Press(w.Store, DeviceB, SignB);
    w.Entries.Add(Pack(3, DeviceB, SignB));
    await w.Engine.PullAsync(default);
    Assert.Equal(new[] { (1UL, DeviceB, true), (2UL, DeviceB, true), (3UL, DeviceB, false) }, w.Sink.Applied);
  }

  [Fact]
  public async Task ARestartInTheMiddleOfAReleaseResumesIt()
  {
    var w = NewWorld();
    w.Entries.AddRange([Pack(1, DeviceB, SignB), Pack(2, DeviceB, SignB), Pack(3, DeviceA, SignA), Pack(4, DeviceB, SignB)]);
    await w.Engine.PullAsync(default);
    Press(w.Store, DeviceB, SignB);
    w.Sink.CrashAt = 2;
    await Assert.ThrowsAsync<InvalidOperationException>(() => w.Engine.ReleaseHeldAsync([DeviceB], default));
    Assert.Equal(new[] { 3UL, 1UL }, w.Sink.Applied.Select(a => a.Seq));
    var row = w.Engine.Ledger.HeldRow(DeviceB)!;
    Assert.Equal(((ulong?)2UL, true), (row.FirstSeq, row.Releasing));

    // The app starts again: a new list, ledger and loop read from what was saved.
    var sink = new Sink();
    var engine = Restarted(w, sink);
    await engine.PullAsync(default);
    Assert.Equal(new[] { (2UL, DeviceB, true), (4UL, DeviceB, true) }, sink.Applied);
    Assert.Empty(engine.Ledger.Held);
    Assert.Equal(4UL, engine.Ledger.Cursor);
  }

  [Fact]
  public async Task APackThatCannotBeOpenedStopsOnlyThatDevicesRelease()
  {
    var w = NewWorld();
    w.Entries.AddRange([Pack(1, DeviceB, SignB), Pack(2, DeviceB, SignB), Pack(3, DeviceC, SignC)]);
    await w.Engine.PullAsync(default);
    Press(w.Store, DeviceB, SignB);
    w.Sink.CannotOpen = 2;
    await w.Engine.ReleaseHeldAsync([DeviceB], default);
    Assert.Equal(new[] { 1UL }, w.Sink.Applied.Select(a => a.Seq));
    Assert.Equal(((ulong?)2UL, false), (w.Engine.Ledger.HeldRow(DeviceB)!.FirstSeq, w.Engine.Ledger.HeldRow(DeviceB)!.Releasing));
    w.Entries.Add(Pack(4, DeviceA, SignA));
    await w.Engine.PullAsync(default);
    Assert.Contains(w.Sink.Applied, a => a.Seq == 4);
  }

  [Fact]
  public void TrustIsAddedOnlyByAPressAndNeverReplacesAKey()
  {
    var slot = new MemorySlot();
    var remote = true;
    var store = Trust(slot, () => remote);
    store.AddSelf(Registration(DeviceA, SignA));
    Assert.Equal("self", store.Entry(DeviceA)!.How);
    Assert.False(store.HasDeviceTrustedByPress());
    // A press that follows the app's own remote input is not the person's.
    Assert.Equal(CloudTrustRefusalKind.RemoteInput, Assert.Throws<CloudTrustRefusal>(() => Press(store, DeviceB, SignB)).Kind);
    Assert.Null(store.TrustedSigningKey(DeviceB));
    remote = false;
    Press(store, DeviceB, SignB);
    Assert.Equal(CloudP256.PublicKey(SignB), store.TrustedSigningKey(DeviceB));
    // Another key for a stored device, or a stored key for another device, is refused.
    Assert.Equal(CloudTrustRefusalKind.ListChanged, Assert.Throws<CloudTrustRefusal>(() => Press(store, DeviceB, SignC)).Kind);
    Assert.Equal(CloudTrustRefusalKind.SameKey, Assert.Throws<CloudTrustRefusal>(() => Press(store, DeviceC, SignB)).Kind);
    // A capture whose code does not belong to its key stores nothing.
    var forged = CloudTrustCapture.Shown(DeviceC, "Golden", CloudP256.PublicKey(SignC))! with { Code = CloudDeviceCode.Code(DeviceB, CloudP256.PublicKey(SignB))! };
    Assert.Throws<CloudTrustRefusal>(() => store.Trust([forged], false, null));
    // The newest device list can cancel a press.
    var capture = CloudTrustCapture.Shown(DeviceC, "Golden", CloudP256.PublicKey(SignC))!;
    Assert.Equal(CloudTrustRefusalKind.ListChanged, Assert.Throws<CloudTrustRefusal>(() => store.Trust([capture], false, [new(DeviceC, capture.KeyId, false, false, Removed: true)])).Kind);
    Assert.Null(store.TrustedSigningKey(DeviceC));
    // Saved and read back by a new instance (a restart).
    var again = Trust(slot);
    Assert.Equal(CloudP256.PublicKey(SignB), again.TrustedSigningKey(DeviceB));
    Assert.Equal(2, again.List().Revision);
  }

  [Fact]
  public async Task AnUnreadableOrForeignListTrustsNobodyAndPacksWait()
  {
    var w = NewWorld();
    Press(w.Store, DeviceB, SignB);
    // Another account's list in this slot: unreadable, so even this PC's own packs wait (fail safe).
    var foreign = new CloudTrustStore(Issuer, DeviceC, w.TrustSlot, () => false);
    Assert.Equal(CloudTrustRefusalKind.Unreadable, Assert.Throws<CloudTrustRefusal>(() => foreign.List()).Kind);
    Assert.Null(foreign.TrustedSigningKey(DeviceA));
    w.TrustSlot.Bytes![^2] ^= 0x01;
    var damaged = Trust(w.TrustSlot);
    Assert.Null(damaged.TrustedSigningKey(DeviceB));
    var engine = new CloudJudgedFeed(Subject, "brain", new Feed(w.Entries), w.Sink, damaged, new CloudFeedLedger(new MemorySlot()));
    w.Entries.Add(Pack(1, DeviceB, SignB));
    await engine.PullAsync(default);
    Assert.Empty(w.Sink.Applied);
    Assert.Equal(DeviceB, Assert.Single(engine.Ledger.Held).DeviceId);
    // A save that cannot be written changes nothing.
    var failing = new MemorySlot { FailWrites = true };
    Assert.Equal(CloudTrustRefusalKind.NotSaved, Assert.Throws<CloudTrustRefusal>(() => Trust(failing).AddSelf(Registration(DeviceA, SignA))).Kind);
  }

  [Fact]
  public void DeviceNamesAreCutToOnePlainLine()
  {
    Assert.Equal("Asad's PC", CloudTrustStore.PlainName("Asad's PC"));
    Assert.Equal("Laptop", CloudTrustStore.PlainName("Laptop BAFA 3267 21BB"));
    Assert.Equal("Laptop code", CloudTrustStore.PlainName("Laptop\ncode: BAFA326721BB30E08061"));
    Assert.Equal(CloudTrustStore.Unnamed, CloudTrustStore.PlainName("‮​"));
    Assert.Equal(new string('z', 40) + "…", CloudTrustStore.PlainName(new string('z', 50)));
    Assert.Equal(CloudTrustStore.Unnamed, CloudTrustStore.PlainName(new string('a', 50))); // all hex: reads as a code
  }
}
