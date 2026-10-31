using System.Net.WebSockets;

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

// A connection epoch owns all channels. Disconnection releases their transports
// and application attachments before a new socket is allowed to replace them.
public sealed class RelayHostConnection(NoiseIdentity identity, IRelayPhoneApplication application, IRelayMcpApplication? mcp = null, TimeProvider? time = null) : IAsyncDisposable
{
  public static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(15);
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private sealed record Channel(byte[] Id, DateTimeOffset Deadline, NoiseTransport? Transport = null, byte[]? Peer = null);
  private readonly Dictionary<string, Channel> channels = [];
  private readonly SemaphoreSlim serial = new(1, 1);
  private bool disposed;

  public async Task RunAsync(IRelaySocket socket, CancellationToken cancellationToken)
  {
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    using var writes = new SemaphoreSlim(1);
    var pending = new System.Collections.Concurrent.ConcurrentDictionary<string, (CancellationTokenSource Stop, Task Work)>();
    async Task SendAsync(IEnumerable<byte[]> frames)
    {
      await writes.WaitAsync(lifetime.Token);
      try { foreach (var frame in frames) await socket.SendAsync(frame, lifetime.Token); }
      finally { writes.Release(); }
    }
    if (application is TerminalDeck.Core.Integration.IW9PhonePushApplication push)
      push.SetPublisher(async (id, clear, ct) =>
      {
        // Keep encryption sequence and socket order together. A reply being
        // processed always reaches the wire before a later pushed event.
        using var pushLifetime = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        var pushToken = pushLifetime.Token;
        await writes.WaitAsync(pushToken);
        try
        {
          await serial.WaitAsync(pushToken);
          try
          {
            if (disposed || !channels.TryGetValue(id, out var channel) || channel.Transport is null) return;
            var frame = new RelayPacket(RelayKind.Data, channel.Id, channel.Transport.Send(clear)).Encode();
            await socket.SendAsync(frame, pushToken);
          }
          finally { serial.Release(); }
        }
        finally { writes.Release(); }
      });
    try
    {
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
      if (application is TerminalDeck.Core.Integration.IW9PhonePushApplication endPush) endPush.SetPublisher(null);
      lifetime.Cancel(); await Task.WhenAll(pending.Values.Select(p => p.Work)); await DisposeAsync().ConfigureAwait(false);
    }
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
            var replies = await application.ReceiveAsync(id, channel.Peer!, clear, cancellationToken).ConfigureAwait(false);
            var packets = replies.Messages.Select(reply => new RelayPacket(RelayKind.Data, channel.Id, channel.Transport.Send(reply)).Encode()).ToList();
            if (replies.Close)
            {
              packets.Add(Close(channel.Id));
              await RemoveAsync(id).ConfigureAwait(false);
            }
            return packets;
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
      foreach (var id in channels.Keys.ToArray()) await RemoveAsync(id).ConfigureAwait(false);
    }
    finally { serial.Release(); }
  }
}
