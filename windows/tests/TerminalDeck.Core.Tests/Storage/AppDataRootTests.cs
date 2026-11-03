using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Storage;

public sealed class AppDataRootTests
{
  [Fact]
  public void DevelopmentLaunchCannotFallBackToLiveData()
  {
    Assert.Throws<ArgumentException>(() => AppDataRoot.FromArguments([], development: true));
    Assert.Throws<ArgumentException>(() => AppDataRoot.FromArguments(["--user-data-dir"]));
    Assert.Throws<ArgumentException>(() => AppDataRoot.Explicit("relative"));
  }

  [Fact]
  public void InstalledLaunchUsesTheStandardRootWithoutCreatingIt()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-installed-" + Guid.NewGuid());
    Assert.Equal(Path.Combine(path, "TerminalDeck"), InstalledDataRoot.Resolve(path, "fixture-pc").DirectoryPath);
    Assert.False(Directory.Exists(path));
  }

  [Fact]
  public void MigrationPreservesTheNamespaceAndOnlyAppliesOnItsOwnMachine()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-migration-" + Guid.NewGuid());
    try
    {
      var original = Path.Combine(path, "review");
      Directory.CreateDirectory(Path.Combine(original, "state")); File.WriteAllText(Path.Combine(original, "state", "sessions.json"), "[]");
      var standard = Path.Combine(path, "TerminalDeck"); Directory.CreateDirectory(standard);
      File.WriteAllText(Path.Combine(standard, "installed-data-root.json"), System.Text.Json.JsonSerializer.Serialize(new InstalledDataRoot("fixture-pc", original)));
      Assert.Equal(AppDataRoot.Explicit(original).NamespaceId, InstalledDataRoot.Resolve(path, "fixture-pc").NamespaceId);
      Assert.Equal(standard, InstalledDataRoot.Resolve(path, "another-pc").DirectoryPath);
      File.Delete(Path.Combine(original, "state", "sessions.json"));
      Assert.Throws<IOException>(() => InstalledDataRoot.Resolve(path, "fixture-pc"));
    }
    finally { Directory.Delete(path, true); }
  }

  [Fact]
  public void EquivalentRootsHaveOneNamespaceWithoutCreatingDirectories()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-windows-" + Guid.NewGuid());
    var first = AppDataRoot.Explicit(path);
    var second = AppDataRoot.Explicit(Path.Combine(path, "child", ".."));
    Assert.Equal(first.NamespaceId, second.NamespaceId);
    Assert.False(Directory.Exists(path));
  }

  [Fact]
  public void SeparateTestRootsCannotShareKeeperOrCredentialNamespace()
  {
    var one = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()));
    var two = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()));
    Assert.NotEqual(one.NamespaceId, two.NamespaceId);
  }

  [Fact]
  public void BothArgumentSpellingsPreserveTheChosenRoot()
  {
    var path = Path.Combine(Path.GetTempPath(), "td windows scratch");
    Assert.Equal(AppDataRoot.FromArguments(["--user-data-dir", path]).DirectoryPath,
      AppDataRoot.FromArguments(["--user-data-dir=" + path]).DirectoryPath);
    Assert.Throws<ArgumentException>(() => AppDataRoot.FromArguments(["--user-data-dir", path, "--user-data-dir", path]));
  }
}
