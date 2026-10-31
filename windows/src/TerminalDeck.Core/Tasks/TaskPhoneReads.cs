using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tasks;

// The existing phones ask panel.read { panel: tasks, path, scope: task:<id> }.
// This contribution supplies only reads, with the same rows/meta/comments format.
public sealed class TaskPhoneReads(ITasks tasks, IProjects projects, Func<string, TaskRecipient?> recipient)
{
  public JsonElement Read(string path, string? scope, string? query, Func<DeckTask, bool> visible)
  {
    var rows = new List<object>();
    var list = tasks.List(new(Status: "all")).Where(t => SamePath(t.Folder, path) && visible(t)).ToArray();
    DeckTask? selected = null;
    if (scope is not null)
    {
      if (!scope.StartsWith("task:", StringComparison.Ordinal)) throw new ProtocolException("Choose a task page from this project.");
      selected = list.FirstOrDefault(t => t.Id == scope[5..]) ?? throw new ProtocolException("This task is outside this phone's current access.");
      rows.Add(Row(selected, detail: true));
      foreach (var a in selected.Activity.TakeLast(20)) rows.Add(new { id = "activity:" + a.Id, title = a.Text, detail = a.At.ToString("O"), group = "Activity", actions = Array.Empty<object>() });
      foreach (var c in selected.Comments.TakeLast(44)) rows.Add(new
      {
        id = "comment:" + c.Id, title = c.Author.Name, detail = c.At.ToString("O"), value = c.Author.Kind,
        body = Clip(c.Text, 4000), group = "Comments", meta = new { authorId = c.Author.Id }, actions = Array.Empty<object>()
      });
    }
    else foreach (var row in list.Where(t => string.IsNullOrWhiteSpace(query) || t.Title.Contains(query, StringComparison.OrdinalIgnoreCase)).Take(200)) rows.Add(Row(row, detail: false));
    // Keep the sealed application frame bounded. A long page is a partial read,
    // never a silent oversized frame which disconnects an unchanged phone.
    var note = selected is null && list.Length > 200 ? "Showing the first 200 tasks. Narrow the search to see more." : (string?)null;
    while (true)
    {
      var value = JsonSerializer.SerializeToElement(new { t = "panel.rows", panel = "tasks", path, view = scope, title = selected?.Title,
        rows, actions = Array.Empty<object>(), scopes = Array.Empty<object>(), note });
      if (JsonSerializer.SerializeToUtf8Bytes(value).Length <= PhoneWire.MaximumMessageBytes - 64) return value;
      if (rows.Count <= 1) throw new ProtocolException("This task page is too large to read on the phone.");
      rows.RemoveAt(rows.Count - 1); note = "This page was shortened for the phone. Read the remaining comments on the computer.";
    }
  }
  private object Row(DeckTask task, bool detail)
  {
    var who = task.Assignee switch { "me" => new TaskRecipient("me", "You", "human", null), "none" => new("none", "Unassigned", "none", null), _ => recipient(task.Assignee) ?? new(task.Assignee, task.Assignee, "agent", null) };
    var meta = new Dictionary<string, object?> { ["status"] = task.Status, ["assignee"] = task.Assignee, ["assigneeName"] = who.Name,
      ["participants"] = TaskExtras.Of(task).Participants, ["assigneeKind"] = who.Kind, ["priority"] = task.Priority, ["start"] = task.StartDate, ["due"] = task.DueDate, ["startTime"] = task.StartTime, ["dueTime"] = task.DueTime, ["tags"] = task.Labels,
      ["board"] = task.Board, ["working"] = tasks.Runs(task.Id).LastOrDefault()?.State == TaskRunState.Working ? "1" : "0" };
    var session = tasks.Runs(task.Id).LastOrDefault(r => r.Id == task.CurrentRunId)?.SessionId;
    return new { id = task.Id, title = task.Title, detail = who.Name, value = task.Status, body = detail ? Clip(task.Details, 12000) : null,
      sessionId = session, meta, actions = Array.Empty<object>() };
  }
  private static string Clip(string text, int max) => text.Length <= max ? text : text[..max] + "\n[Read the rest on the computer.]";
  private static bool SamePath(string first, string second) => first.Length > 0 && second.Length > 0 && ProjectPaths.Equal(first, second);
  public IReadOnlyList<string> ProjectFolders(Func<string, string, bool> permitted) => projects.List().Where(p => p.IsOpen).SelectMany(p => p.Folders.Where(folder => permitted(p.Id, folder))).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
}

