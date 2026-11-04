using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// The answering end of the link (contract §1-§7 and §11) for a desktop guest: this PC's "Other computers" connected
// to another computer. The same client rules the phones and the web keep, so the host cannot tell a guest from a
// phone: the hello claims `link.dc2` + `link.only`; when the welcome offers the link, nothing app-level goes on the
// relay any more (§11.1): messages wait in order until this side has moved, then ride td.ctl (pings too), and the
// screen arrives as `sims.video` on td.rt / td.rel. The relay going away once a side has moved changes nothing
// (§11.4); the link ending does (the connection ends and is made afresh). No link: the plain truth, never the relay.
// A host that offers no link (an older computer) keeps today's relay connection, as §11.5 allows desktop guests.
public sealed class LinkGuest : IDisposable
{
  public static readonly string[] Capabilities = [LinkBinding.Capability, LinkBinding.OnlyCapability];
  /// No open link this long after the welcome: the host is not reachable directly (the host gives up at 10 s).
  public static readonly TimeSpan Deadline = TimeSpan.FromSeconds(15);
  /// Liveness on the link (§11.4): a ping every 25 s on td.ctl, its pong within 10 s.
  public static readonly TimeSpan Heartbeat = TimeSpan.FromSeconds(25);
  public static readonly TimeSpan PongWithin = TimeSpan.FromSeconds(10);
  public const string Unreachable = "This computer can't be reached directly: this network blocks the direct connection.";
  public const string Ended = "The direct link ended.";
  private static readonly byte[] EndText = "{\"t\":\"link.peer\",\"op\":\"end\"}"u8.ToArray();
  private static readonly byte[] PingText = "{\"t\":\"ping\"}"u8.ToArray();

  private readonly ILinkAnswerEngine engine;
  private readonly byte[] binding;
  private readonly Func<byte[], CancellationToken, Task> relay;
  private readonly Action<JsonElement> deliver;
  private readonly Action<Exception> fail;
  private readonly TimeProvider clock;
  private readonly object gate = new();
  private readonly SemaphoreSlim sendGate = new(1, 1);
  private readonly TaskCompletionSource movedSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly TaskCompletionSource endedSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly CancellationTokenSource stop = new();
  private readonly List<(string Candidate, string? Mid, int Index)> early = [];
  private readonly List<byte[]> held = [];
  private ILinkAnswerConnection? link;
  private int remoteCandidates;
  private bool hostOnly, hostMoved, serverHost;
  private string UnreachableReason => serverHost ? "Can't reach your server — this network blocks the direct connection." : Unreachable;
  private volatile bool moved, relayGone;
  private int ended;
  private long pingAt;
  private volatile bool awaitingPong;

  /// `relay` seals one message onto the relay; `deliver` takes every message from the host that is not signalling (in
  /// order on td.ctl; video as it comes); `fail` is told once, with the reason, when the link cannot carry on.
  public LinkGuest(ILinkAnswerEngine engine, ReadOnlySpan<byte> binding, Func<byte[], CancellationToken, Task> relay, Action<JsonElement> deliver,
    Action<Exception> fail, TimeProvider? clock = null)
  {
    this.engine = engine; this.binding = binding.ToArray(); this.relay = relay; this.deliver = deliver; this.fail = fail; this.clock = clock ?? TimeProvider.System;
  }

  /// The welcome offered the link: nothing app-level goes on the relay from now on.
  public bool Offered { get; private set; }
  /// This side has moved onto the link.
  public bool Moved => moved;
  /// The path the link runs on ("host", "internet", "turn") once moved.
  public string? Route { get; private set; }

  private static string Stamp() => DateTimeOffset.Now.ToString("o");

