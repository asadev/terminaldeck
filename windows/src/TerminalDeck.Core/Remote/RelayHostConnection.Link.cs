using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// stream step 2 (dc2), the host side of the link (contract §1–§7 and §11; the Mac's BackendRemoteLink.swift is the
// reference).
//
// Link only (contract §11, batch #27, 3 Nov 2026; Asad: "keep the new two, direct link and TURN backup, and remove old
// relay completely... It's okay if it will not connect"): the link is the only way a phone's or browser's data goes.
// The relay carries the meeting: the hello and its replies, `link.peer` and the marker. Before this side moves,
// everything else for the client waits here (Hold) and goes first on td.ctl right after the marker. No link within
// LinkDeadline (or `end`, or a failure before the move) → `end`, and the sealed connection closes: the phone says it
// can't reach this PC directly and retries. Nothing goes over the relay instead.
// With `link.only` on both ends (§11.1-§11.4): the client's td.ctl is handled at once (nothing app-level crossed the
// relay, so there is nothing to hold it for); late `link.peer` cand/end may come on td.ctl; and once a side has moved
// the relay going away (the phone's relay channel, or this PC's own relay socket) leaves the connection and its link
// alive: it ends only when the link ends (§7 fail-stop), the device loses access, or the app stops.
// An older dc2 phone (no link.only, §11.5): its relay messages are still handled, their answers wait for the link,
// and its td.ctl waits for its own marker (§5).
//
// The switch point is the connection's one ordered writer (`writes`): the marker is this side's last relay message
// for the client, everything after it goes on the link's td.ctl, so order is kept exactly. A link that fails after
// either side moved closes the sealed connection (the client reconnects at once and is sent everything afresh), so a
// message lost in flight can never leave a hole in a terminal.
//
// Security (security-step2.md, Windows W1-W8): signalling only inside the sealed channel (the relay never sees an
// address, an SDP or a candidate); the DTLS fingerprints are protected by travelling only inside that Noise-encrypted,
// mutually authenticated channel (the `bind` tag over the channel binding is a consistency check, not a secret: the
// binding is public) and an SDP naming two different fingerprints is refused; a link only for an approved device with
// a link and a TURN login for every approved device (never pending or revoked; Hoot-only too, §11.6) on a sealed relay
// connection that asked; no TCP listener (TCP candidates off), only ephemeral UDP ICE sockets while a link is up; one
// TURN login per device, withdrawn 2 min after its last link closed or at once when it loses access; clients may
// write only td.ctl; at most 32 usable remote candidates; every message passes the same door; the link closes with
// the connection.
public sealed partial class RelayHostConnection
{
  /// No open link this long after the offer → `link.peer end` and the sealed connection closes (§11.3).
  public static readonly TimeSpan LinkDeadline = TimeSpan.FromSeconds(10);
  /// Link messages held before the client's marker: at most this long (and LinkFrames.MostJoinedBytes) (§5).
  public static readonly TimeSpan LinkHold = TimeSpan.FromSeconds(5);
  public static readonly byte[] MovedText = "{\"t\":\"link.moved\"}"u8.ToArray();
  private static readonly byte[] EndText = "{\"t\":\"link.peer\",\"op\":\"end\"}"u8.ToArray();

  private readonly ConcurrentDictionary<string, HostLink> links = new();
  private readonly HashSet<string> greeted = [];
  private Func<byte[], CancellationToken, ValueTask>? wire;
  // Relay frames being answered right now (they are answered one at a time): the hold waits while one is (W7).
  private int relayAnswering;
  private CancellationToken wireLifetime;

  /// This side moved a connection onto its link (contract §6: every running watch sends a keyframe first on the link).
  public event Action<string>? LinkMoved;

