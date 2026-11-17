using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class LegacyPackageAccountHomesTests
{
  private const string HomeId = "1234567890abcdef1234567890abcdef";

  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public void Installed_legacy_package_uses_original_external_cli_home_and_keeps_app_state_physical(string provider)
  {
    InLegacy((profile, root) =>
    {
      var physical = root.DirectoryPath;
      var expected = Path.Combine(profile, "AppData", "Local", "TerminalDeck", "accounts", HomeId, provider);
      Assert.Equal(expected, AccountHomes.Resolve(root, provider, HomeId, profile, true));
      Assert.Equal(physical, root.DirectoryPath);
      Assert.Equal(AppDataRoot.Explicit(Path.Combine(profile, "AppData", "Local", "TerminalDeck")).NamespaceId, root.NamespaceId);
      var environment = AccountEnvironment.Apply(provider, AccountHomes.Resolve(root, provider, HomeId, profile, true), new Dictionary<string, string> { ["ANTHROPIC_API_KEY"] = "synthetic-test-value", ["CLAUDE_CONFIG_DIR"] = "wrong-home" });
      Assert.Equal(expected, environment[provider switch { "claude" => "CLAUDE_CONFIG_DIR", "codex" => "CODEX_HOME", _ => "GEMINI_CLI_HOME" }]);
      Assert.False(environment.ContainsKey("ANTHROPIC_API_KEY"));
    });
  }

  [Fact]
  public void Empty_physical_directories_and_missing_logical_directories_never_change_home_selection()
  {
    InLegacy((profile, root) =>
    {
      var expected = Path.Combine(profile, "AppData", "Local", "TerminalDeck", "accounts", HomeId, "claude");
      var physicalHome = Path.Combine(root.DirectoryPath, "accounts", HomeId, "claude");
      Directory.CreateDirectory(physicalHome);
      Assert.False(Directory.Exists(expected));
      Assert.Equal(expected, AccountHomes.Resolve(root, "claude", HomeId, profile, true));
      Directory.CreateDirectory(expected);
      Assert.Equal(expected, AccountHomes.Resolve(root, "claude", HomeId, profile, true));
      Directory.Delete(expected);
      Assert.Equal(expected, AccountHomes.Resolve(root, "claude", HomeId, profile, true));
    });
  }

  [Fact]
  public void Scratch_and_unmarked_copies_keep_their_own_private_homes()
  {
    InLegacy((profile, root) =>
    {
      var scratch = AppDataRoot.Explicit(Path.Combine(root.DirectoryPath, "scratch"));
      Assert.Equal(Path.Combine(scratch.DirectoryPath, "accounts", HomeId, "claude"), AccountHomes.Resolve(scratch, "claude", HomeId, profile, true));
      Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", HomeId, "claude"), AccountHomes.Resolve(root, "claude", HomeId, profile, false));
      Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(scratch, "claude", AccountHomes.ExistingLogin, profile, true));
    });
  }

  [Fact]
  public void Cached_stable_install_keeps_its_existing_physical_cli_home()
  {
    InFixture(profile =>
    {
      var cached = Path.Combine(InstalledDataRoot.PackageLocalCache(profile), "Local", "TerminalDeckStable");
      Saved(cached);
      var root = StableChannel.Resolve(cached, profile);
      Assert.Equal(Path.Combine(cached, "accounts", HomeId, "claude"), AccountHomes.Resolve(root, "claude", HomeId, profile, true));
    });
  }

  [Fact]
  public void Refresh_lock_checks_follow_the_same_original_claude_home()
  {
    InLegacy((profile, root) =>
    {
      var account = new AccountProfile(HomeId, "claude", "Personal", null, AccountAuthentication.Subscription, true, HomeId);
      var expected = Path.Combine(profile, "AppData", "Local", "TerminalDeck", "accounts", HomeId, "claude");
      Assert.Contains(expected, SignInRenewal.ClaudeFolders(root, [account], profile, true));
      Assert.DoesNotContain(Path.Combine(root.DirectoryPath, "accounts", HomeId, "claude"), SignInRenewal.ClaudeFolders(root, [account], profile, true));
    });
  }

  private static void InLegacy(Action<string, AppDataRoot> run) => InFixture(profile =>
  {
    var physical = Path.Combine(InstalledDataRoot.PackageLocalCache(profile), "Local", "TerminalDeck");
    Saved(physical);
    run(profile, StableChannel.Resolve(physical, profile));
  });

  private static void Saved(string root)
  {
    Directory.CreateDirectory(Path.Combine(root, "state"));
    File.WriteAllText(Path.Combine(root, "state", "projects.json"), "{}");
  }

  private static void InFixture(Action<string> run)
  {
    var folder = Path.Combine(Path.GetTempPath(), "deck-legacy-cli-home-" + Guid.NewGuid().ToString("N"));
    try { run(Path.Combine(folder, "profile")); }
    finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
  }
}
