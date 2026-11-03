using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace TerminalDeck.Core.Store;

public sealed record VerifiedCommunityCatalog(long Serial, StoreEntry[] Entries, string? Stale);
public static class SignedCommunityCatalog
{
  public const string Address = "https://terminaldeck.dev/store/index.json";
  private const string PublicKey = "66d8a2ecd199a16c8080c00e108911034d9b93932203ec8037d1fb4543257c34";
  public static VerifiedCommunityCatalog Verify(ReadOnlySpan<byte> envelopeBytes, long highWater = 0)
  {
    if (envelopeBytes.Length > 1024 * 1024) throw new IOException("The Store catalogue exceeds its size limit.");
    using var envelope = JsonDocument.Parse(envelopeBytes.ToArray()); var header = envelope.RootElement;
    if (header.GetProperty("v").GetInt32() != 1 || header.GetProperty("alg").GetString() != "ed25519" || header.GetProperty("keyId").GetString() != "td-store-1") throw new IOException("The catalogue does not use this app's production signing key.");
    var signed = Convert.FromBase64String(header.GetProperty("signed").GetString()!); var signature = Convert.FromBase64String(header.GetProperty("sig").GetString()!);
    if (signed.Length > 1024 * 1024 || signature.Length != 64) throw new IOException("The signed catalogue is outside its limits.");
    var verifier = new Ed25519Signer(); verifier.Init(false, new Ed25519PublicKeyParameters(Convert.FromHexString(PublicKey), 0)); verifier.BlockUpdate(signed, 0, signed.Length);
    if (!verifier.VerifySignature(signature)) throw new IOException("The catalogue signature is not trusted. Nothing from it was used.");
    using var document = JsonDocument.Parse(signed); var root = document.RootElement;
    if (root.GetProperty("v").GetInt32() != 1) throw new IOException("This catalogue format is unsupported.");
    var serial = root.GetProperty("serial").GetInt64(); if (serial < highWater) throw new IOException("An older catalogue cannot replace a list this machine already trusted.");
    var rawRows = root.GetProperty("items"); if (rawRows.GetArrayLength() > 10000) throw new IOException("This catalogue contains too many entries.");
    var entries = new List<StoreEntry>(); var ids = new HashSet<string>(StringComparer.Ordinal);
    foreach (var raw in rawRows.EnumerateArray())
    {
      string Text(string key, string fallback = "") => raw.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : fallback;
      var id = Text("id"); if (!System.Text.RegularExpressions.Regex.IsMatch(id, "^[a-z0-9-]+/[a-z0-9-]+$") || !ids.Add(id)) throw new IOException("The catalogue contains invalid or duplicate item IDs.");
      var source = raw.GetProperty("source"); var repo = source.TryGetProperty("repo", out var repository) ? repository.GetString() ?? "" : "";
      if (!repo.Contains("://", StringComparison.Ordinal))
      {
        var host = source.TryGetProperty("host", out var hostValue) ? hostValue.GetString() : null;
        if (host != "github.com" || !System.Text.RegularExpressions.Regex.IsMatch(repo, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) throw new IOException("The catalogue source repository is invalid.");
        repo = "https://github.com/" + repo;
      }
      if (!Uri.TryCreate(repo, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo)) throw new IOException("A catalogue item has an invalid source URL.");
      var platforms = raw.TryGetProperty("platforms", out var platformsValue) ? platformsValue.EnumerateArray().Select(p => p.GetString()).ToArray() : [];
      var compat = platforms.Length == 0 || platforms.Any(p => p is "windows" or "win32" or "all" or "any") ? "works" : "cannot";
      var kind = Text("kind"); var summary = Text("summary");
      var needs = raw.TryGetProperty("needs", out var requirements) ? requirements.EnumerateArray().Select(p => p.GetString()!).ToArray() : [];
      entries.Add(new(id, Text("name"), summary, "Community", Text("category", kind), Text("version"), Text("delivery") == "off-site" || kind is "tool" or "hooks" or "extension" ? "listing" : "community", repo, Text("cost", "unknown"), compat, needs, Manifest: raw.Clone()));
    }
    var revoked = root.GetProperty("revoked").EnumerateArray().Select(r => (Id: r.GetProperty("id").GetString(), Version: r.GetProperty("version").GetString())).ToArray();
    for (var i = 0; i < entries.Count; i++) if (revoked.Any(r => r.Id == entries[i].Id && r.Version == entries[i].Version)) entries[i] = entries[i] with { Compatibility = "cannot", Summary = "Withdrawn from the catalogue. " + entries[i].Summary };
    var issued = DateTimeOffset.Parse(root.GetProperty("issuedAt").GetString()!, System.Globalization.CultureInfo.InvariantCulture);
    var stale = DateTimeOffset.UtcNow - issued > TimeSpan.FromDays(30) ? "This catalogue is more than 30 days old." : null;
    if (root.TryGetProperty("expiresAt", out var expiry) && expiry.ValueKind == JsonValueKind.String && DateTimeOffset.Parse(expiry.GetString()!, System.Globalization.CultureInfo.InvariantCulture) < DateTimeOffset.UtcNow) stale = "This catalogue has expired. Review its source before installing anything.";
    return new(serial, entries.ToArray(), stale);
  }
}
