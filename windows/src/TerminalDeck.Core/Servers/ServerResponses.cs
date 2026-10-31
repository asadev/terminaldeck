using System.Text.Json;

namespace TerminalDeck.Core.Servers;

// SSH login banners and missing remote tools must produce a normal request
// failure, never an unhandled parser exception or partly trusted response.
internal static class ServerResponses
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
  private static IOException Invalid() => new("The server returned an unreadable response. Check its SSH startup output and required tools, then try again.");
  private static T Parse<T>(string text, params string[] required)
  {
    try
    {
      using var doc = JsonDocument.Parse(text);
      if (doc.RootElement.ValueKind != JsonValueKind.Object || required.Any(k => !doc.RootElement.TryGetProperty(k, out _))) throw Invalid();
      return JsonSerializer.Deserialize<T>(text, Json) ?? throw Invalid();
    }
    catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or ArgumentException) { throw Invalid(); }
  }
  public static ServerHealth Health(string text)
  {
    var health = Parse<ServerHealth>(text, "cpuPercent", "memoryUsed", "memoryTotal", "diskUsed", "diskTotal", "load1", "load5", "load15", "cpus", "checkedAt");
    if (!double.IsFinite(health.CpuPercent) || health.CpuPercent is < 0 or > 100 || health.MemoryTotal <= 0 || health.MemoryUsed < 0 || health.MemoryUsed > health.MemoryTotal ||
        health.DiskTotal <= 0 || health.DiskUsed < 0 || health.DiskUsed > health.DiskTotal || health.Cpus < 1 || health.CheckedAt == default ||
        new[] { health.Load1, health.Load5, health.Load15 }.Any(load => !double.IsFinite(load) || load < 0)) throw Invalid();
    return health;
  }
  public static ServerFilePage Files(string text, string path, int offset = 0)
  {
    var page = Parse<ServerFilePage>(text, "path", "entries", "more");
    if (page.Offset != offset || page.Path != path || page.Entries is null || page.Entries.Length > 1000) throw Invalid();
    foreach (var row in page.Entries)
    {
      if (row is null || string.IsNullOrEmpty(row.Name) || row.Name is "." or ".." || row.Name.Contains('/') || row.Name.Any(char.IsControl) ||
        row.Path != path.TrimEnd('/') + "/" + row.Name || row.Kind is not ("file" or "folder" or "link" or "special") || row.Size < 0 || !double.IsFinite(row.Modified)) throw Invalid();
    }
    return page;
  }
  public static ServerFileContent File(string text, string path, bool download = false)
  {
    var file = Parse<ServerFileContent>(text, "path", "base64", "truncated");
    var limit = download ? ServerFilesScript.TransferLimit : 262144;
    if (file.Path != path || file.Base64 is null || file.Base64.Length > (limit + 2) / 3 * 4) throw Invalid();
    try { if (Convert.FromBase64String(file.Base64).Length > limit) throw Invalid(); }
    catch (FormatException) { throw Invalid(); }
    return file;
  }
  public static IReadOnlyList<ServerApp> Apps(string text)
  {
    var rows = new List<ServerApp>();
    foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
      if (rows.Count >= 1000) throw Invalid();
      try
      {
        using var doc = JsonDocument.Parse(line); var row = doc.RootElement;
        string S(string key) => row.GetProperty(key).GetString() ?? throw Invalid();
        var id = S("ID"); ServerValidation.Container(id);
        rows.Add(new(id, S("Names"), S("Image"), S("State"), S("Status"), S("Ports")));
      }
      catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or ServerRefusal) { throw Invalid(); }
    }
    return rows;
  }
}
