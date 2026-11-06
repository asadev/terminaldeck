using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Remote;

// Read-only projections of the same owning services as the desktop/MCP tools.
// Caller supplies CURRENT project/session grant decisions; no cached authorization.
public sealed partial class PhoneConnectedFeatures(IProjects projects, IAgents agents, IReceiverArtifacts artifacts,
  Func<ApprovedDevice, string, bool> projectVisible, Func<ApprovedDevice, string, bool> sessionVisible,
  Func<string, CancellationToken, ValueTask<byte[]?>>? picturePng = null, PhoneArtifactServer? artifactServer = null) : IPhoneHostWorkspace
{
  public IReadOnlyList<string> Capabilities => ["pictures", "panels.agents", "panels.projects", "panels.artifacts"];
  public bool Handles(string type) => type is "pictures" or "picture" or "panel.read" or "panel.act";
  public bool Handles(string type, JsonElement message) => type is "pictures" or "picture" || (type is "panel.read" or "panel.act") &&
    Text(message, "panel") is "agents" or "projects" or "artifacts";
  public bool Permits(PhoneAccess access, string type) => access != PhoneAccess.Hoot && (type is "pictures" or "picture" || access == PhoneAccess.Full);
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "This page needs Full control.");
    if (!Handles(type, message)) throw new PhoneRefusal("unavailable", "This connected page is not available.");
    var answer = type switch { "pictures" => await Pictures(device, rid ?? Required(message, "rid"), ct), "picture" => await Picture(device, rid ?? Required(message, "rid"), Required(message, "picture"), ct), _ => await Panel(channel, device, message, ct) };
    if (type is "panel.read" or "panel.act") PhonePanelPagination.Apply(message, answer, rid);
    return [answer];
  }
  private Project[] VisibleProjects(ApprovedDevice device) => projects.List().Where(p => p.IsOpen && projectVisible(device, p.Id)).Take(128).ToArray();
  private SavedAgent[] VisibleAgents(ApprovedDevice device) => agents.List().Where(a => a.Status != SavedAgentStatus.Archived && projectVisible(device, a.ProjectId)).Take(200).ToArray();
  private static JsonObject Face(SavedAgent a) => new() { ["id"] = a.Id, ["name"] = a.Name, ["icon"] = PhoneAvatarIcon.Encode(a.Icon) };
  private async ValueTask<(string Hash, byte[] Png)?> Logo(Project project, CancellationToken ct)
  {
    var path = projects.PicturePath(project.Id);
    if (path is null) return null;
    if (picturePng is not null)
    {
      var png = await picturePng(path, ct);
      if (png is null || png.Length > 44000) return null;
      return (Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant(), png);
    }
    try
    {
      using var stream = File.OpenRead(path);
      if (stream.Length is < 8 or > 44000) return null;
      var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes);
      // The wire explicitly promises PNG. An arbitrary imported file cannot be relabelled.
      if (!bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return null;
      return (Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), bytes);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
  }
  private async ValueTask<JsonObject> Pictures(ApprovedDevice device, string rid, CancellationToken ct)
  {
    var projectRows = new JsonArray();
    foreach (var p in VisibleProjects(device))
    {
      var logo = await Logo(p, ct);
      foreach (var folder in p.Folders.Take(20))
      {
        var row = new JsonObject { ["folder"] = folder, ["id"] = p.Id, ["name"] = p.Name };
        if (logo is { } image) row["picture"] = image.Hash;
        projectRows.Add(row);
      }
    }
    var faces = new[] { (JsonNode)new JsonObject { ["id"] = "@hoot", ["name"] = "Hoot", ["icon"] = "hoot", ["hoot"] = true } }.Concat(VisibleAgents(device).Select(a => (JsonNode)Face(a))).ToArray();
    var sessionRows = new JsonArray();
    foreach (var run in agents.Runs().Where(r => projectVisible(device, r.ProjectId) && sessionVisible(device, r.SessionId)).Take(128))
      if (agents.SessionFace(run.SessionId) is { } face)
        sessionRows.Add(new JsonObject { ["id"] = run.SessionId, ["agent"] = new JsonObject { ["id"] = face.Id, ["name"] = face.Name, ["icon"] = PhoneAvatarIcon.Encode(face.Icon), ["hoot"] = face.Hoot } });
    var frame = new JsonObject { ["t"] = "pictures", ["rid"] = rid, ["projects"] = projectRows, ["agents"] = new JsonArray(faces), ["sessions"] = sessionRows };
    Trim(frame, projectRows, (JsonArray)frame["agents"]!, sessionRows); return frame;
  }
  private async ValueTask<JsonObject> Picture(ApprovedDevice device, string rid, string hash, CancellationToken ct)
  {
    if (hash.Length != 64 || hash.Any(c => !char.IsAsciiHexDigit(c))) throw new PhoneRefusal("bad-message", "Choose a picture from this device's project list.");
    foreach (var project in VisibleProjects(device))
      if (await Logo(project, ct) is { } logo && logo.Hash == hash)
        return new JsonObject { ["t"] = "picture", ["rid"] = rid, ["picture"] = hash, ["png"] = Convert.ToBase64String(logo.Png) };
    throw new PhoneRefusal("unavailable", "That picture is no longer shared with this device.");
  }
  private async ValueTask<JsonObject> Panel(string channel, ApprovedDevice device, JsonElement request, CancellationToken ct)
  {
    _ = PhonePanelPagination.Cursor(request);
    var panel = Required(request, "panel");
    if (panel == "artifacts" && Text(request, "preview") is not null) return await PreviewBytes(channel, device, request, ct);
    if (Text(request, "t") == "panel.act" && panel != "artifacts") throw new PhoneRefusal("unavailable", "This page is read only on this device."); var scope = Text(request, "scope"); var path = Text(request, "path") ?? "";
    var query = Text(request, "query") ?? ""; var rows = new JsonArray();
    var result = new JsonObject { ["t"] = "panel.rows", ["panel"] = panel, ["path"] = path, ["actions"] = new JsonArray(), ["rows"] = rows, ["view"] = scope };
    if (panel == "projects")
    {
      result["title"] = "Projects";
      var visible = VisibleProjects(device);
      if (scope == "project") visible = visible.Where(p => p.Folders.Any(f => Same(f, path))).ToArray();
      if (scope == "project" && visible.Length == 0) throw new PhoneRefusal("unauthorized", "That open project is no longer shared with this device.");
      foreach (var p in visible)
        foreach (var folder in p.Folders.Where(f => scope != "project" || Same(f, path)).Take(20))
          rows.Add(new JsonObject { ["id"] = folder, ["projectId"] = p.Id, ["title"] = p.Name, ["detail"] = string.Join(" · ", p.Folders), ["value"] = "Open", ["path"] = folder, ["icon"] = p.Icon, ["facts"] = new JsonArray(Fact("Folder", folder), Fact("Project", p.Name)) });
    }
    else if (panel == "agents")
    {
      var visible = VisibleAgents(device); var id = scope?.StartsWith("agent:", StringComparison.Ordinal) == true ? scope[6..] : null;
      if (id is not null)
      {
        var a = visible.FirstOrDefault(a => a.Id == id) ?? throw new PhoneRefusal("unavailable", "That agent is not shared with this device.");
        result["title"] = a.Name;
        rows.Add(new JsonObject { ["id"] = a.Id, ["title"] = a.Name, ["detail"] = a.Description, ["badge"] = a.Status.ToString(), ["facts"] = new JsonArray(
          Fact("AI", a.Provider), Fact("Model", a.Model), Fact("Effort", a.Effort), Fact("Project", a.ProjectId), Fact("Reports to", a.ReportsTo ?? "")) });
        foreach (var run in agents.Runs().Where(r => r.AgentId == id && sessionVisible(device, r.SessionId)).Take(100))
          rows.Add(new JsonObject { ["id"] = run.SessionId, ["title"] = run.Job.Length > 0 ? run.Job : run.AgentName, ["sessionId"] = run.SessionId, ["value"] = run.State.ToString() });
      }
      else
      {
        result["title"] = "Agents";
        foreach (var a in visible)
        {
          var group = scope == "group:reportsTo" || scope == "chart" ? visible.FirstOrDefault(p => p.Id == a.ReportsTo)?.Name ?? "No manager" : projects.List().FirstOrDefault(p => p.Id == a.ProjectId)?.Name ?? "Independent";
          rows.Add(new JsonObject { ["id"] = a.Id, ["title"] = a.Name, ["detail"] = a.Description, ["value"] = a.Provider, ["badge"] = a.Status.ToString(), ["group"] = group, ["icon"] = PhoneAvatarIcon.Encode(a.Icon), ["open"] = "agent:" + a.Id });
        }
      }
      result["note"] = "Read only. Edit agents on the PC.";
    }
    else
    {
      var project = VisibleProjects(device).FirstOrDefault(p => p.Folders.Any(f => Same(f, path)));
      if (project is null) throw new PhoneRefusal("unauthorized", "Choose a shared project folder.");
      result["title"] = "Artifacts";
      foreach (var a in artifacts.List(path).Where(a => device.Platform == "web" || CanPreviewArtifact(a.RelPath)).Take(200))
        rows.Add(new JsonObject { ["id"] = ArtifactId(device, path, a, false), ["title"] = a.RelPath, ["detail"] = a.ProducedAt.ToLocalTime().ToString("g"), ["sessionId"] = sessionVisible(device, a.SessionId) ? a.SessionId : null, ["value"] = ArtifactCatalogPolicy.Kind(a.RelPath) });
      result["note"] = "Recorded outputs. Tap an output to preview it.";
      if (Text(request, "t") == "panel.act")
      {
        if (Text(request, "action") != "preview") throw new PhoneRefusal("unavailable", "This artifact action is not available on this host.");
        var id = Required(request, "id");
        var found = artifacts.List(path).FirstOrDefault(a => CanPreviewArtifact(a.RelPath) && (Token(a) == id || a.Id == id)) ?? throw new PhoneRefusal("unavailable", "That output is no longer in this project's list.");
        var preview = artifacts.Preview(path, found.RelPath);
        if (artifactServer is not null)
        {
          var row = rows.OfType<JsonObject>().First(r => r["title"]?.GetValue<string>() == found.RelPath);
          row["id"] = ArtifactId(device, path, found, true);
          result["notice"] = "Output preview is ready.";
          return PhonePanelPagination.Apply(request, result);
        }
        if (preview.Text is { } text)
        {
          rows.Insert(0, new JsonObject { ["id"] = found.Id + "-preview", ["title"] = found.RelPath, ["body"] = text[..Math.Min(12000, text.Length)], ["bodyStyle"] = "code" });
          result["notice"] = preview.Truncated || text.Length > 12000 ? "Text preview shortened. Read the full output on the PC." : "Text preview.";
        }
        else throw new PhoneRefusal("unavailable", "Refresh the output list before previewing this file.");
      }
    }
    for (var index = rows.Count - 1; index >= 0; index--)
      if (query.Length > 0 && !rows[index]!.ToJsonString().Contains(query, StringComparison.OrdinalIgnoreCase)) rows.RemoveAt(index);
    return PhonePanelPagination.Apply(request, result);
  }
  // Without a media server this panel can preview text documents only.
  private bool CanPreviewArtifact(string path) => artifactServer is not null || Path.GetExtension(path).ToLowerInvariant() is ".html" or ".htm" or ".xhtml";
  private static string Token(ReceiverArtifact artifact) => "#" + Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(artifact.RelPath))).ToLowerInvariant()[..16];
  private string ArtifactId(ApprovedDevice device, string path, ReceiverArtifact artifact, bool serve)
  {
    var file = ReceiverArtifacts.SafePath(path, artifact.RelPath);
    var handle = serve ? artifactServer?.Serve(device.Id, path, artifact.RelPath) : null;
    return string.Join(' ', RememberArtifact(device, path, artifact, file), PhoneArtifactServer.Kind(file), new FileInfo(file).Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
      handle is null ? "-" : handle.Port + "." + handle.Secret, file);
  }
  private static JsonObject Fact(string label, string value) => new() { ["label"] = label, ["value"] = value };
  private static bool Same(string a, string b) => string.Equals(a.TrimEnd('\\', '/'), b.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
  private static string? Text(JsonElement message, string name) => message.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
  private static string Required(JsonElement message, string name) => Text(message, name) is { Length: > 0 and <= 1024 } text ? text : throw new PhoneRefusal("bad-message", "Missing " + name + ".");
  private static void Trim(JsonObject frame, params JsonArray[] rows)
  {
    while (System.Text.Encoding.UTF8.GetByteCount(frame.ToJsonString()) > 48000)
    {
      var largest = rows.OrderByDescending(r => r.Count).First();
      if (largest.Count == 0) throw new PhoneRefusal("unavailable", "This page is too large to send safely.");
      largest.RemoveAt(largest.Count - 1); frame["note"] = "Shortened to fit this device.";
    }
  }
}
