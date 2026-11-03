using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private HootRoutines? phoneRoutines;
  public HootRoutines Routines => phoneRoutines ??= new(new JsonStateStore<HootRoutineState>(Root, "hoot-routines"), DispatchRoutineAsync);
  private ValueTask<JsonObject> PhoneRoutinesAsync(ApprovedDevice device, string type, JsonElement message, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested(); var host = new PhoneSessionsHost(this);
    var rows = Routines.List().Where(r => device.Access == PhoneAccess.Full || host.MayStartIn(device, r.Folder)).ToArray();
    if (type == "routine.text")
    {
      var id = PhoneText(message, "id")!; var routine = rows.FirstOrDefault(r => r.Id == id) ?? throw new PhoneRefusal("unauthorized", "That routine is no longer shared.");
      return ValueTask.FromResult(new JsonObject { ["t"] = "routine.text.rows", ["id"] = id, ["file"] = routine.Name + ".md", ["text"] = routine.Text,
        ["truncated"] = false, ["readOnlyBecause"] = "Manage routines on this computer or through its approved app tools." });
    }
    return ValueTask.FromResult(new JsonObject { ["t"] = "routines.rows", ["routines"] = new JsonArray(rows.Take(100).Select(r => (JsonNode)new JsonObject
    { ["id"] = r.Id, ["name"] = r.Name, ["purpose"] = r.Purpose, ["schedule"] = r.Triggers.Length == 0 ? "Every " + r.EveryMinutes + " minutes" : string.Join(" · ", r.Triggers), ["folder"] = r.Folder,
      ["state"] = r.RecoveryHold ? "blocked" : r.Enabled ? "armed" : "unarmed", ["enabled"] = r.Enabled, ["paused"] = r.RecoveryHold, ["nextAt"] = r.NextAt?.ToUnixTimeMilliseconds(),
      ["lastAt"] = r.LastAt?.ToUnixTimeMilliseconds(), ["lastOutcome"] = r.LastOutcome, ["problem"] = r.Problem }).ToArray()) });
  }
  private async ValueTask<JsonObject> PhoneDevAsync(ApprovedDevice device, string type, JsonElement request, CancellationToken ct)
  {
    var host = new PhoneSessionsHost(this); var folder = PhoneWorkspacePaths.Require(PhoneText(request, "folder")!, host.Folders(device), device.Access == PhoneAccess.Full);
    var packagePath = Path.Combine(folder, "package.json");
    var report = new JsonObject { ["folder"] = folder, ["status"] = "unavailable" };
    if (!File.Exists(packagePath) || new FileInfo(packagePath).Length > 1024 * 1024) { report["message"] = "This folder has no readable package.json."; return new() { ["t"] = "dev.state", ["state"] = report }; }
    using var package = JsonDocument.Parse(await File.ReadAllBytesAsync(packagePath, ct));
    var script = package.RootElement.TryGetProperty("scripts", out var scripts) && scripts.TryGetProperty("dev", out _) ? "dev" : scripts.ValueKind == JsonValueKind.Object && scripts.TryGetProperty("start", out _) ? "start" : null;
    if (script is null) { report["message"] = "This project defines no dev or start script."; return new() { ["t"] = "dev.state", ["state"] = report }; }
    report["script"] = script; report["command"] = "npm run " + script;
    string? sessionId; lock (phoneDevSessions) phoneDevSessions.TryGetValue(folder, out sessionId);
    var session = Sessions.FirstOrDefault(s => s.Definition.Id == sessionId && s.State == SessionState.Running);
    if (type == "dev.start" && session is null)
    {
      var created = await StartAsync("shell", folder, title: "Development server"); sessionId = created.Definition.Id;
      lock (phoneDevSessions) phoneDevSessions[folder] = sessionId;
      if (!host.MayStartIn(device, folder)) throw new PhoneRefusal("unauthorized", "This project is no longer shared.");
      await Keeper.WriteAsync(sessionId, Encoding.UTF8.GetBytes("npm run " + script + "\r"), ct); await RefreshSessionsAsync();
      session = Sessions.FirstOrDefault(s => s.Definition.Id == sessionId);
    }
    report["sessionId"] = session?.Definition.Id; report["status"] = session is null ? "idle" : "starting";
    if (session is not null)
    {
      var matches = Regex.Matches(session.Replay, @"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{1,5})");
      foreach (Match match in matches.Reverse().Take(8))
      {
        if (!int.TryParse(match.Groups[1].Value, out var port) || port is < 1 or > 65535 || LocalToolAddress?.Port == port) continue;
        using var socket = new TcpClient(); using var probe = CancellationTokenSource.CreateLinkedTokenSource(ct); probe.CancelAfter(TimeSpan.FromMilliseconds(300));
        try { await socket.ConnectAsync("127.0.0.1", port, probe.Token); report["status"] = "ready"; report["port"] = port; report["url"] = "http://localhost:" + port; break; }
        catch (Exception e) when (e is SocketException or OperationCanceledException) { ct.ThrowIfCancellationRequested(); }
      }
    }
    return new() { ["t"] = "dev.state", ["state"] = report };
  }
}
