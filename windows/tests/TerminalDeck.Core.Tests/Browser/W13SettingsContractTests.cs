using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class W13SettingsContractTests
{
  [Fact]
  public void CategoriesFollowMacGroupsWithoutUnsupportedPages()
  {
    // Mac, 15 Nov: [profile] · General, Appearance, Notifications · Coding AIs, Agents, Tasks, AI apps · Privacy, Advanced, About.
    Assert.Equal(new[] { "profile", "general", "appearance", "notifications", "coding-ais", "agent-defaults", "tasks", "outside-ai-apps", "privacy", "advanced", "about" }, SettingsNavigation.Categories.Select(c => c.Id));
    Assert.Equal(new[] { 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3 }, SettingsNavigation.Categories.Select(c => c.Group));
    Assert.Equal("AI apps", SettingsNavigation.Categories.Single(c => c.Id == "outside-ai-apps").Title);
  }
  [Theory]
  [InlineData("accounts", "coding-ais")]
  [InlineData("agents", "agent-defaults")]
  [InlineData("devices", "profile")]
  [InlineData("cloud", "cloud")]
  [InlineData("device:abc", "device:abc")]
  [InlineData("profile", "profile")]
  [InlineData("mcp", "outside-ai-apps")]
  public void LegacyRoutesSelectTheOwningCategory(string route, string selected) => Assert.Equal(selected, SettingsNavigation.Canonical(route));

  [Fact]
  public void SearchFindsOptionsAndHasAnHonestEmptyState()
  {
    Assert.Equal("appearance", Assert.Single(SettingsNavigation.Matching(" THEME ")).Id);
    // The Browser's settings open from the Browser itself, not from this list.
    Assert.Empty(SettingsNavigation.Matching("cookies"));
    Assert.True(SettingsNavigation.IsBrowser("browser"));
    Assert.Equal("advanced", Assert.Single(SettingsNavigation.Matching("paired")).Id);
    Assert.Empty(SettingsNavigation.Matching("zz-not-a-setting"));
  }
}
