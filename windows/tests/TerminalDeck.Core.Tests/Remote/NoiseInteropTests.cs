using System.Reflection;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class NoiseInteropTests
{
  private static JsonDocument Vectors() => JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "sealed-vectors.json")));
  private static byte[] Hex(JsonElement element, string name) => Convert.FromHexString(element.GetProperty(name).GetString()!);

  [Theory]
  [InlineData("primary")]
  [InlineData("second-device")]
  public void InitiatorReplaysRecordedProductHandshakeAndBothTrafficDirections(string label)
  {
    using var vectors = Vectors();
    var fixture = vectors.RootElement.GetProperty("sessions").EnumerateArray().Single(s => s.GetProperty("label").GetString() == label);
    using var device = new NoiseIdentity(Hex(fixture.GetProperty("device"), "privateKey"));
    using var ephemeral = new NoiseIdentity(Hex(fixture, "ephemeralPrivate"));
    Assert.Equal(Hex(fixture.GetProperty("device"), "publicKey"), device.PublicKey);
    var start = NoiseChannel.Start(device, Hex(fixture.GetProperty("mac"), "publicKey"), ephemeral);
    Assert.Equal(Hex(fixture, "handshakeMessage"), start.Message);
    Assert.Equal(Hex(fixture, "framedHandshakeMessage"), RelayPacket.FrameHandshake(start.Message));
    var reply = RelayPacket.ReadHandshake(Hex(fixture, "framedReply"), opening: false);
    using var transport = NoiseChannel.Finish(start.Pending, reply);
    Assert.Equal(Hex(fixture, "channelBinding"), transport.ChannelBinding);
    foreach (var frame in fixture.GetProperty("initiatorToResponder").EnumerateArray())
      Assert.Equal(Hex(frame, "frame"), transport.Send(Hex(frame, "plaintext")));
    foreach (var frame in fixture.GetProperty("responderToInitiator").EnumerateArray())
      Assert.Equal(Hex(frame, "plaintext"), transport.Receive(Hex(frame, "frame")));
    Assert.Throws<ProtocolException>(() => NoiseChannel.Finish(start.Pending, reply));
  }

  [Fact]
  public void HostOpensTheRecordedDeviceIdentityBeforeMakingItsReply()
  {
    using var vectors = Vectors();
    var fixture = vectors.RootElement.GetProperty("sessions")[0];
    using var host = new NoiseIdentity(Hex(fixture.GetProperty("mac"), "privateKey"));
    var device = Hex(fixture.GetProperty("device"), "publicKey");
    var response = NoiseChannel.Respond(host, Hex(fixture, "handshakeMessage"), [device]);
    using var transport = response.Transport;
    Assert.Equal(device, response.PeerPublicKey);
    Assert.Equal(48, response.Reply.Length);
    Assert.Throws<ProtocolException>(() => NoiseChannel.Respond(host, Hex(fixture, "handshakeMessage"), []));
  }

  [Fact]
  public void FingerprintsMatchTheIndependentProductFixture()
  {
    using var vectors = Vectors();
    foreach (var vector in vectors.RootElement.GetProperty("fingerprints").EnumerateArray())
      Assert.Equal(vector.GetProperty("fingerprint").GetString(), PairingCode.Fingerprint(Hex(vector, "publicKey")));
  }

  [Fact]
  public void HostAndDeviceExchangeOrderedTrafficAndRejectReplay()
  {
    using var host = NoiseIdentity.Generate(); using var device = NoiseIdentity.Generate();
    var start = NoiseChannel.Start(device, host.PublicKey);
    var response = NoiseChannel.Respond(host, start.Message, [device.PublicKey]);
    using var server = response.Transport;
    using var client = NoiseChannel.Finish(start.Pending, response.Reply);
    Assert.Equal(client.ChannelBinding, server.ChannelBinding);
    var frame = client.Send(Encoding.UTF8.GetBytes("hello 🧨"));
    Assert.Equal("hello 🧨", Encoding.UTF8.GetString(server.Receive(frame)));
    Assert.Equal("answer", Encoding.UTF8.GetString(client.Receive(server.Send(Encoding.UTF8.GetBytes("answer")))));
    Assert.Throws<ProtocolException>(() => server.Receive(frame));
    Assert.Throws<ProtocolException>(() => server.Send([]));
  }

  [Fact]
  public void TamperedHandshakeAndLowOrderPeerAreRefused()
  {
    using var host = NoiseIdentity.Generate(); using var device = NoiseIdentity.Generate();
    var start = NoiseChannel.Start(device, host.PublicKey);
    start.Message[^1] ^= 1;
    Assert.Throws<ProtocolException>(() => NoiseChannel.Respond(host, start.Message, [device.PublicKey]));
    Assert.Throws<ProtocolException>(() => NoiseChannel.Start(device, new byte[32]));
    start.Pending.Dispose();
  }

  [Fact]
  public void AChangedTransportTagClosesTheTransport()
  {
    using var host = NoiseIdentity.Generate(); using var device = NoiseIdentity.Generate();
    var start = NoiseChannel.Start(device, host.PublicKey);
    var response = NoiseChannel.Respond(host, start.Message, [device.PublicKey]);
    using var server = response.Transport;
    using var client = NoiseChannel.Finish(start.Pending, response.Reply);
    var frame = client.Send([1, 2, 3]); frame[^1] ^= 1;
    Assert.Throws<ProtocolException>(() => server.Receive(frame));
    Assert.Throws<ProtocolException>(() => server.Receive(client.Send([4])));
  }

  [Fact]
  public void CounterCeilingPreventsNonceReuse()
  {
    using var host = NoiseIdentity.Generate(); using var device = NoiseIdentity.Generate();
    var start = NoiseChannel.Start(device, host.PublicKey);
    var response = NoiseChannel.Respond(host, start.Message, [device.PublicKey]);
    using var server = response.Transport;
    using var client = NoiseChannel.Finish(start.Pending, response.Reply);
    typeof(NoiseTransport).GetField("sent", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(client, NoiseChannel.CounterLimit - 1);
    _ = client.Send([]);
    Assert.Throws<ProtocolException>(() => client.Send([]));
  }
}
