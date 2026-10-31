using System.Text;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.App.ViewModels.Servers;

public sealed class ServersViewModel(IServers servers)
{
  public IServers Servers { get; } = servers;
  public SavedServer[] Rows { get; private set; } = [];
  public SavedServer? Selected => Rows.SingleOrDefault(s => s.Id == SelectedId);
  public string? SelectedId { get; private set; }
  public string Section { get; private set; } = "Apps";
  public string Folder { get; set; } = "";
  public ServerFilePage? Files { get; private set; }
  public IReadOnlyList<ServerApp>? Apps { get; private set; }
  public ServerHealth? Health { get; private set; }
  public string Preview { get; private set; } = "";
  public bool IsBusy { get; private set; }
  public bool IsError { get; private set; }
  public string Message { get; private set; } = "";
  private readonly Stack<string> folderHistory = new();
  public bool CanGoBack => folderHistory.Count > 0;
  public string? PreviewPath { get; private set; }
  public string? LogsAppId { get; private set; }
  private int logLines = 200;
  public void ClosePreview() { Preview = ""; PreviewPath = null; LogsAppId = null; Changed?.Invoke(); }
  public event Action? Changed;
  public void Refresh()
  {
    try { Rows = Servers.List(ServerCaller.Person).ToArray(); }
    catch (Exception ex) when (ex is IOException or ServerRefusal or System.Text.Json.JsonException)
    { IsError = true; Message = "The saved server list could not be opened. Check this app's data folder."; }
    Changed?.Invoke();
  }
  public void Select(string? id)
  {
    folderHistory.Clear(); PreviewPath = null; LogsAppId = null; SelectedId = id; Health = null; Files = null; Apps = null; Preview = ""; Message = ""; Section = "Apps";
    Refresh(); Folder = Selected?.Access.Folders.FirstOrDefault() ?? ""; Changed?.Invoke();
  }
  public void Tab(string name) { Section = name; PreviewPath = null; LogsAppId = null; Preview = ""; Changed?.Invoke(); }
  public async Task<bool> RunAsync(Func<Task> action, string pending = "Working…", string success = "Done.")
  {
    if (IsBusy) return false;
    IsBusy = true; IsError = false; Message = pending; Changed?.Invoke();
    try { await action(); Message = success; return true; }
    catch (OperationCanceledException) { Message = "Cancelled."; return false; }
    catch (Exception ex) when (ex is ServerRefusal or IOException or ArgumentException or UnauthorizedAccessException or FormatException or System.Text.Json.JsonException)
    { Message = ex is ServerRefusal ? ex.Message : "This request could not finish. Check the connection, folder and server tools, then try again."; IsError = true; return false; }
    finally { IsBusy = false; Refresh(); }
  }
  public Task<bool> LoadFilesAsync(string? path = null) => NavigateAsync(path ?? Folder, false);
  public Task<bool> BackAsync() => folderHistory.TryPeek(out var path) ? NavigateAsync(path, true) : Task.FromResult(false);
  public Task<bool> RefreshFilesAsync() => NavigateAsync(Files?.Path ?? Folder, false);
  private Task<bool> NavigateAsync(string folder, bool back) => RunAsync(async () =>
  {
    var id = Selected?.Id ?? throw new ServerRefusal("Choose a server.");
    var next = await Servers.FilesAsync(id, folder, ServerCaller.Person);
    if (back) folderHistory.Pop();
    else if (Files is { } prior && prior.Path != next.Path) folderHistory.Push(prior.Path);
    Files = next; Folder = next.Path; Preview = ""; PreviewPath = null; LogsAppId = null;
  }, "Opening folder…", "Folder opened.");
  public Task<bool> MoreFilesAsync() => RunAsync(async () =>
  {
    if (Selected is not { } selected || Files is not { More: true } current) throw new ServerRefusal("Open a folder with more files.");
    var next = await Servers.FilesPageAsync(selected.Id, current.Path, current.Entries.Length, ServerCaller.Person);
    Files = next with { Offset = 0, Entries = current.Entries.Concat(next.Entries).DistinctBy(f => f.Path).ToArray() };
  }, "Reading more files…", "More files opened.");
  public Task<bool> LoadHealthAsync() => RunAsync(async () => { Health = await Servers.HealthAsync(Selected!.Id, ServerCaller.Person); }, "Checking server health…", "Health checked.");
  public Task<bool> LoadAppsAsync() => RunAsync(async () =>
  { Apps = await Servers.AppsAsync(Selected!.Id, ServerCaller.Person); }, "Reading apps…", "Apps refreshed.");
  public Task<bool> ReadAsync(ServerFile file) => RunAsync(async () =>
  {
    var read = await Servers.ReadAsync(Selected!.Id, file.Path, ServerCaller.Person);
    var bytes = Convert.FromBase64String(read.Base64);
    PreviewPath = file.Path; LogsAppId = null;
    Preview = bytes.Contains((byte)0) ? "This is a binary file. Use Download to save it." : ServerText.Mask(Encoding.UTF8.GetString(bytes)) + (read.Truncated ? "\n\nPreview ends at 256 KB." : "");
  }, "Opening file…", "Preview opened.");
  public Task<bool> LogsAsync(ServerApp app) => RunAsync(async () =>
  { logLines = LogsAppId == app.Id ? Math.Min(2000, logLines + 200) : 200; Preview = await Servers.LogsAsync(Selected!.Id, app.Id, logLines, ServerCaller.Person); PreviewPath = null; LogsAppId = app.Id; }, "Reading recent logs…", "Recent logs opened.");
}
