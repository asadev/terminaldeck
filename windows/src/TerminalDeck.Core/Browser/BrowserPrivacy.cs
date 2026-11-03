using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Browser;

public sealed record BrowserPrivacyPreferences(bool PersistSignIns = true, bool SavePasswords = true);
public sealed record BrowserLogin(string Id, string Profile, string Origin, string Username, DateTimeOffset UpdatedAt);
public sealed record BrowserLogins(BrowserLogin[] Rows);
public sealed record BrowserCookieImport(string Name, string Value, string Domain, string Path = "/", bool Secure = true, bool HttpOnly = false, double? Expires = null, string SameSite = "Lax");

// The public ledger has only site/username metadata. Password bytes belong to
// the platform's protected store and are never part of reads or exported state.
public sealed class BrowserPrivacy(IStateStore<BrowserPrivacyPreferences> preferences, IStateStore<BrowserLogins> ledger, ISecretStore secrets, string secretPrefix)
{
  private readonly SemaphoreSlim gate = new(1, 1);
  public BrowserPrivacyPreferences Read() => preferences.Load() ?? new();
  public void Save(BrowserPrivacyPreferences value) => preferences.Save(value);
  public IReadOnlyList<BrowserLogin> Logins(string profile) => (ledger.Load()?.Rows ?? []).Where(r => r.Profile == profile).OrderBy(r => r.Origin).ThenBy(r => r.Username).ToArray();
  public static string Origin(string address)
  {
    if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length > 0) throw new ArgumentException("Choose an http or https website.");
    return uri.GetLeftPart(UriPartial.Authority);
  }
  public async ValueTask<BrowserLogin> SaveLoginAsync(string profile, string address, string username, string password, CancellationToken ct = default)
  {
    if (profile != "default" && !Guid.TryParseExact(profile, "N", out _) || username is null || password is null || username.Length > 1024 || username.Any(char.IsControl) || Encoding.UTF8.GetByteCount(password) is < 1 or > 2560 || password.Contains('\0')) throw new ArgumentException("Choose a profile, username and password within the supported limits.");
    var origin = Origin(address); await gate.WaitAsync(ct); var secret = Encoding.UTF8.GetBytes(password);
    try
    {
      var before = ledger.Load()?.Rows ?? [];
      var prior = before.FirstOrDefault(r => r.Profile == profile && r.Origin == origin && r.Username == username);
      if (before.Length >= 2000 && prior is null) throw new IOException("Remove an old saved password before adding another.");
      var row = new BrowserLogin(Guid.NewGuid().ToString("N"), profile, origin, username, DateTimeOffset.UtcNow);
      await secrets.WriteAsync(secretPrefix + row.Id, secret, ct);
      try { ledger.Save(new(before.Where(r => r.Id != prior?.Id).Append(row).ToArray())); }
      catch { await secrets.DeleteAsync(secretPrefix + row.Id, CancellationToken.None); throw; }
      if (prior is not null) await secrets.DeleteAsync(secretPrefix + prior.Id, ct); return row;
    }
    finally { CryptographicOperations.ZeroMemory(secret); gate.Release(); }
  }
  public async ValueTask<string> PasswordForUseAsync(string id, string profile, string address, CancellationToken ct = default)
  {
    var row = Logins(profile).SingleOrDefault(r => r.Id == id && r.Origin == Origin(address)) ?? throw new InvalidOperationException("This saved password belongs to a different site or profile.");
    var bytes = await secrets.ReadAsync(secretPrefix + row.Id, ct) ?? throw new IOException("Windows could not read this saved password. Save it again.");
    try { if (bytes.Length is < 1 or > 2560) throw new IOException("The protected password is outside its supported bounds."); return new UTF8Encoding(false, true).GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public async ValueTask ForgetAsync(string profile, string? id = null, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      var before = ledger.Load()?.Rows ?? []; var removed = before.Where(r => r.Profile == profile && (id is null || r.Id == id)).ToArray();
      ledger.Save(new(before.Except(removed).ToArray())); foreach (var row in removed) await secrets.DeleteAsync(secretPrefix + row.Id, ct);
    }
    finally { gate.Release(); }
  }
  public static bool ValidCapture(JsonElement value, string expectedProof, string address, bool privateMode, bool automated)
  {
    if (privateMode || automated || value.ValueKind != JsonValueKind.Object) return false;
    string? Text(string key) => value.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    var proof = Text("proof"); var origin = Text("origin"); var username = Text("username"); var password = Text("password");
    if (Text("kind") != "deck-save-login" || proof is null || proof.Length != expectedProof.Length ||
      !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(proof), Encoding.UTF8.GetBytes(expectedProof)) ||
      origin is null || username is null || password is null || username.Length > 1024 || username.Any(char.IsControl) ||
      Encoding.UTF8.GetByteCount(password) is < 1 or > 2560 || password.Contains('\0')) return false;
    try { return Origin(origin) == Origin(address); } catch (ArgumentException) { return false; }
  }
  public static async Task<string> ReadCookieFileAsync(string path, CancellationToken ct = default)
  {
    await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 16384, true);
    const int limit = 2 * 1024 * 1024;
    if (input.Length > limit) throw new ArgumentException("Import up to 2 MB of exported cookies.");
    using var output = new MemoryStream(); var buffer = new byte[16384];
    while (true)
    {
      var read = await input.ReadAsync(buffer, ct); if (read == 0) break;
      if (output.Length + read > limit) throw new ArgumentException("The exported cookie file grew beyond its size limit.");
      output.Write(buffer, 0, read);
    }
    return new UTF8Encoding(false, true).GetString(output.ToArray());
  }
  public static BrowserCookieImport[] Cookies(string text)
  {
    if (Encoding.UTF8.GetByteCount(text) > 2 * 1024 * 1024) throw new ArgumentException("Import up to 2 MB of exported cookies.");
    var rows = JsonSerializer.Deserialize<BrowserCookieImport[]>(text, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
    if (rows.Length > 2000 || rows.Any(r => r is null || string.IsNullOrEmpty(r.Name) || r.Value is null || string.IsNullOrEmpty(r.Domain) || string.IsNullOrEmpty(r.Path) || r.Path.Length > 2048 || r.Name.Length is < 1 or > 1024 || r.Name.Any(c => char.IsControl(c) || c is ';' or '=') || r.Value.Length > 8192 || r.Value.Any(char.IsControl) || r.Domain.Length is < 1 or > 253 || Uri.CheckHostName(r.Domain.TrimStart('.')) == UriHostNameType.Unknown || !r.Path.StartsWith('/') || r.Path.Any(char.IsControl) || r.SameSite is not ("Lax" or "Strict" or "None") || r.SameSite == "None" && !r.Secure || r.Expires is { } at && (!double.IsFinite(at) || at < 0 || at > 253402300799))) throw new ArgumentException("The exported cookies contain an unsupported name, domain, value or expiry.");
    return rows;
  }
}
