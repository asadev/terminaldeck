using System.Threading.Channels;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class RelayDeadlineTests
{
  private static byte[] Frame(RelayKind kind, byte id, byte[]? payload = null) => new RelayPacket(kind, [id, ..new byte[15]], payload ?? []).Encode();
  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Now = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
    public TaskCompletionSource<Tick> Next = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public sealed class Tick(TimerCallback callback, object? state) : ITimer
    {
      public bool Closed;
      public void Fire() { if (!Closed) callback(state); }
      public bool Change(TimeSpan dueTime, TimeSpan period) => !Closed;
      public void Dispose() => Closed = true;
      public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
      var tick = new Tick(callback, state); Next.TrySetResult(tick); return tick;
    }
  }
  [Fact]
  public async Task StalledHandshakeExpiresAtTheBoundaryAndFreesItsSlot()
  {
    using var host = NoiseIdentity.Generate(); var app = new TestApplication(); var clock = new Clock();
    await using var connection = new RelayHostConnection(host, app, time: clock);
    for (byte i = 0; i < 16; i++) await connection.ProcessAsync(Frame(RelayKind.Open, i));
    clock.Now += RelayHostConnection.HandshakeTimeout - TimeSpan.FromMilliseconds(1);
    Assert.Empty(await connection.ExpireHandshakesAsync());
    clock.Now += TimeSpan.FromMilliseconds(1);
    var expired = await connection.ExpireHandshakesAsync();
    Assert.Equal(16, expired.Count); Assert.All(expired, f => Assert.Equal(RelayKind.Close, RelayPacket.Decode(f).Kind));
    Assert.Equal(16, app.Disconnections);
    Assert.Empty(await connection.ExpireHandshakesAsync());
    Assert.Empty(await connection.ProcessAsync(Frame(RelayKind.Open, 20)));
  }
  [Fact]
  public async Task LateHandshakeCannotReviveAnExpiredChannel()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate(); var clock = new Clock();
    var app = new TestApplication { PairingOpen = true };
    await using var connection = new RelayHostConnection(host, app, time: clock);
    await connection.ProcessAsync(Frame(RelayKind.Open, 1)); clock.Now += RelayHostConnection.HandshakeTimeout;
    var start = NoiseChannel.Start(phone, host.PublicKey); using var pending = start.Pending;
    var closed = Assert.Single(await connection.ProcessAsync(Frame(RelayKind.Data, 1, RelayPacket.FrameHandshake(start.Message))));
    Assert.Equal(RelayKind.Close, RelayPacket.Decode(closed).Kind);
    Assert.Equal(1, app.Disconnections); Assert.Equal(0, app.Messages);
  }
  [Fact]
  public async Task CompletedHandshakeSurvivesWhileUnfinishedNeighboursExpire()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate(); var clock = new Clock();
    var app = new TestApplication { PairingOpen = true };
    await using var connection = new RelayHostConnection(host, app, time: clock);
    await connection.ProcessAsync(Frame(RelayKind.Open, 1)); await connection.ProcessAsync(Frame(RelayKind.Open, 2));
    var start = NoiseChannel.Start(phone, host.PublicKey);
    var reply = Assert.Single(await connection.ProcessAsync(Frame(RelayKind.Data, 1, RelayPacket.FrameHandshake(start.Message))));
    using var transport = NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(RelayPacket.Decode(reply).Payload, false));
    clock.Now += TimeSpan.FromMinutes(5);
    var expired = RelayPacket.Decode(Assert.Single(await connection.ExpireHandshakesAsync()));
    Assert.Equal(2, expired.Channel[0]); Assert.Equal(1, app.Disconnections);
    await connection.ProcessAsync(Frame(RelayKind.Data, 1, transport.Send([1]))); Assert.Equal(1, app.Messages);
  }
  [Fact(Timeout = 10000)]
  public async Task SocketLoopExpiresAQuietGuestWithoutAnotherIncomingPacketOrParallelReads()
  {
    using var host = NoiseIdentity.Generate(); var clock = new Clock(); var app = new TestApplication();
    await using var connection = new RelayHostConnection(host, app, time: clock);
    await using var socket = new QuietSocket(); using var stop = new CancellationTokenSource();
    await socket.Incoming.Writer.WriteAsync(Frame(RelayKind.Open, 7));
    var run = connection.RunAsync(socket, stop.Token);
    var timer = await clock.Next.Task;
    clock.Now += RelayHostConnection.HandshakeTimeout; timer.Fire();
    var close = await socket.Sent.Reader.ReadAsync();
    Assert.Equal(RelayKind.Close, RelayPacket.Decode(close).Kind); Assert.Equal(1, app.Disconnections);
    Assert.Equal(1, socket.MaximumReads); stop.Cancel();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
  }
  private sealed class QuietSocket : IRelaySocket
  {
    public Channel<byte[]> Incoming = Channel.CreateUnbounded<byte[]>();
    public Channel<byte[]> Sent = Channel.CreateUnbounded<byte[]>();
    private int reads;
    public int MaximumReads;
    public Task ConnectAsync(Uri address, ReadOnlyMemory<byte> secret, CancellationToken ct) => Task.CompletedTask;
    public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken ct) => Sent.Writer.WriteAsync(packet.ToArray(), ct);
    public async ValueTask<byte[]?> ReceiveAsync(CancellationToken ct)
    {
      MaximumReads = Math.Max(MaximumReads, Interlocked.Increment(ref reads));
      try { return await Incoming.Reader.ReadAsync(ct); }
      finally { Interlocked.Decrement(ref reads); }
    }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
}
