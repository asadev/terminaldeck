using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Servers;

public sealed class ServerService(ServerStore store, IServerRuntime runtime, IServerAuthorizer? authorizer = null, IServerTerminal? terminal = null) : IServers
{
  private readonly IServerAuthorizer approvals = authorizer ?? new DenyServerChanges();
  private readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new();
  public IReadOnlyList<SavedServer> List(ServerCaller caller) => store.List().Where(s => Visible(s, caller)).ToArray();
  public SavedServer Get(string id, ServerCaller caller) { var s = store.Get(id); ServerValidation.CanRead(s, caller); return s; }
  private static bool Visible(SavedServer s, ServerCaller c) { try { ServerValidation.CanRead(s, c); return true; } catch (ServerRefusal) { return false; } }
  private static void Owner(ServerCaller c) { if ((!c.Owner && !c.ManageServers) || c.PairedDevice) throw new ServerRefusal("Only the owner can change saved servers and access."); }
  public async ValueTask<SavedServer> AddAsync(ServerDraft draft, string? pickedKey, ReadOnlyMemory<byte> password, CancellationToken ct = default, ServerCaller? caller = null)
  {
    caller ??= ServerCaller.Person; Owner(caller);
    ServerValidation.Draft(draft);
    if (draft.Authentication == ServerAuthentication.Key && string.IsNullOrWhiteSpace(pickedKey)) throw new ServerRefusal("Choose a key file explicitly.");
    if (!await approvals.ApproveAsync(caller, new("new", draft.Name, "save server", draft.Host + (pickedKey is null ? "" : "\nKey file: " + pickedKey)), ct)) throw new ServerRefusal("Saving this server was not approved.");
    await caller.RecheckAsync(ct);
    var s = await store.AddAsync(draft, password, ct);
    try { if (pickedKey is not null) { await caller.RecheckAsync(ct); await runtime.ImportKeyAsync(s.Id, pickedKey, ct); } return s; }
    catch { await runtime.RemoveKeyAsync(s.Id, CancellationToken.None); await store.RemoveAsync(s.Id, CancellationToken.None); throw; }
  }
  public async ValueTask SetAccessAsync(string id, ServerAccess access, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); ServerValidation.Access(access);
    await ChangeAsync(id, caller, "change access", JsonSerializer.Serialize(access), true, false, async _ => await store.SetAccessAsync(id, access, ct), ct);
  }
  public async ValueTask RenameAsync(string id, string name, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); var server = Get(id, caller);
    ServerValidation.Draft(new(name, server.Host, server.Port, server.User, server.Authentication, server.ProjectId));
    await ChangeAsync(id, caller, "rename server", name.Trim(), true, false, async _ => await store.RenameAsync(id, name, ct), ct);
  }
  public async ValueTask RemoveAsync(string id, string confirmName, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller); var s = Get(id, caller);
    if (confirmName != s.Name) throw new ServerRefusal("Type the server's exact name to remove it from this app.");
    await ChangeAsync(id, caller, "forget server", s.Name, true, true, async _ =>
    { await runtime.RemoveKeyAsync(id, ct); await store.RemoveAsync(id, ct); }, ct);
  }
  public async ValueTask<string> TestAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    var output = await RunAsync(Get(id, caller), new("printf 'Connected\\n'; uname -s; command -v python3 >/dev/null && printf 'Files ready\\n'; command -v docker >/dev/null && printf 'Docker available\\n'; true"), ct);
    _ = Get(id, caller); return ServerText.Mask(output.Output);
  }
  public async ValueTask<ServerHealth> HealthAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    var server = Get(id, caller); var result = await RunAsync(server, ServerHealthRead.Command, ct); _ = Get(id, caller);
    return ServerResponses.Health(result.Output);
  }
  public ValueTask<string> ScanHostKeyAsync(string id, ServerCaller caller, CancellationToken ct = default) { Owner(caller); return runtime.ScanHostKeyAsync(Get(id, caller), ct); }
  public async ValueTask TrustHostKeyAsync(string id, string key, ServerCaller caller, CancellationToken ct = default)
  {
    Owner(caller);
    await ChangeAsync(id, caller, "trust SSH host key", key, true, false, async s => await runtime.TrustHostKeyAsync(s, key, ct), ct);
  }
  public ValueTask<ServerFilePage> FilesAsync(string id, string path, ServerCaller caller, CancellationToken ct = default) => FilesPageAsync(id, path, 0, caller, ct);
  public async ValueTask<ServerFilePage> FilesPageAsync(string id, string path, int offset, ServerCaller caller, CancellationToken ct = default)
  {
    var s = Get(id, caller); var output = await RunAsync(s, ServerFilesScript.Make(s, "list", path, offset: offset), ct); _ = Get(id, caller);
    return ServerResponses.Files(output.Output, path, offset);
  }
  public async ValueTask<ServerFileContent> ReadAsync(string id, string path, ServerCaller caller, CancellationToken ct = default)
  {
    var s = Get(id, caller); var output = await RunAsync(s, ServerFilesScript.Make(s, "read", path), ct); _ = Get(id, caller);
    return ServerResponses.File(output.Output, path);
  }
  public async ValueTask UploadAsync(string id, string path, ReadOnlyMemory<byte> bytes, ServerCaller caller, CancellationToken ct = default)
  {
    if (bytes.Length > ServerFilesScript.TransferLimit) throw new ServerRefusal("Files can be up to 8 MB.");
    var s = Get(id, caller); var command = ServerFilesScript.Make(s, "upload", path, Convert.ToBase64String(bytes.Span));
    await ChangeAsync(id, caller, "upload file", path, false, false, async current => { _ = await RunAsync(current, command, ct); }, ct);
  }
  public async ValueTask DownloadAsync(string id, string path, string localPath, ServerCaller caller, CancellationToken ct = default)
  {
    if (!System.IO.Path.IsPathFullyQualified(localPath) || File.Exists(localPath) || Directory.Exists(localPath)) throw new ServerRefusal("Choose a new local file name.");
    var s = Get(id, caller); var command = ServerFilesScript.Make(s, "download", path);
    // Download is a local write: Look only still permits reading a server file,
    // while the approval names the exact local destination that will be created.
    await ChangeAsync(id, caller, "download file", path + " → " + localPath, true, false, async current =>
    {
      var output = await RunAsync(current, command, ct);
      var file = ServerResponses.File(output.Output, path, download: true);
      var bytes = Convert.FromBase64String(file.Base64);
      if (file.Truncated || bytes.Length > ServerFilesScript.TransferLimit) throw new IOException("That file exceeds the transfer limit.");
      await caller.RecheckAsync(ct);
      var temporary = localPath + "." + Guid.NewGuid().ToString("N") + ".partial";
      try
      {
        await using (var destination = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { await destination.WriteAsync(bytes, ct); await destination.FlushAsync(ct); }
        await caller.RecheckAsync(ct); File.Move(temporary, localPath, overwrite: false);
      }
      finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }, ct);
  }
  public async ValueTask ChangeFileAsync(string id, string path, string operation, string? name, string? confirmName, ServerCaller caller, CancellationToken ct = default)
  {
    if (operation is not ("rename" or "delete")) throw new ServerRefusal("Choose rename or delete.");
    if (operation == "delete" && confirmName != path.Split('/').Last()) throw new ServerRefusal("Type the file's exact name to delete it.");
    if (operation == "rename" && name is null) throw new ServerRefusal("Enter the new name.");
    var s = Get(id, caller); var command = ServerFilesScript.Make(s, operation, path, name: name);
    await ChangeAsync(id, caller, operation + " file", path + (name is null ? "" : " → " + name), false, operation == "delete", async current => { _ = await RunAsync(current, command, ct); }, ct);
  }
  public async ValueTask<IReadOnlyList<ServerApp>> AppsAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    var s = Get(id, caller); var output = await RunAsync(s, new("docker ps -a --no-trunc --format '{{json .}}'"), ct); _ = Get(id, caller);
    return ServerResponses.Apps(output.Output);
  }
  public async ValueTask<string> LogsAsync(string id, string appId, int lines, ServerCaller caller, CancellationToken ct = default)
  {
    ServerValidation.Container(appId); if (lines is < 1 or > 2000) throw new ServerRefusal("Choose between 1 and 2000 log lines.");
    if (!(await AppsAsync(id, caller, ct)).Any(a => a.Id == appId)) throw new ServerRefusal("That app is no longer on the server.");
    var output = await RunAsync(Get(id, caller), new($"docker logs --tail {lines} -- {ServerValidation.Quote(appId)} 2>&1"), ct); _ = Get(id, caller); return ServerText.Mask(output.Output);
  }
  public async ValueTask ControlAsync(string id, string appId, string action, ServerCaller caller, CancellationToken ct = default)
  {
    ServerValidation.Container(appId); if (action is not ("start" or "stop" or "restart")) throw new ServerRefusal("Choose start, stop or restart.");
    var s = Get(id, caller); ServerValidation.CanChange(s, caller);
    var app = (await AppsAsync(id, caller, ct)).SingleOrDefault(a => a.Id == appId) ?? throw new ServerRefusal("Refresh Apps and choose a current app.");
    await ChangeAsync(id, caller, action + " app", app.Name + " (" + app.Id + ")", false, false, async current =>
    {
      if (!(await AppsAsync(id, caller, ct)).Any(a => a.Id == app.Id && a.Name == app.Name)) throw new ServerRefusal("That app changed while approval was open. Refresh Apps.");
      await caller.RecheckAsync(ct);
      _ = await RunAsync(current, new("docker " + action + " -- " + ServerValidation.Quote(app.Id)), ct);
    }, ct);
  }
  public async ValueTask<string> OpenTerminalAsync(string id, ServerCaller caller, CancellationToken ct = default)
  {
    if (terminal is null) throw new ServerRefusal("The server session connection has not been connected to this window yet.");
    string? session = null;
    await ChangeAsync(id, caller, "open terminal", "An SSH session can run commands outside the allowed Files folders.", false, false,
      async s => session = await terminal.OpenAsync(new(s), ct), ct);
    return session ?? throw new IOException("The server session did not open.");
  }
  private async ValueTask ChangeAsync(string id, ServerCaller caller, string operation, string target, bool localSetting, bool destructive,
    Func<SavedServer, ValueTask> action, CancellationToken ct)
  {
    var gate = gates.GetOrAdd(id, _ => new(1, 1)); await gate.WaitAsync(ct);
    try
    {
      var before = Get(id, caller); if (!localSetting) ServerValidation.CanChange(before, caller);
      if (caller.PairedDevice) throw new ServerRefusal("Paired devices cannot change a server.");
      if (!await approvals.ApproveAsync(caller, new(id, before.Name, operation, target, destructive), ct)) throw new ServerRefusal("This exact server change was not approved.");
      ct.ThrowIfCancellationRequested(); var current = Get(id, caller);
      if (JsonSerializer.Serialize(before) != JsonSerializer.Serialize(current)) throw new ServerRefusal("The server changed while approval was open. Try again.");
      if (!localSetting) ServerValidation.CanChange(current, caller);
      await caller.RecheckAsync(ct);
      await action(current);
    }
    finally { gate.Release(); }
  }
  private async ValueTask<ServerOutput> RunAsync(SavedServer s, ServerCommand command, CancellationToken ct)
  {
    if (JsonSerializer.Serialize(store.Get(s.Id)) != JsonSerializer.Serialize(s)) throw new ServerRefusal("Server access changed. Try again with the current access.");
    var output = await runtime.RunAsync(s, command, ct);
    if (JsonSerializer.Serialize(store.Get(s.Id)) != JsonSerializer.Serialize(s)) throw new ServerRefusal("Server access changed while the request was running.");
    if (output.ExitCode != 0) throw new IOException("The server could not finish this request. Check its connection and required tools (Python 3 for Files, Docker for Apps).");
    return output;
  }
}
public static partial class ServerText
{
  [GeneratedRegex("""(?im)(["']?(?:password|passwd|secret|token|api[_-]?key|authorization)["']?(?:\s*[:=]\s*|\s+))(?:"[^"\r\n]*"|'[^'\r\n]*'|(?:Bearer|Basic)\s+[^\s,;]+|[^\s,;]+)""")] private static partial Regex Secrets();
  [GeneratedRegex(@"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----")] private static partial Regex Keys();
  [GeneratedRegex(@"(?i)\b(https?://)[^\s/@]+:[^\s/@]+@")] private static partial Regex UrlCredentials();
  public static string Mask(string text) => Secrets().Replace(Keys().Replace(UrlCredentials().Replace(text, "$1[hidden]@"), "[private key hidden]"), "$1[hidden]");
}
