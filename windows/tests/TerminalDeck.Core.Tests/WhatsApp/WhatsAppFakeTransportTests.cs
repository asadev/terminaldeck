using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsApp;

/// The Mac's WhatsAppFakeTransportTests.swift, case for case.
public sealed class WhatsAppFakeTransportTests
{
  private static WhatsAppInbound Text(string body, string id) => WhatsAppFakeTransport.Text(body, id);

  [Fact]
  public async Task OffsetsFollowWhatsAppsRules()
  {
    var fake = new WhatsAppFakeTransport();
    fake.AddBacklog([Text("old", "w1")]);
    fake.Deliver(Text("new 1", "w2"), Text("new 2", "w3"));
    Assert.Equal(new WhatsAppPoll.Messages([Text("new 1", "w2"), Text("new 2", "w3")], 4), await fake.PollAsync("k", null, 25));
    var backlog = Assert.IsType<WhatsAppPoll.Messages>(await fake.PollAsync("k", 0, 25));
    Assert.Equal(4, backlog.Next);
    Assert.Equal(new[] { "w1", "w2", "w3" }, backlog.Items.Select(m => m.Id));
    Assert.IsType<WhatsAppPoll.Nothing>(await fake.PollAsync("k", 4, 25));
    var again = Assert.IsType<WhatsAppPoll.Messages>(await fake.PollAsync("k", 2, 25));
    Assert.Equal(new[] { "w2", "w3" }, again.Items.Select(m => m.Id)); // polling does not consume
    Assert.Equal(4, again.Next);
    Assert.Equal(new long?[] { null, 0, 4, 2 }, fake.Polls.Select(p => p.Offset));
  }

  [Fact]
  public async Task APollReturnsAtMostFifty()
  {
    var fake = new WhatsAppFakeTransport();
    fake.Deliver(Enumerable.Range(1, 70).Select(i => Text("m" + i, "w" + i)));
    var first = Assert.IsType<WhatsAppPoll.Messages>(await fake.PollAsync("k", 1, 25));
    Assert.Equal(50, first.Items.Count);
    Assert.Equal(51, first.Next);
  }

  [Fact]
  public async Task VirtualTimeMovesOnlyWhenTold()
  {
    var fake = new WhatsAppFakeTransport();
    await fake.PollAsync("k", 1, 25);
    Assert.Equal(25, fake.Now); // an empty long-poll takes its timeout, virtually
    fake.Advance(10);
    await fake.SendAsync("k", "user:1000", "hi");
    Assert.Equal(35, fake.Now);
    Assert.Equal(new[] { new WhatsAppFakeTransport.SentText("k", "user:1000", "hi", 35) }, fake.Sent);
  }

  [Fact]
  public async Task ScriptedOutcomesComeFirstInOrder()
  {
    var fake = new WhatsAppFakeTransport();
    fake.ScriptPolls([new WhatsAppPoll.BackOff(2), WhatsAppPoll.Refused]);
    fake.ReplaceNextPoll();
    fake.ScriptSends([new WhatsAppSent.BackOff(4), new WhatsAppSent.Failed("x")]);
    fake.ScriptReads([WhatsAppSent.NotTheCreator]);
    fake.ScriptChecks([WhatsAppKeyCheck.Unreachable]);
    var polls = new List<WhatsAppPoll>();
    for (var i = 0; i < 4; i++) polls.Add(await fake.PollAsync("k", 1, 0));
    Assert.Equal(new WhatsAppPoll[] { new WhatsAppPoll.BackOff(2), WhatsAppPoll.Refused, WhatsAppPoll.ReplacedByNewer, WhatsAppPoll.NothingNew }, polls);
    var sends = new[] { await fake.SendAsync("k", "user:1000", "a"), await fake.SendAsync("k", "user:1000", "b"), await fake.SendAsync("k", "user:1000", "c") };
    Assert.Equal(new WhatsAppSent[] { new WhatsAppSent.BackOff(4), new WhatsAppSent.Failed("x"), WhatsAppSent.Done }, sends);
    Assert.Equal(new[] { "c" }, fake.SentTexts); // only what was really sent is recorded
    var reads = new[] { await fake.MarkReadAsync("k", "w1", true), await fake.MarkReadAsync("k", "w2", false) };
    Assert.Equal(new[] { WhatsAppSent.NotTheCreator, WhatsAppSent.Done }, reads);
    Assert.Equal(new[] { "w2" }, fake.Reads.Select(r => r.MessageId));
    Assert.Equal(new[] { WhatsAppKeyCheck.Unreachable, WhatsAppKeyCheck.Accepted }, new[] { await fake.CheckAsync("k"), await fake.CheckAsync("k") });
  }

