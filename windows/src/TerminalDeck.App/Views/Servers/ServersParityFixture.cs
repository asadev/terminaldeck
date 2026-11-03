using System.Text;
using TerminalDeck.App.ViewModels.Servers;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.App.Views.Servers;

// Opt-in appearance proof only. Every fixture request stays in memory; writes
// are refused so preview controls can never reach SSH, credentials or sessions.
internal static class ServersParityFixture
{
  internal static ServersPage Create(string section = "Directory", nint windowHandle = 0)
  {
    var model = new ServersViewModel(new FixtureServers());
    model.Refresh();
    var settings = section.StartsWith("Settings-", StringComparison.Ordinal);
    if (section != "Directory")
    {
      model.Select("parity-primary"); model.Tab(settings ? section[9..] : section);
      if (section == "Apps") model.LoadAppsAsync().GetAwaiter().GetResult();
      if (section == "Health") model.LoadHealthAsync().GetAwaiter().GetResult();
      if (section == "Files") model.LoadFilesAsync().GetAwaiter().GetResult();
      if (section == "Coding AIs") model.LoadCodingAisAsync().GetAwaiter().GetResult();
      if (section == "Websites") model.LoadWebsitesAsync().GetAwaiter().GetResult();
      if (settings) model.LoadSettingsAsync().GetAwaiter().GetResult();
    }
    var page = new ServersPage(model, new FixtureHost(windowHandle), settingsWindow: settings);
    if (settings) { page.MaxWidth = 560; page.HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Center; }
    return page;
  }
  private sealed class FixtureHost(nint windowHandle) : IServerPageHost
  {
    public nint WindowHandle => windowHandle;
    public IReadOnlyList<ServerAiAppChoice> AiApps => [new("parity-hoot", "Hoot")];
    public void OpenSession(string id) => throw new ServerRefusal("Appearance fixture cannot open real sessions.");
    public Task OpenWebsiteAsync(string url) => throw new ServerRefusal("Appearance fixture cannot open external websites.");
  }
  private sealed class FixtureServers : IServers
  {
    private readonly SavedServer[] rows =
    [
      new("parity-primary", "Production", "production.example.test", 22, "deploy", ServerAuthentication.Key, new(false, ["/srv/apps"], [])),
      new("parity-staging", "Staging", "staging.example.test", 22, "deploy", ServerAuthentication.Key, new(true, ["/srv/apps"], [])),
      new("parity-backups", "Backups", "backup.example.test", 2222, "backup", ServerAuthentication.Key, new(true, ["/srv/backups"], []))
    ];
    public IReadOnlyList<SavedServer> List(ServerCaller caller) => rows;
    public SavedServer Get(string id, ServerCaller caller) => rows.Single(row => row.Id == id);
    public ValueTask<ServerFilePage> FilesAsync(string id, string path, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult(new ServerFilePage(path,
    [
      new("assets", path + "/assets", "folder", 0, 0),
      new("deploy", path + "/deploy", "folder", 0, 0),
      new("compose.yaml", path + "/compose.yaml", "file", 2480, 0),
      new("README.md", path + "/README.md", "file", 1640, 0),
      new("service.log", path + "/service.log", "file", 38720, 0)
    ], false));
    public ValueTask<ServerFileContent> ReadAsync(string id, string path, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult(new ServerFileContent(path, Convert.ToBase64String(Encoding.UTF8.GetBytes("# Deployment\n\nAppearance fixture. No server connected.\n")), false));
    public ValueTask<IReadOnlyList<ServerApp>> AppsAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult<IReadOnlyList<ServerApp>>(
    [
      new("parity-web", "Web", "example/web:stable", "running", "Up 3 days", "127.0.0.1:8080 → 80/tcp"),
      new("parity-api", "API", "example/api:stable", "running", "Up 3 days", "127.0.0.1:3000 → 3000/tcp"),
      new("parity-worker", "Worker", "example/worker:stable", "exited", "Exited 2 hours ago", "")
    ]);
    public ValueTask<ServerHealth> HealthAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult(new ServerHealth(27, 4L * 1024 * 1024 * 1024, 16L * 1024 * 1024 * 1024, 40L * 1024 * 1024 * 1024, 100L * 1024 * 1024 * 1024, 1.1, .8, .7, 8, DateTimeOffset.UtcNow));
    public ValueTask<IReadOnlyList<ServerCodingAi>> CodingAisAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult<IReadOnlyList<ServerCodingAi>>(
    [
      new("claude", "Claude Code", true, "/home/deploy/.local/bin/claude", "2.1.0", "yes", false, null, false),
      new("codex", "Codex", true, "/home/deploy/.local/bin/codex", "0.99.0", "no", false, null, true),
      new("gemini", "Gemini", false, "", "", "unknown", true, "Install for this SSH user. Sign-in stays on the server.", false, true, false)
    ]);
    public ValueTask<IReadOnlyList<ServerWebsite>> WebsitesAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult<IReadOnlyList<ServerWebsite>>(
    [
      new("site:www.example.test", "www.example.test", "nginx · HTTPS", "https://www.example.test/"),
      new("site:api.example.test", "api.example.test", "nginx · HTTPS", "https://api.example.test/"),
      new("site:*.preview.example.test", "*.preview.example.test", "Wildcard configuration", null)
    ]);
    public ValueTask<ServerCodingAiAction> ChangeCodingAiAsync(string id, string provider, string action, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<ServerWebsite> WebsiteAsync(string id, string siteId, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<ServerSettingsSnapshot> SettingsAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult(new ServerSettingsSnapshot(Get(id, caller),
      new(true, true, true, "28.0.0", "production", "0.20.3", "0.20.3", "Caddy manages app addresses", ["Alert watcher on", "Checks every 5 minutes", "Cleanup scheduled", "Deploy endpoint ready"]),
      new(true, [new("parity-telegram", "telegram", "Team alerts") { BotToken = ServerSettingsRules.SecretMask, ChatId = "123456" }]),
      [new(1, "warning", "App restarted", "Web restarted after an update.", "Web", DateTimeOffset.UtcNow.AddHours(-1), [new("Team alerts", true)])], ["Web", "API", "Worker"]));
    public ValueTask SaveSettingsAsync(string id, ServerSettingsPatch patch, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<ServerHostingStatus> HostingAsync(string id, string action, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask SaveAlertsAsync(string id, ServerAlertSettings settings, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<ServerAlertDelivery[]> TestAlertsAsync(string id, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<string> OpenTerminalAtAsync(string id, string? folder, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<string> LogsAsync(string id, string appId, int lines, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult("Appearance fixture. No server connected.");
    public ValueTask<string> TestAsync(string id, ServerCaller caller, CancellationToken ct = default) => ValueTask.FromResult("Appearance fixture. No server connected.");
    private static ServerRefusal Refused() => new("Appearance fixture refuses changes and external requests.");
    public ValueTask<SavedServer> AddAsync(ServerDraft draft, string? pickedKey, ReadOnlyMemory<byte> password, CancellationToken ct = default, ServerCaller? caller = null) => throw Refused();
    public ValueTask SetAccessAsync(string id, ServerAccess access, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask RemoveAsync(string id, string confirmName, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<string> ScanHostKeyAsync(string id, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask TrustHostKeyAsync(string id, string key, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask UploadAsync(string id, string path, ReadOnlyMemory<byte> bytes, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask DownloadAsync(string id, string path, string localPath, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask ChangeFileAsync(string id, string path, string operation, string? name, string? confirmName, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask ControlAsync(string id, string appId, string action, ServerCaller caller, CancellationToken ct = default) => throw Refused();
    public ValueTask<string> OpenTerminalAsync(string id, ServerCaller caller, CancellationToken ct = default) => throw Refused();
  }
}