// Wrap the existing phone application, retaining its sealed handshake, pairing,
// session behavior and authentication. Task access is a separate explicit grant.
public sealed class TaskPhoneApplication(IRelayPhoneApplication next, DeviceTrust trust, TaskPhoneReads reads,
  Func<ApprovedDevice, string?, string, bool> permitted) : IRelayPhoneApplication
{
  private readonly ConcurrentDictionary<string, string> authenticated = new();
  public IReadOnlyCollection<byte[]> KnownPeers => next.KnownPeers;
  public bool PairingOpen => next.PairingOpen;
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> peerKey, CancellationToken ct) => next.OpenedAsync(channel, peerKey, ct);
  public async ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (plaintext.Length > PhoneWire.MaximumMessageBytes) throw new ProtocolException("The phone message is too large.");
    JsonElement message;
    try
    {
      // Decode strictly before JsonDocument can accept replacement characters.
      _ = new System.Text.UTF8Encoding(false, true).GetString(plaintext.Span);
      using var doc = JsonDocument.Parse(plaintext, new JsonDocumentOptions { MaxDepth = 32 }); message = doc.RootElement.Clone();
      if (message.EnumerateObject().Select(p => p.Name).Distinct().Count() != message.EnumerateObject().Count()) throw new JsonException();
    }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException or System.Text.DecoderFallbackException)
    { throw new ProtocolException("The phone message is unusable."); }
    var type = Text(message, "t", 64);
    if (type == "hello")
    {
      var reply = await next.ReceiveAsync(channel, peerKey, plaintext, ct);
      if (reply.Close) return reply;
      var device = trust.Authenticate(Text(message, "token", 200), peerKey.Span);
      authenticated[channel] = device.Id;
      var folders = reads.ProjectFolders((project, path) => permitted(device, project, path));
      var messages = reply.Messages.Select(raw =>
      {
        var root = JsonNode.Parse(raw);
        if (root?["t"]?.GetValue<string>() != "welcome") return raw;
        var caps = root["capabilities"]?.AsArray() ?? new();
        if (folders.Count > 0)
        {
          var values = caps.Select(c => c!.GetValue<string>()).Concat(new[] { "panels", "panels.tasks" }).Distinct().ToArray();
          root["capabilities"] = JsonSerializer.SerializeToNode(values);
          var oldFolders = root["folders"]?.Deserialize<string[]>() ?? [];
          root["folders"] = JsonSerializer.SerializeToNode(oldFolders.Concat(folders).Distinct(StringComparer.OrdinalIgnoreCase));
        }
        return JsonSerializer.SerializeToUtf8Bytes(root);
      }).ToArray();
      _ = trust.RequireCurrent(device.Id, peerKey.Span);
      return new(messages);
    }
    if (type != "panel.read" || Text(message, "panel", 64) != "tasks") return await next.ReceiveAsync(channel, peerKey, plaintext, ct);
    if (!authenticated.TryGetValue(channel, out var id)) throw new ProtocolException("Say hello before reading tasks.");
    var current = trust.RequireCurrent(id, peerKey.Span);
    var path = Text(message, "path", 4096);
    try { _ = ProjectPaths.Normalize(path); } catch (ArgumentException) { throw new ProtocolException("Choose an absolute project folder for this task read."); }
    var scope = Optional(message, "scope", 128); var query = Optional(message, "query", 128);
    if (!permitted(current, null, path)) throw new ProtocolException("This phone cannot read tasks in that project.");
    var visibleTasks = new List<DeckTask>();
    var payload = reads.Read(path, scope, query, row =>
    {
      if (!permitted(current, row.ProjectId, row.Folder)) return false;
      visibleTasks.Add(row); return true;
    });
    ct.ThrowIfCancellationRequested(); var fresh = trust.RequireCurrent(id, peerKey.Span);
    if (!permitted(fresh, null, path) || visibleTasks.Any(row => !permitted(fresh, row.ProjectId, row.Folder))) throw new ProtocolException("This phone's task access changed.");
    return new([JsonSerializer.SerializeToUtf8Bytes(payload)]);
  }
  public async ValueTask DisconnectedAsync(string channel) { authenticated.TryRemove(channel, out _); await next.DisconnectedAsync(channel); }
  private static string? Optional(JsonElement value, string key, int max) => value.TryGetProperty(key, out _) ? Text(value, key, max, empty: true) : null;
  private static string Text(JsonElement value, string key, int max, bool empty = false)
  {
    if (!value.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.String) throw new ProtocolException("The phone message is missing a field.");
    var s = v.GetString()!;
    if ((!empty && s.Length == 0) || System.Text.Encoding.UTF8.GetByteCount(s) > max || s.Any(char.IsControl)) throw new ProtocolException("The phone message has an unusable field.");
    return s;
  }
}
