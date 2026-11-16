using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 16 Nov, the first real sign-in on Windows: a brand-new PC that only RECEIVES never commits a pack, so it never learned
// the service clock (commit receipt or clock_skew answer only) and every announcement it should write waited forever:
// with announcements on, the Cloud folder, artifacts and the delete rule stayed shut for every device of the account.
// Against the fixture service with the real service's 60 s signing window (CloudFakeService = worker user.ts clockWithin).
public sealed class CloudFreshPcClockTests
{
  private const string Subject = CloudFakeService.Subject;
  private const string Mac = "e3c75f30-363e-4323-a592-cf07fe14c4a6", Pc = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private long pcClockAhead;

  private (CloudSyncEngine Engine, CloudFeedClient Client, InMemoryDeckMemoryStore Memory) Device(string id, Func<long> clock)
  {
    var device = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk;
    var memory = new InMemoryDeckMemoryStore(Guid.NewGuid().ToString("D"));
    var adapter = new CloudMemoryAdapter(memory, new CloudMemorySlot(), id, localNow: clock, keeper: new CloudMemoryKeptInMemory());
    var store = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, clock,
      new CloudSyncBackoff(store, clock, _ => 0));
    return (new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [adapter], null, clock), client, memory);
  }

  private static DeckMemoryRow Note(string id, string path)
  {
    var t = DeckMemoryCloudSchema.Table("notes");
    var cells = Enumerable.Repeat(DeckMemoryCell.Null, t.Columns.Count).ToArray();
    cells[t.Index("id")] = DeckMemoryCell.Text(id); cells[t.Index("path")] = DeckMemoryCell.Text(path);
    cells[t.Index("title")] = DeckMemoryCell.Text("Weekly plan"); cells[t.Index("type")] = DeckMemoryCell.Text("note"); cells[t.Index("owner")] = DeckMemoryCell.Text("hoot");
    return new("notes", cells);
  }

  [Fact]
  public async Task A_PC_that_only_receives_knows_the_service_clock_announces_and_a_later_change_of_its_own_clock_does_not_move_it()
  {
    var mac = Device(Mac, () => service.Now);
    mac.Memory.WriteFile("hoot/notes/weekly-plan.md", Encoding.UTF8.GetBytes("# Weekly plan\n\nWater the seedlings.\n"));
    mac.Memory.PutRow(Note("weekly-plan", "hoot/notes/weekly-plan.md"), null);
    await mac.Engine.SyncAsync(default);
    var sent = service.Segments;
    Assert.True(sent > 0);

    var pc = Device(Pc, () => service.Now + pcClockAhead);
    Assert.Null(pc.Client.KnownServiceNow());
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // The PC received and sent nothing, so it learned no offset (the case the first real sign-in hit) ...
    Assert.Single(pc.Memory.Rows("notes"));
    Assert.Equal(sent, service.Segments);
    Assert.Null(pc.Client.ServiceOffset);
    // ... and still knows the service's time, within the service's own 60 s window.
    var known = Assert.IsType<long>(pc.Client.KnownServiceNow());
    Assert.InRange(known, service.Now - 60_000, service.Now + 60_000);

    // Its announcements are written now, not kept waiting.
    var announce = new CloudAnnounce(pc.Memory, () => Pc, pc.Client.KnownServiceNow, () => [Mac, Pc], new CloudMemorySlot());
    Assert.True(announce.Announce(CloudFolderFormat.Feature, CloudFolderFormat.Format, force: true));
    Assert.True(CloudAnnounce.Fresh(announce.Setting(CloudAnnounce.FeatureKey(CloudFolderFormat.Feature, Pc)), CloudFolderFormat.Format, service.Now));

    // The PC's own clock jumps two days ahead: the service clock it learned does not follow (taken once, counted forward
    // on the steady clock), so the 30-day Bin rule and the delete rule's gates are not moved by it.
    pcClockAhead = 2 * 86_400_000L;
    Assert.InRange(Assert.IsType<long>(pc.Client.KnownServiceNow()), service.Now - 60_000, service.Now + 60_000);
  }

  [Fact]
  public async Task Nothing_is_known_before_the_service_answered_and_a_refused_clock_is_never_taken()
  {
    // A PC clock ten minutes behind: the service refuses with clock_skew and states its time; the PC learns the real
    // offset from that answer (the precise way, unchanged), never its own wrong time.
    pcClockAhead = -600_000;
    var pc = Device(Pc, () => service.Now + pcClockAhead);
    Assert.Null(pc.Client.KnownServiceNow());
    await pc.Engine.SyncAsync(default);
    Assert.NotNull(pc.Client.ServiceOffset);
    Assert.InRange(Assert.IsType<long>(pc.Client.KnownServiceNow()), service.Now - 5_000, service.Now + 5_000);
  }
}
