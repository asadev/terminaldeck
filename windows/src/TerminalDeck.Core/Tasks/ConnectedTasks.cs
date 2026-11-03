using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tasks;

public sealed record ConnectedTaskSystem(string Id, string Name, string ServerId, string ProjectId, bool AllowChanges = false);
public sealed record ConnectedTasksState(int Version, ImmutableArray<ConnectedTaskSystem> Systems);
public sealed record ConnectedTask(string Id, string Title, string Status, string Details, string? Priority = null, string? DueDate = null,
  string? Assignee = null, string? Board = null, bool AssignedToMe = false, bool RaisedByMe = false);
public sealed record ConnectedTaskServer(string Id, string Name, string Url);
public interface IConnectedTaskGateway
{
  ValueTask<IReadOnlyList<ConnectedTaskServer>> ServersAsync(CancellationToken cancellationToken) => ValueTask.FromResult<IReadOnlyList<ConnectedTaskServer>>([]);
  ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(string server, CancellationToken cancellationToken);
  ValueTask<JsonElement> CallAsync(string server, string tool, JsonElement arguments, CancellationToken cancellationToken);
}
public sealed class ManagedConnectedTaskGateway(McpManager manager) : IConnectedTaskGateway
{
  public async ValueTask<IReadOnlyList<ConnectedTaskServer>> ServersAsync(CancellationToken ct)
  {
    var result = new List<ConnectedTaskServer>();
    foreach (var server in (await manager.ListAsync(ct)).Where(s => s.Enabled && s.Transport == "http"))
    {
      var config = await manager.ExportAsync(server.Id, ct);
      if (config.TryGetProperty("Url", out var url) && url.GetString() is { } address && Uri.TryCreate(address, UriKind.Absolute, out var uri) &&
        uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0 && (uri.Scheme == "https" || uri.IsLoopback))
        result.Add(new(server.Id, server.Name, address));
    }
    return result;
  }
  public ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(string server, CancellationToken ct) => manager.ConnectAsync(server, ct);
  public async ValueTask<JsonElement> CallAsync(string server, string tool, JsonElement args, CancellationToken ct)
  {
    var answer = await manager.CallAsync(server, tool, args, ct);
    return ConnectedTaskMapping.Unwrap(answer.GetProperty("data"));
  }
}

