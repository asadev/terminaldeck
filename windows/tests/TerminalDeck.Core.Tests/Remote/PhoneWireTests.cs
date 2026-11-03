using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneWireTests
{
  [Theory]
  [InlineData("not json")]
  [InlineData("[]")]
  [InlineData("{\"t\":\"unknown\"}")]
  [InlineData("{\"t\":\"hello\",\"protocol\":1,\"token\":\"\",\"device\":{\"name\":\"Phone\",\"platform\":\"ios\"}}")]
  [InlineData("{\"t\":\"attach\",\"id\":\"s\",\"cols\":80}")]
  public void MalformedFramesNeverBecomeCommands(string json) => Assert.Throws<ProtocolException>(() => PhoneWire.ParseClient(Encoding.UTF8.GetBytes(json)));

  [Fact]
  public void InputLimitMeasuresUtf8Bytes()
  {
    var atLimit = JsonSerializer.SerializeToUtf8Bytes(new { t = "input", id = "s", data = string.Concat(Enumerable.Repeat("🧨", 4096)) }, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    Assert.Equal("input", PhoneWire.ParseClient(atLimit).Type);
    var oversized = JsonSerializer.SerializeToUtf8Bytes(new { t = "input", id = "s", data = new string('x', 16385) });
    Assert.Throws<ProtocolException>(() => PhoneWire.ParseClient(oversized));
    Assert.Throws<ProtocolException>(() => PhoneWire.ParseClient([0xff, 0xfe]));
  }

  [Theory]
  [InlineData(20, 5, true)]
  [InlineData(500, 200, true)]
  [InlineData(19, 5, false)]
  [InlineData(500, 201, false)]
  [InlineData(80, 0, false)]
  public void TerminalSizesFollowThePhoneContract(int cols, int rows, bool accepted)
  {
    var json = JsonSerializer.SerializeToUtf8Bytes(new { t = "take", id = "s", cols, rows });
    if (accepted) Assert.Equal("take", PhoneWire.ParseClient(json).Type);
    else Assert.Throws<ProtocolException>(() => PhoneWire.ParseClient(json));
  }

  [Fact]
  public void OutputChunksKeepUnicodeIntactAtTheByteBoundary()
  {
    var input = new string('a', 32767) + "🧨" + new string('b', 32767);
    var chunks = PhoneWire.OutputChunks(input).ToArray();
    Assert.Equal(input, string.Concat(chunks));
    Assert.All(chunks, c => Assert.InRange(Encoding.UTF8.GetByteCount(c), 1, 32768));
    Assert.DoesNotContain(chunks, c => c.Contains('\ufffd'));
  }

  [Fact]
  public void RelayChannelBytesRemainInWireOrderAndStayBounded()
  {
    var id = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
    var packet = new RelayPacket(RelayKind.Data, id, [42]);
    Assert.Equal(new byte[] { 2 }.Concat(id).Concat(new byte[] { 42 }), packet.Encode());
    Assert.Equal(id, RelayPacket.Decode(packet.Encode()).Channel);
    Assert.Throws<ProtocolException>(() => RelayPacket.Decode(new byte[16]));
    Assert.Throws<ProtocolException>(() => RelayPacket.Decode(new byte[17 + 96 * 1024 + 1]));
    Assert.Throws<ProtocolException>(() => new RelayPacket(RelayKind.Data, new byte[15], []).Encode());
    Assert.Throws<ProtocolException>(() => RelayPacket.ReadHandshake(new byte[80], true));
    var wrongVersion = new byte[81]; wrongVersion[0] = 2;
    Assert.Throws<ProtocolException>(() => RelayPacket.ReadHandshake(wrongVersion, true));
  }

  [Fact]
  public void ApprovedWelcomeUsesExistingPhoneFieldNames()
  {
    using var document = JsonDocument.Parse(PhoneWire.ApprovedWelcome("d", "Phone", "PC", "0.1", [], []));
    var welcome = document.RootElement;
    Assert.Equal("win32", welcome.GetProperty("hostPlatform").GetString());
    Assert.Equal("desktop", welcome.GetProperty("hostKind").GetString());
    Assert.Equal(JsonValueKind.Null, welcome.GetProperty("token").ValueKind);
    Assert.Empty(welcome.GetProperty("capabilities").EnumerateArray());
  }
}
