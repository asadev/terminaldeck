using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace TerminalDeck.Core.Platform;

// The public GitHub releases are the update source from 0.21.0 on (release 27; Asad 3 Nov: "every time
// something new comes in GitHub it will show that pop-up and we can directly update from here"). Each release
// carries release-manifest.json (one Mac zip, one Windows MSIX, sizes and SHA-256) and release-manifest.json.sig,
// an Ed25519 signature over the manifest's exact bytes made by the release machine's key. The Mac app checks
// the same file with the same public key. Nothing is downloaded from a manifest the key did not sign, and the
// MSIX is checked again (size, SHA-256, package name, publisher, version) before Windows is asked to install it;
// Windows then checks the package signature itself.
public static class GitHubReleaseChannel
{
  public const string Repository = "asadev/terminaldeck";
  public static readonly Uri ManifestUri = new("https://github.com/" + Repository + "/releases/latest/download/release-manifest.json");
  public static readonly Uri SignatureUri = new("https://github.com/" + Repository + "/releases/latest/download/release-manifest.json.sig");
  // Raw 32-byte Ed25519 public keys, base64. A new key is added one release before the publisher switches to it.
  public static readonly IReadOnlyList<string> PublicKeys = ["seyAiThAvnCyVp9CZR6MrBOyMxsEb1P9+Pe8M9YCP5A="];
  public const string PackageName = "TerminalDeck";
  public const string Publisher = "CN=Terminal Deck Stable";
  public const int ManifestLimit = 262_144;
  public const long PackageLimit = 2_147_483_648;
  private static readonly HashSet<string> AllowedHosts = new(StringComparer.OrdinalIgnoreCase)
    { "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com" };

  public sealed record WindowsRelease(string Version, Uri Url, long Size, string Sha256, string Architecture, Uri? NotesUrl, string? Notes);

  public sealed class RefusedException(string message) : Exception(message);

  public static void Verify(byte[] manifest, string signatureText, IReadOnlyList<string>? keys = null)
  {
    byte[] signature;
    try { signature = Convert.FromBase64String(signatureText.Trim()); }
    catch (FormatException) { throw new RefusedException("The release manifest's signature is unreadable. Nothing was downloaded."); }
    if (manifest.Length > ManifestLimit || signature.Length != 64) throw new RefusedException("The release manifest's signature is missing or unreadable. Nothing was downloaded.");
    foreach (var raw in keys ?? PublicKeys)
    {
      byte[] key;
      try { key = Convert.FromBase64String(raw); } catch (FormatException) { continue; }
      if (key.Length != 32) continue;
      var verifier = new Ed25519Signer();
      verifier.Init(false, new Ed25519PublicKeyParameters(key, 0));
      verifier.BlockUpdate(manifest, 0, manifest.Length);
      if (verifier.VerifySignature(signature)) return;
    }
    throw new RefusedException("The release manifest is not signed by Terminal Deck's release key. Nothing was downloaded.");
  }

