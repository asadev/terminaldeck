using System.Buffers.Binary;
using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

public sealed class McpRelayRequest
{
  public int V { get; init; } = 1;
  public string? PathKey { get; init; }
  public string? Authorization { get; init; }
  public string? ProtocolVersion { get; init; }
  public string? UserAgent { get; init; }
  public override string ToString() => "<relay MCP envelope>";
}
public sealed record McpRelayReplyHead(int V, bool First, bool Last, int? Status, string? ContentType);

public static class McpRelayCodec
{
  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
  public static (McpRelayRequest Head, byte[] Body) DecodeRequest(ReadOnlySpan<byte> payload)
  {
    if (payload.Length < 2 || payload.Length > 65536) throw new McpRefusal("The relay MCP request is unusable.");
    var length = BinaryPrimitives.ReadUInt16BigEndian(payload);
    if (length == 0 || length > payload.Length - 2) throw new McpRefusal("The relay MCP header is unusable.");
    try
    {
      var head = JsonSerializer.Deserialize<McpRelayRequest>(payload.Slice(2, length), Json) ?? throw new JsonException();
      if (head.V != 1 || head.PathKey is { Length: > 512 } || head.Authorization is { Length: > 512 }) throw new JsonException();
      return (head, payload[(2 + length)..].ToArray());
    }
    catch (JsonException) { throw new McpRefusal("The relay MCP header is unusable."); }
  }
  public static IReadOnlyList<byte[]> EncodeReply(McpHttpReply reply)
  {
    if (reply.Body.Length > 8 * 1024 * 1024) throw new McpRefusal("The relay MCP reply is too large.");
    var result = new List<byte[]>(); var offset = 0;
    do
    {
      var count = Math.Min(60 * 1024, reply.Body.Length - offset);
      var first = offset == 0; var last = offset + count == reply.Body.Length;
      var head = first ? JsonSerializer.SerializeToUtf8Bytes(new { status = reply.Status, contentType = reply.ContentType }, Json) : [];
      var prefix = first ? 3 + head.Length : 1;
      var chunk = new byte[prefix + count];
      chunk[0] = (byte)((first ? 1 : 0) | (last ? 2 : 0));
      if (first) { BinaryPrimitives.WriteUInt16BigEndian(chunk.AsSpan(1), checked((ushort)head.Length)); head.CopyTo(chunk.AsSpan(3)); }
      reply.Body.AsSpan(offset, count).CopyTo(chunk.AsSpan(prefix)); result.Add(chunk); offset += count;
    } while (offset < reply.Body.Length);
    return result;
  }
}