  private sealed class HostLink(string id, byte[] binding, string device)
  {
    public string Id { get; } = id;
    public byte[] Binding { get; } = binding;
    /// The paired device this connection belongs to (its own TURN login, Security M2).
    public string Device { get; } = device;
    public volatile bool Started;
    public int Candidates;
    public readonly object Gate = new();
    public ILinkConnection? Connection;
    public string Policy = "all";
    public long OfferedAt;
    public bool OfferSent;
    public bool Answered;
    public readonly List<byte[]> EarlyCandidates = [];
    public volatile bool Open;
    public volatile string Route = "";
    public volatile bool HostMoved;
    public volatile bool ClientMoved;
    public volatile bool Dead;
    /// Both ends speak link only (§11): nothing app-level crosses the relay, td.ctl is never held for the marker, and
    /// the link outlives the relay once a side has moved (§11.4).
    public bool LinkOnly;
    /// The relay side of this connection is gone (the phone's relay channel, or this PC's relay socket): the link alone
    /// carries it now (§11.4).
    public volatile bool RelayGone;
    public int Ended;
    public long InboxBytes;
    public readonly TaskCompletionSource ClientMovedSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly System.Threading.Channels.Channel<(byte[] Data, LinkLane Lane, long At)> Inbox =
      System.Threading.Channels.Channel.CreateUnbounded<(byte[], LinkLane, long)>(new System.Threading.Channels.UnboundedChannelOptions { SingleReader = true });
    public readonly CancellationTokenSource Stop = new();
    /// Messages for the client made before this side moved (under Gate): they go first on td.ctl after the marker.
    public readonly List<byte[]> Held = [];
    public long HeldBytes;
  }

  /// Video on the link (contract §6): null when the channel is not one of this connection's links; true when it went
  /// on `lane`; false when it was dropped (not moved yet, td.rt full, or the link is ending; never the relay instead).
  public bool? SendDirect(string channel, ReadOnlySpan<byte> message, LinkLane lane)
  {
    if (!links.TryGetValue(channel, out var link)) return null;
    if (!link.HostMoved || link.Dead || link.Connection is not { } connection) return false;
    // M5: over TCP every video message goes the reliable way (one channel, one order; nothing is ever given up).
    return connection.Send(message, lane == LinkLane.Moving && connection.OverTcp ? LinkLane.Still : lane);
  }

  /// How a connection's link carries video now (M5): null while it has not moved.
  public LinkVideo? LinkVideo(string channel) =>
    links.TryGetValue(channel, out var link) && link.HostMoved && !link.Dead && link.Connection is { } connection
      ? new LinkVideo(connection.OverTcp, connection.Queued(LinkLane.Moving), connection.Queued(LinkLane.Still)) : null;

  /// The path a connection's link runs on ("host", "internet", "turn"), null while it has not moved.
  public string? LinkRoute(string channel) => links.TryGetValue(channel, out var link) && link.HostMoved && !link.Dead ? link.Route : null;

  /// A connection whose link is still coming: nothing may be sent for it yet (video waits for the move).
  public bool AwaitsLink(string channel) => links.TryGetValue(channel, out var link) && !link.HostMoved && Volatile.Read(ref link.Ended) == 0;

  /// A connection with a live link (moved or about to): the only kind that may watch a screen (§11.7).
  public bool HasLink(string channel) => links.TryGetValue(channel, out var link) && Volatile.Read(ref link.Ended) == 0 && !link.Dead;

  // §11.4: a link-only connection that a side has moved onto its link outlives its relay.
  private static bool Survives(HostLink link) => link.LinkOnly && (link.HostMoved || link.ClientMoved) && Volatile.Read(ref link.Ended) == 0 && !link.Dead;

  // A message for the client before this side moved: it waits for the link (at most LinkFrames.MostJoinedBytes, else
  // the link has failed). A link that ended takes nothing more: the message is dropped, never sent over the relay.
  private void Hold(HostLink link, byte[] message)
  {
    bool over = false, moved;
    lock (link.Gate)
    {
      if (Volatile.Read(ref link.Ended) != 0) return;
      if (!(moved = link.HostMoved))
      {
        link.Held.Add(message);
        over = (link.HeldBytes += message.Length) > LinkFrames.MostJoinedBytes;
      }
    }
    // (Every writer holds `writes`, as the move does, so a message never finds the link moved here; if it ever did, it
    // goes on the link like any other.)
    if (moved && !link.Dead && link.Connection?.Send(message, LinkLane.Control) != true && !link.Dead)
    { link.Dead = true; _ = Task.Run(() => EndLinkAsync(link, "A message could not go on the direct link.")); }
    if (over) _ = Task.Run(() => EndLinkAsync(link, "Too much waited for the direct link."));
  }