  // The Windows part of a verified manifest.
  public static WindowsRelease Parse(byte[] manifest)
  {
    JsonDocument document;
    try { document = JsonDocument.Parse(manifest); }
    catch (JsonException) { throw new RefusedException("The release manifest is not valid JSON."); }
    using (document)
    {
      var root = document.RootElement;
      if (root.ValueKind != JsonValueKind.Object || !Has(root, "schema", JsonValueKind.Number) || root.GetProperty("schema").GetInt32() != 1 || Text(root, "product") != "terminaldeck")
        throw new RefusedException("The release manifest belongs to another product or a newer format. Update by hand from the releases page.");
      if (!root.TryGetProperty("windows", out var windows) || windows.ValueKind != JsonValueKind.Object) throw new RefusedException("This release has no Windows app.");
      var version = Text(windows, "version");
      if (!System.Version.TryParse(version, out var parsed) || parsed.Revision < 0 || version.Split('.').Length != 4)
        throw new RefusedException("The release manifest has an invalid Windows version.");
      if (Text(windows, "packageName") != PackageName || Text(windows, "publisher") != Publisher)
        throw new RefusedException("This release names another package or publisher. Nothing was downloaded.");
      var architecture = Text(windows, "architecture");
      if (architecture != "x64") throw new RefusedException("This release is not for x64 Windows.");
      var sha256 = Text(windows, "sha256");
      if (sha256.Length != 64 || !sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) throw new RefusedException("The release manifest has an invalid SHA-256.");
      if (!Has(windows, "size", JsonValueKind.Number) || !windows.GetProperty("size").TryGetInt64(out var size) || size <= 0 || size > PackageLimit)
        throw new RefusedException("The release manifest has an invalid package size.");
      if (!Uri.TryCreate(Text(windows, "url"), UriKind.Absolute, out var url) || !IsReleaseAsset(url, ".msix"))
        throw new RefusedException("The Windows package must be an MSIX asset of " + Repository + "'s GitHub releases.");
      Uri? notes = root.TryGetProperty("notesUrl", out var n) && n.ValueKind == JsonValueKind.String && Uri.TryCreate(n.GetString(), UriKind.Absolute, out var page)
        && page.Scheme == Uri.UriSchemeHttps && page.Host == "github.com" && page.AbsolutePath.StartsWith("/" + Repository + "/releases/", StringComparison.Ordinal) ? page : null;
      var text = root.TryGetProperty("notes", out var body) && body.ValueKind == JsonValueKind.String ? body.GetString()?.Trim() : null;
      if (text is { Length: > 4000 }) text = text[..4000];
      return new WindowsRelease(version, url, size, sha256, architecture, notes, string.IsNullOrEmpty(text) ? null : text);
    }
  }

  public static bool IsNewer(string candidate, System.Version installed) =>
    System.Version.TryParse(candidate, out var offered) && offered > installed;

  // https://github.com/<repo>/releases/download/<tag>/<file>, nothing else (no query, no other host, no ..).
  public static bool IsReleaseAsset(Uri url, string extension)
  {
    if (url.Scheme != Uri.UriSchemeHttps || url.Host != "github.com" || !url.IsDefaultPort || url.UserInfo.Length > 0 || url.Query.Length > 0 || url.Fragment.Length > 0) return false;
    var parts = url.AbsolutePath.Split('/');
    return parts.Length == 7 && parts[0] == "" && parts[1] + "/" + parts[2] == Repository && parts[3] == "releases" && parts[4] == "download"
      && parts[5].Length > 0 && !parts[6].Contains("..") && parts[6].EndsWith(extension, StringComparison.OrdinalIgnoreCase);
  }

  public static bool AllowedHost(Uri url) => url.Scheme == Uri.UriSchemeHttps && url.UserInfo.Length == 0 && AllowedHosts.Contains(url.Host);

