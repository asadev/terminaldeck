using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Platform;

// The Windows-only update channel (13 Nov 2026). Windows releases are made by their own GitHub Actions workflow
// (.github/workflows/windows-release.yml) and can go out without a Mac release, and the other way round.
//
// The workflow keeps ONE fixed release, tag "windows-stable" (a pre-release, so it is never GitHub's "latest"),
// that holds windows-update.json + windows-update.json.sig: the same shape as the shared release-manifest.json's
// Windows part, plus "platform": "windows", signed with the WINDOWS-ONLY Ed25519 key below. That key can move
// Windows updates and nothing else: the Mac app never trusts it, and GitHubReleaseChannel.Verify (the shared
// manifest) does not accept it either.
//
// The app checks both sources and offers the newer verified Windows package: the Windows feed, and the shared
// release-manifest.json of the newest combined release (signed by the main release key), so a combined release
// still reaches Windows and neither line can hold the other back. Every download check after this point is
// GitHubReleaseChannel's (size, SHA-256, package name, publisher, version; Windows checks the MSIX signature).
public static class WindowsReleaseFeed
{
  public const string ChannelTag = "windows-stable";
  public const string FeedFile = "windows-update.json";
  public static readonly Uri FeedUri = new("https://github.com/" + GitHubReleaseChannel.Repository + "/releases/download/" + ChannelTag + "/" + FeedFile);
  public static readonly Uri SignatureUri = new(FeedUri.AbsoluteUri + ".sig");
  // Raw 32-byte Ed25519 public keys, base64. Windows-only; a new key is added one release before it signs.
  public static readonly IReadOnlyList<string> PublicKeys = ["dEXooWaSwDx1EgMRuWdIJGeZ400ZsMzhqVwCh/5L+Rk="];

  // A Windows feed file: signed by a Windows key AND marked as the Windows channel's own file.
  public static GitHubReleaseChannel.WindowsRelease Read(byte[] feed, string signatureText, IReadOnlyList<string>? keys = null)
  {
    GitHubReleaseChannel.Verify(feed, signatureText, keys ?? PublicKeys);
    try
    {
      using var document = JsonDocument.Parse(feed);
      if (document.RootElement.ValueKind != JsonValueKind.Object || !document.RootElement.TryGetProperty("platform", out var platform)
          || platform.ValueKind != JsonValueKind.String || platform.GetString() != "windows")
        throw new GitHubReleaseChannel.RefusedException("The Windows update file is not the Windows channel's own file. Nothing was downloaded.");
    }
    catch (JsonException) { throw new GitHubReleaseChannel.RefusedException("The Windows update file is not valid JSON."); }
    return GitHubReleaseChannel.Parse(feed);
  }

  // The newer of the two verified offers; null when neither source answered with one.
  public static GitHubReleaseChannel.WindowsRelease? Newest(GitHubReleaseChannel.WindowsRelease? a, GitHubReleaseChannel.WindowsRelease? b)
  {
    if (a is null) return b;
    if (b is null) return a;
    return System.Version.Parse(b.Version) > System.Version.Parse(a.Version) ? b : a;
  }

  public static async Task<GitHubReleaseChannel.WindowsRelease> FetchAsync(HttpClient client, CancellationToken cancel)
  {
    GitHubReleaseChannel.WindowsRelease? own = null, shared = null;
    Exception? ownError = null, sharedError = null;
    try
    {
      var feed = await GitHubReleaseChannel.ReadSmallAsync(client, FeedUri, GitHubReleaseChannel.ManifestLimit, cancel);
      var signature = Encoding.UTF8.GetString(await GitHubReleaseChannel.ReadSmallAsync(client, SignatureUri, 1024, cancel));
      own = Read(feed, signature);
    }
    catch (Exception ex) when (ex is GitHubReleaseChannel.RefusedException or HttpRequestException or IOException) { ownError = ex; }
    try { shared = await GitHubReleaseChannel.FetchAsync(client, cancel); }
    catch (Exception ex) when (ex is GitHubReleaseChannel.RefusedException or HttpRequestException or IOException) { sharedError = ex; }
    return Newest(own, shared) ?? throw (ownError ?? sharedError)!;
  }
}
