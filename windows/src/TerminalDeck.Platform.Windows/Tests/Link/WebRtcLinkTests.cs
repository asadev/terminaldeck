using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Tests.Remote;
using TerminalDeck.Platform.Windows.Link;
using Xunit.Abstractions;

namespace TerminalDeck.Windows.Tests.Link;

// stream step 2 (dc2) on the Windows host with the REAL engine: tdlink.dll over webrtc-sdk libwebrtc.dll m150 on both
// ends (host = the real RelayHostConnection; client = the contract-exact dc2 client from LinkHarness), the relay
// simulated at today's Dubai relay (132 ms each way; direct only since #27, it carries only the meeting). Paths:
//   host  — the ICE ladder as shipped (same machine, so the same-network rung wins)
//   internet — no host candidates (needs router hairpin on one machine: reported, not required)
//   turn  — Cloudflare Realtime TURN only (needs TD_PEER_TEST_TURN = a JSON file of minted ICE servers)
// Prints `MEASURE win-link-<path> …`. Needs tdlink.dll + libwebrtc.dll next to the tests (-p:TdLinkNative=<folder>).
[Collection("webrtc")]
public sealed class WebRtcLinkTests(ITestOutputHelper output)
{
  private static readonly LinkServers Stun = new([LinkPaths.CloudflareStun], "all");

  private static WebRtcLinkEngine Engine()
  {
    var engine = WebRtcLinkEngine.TryCreate(out var problem);
    Assert.True(engine is not null, "the link engine: " + problem);
    return engine!;
  }

  private sealed class Answerer(WebRtcLink link) : ILinkAnswerer
  {
    public Task<string> AnswerAsync(string offer) => link.AnswerAsync(offer, CancellationToken.None);
    public void AddCandidate(string candidate, string? mid, int index) => link.AddCandidate(candidate, mid, index);
    public bool Send(ReadOnlySpan<byte> message, LinkLane lane) => link.Send(message, lane);
    public void Close() => link.Close();
  }

  private static Task<LinkHarness> Start(LinkServers? servers, bool askLink = true, double oneWayMs = LinkKit.RelayOneWayMs, bool waitMoved = true)
  {
    var engine = Engine();
    var setup = servers is null ? null : new LinkSetup(engine, (_, _) => ValueTask.FromResult(servers));
    return LinkHarness.StartAsync(setup, (given, events) => new Answerer(engine.ConnectAnswerer(given, events)), askLink, oneWayMs: oneWayMs, waitMoved: waitMoved);
  }

  private static LinkServers? Turn()
  {
    var path = Environment.GetEnvironmentVariable("TD_PEER_TEST_TURN");
    if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
    var servers = LinkIceSource.ParseList(File.ReadAllText(path));
    return servers is { Count: > 0 } ? new LinkServers(servers, "relay") : null;
  }