  // GitHub answers a release asset with a redirect to its storage host. Each hop must stay on GitHub's hosts.
  public static async Task<HttpResponseMessage> GetAsync(HttpClient client, Uri url, CancellationToken cancel)
  {
    for (var hop = 0; hop < 6; hop++)
    {
      if (!AllowedHost(url)) throw new RefusedException("The release download left GitHub. Nothing was installed.");
      var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel);
      if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } next)
      {
        url = next.IsAbsoluteUri ? next : new Uri(url, next);
        response.Dispose();
        continue;
      }
      if ((int)response.StatusCode == 404) { response.Dispose(); throw new RefusedException("The newest release on GitHub has no release manifest yet."); }
      if (!response.IsSuccessStatusCode) { var status = (int)response.StatusCode; response.Dispose(); throw new IOException("GitHub answered " + status + "."); }
      return response;
    }
    throw new IOException("GitHub redirected the download too many times.");
  }

  public static HttpClient NewClient() => new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromMinutes(15) };

  public static async Task<byte[]> ReadSmallAsync(HttpClient client, Uri url, int limit, CancellationToken cancel)
  {
    using var response = await GetAsync(client, url, cancel);
    await using var stream = await response.Content.ReadAsStreamAsync(cancel);
    using var buffer = new MemoryStream();
    var chunk = new byte[16384];
    int read;
    while ((read = await stream.ReadAsync(chunk, cancel)) > 0)
    {
      if (buffer.Length + read > limit) throw new RefusedException("The release manifest is too large.");
      buffer.Write(chunk, 0, read);
    }
    return buffer.ToArray();
  }

  // The signed manifest of the newest release: fetched, verified, parsed.
  public static async Task<WindowsRelease> FetchAsync(HttpClient client, CancellationToken cancel)
  {
    var manifest = await ReadSmallAsync(client, ManifestUri, ManifestLimit, cancel);
    var signature = System.Text.Encoding.UTF8.GetString(await ReadSmallAsync(client, SignatureUri, 1024, cancel));
    Verify(manifest, signature);
    return Parse(manifest);
  }

  // Downloads into `folder` (the app's own LocalState), then checks size and SHA-256 before anything else reads it.
  public static async Task<string> DownloadAsync(HttpClient client, WindowsRelease release, string folder, IProgress<double>? progress, CancellationToken cancel)
  {
    Directory.CreateDirectory(folder);
    var target = Path.Combine(folder, "TerminalDeck-" + release.Version + "-x64.msix");
    var partial = target + ".part";
    using (var response = await GetAsync(client, release.Url, cancel))
    await using (var input = await response.Content.ReadAsStreamAsync(cancel))
    await using (var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None))
    {
      var chunk = new byte[1 << 16];
      long total = 0;
      int read;
      while ((read = await input.ReadAsync(chunk, cancel)) > 0)
      {
        total += read;
        if (total > release.Size) throw new RefusedException("The download is larger than the release manifest says. Nothing was installed.");
        await output.WriteAsync(chunk.AsMemory(0, read), cancel);
        progress?.Report(total * 100.0 / release.Size);
      }
    }
    VerifyFile(partial, release);
    File.Move(partial, target, overwrite: true);
    VerifyPackage(target, release);
    return target;
  }

  public static void VerifyFile(string path, WindowsRelease release)
  {
    var info = new FileInfo(path);
    if (!info.Exists || info.Length != release.Size) throw new RefusedException("The downloaded package has the wrong size. Nothing was installed.");
    using var stream = File.OpenRead(path);
    if (Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != release.Sha256)
      throw new RefusedException("The downloaded package failed its SHA-256 check. Nothing was installed.");
  }

  // The MSIX's own AppxManifest says the same package, publisher, version and architecture.
  public static void VerifyPackage(string path, WindowsRelease release)
  {
    XElement? identity;
    try
    {
      using var zip = ZipFile.OpenRead(path);
      var entry = zip.GetEntry("AppxManifest.xml") ?? throw new RefusedException("The downloaded file is not an MSIX package.");
      using var stream = entry.Open();
      identity = XDocument.Load(stream).Descendants().FirstOrDefault(e => e.Name.LocalName == "Identity");
    }
    catch (Exception ex) when (ex is InvalidDataException or System.Xml.XmlException) { throw new RefusedException("The downloaded file is not a readable MSIX package."); }
    if (identity is null || (string?)identity.Attribute("Name") != PackageName || (string?)identity.Attribute("Publisher") != Publisher
        || (string?)identity.Attribute("Version") != release.Version || (string?)identity.Attribute("ProcessorArchitecture") != release.Architecture)
      throw new RefusedException("The downloaded package is not this app's " + release.Version + " for x64. Nothing was installed.");
  }

  private static bool Has(JsonElement element, string name, JsonValueKind kind) => element.TryGetProperty(name, out var value) && value.ValueKind == kind;
  private static string Text(JsonElement element, string name) =>
    element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
}
