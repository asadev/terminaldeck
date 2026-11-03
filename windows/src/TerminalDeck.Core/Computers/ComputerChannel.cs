using System.Net.WebSockets;
using System.Runtime.ExceptionServices;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Computers;

// The joining socket carries sealed frames directly. RelayPacket headers exist
// only on the host multiplexing side, not here.
// Link only (contract §11, batch #27): with a LinkEngine the hello asks for the direct link; when the welcome offers it,
// everything after the welcome rides the link (LinkGuest) and the relay is only the meeting point. One inbox carries
// what arrives either way, in order per way; ReceiveAsync reads it.
public sealed class ComputerChannel : IAsyncDisposable
{
  private readonly ClientWebSocket socket = new();
  private readonly SemaphoreSlim writes = new(1);
  private readonly CancellationTokenSource life = new();
  private readonly System.Threading.Channels.Channel<JsonElement> inbox = System.Threading.Channels.Channel.CreateUnbounded<JsonElement>();
  private NoiseTransport? transport;
  private LinkGuest? guest;
  private volatile bool welcomed;
  private int disposed;

  /// Set before OpenAsync to ask for the direct link (§11); null keeps the relay connection (the pairing lookups).
  public ILinkAnswerEngine? LinkEngine { get; init; }
  /// What the hello claims about the link.
  public IReadOnlyList<string> LinkCapabilities => LinkEngine is null ? [] : LinkGuest.Capabilities;
  /// The connection runs on its direct link now ("host", "internet", "turn"), or null.
  public string? LinkRoute => guest is { Moved: true } g ? g.Route : null;

  public async Task OpenAsync(MachineOffer host, NoiseIdentity identity, CancellationToken ct)
  {
    socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(10);
    socket.Options.KeepAliveTimeout = TimeSpan.FromSeconds(30);
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
    deadline.CancelAfter(TimeSpan.FromSeconds(15));
    await socket.ConnectAsync(RelayEndpoint.Join(host.RelayUrl, host.HostId), deadline.Token);
    var start = NoiseChannel.Start(identity, host.PublicKey);
    using (start.Pending)
    {
      await socket.SendAsync(RelayPacket.FrameHandshake(start.Message), WebSocketMessageType.Binary, true, deadline.Token);
      transport = NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(await ReceiveBytesAsync(deadline.Token), false));
    }
    if (LinkEngine is { } engine)
      guest = new LinkGuest(engine, transport.ChannelBinding, SendSealedAsync, message => inbox.Writer.TryWrite(message), ex => inbox.Writer.TryComplete(ex));
    _ = Task.Run(ReadRelayAsync);
  }

  public async Task SendAsync(object message, CancellationToken ct)
  {
    var clear = JsonSerializer.SerializeToUtf8Bytes(message);
    // §11.1: after a welcome that offered the link, nothing app-level goes on the relay.
    if (welcomed && guest is { Offered: true } link) { await link.SendAsync(clear, ct); return; }
    if (clear.Length > 93528) throw new ProtocolException("The computer message is too large.");
    await SendSealedAsync(clear, ct);
  }

  private async Task SendSealedAsync(byte[] clear, CancellationToken ct)
  {
    await writes.WaitAsync(ct);
    try
    {
      if (transport is null) throw new ProtocolException("That computer is disconnected.");
      await socket.SendAsync(transport.Send(clear), WebSocketMessageType.Binary, true, ct);
    }
    finally { writes.Release(); }
  }

  public async Task<JsonElement> ReceiveAsync(CancellationToken ct)
  {
    if (transport is null) throw new ProtocolException("That computer is disconnected.");
    try { return await inbox.Reader.ReadAsync(ct); }
    catch (System.Threading.Channels.ChannelClosedException closed) when (closed.InnerException is { } inner)
    {
      ExceptionDispatchInfo.Capture(inner).Throw();
      throw;
    }
  }

  private async Task ReadRelayAsync()
  {
    try
    {
      while (true)
      {
        var clear = transport!.Receive(await ReceiveBytesAsync(life.Token));
        if (clear.Length > 93528) throw new ProtocolException("That computer sent a message that is too large.");
        JsonElement message;
        try
        {
          using var json = JsonDocument.Parse(clear, new JsonDocumentOptions { MaxDepth = 32 });
          if (json.RootElement.ValueKind != JsonValueKind.Object || !json.RootElement.TryGetProperty("t", out var tag) || tag.ValueKind != JsonValueKind.String)
            throw new ProtocolException("That computer sent an invalid message.");
          message = json.RootElement.Clone();
        }
        catch (JsonException) { throw new ProtocolException("That computer sent an invalid message."); }
        if (welcomed && guest is not null && guest.FromRelay(message)) continue;
        if (!welcomed && message.GetProperty("t").GetString() == "welcome") { guest?.Welcomed(message); welcomed = true; }
        inbox.Writer.TryWrite(message);
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // §11.4: once on the link, the relay going away changes nothing; before it, the connection is over.
      if (guest is { Offered: true } link && welcomed)
      {
        link.RelayClosed();
        if (link.Moved) return;
      }
      inbox.Writer.TryComplete(ex is IOException or ProtocolException or WebSocketException or OperationCanceledException ? ex : new IOException("That computer disconnected.", ex));
    }
  }

  private async Task<byte[]> ReceiveBytesAsync(CancellationToken ct)
  {
    using var bytes = new MemoryStream(); var buffer = new byte[8192];
    while (true)
    {
      var next = await socket.ReceiveAsync(buffer.AsMemory(), ct);
      if (next.MessageType == WebSocketMessageType.Close) throw new IOException("That computer disconnected.");
      if (next.MessageType != WebSocketMessageType.Binary || bytes.Length + next.Count > 98304)
        throw new ProtocolException("That computer sent an invalid sealed frame.");
      bytes.Write(buffer, 0, next.Count);
      if (next.EndOfMessage) return bytes.ToArray();
    }
  }

  public ValueTask DisposeAsync()
  {
    if (Interlocked.Exchange(ref disposed, 1) == 0)
    {
      life.Cancel(); guest?.Dispose();
      socket.Abort(); socket.Dispose(); transport?.Dispose();
      inbox.Writer.TryComplete(new IOException("That computer disconnected."));
    }
    return ValueTask.CompletedTask;
  }
}
