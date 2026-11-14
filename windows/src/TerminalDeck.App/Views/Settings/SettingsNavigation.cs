namespace TerminalDeck.App.Views.Settings;

public sealed record SettingsCategory(string Id, string Title, string Glyph, string ColorResource, int Group, string Keywords);

public static class SettingsNavigation
{
  // Keep stable route ids and the Mac's order (14 Nov): Profile and Devices first, in a group of their own; then
  // General, Cloud and the rest. Windows has no island, voice or plugins page.
  public static IReadOnlyList<SettingsCategory> Categories { get; } = [
    new("profile", "Profile", "\uE77B", "DeckProjectBlueBrush", 0, "account name picture photo e-mail email sign in out ways github google apple"),
    new("devices", "Devices", "\uE8EA", "DeckProjectTealBrush", 0, "devices phones computers this pc sign out pairing paired"),
    new("general", "General", "\uE713", "DeckProjectGraphiteBrush", 1, "sessions restart reconnect name copy select awake sleep updates version opens new session"),
    new("cloud", "Cloud", "\uE753", "DeckProjectBlueBrush", 1, "cloud account sign in out e-mail email sync trust terminal deck"),
    new("appearance", "Appearance", "\uE793", "DeckProjectGraphiteBrush", 1, "theme light dark system"),
    new("notifications", "Notifications", "\uE7F4", "SystemFillColorCriticalBrush", 1, "approvals mentions windows alerts"),
    new("coding-ais", "Coding AIs", "\uE756", "SystemFillColorAttentionBrush", 2, "accounts who uses what sign in models"),
    new("outside-ai-apps", "Outside AI apps", "link", "DeckOutsideAIAppsBrush", 2, "mcp servers connections tools"),
    new("agent-defaults", "Agents", "agent-defaults", "DeckProjectGreenBrush", 2, "templates instructions hands helper memory defaults"),
    new("browser", "Browser", "\uE774", "DeckProjectTealBrush", 3, "pages profiles sign-ins cookies start page"),
    new("tasks", "Tasks", "checklist", "DeckProjectOrangeBrush", 3, "connected task systems crm agents"),
    new("advanced", "Advanced", "\uE945", "TextFillColorSecondaryBrush", 4, "privacy access diagnostics"),
    new("about", "About", "\uE946", "TextFillColorSecondaryBrush", 4, "version help shortcuts")
  ];

  public static IEnumerable<SettingsCategory> Matching(string query) => Categories.Where(item =>
    (item.Title + " " + item.Keywords).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase));

  public static bool IsHoot(string section) => section is "hoot" or "copilot";

  public static string Canonical(string section) => section switch
  {
    "agents" => "agent-defaults",
    "power" => "general",
    "scraping" => "browser",
    "accounts" or "coding-ais" => "coding-ais",
    "hoot" or "copilot" => "hoot",
    "mcp" => "outside-ai-apps",
    _ when Categories.Any(item => item.Id == section) => section,
    _ => throw new ArgumentException("Choose an available Settings category.")
  };
}
