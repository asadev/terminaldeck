using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Sessions;
using System.Text.Json;

namespace TerminalDeck.Core.Tests.Storage;

public sealed class InstalledPackageRootTests
{
  [Fact]
  public void Machine_receipt_keeps_original_physical_state_and_namespace_over_unrelated_plain_stable()
  {
    InFixture((profile, cache) =>
    {
      var legacy = AppDataRoot.Explicit(Path.Combine(profile, "AppData", "Local", "TerminalDeck"));
      var physical = Path.Combine(cache, "Local", "TerminalDeck");
      Saved(physical, "sessions");
      Saved(Path.Combine(profile, "AppData", "Local", "TerminalDeckStable"), "accounts");
      Receipt(physical, physical);
      var selected = StableChannel.Resolve(null, profile, cache);
      Assert.Equal(physical, selected.DirectoryPath);
      Assert.Equal(legacy.NamespaceId, selected.NamespaceId);
      Assert.Equal(selected.DirectoryPath, StableChannel.Root(profile).DirectoryPath);
      Assert.Equal(Path.Combine(profile, ".claude"), AccountHomes.Resolve(selected, "claude", AccountHomes.ExistingLogin, profile, true));
      Assert.Equal(selected.NamespaceId, StableChannel.Resolve(selected.DirectoryPath, profile).NamespaceId);
      Assert.False(File.Exists(Path.Combine(legacy.DirectoryPath, "state", "sessions.json")));
      Assert.True(StableChannel.IsLegacyRoot(selected, profile));
    });
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void Cached_stable_wins_over_cached_legacy_when_no_plain_stable_or_receipt_exists(bool oldData)
  {
    InFixture((profile, cache) =>
    {
      Saved(Path.Combine(cache, "Local", "TerminalDeckStable"), "accounts");
      if (oldData) Saved(Path.Combine(cache, "Local", "TerminalDeck"), "sessions");
      var selected = StableChannel.Resolve(null, profile, cache);
      Assert.Equal(Path.Combine(cache, "Local", "TerminalDeckStable"), selected.DirectoryPath);
      Assert.Equal(AppDataRoot.Explicit(Path.Combine(profile, "AppData", "Local", "TerminalDeckStable")).NamespaceId, selected.NamespaceId);
      Assert.False(StableChannel.IsLegacyRoot(selected, profile));
    });
  }

  [Fact]
  public void Existing_unvirtualized_stable_wins_without_a_receipt()
  {
    InFixture((profile, cache) =>
    {
      var stable = Path.Combine(profile, "AppData", "Local", "TerminalDeckStable");
      Saved(stable, "accounts"); Saved(Path.Combine(cache, "Local", "TerminalDeck"), "sessions"); Saved(Path.Combine(cache, "Local", "TerminalDeckStable"), "projects");
      Assert.Equal(stable, StableChannel.Resolve(null, profile, cache).DirectoryPath);
    });
  }

  [Theory]
  [InlineData("TerminalDeck")]
  [InlineData("TerminalDeckStable")]
  public void Fresh_child_accepts_saved_physical_root_with_same_old_namespace(string name)
  {
    InFixture((profile, cache) =>
    {
      var physical = Path.Combine(cache, "Local", name); Saved(physical, "projects");
      var selected = StableChannel.Resolve(physical, profile);
      var logical = AppDataRoot.Explicit(Path.Combine(profile, "AppData", "Local", name));
      Assert.Equal(physical, selected.DirectoryPath); Assert.Equal(logical.NamespaceId, selected.NamespaceId);
      Assert.Equal(physical, StableChannel.Root(profile).DirectoryPath);
      Assert.Equal(Path.Combine(profile, ".claude"), AccountHomes.Resolve(selected, "claude", AccountHomes.ExistingLogin, profile, true));
      Assert.Throws<ArgumentException>(() => StableChannel.Resolve(Path.Combine(profile, "scratch"), profile));
      Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(selected, "claude", AccountHomes.ExistingLogin, profile, false));
    });
  }

  [Theory]
  [InlineData("TerminalDeck")]
  [InlineData("TerminalDeckStable")]
  public void Only_exact_current_user_package_root_aliases_its_logical_namespace(string name)
  {
    InFixture((profile, cache) =>
    {
      var physical = Path.Combine(cache, "Local", name);
      Assert.Equal(Path.Combine(profile, "AppData", "Local", name), InstalledDataRoot.NamespacePath(physical, profile));
      foreach (var path in new[] { Path.Combine(physical, "scratch"), physical.Replace(InstalledDataRoot.PackageFamilyName, "TerminalDeck_anotherfamily"), physical.Replace(InstalledDataRoot.PackageFamilyName, "OtherApp_6wvt5fg33ztg8"), physical.Replace("profile", "other-user") })
        Assert.Equal(path, InstalledDataRoot.NamespacePath(path, profile));
      Assert.True(InstalledDataRoot.IsInstalledPath(physical, profile));
      Assert.True(InstalledDataRoot.IsInstalledPath(Path.Combine(physical, "scratch"), profile));
      Assert.True(InstalledDataRoot.IsInstalledPath(Path.Combine(profile, "AppData", "Local", name), profile));
      Assert.True(InstalledDataRoot.IsInstalledPath(Path.Combine(profile, "AppData", "Local", name, "scratch"), profile));
    });
  }

