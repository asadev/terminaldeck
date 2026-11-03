using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Quality;

public sealed record ProviderUpdate(string Provider, string? Installed, string? Latest, string Status, string Detail, DateTimeOffset CheckedAt);
public static class ReadinessProviderUpdates
{
  private static readonly Dictionary<string, ProviderUpdate> cache = [];
  private static readonly SemaphoreSlim gate = new(1, 1);
  public static async Task<ProviderUpdate[]> CheckAsync(ProjectReadinessReport report, HttpClient http, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      var results = new List<ProviderUpdate>();
      foreach (var row in report.Checks.Where(c => c.Id.StartsWith("provider-", StringComparison.Ordinal)))
      {
        var provider = row.Id[9..]; if (cache.TryGetValue(provider, out var kept) && kept.CheckedAt > DateTimeOffset.UtcNow.AddHours(-6)) { results.Add(kept); continue; }
        var package = provider switch { "claude" => "@anthropic-ai%2fclaude-code", "codex" => "@openai%2fcodex", "gemini" => "@google%2fgemini-cli", _ => throw new ArgumentException("Choose a supported coding AI.") };
        var match = Regex.Match(row.Detail, @"\b\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\b"); var installed = match.Success ? match.Value : null;
        ProviderUpdate result;
        try
        {
          using var response = await http.GetAsync("https://registry.npmjs.org/" + package + "/latest", HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
          if (response.Content.Headers.ContentLength > 1024 * 1024) throw new IOException("The version reply exceeds its size limit.");
          await using var input = await response.Content.ReadAsStreamAsync(ct); using var bytes = new MemoryStream(); var buffer = new byte[16384];
          while (true) { var count = await input.ReadAsync(buffer, ct); if (count == 0) break; if (bytes.Length + count > 1024 * 1024) throw new IOException("The version reply exceeds its size limit."); bytes.Write(buffer, 0, count); }
          using var json = JsonDocument.Parse(bytes.ToArray()); var latest = json.RootElement.GetProperty("version").GetString();
          var updated = installed is not null && latest is not null && Version.TryParse(installed.Split('-', '+')[0], out var have) && Version.TryParse(latest.Split('-', '+')[0], out var wanted) && have >= wanted;
          result = new(provider, installed, latest, installed is null ? "warn" : updated ? "pass" : "warn", installed is null ? "No installed version was observed. Open Coding AIs to install it." : updated ? "The installed version is current with the registry's latest release." : "A newer release is available. Update this AI under Coding AIs.", DateTimeOffset.UtcNow);
        }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException or KeyNotFoundException)
        { result = new(provider, installed, null, "skip", "The current release could not be checked. The installed version remains an observation, not an update claim.", DateTimeOffset.UtcNow); }
        if (result.Latest is not null) cache[provider] = result; results.Add(result);
      }
      return results.ToArray();
    }
    finally { gate.Release(); }
  }
}
