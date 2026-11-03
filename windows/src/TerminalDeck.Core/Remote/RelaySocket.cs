using System.Diagnostics;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public interface IRelaySocket : IAsyncDisposable
{
  Task ConnectAsync(Uri hostAddress, ReadOnlyMemory<byte> hostSecret, CancellationToken cancellationToken);
  ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken cancellationToken);
  ValueTask<byte[]?> ReceiveAsync(CancellationToken cancellationToken);
}

// No connection is made until explicitly requested by the composition root.
public sealed class RelayWebSocket : IRelaySocket
{
  private readonly ClientWebSocket socket = new();

  public async Task ConnectAsync(Uri hostAddress, ReadOnlyMemory<byte> hostSecret, CancellationToken cancellationToken)
  {
    RelayEndpoint.Validate(hostAddress);
    if (hostAddress.AbsolutePath != "/v1/host" || hostSecret.Length != 32)
      throw new ProtocolException("The host relay settings are unusable.");
    socket.Options.SetRequestHeader("x-deck-host-secret", Convert.ToBase64String(hostSecret.Span).TrimEnd('=').Replace('+', '-').Replace('/', '_'));
    socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
    socket.Options.KeepAliveTimeout = TimeSpan.FromSeconds(20);
    await socket.ConnectAsync(hostAddress, cancellationToken).ConfigureAwait(false);
  }

  public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken cancellationToken) =>
    socket.SendAsync(packet, WebSocketMessageType.Binary, true, cancellationToken);

  public async ValueTask<byte[]?> ReceiveAsync(CancellationToken cancellationToken)
  {
    using var assembled = new MemoryStream();
    var buffer = new byte[8192];
    while (true)
    {
      var result = await socket.ReceiveAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
      if (result.MessageType == WebSocketMessageType.Close) return null;
      if (result.MessageType != WebSocketMessageType.Binary || assembled.Length + result.Count > RelayPacket.HeaderBytes + RelayPacket.MaximumPayloadBytes)
        throw new ProtocolException("The relay packet is unusable.");
      assembled.Write(buffer, 0, result.Count);
      if (result.EndOfMessage) return assembled.ToArray();
    }
  }

  public ValueTask DisposeAsync() { socket.Abort(); socket.Dispose(); return ValueTask.CompletedTask; }
}

public interface IRelayMcpApplication
{
  ValueTask<IReadOnlyList<byte[]>> ReceiveAsync(ReadOnlyMemory<byte> payload, CancellationToken ct);
}

public sealed record PhoneApplicationReply(IReadOnlyList<byte[]> Messages, bool Close = false);

public interface IRelayPhoneApplication
{
  IReadOnlyCollection<byte[]> KnownPeers { get; }
  bool PairingOpen { get; }
  ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> peerKey, CancellationToken cancellationToken) =>
    ValueTask.FromResult(new PhoneApplicationReply([]));
  ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey,
    ReadOnlyMemory<byte> plaintext, CancellationToken cancellationToken);
  ValueTask DisconnectedAsync(string channel);
}

// A connection owns all channels. A socket's end releases their transports and application attachments, except a
// link-only phone whose link is up (contract §11.4): it lives on until its link ends.
// stream step 2 (dc2), link only (contract §11, batch #27): with a LinkSetup, a phone or browser that asks (`link.dc2`
// in its hello) is offered ONE WebRTC link right after the welcome (RelayHostConnection.Link.cs), and that link is the
// only way its data goes. With `link.only` on both ends the relay carries the meeting and nothing else: the sealed
// handshake, the hello and its replies (welcome, device.access, the hello's refusals, a pairing's credential) and
// `link.*`. A phone or browser that cannot make the link is refused at the hello; a desktop guest (another computer's
// "Other computers") keeps today's relay connection (§11.5).
public sealed partial class RelayHostConnection(NoiseIdentity identity, IRelayPhoneApplication application, IRelayMcpApplication? mcp = null, TimeProvider? time = null, IRelayReceiverApplication? receiver = null, LinkSetup? linkSetup = null) : IAsyncDisposable
{
  public static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(15);
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private sealed record Channel(byte[] Id, DateTimeOffset Deadline, NoiseTransport? Transport = null, byte[]? Peer = null);
  private readonly Dictionary<string, Channel> channels = [];
  private readonly SemaphoreSlim serial = new(1, 1);
  // The connection's one ordered way out: every packet to the relay socket (and, after a link's hand-over, every
  // message to that link's td.ctl) is written while holding it, so order is kept exactly across the switch.
  private readonly SemaphoreSlim writes = new(1, 1);
  // The connection's own lifetime: it outlives a relay socket when a link-only phone's link is up (§11.4).
  private readonly CancellationTokenSource life = new();
  // Desktop guests' channels: today's relay connection (contract §11.5), never a link.
  private readonly HashSet<string> guests = [];
  private int publisherSet;
  private bool disposed;

