using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.Core.Tests.Storage;

public sealed class StableChannelTests
{
  [Fact]
  public void RetiredPackageMarkerDoesNotBlockNewSessionsUsingTheExistingLogin()
  {
    var scratch = Path.Combine(Path.GetTempPath(), "stable-retired-" + Guid.NewGuid().ToString("N"));
    var package = Path.Combine(scratch, "package");
    Directory.CreateDirectory(package);
    try
    {
      var marker = Path.Combine(package, StableChannel.Marker);
      File.WriteAllText(marker, "");
      var root = StableChannel.Root(scratch);
      var before = AccountHomes.Resolve(root, "claude", AccountHomes.ExistingLogin, scratch, StableChannel.IsStable(package));
      File.Delete(marker);
      Assert.False(File.Exists(marker));
      foreach (var provider in new[] { "claude", "codex", "gemini" })
      {
        var home = AccountHomes.Resolve(root, provider, AccountHomes.ExistingLogin, scratch, StableChannel.IsStable(package));
        Assert.Equal(provider == "gemini" ? scratch : Path.Combine(scratch, "." + provider), home);
      }
      Assert.Equal(Path.Combine(scratch, ".claude"), before);
      Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(AppDataRoot.Explicit(Path.Combine(scratch, "test-data")),
        "claude", AccountHomes.ExistingLogin, scratch, StableChannel.IsStable(package)));
    }
    finally { Directory.Delete(scratch, true); }
  }

  [Fact]
  public void TestCopyCannotAcquireExistingLoginAccessByAddingAMarkerLater()
  {
    var scratch = Path.Combine(Path.GetTempPath(), "stable-test-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(scratch);
    try
    {
      Assert.False(StableChannel.IsStable(scratch));
      File.WriteAllText(Path.Combine(scratch, StableChannel.Marker), "");
      Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(StableChannel.Root(scratch),
        "claude", AccountHomes.ExistingLogin, scratch, StableChannel.IsStable(scratch)));
    }
    finally { Directory.Delete(scratch, true); }
  }

  [Fact]
  public void PublisherChangesDoNotChangeTheDataOrCredentialNamespace()
  {
    var profile = Path.Combine(Path.GetTempPath(), "stable-profile");
    var first = StableChannel.Resolve(null, profile);
    Assert.Equal(first.NamespaceId, StableChannel.Resolve(first.DirectoryPath, profile).NamespaceId);
    Assert.EndsWith("TerminalDeckStable", first.DirectoryPath);
    Assert.NotEqual(first.NamespaceId, AppDataRoot.Explicit(Path.Combine(profile, "test-data")).NamespaceId);
  }

  [Fact]
  public void StablePackageCannotBePointedAtTheTestData()
  {
    var profile = Path.Combine(Path.GetTempPath(), "stable-profile");
    Assert.Throws<ArgumentException>(() => StableChannel.Resolve(Path.Combine(profile, "test-data"), profile));
  }
}
