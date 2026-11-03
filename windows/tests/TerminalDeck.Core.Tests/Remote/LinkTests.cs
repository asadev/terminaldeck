using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Remote;
using Xunit.Abstractions;

namespace TerminalDeck.Core.Tests.Remote;

// stream step 2 (dc2) on the Windows host: the whole protocol over ONE link per sealed relay connection, against the
// real RelayHostConnection + PhoneLink. The relay is simulated at today's Dubai relay (263 ms keystroke echo → 132 ms
// each way); the client is a contract-exact dc2 client (stream-step2-contract.md §2–§7, the same rules the phones and
// the web implement). The link here is an in-memory stand-in for a WebRTC stack (MemoryLink): it pins DTLS
// fingerprints like a real stack (only the endpoint whose fingerprint is in the SDP can connect), joins parts and
// keeps each channel in order. The real-WebRTC echo waits for the stack decision (SIPSorcery's licence).
public sealed class LinkTests(ITestOutputHelper output)
{
  // ---- contract vectors ----------------------------------------------------------------------------------------

  [Fact]
  public void BindingVectorsFingerprintAndParts()
  {
    var key = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();
    const string fp = "sha-256 AA:BB";
    Assert.Equal("scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=", LinkBinding.Make(key, "host", fp));
    Assert.Equal("L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=", LinkBinding.Make(key, "client", fp));
    Assert.True(LinkBinding.Check("L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=", key, "client", fp));
    Assert.False(LinkBinding.Check("L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=", key, "host", fp));
    Assert.False(LinkBinding.Check("scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=", new byte[32], "host", fp));
    Assert.False(LinkBinding.Check("eA==", key, "host", fp));
    Assert.False(LinkBinding.Check(null, key, "host", fp));
    Assert.Equal("sha-256 11:22", LinkBinding.Fingerprint("v=0\r\na=group:BUNDLE 0\r\na=fingerprint:sha-256 11:22\r\n"));
    Assert.Null(LinkBinding.Fingerprint("v=0\r\na=fingerprint:sha-1 11:22\r\n"));
    // Two different sha-256 fingerprints in one SDP: refused (which certificate would DTLS accept? — W4). The same one
    // twice (per media section) is fine.
    Assert.Null(LinkBinding.Fingerprint("v=0\r\na=fingerprint:sha-256 11:22\r\na=fingerprint:sha-256 33:44\r\n"));
    Assert.Equal("sha-256 11:22", LinkBinding.Fingerprint("v=0\r\na=fingerprint:sha-256 11:22\r\na=fingerprint:SHA-256 11:22\r\n"));

    // A short text is itself; a long one splits into 0x01 … 0x02 parts that join back byte for byte.
    var shortText = "{\"t\":\"ping\"}"u8.ToArray();
    Assert.Equal(shortText, Assert.Single(LinkFrames.Parts(shortText)));
    var longText = Encoding.UTF8.GetBytes("{\"t\":\"x\",\"d\":\"" + new string('a', 450_000) + "\"}");
    var parts = LinkFrames.Parts(longText);
    Assert.Equal(3, parts.Count);
    Assert.All(parts.SkipLast(1), p => Assert.Equal(0x01, p[0]));
    Assert.Equal(0x02, parts[^1][0]);
    Assert.All(parts, p => Assert.True(p.Length <= LinkFrames.MostMessageBytes));
    MemoryStream? pending = null; byte[]? joined = null;
    foreach (var part in parts) if (LinkFrames.Join(part, ref pending, out var whole) == LinkFrames.Result.Whole) joined = whole;
    Assert.Equal(longText, joined); Assert.Null(pending);
    // A whole message in the middle of parts, or more than 4 MiB joined, breaks the rules.
    MemoryStream? broken = null;
    Assert.Equal(LinkFrames.Result.Waiting, LinkFrames.Join(parts[0], ref broken, out _));
    Assert.Equal(LinkFrames.Result.Failure, LinkFrames.Join(shortText, ref broken, out _));
    MemoryStream? big = null; var chunk = new byte[LinkFrames.MostMessageBytes]; chunk[0] = 0x01;
    var result = LinkFrames.Result.Waiting;
    for (var i = 0; i < 30 && result == LinkFrames.Result.Waiting; i++) result = LinkFrames.Join(chunk, ref big, out _);
    Assert.Equal(LinkFrames.Result.Failure, result);
    Assert.Equal("turn", LinkPaths.Name("candidate:1 1 udp 1 10.0.0.2 5000 typ relay", "candidate:2 1 udp 1 1.2.3.4 6000 typ srflx"));
    Assert.Equal("host", LinkPaths.Name("candidate:1 1 udp 1 192.168.1.2 5000 typ host", "candidate:2 1 udp 1 192.168.1.9 6000 typ prflx"));
    Assert.Equal("internet", LinkPaths.Name("candidate:1 1 udp 1 5.6.7.8 5000 typ srflx", "candidate:2 1 udp 1 1.2.3.4 6000 typ srflx"));
  }

  // ---- TURN logins (contract §8): never the live relay ----------------------------------------------------------

