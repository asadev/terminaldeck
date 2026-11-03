using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Remote;

public static class PhoneChatText
{
  public static string Read(JsonElement message)
  {
    if (!message.TryGetProperty("text", out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { } text || Encoding.UTF8.GetByteCount(text) > 16384 || text.Any(c => char.IsControl(c) && c is not ('\n' or '\r' or '\t')))
      throw new PhoneRefusal("bad-message", "Send at most 16,384 UTF8 bytes; only line breaks and tabs are supported controls.");
    return text;
  }
}