  [Fact]
  public async Task ARefusedKeyIsRefusedEverywhere()
  {
    var fake = new WhatsAppFakeTransport();
    fake.Refuse("bad");
    Assert.Equal(WhatsAppKeyCheck.Refused, await fake.CheckAsync("bad"));
    Assert.IsType<WhatsAppPoll.KeyRefused>(await fake.PollAsync("bad", null, 25));
    Assert.IsType<WhatsAppSent.KeyRefused>(await fake.SendAsync("bad", "user:1000", "x"));
    Assert.IsType<WhatsAppSent.KeyRefused>(await fake.MarkReadAsync("bad", "w", false));
    fake.Accept("bad");
    Assert.Equal(WhatsAppKeyCheck.Accepted, await fake.CheckAsync("bad"));
  }

  [Fact]
  public async Task OnlyTheCreatorCanBeAddressedAndTooLongIsRefused()
  {
    var fake = new WhatsAppFakeTransport(creator: "user:42");
    Assert.IsType<WhatsAppSent.NotCreator>(await fake.SendAsync("k", "user:43", "x"));
    Assert.IsType<WhatsAppSent.Failed>(await fake.SendAsync("k", "user:42", new string('a', 4097)));
    Assert.Empty(fake.Sent);
  }

  [Fact]
  public async Task LimitsWhenEnforced()
  {
    var fake = new WhatsAppFakeTransport();
    fake.EnforceLimits();
    for (var i = 0; i < 12; i++) await fake.SendAsync("k", "user:1000", i.ToString(System.Globalization.CultureInfo.InvariantCulture));
    Assert.Equal(new WhatsAppSent.BackOff(60), await fake.SendAsync("k", "user:1000", "13"));
    fake.Advance(60);
    Assert.IsType<WhatsAppSent.Sent>(await fake.SendAsync("k", "user:1000", "13"));
  }

  [Fact]
  public async Task MediaRespectsTheLimit()
  {
    var fake = new WhatsAppFakeTransport();
    var picture = new WhatsAppMedia(new byte[100], "image/jpeg");
    fake.SetMedia("m1", picture);
    Assert.Equal(picture, await fake.MediaAsync("k", "m1", 100));
    Assert.Null(await fake.MediaAsync("k", "m1", 99));
    Assert.Null(await fake.MediaAsync("k", "m2", 100));
    Assert.Equal(new[] { "m1", "m1", "m2" }, fake.MediaFetches);
  }

  [Fact]
  public async Task ItIsAWhatsAppTransport()
  {
    IWhatsAppTransport transport = new WhatsAppFakeTransport();
    Assert.Equal(WhatsAppKeyCheck.Accepted, await transport.CheckAsync("k"));
  }

  // ---- ours -----------------------------------------------------------------------------------------------

  [Fact]
  public async Task VirtualClockNeverSleeps()
  {
    var clock = new WhatsAppVirtualClock(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
    var started = DateTime.UtcNow;
    await clock.DelayAsync(TimeSpan.FromHours(3), CancellationToken.None);
    Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
    Assert.Equal(new DateTimeOffset(2026, 1, 1, 3, 0, 0, TimeSpan.Zero), clock.Now);
    Assert.Equal(TimeSpan.FromHours(3), clock.TotalDelayed);
    using var cts = new CancellationTokenSource();
    cts.Cancel();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => clock.DelayAsync(TimeSpan.FromSeconds(1), cts.Token));
  }

  [Fact]
  public void MediaPrintsItsSizeNotItsBytes() =>
    Assert.Equal("WhatsAppMedia { 3 bytes, image/png }", new WhatsAppMedia([1, 2, 3], "image/png").ToString());
}
