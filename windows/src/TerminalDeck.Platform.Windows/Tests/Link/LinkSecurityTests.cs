using System.Diagnostics;
using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Tests.Remote;
using TerminalDeck.Platform.Windows.Link;
using Xunit.Abstractions;

namespace TerminalDeck.Windows.Tests.Link;

// Security's must-fixes for the Windows link (security-step2.md, Windows W1-W8), with the real engine on this PC.
[Collection("webrtc")]
public sealed class LinkSecurityTests(ITestOutputHelper output)
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

  private static Task<LinkHarness> Start(LinkServers servers, double oneWayMs = 30, bool waitMoved = true)
  {
    var engine = Engine();
    return LinkHarness.StartAsync(new LinkSetup(engine, (_, _) => ValueTask.FromResult(servers)), (given, events) => new Answerer(engine.ConnectAnswerer(given, events)),
      askLink: true, oneWayMs: oneWayMs, waitMoved: waitMoved);
  }

  private void Measure(string label, string text)
  {
    var line = "MEASURE " + label + " " + text;
    output.WriteLine(line);
    if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file) File.AppendAllText(file, line + Environment.NewLine);
  }

  // TCP ports this process listens on, IPv4 and IPv6 (netstat -ano).
  private static HashSet<string> ListeningTcp()
  {
    var start = new ProcessStartInfo("netstat", "-ano") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
    using var netstat = Process.Start(start)!;
    var text = netstat.StandardOutput.ReadToEnd();
    netstat.WaitForExit(15_000);
    var pid = Environment.ProcessId.ToString();
    return text.Split('\n').Select(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries))
      .Where(w => w.Length >= 5 && w[0] == "TCP" && w[3] == "LISTENING" && w[4] == pid).Select(w => w[1]).ToHashSet();
  }

  [Fact]
  public async Task W1NoListeningTcpPortWhileALinkIsUp()
  {
    var before = ListeningTcp();
    await using var run = await Start(Stun);
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
    await Task.Delay(1_000);
    var during = ListeningTcp();
    var added = during.Except(before).ToArray();
    List<string> candidates;
    lock (run.Client.HostCandidates) candidates = [.. run.Client.HostCandidates];
    var tcp = candidates.Where(c => c.Contains(" tcp ", StringComparison.OrdinalIgnoreCase)).ToArray();
    Measure("win-link-security-w1", $"listening-before={before.Count} during={during.Count} new=[{string.Join(" ", added)}] host-candidates={candidates.Count} tcp-candidates={tcp.Length}");
    Assert.Empty(added);
    Assert.Empty(tcp);
    Assert.NotEmpty(candidates);
  }

  [Fact]
  public async Task W1TurnOverTcpAndTlsStillConnects()
  {
    var file = Environment.GetEnvironmentVariable("TD_PEER_TEST_TURN");
    if (string.IsNullOrEmpty(file) || !File.Exists(file) || LinkIceSource.ParseList(File.ReadAllText(file)) is not { Count: > 0 } minted)
    { Measure("win-link-turn-tcp", "skipped (no TD_PEER_TEST_TURN)"); return; }
    // Only TURN over TCP (transport=tcp) and TLS (turns:), TURN-only policy: the path must still come up with TCP
    // candidates off, because those are outgoing connections to Cloudflare.
    var tcpOnly = minted.Select(s => s with { Urls = s.Urls.Where(u => u.StartsWith("turns:", StringComparison.Ordinal) || u.Contains("transport=tcp", StringComparison.Ordinal)).ToArray() })
      .Where(s => s.Urls.Count > 0).ToArray();
    Assert.NotEmpty(tcpOnly);
    await using var run = await Start(new LinkServers(tcpOnly, "relay"), waitMoved: false);
    await run.Client.WaitAsync(() => run.Client.MovedAt is not null && run.Connection.LinkRoute(run.ChannelHex) is not null, 20_000);
    var route = run.Connection.LinkRoute(run.ChannelHex);
    Assert.True(route == "turn", "over TURN TCP/TLS: " + route + " " + run.Client.LinkEnded);
    var times = await run.EchoesAsync(20);
    Measure("win-link-turn-tcp", $"route={route} servers={string.Join(",", tcpOnly.SelectMany(s => s.Urls).Select(u => u.Split('?')[0].Split(':')[0] + (u.Contains("transport=tcp") ? "/tcp" : "")))} echo-median={LinkKit.Median(times):0.0} p90={LinkKit.P90(times):0.0}");
  }

  [Fact]
  public async Task W8APhoneDroppingRightAfterHelloFiftyTimesNeverCrashes()
  {
    var engine = Engine();
    var started = Stopwatch.GetTimestamp();
    for (var n = 0; n < 50; n++)
    {
      await using var run = await LinkHarness.StartAsync(new LinkSetup(engine, (_, _) => ValueTask.FromResult(Stun)),
        (given, events) => new Answerer(engine.ConnectAnswerer(given, events)), askLink: true, oneWayMs: 1, waitMoved: false);
      // The relay says the phone went away while the host is making its offer (and, on odd rounds, once the answer is in).
      if (n % 2 == 1) await run.Client.WaitAsync(() => run.Client.AnswerSent, 2_000);
      run.Client.CloseChannel();
      await Task.Delay(n % 3 == 0 ? 0 : 15);
    }
    // Still healthy: a full link and an echo afterwards.
    await using var after = await Start(Stun);
    var times = await after.EchoesAsync(5);
    Measure("win-link-security-w8", $"drops=50 in {Stopwatch.GetElapsedTime(started).TotalSeconds:0.0} s, then a link echo-median={LinkKit.Median(times):0.0} ms");
    Assert.True(LinkKit.Median(times) < 50);
    // One peer connection is left open on purpose: this test process must still end cleanly (the run's own exit is
    // the check — a process that quits with a link open must not hang in libwebrtc's teardown).
    LeftOpen = engine.ConnectAnswerer(Stun, new LinkEvents((_, _, _) => { }, _ => { }, _ => { }, (_, _) => { }));
  }

  private static WebRtcLink? LeftOpen;

  [Fact]
  public async Task W8ClosedOrUnknownHandlesAreRefused()
  {
    var engine = Engine();
    var link = engine.ConnectAnswerer(Stun, new LinkEvents((_, _, _) => { }, _ => { }, _ => { }, (_, _) => { }));
    link.Close();
    // After Close no native call is made: the C# side refuses first.
    await Assert.ThrowsAsync<InvalidOperationException>(() => link.AnswerAsync("v=0", CancellationToken.None));
    Assert.False(link.Send("{}"u8, LinkLane.Control));
    link.AddCandidate("candidate:1 1 udp 1 192.168.1.2 5000 typ host", "0", 0);
    // And the C layer refuses ids it does not hold (closed, never issued): nothing happens, nothing crashes.
    foreach (var stale in new[] { new IntPtr(1L << 40), new IntPtr(999_999_999), IntPtr.Zero })
    {
      engine.Api.Offer(stale); engine.Api.Stats(stale); engine.Api.Close(stale);
      byte[] data = [123, 125];
      var pinned = System.Runtime.InteropServices.GCHandle.Alloc(data, System.Runtime.InteropServices.GCHandleType.Pinned);
      try { Assert.Equal(0, engine.Api.Send(stale, 3, pinned.AddrOfPinnedObject(), 2)); } finally { pinned.Free(); }
      Assert.Equal(0UL, engine.Api.Buffered(stale, 3));
    }
  }

  [Fact]
  public async Task W5AShippedBuildIgnoresTheMeasurementKnobs()
  {
    var knobs = new Dictionary<string, string> { ["TD_PEER_WORKER_TURN"] = "0", ["TD_PEER_POLICY"] = "relay", ["TD_PEER_ICE_SERVERS"] = """[{"urls":["turn:evil.example"]}]""" };
    var asked = 0;
    var servers = await new LinkIceSource((_, _) => { asked++; return Task.FromResult<TurnLogin?>(null); }, (_, _, _) => Task.FromResult(true), null, knobs).ServersAsync("devA", CancellationToken.None);
    Measure("win-link-security-w5", $"build={(LinkIceSource.KnobsAllowed ? "debug" : "release")} policy={servers.Policy} first-server={servers.Servers[0].Urls[0]} worker-asked={asked}");
#if DEBUG
    Assert.True(LinkIceSource.KnobsAllowed);
#else
    Assert.False(LinkIceSource.KnobsAllowed);
    Assert.Equal(("all", 1, "stun:stun.cloudflare.com:3478"), (servers.Policy, asked, servers.Servers[0].Urls[0]));
#endif
  }
}
