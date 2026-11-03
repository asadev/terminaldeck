using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Remote;

public sealed record PhoneMessage(string Type, JsonElement Value)
{
  public string Text(string field) => Value.GetProperty(field).GetString()!;
}

public static class PhoneWire
{
  public const int Version = 1;
  public const int MaximumMessageBytes = 65536;
  public const int MaximumInputBytes = 16384;
  public const int OutputChunkBytes = 32768;
  private static readonly UTF8Encoding Utf8 = new(false, true);

  public static PhoneMessage ParseClient(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Length > MaximumMessageBytes) throw new ProtocolException("The phone message is too large.");
    try
    {
      // Decode strictly: replacement characters must not turn broken bytes into commands.
      _ = Utf8.GetString(bytes);
      using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
      var value = document.RootElement;
      if (value.ValueKind != JsonValueKind.Object) throw new FormatException();
      var type = Text(value, "t", 64);
      switch (type)
      {
        case "hello":
          _ = Whole(value, "protocol", 0, 65535);
          _ = Text(value, "token", 200);
          var device = value.GetProperty("device");
          _ = Text(device, "name", 256, true);
          _ = Text(device, "platform", 128, true);
          if (value.TryGetProperty("capabilities", out var caps) && caps.ValueKind != JsonValueKind.Array) throw new FormatException();
          break;
        case "list": case "ping": break;
        case "attach":
          _ = Text(value, "id", 128);
          SizeIfPresent(value);
          if (value.TryGetProperty("keep", out var keep) && keep.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new FormatException();
          break;
        case "detach": case "close": _ = Text(value, "id", 128); break;
        case "input": case "session.send":
          _ = Text(value, "id", 128);
          if (type == "session.send") _ = Text(value, "rid", 128);
          var data = Text(value, "data", MaximumInputBytes, true, controls: true);
          if (Utf8.GetByteCount(data) > MaximumInputBytes) throw new FormatException();
          break;
        case "resize": case "take":
          _ = Text(value, "id", 128);
          new TerminalSize(Whole(value, "cols", 20, 500), Whole(value, "rows", 5, 200)).Validate();
          break;
        case "rename":
          _ = Text(value, "id", 128);
          _ = Text(value, "title", 8192, true, controls: true);
          break;
        default: throw new ProtocolException("This phone message is not implemented yet.");
      }
      return new PhoneMessage(type, value.Clone());
    }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or DecoderFallbackException or ArgumentException)
    { throw new ProtocolException("The phone message is unusable."); }
  }

  private static void SizeIfPresent(JsonElement value)
  {
    if (value.TryGetProperty("cols", out _) || value.TryGetProperty("rows", out _))
      new TerminalSize(Whole(value, "cols", 20, 500), Whole(value, "rows", 5, 200)).Validate();
  }

  private static int Whole(JsonElement value, string field, int minimum, int maximum)
  {
    var item = value.GetProperty(field);
    if (!item.TryGetInt32(out var number) || number < minimum || number > maximum) throw new FormatException();
    return number;
  }

  private static string Text(JsonElement value, string field, int limit, bool empty = false, bool controls = false)
  {
    var text = value.GetProperty(field).GetString() ?? throw new FormatException();
    if ((!empty && text.Length == 0) || text.Length > limit || (!controls && text.Any(char.IsControl))) throw new FormatException();
    return text;
  }

  public static byte[] PendingWelcome(string id, string name, string credential) => JsonSerializer.SerializeToUtf8Bytes(new
  {
    t = "welcome", protocol = 1, deviceId = id, deviceName = name, token = credential,
    sessions = Array.Empty<object>(), capabilities = Array.Empty<string>()
  });

  public static byte[] ApprovedWelcome(string id, string name, string hostName, string appVersion,
    IReadOnlyList<JsonElement> sessions, IReadOnlyList<string> capabilities) => JsonSerializer.SerializeToUtf8Bytes(new
  {
    t = "welcome", protocol = 1, deviceId = id, deviceName = name, token = (string?)null,
    sessions, capabilities, hostPlatform = "win32", hostKind = "desktop", hostName, appVersion
  });

  public static IEnumerable<string> OutputChunks(string text)
  {
    var chunk = new StringBuilder();
    var bytes = 0;
    foreach (var rune in text.EnumerateRunes())
    {
      if (bytes + rune.Utf8SequenceLength > OutputChunkBytes)
      {
        yield return chunk.ToString();
        chunk.Clear(); bytes = 0;
      }
      chunk.Append(rune.ToString()); bytes += rune.Utf8SequenceLength;
    }
    if (chunk.Length > 0) yield return chunk.ToString();
  }
}