  private static string Stamp() => DateTimeOffset.Now.ToString("o");

  // ---- who gets a link -------------------------------------------------------------------------------------------

  // The approved device's welcome with `link.dc2` (and `link.only` for a client that claimed it) added; null when the
  // reply holds none (a pairing welcome carries its new credential and closes; nothing else is a welcome).
  private static List<byte[]>? WithLinkCapability(IReadOnlyList<byte[]> messages, bool only)
  {
    for (var i = 0; i < messages.Count; i++)
    {
      JsonNode? root;
      try { root = JsonNode.Parse(messages[i]); }
      catch (JsonException) { continue; }
      if (root is not JsonObject welcome || welcome["t"] is not JsonValue type || !type.TryGetValue<string>(out var name) || name != "welcome") continue;
      if (welcome["token"] is not null) return null;
      if (welcome["capabilities"] is not JsonArray capabilities) welcome["capabilities"] = capabilities = [];
      foreach (var name2 in only ? new[] { LinkBinding.Capability, LinkBinding.OnlyCapability } : [LinkBinding.Capability])
        if (!capabilities.Any(c => c is JsonValue v && v.TryGetValue<string>(out var s) && s == name2)) capabilities.Add(name2);
      var copy = messages.ToList();
      copy[i] = JsonSerializer.SerializeToUtf8Bytes(welcome);
      return copy;
    }
    return null;
  }

  private HostLink NewLink(string id, Channel channel, string device, bool only)
  {
    var link = new HostLink(id, channel.Transport!.ChannelBinding.ToArray(), device) { LinkOnly = only };
    links[id] = link;
    return link;
  }

  // Under `serial`: the link is still this channel's and the channel is still open.
  private bool Current(HostLink link, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out Channel? channel)
  {
    channel = null;
    return links.TryGetValue(link.Id, out var current) && ReferenceEquals(current, link) &&
      channels.TryGetValue(link.Id, out channel) && channel.Transport is not null;
  }

  // ---- offer, candidates, hand-over --------------------------------------------------------------------------------

  private void StartLink(HostLink link) => _ = Task.Run(() => RunLinkAsync(link));

  private async Task RunLinkAsync(HostLink link)
  {
    var ct = link.Stop.Token;
    link.Started = true;
    try
    {
      var servers = await linkSetup!.Servers(link.Device, ct).ConfigureAwait(false);
      link.Policy = servers.Policy;
      var events = new LinkEvents(
        (candidate, mid, index) => Candidate(link, candidate, mid, index),
        route => _ = MoveAsync(link, route),
        why => _ = EndLinkAsync(link, why),
        (data, lane) => Arrived(link, data, lane));
      var connection = linkSetup.Engine.Connect(servers, events);
      lock (link.Gate)
      {
        if (Volatile.Read(ref link.Ended) != 0) { connection.Close(); return; }
        link.Connection = connection;
      }
      link.OfferedAt = clock.GetTimestamp();
      _ = Task.Run(() => ReadLinkAsync(link));
      var offer = await connection.OfferAsync(ct).ConfigureAwait(false);
      var fingerprint = LinkBinding.Fingerprint(offer) ?? throw new ProtocolException("The offer has no DTLS fingerprint.");
      var ice = new JsonArray();
      foreach (var server in servers.Servers.Take(8))
      {
        var row = new JsonObject { ["urls"] = new JsonArray(server.Urls.Select(u => (JsonNode)u).ToArray()) };
        if (server.Username is not null) row["username"] = server.Username;
        if (server.Credential is not null) row["credential"] = server.Credential;
        ice.Add(row);
      }
      await SignalAsync(link, JsonSerializer.SerializeToUtf8Bytes(new JsonObject
      {
        ["t"] = "link.peer", ["op"] = "offer", ["sdp"] = offer, ["fp"] = fingerprint,
        ["bind"] = LinkBinding.Make(link.Binding, "host", fingerprint), ["ice"] = ice, ["policy"] = servers.Policy
      })).ConfigureAwait(false);
      byte[][] early;
      lock (link.Gate) { link.OfferSent = true; early = [.. link.EarlyCandidates]; link.EarlyCandidates.Clear(); }
      foreach (var candidate in early) await SignalAsync(link, candidate).ConfigureAwait(false);
      await Task.Delay(LinkDeadline, clock, ct).ConfigureAwait(false);
      if (!link.Open) await EndLinkAsync(link, "No direct path within " + LinkDeadline.TotalSeconds + " s.").ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception ex)
    {
      Trace.WriteLine(Stamp() + " link: could not start (" + ex.GetType().Name + ")");
      await EndLinkAsync(link, "The direct link could not start.").ConfigureAwait(false);
    }
  }

