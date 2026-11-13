using System.Text;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Platform;

// The Windows-only update channel (WindowsReleaseFeed). The fixture was written by
// windows/scripts/windows/make-windows-update.mjs (the workflow's signer) with a throwaway test key, so these tests
// prove the workflow's bytes and the app's reader agree. Named GitHubReleaseChannel* so the public CI's update
// filter runs them.
public sealed class GitHubReleaseChannelWindowsFeedTests
{
  private static readonly byte[] Feed = Convert.FromBase64String("ewogICJzY2hlbWEiOiAxLAogICJwcm9kdWN0IjogInRlcm1pbmFsZGVjayIsCiAgInBsYXRmb3JtIjogIndpbmRvd3MiLAogICJ2ZXJzaW9uIjogIjkuOS45LjAiLAogICJ0YWciOiAid2luZG93cy12OS45LjkuMCIsCiAgImNvbW1pdCI6ICIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3IiwKICAicmVsZWFzZURhdGUiOiAiMjAyNi0xMS0xM1QwMDowMDowMC4wMDBaIiwKICAibm90ZXNVcmwiOiAiaHR0cHM6Ly9naXRodWIuY29tL2FzYWRldi90ZXJtaW5hbGRlY2svcmVsZWFzZXMvdGFnL3dpbmRvd3MtdjkuOS45LjAiLAogICJub3RlcyI6ICJGaXh0dXJlIG5vdGVzLiIsCiAgIndpbmRvd3MiOiB7CiAgICAiZmlsZSI6ICJUZXJtaW5hbERlY2stOS45LjkuMC14NjQubXNpeCIsCiAgICAidXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS9hc2FkZXYvdGVybWluYWxkZWNrL3JlbGVhc2VzL2Rvd25sb2FkL3dpbmRvd3MtdjkuOS45LjAvVGVybWluYWxEZWNrLTkuOS45LjAteDY0Lm1zaXgiLAogICAgInNpemUiOiAxOSwKICAgICJzaGEyNTYiOiAiMjQ5MjgzYzY0ZGJmZTY3NmM4YzRkYmI2NDZjODIwZTI5YThlZTU1MmExNzRhMDhjNTBlNzczZGNkNDhkOWVlZiIsCiAgICAicGFja2FnZU5hbWUiOiAiVGVybWluYWxEZWNrIiwKICAgICJwdWJsaXNoZXIiOiAiQ049VGVybWluYWwgRGVjayBTdGFibGUiLAogICAgInZlcnNpb24iOiAiOS45LjkuMCIsCiAgICAiYXJjaGl0ZWN0dXJlIjogIng2NCIKICB9Cn0K");
  private const string FeedSignature = "7E7rFmQ1VF3QTgfgJuYL8Uy4tVPbRjEZmf4Ld7EdEETWxuBGL45q+CiaKIfZnwNV8WM/KFLRVyn5vLbIo6WiAw==";
  private static readonly string[] TestKey = ["5tJxcl3iVXPIlQX/8Pw89zWm35FTkwRCWBT1DyPxTRk="];

  [Fact]
  public void TheWorkflowsSignedFeedReadsAsTheWindowsRelease()
  {
    var release = WindowsReleaseFeed.Read(Feed, FeedSignature + "\n", TestKey);
    Assert.Equal("9.9.9.0", release.Version);
    Assert.Equal(19, release.Size);
    Assert.Equal("249283c64dbfe676c8c4dbb646c820e29a8ee552a174a08c50e773dcd48d9eef", release.Sha256);
    Assert.Equal("https://github.com/asadev/terminaldeck/releases/download/windows-v9.9.9.0/TerminalDeck-9.9.9.0-x64.msix", release.Url.AbsoluteUri);
    Assert.Equal("https://github.com/asadev/terminaldeck/releases/tag/windows-v9.9.9.0", release.NotesUrl?.AbsoluteUri);
    Assert.Equal("Fixture notes.", release.Notes);
  }

  [Fact]
  public void TheFeedLivesOnTheFixedWindowsReleaseNotOnLatest()
  {
    Assert.Equal("https://github.com/asadev/terminaldeck/releases/download/windows-stable/windows-update.json", WindowsReleaseFeed.FeedUri.AbsoluteUri);
    Assert.Equal(WindowsReleaseFeed.FeedUri.AbsoluteUri + ".sig", WindowsReleaseFeed.SignatureUri.AbsoluteUri);
    Assert.True(GitHubReleaseChannel.IsReleaseAsset(WindowsReleaseFeed.FeedUri, ".json"));
    Assert.All(WindowsReleaseFeed.PublicKeys, key => Assert.Equal(32, Convert.FromBase64String(key).Length));
  }

  [Fact]
  public void TheTwoKeysNeverStandInForEachOther()
  {
    // The Windows feed is refused under the shared release key (so the Windows key moves nothing but Windows)...
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => GitHubReleaseChannel.Verify(Feed, FeedSignature));
    // ...and the real Windows keys are not the shared release key.
    Assert.DoesNotContain(WindowsReleaseFeed.PublicKeys, key => GitHubReleaseChannel.PublicKeys.Contains(key));
    // A feed under the compiled-in Windows keys only: the test key is not one of them.
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => WindowsReleaseFeed.Read(Feed, FeedSignature));
  }

  [Fact]
  public void AChangedByteOrAFileWithoutTheWindowsMarkIsRefused()
  {
    var changed = (byte[])Feed.Clone(); changed[changed.Length / 2] ^= 1;
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => WindowsReleaseFeed.Read(changed, FeedSignature, TestKey));
    var root = JsonNode.Parse(Feed)!.AsObject();
    root.Remove("platform");
    var unmarked = Encoding.UTF8.GetBytes(root.ToJsonString());
    var (key, signature) = SignWithNewKey(unmarked);
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => WindowsReleaseFeed.Read(unmarked, signature, [key]));
    root["platform"] = "mac";
    var mac = Encoding.UTF8.GetBytes(root.ToJsonString());
    (key, signature) = SignWithNewKey(mac);
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => WindowsReleaseFeed.Read(mac, signature, [key]));
  }

  [Fact]
  public void ASignedFeedForAnotherPackageOrPlaceIsStillRefused()
  {
    var root = JsonNode.Parse(Feed)!.AsObject();
    root["windows"]!["url"] = "https://github.com/someone/else/releases/download/windows-v9.9.9.0/TerminalDeck-9.9.9.0-x64.msix";
    var bytes = Encoding.UTF8.GetBytes(root.ToJsonString());
    var (key, signature) = SignWithNewKey(bytes);
    Assert.Throws<GitHubReleaseChannel.RefusedException>(() => WindowsReleaseFeed.Read(bytes, signature, [key]));
  }

  [Fact]
  public void TheNewerOfTheTwoSourcesIsOffered()
  {
    var feed = WindowsReleaseFeed.Read(Feed, FeedSignature, TestKey);
    var older = feed with { Version = "0.21.2.0" };
    Assert.Same(feed, WindowsReleaseFeed.Newest(feed, older));
    Assert.Same(feed, WindowsReleaseFeed.Newest(older, feed));
    Assert.Same(older, WindowsReleaseFeed.Newest(null, older));
    Assert.Same(feed, WindowsReleaseFeed.Newest(feed, null));
    Assert.Null(WindowsReleaseFeed.Newest(null, null));
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