  private void Measure(string label, string text)
  {
    var line = "MEASURE " + label + " " + text;
    output.WriteLine(line);
    if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file) File.AppendAllText(file, line + Environment.NewLine);
  }

  private async Task<double> EchoRunAsync(string label, LinkServers servers, bool required = true)
  {
    await using var run = await Start(servers, waitMoved: false);
    await run.Client.WaitAsync(() => run.Client.MovedAt is not null && run.Connection.LinkRoute(run.ChannelHex) is not null, 15_000);
    var route = run.Connection.LinkRoute(run.ChannelHex) ?? "none";
    if (route == "none" && !required) { Measure(label, "route=none (no path on this machine) ended=" + (run.Client.LinkEnded ?? "")); return double.NaN; }
    Assert.True(route != "none", label + ": moved onto the link (" + run.Client.LinkEnded + ")");
    var times = await run.EchoesAsync(50);
    Measure(label, $"route={route} connect-ms={run.Client.ConnectMs:0} echo-median={LinkKit.Median(times):0.0} p90={LinkKit.P90(times):0.0} max={times.Max():0.0} viaLink={run.Client.ViaLink} viaRelay={run.Client.ViaRelay}");
    return LinkKit.Median(times);
  }

  [Fact]
  public async Task KeystrokeEchoOnEveryRungWithRealWebRtc()
  {
    // (The relay rung is gone: direct only. Today's relay echo was 263 ms; the link must stay well under it.)
    var host = await EchoRunAsync("win-link-host", Stun);
    Assert.True(host < 60, $"link {host}");
    _ = await EchoRunAsync("win-link-internet", new LinkServers([LinkPaths.CloudflareStun], "nohost"), required: false);
    if (Turn() is { } turn)
    {
      var viaTurn = await EchoRunAsync("win-link-turn", turn);
      Assert.True(viaTurn < 130, $"TURN {viaTurn}");
    }
    else Measure("win-link-turn", "skipped (no TD_PEER_TEST_TURN)");
  }

  [Fact]
  public async Task TheHandOverKeepsOrderBothWaysWithRealWebRtc()
  {
    await using var run = await Start(Stun, waitMoved: false);
    var pushes = Task.Run(async () =>
    {
      for (var n = 0; n < 300; n++)
      {
        await run.App.Publisher!(run.ChannelHex, JsonSerializer.SerializeToUtf8Bytes(new { t = "test.push", n }), CancellationToken.None);
        await Task.Delay(3);
      }
    });
    for (var n = 0; n < 300; n++) { await run.Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n })); await Task.Delay(3); }
    await pushes;
    await run.Client.WaitAsync(() => run.Client.Echoed.Count == 300 && run.Client.Pushed.Count == 300, 20_000);
    Assert.Equal(Enumerable.Range(0, 300), run.App.Applied());
    Assert.Equal(Enumerable.Range(0, 300), run.Client.Echoed);
    Assert.Equal(Enumerable.Range(0, 300), run.Client.Pushed);
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
    // Direct only: over the relay the client got the welcome and nothing else; host pushes made before the move waited.
    Assert.True(run.Client.ViaLink >= 600 && run.Client.ViaRelay == 1 && run.Client.PushesFromRelay == 0 && run.Client.EchoesFromRelay == 0,
      $"viaLink={run.Client.ViaLink} viaRelay={run.Client.ViaRelay}");
    Measure("win-link-handover-real", $"viaLink={run.Client.ViaLink} viaRelay={run.Client.ViaRelay} route={run.Connection.LinkRoute(run.ChannelHex)}");
    // A 450 000-byte message crosses in parts and joins whole.
    var big = JsonSerializer.SerializeToUtf8Bytes(new { t = "test.video", n = 2, pad = new string('a', 450_000) });
    Assert.Equal(true, run.Connection.SendDirect(run.ChannelHex, big, LinkLane.Still));
    await run.Client.WaitAsync(() => run.Client.VideoOnStill == 1, 10_000);
    Assert.Equal(1, run.Client.VideoOnStill);
    Assert.False(run.Client.Closed);
  }

  [Fact]
  public async Task ADeadRealLinkClosesTheConnection()
  {
    await using var run = await Start(Stun, oneWayMs: 30);
    run.Client.KillLink();
    await run.Client.WaitAsync(() => run.Client.Closed, 12_000);
    Assert.True(run.Client.Closed, "the host closed the sealed connection after its link died");
  }

  private static void Step(string text)
  {
    if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file)
      File.AppendAllText(Path.Combine(Path.GetDirectoryName(file)!, "steps.txt"), DateTimeOffset.Now.ToString("HH:mm:ss.fff") + " " + text + Environment.NewLine);
  }

  [Fact]
  public async Task TheEngineStartsAndMakesAnOffer()
  {
    Step("engine: loading");
    var engine = WebRtcLinkEngine.TryCreate(out var problem);
    Step("engine: " + (engine is null ? "failed " + problem : "ready"));
    Assert.NotNull(engine);
    Step("audio asked and refused: " + engine!.AudioRefused);
    Assert.True(engine.AudioRefused >= 1, "libwebrtc's audio device lookups go to the empty enumerator");
    var candidates = 0;
    var link = engine!.Connect(Stun, new LinkEvents((_, _, _) => Interlocked.Increment(ref candidates), _ => { }, _ => { }, (_, _) => { }));
    Step("connect: made");
    var offer = await link.OfferAsync(CancellationToken.None);
    Step("offer: " + offer.Length + " bytes, fingerprint " + (LinkBinding.Fingerprint(offer) is not null));
    Assert.NotNull(LinkBinding.Fingerprint(offer));
    Assert.Contains("webrtc-datachannel", offer);
    for (var i = 0; i < 50 && Volatile.Read(ref candidates) == 0; i++) await Task.Delay(20);
    Step("candidates: " + candidates);
    link.Close();
    Step("closed");
  }

  [Fact]
  public void StatsNameThePath()
  {
    const string stats = """[{"id":"T1","type":"transport","selectedCandidatePairId":"CP1"},{"id":"CP1","type":"candidate-pair","localCandidateId":"L1","remoteCandidateId":"R1","state":"succeeded","nominated":true},{"id":"L1","type":"local-candidate","candidateType":"relay","address":"10.1.1.1"},{"id":"R1","type":"remote-candidate","candidateType":"srflx","address":"5.6.7.8"}]""";
    Assert.Equal("turn", WebRtcLink.PathFrom(stats));
    Assert.Equal("host", WebRtcLink.PathFrom(stats.Replace("\"relay\"", "\"host\"").Replace("5.6.7.8", "192.168.0.4").Replace("\"srflx\"", "\"host\"")));
    Assert.Equal("unknown", WebRtcLink.PathFrom("[]"));
    // M5: the path crosses TCP when this side reaches its TURN server over TCP/TLS, or the other side's relayed
    // candidate says so in its priority (type preference 1 = TCP, 0 = TLS; relayed UDP is 2).
    Assert.False(WebRtcLink.OverTcpFrom(stats));
    Assert.True(WebRtcLink.OverTcpFrom(stats.Replace("\"address\":\"10.1.1.1\"", "\"address\":\"10.1.1.1\",\"relayProtocol\":\"tls\"")));
    Assert.False(WebRtcLink.OverTcpFrom(stats.Replace("\"address\":\"10.1.1.1\"", "\"address\":\"10.1.1.1\",\"relayProtocol\":\"udp\"")));
    var remoteRelay = stats.Replace("\"relay\"", "\"host\"").Replace("\"srflx\",\"address\":\"5.6.7.8\"", "\"relay\",\"address\":\"5.6.7.8\",\"priority\":");
    Assert.True(WebRtcLink.OverTcpFrom(remoteRelay.Replace("\"priority\":", "\"priority\":16777215")));   // TLS
    Assert.True(WebRtcLink.OverTcpFrom(remoteRelay.Replace("\"priority\":", "\"priority\":33554431")));   // TCP
    Assert.False(WebRtcLink.OverTcpFrom(remoteRelay.Replace("\"priority\":", "\"priority\":41885439")));
    Assert.False(WebRtcLink.OverTcpFrom("[]"));
  }
}
