namespace TerminalDeck.App.Views.Settings;

public sealed record SettingsCategory(string Id, string Title, string Glyph, string ColorResource, int Group, string Keywords);

public static class SettingsNavigation
{
  // Keep stable route ids and the Mac's order (15 Nov): [Profile] · General, Appearance, Notifications · Coding AIs,
  // Agents, Tasks, AI apps · Privacy, Advanced, About. Devices and Cloud live inside Profile; Browser opens from the
  // Browser itself. Windows has no island, voice or plugins page.
  public static IReadOnlyList<SettingsCategory> Categories { get; } = [
    new("profile", "Profile", "", "DeckProjectBlueBrush", 0, "account name picture photo e-mail email sign in out ways github google apple cloud sync devices phones computers this pc"),
    new("general", "General", "", "DeckProjectGraphiteBrush", 1, "sessions restart reconnect name copy select awake sleep updates version opens new session terminal text size font"),
    new("appearance", "Appearance", "", "DeckProjectGraphiteBrush", 1, "theme light dark system match windows"),
    new("notifications", "Notifications", "", "SystemFillColorCriticalBrush", 1, "finishes sound test alerts"),
    new("coding-ais", "Coding AIs", "", "SystemFillColorAttentionBrush", 2, "accounts who uses what sign in models"),
    new("agent-defaults", "Agents", "agent-defaults", "DeckProjectGreenBrush", 2, "templates instructions hands helper memory defaults budgets behaviour"),
    new("tasks", "Tasks", "checklist", "DeckProjectOrangeBrush", 2, "connected task systems crm agents"),
    new("outside-ai-apps", "AI apps", "link", "DeckOutsideAIAppsBrush", 2, "mcp servers connections tools keys"),
    new("privacy", "Privacy", "", "DeckProjectBlueBrush", 3, "permissions this pc allowed notifications"),
    new("advanced", "Advanced", "", "TextFillColorSecondaryBrush", 3, "debug logs pairing paired phones access reset diagnostics"),
    new("about", "About", "", "TextFillColorSecondaryBrush", 3, "version help")
  ];

  // Pages opened from a row inside another page (Profile); never listed on their own.
  public static IReadOnlyList<SettingsCategory> InnerPages { get; } = [
    new("cloud", "Cloud", "", "DeckProjectBlueBrush", 0, "cloud sync"),
    new("personal", "Personal information", "", "DeckProjectGraphiteBrush", 0, "name e-mail"),
    new("sign-in", "Sign-in", "", "DeckProjectGraphiteBrush", 0, "google github apple sign out"),
    new("custom-clis", "Custom terminal CLIs", "\uE756", "SystemFillColorAttentionBrush", 2, "custom terminal cli")
  ];

  // The list row an inner page lights (a second page keeps its owner selected).
  private static readonly Dictionary<string, string> Owners = new(StringComparer.Ordinal)
  {
    ["cloud"] = "profile", ["personal"] = "profile", ["sign-in"] = "profile", ["custom-clis"] = "coding-ais"
  };

  // One device's own page: "device:" + the device's id (the id is a route only, never drawn).
  public const string DevicePrefix = "device:";

  public static IEnumerable<SettingsCategory> Matching(string query) => Categories.Where(item =>
    (item.Title + " " + item.Keywords).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase));

  public static bool IsHoot(string section) => section is "hoot" or "copilot";

  // The Browser's settings open in their own small window from the Browser (Mac, 15 Nov), not in this list.
  public static bool IsBrowser(string section) => section is "browser" or "scraping";

  public static bool IsDevice(string section) => section.StartsWith(DevicePrefix, StringComparison.Ordinal) && section.Length > DevicePrefix.Length;

  // The list row lit for a page: a page inside Profile lights Profile.
  public static string ListOwner(string id) => Categories.Any(item => item.Id == id) ? id : Owners.TryGetValue(id, out var owner) ? owner : "profile";

  // The page's name in the top bar (a device's page names itself). A second page that shares its owner's
  // category ("accounts", "mcp-servers") has its own name.
  public static string Title(string id) => id switch
  {
    "accounts" => "Which account agents use",
    "mcp" or "mcp-servers" => "MCP servers",
    _ => Categories.Concat(InnerPages).FirstOrDefault(item => item.Id == id)?.Title ?? (IsDevice(id) ? "Device" : "Settings")
  };

  public static string Canonical(string section) => section switch
  {
    "agents" => "agent-defaults",
    "power" => "general",
    "accounts" or "coding-ais" => "coding-ais",
    "hoot" or "copilot" => "hoot",
    "mcp" or "mcp-servers" => "outside-ai-apps",
    "devices" or "devices.older" => "profile",
    _ when IsDevice(section) => section,
    _ when Categories.Any(item => item.Id == section) || InnerPages.Any(item => item.Id == section) => section,
    _ => throw new ArgumentException("Choose an available Settings category.")
  };
}