  [Fact]
  public void Explicit_uses_current_user_package_namespace_for_all_child_executables()
  {
    var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var physical = Path.Combine(InstalledDataRoot.PackageLocalCache(profile), "Local", "TerminalDeck");
    var logical = Path.Combine(profile, "AppData", "Local", "TerminalDeck");
    Assert.Equal(logical, InstalledDataRoot.NamespacePath(physical, profile));
    Assert.Equal(AppDataRoot.Explicit(logical).NamespaceId, AppDataRoot.Explicit(physical).NamespaceId);
    Assert.NotEqual(AppDataRoot.Explicit(logical).NamespaceId, AppDataRoot.Explicit(Path.Combine(physical, "scratch")).NamespaceId);
    Assert.Equal(physical, AppDataRoot.Explicit(physical).DirectoryPath);
  }

  [Fact]
  public void Cached_legacy_is_used_without_receipt_when_no_stable_state_exists()
  {
    InFixture((profile, cache) =>
    {
      var legacy = Path.Combine(cache, "Local", "TerminalDeck"); Saved(legacy, "accounts");
      Assert.Equal(legacy, StableChannel.Resolve(null, profile, cache).DirectoryPath);
    });
  }

  [Fact]
  public void A_different_family_cannot_supply_a_keeper_root_even_when_it_has_saved_state()
  {
    InFixture((profile, cache) =>
    {
      var other = Path.Combine(cache.Replace(InstalledDataRoot.PackageFamilyName, "TerminalDeck_anotherfamily"), "Local", "TerminalDeck");
      Saved(other, "sessions");
      Assert.Throws<ArgumentException>(() => StableChannel.Resolve(other, profile));
    });
  }

  [Theory]
  [InlineData("scratch")]
  [InlineData("missing")]
  public void Receipt_cannot_choose_an_unrelated_or_missing_data_root(string target)
  {
    InFixture((profile, cache) =>
    {
      var legacy = Path.Combine(cache, "Local", "TerminalDeck"); Saved(legacy, "accounts");
      var destination = target == "scratch" ? Path.Combine(profile, "scratch") : Path.Combine(cache, "Local", "TerminalDeckStable");
      if (target == "scratch") Saved(destination, "accounts");
      Receipt(legacy, destination);
      Assert.Throws<IOException>(() => StableChannel.Resolve(null, profile, cache));
    });
  }

  [Fact]
  public void Receipt_from_another_machine_does_not_override_existing_stable_state()
  {
    InFixture((profile, cache) =>
    {
      var legacy = Path.Combine(cache, "Local", "TerminalDeck"); Saved(legacy, "accounts");
      var stable = Path.Combine(profile, "AppData", "Local", "TerminalDeckStable"); Saved(stable, "accounts");
      File.WriteAllText(Path.Combine(legacy, "installed-data-root.json"), JsonSerializer.Serialize(new InstalledDataRoot("another-" + Environment.MachineName, legacy)));
      Assert.Equal(stable, StableChannel.Resolve(null, profile, cache).DirectoryPath);
    });
  }

  [Fact]
  public async Task Legacy_namespace_keeps_named_accounts_and_default_without_adding_ambient_login()
  {
    var profile = Path.Combine(Path.GetTempPath(), "deck-default-policy-" + Guid.NewGuid().ToString("N"));
    var root = AppDataRoot.Explicit(Path.Combine(InstalledDataRoot.PackageLocalCache(profile), "Local", "TerminalDeck"));
    var service = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    var primary = await service.CreateAsync("claude", "Personal"); var alternate = await service.CreateAsync("claude", "Work");
    await service.SetDefaultAsync("claude", primary.Id);
    var before = service.List().ToArray();
    await service.EnsureDefaultAsync("claude", !StableChannel.IsLegacyRoot(root, profile));
    Assert.Equal(before, service.List()); Assert.Equal(primary.Id, service.Default("claude")!.Id);
    Assert.Equal(alternate.HomeId, service.Get(alternate.Id).HomeId); Assert.DoesNotContain(service.List(), a => a.HomeId == AccountHomes.ExistingLogin);
  }

  private static void Receipt(string folder, string destination) => File.WriteAllText(Path.Combine(folder, "installed-data-root.json"), JsonSerializer.Serialize(new InstalledDataRoot(Environment.MachineName, destination)));

  private static void Saved(string root, string name)
  {
    Directory.CreateDirectory(Path.Combine(root, "state"));
    File.WriteAllText(Path.Combine(root, "state", name + ".json"), "{}");
  }
  private static void InFixture(Action<string, string> run)
  {
    var folder = Path.Combine(Path.GetTempPath(), "deck-installed-root-" + Guid.NewGuid().ToString("N"));
    var profile = Path.Combine(folder, "profile");
    try { run(profile, InstalledDataRoot.PackageLocalCache(profile)); }
    finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
  }
}