  // A local candidate: trickled inside the sealed channel, never before the offer (the client has no peer
  // connection until the offer arrives). `nohost` (measurement only) sends no same-network candidates.
  private void Candidate(HostLink link, string candidate, string? mid, int index)
  {
    if (Volatile.Read(ref link.Ended) != 0 || Encoding.UTF8.GetByteCount(candidate) > 2000 || (mid is not null && Encoding.UTF8.GetByteCount(mid) > 32) || index is < 0 or > 64) return;
    if (link.Policy == "nohost" && LinkPaths.CandidateType(candidate) == "host") return;
    var node = new JsonObject { ["t"] = "link.peer", ["op"] = "cand", ["c"] = candidate, ["idx"] = index };
    if (mid is not null) node["mid"] = mid;
    var message = JsonSerializer.SerializeToUtf8Bytes(node);
    lock (link.Gate) if (!link.OfferSent) { link.EarlyCandidates.Add(message); return; }
    // §11.4: once moved, a link-only client takes late candidates from td.ctl (the relay may be gone); the relay gets
    // them too while it is still there.
    if (link.LinkOnly && link.HostMoved && !link.Dead) link.Connection?.Send(message, LinkLane.Control);
    if (!link.RelayGone) _ = SignalAsync(link, message);
  }

  // A `link.peer` frame, sealed onto the relay through the writer (signalling never goes on the link).
  private async Task SignalAsync(HostLink link, byte[] message)
  {
    var send = wire;
    if (send is null) return;
    var ct = wireLifetime;
    try
    {
      await writes.WaitAsync(ct).ConfigureAwait(false);
      try
      {
        byte[] packet;
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
          if (disposed || Volatile.Read(ref link.Ended) != 0 || link.RelayGone || !Current(link, out var channel)) return;
          packet = new RelayPacket(RelayKind.Data, channel.Id, channel.Transport!.Send(message)).Encode();
        }
        finally { serial.Release(); }
        await send(packet, ct).ConfigureAwait(false);
      }
      finally { writes.Release(); }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: signalling not sent (" + ex.GetType().Name + ")"); }
  }

