using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public static class PhonePanelPagination
{
  public const int MaximumBytes = 48 * 1024;
  public static int Cursor(JsonElement request)
  {
    if (!request.TryGetProperty("cursor", out var cursor)) return 0;
    if (cursor.ValueKind != JsonValueKind.Number || !cursor.TryGetInt32(out var value) || value is < 0 or > 200) throw new PhoneRefusal("bad-message", "Choose a panel cursor between 0 and 200.");
    return value;
  }
  public static JsonObject Apply(JsonElement request, JsonObject frame, string? rid = null)
  {
    var cursor = Cursor(request);
    if (rid is null && request.TryGetProperty("rid", out var r) && r.ValueKind == JsonValueKind.String) rid = r.GetString();
    if (rid is not null) frame["rid"] = rid;
    if (frame.ContainsKey("totalRows")) return frame;
    var all = frame["rows"] as JsonArray ?? throw new PhoneRefusal("unavailable", "This page did not return rows.");
    // The shared panel contract allows at most 200 logical rows; pagination
    // splits that bounded reading without repeating a mutation.
    var total = Math.Min(200, all.Count);
    var nodes = all.Take(total).Select(n => n?.DeepClone()).ToArray();
    var effective = frame.ContainsKey("view") ? frame["view"]?.GetValue<string>() : frame.ContainsKey("scope") ? frame["scope"]?.GetValue<string>() : request.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.String ? scope.GetString() : null;
    frame["continuationScope"] = effective;
    frame["cursor"] = cursor; frame["totalRows"] = total; frame["nextCursor"] = null;
    var page = new JsonArray(); frame["rows"] = page;
    if (cursor > total) throw new PhoneRefusal("bad-message", "That panel cursor is beyond this reading.");
    for (var index = cursor; index < total; index++)
    {
      page.Add(nodes[index]); frame["nextCursor"] = index + 1 < total ? index + 1 : null;
      if (Encoding.UTF8.GetByteCount(frame.ToJsonString()) <= MaximumBytes) continue;
      page.RemoveAt(page.Count - 1); frame["nextCursor"] = index;
      frame["note"] ??= "This page continues. Read the remaining rows on the computer or a client with paging.";
      while (page.Count > 0 && Encoding.UTF8.GetByteCount(frame.ToJsonString()) > MaximumBytes)
      { page.RemoveAt(page.Count - 1); frame["nextCursor"] = cursor + page.Count; }
      if (page.Count == 0) throw new PhoneRefusal("unavailable", "A panel row is too large to send safely.");
      break;
    }
    if (Encoding.UTF8.GetByteCount(frame.ToJsonString()) > MaximumBytes) throw new PhoneRefusal("unavailable", "This page is too large to send safely.");
    return frame;
  }
}
