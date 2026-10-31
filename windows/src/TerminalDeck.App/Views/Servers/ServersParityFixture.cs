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
    if (section != "Directory")
    {
      model.Select("parity-primary"); model.Tab(section);
      if (section == "Apps") model.LoadAppsAsync().GetAwaiter().GetResult();
      if (section == "Health") model.LoadHealthAsync().GetAwaiter().GetResult();
      if (section == "Files") model.LoadFilesAsync().GetAwaiter().GetResult();
    }
    return new ServersPage(model, new FixtureHost(windowHandle));
  }
  private sealed class FixtureHost(nint windowHandle) : IServerPageHost
  {
    public nint WindowHandle => windowHandle;
    public IReadOnlyList<ServerAiAppChoice> AiApps => [new("parity-hoot", "Hoot")];
    public void OpenSession(string id) => throw new ServerRefusal("Appearance fixture cannot open real sessions.");
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