  // Every channel is open: the marker goes as this side's last relay message for the client, and from then on
  // everything goes on the link, first what waited for it (Hold). Holding the writer across all of it, nothing can
  // slip between them. With the relay already gone (a link-only phone, §11.4) there is no marker to send: the client
  // takes td.ctl at once.
  private async Task MoveAsync(HostLink link, string route)
  {
    try
    {
      await writes.WaitAsync(life.Token).ConfigureAwait(false);
      try
      {
        byte[]? packet = null;
        await serial.WaitAsync(life.Token).ConfigureAwait(false);
        try
        {
          if (disposed || Volatile.Read(ref link.Ended) != 0 || link.Open || !Current(link, out var channel)) return;
          link.Open = true; link.Route = route;
          if (!link.RelayGone && wire is not null) packet = new RelayPacket(RelayKind.Data, channel.Id, channel.Transport!.Send(MovedText)).Encode();
          else if (!link.LinkOnly) { _ = Task.Run(() => EndLinkAsync(link, "The relay went away before the hand-over.")); return; }
        }
        finally { serial.Release(); }
        if (packet is not null && wire is { } send) await send(packet, wireLifetime).ConfigureAwait(false);
        List<byte[]> held;
        lock (link.Gate) { link.HostMoved = true; held = [.. link.Held]; link.Held.Clear(); link.HeldBytes = 0; }
        foreach (var message in held)
          if (link.Dead || link.Connection?.Send(message, LinkLane.Control) != true)
          {
            if (!link.Dead) { link.Dead = true; _ = Task.Run(() => EndLinkAsync(link, "A message could not go on the direct link.")); }
            break;
          }
      }
      finally { writes.Release(); }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      _ = EndLinkAsync(link, "The hand-over could not be sent (" + ex.GetType().Name + ").");
      return;
    }
    if (!link.HostMoved) return;
    Trace.WriteLine(Stamp() + " link: up " + route + " in " + (int)clock.GetElapsedTime(link.OfferedAt).TotalMilliseconds + " ms");
    try { LinkMoved?.Invoke(link.Id); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: moved handler failed (" + ex.GetType().Name + ")"); }
  }

  // ---- what comes from the client ---------------------------------------------------------------------------------

  // `link.moved` / `link.peer` on the relay (under `serial`): the client's marker and signalling. True = handled here.
  private bool LinkSignal(string id, byte[] clear)
  {
    var type = LinkFrame(clear, out var root);
    if (type is null) return false;
    links.TryGetValue(id, out var link);
    if (type == "link.moved")
    {
      if (link is null) return true;
      link.ClientMoved = true;
      link.ClientMovedSignal.TrySetResult();
      // Its link already ended here: what it sent there is lost, so the connection restarts cleanly.
      if (Volatile.Read(ref link.Ended) != 0) _ = Task.Run(() => FailStopOrTellAsync(link, tell: false));
      return true;
    }
    if (link is null || Volatile.Read(ref link.Ended) != 0 || root is null) return true;
    Peer(link, root.Value);
    return true;
  }

  // "link.moved" / "link.peer" when the text is one of those frames, else null.
  private static string? LinkFrame(ReadOnlySpan<byte> clear, out JsonElement? root)
  {
    root = null;
    if (clear.IndexOf("link."u8) < 0) return null;
    try
    {
      using var document = JsonDocument.Parse(clear.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
      if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.String) return null;
      var type = t.GetString();
      if (type is not ("link.moved" or "link.peer")) return null;
      root = document.RootElement.Clone();
      return type;
    }
    catch (JsonException) { return null; }
  }

  private void Peer(HostLink link, JsonElement root)
  {
    string? op, sdp, fp, bind, candidate, mid;
    var index = 0;
    try
    {
      op = Field(root, "op", 16); sdp = Field(root, "sdp", 32_000); fp = Field(root, "fp", 200); bind = Field(root, "bind", 64);
      candidate = Field(root, "c", 2_000); mid = Field(root, "mid", 32);
      if (root.TryGetProperty("idx", out var idx) && idx.ValueKind != JsonValueKind.Null && (!idx.TryGetInt32(out index) || index is < 0 or > 64)) throw new FormatException();
    }
    catch (Exception ex) when (ex is FormatException or InvalidOperationException)
    {
      _ = EndLinkAsync(link, "The device sent unusable signalling.");
      return;
    }
    switch (op)
    {
      case "answer":
        ILinkConnection? connection;
        lock (link.Gate) { connection = link.Answered ? null : link.Connection; link.Answered = true; }
        // The answer must carry its SDP's own fingerprint, bound to this pairing (§3); then the stack refuses any
        // DTLS certificate whose fingerprint differs from it.
        if (connection is null || sdp is null || fp is null || !string.Equals(LinkBinding.Fingerprint(sdp), fp, StringComparison.Ordinal) ||
          !LinkBinding.Check(bind, link.Binding, "client", fp))
        {
          _ = EndLinkAsync(link, "The device's answer did not match this pairing.");
          return;
        }
        _ = AcceptAsync(link, connection, sdp);
        return;
      case "cand":
        // At most 32, and never loopback, unspecified, multicast or broadcast addresses (W6).
        if (candidate is null || link.Candidates >= LinkCandidates.MostPerLink || !LinkCandidates.Usable(candidate)) return;
        link.Candidates++;
        { ILinkConnection? current; lock (link.Gate) current = link.Connection; current?.AddCandidate(candidate, mid, index); }
        return;
      case "end":
        _ = EndLinkAsync(link, "The device ended it.", tell: false);
        return;
      default:
        _ = EndLinkAsync(link, "The device sent unusable signalling.");
        return;
    }
  }

  private static string? Field(JsonElement root, string name, int bytes)
  {
    if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
    if (value.ValueKind != JsonValueKind.String) throw new FormatException();
    var text = value.GetString()!;
    return Encoding.UTF8.GetByteCount(text) <= bytes ? text : throw new FormatException();
  }

  private async Task AcceptAsync(HostLink link, ILinkConnection connection, string answer)
  {
    try { await connection.AcceptAsync(answer, link.Stop.Token).ConfigureAwait(false); }
    catch (OperationCanceledException) when (link.Stop.IsCancellationRequested) { }
    catch (Exception ex) when (ex is not OutOfMemoryException) { await EndLinkAsync(link, "The device's answer could not be used.").ConfigureAwait(false); }
  }

  // From the stack, in arrival order: queued for the reader (td.ctl waits there for the client's marker).
  private void Arrived(HostLink link, byte[] data, LinkLane lane)
  {
    if (Volatile.Read(ref link.Ended) != 0) return;
    if (Interlocked.Add(ref link.InboxBytes, data.Length) > LinkFrames.MostJoinedBytes)
    {
      _ = EndLinkAsync(link, "Too much arrived on the direct link before its hand-over.");
      return;
    }
    link.Inbox.Writer.TryWrite((data, lane, clock.GetTimestamp()));
  }

  private async Task ReadLinkAsync(HostLink link)
  {
    try
    {
      await foreach (var (data, lane, at) in link.Inbox.Reader.ReadAllAsync(link.Stop.Token).ConfigureAwait(false))
      {
        try
        {
          // A client writes only on td.ctl (contract §4, W3): anything on a video channel ends the link.
          if (lane != LinkLane.Control)
          {
            await EndLinkAsync(link, "The device wrote on a video channel.").ConfigureAwait(false);
            return;
          }
          // td.ctl only after the client's marker (§5); with link only on both ends at once (§11.2).
          if (!link.LinkOnly && !link.ClientMoved && !await WaitForClientAsync(link, LinkHold - clock.GetElapsedTime(at)).ConfigureAwait(false))
          {
            await EndLinkAsync(link, "The device's hand-over never came.").ConfigureAwait(false);
            return;
          }
          await TakeFromLinkAsync(link, data).ConfigureAwait(false);
        }
        finally { Interlocked.Add(ref link.InboxBytes, -data.Length); }
      }
    }
    catch (OperationCanceledException) when (link.Stop.IsCancellationRequested) { }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      Trace.WriteLine(Stamp() + " link: reader stopped (" + ex.GetType().Name + ")");
      await EndLinkAsync(link, "A message from the direct link could not be handled.").ConfigureAwait(false);
    }
  }

