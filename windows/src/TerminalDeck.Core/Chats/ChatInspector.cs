using System.Text.Json;
namespace TerminalDeck.Core.Chats;

public sealed record ChatRequestReading(string Id, string Model, long? FreshInput, long? Output, long? CacheWrite, long? CacheRead, DateTimeOffset FirstAt, DateTimeOffset LastAt, long SourceSequence);
public sealed record ChatToolReading(string Id, string Name, bool Failed, double? ElapsedSeconds, string Input, string Output);
public sealed record ChatInspectorReading(string SessionId, ChatRequestReading[] Requests, ChatToolReading[] Tools, int RecordedPrompts, int RecordedAnswers, int ProviderTurnReports, long? FreshInput, long? Output, long? CacheWrite, long? CacheRead);
public static class ChatInspector
{
  public static ChatInspectorReading Read(ChatRecord chat)
  {
    var requests = new List<ChatRequestReading>();
    foreach (var group in chat.Events.Where(e => e.Kind is "requestStarted" or "requestUsage").GroupBy(e => e.Id))
    {
      string model = "Not reported"; long? input = null, output = null, writes = null, reads = null;
      foreach (var entry in group)
      {
        var data = entry.Data ?? default;
        var name = ChatLineProtocol.S(data, "model"); if (name.Length > 0) model = name;
        var usage = ChatLineProtocol.P(data, "usage");
        input = Number(usage, "input_tokens") ?? input; output = Number(usage, "output_tokens") ?? output;
        writes = Number(usage, "cache_creation_input_tokens") ?? writes; reads = Number(usage, "cache_read_input_tokens") ?? reads;
      }
      requests.Add(new(group.Key, model, input, output, writes, reads, group.First().At, group.Last().At, group.Last().Sequence));
    }
    var rows = ChatProjection.Rows(chat); var tools = new List<ChatToolReading>();
    foreach (var row in rows.Where(r => r.Kind == "tool"))
    {
      var start = chat.Events.FirstOrDefault(e => e.Kind == "toolCall" && e.Id == row.Id)?.At;
      var end = chat.Events.LastOrDefault(e => e.Kind == "toolResult" && e.Id == row.Id)?.At;
      var seconds = start is { } first && end is { } last && first != default && last >= first ? (last - first).TotalSeconds : (double?)null;
      tools.Add(new(row.Id, row.Text, row.Status == "Failed", seconds, row.Input, row.Output));
    }
    return new(chat.Definition.Id, requests.ToArray(), tools.ToArray(), rows.Count(r => r.Kind == "user"), rows.Count(r => r.Kind == "assistant"),
      chat.Events.Where(e => e.Kind == "usage").Select(e => e.Id).Distinct().Count(), Sum(requests.Select(r => r.FreshInput)), Sum(requests.Select(r => r.Output)), Sum(requests.Select(r => r.CacheWrite)), Sum(requests.Select(r => r.CacheRead)));
  }
  private static long? Number(JsonElement value, string key)
  { var number = ChatLineProtocol.P(value, key); return number.ValueKind == JsonValueKind.Number && number.TryGetInt64(out var result) && result >= 0 ? result : null; }
  private static long? Sum(IEnumerable<long?> source)
  {
    var values = source.ToArray(); if (values.Length == 0 || values.Any(v => !v.HasValue)) return null;
    try { return values.Aggregate(0L, (sum, v) => checked(sum + v!.Value)); } catch (OverflowException) { return null; }
  }
}