  /// One relay socket's run. `keepLinks` (the relay client): at the socket's end a link-only phone whose link is up
  /// stays (§11.4) and the next socket is served by this same connection; without it the connection ends with the socket.
  public async Task RunAsync(IRelaySocket socket, CancellationToken cancellationToken, bool keepLinks = false)
  {
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, life.Token);
    wireLifetime = lifetime.Token;
    wire = (packet, ct) => socket.SendAsync(packet, ct);
    var pending = new System.Collections.Concurrent.ConcurrentDictionary<string, (CancellationTokenSource Stop, Task Work)>();
    async Task SendAsync(IEnumerable<byte[]> frames)
    {
      await writes.WaitAsync(lifetime.Token);
      try { foreach (var frame in frames) await socket.SendAsync(frame, lifetime.Token); }
      finally { writes.Release(); }
    }
    SetPublisher();
    try
    {
      if (receiver is not null) await receiver.ConnectedAsync(async (packet, ct) =>
      {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        await writes.WaitAsync(linked.Token);
        try { await socket.SendAsync(packet.Encode(), linked.Token); }
        finally { writes.Release(); }
      }, lifetime.Token);
      if (mcp is not null) await SendAsync([new RelayPacket(RelayKind.McpReach, new byte[16], [1]).Encode()]);
      Task<byte[]?>? incoming = null;
      while (true)
      {
        incoming ??= socket.ReceiveAsync(lifetime.Token).AsTask();
        var delay = await NextHandshakeDelayAsync(lifetime.Token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var expired = Task.Delay(delay, clock, timeout.Token);
        if (await Task.WhenAny(incoming, expired).ConfigureAwait(false) != incoming)
        {
          lifetime.Token.ThrowIfCancellationRequested();
          await writes.WaitAsync(lifetime.Token);
          try { foreach (var close in await ExpireHandshakesAsync(lifetime.Token)) await socket.SendAsync(close, lifetime.Token); }
          finally { writes.Release(); }
          continue;
        }
        timeout.Cancel();
        var frame = await incoming.ConfigureAwait(false); incoming = null;
        if (frame is null) break;
        var packet = RelayPacket.Decode(frame);
        if (packet.Kind is RelayKind.ReceiverSync or RelayKind.ReceiverDelivery or RelayKind.ReceiverAck or RelayKind.ReceiverSynced)
        { if (receiver is not null) await receiver.FrameAsync(packet, lifetime.Token); continue; }
        if (packet.Kind == RelayKind.McpCancel) { if (pending.TryGetValue(packet.ChannelId, out var request)) { try { request.Stop.Cancel(); } catch (ObjectDisposedException) { } } continue; }
        if (packet.Kind == RelayKind.McpRequest)
        {
          if (mcp is null || pending.Count >= 8 || pending.ContainsKey(packet.ChannelId)) continue;
          var source = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); source.CancelAfter(TimeSpan.FromSeconds(150));
          var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          async Task ServeAsync()
          {
            await ready.Task;
            try
            {
              var replies = await mcp.ReceiveAsync(packet.Payload, source.Token);
              await SendAsync(replies.Select(reply => new RelayPacket(RelayKind.McpReply, packet.Channel, reply).Encode()));
            }
            catch (Exception ex) when (ex is OperationCanceledException or IOException or System.Net.WebSockets.WebSocketException) { }
            finally { pending.TryRemove(packet.ChannelId, out _); source.Dispose(); }
          }
          var work = ServeAsync(); pending[packet.ChannelId] = (source, work); ready.SetResult(); continue;
        }
        await writes.WaitAsync(lifetime.Token);
        try { foreach (var reply in await ProcessAsync(frame, lifetime.Token).ConfigureAwait(false)) await socket.SendAsync(reply, lifetime.Token); }
        finally { writes.Release(); }
      }
    }
    finally
    {
      wire = null;
      if (receiver is not null) await receiver.DisconnectedAsync();
      lifetime.Cancel(); await Task.WhenAll(pending.Values.Select(p => p.Work));
      if (keepLinks && !life.IsCancellationRequested) await EndSocketAsync().ConfigureAwait(false);
      else await DisposeAsync().ConfigureAwait(false);
    }
  }

  // Pushes (host events) for the whole connection, not one socket: a link-only phone's link carries them on while
  // the relay is away. Writer then serial: a reply being processed always reaches the wire before a later push.
  private void SetPublisher()
  {
    if (application is not TerminalDeck.Core.Integration.IW9PhonePushApplication push || Interlocked.Exchange(ref publisherSet, 1) != 0) return;
    push.SetPublisher(async (id, clear, ct) =>
    {
      using var pushLifetime = CancellationTokenSource.CreateLinkedTokenSource(ct, life.Token);
      var pushToken = pushLifetime.Token;
      await writes.WaitAsync(pushToken);
      try
      {
        byte[]? frame;
        await serial.WaitAsync(pushToken);
        try
        {
          if (disposed || !channels.TryGetValue(id, out var channel) || channel.Transport is null) return;
          frame = Outgoing(id, channel, clear);
        }
        finally { serial.Release(); }
        if (frame is not null && wire is { } send)
          try { await send(frame, wireLifetime); }
          catch (Exception ex) when (ex is OperationCanceledException or IOException or WebSocketException) { }
      }
      finally { writes.Release(); }
    });
  }

  // The relay socket ended: every channel goes with it except a link-only phone whose link is up (§11.4).
  private async ValueTask EndSocketAsync()
  {
    await serial.WaitAsync().ConfigureAwait(false);
    try
    {
      if (disposed) return;
      foreach (var id in channels.Keys.ToArray())
      {
        if (links.TryGetValue(id, out var link) && Survives(link)) { link.RelayGone = true; Trace.WriteLine(Stamp() + " link: relay closed; the direct link stays"); continue; }
        await RemoveAsync(id).ConfigureAwait(false);
      }
    }
    finally { serial.Release(); }
  }

  public async ValueTask<IReadOnlyList<byte[]>> ProcessAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken = default)
  {
    // Incoming traffic must not starve the quiet-socket deadline path.
    var expired = await ExpireHandshakesAsync(cancellationToken).ConfigureAwait(false);
    var replies = await ProcessPacketAsync(frame, cancellationToken).ConfigureAwait(false);
    return [..expired, ..replies];
  }

  private async ValueTask<IReadOnlyList<byte[]>> ProcessPacketAsync(ReadOnlyMemory<byte> frame, CancellationToken cancellationToken)
  {
    await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
    try
    {
      ObjectDisposedException.ThrowIf(disposed, this);
      var packet = RelayPacket.Decode(frame.Span);
      var id = packet.ChannelId;
      switch (packet.Kind)
      {
        case RelayKind.Open:
          if (channels.ContainsKey(id)) return [];
          if (channels.Count >= 16) return [Close(packet.Channel)];
          channels.Add(id, new Channel(packet.Channel, clock.GetUtcNow() + HandshakeTimeout));
          return [];
        case RelayKind.Close:
          // A link-only phone's relay channel closing leaves its link and its sessions alive (§11.4).
          if (links.TryGetValue(id, out var closing) && Survives(closing))
          {
            closing.RelayGone = true;
            Trace.WriteLine(Stamp() + " link: relay closed; the direct link stays");
            return [];
          }
          await RemoveAsync(id).ConfigureAwait(false);
          return [];
        case RelayKind.Data:
          if (!channels.TryGetValue(id, out var channel)) return [];
          try
          {
            if (channel.Transport is null)
            {
              if (channel.Deadline <= clock.GetUtcNow())
              {
                await RemoveAsync(id).ConfigureAwait(false);
                return [Close(packet.Channel)];
              }
              var message = RelayPacket.ReadHandshake(packet.Payload, opening: true);
              var answer = NoiseChannel.Respond(identity, message, application.KnownPeers, application.PairingOpen);
              channels[id] = channel with { Transport = answer.Transport, Peer = answer.PeerPublicKey };
              var opened = await application.OpenedAsync(id, answer.PeerPublicKey, cancellationToken).ConfigureAwait(false);
              var initial = new List<byte[]> { new RelayPacket(RelayKind.Data, packet.Channel, RelayPacket.FrameHandshake(answer.Reply)).Encode() };
              initial.AddRange(opened.Messages.Select(clear => new RelayPacket(RelayKind.Data, packet.Channel, answer.Transport.Send(clear)).Encode()));
              if (opened.Close) { initial.Add(Close(packet.Channel)); await RemoveAsync(id).ConfigureAwait(false); }
              return initial;
            }
            var clear = channel.Transport.Receive(packet.Payload);
            if (clear.Length > PhoneWire.MaximumMessageBytes) throw new ProtocolException("The phone message is too large.");
            // The client's link marker and signalling (stream step 2) belong to the connection, never the application.
            if (LinkSignal(id, clear)) return [];
            // Link only (§11.1): a link-only phone sends nothing else on the relay; anything else is dropped and logged,
            // never handled. (An older dc2 phone's relay messages are handled; their answers wait for the link.)
            if (links.TryGetValue(id, out var only) && only.LinkOnly)
            {
              Trace.WriteLine(Stamp() + " link: dropped a relay message (" + (LinkAsk.Type(clear) ?? "unreadable") + "): it belongs on the direct link");
              return [];
            }
            // Only the first message can be the hello that asks for a link.
            var hello = greeted.Add(id) && LinkAsk.Type(clear) == "hello";
            var ask = hello ? LinkAsk.From(clear) : default;
            Interlocked.Increment(ref relayAnswering);
            try { return await DeliverAsync(id, channel, clear, ask, cancellationToken, hello: hello).ConfigureAwait(false); }
            finally { Interlocked.Decrement(ref relayAnswering); }
          }
          catch (ProtocolException)
          {
            await RemoveAsync(id).ConfigureAwait(false);
            return [Close(packet.Channel)]; // No authentication detail is sent to the relay.
          }
        default: return []; // MCP packets belong to a separate authenticated door, not phone channels.
      }
    }
    finally { serial.Release(); }
  }

  // One client message through the application, from the relay or the link: the same door, the same checks. The
  // hello's replies go on the relay (the meeting); every other reply goes the connection's way out (Outgoing: the link,
  // or waiting for it; a desktop guest's relay). Called holding `serial`.
  private async ValueTask<IReadOnlyList<byte[]>> DeliverAsync(string id, Channel channel, byte[] clear, LinkAsk ask, CancellationToken cancellationToken,
    bool hello = false)
  {
    try
    {
      PhoneApplicationReply replies;
      try { replies = await application.ReceiveAsync(id, channel.Peer!, clear, cancellationToken).ConfigureAwait(false); }
      catch (Exception ex) when (ex is not ProtocolException && !(ex is OperationCanceledException && cancellationToken.IsCancellationRequested))
      {
        // Whatever escapes the whole handler chain is answered on this channel only: one bad
        // message must never end the relay loop for every phone (the Mac's rule).
        Trace.WriteLine("Phone message failed: " + ex.GetType().Name);
        replies = new([Unavailable(clear)]);
      }
      var messages = replies.Messages;
      HostLink? offer = null;
      // Who gets a link comes from the device record (pending and revoked devices get none); the welcome is only where
      // the capability is said. A phone or browser that gets no link is told why and let go: nothing else would ever
      // reach it (contract §11.5). A desktop guest keeps today's relay connection. A pairing hello's pending welcome
      // carries its credential and closes, as before.
      if (hello && !replies.Close && ApprovedWelcome(messages))
      {
        if (ask.Dc2 && linkSetup?.Eligible(channel.Peer!) is { } device && WithLinkCapability(messages, ask.Only) is { } welcomed)
        { messages = welcomed; offer = NewLink(id, channel, device, ask.Only); }
        else if (ask.Phone)
        {
          Trace.WriteLine(Stamp() + " link: refused a " + ask.Platform + " that cannot make the direct link (" + (!ask.Dc2 ? "an app too old for it" : linkSetup is null ? "no link on this connection" : "not approved") + ")");
          // Sealed before the channel goes (removing it disposes its transport).
          var told = Sealed(channel, ask.Dc2 ? LinkAsk.CannotLink() : LinkAsk.UpdateApp());
          await RemoveAsync(id).ConfigureAwait(false);
          return [told, Close(channel.Id)];
        }
        else guests.Add(id);
      }
      var packets = messages.Select(reply => Outgoing(id, channel, reply, meeting: hello)).OfType<byte[]>().ToList();
      if (replies.Close)
      {
        packets.Add(Close(channel.Id));
        await RemoveAsync(id).ConfigureAwait(false);
      }
      // The offer waits for the writer, so it follows the welcome on the wire.
      else if (offer is not null) StartLink(offer);
      return packets;
    }
    catch (ProtocolException)
    {
      await RemoveAsync(id).ConfigureAwait(false);
      return [Close(channel.Id)]; // No authentication detail is sent to the relay.
    }
  }

  // A message to the client: onto the link's td.ctl once this side has moved (contract §5); a link that refuses it has
  // failed: nothing more goes anywhere and the connection closes (fail-stop, §7). Before the move only the hello's
  // replies (`meeting`) are sealed onto the relay; anything else waits for the link and goes first on td.ctl right
  // after the marker (Hold, §11.2). A desktop guest's channel (no link) is today's relay connection. Anything else is
  // dropped: never the relay instead of the link.
  private byte[]? Outgoing(string id, Channel channel, byte[] message, bool meeting = false)
  {
    links.TryGetValue(id, out var link);
    if (link is { HostMoved: true })
    {
      if (!link.Dead && link.Connection?.Send(message, LinkLane.Control) == true) return null;
      if (!link.Dead) { link.Dead = true; _ = Task.Run(() => EndLinkAsync(link, "A message could not go on the direct link.")); }
      return null;
    }
    if (meeting) return Sealed(channel, message);
    if (link is not null) { Hold(link, message); return null; }
    return guests.Contains(id) ? Sealed(channel, message) : null;
  }

  private static byte[] Sealed(Channel channel, byte[] message) => new RelayPacket(RelayKind.Data, channel.Id, channel.Transport!.Send(message)).Encode();

  // The hello's replies hold an approved device's welcome (a pairing's pending welcome carries its credential).
  private static bool ApprovedWelcome(IReadOnlyList<byte[]> messages)
  {
    foreach (var raw in messages)
    {
      try
      {
        if (JsonNode.Parse(raw) is JsonObject welcome && welcome["t"] is JsonValue t && t.TryGetValue<string>(out var name) && name == "welcome")
          return welcome["token"] is null;
      }
      catch (JsonException) { }
    }
    return false;
  }

  internal static byte[] Unavailable(ReadOnlySpan<byte> request)
  {
    string? rid = null;
    try
    {
      using var doc = System.Text.Json.JsonDocument.Parse(request.ToArray());
      if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object && doc.RootElement.TryGetProperty("rid", out var r) && r.ValueKind == System.Text.Json.JsonValueKind.String) rid = r.GetString();
    }
    catch (System.Text.Json.JsonException) { }
    var error = new System.Text.Json.Nodes.JsonObject { ["t"] = "error", ["code"] = "unavailable", ["message"] = "That did not work on this computer." };
    if (rid is not null) error["rid"] = rid;
    return System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(error);
  }

  private async ValueTask<TimeSpan> NextHandshakeDelayAsync(CancellationToken ct)
  {
    await serial.WaitAsync(ct);
    try
    {
      var deadlines = channels.Values.Where(c => c.Transport is null).Select(c => c.Deadline).ToArray();
      if (deadlines.Length == 0) return Timeout.InfiniteTimeSpan;
      var delay = deadlines.Min() - clock.GetUtcNow();
      return delay > TimeSpan.Zero ? delay : TimeSpan.Zero;
    }
    finally { serial.Release(); }
  }

  public async ValueTask<IReadOnlyList<byte[]>> ExpireHandshakesAsync(CancellationToken ct = default)
  {
    await serial.WaitAsync(ct);
    try
    {
      ObjectDisposedException.ThrowIf(disposed, this);
      var expired = channels.Values.Where(c => c.Transport is null && c.Deadline <= clock.GetUtcNow()).ToArray();
      foreach (var channel in expired) await RemoveAsync(Convert.ToHexStringLower(channel.Id)).ConfigureAwait(false);
      return expired.Select(c => Close(c.Id)).ToArray();
    }
    finally { serial.Release(); }
  }

  private static byte[] Close(byte[] channel) => new RelayPacket(RelayKind.Close, channel, []).Encode();
  private async ValueTask RemoveAsync(string id)
  {
    if (!channels.Remove(id, out var old)) return;
    greeted.Remove(id); guests.Remove(id);
    if (links.TryRemove(id, out var link)) DropLink(link);
    old.Transport?.Dispose();
    await application.DisconnectedAsync(id).ConfigureAwait(false);
  }

  public async ValueTask DisposeAsync()
  {
    await serial.WaitAsync().ConfigureAwait(false);
    try
    {
      if (disposed) return;
      disposed = true;
      life.Cancel();
      foreach (var id in channels.Keys.ToArray()) await RemoveAsync(id).ConfigureAwait(false);
      if (Volatile.Read(ref publisherSet) != 0 && application is TerminalDeck.Core.Integration.IW9PhonePushApplication push) push.SetPublisher(null);
    }
    finally { serial.Release(); }
  }
}