  // The hold (§5). The client's marker is read only after the relay frames before it are answered (one at a time, under
  // `serial`), so while a relay frame is still being answered (a slow attach, say) the hold waits on (W7, Mac N3),
  // bounded by the 4 MiB inbox limit and by the connection itself.
  private async Task<bool> WaitForClientAsync(HostLink link, TimeSpan left)
  {
    while (true)
    {
      if (link.ClientMoved) return true;
      if (left > TimeSpan.Zero)
      {
        try { await link.ClientMovedSignal.Task.WaitAsync(left, clock, link.Stop.Token).ConfigureAwait(false); return link.ClientMoved; }
        catch (TimeoutException) { }
      }
      if (Volatile.Read(ref relayAnswering) == 0) return link.ClientMoved;
      left = LinkHold;
    }
  }

  /// The device lost access or was unpaired (trust change): its links end now (fail-stop after the move).
  public void EndLinksFor(string device)
  {
    foreach (var link in links.Values.Where(l => l.Device == device && Volatile.Read(ref l.Ended) == 0).ToArray())
      _ = EndLinkAsync(link, "The device's access changed.");
  }

  // One client message from the link: exactly the relay's door (DeliverAsync), replies through the writer. It never
  // needs the relay (a link-only phone's link carries on while the relay is away, §11.4).
  private async Task TakeFromLinkAsync(HostLink link, byte[] data)
  {
    if (LinkFrame(data, out var root) is { } kind)
    {
      // §11.4: a link-only client's late candidates and its `end` come on td.ctl; any other `link.*` on the link is
      // ignored (§5).
      if (link.LinkOnly && kind == "link.peer" && root is { } peer && peer.TryGetProperty("op", out var op) && op.ValueKind == JsonValueKind.String && op.GetString() is "cand" or "end")
      {
        await serial.WaitAsync(life.Token).ConfigureAwait(false);
        try { if (Volatile.Read(ref link.Ended) == 0) Peer(link, peer); }
        finally { serial.Release(); }
      }
      return;
    }
    await writes.WaitAsync(life.Token).ConfigureAwait(false);
    try
    {
      IReadOnlyList<byte[]> packets;
      await serial.WaitAsync(life.Token).ConfigureAwait(false);
      try
      {
        if (disposed || Volatile.Read(ref link.Ended) != 0 || !Current(link, out var channel)) return;
        if (data.Length > PhoneWire.MaximumMessageBytes) { await RemoveAsync(link.Id).ConfigureAwait(false); packets = [Close(channel.Id)]; }
        else packets = await DeliverAsync(link.Id, channel, data, default, life.Token).ConfigureAwait(false);
      }
      finally { serial.Release(); }
      // Relay packets (only ever a close) while the relay is there.
      if (packets.Count > 0 && !link.RelayGone && wire is { } send)
        try { foreach (var packet in packets) await send(packet, wireLifetime).ConfigureAwait(false); }
        catch (Exception ex) when (ex is OperationCanceledException or IOException or System.Net.WebSockets.WebSocketException) { }
    }
    finally { writes.Release(); }
  }

