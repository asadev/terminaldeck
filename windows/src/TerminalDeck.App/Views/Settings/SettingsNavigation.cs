namespace TerminalDeck.App.Views.Settings;

public sealed record SettingsCategory(string Id, string Title, string Glyph, string ColorResource, int Group, string Keywords);

public static class SettingsNavigation
{
  // Keep stable route ids and the Mac category groups. Windows has no island, voice or plugins page.
  public static IReadOnlyList<SettingsCategory> Categories { get; } = [
    new("general", "General", "\uE713", "DeckProjectGraphiteBrush", 0, "sessions restart reconnect name copy select awake sleep updates version"),
    new("cloud", "Cloud", "\uE753", "DeckProjectBlueBrush", 0, "cloud account sign in out e-mail email devices terminal deck"),
    new("appearance", "Appearance", "\uE793", "DeckProjectGraphiteBrush", 0, "theme light dark system"),
    new("notifications", "Notifications", "\uE7F4", "SystemFillColorCriticalBrush", 0, "approvals mentions windows alerts"),
    new("coding-ais", "Coding AIs", "\uE756", "SystemFillColorAttentionBrush", 1, "accounts who uses what sign in models"),
    new("outside-ai-apps", "Outside AI apps", "link", "DeckOutsideAIAppsBrush", 1, "mcp servers connections tools"),
    new("agent-defaults", "Agents", "agent-defaults", "DeckProjectGreenBrush", 1, "templates instructions hands helper memory defaults"),
    new("browser", "Browser", "\uE774", "DeckProjectTealBrush", 2, "pages profiles sign-ins cookies start page"),
    new("tasks", "Tasks", "checklist", "DeckProjectOrangeBrush", 2, "connected task systems crm agents"),
    new("advanced", "Advanced", "\uE945", "TextFillColorSecondaryBrush", 3, "devices pairing privacy access phones"),
    new("about", "About", "\uE946", "TextFillColorSecondaryBrush", 3, "version help shortcuts")
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
    "devices" => "advanced",
    "mcp" => "outside-ai-apps",
    _ when Categories.Any(item => item.Id == section) => section,
    _ => throw new ArgumentException("Choose an available Settings category.")
  };
}
