using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TerminalDeck.Core.Sessions;

// This private framing is deliberately separate from PhoneWire and relay packets.
public static class KeeperWire
{
  public const int Version = 2;
  public const int MaximumRequestBytes = 8 * 1024 * 1024;
  public const int MaximumResponseBytes = 128 * 1024 * 1024;
  public const int MaximumInputBytes = 4 * 1024 * 1024;
  public const int MaximumConnections = 16;
  public static JsonSerializerOptions Json { get; } = new(JsonSerializerDefaults.Web)
  {
    Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
  };

  public static async ValueTask WriteAsync<T>(Stream stream, T value, bool response = false, CancellationToken cancellationToken = default)
  {
    var body = JsonSerializer.SerializeToUtf8Bytes(value, Json);
    ValidateLength((uint)body.Length, response);
    var header = new byte[4];
    BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length);
    await stream.WriteAsync(header, cancellationToken);
    await stream.WriteAsync(body, cancellationToken);
    await stream.FlushAsync(cancellationToken);
  }

  public static async ValueTask<T> ReadAsync<T>(Stream stream, bool response = false, CancellationToken cancellationToken = default)
  {
    var header = new byte[4];
    await stream.ReadExactlyAsync(header, cancellationToken);
    var length = BinaryPrimitives.ReadUInt32BigEndian(header);
    ValidateLength(length, response);
    var body = new byte[(int)length];
    await stream.ReadExactlyAsync(body, cancellationToken);
    try { return JsonSerializer.Deserialize<T>(body, Json) ?? throw new IOException("The keeper sent an empty message."); }
    catch (JsonException) { throw new IOException("The keeper message could not be read."); }
  }

  private static void ValidateLength(uint length, bool response)
  {
    if (length == 0 || length > (response ? MaximumResponseBytes : MaximumRequestBytes))
      throw new IOException("The keeper message is too large or empty.");
  }
}

// Authentication material must never appear in a generated record ToString().
public sealed class KeeperRequest
{
  public int ProtocolVersion { get; init; } = KeeperWire.Version;
  public required string Secret { get; init; }
  public required string Operation { get; init; }
  public Guid? Instance { get; init; }
  public string? Id { get; init; }
  public SessionDefinition? Launch { get; init; }
  public byte[]? Bytes { get; init; }
  public int? Cols { get; init; }
  public int? Rows { get; init; }
  public string? Title { get; init; }
  public long? Revision { get; init; }
  public string? Transaction { get; init; }
  public string? Conversation { get; init; }
  public override string ToString() => "<private keeper request>";
}

public sealed record KeeperHello(int ProtocolVersion, string HostVersion, Guid Instance);
public sealed record KeeperResponse(KeeperHello? Hello = null, IReadOnlyList<SessionRecord>? Sessions = null,
  SessionSnapshot? Snapshot = null, SessionRecord? Session = null, bool? Success = null, string? Error = null, SessionEvent? Event = null,
  IReadOnlyList<SessionActivity>? Activity = null);