  // ---- the end ---------------------------------------------------------------------------------------------------

  // The link ended (at most once). Before either side moved: `link.peer end` (unless the client ended it), then the
  // sealed connection closes (§11.3: no direct path; the phone says it can't reach this PC and retries). After: the
  // sealed connection closes (contract §7). Either way what waited for the link goes with it.
  private async Task EndLinkAsync(HostLink link, string why, bool tell = true)
  {
    if (!Stop(link)) return;
    Trace.WriteLine(Stamp() + " link: ended " + why);
    await FailStopOrTellAsync(link, tell).ConfigureAwait(false);
  }

  private static bool Stop(HostLink link)
  {
    if (Interlocked.Exchange(ref link.Ended, 1) != 0) return false;
    link.Dead = true;
    ILinkConnection? connection;
    lock (link.Gate) { connection = link.Connection; link.Held.Clear(); link.HeldBytes = 0; }
    link.Inbox.Writer.TryComplete();
    link.Stop.Cancel();
    try { connection?.Close(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: close failed (" + ex.GetType().Name + ")"); }
    return true;
  }

  // Decided holding the writer, so an in-flight marker (either side's) is always seen. Needs no relay: with the relay
  // gone the connection simply ends here.
  private async Task FailStopOrTellAsync(HostLink link, bool tell)
  {
    try
    {
      await writes.WaitAsync(life.Token).ConfigureAwait(false);
      try
      {
        var packets = new List<byte[]>(2);
        await serial.WaitAsync(life.Token).ConfigureAwait(false);
        try
        {
          if (disposed || !Current(link, out var channel)) return;
          var moved = link.HostMoved || link.ClientMoved;
          // Messages in flight on a dead link cannot be recovered: the client reconnects, attaches and replays.
          Trace.WriteLine(Stamp() + " link: closing the connection (" + (moved ? "The direct link ended." : "This device can't be reached directly.") + ")");
          if (!link.RelayGone && wire is not null)
          {
            if (!moved && tell) packets.Add(new RelayPacket(RelayKind.Data, channel.Id, channel.Transport!.Send(EndText)).Encode());
            packets.Add(Close(channel.Id));
          }
          await RemoveAsync(link.Id).ConfigureAwait(false);
        }
        finally { serial.Release(); }
        if (wire is { } send) foreach (var packet in packets) await send(packet, wireLifetime).ConfigureAwait(false);
      }
      finally { writes.Release(); }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(Stamp() + " link: end not sent (" + ex.GetType().Name + ")"); }
  }

  // The channel closed for any reason: its link goes with it, and when it was that device's last link its TURN login
  // is withdrawn (only the login this run gave it, so a reconnect's fresh one survives — Security M2/R1).
  private void DropLink(HostLink link)
  {
    var had = link.Connection is not null;
    if (Stop(link) && had) Trace.WriteLine(Stamp() + " link: ended The connection closed.");
    // §11.6: the login stays ReleaseAfter (2 min) so a reconnect reuses it; then it is withdrawn unless the device has
    // a link again.
    if (link.Started && !links.Values.Any(l => l.Device == link.Device) && linkSetup is { } setup)
      _ = Task.Run(async () =>
      {
        if (setup.ReleaseAfter > TimeSpan.Zero) await Task.Delay(setup.ReleaseAfter, clock).ConfigureAwait(false);
        if (!links.Values.Any(l => l.Device == link.Device)) await setup.Release(link.Device, false).ConfigureAwait(false);
      });
  }
}

/// What a hello says about the link (contract §11): whether the client answers one (`link.dc2`), speaks link only
/// (`link.only`), and whether it is a phone or a browser (nothing but the link would reach it) or a desktop guest
/// (another computer's "Other computers", which keeps today's relay connection, §11.5).
public readonly record struct LinkAsk(bool Dc2, bool Only, bool Phone, string Platform)
{
  // A desktop guest says its OS the way Node / .NET name it; a phone says "iOS 26.1" / "android", a browser "web".
  private static readonly string[] Desktops = ["win32", "windows", "darwin", "macos", "mac", "linux"];

  public static LinkAsk From(ReadOnlySpan<byte> hello)
  {
    try
    {
      using var document = JsonDocument.Parse(hello.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
      var root = document.RootElement;
      if (root.ValueKind != JsonValueKind.Object) return default;
      bool dc2 = false, only = false;
      if (root.TryGetProperty("capabilities", out var caps) && caps.ValueKind == JsonValueKind.Array)
        foreach (var c in caps.EnumerateArray().Take(64))
          if (c.ValueKind == JsonValueKind.String) { var name = c.GetString(); dc2 |= name == LinkBinding.Capability; only |= name == LinkBinding.OnlyCapability; }
      var platform = root.TryGetProperty("device", out var device) && device.ValueKind == JsonValueKind.Object && device.TryGetProperty("platform", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "";
      var phone = !Desktops.Contains(platform.Trim().ToLowerInvariant());
      return new(dc2, dc2 && only, phone, platform.Length > 40 ? platform[..40] : platform);
    }
    catch (JsonException) { return default; }
  }

  /// The message's `t`, or null when it has none.
  public static string? Type(ReadOnlySpan<byte> clear)
  {
    try
    {
      var reader = new Utf8JsonReader(clear, new JsonReaderOptions { MaxDepth = 64 });
      if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
      while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
      {
        var isType = reader.ValueTextEquals("t"u8);
        if (!reader.Read()) return null;
        if (isType) return reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
        reader.Skip();
      }
      return null;
    }
    catch (JsonException) { return null; }
  }

  /// §11.5: a phone or browser too old for the link, refused at the hello (the connection closes).
  public static byte[] UpdateApp() => JsonSerializer.SerializeToUtf8Bytes(new JsonObject
  {
    ["t"] = "error", ["code"] = "version",
    ["message"] = "Update Terminal Deck on this phone to connect: this PC now connects to phones directly."
  });

  /// An approved phone that asked for the link but gets none on this connection (no stack here, not approved now).
  public static byte[] CannotLink() => JsonSerializer.SerializeToUtf8Bytes(new JsonObject
  {
    ["t"] = "error", ["code"] = "unavailable",
    ["message"] = "This PC can't make a direct connection to this device right now. Retry the connection."
  });
}
