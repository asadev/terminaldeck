using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Platform;

// Release 27: Windows updates from the public GitHub releases' signed release-manifest.json. The fixture was
// written by tools/release/make-release-manifest.mjs with the REAL release key; the Mac suite
// (Release27UpdateManifestTests) checks the very same bytes, so both apps accept one file.
public sealed class GitHubReleaseChannelTests
{
  private static readonly byte[] Fixture = Convert.FromBase64String("ewogICJzY2hlbWEiOiAxLAogICJwcm9kdWN0IjogInRlcm1pbmFsZGVjayIsCiAgInZlcnNpb24iOiAiOS45LjkiLAogICJ0YWciOiAidjkuOS45IiwKICAiY29tbWl0IjogIjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1NjciLAogICJyZWxlYXNlRGF0ZSI6ICIyMDI2LTExLTAzVDIyOjAwOjAwLjAwMFoiLAogICJub3Rlc1VybCI6ICJodHRwczovL2dpdGh1Yi5jb20vYXNhZGV2L3Rlcm1pbmFsZGVjay9yZWxlYXNlcy90YWcvdjkuOS45IiwKICAibm90ZXMiOiAiRml4dHVyZSBub3Rlcy4iLAogICJtYWMiOiB7CiAgICAiZmlsZSI6ICJ0ZXJtaW5hbGRlY2stbmF0aXZlLTkuOS45LWFybTY0LnppcCIsCiAgICAidXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS9hc2FkZXYvdGVybWluYWxkZWNrL3JlbGVhc2VzL2Rvd25sb2FkL3Y5LjkuOS90ZXJtaW5hbGRlY2stbmF0aXZlLTkuOS45LWFybTY0LnppcCIsCiAgICAic2l6ZSI6IDIyLAogICAgInNoYTI1NiI6ICJlYWM3NzFkMjJiNzdhOWM1M2IzOTgyMmZkM2ZkMjMyYzZmNTk5OGJhYTlkMzAyNTMyN2E0ZGUzNzI2ODNlYWFhIiwKICAgICJzaGE1MTIiOiAibzFtcjZLL2ZlQU82T1ZJQlFkZnZLYWg1clQvUlp4anUwbDlYZjBaZjVmZU1WQmdUWCt3bjdVMExHMXJjMi9wS2dCTGtuUmZ1d1FrQWxzWmpVNHZqNGc9PSIsCiAgICAiYnVuZGxlSWRlbnRpZmllciI6ICJkZXYudGVybWluYWxkZWNrLmFwcCIsCiAgICAiYXJjaGl0ZWN0dXJlIjogImFybTY0IiwKICAgICJ0ZWFtSWRlbnRpZmllciI6ICI2VTRWTlg1Vzg3IiwKICAgICJub3Rhcml6ZWQiOiBmYWxzZQogIH0sCiAgIndpbmRvd3MiOiB7CiAgICAiZmlsZSI6ICJUZXJtaW5hbERlY2stOS45LjkuMC14NjQubXNpeCIsCiAgICAidXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS9hc2FkZXYvdGVybWluYWxkZWNrL3JlbGVhc2VzL2Rvd25sb2FkL3Y5LjkuOS9UZXJtaW5hbERlY2stOS45LjkuMC14NjQubXNpeCIsCiAgICAic2l6ZSI6IDE5LAogICAgInNoYTI1NiI6ICJmNzExYmU4NGY4OWJkZDgwYWRiZWY0M2Q3OTljMmVhYTUwZTFmMzYxOWUyMDZmNzdlNjFmY2UwZTcwMGZlMTQ2IiwKICAgICJwYWNrYWdlTmFtZSI6ICJUZXJtaW5hbERlY2siLAogICAgInB1Ymxpc2hlciI6ICJDTj1UZXJtaW5hbCBEZWNrIFN0YWJsZSIsCiAgICAidmVyc2lvbiI6ICI5LjkuOS4wIiwKICAgICJhcmNoaXRlY3R1cmUiOiAieDY0IgogIH0KfQo=");
  private const string FixtureSignature = "SKMHPTRUEd2qsCbYQBM2X/ru/f1fsuhmpwZFVczXeqwT/2YDDLXWJETESafmRpW666MoIGlxGEP4oDMuAQM9AA==";

  [Fact]
  public void TheRealKeySignedFixtureVerifiesAndReadsAsTheWindowsRelease()
  {
    GitHubReleaseChannel.Verify(Fixture, FixtureSignature + "\n");
    var release = GitHubReleaseChannel.Parse(Fixture);
    Assert.Equal("9.9.9.0", release.Version);
    Assert.Equal(19, release.Size);
    Assert.Equal("f711be84f89bdd80adbef43d799c2eaa50e1f3619e206f77e61fce0e700fe146", release.Sha256);
    Assert.Equal("https://github.com/asadev/terminaldeck/releases/download/v9.9.9/TerminalDeck-9.9.9.0-x64.msix", release.Url.AbsoluteUri);
    Assert.Equal("https://github.com/asadev/terminaldeck/releases/tag/v9.9.9", release.NotesUrl?.AbsoluteUri);
    Assert.Equal("Fixture notes.", release.Notes);
    Assert.True(GitHubReleaseChannel.IsNewer(release.Version, new Version(0, 20, 4, 1)));
    Assert.False(GitHubReleaseChannel.IsNewer("0.20.4.1", new Version(0, 20, 4, 1)));
  }

