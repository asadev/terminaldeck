using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class W13SettingsContractTests
{
  [Fact]
  public void CategoriesFollowMacGroupsWithoutUnsupportedPages()
  {
    Assert.Equal(new[] { "general", "appearance", "notifications", "coding-ais", "outside-ai-apps", "agent-defaults", "browser", "tasks", "advanced", "about" }, SettingsNavigation.Categories.Select(c => c.Id));
    Assert.Equal(new[] { 0, 0, 0, 1, 1, 1, 2, 2, 3, 3 }, SettingsNavigation.Categories.Select(c => c.Group));
  }
  [Theory]
  [InlineData("accounts", "coding-ais")]
  [InlineData("agents", "agent-defaults")]
  [InlineData("devices", "advanced")]
  [InlineData("mcp", "outside-ai-apps")]
  public void LegacyRoutesSelectTheOwningCategory(string route, string selected) => Assert.Equal(selected, SettingsNavigation.Canonical(route));

  [Fact]
  public void SearchFindsOptionsAndHasAnHonestEmptyState()
  {
    Assert.Equal("appearance", Assert.Single(SettingsNavigation.Matching(" THEME ")).Id);
    Assert.Equal("browser", Assert.Single(SettingsNavigation.Matching("cookies")).Id);
    Assert.Empty(SettingsNavigation.Matching("zz-not-a-setting"));
  }
}