  /// The host's welcome: whether it offers the link (`link.dc2`) and speaks link only (`link.only`).
  public void Welcomed(JsonElement welcome)
  {
    var caps = welcome.TryGetProperty("capabilities", out var c) && c.ValueKind == JsonValueKind.Array
      ? c.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()).ToHashSet() : [];
    ValidateServerWelcome(welcome, canMakeLink: true);
    serverHost = IsServer(welcome);
    lock (gate) { hostOnly = caps.Contains(LinkBinding.OnlyCapability); Offered = caps.Contains(LinkBinding.Capability) || (serverHost && hostOnly); }
    if (caps.Contains(LinkBinding.Capability)) _ = DeadlineAsync();
  }

  /// A server has no legacy relay data path. Pairing receipts are admission only.
  public static void ValidateServerWelcome(JsonElement welcome, bool canMakeLink)
  {
    if (!IsServer(welcome) || (welcome.TryGetProperty("token", out var token) && token.ValueKind == JsonValueKind.String)) return;
    var capabilities = welcome.TryGetProperty("capabilities", out var values) && values.ValueKind == JsonValueKind.Array
      ? values.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()).ToHashSet() : [];
    if (!capabilities.Contains(LinkBinding.Capability) && !capabilities.Contains(LinkBinding.OnlyCapability))
      throw new ProtocolException("Update the host on your server to connect directly.");
    if (!canMakeLink) throw new ProtocolException("Can't reach your server — this network blocks the direct connection.");
  }

  private static bool IsServer(JsonElement welcome) => welcome.TryGetProperty("hostKind", out var kind) && kind.ValueKind == JsonValueKind.String && kind.GetString() == "headless";

  /// A relay message after the welcome. True = taken here (signalling, or dropped because it belongs on the link).
  public bool FromRelay(JsonElement message)
  {
    var type = message.TryGetProperty("t", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
    if (type == "link.peer") { Signal(message, fromLink: false); return true; }
    if (type == "link.moved") { HostMarker(); return true; }
    if (!Offered || type is "welcome" or "error" or "device.access") return false;
    // An older dc2 host still sends its own messages on the relay until its marker (§11.5); a link-only host never does.
    lock (gate) if (!hostOnly && !hostMoved) return false;
    Trace.WriteLine(Stamp() + " link: dropped a relay message (" + type + "): it belongs on the direct link");
    return true;
  }

  /// The relay went away. With the link up nothing changes (§11.4); before it there is no way left to the host.
  public void RelayClosed()
  {
    relayGone = true;
    if (moved) Trace.WriteLine(Stamp() + " link: relay closed; the direct link stays");
    else Fail(UnreachableReason);
  }

  /// One message to the host on td.ctl, waiting (in order) until this side has moved onto the link.
  public async Task SendAsync(byte[] message, CancellationToken ct)
  {
    if (!moved)
    {
      using var wait = CancellationTokenSource.CreateLinkedTokenSource(ct, stop.Token);
      try { await Task.WhenAny(movedSignal.Task, endedSignal.Task, Task.Delay(Deadline + TimeSpan.FromSeconds(5), clock, wait.Token)).ConfigureAwait(false); }
      catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
      ct.ThrowIfCancellationRequested();
    }
    if (!moved || Volatile.Read(ref ended) != 0) throw new IOException(moved ? Ended : UnreachableReason);
    await sendGate.WaitAsync(ct).ConfigureAwait(false);
    try
    {
      if (Volatile.Read(ref ended) != 0 || link?.Send(message, LinkLane.Control) != true) { Fail(Ended); throw new IOException(Ended); }
    }
    finally { sendGate.Release(); }
  }

  // ---- signalling ----------------------------------------------------------------------------------------------------

  private void Signal(JsonElement message, bool fromLink)
  {
    if (Volatile.Read(ref ended) != 0) return;
    string? Field(string name, int bytes) => message.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { } s && Encoding.UTF8.GetByteCount(s) <= bytes ? s : null;
    switch (Field("op", 16))
    {
      case "offer" when !fromLink:
        Offer(Field("sdp", 32_000), Field("fp", 200), Field("bind", 64), message);
        return;
      case "cand":
      {
        var candidate = Field("c", 2_000);
        var index = message.TryGetProperty("idx", out var i) && i.TryGetInt32(out var n) && n is >= 0 and <= 64 ? n : 0;
        // At most 32, never loopback, unspecified or multicast addresses (Security S4).
        if (candidate is null || Interlocked.Increment(ref remoteCandidates) > LinkCandidates.MostPerLink || !LinkCandidates.Usable(candidate)) return;
        ILinkAnswerConnection? current;
        lock (gate) { current = link; if (current is null) { early.Add((candidate, Field("mid", 32), index)); return; } }
        current.AddCandidate(candidate, Field("mid", 32), index);
        return;
      }
      case "end":
        Fail(moved ? Ended : UnreachableReason);
        return;
    }
  }

  private void Offer(string? sdp, string? fp, string? bind, JsonElement message)
  {
    lock (gate) if (link is not null) return;
    // The offer must carry its SDP's own fingerprint, bound to this pairing (§3); then the stack refuses any DTLS
    // certificate whose fingerprint differs from it.
    if (sdp is null || fp is null || !string.Equals(LinkBinding.Fingerprint(sdp), fp, StringComparison.Ordinal) || !LinkBinding.Check(bind, binding, "host", fp))
    {
      _ = RelayQuietlyAsync(EndText);
      Fail("This computer's direct-link offer did not match this pairing.");
      return;
    }
    var servers = new List<LinkIceServer>();
    if (message.TryGetProperty("ice", out var ice) && ice.ValueKind == JsonValueKind.Array)
      foreach (var row in ice.EnumerateArray().Take(8))
      {
        if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("urls", out var urls) || urls.ValueKind != JsonValueKind.Array) continue;
        // Only STUN/TURN servers (Security S3, #27), as the Mac guest and the phones take them.
        var list = urls.EnumerateArray().Where(u => u.ValueKind == JsonValueKind.String).Select(u => u.GetString()!)
          .Where(u => u.Length <= 512 && (u.StartsWith("stun:", StringComparison.Ordinal) || u.StartsWith("turn:", StringComparison.Ordinal) || u.StartsWith("turns:", StringComparison.Ordinal)))
          .Take(8).ToArray();
        if (list.Length == 0) continue;
        servers.Add(new(list, row.TryGetProperty("username", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null,
          row.TryGetProperty("credential", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString() : null));
      }
    var policy = message.TryGetProperty("policy", out var p) && p.ValueKind == JsonValueKind.String && p.GetString() is "nohost" or "relay" ? p.GetString()! : "all";
    var events = new LinkEvents(
      (candidate, mid, index) => _ = LocalCandidateAsync(candidate, mid, index),
      route => _ = OpenedAsync(route),
      why => { Trace.WriteLine(Stamp() + " link: ended " + why); Fail(moved ? Ended : UnreachableReason); },
      Arrived);
    ILinkAnswerConnection made;
    try { made = engine.ConnectAnswerer(new LinkServers(servers, policy), events); }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      Trace.WriteLine(Stamp() + " link: could not start (" + ex.Message + ")");
      _ = RelayQuietlyAsync(EndText);
      Fail("This PC can't make the direct connection: " + ex.Message);
      return;
    }
    (string Candidate, string? Mid, int Index)[] waiting;
    lock (gate)
    {
      if (Volatile.Read(ref ended) != 0 || link is not null) { made.Close(); return; }
      link = made; waiting = [.. early]; early.Clear();
    }
    foreach (var (candidate, mid, index) in waiting) made.AddCandidate(candidate, mid, index);
    _ = AnswerAsync(made, sdp);
  }

  private async Task AnswerAsync(ILinkAnswerConnection made, string offer)
  {
    try
    {
      var answer = await made.AnswerAsync(offer, stop.Token).ConfigureAwait(false);
      var mine = LinkBinding.Fingerprint(answer) ?? throw new InvalidOperationException("The answer has no DTLS fingerprint.");
      await relay(JsonSerializer.SerializeToUtf8Bytes(new JsonObject
      {
        ["t"] = "link.peer", ["op"] = "answer", ["sdp"] = answer, ["fp"] = mine, ["bind"] = LinkBinding.Make(binding, "client", mine)
      }), stop.Token).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      Trace.WriteLine(Stamp() + " link: the answer failed (" + ex.GetType().Name + ")");
      _ = RelayQuietlyAsync(EndText);
      Fail(UnreachableReason);
    }
  }

  // A local candidate: inside the sealed channel on the relay; once moved, on td.ctl too for a link-only host (§11.4).
  private async Task LocalCandidateAsync(string candidate, string? mid, int index)
  {
    if (Volatile.Read(ref ended) != 0 || Encoding.UTF8.GetByteCount(candidate) > 2000) return;
    var node = new JsonObject { ["t"] = "link.peer", ["op"] = "cand", ["c"] = candidate, ["idx"] = index };
    if (mid is not null) node["mid"] = mid;
    var message = JsonSerializer.SerializeToUtf8Bytes(node);
    bool onLink; lock (gate) onLink = moved && hostOnly;
    if (onLink) link?.Send(message, LinkLane.Control);
    if (!relayGone) await RelayQuietlyAsync(message).ConfigureAwait(false);
  }

  private async Task RelayQuietlyAsync(byte[] message)
  {
    try { await relay(message, stop.Token).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: signalling not sent (" + ex.GetType().Name + ")"); }
  }

  // td.ctl is open: the marker is this side's last relay message, then everything goes on the link (§5).
  private async Task OpenedAsync(string route)
  {
    await sendGate.WaitAsync().ConfigureAwait(false);
    try
    {
      if (moved || Volatile.Read(ref ended) != 0) return;
      if (!relayGone)
      {
        try { await relay(RelayMarker, stop.Token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { if (!hostOnly) { Fail(UnreachableReason); return; } }
      }
      Route = route; moved = true; movedSignal.TrySetResult();
    }
    finally { sendGate.Release(); }
    Trace.WriteLine(Stamp() + " link: up " + route);
    _ = HeartbeatAsync();
  }

  private static readonly byte[] RelayMarker = "{\"t\":\"link.moved\"}"u8.ToArray();

  // ---- what comes from the host ---------------------------------------------------------------------------------------

  private void HostMarker()
  {
    List<byte[]> waiting;
    lock (gate) { hostMoved = true; waiting = [.. held]; held.Clear(); }
    foreach (var data in waiting) Take(data, LinkLane.Control);
  }

  private void Arrived(byte[] data, LinkLane lane)
  {
    if (Volatile.Read(ref ended) != 0) return;
    lock (gate)
    {
      // §5: td.ctl waits for the host's marker, unless both speak link only (§11.2).
      if (lane == LinkLane.Control && !hostOnly && !hostMoved) { held.Add(data); return; }
    }
    Take(data, lane);
  }

  private void Take(byte[] data, LinkLane lane)
  {
    JsonElement message;
    try
    {
      using var document = JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = 32 });
      if (document.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException();
      message = document.RootElement.Clone();
    }
    catch (JsonException) { Fail("This computer sent an unusable message on the direct link."); return; }
    var type = message.TryGetProperty("t", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
    if (type is null) return;
    // td.rt / td.rel carry the screen and nothing else (contract §4; Security S3, #27): anything else there is dropped.
    if (lane != LinkLane.Control)
    {
      if (type == "sims.video") deliver(message);
      else Trace.WriteLine(Stamp() + " link: dropped a " + type + " that came on a video channel");
      return;
    }
    if (type.StartsWith("link.", StringComparison.Ordinal))
    {
      // §11.4: a link-only host's late candidates and its end come on td.ctl; any other link.* on the link is ignored.
      bool only; lock (gate) only = hostOnly;
      if (lane == LinkLane.Control && only && type == "link.peer") Signal(message, fromLink: true);
      return;
    }
    if (type == "pong" && lane == LinkLane.Control) { awaitingPong = false; return; }
    deliver(message);
  }

  // ---- liveness and the end -------------------------------------------------------------------------------------------

  private async Task DeadlineAsync()
  {
    try { await Task.Delay(Deadline, clock, stop.Token).ConfigureAwait(false); }
    catch (OperationCanceledException) { return; }
    if (moved || Volatile.Read(ref ended) != 0) return;
    if (!relayGone) await RelayQuietlyAsync(EndText).ConfigureAwait(false);
    Fail(UnreachableReason);
  }

  private async Task HeartbeatAsync()
  {
    pingAt = clock.GetTimestamp();
    try
    {
      while (!stop.IsCancellationRequested)
      {
        await Task.Delay(TimeSpan.FromSeconds(1), clock, stop.Token).ConfigureAwait(false);
        var since = clock.GetElapsedTime(pingAt);
        if (awaitingPong && since > PongWithin) { Fail("The other computer stopped answering on the direct link."); return; }
        if (awaitingPong || since < Heartbeat) continue;
        await sendGate.WaitAsync(stop.Token).ConfigureAwait(false);
        try
        {
          awaitingPong = true; pingAt = clock.GetTimestamp();
          if (link?.Send(PingText, LinkLane.Control) != true) { Fail(Ended); return; }
        }
        finally { sendGate.Release(); }
      }
    }
    catch (OperationCanceledException) { }
  }

  private void Fail(string why)
  {
    if (Interlocked.Exchange(ref ended, 1) != 0) return;
    Trace.WriteLine(Stamp() + " link: " + why);
    ILinkAnswerConnection? current;
    lock (gate) { current = link; held.Clear(); early.Clear(); }
    stop.Cancel();
    endedSignal.TrySetResult();
    try { current?.Close(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: close failed (" + ex.GetType().Name + ")"); }
    fail(new IOException(why));
  }

  public void Dispose()
  {
    if (Interlocked.Exchange(ref ended, 1) != 0) return;
    ILinkAnswerConnection? current;
    lock (gate) current = link;
    stop.Cancel();
    endedSignal.TrySetResult();
    try { current?.Close(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
