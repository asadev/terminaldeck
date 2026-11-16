using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsApp;

public sealed class WhatsAppHttpTransportTests
{
  private const string Key = "WAKEY-test-7d1f0c9e2b4a";
  private const string Creator = "user:50972923564215";

  // ---- the stub WhatsApp ------------------------------------------------------------------------------------

  private sealed record Seen(HttpMethod Method, Uri Uri, string? Authorization, string? Body);

  private sealed class Stub : HttpMessageHandler
  {
    private readonly Queue<Func<HttpRequestMessage, Task<HttpResponseMessage>>> script = new();
    public readonly List<Seen> Requests = [];
    public Func<HttpRequestMessage, Task<HttpResponseMessage>>? Always;

    public Stub Then(Func<HttpRequestMessage, Task<HttpResponseMessage>> step) { script.Enqueue(step); return this; }
    public Stub Then(HttpStatusCode status, string? json = null, Action<HttpResponseMessage>? edit = null) =>
      Then(_ => { var r = Reply(status, json); edit?.Invoke(r); return Task.FromResult(r); });
    public Stub Throw(Exception e) => Then(_ => Task.FromException<HttpResponseMessage>(e));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
      var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
      lock (Requests) Requests.Add(new(request.Method, request.RequestUri!, request.Headers.TryGetValues("Authorization", out var a) ? a.Single() : null, body));
      Func<HttpRequestMessage, Task<HttpResponseMessage>> step;
      lock (script) step = script.Count > 0 ? script.Dequeue() : Always ?? throw new InvalidOperationException("no scripted reply");
      return await step(request);
    }
  }

  private static HttpResponseMessage Reply(HttpStatusCode status, string? json) =>
    new(status) { Content = json is null ? new ByteArrayContent([]) : new StringContent(json, Encoding.UTF8, "application/json") };

  private static string Error(long code, string message = "(#0) error") =>
    JsonSerializer.Serialize(new { error = new { message, type = "OAuthException", code, error_data = new { messaging_product = "whatsapp", details = "detail" }, fbtrace_id = "AW7bqWj4" } });

  private static (WhatsAppHttpTransport Transport, Stub Stub, WhatsAppVirtualClock Clock) Make()
  {
    var stub = new Stub(); var clock = new WhatsAppVirtualClock();
    return (new WhatsAppHttpTransport(stub, clock: clock), stub, clock);
  }

  private static string Updates(string messagesJson, long next, string statuses = "[]") =>
    "{\"object\":\"whatsapp_agent_platform\",\"entry\":[{\"id\":\"123456789\",\"changes\":[{\"field\":\"messages\",\"value\":{\"messaging_product\":\"whatsapp\"," +
    "\"contacts\":[{\"wa_id\":\"user:50972923564215\",\"profile\":{\"name\":\"Alex\"}}],\"messages\":" + messagesJson + ",\"statuses\":" + statuses + "}}]}],\"next_offset\":" + next + "}";

  // ---- check ----------------------------------------------------------------------------------------------

  [Theory]
  [InlineData(200, 0L, WhatsAppKeyCheck.Accepted)]
  [InlineData(204, 0L, WhatsAppKeyCheck.Accepted)]
  [InlineData(400, 100L, WhatsAppKeyCheck.Refused)]
  [InlineData(409, 1752041L, WhatsAppKeyCheck.Accepted)]
  [InlineData(401, 190L, WhatsAppKeyCheck.Refused)]
  [InlineData(400, 131009L, WhatsAppKeyCheck.Unreachable)]
  [InlineData(429, 130429L, WhatsAppKeyCheck.Unreachable)]
  [InlineData(500, 2L, WhatsAppKeyCheck.Unreachable)]
  public async Task CheckIsOneQuickPollWithoutOffset(int status, long code, WhatsAppKeyCheck expected)
  {
    var (t, stub, _) = Make();
    stub.Then((HttpStatusCode)status, status == 200 ? Updates("[]", 5) : status == 204 ? null : Error(code));
    Assert.Equal(expected, await t.CheckAsync(Key));
    var seen = Assert.Single(stub.Requests);
    Assert.Equal(HttpMethod.Get, seen.Method);
    Assert.Equal("https://api.whatsapp.com/agent/v1/updates?limit=1&timeout=0", seen.Uri.AbsoluteUri);
    Assert.Equal("Bearer " + Key, seen.Authorization);
  }

  [Fact]
  public async Task CheckWithoutConnectionIsUnreachableAndABadKeyNeverLeaves()
  {
    var (t, stub, _) = Make();
    stub.Throw(new HttpRequestException(HttpRequestError.NameResolutionError, "no such host"));
    Assert.Equal(WhatsAppKeyCheck.Unreachable, await t.CheckAsync(Key));
    Assert.Equal(WhatsAppKeyCheck.Refused, await t.CheckAsync("has space"));
    Assert.Equal(WhatsAppKeyCheck.Refused, await t.CheckAsync("line\nbreak"));
    Assert.Equal(WhatsAppKeyCheck.Refused, await t.CheckAsync(""));
    Assert.Single(stub.Requests);
  }

  // ---- poll -----------------------------------------------------------------------------------------------

  [Fact]
  public async Task PollParsesEveryKindAndPassesTheOffsetOn()
  {
    var (t, stub, _) = Make();
    const string messages = """
      [
        {"from":"user:50972923564215","id":"wamid.T","timestamp":"1736844652","type":"text","text":{"body":"Hello agent"}},
        {"from":"user:50972923564215","id":"wamid.I","timestamp":"1736844653","type":"image","image":{"id":"998a7c17-60bf","mime_type":"image/jpeg","sha256":"qMVn","caption":"look at this"}},
        {"from":"user:50972923564215","id":"wamid.A","timestamp":"1736844654","type":"audio","audio":{"id":"5f637c19","mime_type":"audio/ogg","sha256":"h2Es","voice":true}},
        {"from":"user:50972923564215","id":"wamid.V","timestamp":"1736844655","type":"video","video":{"id":"451bd2ad","mime_type":"video/mp4","sha256":"x"}},
        {"from":"user:50972923564215","id":"wamid.D","timestamp":"1736844656","type":"document","document":{"id":"14ef9fff","mime_type":"application/pdf","sha256":"x","caption":"the report","filename":"report.pdf"}},
        {"from":"user:50972923564215","id":"wamid.S","timestamp":"1736844657","type":"sticker","sticker":{"id":"2c3dde1d","mime_type":"image/webp","sha256":"x","animated":false}},
        {"from":"user:50972923564215","id":"wamid.R","timestamp":"1736844658","type":"reaction","reaction":{"message_id":"wamid.OUT","emoji":"👍"}},
        {"from":"user:50972923564215","id":"wamid.Q","timestamp":"1736844659","type":"text","context":{"id":"wamid.OLD","from":"agent:123456789"},"text":{"body":"ردّ: ٹھیک ہے"}},
        {"from":"user:50972923564215","id":"wamid.X","timestamp":"1736844660","type":"location","location":{}},
        {"id":"wamid.broken"}
      ]
      """;
    const long next = 9_007_199_254_740_993L; // above 2^53: must survive as a 64-bit integer
    stub.Then(HttpStatusCode.OK, Updates(messages, next, """[{"id":"wamid.OUT","status":"read","recipient_id":"user:50972923564215","timestamp":"1736844652"}]"""));
    var poll = Assert.IsType<WhatsAppPoll.Messages>(await t.PollAsync(Key, 1286, 25));
    Assert.Equal("https://api.whatsapp.com/agent/v1/updates?offset=1286&limit=50&timeout=25", stub.Requests[0].Uri.AbsoluteUri);
    Assert.Equal(next, poll.Next);
    Assert.Equal(9, poll.Items.Count);
    var at = DateTimeOffset.FromUnixTimeSeconds(1736844652);
    Assert.Equal(new WhatsAppInbound("wamid.T", Creator, at, WhatsAppInboundKind.Text, Text: "Hello agent"), poll.Items[0]);
    Assert.Equal(new WhatsAppInbound("wamid.I", Creator, at.AddSeconds(1), WhatsAppInboundKind.Image, Caption: "look at this", MediaId: "998a7c17-60bf", MimeType: "image/jpeg"), poll.Items[1]);
    Assert.Equal(new WhatsAppInbound("wamid.A", Creator, at.AddSeconds(2), WhatsAppInboundKind.Audio, MediaId: "5f637c19", MimeType: "audio/ogg"), poll.Items[2]);
    Assert.Equal(WhatsAppInboundKind.Video, poll.Items[3].Kind);
    Assert.Equal(new WhatsAppInbound("wamid.D", Creator, at.AddSeconds(4), WhatsAppInboundKind.Document, Caption: "the report", MediaId: "14ef9fff", MimeType: "application/pdf", FileName: "report.pdf"), poll.Items[4]);
    Assert.Equal(new WhatsAppInbound("wamid.S", Creator, at.AddSeconds(5), WhatsAppInboundKind.Sticker, MediaId: "2c3dde1d", MimeType: "image/webp"), poll.Items[5]);
    Assert.Equal(new WhatsAppInbound("wamid.R", Creator, at.AddSeconds(6), WhatsAppInboundKind.Reaction), poll.Items[6]);
    Assert.Equal("ردّ: ٹھیک ہے", poll.Items[7].Text);
    Assert.Equal(WhatsAppInboundKind.Other, poll.Items[8].Kind);
  }

  [Fact]
  public async Task PollWithOnlyStatusesStillMovesTheOffset()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.OK, Updates("[]", 1300, """[{"id":"wamid.OUT","status":"delivered","recipient_id":"user:1","timestamp":"1"}]"""));
    Assert.Equal(new WhatsAppPoll.Messages([], 1300), await t.PollAsync(Key, 1299, 25));
  }

  [Fact]
  public async Task PollWithoutOffsetStartsAtTheHeadAndZeroReplaysAndTimeoutIsKeptInRange()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.NoContent).Then(HttpStatusCode.NoContent).Then(HttpStatusCode.NoContent);
    Assert.IsType<WhatsAppPoll.Nothing>(await t.PollAsync(Key, null, 25));
    Assert.IsType<WhatsAppPoll.Nothing>(await t.PollAsync(Key, 0, 99));
    Assert.IsType<WhatsAppPoll.Nothing>(await t.PollAsync(Key, -4, -1));
    Assert.Equal("https://api.whatsapp.com/agent/v1/updates?limit=50&timeout=25", stub.Requests[0].Uri.AbsoluteUri);
    Assert.Equal("https://api.whatsapp.com/agent/v1/updates?offset=0&limit=50&timeout=25", stub.Requests[1].Uri.AbsoluteUri);
    Assert.Equal("https://api.whatsapp.com/agent/v1/updates?offset=0&limit=50&timeout=0", stub.Requests[2].Uri.AbsoluteUri);
  }

  [Fact]
  public async Task PollOutcomesForEveryStatusInTheManual()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.Conflict, Error(1752041, "(#1752041) A newer poll replaced this one"))
        .Then(HttpStatusCode.BadRequest, Error(100, "(#100) Invalid OAuth access token"))
        .Then(HttpStatusCode.Unauthorized, Error(190, "(#190) Malformed access token"));
    Assert.IsType<WhatsAppPoll.Replaced>(await t.PollAsync(Key, 7, 25));
    Assert.IsType<WhatsAppPoll.KeyRefused>(await t.PollAsync(Key, 7, 25));
    Assert.IsType<WhatsAppPoll.KeyRefused>(await t.PollAsync(Key, 7, 25));
  }

  [Fact]
  public async Task PollBacksOffExponentiallyToSixtySecondsAndStartsOverAfterSuccess()
  {
    var (t, stub, clock) = Make();
    stub.Then(HttpStatusCode.TooManyRequests, Error(130429))
        .Then(HttpStatusCode.InternalServerError, Error(2))
        .Then(HttpStatusCode.ServiceUnavailable, null)
        .Throw(new HttpRequestException(HttpRequestError.ConnectionError, "refused"))
        .Throw(new TaskCanceledException("timed out", new TimeoutException()))
        .Then(HttpStatusCode.BadGateway, null)
        .Then(HttpStatusCode.BadRequest, Error(2, "(#2) malformed query"))
        .Then(HttpStatusCode.NoContent)
        .Then(HttpStatusCode.InternalServerError, null)
        .Then(HttpStatusCode.OK, "not json");
    var waits = new List<double>();
    for (var i = 0; i < 7; i++) waits.Add(Assert.IsType<WhatsAppPoll.BackOff>(await t.PollAsync(Key, 7, 25)).Seconds);
    Assert.Equal(new double[] { 2, 4, 8, 16, 32, 60, 60 }, waits);
    Assert.IsType<WhatsAppPoll.Nothing>(await t.PollAsync(Key, 7, 25));
    Assert.Equal(2, Assert.IsType<WhatsAppPoll.BackOff>(await t.PollAsync(Key, 7, 25)).Seconds); // a good poll resets it
    Assert.Equal(4, Assert.IsType<WhatsAppPoll.BackOff>(await t.PollAsync(Key, 7, 25)).Seconds); // a 200 that is not WhatsApp's shape is a failed poll
    Assert.All(stub.Requests, r => Assert.Contains("offset=7&", r.Uri.Query)); // the prior offset is reused
    Assert.Equal(TimeSpan.Zero, clock.TotalDelayed); // the poll gives the wait to the engine; it does not sleep
  }

  [Fact]
  public async Task NeverTwoPollsAtOnceForOneKeyButTwoKeysDoNotWaitForEachOther()
  {
    var (t, stub, _) = Make();
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    var open = 0; var most = 0;
    stub.Always = async _ =>
    {
      var now = Interlocked.Increment(ref open); lock (stub) most = Math.Max(most, now);
      try { return await release.Task.ContinueWith(_ => Reply(HttpStatusCode.NoContent, null)); }
      finally { Interlocked.Decrement(ref open); }
    };
    var first = t.PollAsync(Key, 1, 25);
    var second = t.PollAsync(Key, 1, 25);
    var other = t.PollAsync("WAKEY-another-agent", 1, 25);
    for (var i = 0; i < 200 && stub.Requests.Count < 2; i++) await Task.Delay(5);
    Assert.Equal(2, stub.Requests.Count); // one for Key, one for the other key; Key's second waits
    release.SetResult(Reply(HttpStatusCode.NoContent, null));
    await Task.WhenAll(first, second, other);
    Assert.Equal(3, stub.Requests.Count);
    Assert.Equal(2, most);
  }

  [Fact]
  public async Task PollsStayInsideFifteenAMinute()
  {
    var (t, stub, clock) = Make();
    stub.Always = _ => Task.FromResult(Reply(HttpStatusCode.NoContent, null));
    for (var i = 0; i < 15; i++) await t.PollAsync(Key, 1, 0);
    Assert.Equal(TimeSpan.Zero, clock.TotalDelayed);
    await t.PollAsync(Key, 1, 0);
    Assert.Equal(TimeSpan.FromSeconds(60), clock.TotalDelayed);
  }

  // ---- send -----------------------------------------------------------------------------------------------

  [Fact]
  public async Task SendPostsTheManualsBodyAndNeverRetriesASuccess()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.OK, """{"messaging_product":"whatsapp","contacts":[{"input":"user:50972923564215","wa_id":"user:50972923564215"}],"messages":[{"id":"wamid.HBg"}]}""");
    var text = "Done ✅ — *bold* \"quoted\" ٹھیک ہے 👍🏽";
    Assert.IsType<WhatsAppSent.Sent>(await t.SendAsync(Key, Creator, text));
    var seen = Assert.Single(stub.Requests);
    Assert.Equal(HttpMethod.Post, seen.Method);
    Assert.Equal("https://api.whatsapp.com/agent/v1/messages", seen.Uri.AbsoluteUri);
    using var body = JsonDocument.Parse(seen.Body!);
    Assert.Equal("whatsapp", body.RootElement.GetProperty("messaging_product").GetString());
    Assert.Equal(Creator, body.RootElement.GetProperty("to").GetString());
    Assert.Equal("text", body.RootElement.GetProperty("type").GetString());
    Assert.Equal(text, body.RootElement.GetProperty("text").GetProperty("body").GetString());
    Assert.Equal(4, body.RootElement.EnumerateObject().Count());
  }

  [Fact]
  public async Task SendEmptyAnswerTwoHundredIsStillSentOnce()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.Accepted, null);
    Assert.IsType<WhatsAppSent.Sent>(await t.SendAsync(Key, Creator, "hi"));
    Assert.Single(stub.Requests);
  }

  [Theory]
  [InlineData(400, 131009, "(#131009) Missing or malformed required fields", "Failed")]
  [InlineData(400, 100, "(#100) Invalid OAuth access token", "KeyRefused")]
  [InlineData(400, 100, "text.body", "Failed")]
  [InlineData(401, 190, "(#190) Malformed access token", "KeyRefused")]
  [InlineData(403, 131005, "(#131005) The recipient is not the agent's creator", "NotCreator")]
  [InlineData(404, 0, "not found", "Failed")]
  [InlineData(500, 2, "(#2) Internal server error", "Failed")]
  [InlineData(502, 0, "bad gateway", "Failed")]
  [InlineData(503, 2, "unavailable without the code", "Failed")]
  public async Task SendIsNotRetriedOnA4xxOrWhenItMayHaveGoneOut(int status, long code, string message, string expected)
  {
    var (t, stub, clock) = Make();
    stub.Then((HttpStatusCode)status, Error(code, message));
    var result = await t.SendAsync(Key, Creator, "hello");
    Assert.Equal(expected, result.GetType().Name);
    if (status >= 500) Assert.Equal(new WhatsAppSent.Failed(WhatsAppHttpTransport.UnknownWhetherSent), result);
    if (status == 400 && code == 131009) Assert.Equal(new WhatsAppSent.Failed("WhatsApp refused the message (HTTP 400, code 131009)."), result);
    if (status == 404) Assert.Equal(new WhatsAppSent.Failed("WhatsApp refused the message (HTTP 404, code 0)."), result);
    if (message == "text.body") Assert.Equal(new WhatsAppSent.Failed("WhatsApp said the message is too long."), result);
    Assert.Single(stub.Requests);
    Assert.Equal(TimeSpan.Zero, clock.TotalDelayed);
  }

  [Fact]
  public async Task SendRetriesA429AndA503NotAcceptedAfterBackingOff()
  {
    var (t, stub, clock) = Make();
    stub.Then(HttpStatusCode.TooManyRequests, Error(130429))
        .Then(HttpStatusCode.ServiceUnavailable, Error(131016, "(#131016) Not accepted for delivery"))
        .Then(HttpStatusCode.OK, """{"messages":[{"id":"wamid.1"}]}""");
    Assert.IsType<WhatsAppSent.Sent>(await t.SendAsync(Key, Creator, "hello"));
    Assert.Equal(3, stub.Requests.Count);
    Assert.Equal(new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4) }, clock.Delays);
  }

  [Fact]
  public async Task SendGivesUpAfterThreeNotSentAnswersWithABackOff()
  {
    var (t, stub, _) = Make();
    stub.Always = _ => Task.FromResult(Reply(HttpStatusCode.ServiceUnavailable, Error(131016)));
    Assert.Equal(new WhatsAppSent.BackOff(8), await t.SendAsync(Key, Creator, "hello"));
    Assert.Equal(3, stub.Requests.Count);
  }

  [Fact]
  public async Task SendRetriesWhenNoConnectionWasMade()
  {
    var (t, stub, _) = Make();
    stub.Throw(new HttpRequestException(HttpRequestError.ConnectionError, "refused")).Then(HttpStatusCode.OK, "{}");
    Assert.IsType<WhatsAppSent.Sent>(await t.SendAsync(Key, Creator, "hello"));
    Assert.Equal(2, stub.Requests.Count);
  }

  [Theory]
  [InlineData(0)]
  [InlineData(1)]
  [InlineData(2)]
  [InlineData(3)]
  public async Task ATimeoutOrBrokenConnectionIsUnknownAndNeverSentTwice(int which)
  {
    Exception failure = which switch
    {
      0 => new TaskCanceledException("The request was canceled due to the configured timeout.", new TimeoutException()),
      1 => new HttpRequestException(HttpRequestError.ResponseEnded, "The response ended prematurely."),
      2 => new HttpRequestException("An error occurred while sending the request.", new IOException("Connection reset by peer")),
      _ => new IOException("Unable to read data from the transport connection"),
    };
    var (t, stub, _) = Make();
    stub.Throw(failure);
    stub.Always = _ => Task.FromResult(Reply(HttpStatusCode.OK, "{}"));
    Assert.Equal(new WhatsAppSent.Failed(WhatsAppHttpTransport.UnknownWhetherSent), await t.SendAsync(Key, Creator, "hello"));
    Assert.Single(stub.Requests);
  }

  [Fact]
  public async Task SendRefusesLocallyWhatWhatsAppWouldRefuse()
  {
    var (t, stub, _) = Make();
    Assert.Equal(new WhatsAppSent.Failed("The message is longer than WhatsApp allows (4096 characters)."), await t.SendAsync(Key, Creator, string.Concat(Enumerable.Repeat("😀", 2049))));
    Assert.IsType<WhatsAppSent.NotCreator>(await t.SendAsync(Key, "agent:123456789", "hi"));
    Assert.IsType<WhatsAppSent.NotCreator>(await t.SendAsync(Key, "50972923564215", "hi"));
    Assert.IsType<WhatsAppSent.NotCreator>(await t.SendAsync(Key, "user:", "hi"));
    Assert.Equal(new WhatsAppSent.Failed("There was nothing to send."), await t.SendAsync(Key, Creator, ""));
    Assert.IsType<WhatsAppSent.KeyRefused>(await t.SendAsync("bad key", Creator, "hi"));
    Assert.Empty(stub.Requests);
    stub.Then(HttpStatusCode.OK, "{}");
    Assert.IsType<WhatsAppSent.Sent>(await t.SendAsync(Key, Creator, new string('a', 4096)));
  }

  [Fact]
  public async Task SendsAndStatusesForOneKeyGoOneAfterAnother()
  {
    var (t, stub, _) = Make();
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var open = 0; var most = 0;
    stub.Always = async _ =>
    {
      var now = Interlocked.Increment(ref open); lock (stub) most = Math.Max(most, now);
      try { await release.Task; return Reply(HttpStatusCode.OK, "{}"); }
      finally { Interlocked.Decrement(ref open); }
    };
    var calls = new List<Task<WhatsAppSent>> { t.SendAsync(Key, Creator, "one"), t.MarkReadAsync(Key, "wamid.1", true), t.SendAsync(Key, Creator, "two") };
    for (var i = 0; i < 100 && stub.Requests.Count < 1; i++) await Task.Delay(5);
    await Task.Delay(30);
    Assert.Single(stub.Requests);
    release.SetResult();
    await Task.WhenAll(calls);
    Assert.Equal(1, most);
    Assert.Equal(new[] { "messages", "statuses", "messages" }, stub.Requests.Select(r => r.Uri.Segments[^1]));
  }

  [Fact]
  public async Task SendsStayInsideTwelveAMinute()
  {
    var (t, stub, clock) = Make();
    stub.Always = _ => Task.FromResult(Reply(HttpStatusCode.OK, "{}"));
    for (var i = 0; i < 12; i++) await t.SendAsync(Key, Creator, "m" + i);
    Assert.Equal(TimeSpan.Zero, clock.TotalDelayed);
    await t.SendAsync(Key, Creator, "thirteenth");
    Assert.Equal(TimeSpan.FromSeconds(60), clock.TotalDelayed);
    for (var i = 0; i < 12; i++) await t.MarkReadAsync(Key, "wamid." + i, false);
    Assert.Equal(TimeSpan.FromSeconds(60), clock.TotalDelayed); // statuses have their own counter
  }

  // ---- mark read ------------------------------------------------------------------------------------------

  [Fact]
  public async Task MarkReadSendsTheTypingIndicatorOnlyWhenAsked()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.OK, """{"success":true}""").Then(HttpStatusCode.OK, """{"success":true}""");
    Assert.IsType<WhatsAppSent.Sent>(await t.MarkReadAsync(Key, "wamid.HBg", true));
    Assert.IsType<WhatsAppSent.Sent>(await t.MarkReadAsync(Key, "wamid.HBg", false));
    Assert.Equal("https://api.whatsapp.com/agent/v1/statuses", stub.Requests[0].Uri.AbsoluteUri);
    Assert.Equal("""{"messaging_product":"whatsapp","status":"read","message_id":"wamid.HBg","typing_indicator":{"type":"text"}}""", stub.Requests[0].Body);
    Assert.Equal("""{"messaging_product":"whatsapp","status":"read","message_id":"wamid.HBg"}""", stub.Requests[1].Body);
  }

  [Fact]
  public async Task MarkReadOutcomes()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.Forbidden, Error(131005))
        .Then(HttpStatusCode.BadRequest, Error(131009, "(#131009) Field \"message_id\" must be a wamid issued by this platform"))
        .Then(HttpStatusCode.Unauthorized, Error(190))
        .Then(HttpStatusCode.ServiceUnavailable, Error(131016)).Then(HttpStatusCode.OK, "{}")
        .Then(HttpStatusCode.InternalServerError, Error(2)).Then(HttpStatusCode.TooManyRequests, Error(130429));
    Assert.IsType<WhatsAppSent.NotCreator>(await t.MarkReadAsync(Key, "wamid.1", true));
    Assert.Equal(new WhatsAppSent.Failed("WhatsApp could not mark the message read (HTTP 400, code 131009)."), await t.MarkReadAsync(Key, "nope", true));
    Assert.IsType<WhatsAppSent.KeyRefused>(await t.MarkReadAsync(Key, "wamid.1", true));
    Assert.IsType<WhatsAppSent.Sent>(await t.MarkReadAsync(Key, "wamid.1", true)); // a receipt may be repeated
    Assert.Equal(new WhatsAppSent.BackOff(4), await t.MarkReadAsync(Key, "wamid.1", true));
    Assert.Equal(7, stub.Requests.Count);
  }

  [Fact]
  public async Task TheThirteenthStatusCallInAMinuteIsSkippedNotQueued()
  {
    var (t, stub, clock) = Make();
    stub.Always = _ => Task.FromResult(Reply(HttpStatusCode.OK, """{"success":true}"""));
    for (var i = 0; i < 12; i++) Assert.IsType<WhatsAppSent.Sent>(await t.MarkReadAsync(Key, "wamid.A", true));
    Assert.Equal(60, Assert.IsType<WhatsAppSent.BackOff>(await t.MarkReadAsync(Key, "wamid.A", true)).Seconds, 2);
    Assert.Equal(12, stub.Requests.Count);
    Assert.Equal(TimeSpan.Zero, clock.TotalDelayed);
  }

  // ---- media ----------------------------------------------------------------------------------------------

  [Fact]
  public async Task MediaFetchesTheMetadataThenTheUrlWithTheSameKey()
  {
    var (t, stub, _) = Make();
    var bytes = Enumerable.Range(0, 5000).Select(i => (byte)i).ToArray();
    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/agent/v1/media/8f3a/content","mime_type":"application/pdf","sha256":"a8c5","file_size":5000,"id":"8f3a","messaging_product":"whatsapp"}""")
        .Then(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }));
    var media = await t.MediaAsync(Key, "8f3a", WhatsAppLimits.MaxBytes(WhatsAppInboundKind.Document));
    Assert.Equal(new WhatsAppMedia(bytes, "application/pdf"), media);
    Assert.Equal("https://api.whatsapp.com/agent/v1/media/8f3a", stub.Requests[0].Uri.AbsoluteUri);
    Assert.Equal("https://lookaside.fbsbx.com/agent/v1/media/8f3a/content", stub.Requests[1].Uri.AbsoluteUri);
    Assert.All(stub.Requests, r => Assert.Equal("Bearer " + Key, r.Authorization));
  }

  [Fact]
  public async Task MediaOverTheLimitOrUnknownOrNotHttpsIsNull()
  {
    var (t, stub, _) = Make();
    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/x","mime_type":"image/jpeg","file_size":6000000}""");
    Assert.Null(await t.MediaAsync(Key, "big", WhatsAppLimits.ImageBytes));
    Assert.Single(stub.Requests); // never downloaded

    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/y","mime_type":"image/jpeg"}""")
        .Then(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[2048]) }));
    Assert.Null(await t.MediaAsync(Key, "no-size", 1024)); // larger than said: cut off while reading

    stub.Then(HttpStatusCode.BadRequest, Error(100, "(#100) Unknown media id"));
    Assert.Null(await t.MediaAsync(Key, "gone", 1024));

    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/z","file_size":10}""").Then(HttpStatusCode.NotFound, Error(100));
    Assert.Null(await t.MediaAsync(Key, "expired", 1024));

    var before = stub.Requests.Count;
    stub.Then(HttpStatusCode.OK, """{"url":"http://plain.example/z","file_size":10}""");
    Assert.Null(await t.MediaAsync(Key, "plain", 1024));
    Assert.Equal(before + 1, stub.Requests.Count); // the key is never sent to a plain-http address

    stub.Then(HttpStatusCode.OK, """{"url":"https://evil.example.com/z","file_size":10}""");
    Assert.Null(await t.MediaAsync(Key, "foreign", 1024));
    stub.Then(HttpStatusCode.OK, """{"url":"https://user:pw@lookaside.fbsbx.com/z","file_size":10}""");
    Assert.Null(await t.MediaAsync(Key, "userinfo", 1024));
    Assert.Equal(before + 3, stub.Requests.Count); // the key is never sent anywhere but WhatsApp's own hosts
    Assert.DoesNotContain(stub.Requests, r => r.Uri.Host == "evil.example.com");

    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/w","file_size":3}""")
        .Then(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) { Headers = { ContentType = new MediaTypeHeaderValue("image/png") } } }));
    Assert.Equal(new WhatsAppMedia([1, 2, 3], "application/octet-stream"), await t.MediaAsync(Key, "untyped", 1024));
    stub.Then(HttpStatusCode.OK, """{"url":"https://lookaside.fbsbx.com/e","file_size":0}""").Then(HttpStatusCode.OK, null);
    Assert.Null(await t.MediaAsync(Key, "empty", 1024));
  }

  [Fact]
  public async Task AMediaIdThatIsNotWhatsAppsIsNeverAskedFor()
  {
    var (t, stub, _) = Make();
    Assert.Null(await t.MediaAsync(Key, "../updates?x=1", 10));
    Assert.Null(await t.MediaAsync(Key, ".hidden", 10));
    Assert.Null(await t.MediaAsync(Key, "a/b", 10));
    Assert.Null(await t.MediaAsync(Key, "ok-id", 0));
    Assert.Empty(stub.Requests);
  }

  // ---- the key stays secret; cancellation is the caller's ---------------------------------------------------

  [Fact]
  public async Task TheKeyNeverAppearsInAnyResultOrMessage()
  {
    var (t, stub, _) = Make();
    stub.Always = req => Task.FromResult(Reply(HttpStatusCode.BadRequest, Error(131009, "(#131009) echo " + req.Headers.Authorization)));
    var said = new List<string?> { t.ToString(), (await t.CheckAsync(Key)).ToString() };
    said.Add((await t.PollAsync(Key, 1, 25)).ToString());
    var sent = await t.SendAsync(Key, Creator, "hi"); said.Add(sent.ToString()); said.Add(Assert.IsType<WhatsAppSent.Failed>(sent).Reason);
    var read = await t.MarkReadAsync(Key, "wamid.1", true); said.Add(read.ToString());
    said.Add((await t.MediaAsync(Key, "m", 10))?.ToString());
    stub.Always = _ => throw new HttpRequestException("socket closed for Bearer " + Key);
    said.Add((await t.SendAsync(Key, Creator, "hi")).ToString());
    said.Add((await t.PollAsync(Key, 1, 25)).ToString());
    stub.Always = _ => throw new TaskCanceledException("timeout " + Key, new TimeoutException());
    said.Add((await t.SendAsync(Key, Creator, "hi")).ToString());
    said.Add((await t.MarkReadAsync(Key, "wamid.1", false)).ToString());
    Assert.All(said, s => Assert.DoesNotContain("7d1f0c9e2b4a", s ?? ""));
    Assert.Equal(WhatsAppKeyCheck.Refused, await t.CheckAsync("WAKEY\r\nX-Injected: 1"));
  }

  [Fact]
  public async Task CallerCancellationIsThrownNotReportedAsUnknown()
  {
    var (t, stub, _) = Make();
    using var cts = new CancellationTokenSource();
    stub.Always = _ => { cts.Cancel(); return Task.FromException<HttpResponseMessage>(new TaskCanceledException(null, null, cts.Token)); };
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => t.SendAsync(Key, Creator, "hi", cts.Token));
  }
}