  [Fact]
  public void AChangedByteOrAnotherKeyIsRefusedBeforeAnyDownload()
  {
    var changed = (byte[])Fixture.Clone(); changed[changed.Length / 2] ^= 1;
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Verify(changed, FixtureSignature));
    var (_, otherSignature) = SignWithNewKey(Fixture);
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Verify(Fixture, otherSignature));
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Verify(Fixture, "not base64"));
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Verify(Fixture, ""));
  }

  [Theory]
  [InlineData("publisher")]
  [InlineData("package")]
  [InlineData("repository")]
  [InlineData("sha256")]
  [InlineData("version")]
  [InlineData("product")]
  [InlineData("architecture")]
  public void ASignedManifestForAnotherPackageOrPlaceIsStillRefused(string change)
  {
    var root = JsonNode.Parse(Fixture)!.AsObject();
    var windows = root["windows"]!.AsObject();
    switch (change)
    {
      case "publisher": windows["publisher"] = "CN=Someone Else"; break;
      case "package": windows["packageName"] = "Other"; break;
      case "repository": windows["url"] = "https://github.com/someone/else/releases/download/v9.9.9/TerminalDeck-9.9.9.0-x64.msix"; break;
      case "sha256": windows["sha256"] = "ABC"; break;
      case "version": windows["version"] = "9.9.9"; break;
      case "product": root["product"] = "other"; break;
      case "architecture": windows["architecture"] = "arm64"; break;
    }
    var bytes = Encoding.UTF8.GetBytes(root.ToJsonString());
    var (key, signature) = SignWithNewKey(bytes);
    GitHubReleaseChannel.Verify(bytes, signature, [key]);
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Parse(bytes));
  }

  [Theory]
  [InlineData("https://github.com/asadev/terminaldeck/releases/download/v1/TerminalDeck.msix", true)]
  [InlineData("http://github.com/asadev/terminaldeck/releases/download/v1/TerminalDeck.msix", false)]
  [InlineData("https://example.com/asadev/terminaldeck/releases/download/v1/TerminalDeck.msix", false)]
  [InlineData("https://github.com/asadev/terminaldeck/releases/download/v1/TerminalDeck.msix?x=1", false)]
  [InlineData("https://github.com/asadev/terminaldeck/releases/download/v1/TerminalDeck.exe", false)]
  [InlineData("https://github.com/asadev/terminaldeck/raw/main/TerminalDeck.msix", false)]
  public void OnlyThisRepositorysReleaseAssetsAreDownloaded(string url, bool allowed) =>
    Assert.Equal(allowed, GitHubReleaseChannel.IsReleaseAsset(new Uri(url), ".msix"));

  [Fact]
  public void RedirectsMayOnlyStayOnGitHubsHosts()
  {
    Assert.True(GitHubReleaseChannel.AllowedHost(new Uri("https://release-assets.githubusercontent.com/x")));
    Assert.True(GitHubReleaseChannel.AllowedHost(new Uri("https://objects.githubusercontent.com/x")));
    Assert.False(GitHubReleaseChannel.AllowedHost(new Uri("https://evil.example/x")));
    Assert.False(GitHubReleaseChannel.AllowedHost(new Uri("http://github.com/x")));
  }

  [Fact]
  public void TheDownloadedPackageMustMatchSizeHashAndItsOwnIdentity()
  {
    var folder = Path.Combine(Path.GetTempPath(), "r27-msix-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(folder);
    try
    {
      var msix = Path.Combine(folder, "p.msix");
      using (var zip = ZipFile.Open(msix, ZipArchiveMode.Create))
      using (var writer = new StreamWriter(zip.CreateEntry("AppxManifest.xml").Open()))
        writer.Write("<Package xmlns=\"http://schemas.microsoft.com/appx/manifest/foundation/windows10\"><Identity Name=\"TerminalDeck\" Publisher=\"CN=Terminal Deck Stable\" Version=\"9.9.9.0\" ProcessorArchitecture=\"x64\"/></Package>");
      var bytes = File.ReadAllBytes(msix);
      var sha = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
      var release = new GitHubReleaseChannel.WindowsRelease("9.9.9.0", new Uri("https://github.com/asadev/terminaldeck/releases/download/v9.9.9/p.msix"), bytes.Length, sha, "x64", null, null);
      GitHubReleaseChannel.VerifyFile(msix, release);
      GitHubReleaseChannel.VerifyPackage(msix, release);
      Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.VerifyFile(msix, release with { Sha256 = new string('0', 64) }));
      Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.VerifyFile(msix, release with { Size = bytes.Length + 1 }));
      Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.VerifyPackage(msix, release with { Version = "9.9.9.1" }));
    }
    finally { Directory.Delete(folder, true); }
  }

  private static (string Key, string Signature) SignWithNewKey(byte[] data)
  {
    var generator = new Ed25519KeyPairGenerator();
    generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
    var pair = generator.GenerateKeyPair();
    var signer = new Ed25519Signer();
    signer.Init(true, pair.Private);
    signer.BlockUpdate(data, 0, data.Length);
    return (Convert.ToBase64String(((Ed25519PublicKeyParameters)pair.Public).GetEncoded()), Convert.ToBase64String(signer.GenerateSignature()));
  }
}