  private sealed class FakeHttp(Func<HttpRequestMessage, string, HttpResponseMessage> answer) : HttpMessageHandler
  {
    public int Calls;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
      Interlocked.Increment(ref Calls);
      var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
      return answer(request, body);
    }
  }

  // A fake Worker: /v1/turn mints a fresh login per ask (and remembers the device's current one), /v1/turn/revoke
  // withdraws by device, or by login only while it is still current (contract "TURN per device + revoke").
  private sealed class FakeWorker
  {
    public readonly List<(string Path, JsonElement Body)> Seen = [];
    public readonly Dictionary<string, string> Current = [];
    public string? Secret;
    public int RevokeFailures;
    private int next;
    public long ExpiresAtMs = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeMilliseconds();
    public FakeHttp Handler => new((request, body) =>
    {
      using var doc = JsonDocument.Parse(body);
      var root = doc.RootElement.Clone();
      lock (this) { Seen.Add((request.RequestUri!.AbsolutePath, root)); Secret = request.Headers.GetValues("x-deck-host-secret").Single(); }
      var device = root.GetProperty("device").GetString()!;
      if (request.RequestUri!.AbsolutePath == "/v1/turn")
      {
        string login;
        lock (this) { login = (++next).ToString("x32"); Current[device] = login; }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new
        {
          ok = true, device, login, ttl = 3600, expiresAtMs = ExpiresAtMs,
          iceServers = new object[] { new { urls = new[] { "turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:5349", "http://bad" }, username = "u-" + login, credential = "c-" + login } }
        })) };
      }
      lock (this)
      {
        if (RevokeFailures > 0) { RevokeFailures--; return new HttpResponseMessage(HttpStatusCode.BadGateway) { Content = new StringContent("{\"ok\":false}") }; }
        var named = root.TryGetProperty("login", out var l) ? l.GetString() : null;
        var revoked = Current.TryGetValue(device, out var held) && (named is null || named == held) ? 1 : 0;
        if (revoked == 1) Current.Remove(device);
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { ok = true, device, revoked })) };
      }
    });
    public int Count(string path) { lock (this) return Seen.Count(s => s.Path == path); }
  }

  [Fact]
  public async Task TurnLoginsArePerDeviceReusedOnlyWithTenMinutesLeftAndWithdrawn()
  {
    var secret = Enumerable.Range(0, 32).Select(i => (byte)(250 - i)).ToArray();
    var worker = new FakeWorker();
    var open = true;
    using var logins = new RelayTurnLogins(new Uri("wss://relay.example"), secret, () => open, new HttpClient(worker.Handler));
    var clock = new TestClock { Now = DateTimeOffset.UtcNow };
    var source = new LinkIceSource((d, ct) => logins.FetchAsync(d, 3600, ct), (d, l, ct) => logins.RevokeAsync(d, l, ct), clock, new Dictionary<string, string>(),
      [TimeSpan.FromMilliseconds(30), TimeSpan.FromMilliseconds(30), TimeSpan.FromMilliseconds(30)]);
    var a = await source.ServersAsync("devA", CancellationToken.None);
    var b = await source.ServersAsync("devB", CancellationToken.None);
    // The body names the device; the host secret is the header; STUN is always first; each device has its own username.
    Assert.Equal("devA", worker.Seen[0].Body.GetProperty("device").GetString());
    Assert.Equal(3600, worker.Seen[0].Body.GetProperty("ttl").GetInt32());
    Assert.Equal(Convert.ToBase64String(secret).TrimEnd('=').Replace('+', '-').Replace('/', '_'), worker.Secret);
    Assert.Equal(["stun:stun.cloudflare.com:3478"], a.Servers[0].Urls);
    Assert.Equal(["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:5349"], a.Servers[1].Urls);
    Assert.NotEqual(a.Servers[1].Username, b.Servers[1].Username);
    // Reused for that device while more than 10 minutes are left; asked again after that.
    clock.Now = DateTimeOffset.FromUnixTimeMilliseconds(worker.ExpiresAtMs).AddMinutes(-11);
    var again = await source.ServersAsync("devA", CancellationToken.None);
    Assert.Equal(a.Servers[1].Username, again.Servers[1].Username);
    Assert.Equal(2, worker.Count("/v1/turn"));
    clock.Now = DateTimeOffset.FromUnixTimeMilliseconds(worker.ExpiresAtMs).AddMinutes(-9);
    var fresh = await source.ServersAsync("devA", CancellationToken.None);
    Assert.NotEqual(a.Servers[1].Username, fresh.Servers[1].Username);
    Assert.Equal(3, worker.Count("/v1/turn"));
    // Its last link closed: the login is withdrawn by name (only while it is still the device's current one).
    var currentA = worker.Current["devA"];
    await source.ReleaseAsync("devA", force: false);
    var named = worker.Seen.Last(s => s.Path == "/v1/turn/revoke").Body;
    Assert.Equal((currentA, "devA"), (named.GetProperty("login").GetString(), named.GetProperty("device").GetString()));
    Assert.False(worker.Current.ContainsKey("devA"));
    Assert.DoesNotContain("devA", source.Holders);
    // Unpaired / access off: unconditionally, no login named, even with nothing cached and the relay socket closed.
    open = false;
    await source.ReleaseAsync("devC", force: true);
    var forced = worker.Seen.Last(s => s.Path == "/v1/turn/revoke").Body;
    Assert.Equal("devC", forced.GetProperty("device").GetString());
    Assert.False(forced.TryGetProperty("login", out _));
    Assert.Null(await logins.FetchAsync("devD", 3600, CancellationToken.None)); // asking needs the open socket
    open = true;
    // A withdrawal the Worker refuses is retried; the retries stop once the device has a new login (Security R1).
    _ = await source.ServersAsync("devB", CancellationToken.None); // B already cached: no new ask
    worker.RevokeFailures = 1;
    await source.ReleaseAsync("devB", force: false);
    Assert.Equal(2, worker.Seen.Count(s => s.Path == "/v1/turn/revoke" && s.Body.GetProperty("device").GetString() == "devB"));
    _ = await source.ServersAsync("devB", CancellationToken.None);
    worker.RevokeFailures = 10;
    var releasing = source.ReleaseAsync("devB", force: false);
    await Task.Delay(10);
    _ = await source.ServersAsync("devB", CancellationToken.None); // a reconnect's fresh login
    worker.RevokeFailures = 0;
    await releasing;
    Assert.True(worker.Current.ContainsKey("devB"), "the fresh login survives the old login's late withdrawal");
    // Refused or not deployed: STUN only. A bad device id is never sent.
    var refusing = new FakeHttp((_, _) => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{\"ok\":false}") });
    using var refused = new RelayTurnLogins(new Uri("wss://relay.example"), secret, () => true, new HttpClient(refusing));
    var stunOnly = await new LinkIceSource((d, ct) => refused.FetchAsync(d, 3600, ct), (d, l, ct) => refused.RevokeAsync(d, l, ct), clock, new Dictionary<string, string>()).ServersAsync("devA", CancellationToken.None);
    Assert.Equal(["stun:stun.cloudflare.com:3478"], Assert.Single(stunOnly.Servers).Urls);
    Assert.Null(await refused.FetchAsync("bad id!", 3600, CancellationToken.None));
    // An answer for another device is not used.
    Assert.Null(RelayTurnLogins.Parse("""{"ok":true,"device":"other","iceServers":[{"urls":["turn:x"]}]}"""u8, "devA"));
    Assert.Equal("http://localhost:8787/v1/turn", RelayTurnLogins.Endpoint(new Uri("ws://localhost:8787/v1/host")).ToString());
    Assert.Equal("https://relay.example/v1/turn/revoke", RelayTurnLogins.Endpoint(new Uri("wss://relay.example"), "/v1/turn/revoke").ToString());
  }

  // Security S1 (#27): the phone host stopping (device access off for the whole app, or the app closing) withdraws every
  // login it handed out at once, by name, instead of after the 2-minute timers.
  [Fact]
  public async Task StoppingWithdrawsEveryLoginAtOnceByName()
  {
    var secret = Enumerable.Range(0, 32).Select(i => (byte)(250 - i)).ToArray();
    var worker = new FakeWorker();
    using var logins = new RelayTurnLogins(new Uri("wss://relay.example"), secret, () => true, new HttpClient(worker.Handler));
    var source = new LinkIceSource((d, ct) => logins.FetchAsync(d, 3600, ct), (d, l, ct) => logins.RevokeAsync(d, l, ct), new TestClock { Now = DateTimeOffset.UtcNow }, new Dictionary<string, string>());
    _ = await source.ServersAsync("devA", CancellationToken.None);
    _ = await source.ServersAsync("devB", CancellationToken.None);
    Assert.Equal(2, source.Holders.Count);
    await source.WithdrawAllAsync(TimeSpan.FromSeconds(5));
    Assert.Empty(source.Holders);
    var revoked = worker.Seen.Where(s => s.Path == "/v1/turn/revoke").ToArray();
    Assert.Equal(["devA", "devB"], revoked.Select(s => s.Body.GetProperty("device").GetString()).Order());
    Assert.All(revoked, s => Assert.True(s.Body.TryGetProperty("login", out _), "withdrawn by name"));
  }

  [Fact]
  public async Task MeasurementKnobsOnlyInDebugBuilds()
  {
    var knobs = new Dictionary<string, string> { ["TD_PEER_WORKER_TURN"] = "0", ["TD_PEER_POLICY"] = "relay", ["TD_PEER_ICE_SERVERS"] = """[{"urls":["turn:evil.example"]}]""" };
    var asked = 0;
    var servers = await new LinkIceSource((_, _) => { asked++; return Task.FromResult<TurnLogin?>(null); }, (_, _, _) => Task.FromResult(true), null, knobs).ServersAsync("devA", CancellationToken.None);
#if DEBUG
    Assert.True(LinkIceSource.KnobsAllowed);
    Assert.Equal(("relay", "turn:evil.example"), (servers.Policy, servers.Servers[0].Urls[0]));
#else
    // A shipped build ignores the environment: the Worker is asked, the policy is the product's.
    Assert.False(LinkIceSource.KnobsAllowed);
    Assert.Equal(("all", 1), (servers.Policy, asked));
#endif
  }

  [Fact]
  public async Task TrustChangesEndLinksAndWithdrawLogins()
  {
    var worker = new FakeWorker();
    using var host = NoiseIdentity.Generate();
    using var client = new RelayHostClient(new Uri("wss://relay.example/v1/host"), new byte[32], host, new TestApplication(), linkEngine: new MemoryEngine(new MemoryNet()),
      turnHttp: new HttpClient(worker.Handler), linkEligible: _ => null);
    // First look: every known device without access is withdrawn (it may hold a login from before a restart).
    client.RefreshLinkDevices(["devA", "devB"], ["devA", "devB", "devHoot", "devPending"]);
    await WaitUntil(() => worker.Count("/v1/turn/revoke") == 2);
    Assert.Equal(["devHoot", "devPending"], worker.Seen.Where(s => s.Path == "/v1/turn/revoke").Select(s => s.Body.GetProperty("device").GetString()).Order());
    Assert.All(worker.Seen, s => Assert.False(s.Body.TryGetProperty("login", out _)));
    // devB is unpaired (or loses access): withdrawn unconditionally; devA stays.
    client.RefreshLinkDevices(["devA"], ["devA"]);
    await WaitUntil(() => worker.Count("/v1/turn/revoke") == 3);
    Assert.Equal("devB", worker.Seen.Last().Body.GetProperty("device").GetString());
    await Task.Delay(100);
    Assert.Equal(3, worker.Count("/v1/turn/revoke"));
  }

  private static async Task WaitUntil(Func<bool> done, int ms = 5000)
  {
    for (var waited = 0; waited < ms && !done(); waited += 10) await Task.Delay(10);
    Assert.True(done());
  }

  // ---- who is offered a link ------------------------------------------------------------------------------------

  private static async Task<(RelayHostConnection Connection, NoiseTransport Client, byte[] Id)> Opened(NoiseIdentity host, NoiseIdentity phone, IRelayPhoneApplication app, LinkSetup? setup)
  {
    var id = RandomNumberGenerator.GetBytes(16);
    var connection = new RelayHostConnection(host, app, linkSetup: setup);
    await connection.ProcessAsync(new RelayPacket(RelayKind.Open, id, []).Encode());
    var start = NoiseChannel.Start(phone, host.PublicKey);
    var reply = RelayPacket.Decode((await connection.ProcessAsync(new RelayPacket(RelayKind.Data, id, RelayPacket.FrameHandshake(start.Message)).Encode()))[0]);
    return (connection, NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(reply.Payload, false)), id);
  }

  private static string[] WelcomeCapabilities(NoiseTransport client, IReadOnlyList<byte[]> packets)
  {
    foreach (var packet in packets.Select(p => RelayPacket.Decode(p)).Where(p => p.Kind == RelayKind.Data))
    {
      using var doc = JsonDocument.Parse(client.Receive(packet.Payload));
      if (doc.RootElement.GetProperty("t").GetString() == "welcome") return doc.RootElement.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()!).ToArray();
    }
    throw new InvalidOperationException("no welcome");
  }

  private static (string? Code, string? Message) Refusal(NoiseTransport client, IReadOnlyList<byte[]> packets)
  {
    foreach (var packet in packets.Select(p => RelayPacket.Decode(p)).Where(p => p.Kind == RelayKind.Data))
    {
      using var doc = JsonDocument.Parse(client.Receive(packet.Payload));
      Assert.NotEqual("welcome", doc.RootElement.GetProperty("t").GetString());
      if (doc.RootElement.GetProperty("t").GetString() == "error") return (doc.RootElement.GetProperty("code").GetString(), doc.RootElement.GetProperty("message").GetString());
    }
    throw new InvalidOperationException("no error");
  }

  [Fact]
  public async Task EveryApprovedPhoneThatAsksIsOfferedTheLinkAndNoOtherPhoneGetsIn()
  {
    using var host = NoiseIdentity.Generate();
    var net = new MemoryNet(); var engine = new MemoryEngine(net);
    var asked_devices = new List<string>();
    LinkSetup Setup(DeviceTrust trust) => new(engine, (device, _) => { lock (asked_devices) asked_devices.Add(device); return ValueTask.FromResult(new LinkServers([LinkPaths.CloudflareStun], "all")); })
    { Eligible = LinkEligibility.For(trust) };
    // Asked (link only), approved, a host with a stack: the welcome says link.dc2 and link.only, and a peer connection
    // is made for the offer, with that device's own ICE servers.
    var (trust, credential, phone) = LinkKit.Approved();
    var (asked, askedClient, askedId) = await Opened(host, phone, new PhoneLink(trust, "PC", "0.1", new TestSessionView()), Setup(trust));
    await using (asked)
    {
      var capabilities = WelcomeCapabilities(askedClient, await asked.ProcessAsync(new RelayPacket(RelayKind.Data, askedId, askedClient.Send(LinkKit.Hello(credential, link: true))).Encode()));
      Assert.Contains("link.dc2", capabilities); Assert.Contains("link.only", capabilities);
      for (var i = 0; i < 100 && engine.Connects == 0; i++) await Task.Delay(10);
      Assert.Equal(1, engine.Connects);
      lock (asked_devices) Assert.Equal([trust.List().Single().Id], asked_devices);
    }
    // An older dc2 phone: link.dc2 only.
    var (trust5, credential5, phone5) = LinkKit.Approved();
    var (older, olderClient, olderId) = await Opened(host, phone5, new PhoneLink(trust5, "PC", "0.1", new TestSessionView()), Setup(trust5));
    await using (older)
    {
      var capabilities = WelcomeCapabilities(olderClient, await older.ProcessAsync(new RelayPacket(RelayKind.Data, olderId, olderClient.Send(LinkKit.Hello(credential5, link: true, only: false))).Encode()));
      Assert.Contains("link.dc2", capabilities); Assert.DoesNotContain("link.only", capabilities);
    }
    // Hoot-only: a link and its own TURN login too (§11.6: it has nothing else to talk over).
    var (hootTrust, hootCredential, hootPhone) = LinkKit.Approved(PhoneAccess.Hoot);
    var (hoot, hootClient, hootId) = await Opened(host, hootPhone, new PhoneLink(hootTrust, "PC", "0.1", new TestSessionView()), Setup(hootTrust));
    await using (hoot)
    {
      Assert.Contains("link.dc2", WelcomeCapabilities(hootClient, await hoot.ProcessAsync(new RelayPacket(RelayKind.Data, hootId, hootClient.Send(LinkKit.Hello(hootCredential, link: true))).Encode())));
      for (var i = 0; i < 100 && engine.Connects < 3; i++) await Task.Delay(10);
      Assert.Equal(3, engine.Connects);
    }
    // The default setup (no eligibility given) offers nobody a link, and a phone without one is told and let go:
    // nothing else would ever reach it.
    var (trust4, credential4, phone4) = LinkKit.Approved();
    var (closed, closedClient, closedId) = await Opened(host, phone4, new PhoneLink(trust4, "PC", "0.1", new TestSessionView()), new LinkSetup(engine, (_, _) => ValueTask.FromResult(new LinkServers([], "all"))));
    await using (closed)
    {
      var packets = await closed.ProcessAsync(new RelayPacket(RelayKind.Data, closedId, closedClient.Send(LinkKit.Hello(credential4, link: true))).Encode());
      Assert.Equal("unavailable", Refusal(closedClient, packets).Code);
      Assert.Equal(RelayKind.Close, RelayPacket.Decode(packets[^1]).Kind);
    }
    // A phone that does not ask (an app too old for the link): `version`, told to update, let go (§11.5).
    var (trust2, credential2, phone2) = LinkKit.Approved();
    var (quiet, quietClient, quietId) = await Opened(host, phone2, new PhoneLink(trust2, "PC", "0.1", new TestSessionView()), Setup(trust2));
    await using (quiet)
    {
      var packets = await quiet.ProcessAsync(new RelayPacket(RelayKind.Data, quietId, quietClient.Send(LinkKit.Hello(credential2, link: false))).Encode());
      var (refusal, message) = Refusal(quietClient, packets);
      Assert.Equal("version", refusal);
      Assert.StartsWith("Update Terminal Deck on this phone to connect", message);
      Assert.Equal(RelayKind.Close, RelayPacket.Decode(packets[^1]).Kind);
    }
    // A browser too ("web").
    var (trust6, credential6, phone6) = LinkKit.Approved();
    var (browser, browserClient, browserId) = await Opened(host, phone6, new PhoneLink(trust6, "PC", "0.1", new TestSessionView()), Setup(trust6));
    await using (browser)
      Assert.Equal("version", Refusal(browserClient, await browser.ProcessAsync(new RelayPacket(RelayKind.Data, browserId, browserClient.Send(LinkKit.Hello(credential6, link: false, platform: "web"))).Encode())).Code);
    // A desktop guest (another computer's "Other computers"): today's relay connection (§11.5), no link.
    var (trust7, credential7, phone7) = LinkKit.Approved();
    var (guest, guestClient, guestId) = await Opened(host, phone7, new PhoneLink(trust7, "PC", "0.1", new TestSessionView()), Setup(trust7));
    await using (guest)
    {
      Assert.DoesNotContain("link.dc2", WelcomeCapabilities(guestClient, await guest.ProcessAsync(new RelayPacket(RelayKind.Data, guestId, guestClient.Send(LinkKit.Hello(credential7, link: false, platform: "win32"))).Encode())));
      var listed = await guest.ProcessAsync(new RelayPacket(RelayKind.Data, guestId, guestClient.Send(JsonSerializer.SerializeToUtf8Bytes(new { t = "list" }))).Encode());
      using var sessions = JsonDocument.Parse(guestClient.Receive(RelayPacket.Decode(Assert.Single(listed)).Payload));
      Assert.Equal("sessions", sessions.RootElement.GetProperty("t").GetString());
    }
    // Asked, but this connection has no stack (the pairing beacon, a receiver-only host): told, let go, nothing else.
    var (trust3, credential3, phone3) = LinkKit.Approved();
    var (plain, plainClient, plainId) = await Opened(host, phone3, new PhoneLink(trust3, "PC", "0.1", new TestSessionView()), null);
    await using (plain)
    {
      var packets = await plain.ProcessAsync(new RelayPacket(RelayKind.Data, plainId, plainClient.Send(LinkKit.Hello(credential3, link: true))).Encode());
      Assert.Equal("unavailable", Refusal(plainClient, packets).Code);
      Assert.Equal(RelayKind.Close, RelayPacket.Decode(packets[^1]).Kind);
    }
    // A pairing hello (a code, not yet approved): the pending welcome carries no link and the channel closes.
    using var newPhone = NoiseIdentity.Generate();
    var pairing = new DeviceTrust(new TestTrustStore()); var code = pairing.Pairing.Create().Code;
    var (pairs, pairsClient, pairsId) = await Opened(host, newPhone, new PairingApp(new PhoneLink(pairing, "PC", "0.1", new TestSessionView()), pairing), Setup(pairing));
    await using (pairs)
    {
      var packets = await pairs.ProcessAsync(new RelayPacket(RelayKind.Data, pairsId, pairsClient.Send(LinkKit.Hello(code, link: true))).Encode());
      Assert.DoesNotContain("link.dc2", WelcomeCapabilities(pairsClient, packets));
      Assert.Equal(RelayKind.Close, RelayPacket.Decode(packets[^1]).Kind);
    }
    await Task.Delay(100);
    Assert.Equal(3, engine.Connects);
    lock (asked_devices) Assert.Equal(3, asked_devices.Count);
  }

  private sealed class PairingApp(PhoneLink inner, DeviceTrust trust) : IRelayPhoneApplication
  {
    public IReadOnlyCollection<byte[]> KnownPeers => trust.KnownPeers;
    public bool PairingOpen => true;
    public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken ct) => inner.ReceiveAsync(channel, peerKey, plaintext, ct);
    public ValueTask DisconnectedAsync(string channel) => inner.DisconnectedAsync(channel);
  }

  [Fact]
  public void RemoteCandidatesAreParsedAndFiltered()
  {
    static string Line(string address) => "candidate:1 1 udp 2122260223 " + address + " 50000 typ host generation 0";
    foreach (var good in new[] { "192.168.1.20", "10.0.0.9", "100.64.1.2", "5.6.7.8", "fe80::1", "2001:db8::5", "fd7a:115c:a1e0::1", "0f3b2a1c-89ab-4cde-9f01-23456789abcd.local", "a=candidate:1 1 udp 1 192.168.1.2 1 typ host".Split(' ')[4] })
      Assert.True(LinkCandidates.Usable(Line(good)), good);
    Assert.True(LinkCandidates.Usable("a=" + Line("192.168.1.20")));
    foreach (var bad in new[] { "127.0.0.1", "127.1", "0.0.0.0", "0.1.2.3", "224.0.0.251", "239.1.1.1", "255.255.255.255", "::1", "0:0:0:0:0:0:0:1", "::",
      "::ffff:127.0.0.1", "::ffff:7f00:1", "ff02::fb", "0x7f000001", "localhost", "evil.example.com", "my host.local" })
      Assert.False(LinkCandidates.Usable(Line(bad)), bad);
    Assert.False(LinkCandidates.Usable("candidate:1 1 udp"));
  }

  // ---- the whole protocol over the link ---------------------------------------------------------------------------

  [Fact]
  public async Task TheHandOverKeepsOrderAndOnlyTheMeetingCrossesTheRelay()
  {
    var net = new MemoryNet();
    await using var run = await Memory(net, askLink: true, waitMoved: false);
    Assert.Null(run.Connection.LinkRoute(run.ChannelHex));
    // 300 host pushes every 3 ms from right after the welcome, across the host's move: the ones made before it wait for
    // the link and go first on td.ctl. 300 ordered client messages as soon as the client can (it sends them on the link).
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
    await run.Client.WaitAsync(() => run.Client.Echoed.Count == 300 && run.Client.Pushed.Count == 300, 15_000);
    Assert.Equal(Enumerable.Range(0, 300), run.App.Applied());
    Assert.Equal(Enumerable.Range(0, 300), run.Client.Echoed);
    Assert.Equal(Enumerable.Range(0, 300), run.Client.Pushed);
    Assert.Equal("host", run.Connection.LinkRoute(run.ChannelHex));
    // Link only: over the relay the client got the welcome and nothing else (signalling aside).
    Assert.Equal(1, run.Client.ViaRelay);
    Assert.Equal(0, run.Client.EchoesFromRelay);
    Assert.Equal(0, run.Client.PushesFromRelay);
    output.WriteLine($"MEASURE win-link-handover viaLink={run.Client.ViaLink} viaRelay={run.Client.ViaRelay}");
    // The offer carried the ICE servers and the policy; candidates trickled both ways inside the sealed channel.
    Assert.Equal("all", run.Client.Offer!.Value.GetProperty("policy").GetString());
    Assert.Equal("stun:stun.cloudflare.com:3478", run.Client.Offer.Value.GetProperty("ice")[0].GetProperty("urls")[0].GetString());
    Assert.True(run.Client.CandidatesFromHost >= 1 && net.HostCandidatesAdded >= 1);
    // After the move: the ping goes on td.ctl and its pong comes back there (§11.1); a late host candidate goes on
    // td.ctl and on the relay while it is there (§11.4); video goes on its own channel.
    await run.Client.SendAsync("{\"t\":\"ping\"}"u8.ToArray());
    await run.Client.WaitAsync(() => run.Client.PongsViaLink == 1, 5_000);
    Assert.Equal(0, run.Client.PingsOnRelay);
    await run.Client.WaitAsync(() => run.Client.CandidatesOnLink >= 1 && run.Client.CandidatesAfterHostMoved >= 1, 5_000);
    Assert.True(run.Client.CandidatesOnLink >= 1, "a late candidate on td.ctl");
    Assert.Equal(true, run.Connection.SendDirect(run.ChannelHex, "{\"t\":\"test.video\",\"n\":1}"u8, LinkLane.Moving));
    await run.Client.WaitAsync(() => run.Client.VideoOnMoving == 1, 5_000);
    Assert.False(run.Client.Closed);
  }

  [Fact]
  public async Task AnOlderDc2PhoneIsAnsweredOnTheLinkOnly()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, waitMoved: false, only: false);
    // It still asks over the relay before its link is up (§11.5): handled, the answer waits for the link.
    await run.Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1 }));
    await run.Client.WaitAsync(() => run.Client.Echoed.Contains(1), 5_000);
    Assert.Equal([1], run.App.Applied());
    Assert.Equal(0, run.Client.EchoesFromRelay);
    Assert.DoesNotContain("link.only", run.Client.Welcome!.Value.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()));
    // Its ping stays on the relay; the pong comes on the link.
    await run.Client.WaitAsync(() => run.Client.MovedAt is not null, 5_000);
    await run.Client.SendAsync("{\"t\":\"ping\"}"u8.ToArray());
    await run.Client.WaitAsync(() => run.Client.PongsViaLink == 1, 5_000);
    Assert.Equal(0, run.Client.PongsViaRelay);
  }

  [Fact]
  public async Task NothingGoesOnALinkThatHasNotMoved()
  {
    await using var run = await Memory(new MemoryNet { NeverConnect = true }, askLink: true, waitMoved: false);
    Assert.True(run.Connection.AwaitsLink(run.ChannelHex));
    Assert.True(run.Connection.HasLink(run.ChannelHex));
    Assert.Equal(false, run.Connection.SendDirect(run.ChannelHex, "{}"u8, LinkLane.Moving));
    // Not one of this connection's channels (the PC's own loopback web page): no link, so no screens either (§11.7).
    Assert.Null(run.Connection.SendDirect("local-web:1", "{}"u8, LinkLane.Moving));
    Assert.False(run.Connection.AwaitsLink("local-web:1"));
    Assert.False(run.Connection.HasLink("local-web:1"));
  }

  [Fact]
  public async Task ALinkOnlyPhonesRelayMessagesAreDroppedNeverHandled()
  {
    await using var run = await Memory(new MemoryNet { NeverConnect = true }, askLink: true, oneWayMs: 20, waitMoved: false);
    await run.Client.SendOnRelayAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 3, rid = "r3" }));
    await run.Client.SendOnRelayAsync("{\"t\":\"ping\"}"u8.ToArray());
    await Task.Delay(500);
    Assert.Empty(run.App.Applied());
    Assert.Empty(run.Client.Errors);
    Assert.Equal(0, run.Client.PongsViaRelay);
    Assert.False(run.Client.Closed);
  }

  [Fact]
  public async Task AnAnswerNotBoundToThePairingEndsTheLinkAndTheConnection()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, forge: true, oneWayMs: 30, waitMoved: false);
    await run.Client.WaitAsync(() => run.Client.EndFromHost && run.Client.Closed, 3_000);
    Assert.True(run.Client.EndFromHost, "the host refused the answer");
    Assert.True(run.Client.Closed, "no direct path: the sealed connection closes (§11.3)");
    Assert.Equal(0, run.Client.ViaLink);
    Assert.Empty(run.App.Applied());
  }

  [Fact]
  public async Task ADeadLinkClosesTheConnection()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30);
    run.Client.KillLink();
    await run.Client.WaitAsync(() => run.Client.Closed, 10_000);
    Assert.True(run.Client.Closed, "the host closed the sealed connection after its link died");
  }

  [Fact]
  public async Task LinkMessagesAreHeldUntilTheClientsMarkerAndAHandOverThatNeverComesEndsTheConnection()
  {
    // An older dc2 phone (§5): its td.ctl waits for its marker. (Link only on both ends takes td.ctl at once.)
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30, neverMark: true, only: false);
    var sent = Stopwatch.GetTimestamp();
    await run.Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 7 }));
    await Task.Delay(1_000);
    Assert.Empty(run.App.Applied());
    await run.Client.WaitAsync(() => run.Client.Closed, 9_000);
    var waited = Stopwatch.GetElapsedTime(sent).TotalMilliseconds;
    Assert.True(run.Client.Closed && waited >= 4_900, $"closed after {waited:0} ms");
    Assert.Empty(run.App.Applied());
  }

  [Fact]
  public async Task NoOpenLinkWithinTenSecondsEndsItAndTheConnection()
  {
    await using var run = await Memory(new MemoryNet { NeverConnect = true }, askLink: true, oneWayMs: 20, waitMoved: false);
    // Before the deadline a host push waits for the link; when the link never comes it goes nowhere.
    await run.App.Publisher!(run.ChannelHex, JsonSerializer.SerializeToUtf8Bytes(new { t = "test.push", n = 1 }), CancellationToken.None);
    await run.Client.WaitAsync(() => run.Client.EndFromHost && run.Client.Closed, 12_000);
    Assert.True(run.Client.EndFromHost, "the host gave up after the deadline");
    Assert.True(run.Client.Closed, "and closed the sealed connection (§11.3)");
    Assert.Empty(run.Client.Pushed);
  }

  [Fact]
  public async Task TooMuchWaitingForTheLinkEndsIt()
  {
    await using var run = await Memory(new MemoryNet { NeverConnect = true }, askLink: true, oneWayMs: 20, waitMoved: false);
    var pad = new string('a', 1_000_000);
    for (var n = 0; n < 5; n++) await run.App.Publisher!(run.ChannelHex, JsonSerializer.SerializeToUtf8Bytes(new { t = "test.push", n, pad }), CancellationToken.None);
    await run.Client.WaitAsync(() => run.Client.Closed, 5_000);
    Assert.True(run.Client.EndFromHost && run.Client.Closed, "more than 4 MiB waiting for the link ends it");
    Assert.Empty(run.Client.Pushed);
  }

  [Fact]
  public async Task AHootOnlyDeviceGetsALinkAndItsOwnTurnLogin()
  {
    var net = new MemoryNet();
    var asked = 0;
    await using var run = await LinkHarness.StartAsync(new LinkSetup(new MemoryEngine(net), (_, _) => { Interlocked.Increment(ref asked); return ValueTask.FromResult(new LinkServers([LinkPaths.CloudflareStun, new(["turn:turn.example:3478"], "u", "p")], "all")); }),
      (_, events) => net.Make(events, offerer: false), askLink: true, oneWayMs: 30, access: PhoneAccess.Hoot);
    Assert.Contains("link.dc2", run.Client.Welcome!.Value.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()));
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
    Assert.Equal(1, asked);
    Assert.Equal(2, run.Client.Offer!.Value.GetProperty("ice").GetArrayLength());
  }

  [Fact]
  public async Task ALinkOnlyPhoneOutlivesItsRelay()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 20);
    Assert.True(LinkKit.Median(await run.EchoesAsync(1)) < 100);
    // The phone's relay channel closes (Cloudflare resets idle-looking sockets): the link and the connection stay.
    run.Client.CloseChannel();
    await Task.Delay(300);
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
    Assert.True(LinkKit.Median(await run.EchoesAsync(3)) < 100, "echoes over the link after the phone's relay went");
    // This PC's own relay socket ends too: still alive, and host pushes still arrive.
    run.Relay.EndHostSocket();
    await run.Running.WaitAsync(TimeSpan.FromSeconds(5));
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
    Assert.True(LinkKit.Median(await run.EchoesAsync(3)) < 100, "echoes over the link after this PC's relay socket went");
    await run.App.Publisher!(run.ChannelHex, JsonSerializer.SerializeToUtf8Bytes(new { t = "test.push", n = 9 }), CancellationToken.None);
    await run.Client.WaitAsync(() => run.Client.Pushed.Contains(9), 5_000);
    Assert.Contains(9, run.Client.Pushed);
    // Only the link ending ends it (fail-stop).
    run.Client.KillLink();
    for (var i = 0; i < 100 && run.Connection.HasLink(run.ChannelHex); i++) await Task.Delay(20);
    Assert.False(run.Connection.HasLink(run.ChannelHex));
  }

  [Fact]
  public async Task AnOlderDc2PhoneGoesWithItsRelay()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 20, only: false);
    run.Client.CloseChannel();
    for (var i = 0; i < 100 && run.Connection.HasLink(run.ChannelHex); i++) await Task.Delay(20);
    Assert.False(run.Connection.HasLink(run.ChannelHex));
  }

  [Fact]
  public async Task ItsLastConnectionClosingWithdrawsTheDevicesLoginAfterALinger()
  {
    var released = new ConcurrentQueue<(string Device, bool Force)>();
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30, release: (device, force) => { released.Enqueue((device, force)); return Task.CompletedTask; }, releaseAfter: TimeSpan.FromMilliseconds(600));
    var device = run.App.Trust.List().Single().Id;
    run.Client.KillLink();
    await Task.Delay(300);
    Assert.True(released.IsEmpty, "a reconnect within the linger reuses the login (§11.6)");
    await run.Client.WaitAsync(() => !released.IsEmpty, 5_000);
    Assert.Equal([(device, false)], released);
  }

  [Fact]
  public async Task ATrustChangeEndsTheDevicesLink()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30);
    run.Connection.EndLinksFor(run.App.Trust.List().Single().Id);
    await run.Client.WaitAsync(() => run.Client.Closed, 5_000);
    Assert.True(run.Client.Closed, "after the move, the link ending closes the sealed connection");
  }

  [Fact]
  public async Task AClientWritingOnAVideoChannelEndsTheLink()
  {
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30);
    Assert.True(run.Client.SendOnLane(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 5 }), LinkLane.Moving));
    await run.Client.WaitAsync(() => run.Client.Closed, 5_000);
    Assert.True(run.Client.Closed);
    Assert.Empty(run.App.Applied());
  }

  [Fact]
  public async Task AtMost32UsableRemoteCandidates()
  {
    var net = new MemoryNet();
    await using var run = await Memory(net, askLink: true, oneWayMs: 20);
    var before = net.HostCandidatesAdded;
    for (var i = 0; i < 5; i++) await run.Client.SendCandidateAsync("candidate:9 1 udp 1 127.0.0." + (i + 1) + " 5000 typ host");
    for (var i = 0; i < 40; i++) await run.Client.SendCandidateAsync("candidate:9 1 udp 1 192.168.7." + (i + 1) + " 5000 typ host");
    await Task.Delay(500);
    Assert.Equal(32, net.HostCandidatesAdded);
    Assert.True(before >= 1);
    Assert.False(run.Client.Closed);
  }

  [Fact]
  public async Task TheHoldWaitsWhileARelayFrameIsStillBeingAnswered()
  {
    // The client's marker sits behind a relay frame that takes 6.5 s to answer: its link message arrives first and must
    // be held past the 5 s hold, because the relay frame before the marker is still being answered (W7).
    // An older dc2 phone (§5, §11.5): its relay frames are still answered, and its marker can sit behind one.
    await using var run = await Memory(new MemoryNet(), askLink: true, oneWayMs: 30, waitMoved: false, only: false);
    await run.Client.WaitAsync(() => run.Client.AnswerSent, 5_000);
    // Right behind the answer: the host takes the answer, the link opens, and the client's marker queues behind this
    // relay frame (its ping) that takes 6.5 s to answer.
    await run.Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "ping", slowMs = 6_500 }));
    await run.Client.WaitAsync(() => run.Client.MovedAt is not null, 5_000);
    Assert.NotNull(run.Client.MovedAt);
    await run.Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1 }));
    await run.Client.WaitAsync(() => run.Client.Echoed.Contains(1), 12_000);
    Assert.Equal([1], run.App.Applied());
    Assert.False(run.Client.Closed, "the connection survived the slow answer");
    Assert.NotNull(run.Connection.LinkRoute(run.ChannelHex));
  }

  [Fact]
  public async Task KeystrokeEchoOnTheLinkAndAClientThatCannotLinkIsToldToUpdate()
  {
    await using (var run = await Memory(new MemoryNet(), askLink: true))
    {
      output.WriteLine($"MEASURE win-link-memory route={run.Connection.LinkRoute(run.ChannelHex)} connect-ms={run.Client.ConnectMs:0}");
      var times = await run.EchoesAsync(50);
      var median = LinkKit.Median(times);
      output.WriteLine($"MEASURE win-link-memory echo-median={median:0.0} p90={LinkKit.P90(times):0.0} max={times.Max():0.0} viaLink={run.Client.ViaLink} viaRelay={run.Client.ViaRelay}");
      Assert.True(median < 30, $"link echo {median}");
      Assert.Equal(1, run.Client.ViaRelay);
    }
    // The relay (132 ms each way) carries no keystrokes any more: an app that does not ask for the link is let go.
    await using (var old = await Memory(new MemoryNet(), askLink: false))
    {
      await old.Client.WaitAsync(() => old.Client.Closed, 5_000);
      Assert.True(old.Client.Closed);
      Assert.Null(old.Client.Welcome);
      Assert.Equal("version", Assert.Single(old.Client.Errors).Code);
      Assert.StartsWith("Update Terminal Deck on this phone to connect", old.Client.Errors[0].Message);
    }
  }

  private static Task<LinkHarness> Memory(MemoryNet net, bool askLink, bool forge = false, double oneWayMs = LinkKit.RelayOneWayMs, bool neverMark = false, bool waitMoved = true,
    Func<string, bool, Task>? release = null, PhoneAccess access = PhoneAccess.Full, bool only = true, TimeSpan? releaseAfter = null) =>
    LinkHarness.StartAsync(new LinkSetup(new MemoryEngine(net), (_, _) => ValueTask.FromResult(new LinkServers([LinkPaths.CloudflareStun], "all")))
    { Release = release ?? ((_, _) => Task.CompletedTask), ReleaseAfter = releaseAfter ?? TimeSpan.Zero },
      (_, events) => net.Make(events, offerer: false), askLink, forge, oneWayMs, neverMark, waitMoved, access: access, only: only);
}
