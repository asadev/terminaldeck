using System.Text.Json;
namespace TerminalDeck.Core.Chats;
public sealed record ChatContextReading(long? Window, long? Tokens, long? Remaining, double? Percent, long? PeakRecordedTokens, int RecordedCompactions);
public static class ChatContext
{
  public static ChatContextReading Read(ChatRecord chat)
  {
    long? window = null, tokens = null, peak = null;
    foreach (var entry in chat.Events.Where(e => e.Kind == "usage"))
    {
      var data = entry.Data ?? default; var usage = ChatLineProtocol.P(data, "usage"); var last = ChatLineProtocol.P(usage, "last");
      var count = Number(last, "totalTokens"); if (count.HasValue) peak = Math.Max(peak ?? 0, count.Value);
      if (ChatLineProtocol.S(data, "creationKey") == chat.CreationKey)
      { window = Number(usage, "modelContextWindow"); tokens = count; }
    }
    var remaining = window.HasValue && tokens.HasValue ? Math.Max(0, window.Value - tokens.Value) : (long?)null;
    var percent = window is > 0 && tokens.HasValue ? (double)tokens.Value / window.Value * 100 : (double?)null;
    return new(window, tokens, remaining, percent, peak, chat.Events.Where(e => e.Kind == "compaction").Select(e => e.Id).Distinct().Count());
  }
  private static long? Number(JsonElement data, string field)
  { var value = ChatLineProtocol.P(data, field); return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var count) && count >= 0 ? count : null; }
}
