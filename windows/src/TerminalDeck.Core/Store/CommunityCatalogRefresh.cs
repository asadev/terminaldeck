using System.Text;

namespace TerminalDeck.Core.Store;

public sealed partial class AppStoreService
{
  public string? CatalogProblem { get; private set; }
  public string? CatalogStale { get; private set; }
  public async Task RefreshCommunityAsync(HttpClient http, CancellationToken ct = default)
  {
    try
    {
      using var request = StoreNetwork.Get(SignedCommunityCatalog.Address, "application/json");
      using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
      if (response.RequestMessage?.RequestUri?.AbsoluteUri != SignedCommunityCatalog.Address || response.Content.Headers.ContentLength > 1024 * 1024) throw new IOException("The community catalogue redirected or exceeds its limit.");
      await using var input = await response.Content.ReadAsStreamAsync(ct); using var output = new MemoryStream(); var buffer = new byte[16384];
      while (true) { var count = await input.ReadAsync(buffer, ct); if (count == 0) break; if (output.Length + count > 1024 * 1024) throw new IOException("The community catalogue exceeds its limit."); output.Write(buffer, 0, count); }
      var saved = store.Load(); var bytes = output.ToArray(); var verified = SignedCommunityCatalog.Verify(bytes, saved?.CatalogSerial ?? 0);
      catalog = catalog.Where(e => e.Department != "Community").Concat(verified.Entries).ToArray();
      store.Save(new(saved?.Installed ?? [], catalog, verified.Serial, Encoding.UTF8.GetString(bytes))); CatalogProblem = null; CatalogStale = verified.Stale;
    }
    catch (Exception ex) when (ex is OperationCanceledException or HttpRequestException or IOException or System.Text.Json.JsonException or FormatException or InvalidOperationException or KeyNotFoundException)
    {
      CatalogProblem = ex.Message; var saved = store.Load();
      if (saved?.SignedEnvelope is { } cached)
      {
        try { var kept = SignedCommunityCatalog.Verify(Encoding.UTF8.GetBytes(cached), saved.CatalogSerial); catalog = catalog.Where(e => e.Department != "Community").Concat(kept.Entries).ToArray(); CatalogStale = kept.Stale; }
        catch (Exception invalid) when (invalid is IOException or System.Text.Json.JsonException or FormatException) { catalog = catalog.Where(e => e.Department != "Community").ToArray(); }
      }
    }
    Changed?.Invoke();
  }
}
