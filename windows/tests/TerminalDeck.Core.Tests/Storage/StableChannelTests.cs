using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Storage;

public sealed class StableChannelTests
{
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