// Connections refer to the existing MCP manager, which owns authentication and
// protected headers. No token, credential copy or second HTTP client lives here.
public sealed class ConnectedTasksService(IStateStore<ConnectedTasksState> persistence, IConnectedTaskGateway gateway, IProjects projects)
{
  private readonly SemaphoreSlim gate = new(1);
  private ConnectedTasksState state = Load(persistence);
  public event Action? Changed;
  public ValueTask<IReadOnlyList<ConnectedTaskServer>> ServersAsync(CancellationToken ct = default) => gateway.ServersAsync(ct);
  public async ValueTask<ConnectedTaskSystem> ConnectExistingAsync(string name, string url, string projectId, string changes, CancellationToken ct = default, Func<CancellationToken, ValueTask>? current = null)
  {
    if (changes is not ("off" or "ask" or "allow")) throw new ArgumentException("Choose whether task changes are allowed.");
    var servers = await ServersAsync(ct);
    var server = servers.SingleOrDefault(s => s.Url == url && s.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
      ?? throw new InvalidOperationException("Save this HTTP server and its protected sign-in under MCP first, then select it here.");
    var existing = Systems().FirstOrDefault(s => s.ServerId == server.Id);
    var id = existing?.Id ?? ProjectIdentity.NewId(name, Systems().Select(s => s.Id));
    return await BindAsync(id, name, server.Id, projectId, changes != "off", ct, current);
  }
  public IReadOnlyList<ConnectedTaskSystem> Systems() => Volatile.Read(ref state).Systems;
  public async ValueTask<ConnectedTaskSystem> BindAsync(string id, string name, string serverId, string projectId, bool allowChanges, CancellationToken ct = default, Func<CancellationToken, ValueTask>? current = null)
  {
    if (!ProjectIdentity.ValidId(id) || string.IsNullOrWhiteSpace(name) || name.Length > 120 || name.Any(char.IsControl) || string.IsNullOrWhiteSpace(serverId)) throw new ArgumentException("Give the task system a short name and choose a saved MCP server.");
    _ = projects.Get(projectId);
    var tools = await gateway.ToolsAsync(serverId, ct);
    _ = ConnectedTaskProfile.Discover(tools).List ?? throw new InvalidOperationException("This server does not offer a supported task list.");
    if (current is not null) await current(ct);
    var system = new ConnectedTaskSystem(id, name, serverId, projectId, allowChanges);
    await gate.WaitAsync(ct);
    try
    {
      var next = state with { Systems = state.Systems.Where(s => s.Id != id).Append(system).ToImmutableArray() };
      persistence.Save(next); state = next;
    }
    finally { gate.Release(); }
    Changed?.Invoke(); return system;
  }
  public async ValueTask<IReadOnlyList<ConnectedTask>> ListAsync(string systemId, string search = "", bool includeDone = false, CancellationToken ct = default)
  {
    var system = Get(systemId); var profile = ConnectedTaskProfile.Discover(await gateway.ToolsAsync(system.ServerId, ct));
    var tool = profile.List ?? throw new InvalidOperationException("This task system does not offer a supported task list.");
    var args = new Dictionary<string, object?>();
    if (tool.Property("limit", "max", "max_results", "page_size") is { } limit) args[limit] = 200;
    if (tool.Property("include_done", "includeDone", "include_closed", "includeCompleted", "include_completed") is { } done) args[done] = includeDone;
    var answer = await gateway.CallAsync(system.ServerId, tool.Spec.Name, TasksMcp.Value(args), ct);
    return ConnectedTaskMapping.Rows(answer).Take(200).Select(ConnectedTaskMapping.Task).Where(t => includeDone || !ConnectedTaskMapping.Done(t.Status))
      .Where(t => search.Length == 0 || string.Join(' ', t.Title, t.Assignee, t.Board).Contains(search, StringComparison.OrdinalIgnoreCase)).ToArray();
  }
  public async ValueTask<JsonElement> GetAsync(string systemId, string taskId, CancellationToken ct = default)
  {
    var system = Get(systemId); var profile = ConnectedTaskProfile.Discover(await gateway.ToolsAsync(system.ServerId, ct));
    var tool = profile.Get ?? throw new InvalidOperationException("This task system does not offer task details.");
    return await gateway.CallAsync(system.ServerId, tool.Spec.Name, TasksMcp.Value(new Dictionary<string, object?> { [tool.IdArgument!] = taskId }), ct);
  }
  public async ValueTask<JsonElement> CommentAsync(string systemId, string taskId, string text, CancellationToken ct = default,
    Func<CancellationToken, ValueTask>? current = null)
  {
    if (string.IsNullOrWhiteSpace(text) || text.Length > 2000) throw new ArgumentException("Write a comment of up to 2,000 characters.");
    var system = Changeable(systemId); var profile = ConnectedTaskProfile.Discover(await gateway.ToolsAsync(system.ServerId, ct));
    var tool = profile.Comment ?? throw new InvalidOperationException("This system does not offer comments.");
    var body = tool.Property("body", "text", "comment", "content", "message") ?? throw new InvalidOperationException("The comment tool has no supported text field.");
    var args = TasksMcp.Value(new Dictionary<string, object?> { [tool.IdArgument!] = taskId, [body] = text });
    if (current is not null) await current(ct); if (Get(systemId) != system) throw new InvalidOperationException("This connection changed. Read it again before commenting.");
    return await gateway.CallAsync(system.ServerId, tool.Spec.Name, args, ct);
  }
  public async ValueTask<JsonElement> UpdateAsync(string systemId, string taskId, string? status, string? dueDate, string? assignee, bool confirm,
    CancellationToken ct = default, Func<CancellationToken, ValueTask>? current = null)
  {
    var system = Changeable(systemId); var profile = ConnectedTaskProfile.Discover(await gateway.ToolsAsync(system.ServerId, ct));
    if (status is null && dueDate is null && assignee is null) throw new ArgumentException("Choose a status, due date or person to change.");
    if (dueDate is { Length: > 0 } && !DateOnly.TryParseExact(dueDate, "yyyy-MM-dd", out _)) throw new ArgumentException("Use a due date such as 2026-10-29, or clear it.");
    var tool = dueDate is not null || assignee is not null ? profile.Update : profile.Status ?? profile.Update;
    if (tool is null) throw new InvalidOperationException("This task system does not offer that change.");
    var args = new Dictionary<string, object?> { [tool.IdArgument!] = taskId };
    void Put(string? value, params string[] names)
    {
      if (value is null) return;
      var key = tool.Property(names) ?? throw new InvalidOperationException("This task system does not offer that field."); args[key] = value;
    }
    Put(status, "status", "state", "to", "group"); Put(dueDate, "due_date", "dueDate", "due", "due_on"); Put(assignee, "assignee", "assignee_id", "assigneeId", "assigned_to", "owner");
    if (confirm && tool.Property("confirm") is { } c) args[c] = true;
    var value = TasksMcp.Value(args); McpSchema.Validate(tool.Spec.InputSchema, value);
    if (current is not null) await current(ct); if (Get(systemId) != system) throw new InvalidOperationException("This connection changed. Read it again before changing the task.");
    var result = await gateway.CallAsync(system.ServerId, tool.Spec.Name, value, ct); Changed?.Invoke(); return result;
  }
  private ConnectedTaskSystem Get(string id) => Systems().SingleOrDefault(s => s.Id == id) ?? throw new ArgumentException("Choose a connected task system.");
  private ConnectedTaskSystem Changeable(string id)
  {
    var system = Get(id); if (!system.AllowChanges) throw new InvalidOperationException("Changes are off for this task system. The owner can allow them in its connection settings."); return system;
  }
  private static ConnectedTasksState Load(IStateStore<ConnectedTasksState> store)
  {
    var s = store.Load() ?? new(1, []);
    if (s.Version != 1 || s.Systems.IsDefault || s.Systems.Select(x => x.Id).Distinct().Count() != s.Systems.Length) throw new IOException("The saved task systems could not be read safely.");
    return s;
  }
}
public sealed record ConnectedTaskTool(McpRemoteTool Spec, string? IdArgument)
{
  public string? Property(params string[] names) => Spec.InputSchema.TryGetProperty("properties", out var props) ? names.FirstOrDefault(n => props.TryGetProperty(n, out _)) : null;
}
public sealed record ConnectedTaskProfile(ConnectedTaskTool? List, ConnectedTaskTool? Get, ConnectedTaskTool? Status, ConnectedTaskTool? Update, ConnectedTaskTool? Comment)
{
  public static ConnectedTaskProfile Discover(IReadOnlyList<McpRemoteTool> tools)
  {
    ConnectedTaskTool? Find(bool id, params string[] names)
    {
      foreach (var name in names)
      foreach (var candidate in new[] { name, "tasks_" + name, "task_" + name, "tasks." + name })
      {
        var spec = tools.FirstOrDefault(t => t.Name.Equals(candidate, StringComparison.OrdinalIgnoreCase)); if (spec is null) continue;
        var tool = new ConnectedTaskTool(spec, null); var arg = tool.Property("task_id", "taskId", "id", "task");
        if (!id || arg is not null) return tool with { IdArgument = arg };
      }
      return null;
    }
    return new(Find(false, "list_tasks", "list_my_tasks", "tasks_list"), Find(true, "get_task", "read_task", "open_task", "task_get", "tasks_get"),
      Find(true, "set_task_status", "update_task_status", "change_task_status", "set_status", "move_task", "tasks_set_status"),
      Find(true, "update_task", "edit_task", "patch_task", "tasks_update"), Find(true, "add_comment", "add_task_comment", "comment_on_task", "create_comment", "tasks_comment"));
  }
}
public static class ConnectedTaskMapping
{
  public static JsonElement Unwrap(JsonElement value)
  {
    if (value.ValueKind != JsonValueKind.Object) return value.Clone();
    if (value.TryGetProperty("isError", out var error) && error.ValueKind == JsonValueKind.True) throw new InvalidOperationException("The task system refused this request. Check the task there before trying again.");
    if (value.TryGetProperty("structuredContent", out var structured) && structured.ValueKind is JsonValueKind.Object or JsonValueKind.Array) return structured.Clone();
    if (value.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
      foreach (var item in content.EnumerateArray()) if (item.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
      {
        try { using var doc = JsonDocument.Parse(text.GetString()!); return doc.RootElement.Clone(); } catch (JsonException) { }
      }
    return value.Clone();
  }
  public static IEnumerable<JsonElement> Rows(JsonElement value)
  {
    if (value.ValueKind == JsonValueKind.Array) return value.EnumerateArray().ToArray();
    foreach (var key in new[] { "tasks", "rows", "items", "data" }) if (value.TryGetProperty(key, out var rows))
    {
      if (rows.ValueKind == JsonValueKind.Array) return rows.EnumerateArray().ToArray();
      if (rows.ValueKind == JsonValueKind.Object) return Rows(rows);
    }
    throw new InvalidOperationException("This task system did not return a readable task list.");
  }
  public static ConnectedTask Task(JsonElement row)
  {
    string? Text(params string[] keys) { foreach (var key in keys) if (row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String) return v.GetString(); return null; }
    bool Flag(string key) => row.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
    return new(Text("id", "task_id", "taskId") ?? throw new InvalidOperationException("A connected task has no id."), Text("title", "name") ?? "Untitled task", Text("status", "state") ?? "",
      Text("description", "details", "instructions") ?? "", Text("priority"), Text("dueDate", "due_date"), Text("assigneeName", "assignee"), Text("board"), Flag("assignedToMe"), Flag("raisedByMe"));
  }
  public static bool Done(string status) => new[] { "done", "complete", "completed", "closed", "finished", "resolved" }.Contains(status.ToLowerInvariant());
}
