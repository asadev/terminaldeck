using System.Buffers.Binary;

namespace TerminalDeck.Core.Remote;

public enum RelayKind : byte
{
  Open = 1, Data = 2, Close = 3, McpRequest = 0x10, McpReply = 0x11, McpCancel = 0x12, McpReach = 0x13, ReceiverSync = 0x20, ReceiverDelivery = 0x21, ReceiverAck = 0x22, ReceiverSynced = 0x23
}

public sealed record RelayPacket(RelayKind Kind, byte[] Channel, byte[] Payload)
{
  public const int HeaderBytes = 17;
  public const int MaximumPayloadBytes = 96 * 1024;
  public string ChannelId => Convert.ToHexStringLower(Channel);

  public byte[] Encode()
  {
    if (Channel.Length != 16 || Payload.Length > MaximumPayloadBytes || !Enum.IsDefined(Kind))
      throw new ProtocolException("The relay packet is unusable.");
    return [(byte)Kind, ..Channel, ..Payload];
  }

  public static RelayPacket Decode(ReadOnlySpan<byte> frame)
  {
    if (frame.Length < HeaderBytes || frame.Length > HeaderBytes + MaximumPayloadBytes ||
      !Enum.IsDefined((RelayKind)frame[0])) throw new ProtocolException("The relay packet is unusable.");
    return new RelayPacket((RelayKind)frame[0], frame.Slice(1, 16).ToArray(), frame[17..].ToArray());
  }

  public static byte[] FrameHandshake(ReadOnlySpan<byte> message)
  {
    if (message.Length is not (80 or 48)) throw new ProtocolException("The handshake has the wrong length.");
    return [1, ..message];
  }

  public static byte[] ReadHandshake(ReadOnlySpan<byte> payload, bool opening)
  {
    if (payload.Length != (opening ? 81 : 49) || payload[0] != 1)
      throw new ProtocolException("The sealed handshake is unusable.");
    return payload[1..].ToArray();
  }
}
