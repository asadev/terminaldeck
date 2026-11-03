using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Store;

public sealed record StoreEntry(string Id, string Name, string Summary, string Department, string Category, string Version, string Delivery, string Source, string Cost = "free", string Compatibility = "works", string[]? Needs = null, string? Artifact = null, string? Sha256 = null, long Bytes = 0, string? Executable = null, string[]? Arguments = null, JsonElement? Manifest = null);
public sealed record InstalledStoreEntry(string Id, string Version, string Department, string Receipt, DateTimeOffset InstalledAt, StoreEntry? Entry = null);
public sealed record StoreLedger(InstalledStoreEntry[] Installed, StoreEntry[]? Catalog = null, long CatalogSerial = 0, string? SignedEnvelope = null);
public sealed record StoreRow(StoreEntry Entry, InstalledStoreEntry? Installed)
{
  public bool UpdateAvailable => Installed is not null && Installed.Version != Entry.Version;
}
public sealed record StoreInstallOptions(string? Folder = null, string[]? Agents = null, Dictionary<string, string>? Values = null, string? PreviousReceipt = null, [property: System.Text.Json.Serialization.JsonIgnore] Func<CancellationToken, ValueTask>? EnsureCurrent = null);
public sealed record StoreInstallation(string Receipt, string Version);
public interface IAppStoreInstaller
{
  ValueTask<StoreInstallation> InstallAsync(StoreEntry entry, bool update, CancellationToken ct, StoreInstallOptions? options = null);
  ValueTask RemoveAsync(StoreEntry entry, string receipt, CancellationToken ct);
}
public interface IStoreAuthorizer
{
  ValueTask<bool> ApproveAsync(StoreEntry entry, string action, CancellationToken ct);
}
public sealed partial class AppStoreService(IStateStore<StoreLedger> store, IAppStoreInstaller installer, IStoreAuthorizer authorizer)
{
  private StoreEntry[] catalog = store.Load()?.Catalog ?? [];
  private readonly SemaphoreSlim gate = new(1, 1);
  public event Action? Changed;
  public static string[] Departments { get; } = ["Browser tools", "MCP servers", "Community"];
  public void MergeCatalog(IEnumerable<StoreEntry> entries)
  { var rows = entries.ToArray(); SetCatalog(catalog.Where(old => !rows.Any(row => row.Id == old.Id)).Concat(rows)); }
  public void SetCatalog(IEnumerable<StoreEntry> entries)
  {
    var rows = entries.ToArray();
    if (rows.Length > 10000 || rows.Select(r => r.Id).Distinct(StringComparer.Ordinal).Count() != rows.Length) throw new ArgumentException("The catalogue contains duplicate entries or exceeds its limit.");
    foreach (var row in rows)
      if (string.IsNullOrWhiteSpace(row.Id) || row.Id.Length > 160 || !Departments.Contains(row.Department) || row.Delivery is not ("mcp-store" or "community" or "browser-tool" or "listing" or "winget" or "tool-archive" or "browser-extension") || row.Name.Length > 200 || row.Version.Length > 100) throw new ArgumentException("The app catalogue contains an unsupported entry. MCP servers use their own catalogue.");
    catalog = rows; var saved = store.Load(); store.Save(new(saved?.Installed ?? [], rows, saved?.CatalogSerial ?? 0, saved?.SignedEnvelope)); Changed?.Invoke();
  }
  public async Task<int> ImportCatalogAsync(string address, string sha256, HttpClient http, CancellationToken ct = default)
  {
    if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) || !System.Text.RegularExpressions.Regex.IsMatch(sha256, "^[0-9a-fA-F]{64}$")) throw new ArgumentException("Use a trusted HTTPS catalogue URL and its SHA-256 fingerprint.");
    using var response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
    if (response.RequestMessage?.RequestUri?.Scheme != "https" || response.Content.Headers.ContentLength > 1024 * 1024) throw new IOException("The catalogue download is outside its limits.");
    await using var input = await response.Content.ReadAsStreamAsync(ct); using var output = new MemoryStream(); var buffer = new byte[16384];
    while (true) { var read = await input.ReadAsync(buffer, ct); if (read == 0) break; if (output.Length + read > 1024 * 1024) throw new IOException("The catalogue exceeds its size limit."); output.Write(buffer, 0, read); }
    var rows = ParseCatalog(output.ToArray(), Convert.FromHexString(sha256));
    SetCatalog(catalog.Where(old => !rows.Any(row => row.Id == old.Id)).Concat(rows)); return rows.Length;
  }
  public StoreRow[] Browse(string? department = null, string query = "", string? category = null, string? cost = null, bool? installed = null)
  {
    var receipts = store.Load()?.Installed ?? [];
    return catalog.Select(e => new StoreRow(e, receipts.SingleOrDefault(r => r.Id == e.Id)))
      .Where(r => (department is null || r.Entry.Department == department) && (category is null || r.Entry.Category == category) && (cost is null || r.Entry.Cost == cost) && (installed is null || (r.Installed is not null) == installed) && (r.Entry.Name + " " + r.Entry.Summary + " " + r.Entry.Category).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase)).OrderBy(r => r.Entry.Name).ToArray();
  }
  public async ValueTask<InstalledStoreEntry?> ChangeAsync(string id, string action, CancellationToken ct = default, Func<CancellationToken, ValueTask>? ensureCurrent = null, StoreInstallOptions? options = null)
  {
    if (action is not ("install" or "update" or "remove")) throw new ArgumentException("Choose install, update or remove.");
    await gate.WaitAsync(ct);
    try
    {
      var entry = catalog.SingleOrDefault(e => e.Id == id) ?? throw new ArgumentException("Choose an entry in the current catalogue.");
      if (entry.Delivery == "community" && options is null)
      {
        var manifest = entry.Manifest ?? throw new IOException("The community manifest is unavailable.");
        options = new(Agents: manifest.GetProperty("agents").EnumerateArray().Select(a => a.GetString()!).ToArray());
      }
      var before = store.Load()?.Installed ?? []; var existing = before.SingleOrDefault(e => e.Id == id);
      if (action == "install" && existing is not null || action != "install" && existing is null) throw new InvalidOperationException("Refresh the Store and choose an available action.");
      if (action != "remove" && entry.Compatibility != "works") throw new InvalidOperationException("This entry is not compatible with this Windows app.");
      var approvalEntry = entry.Department == "Community" && CatalogStale is { } stale ? entry with { Summary = entry.Summary + "\n" + stale } : entry;
      if (options is not null) approvalEntry = approvalEntry with { Summary = approvalEntry.Summary + "\nAgents: " + string.Join(", ", options.Agents ?? []) + "\nFolder: " + (options.Folder ?? "Global agent instructions and skills") };
      if (!await authorizer.ApproveAsync(approvalEntry, action, ct)) throw new InvalidOperationException("This Store change was not approved.");
      if (ensureCurrent is not null) await ensureCurrent(ct);
      if (catalog.SingleOrDefault(e => e.Id == id) != entry) throw new InvalidOperationException("This catalogue entry changed during approval. Review it again.");
      InstalledStoreEntry? result = null;
      if (action == "remove") await installer.RemoveAsync(existing!.Entry ?? entry, existing.Receipt, ct);
      else
      {
        var installation = await installer.InstallAsync(entry, action == "update", ct, (options ?? new()) with { PreviousReceipt = existing?.Receipt, EnsureCurrent = ensureCurrent });
        result = new(id, installation.Version, entry.Department, installation.Receipt, DateTimeOffset.UtcNow, entry);
      }
      store.Save(new(before.Where(e => e.Id != id).Concat(result is null ? [] : new[] { result }).ToArray(), catalog, store.Load()?.CatalogSerial ?? 0, store.Load()?.SignedEnvelope)); Changed?.Invoke(); return result;
    }
    finally { gate.Release(); }
  }
  public static StoreEntry[] ParseCatalog(ReadOnlySpan<byte> bytes, ReadOnlySpan<byte> expectedSha256)
  {
    if (bytes.Length > 1024 * 1024 || expectedSha256.Length != 32 || !CryptographicOperations.FixedTimeEquals(SHA256.HashData(bytes), expectedSha256)) throw new IOException("The catalogue fingerprint did not match the trusted source.");
    return JsonSerializer.Deserialize<StoreEntry[]>(bytes, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new IOException("The catalogue is empty or unreadable.");
  }
}
