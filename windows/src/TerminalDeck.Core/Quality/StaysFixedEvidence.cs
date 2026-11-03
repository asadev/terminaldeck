using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Quality;

public static class StaysFixedEvidence
{
  public static JsonElement Result(JsonElement report)
  {
    if (!report.TryGetProperty("result", out var result)) return report.Clone();
    if (result.ValueKind == JsonValueKind.Object) return result.Clone();
    if (result.ValueKind == JsonValueKind.String) { using var decoded = JsonDocument.Parse(result.GetString()!); return decoded.RootElement.Clone(); }
    throw new IOException("The last check result could not be read. Run a fresh check.");
  }
  public static void RequireObservedBuild(string folder, JsonElement report)
  {
    var result = Result(report);
    if (result.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null || result.TryGetProperty("blocked", out var blocked) && blocked.ValueKind == JsonValueKind.True) throw new InvalidOperationException("The last check could not run. Fix its reported problem and check again before marking a good build.");
    if (!result.TryGetProperty("coverage", out var coverage) || !coverage.TryGetProperty("paths", out var paths) || !paths.TryGetDouble(out var count) || !double.IsFinite(count) || count <= 0) throw new InvalidOperationException("The last check observed nothing. Run a runnable project check and review its result first.");
    if (!result.TryGetProperty("candidate", out var candidate) || !candidate.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String || id.GetString() is not { } build || build is "." or ".." || !Regex.IsMatch(build, "^[A-Za-z0-9._-]+$")) throw new InvalidOperationException("The last check names no recorded candidate build.");
    var directory = ProjectReadiness.SafeFile(folder, ".staysfixed/v2/builds/" + build);
    if (Directory.Exists(directory)) foreach (var journey in Directory.EnumerateDirectories(directory).Take(10000))
    {
      _ = ProjectReadiness.SafeFile(folder, Path.GetRelativePath(folder, journey));
      var latest = Directory.EnumerateFiles(journey, "*.jsonl").OrderByDescending(p => Path.GetFileName(p), StringComparer.Ordinal).FirstOrDefault();
      if (latest is not null && ObservedCapture(folder, latest)) return;
    }
    throw new InvalidOperationException("The last check did not record the product running. Run a runnable check and review it before marking a good build.");
  }
  private static bool ObservedCapture(string folder, string path)
  {
    _ = ProjectReadiness.SafeFile(folder, Path.GetRelativePath(folder, path)); if (new FileInfo(path).Length > 16 * 1024 * 1024) return false;
    var started = false; var ended = false; var observed = false; var rows = 0;
    try
    {
      foreach (var line in File.ReadLines(path))
      {
        if (string.IsNullOrWhiteSpace(line)) continue; if (ended) return false;
        using var document = JsonDocument.Parse(line); var row = document.RootElement;
        if (row.TryGetProperty("kind", out var kind) && kind.GetString() == "capture") { if (started) return false; started = true; continue; }
        if (!started) return false;
        if (row.TryGetProperty("kind", out kind) && kind.GetString() == "end") { if (row.TryGetProperty("count", out var expected) && (!expected.TryGetInt32(out var number) || number != rows)) return false; ended = true; continue; }
        if (!row.TryGetProperty("path", out var address) || address.ValueKind != JsonValueKind.String || !row.TryGetProperty("channel", out var channel)) return false; rows++;
        var refused = row.TryGetProperty("meta", out var meta) && meta.TryGetProperty("refused", out var refusal) && refusal.ValueKind == JsonValueKind.True;
        if (row.TryGetProperty("value", out var value))
        {
          refused |= value.ValueKind == JsonValueKind.Object && value.TryGetProperty("kind", out var why) && why.GetString() == "refused";
          refused |= value.ValueKind == JsonValueKind.String && value.GetString()!.StartsWith("not checked", StringComparison.OrdinalIgnoreCase);
        }
        if (!refused && channel.GetString() is "meaning" or "effects" or "complaints" or "results" or "pixels") observed = true;
      }
    }
    catch (Exception ex) when (ex is JsonException or IOException or InvalidOperationException) { return false; }
    return started && ended && observed;
  }
}
