using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Tasks;

public sealed record TaskToolContribution(McpToolSpec Spec, McpToolHandler Handler);
public sealed class TasksMcp(ITasks tasks, IProjects projects, string machine, Func<string, TaskRecipient?> recipient,
  ConnectedTasksService? connected = null, Func<string, string?>? sessionProject = null)
{
  private static readonly object Text = new { type = "string", maxLength = 40000 };
  private static readonly object Bool = new { type = "boolean" };
  private static readonly object NullableText = new { type = new[] { "string", "null" } };
  public static IReadOnlyList<McpToolSpec> Specs { get; } = MakeSpecs();
  public IReadOnlyList<TaskToolContribution> Contributions() => Specs.Where(s => connected is not null || !s.Id.StartsWith("connected_tasks.", StringComparison.Ordinal))
    .Select(spec => new TaskToolContribution(spec, (ctx, args, ct) => CallAsync(spec.Id, ctx, args, ct))).ToArray();
  public void Register(McpDoor door)
  {
    var contracts = McpCatalogue.Load().ToDictionary(s => s.Id);
    foreach (var row in Contributions())
      if (!contracts.TryGetValue(row.Spec.Id, out var known) || known.Tier != row.Spec.Tier || !JsonElement.DeepEquals(known.InputSchema, row.Spec.InputSchema))
        throw new InvalidOperationException("Install the Tasks contribution in the central tool catalogue before registering it.");
    foreach (var pair in new[] { ("tasks.local_change", "create"), ("tasks.local_change", "assign"), ("tasks.views", "update") })
    {
      var spec = Specs.Single(s => s.Id == pair.Item1); var args = Value(new { @do = pair.Item2 });
      if (McpCatalogue.EffectiveTier(spec, args) != Tier(spec, args)) throw new InvalidOperationException("Install the Tasks permission rules before registering its tools.");
    }
    foreach (var row in Contributions()) door.Register(row.Spec.Id, row.Handler);
  }
  // Same mixed-action policy as BackendTaskToolPolicy and BackendTasksPageTools.
  public static McpTier Tier(McpToolSpec spec, JsonElement args) => spec.Id switch
  {
    "tasks.local_change" => S(args, "do") is "status" or "comment" ? McpTier.Act : McpTier.Alter,
    "tasks.views" => S(args, "do") == "list" ? McpTier.Read : McpTier.Alter,
    "tasks.goals" => S(args, "do") is "list" or "get" ? McpTier.Read : McpTier.Alter,
    _ => spec.Tier
  };
  public async ValueTask<JsonElement> CallAsync(string id, McpCallContext ctx, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.Single(s => s.Id == id); McpSchema.Validate(spec.InputSchema, args);
    var tier = Tier(spec, args);
    if (!ctx.Grant.Tools.Contains(id) || !ctx.Grant.Tiers.Contains(tier)) throw new McpRefusal("This caller cannot use this task action.");
    if (tier != McpTier.Read && (ctx.Grant.PermissionMode == AiPermissionMode.Plan || tier == McpTier.Alter && !ctx.Grant.Attended)) throw new McpRefusal("This task change needs the calling AI's permission and the person present.");
    await ctx.EnsureCurrentAsync(ct);
    string? HomeProject()
    {
      if (ctx.Grant.SessionId is not { } session) return null;
      if (sessionProject?.Invoke(session) is { } project) return project;
      if (tasks.Runs().LastOrDefault(r => r.SessionId == session) is { } run) return tasks.Get(run.TaskId).ProjectId;
      var granted = ctx.Grant.Resources.Where(r => r.StartsWith("projects:", StringComparison.Ordinal)).Select(r => r[9..]).ToArray();
      return granted.Length == 1 ? granted[0] : null;
    }
    // AIs name agents the way people see them ("Captest Tester"); store the id.
    string Canonical(string who) => who is "me" or "none" ? who : recipient(who)?.Id ?? who;
    bool Visible(DeckTask t) => (ctx.Has("tasks", t.Id) || ctx.Has("tasks", "*")) && ctx.Has("projects", t.ProjectId) && (t.Folder.Length == 0 || ctx.Has("folders", t.Folder));
    DeckTask TaskOf(bool trash = false)
    {
      var task = tasks.Get(R(args, "task"), trash);
      if (!Visible(task)) throw new McpRefusal("This task is outside this caller's current access."); return task;
    }
    void Project(string projectId, string? folder)
    {
      ctx.Require("projects", projectId);
      if (folder is { Length: > 0 }) ctx.Require("folders", folder);
    }
    TaskActor Actor(DeckTask? task = null)
    {
      if (ctx.Grant.OwnerApplication) return TaskActor.Owner;
      if (ctx.Grant.SeatId == TerminalDeck.Core.Hoot.HootDesk.Seat) return new("hoot", "Hoot", "hoot");
      var run = task is null ? null : tasks.Runs(task.Id).LastOrDefault(r => r.Id == task.CurrentRunId && r.SessionId == ctx.Grant.SessionId && r.SessionId is not null);
      return run is null ? new(ctx.Grant.CallerId, ctx.Grant.CallerId, "agent") : new(run.AgentId, recipient(run.AgentId)?.Name ?? run.AgentId, "agent");
    }
    async ValueTask<DeckTask> Assign(string taskId, string agent, TaskActor by)
    {
      var row = await tasks.AssignAsync(taskId, agent, by, cancellationToken: ct, beforeStart: ctx.EnsureCurrentAsync,
        authorizeStart: async (plan, token) =>
        {
          ctx.Require("agents", plan.AgentId); ctx.Require("projects", plan.ProjectId); ctx.Require("folders", plan.Folder); ctx.Require("accounts", plan.AccountId);
          await ctx.EnsureCurrentAsync(token);
        });
      if (tasks.Runs(taskId).LastOrDefault(r => r.Id == row.CurrentRunId)?.SessionId is { } session && !TerminalDeck.Core.Integration.W9TaskRunner.IsHootRun(session)) ctx.NoteSessionStarted(session);
      return row;
    }
    if (id.StartsWith("connected_tasks.", StringComparison.Ordinal))
    {
      if (connected is null) throw new McpRefusal("Connected task systems are not connected on this host.");
      var systems = connected.Systems().Where(s => ctx.Has("task-systems", s.Id) && ctx.Has("projects", s.ProjectId)).ToArray();
      if (id == "connected_tasks.systems") return Value(new { systems = systems.Where(s => S(args, "projectId") is not { } p || s.ProjectId == p) });
      if (id == "connected_tasks.connect")
      {
        var projectId = S(args, "projectId") ?? ProjectIdentity.IndependentId;
        ctx.Require("projects", projectId); ctx.Require("settings", "tasks"); ctx.Require("task-systems", "*");
        await ctx.EnsureCurrentAsync(ct);
        return Value(await connected.ConnectExistingAsync(R(args, "name"), R(args, "url"), projectId, S(args, "changes") ?? "ask", ct, ctx.EnsureCurrentAsync));
      }
      var name = S(args, "system");
      var system = (name is null ? systems.Length == 1 ? systems[0] : null : systems.SingleOrDefault(s => s.Id == name || s.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
        ?? throw new McpRefusal("Choose one of this caller's connected task systems.");
      await ctx.EnsureCurrentAsync(ct);
      if (id == "connected_tasks.list") return Value(await connected.ListAsync(system.Id, S(args, "search") ?? "", B(args, "include_done"), ct));
      if (id == "connected_tasks.hand_to_agent")
      {
        var agent = R(args, "agent"); RequireAgent(ctx, agent); ctx.Require("tasks", "*");
        var folder = S(args, "project") ?? projects.Get(system.ProjectId).HomeFolder ?? throw new McpRefusal("Choose a project folder for this task.");
        var projectId = projects.Resolve(null, folder); Project(projectId, folder);
        var sourceId = R(args, "task"); var link = new ConnectedTaskLink(system.Id, sourceId);
        var previous = tasks.List(new(Status: "all")).FirstOrDefault(t => t.Connected == link);
        if (previous is not null) { if (!Visible(previous)) throw new McpRefusal("The linked local task is outside this caller's access."); return View(previous); }
        var detail = await connected.GetAsync(system.Id, sourceId, ct); var source = ConnectedTaskMapping.Task(detail.TryGetProperty("task", out var nested) ? nested : detail);
        await ctx.EnsureCurrentAsync(ct);
        var local = tasks.Create(new(source.Title, source.Details, projectId, folder), Actor(), link);
        return View(await Assign(local.Id, agent, Actor()));
      }
      if (id == "connected_tasks.get") return await connected.GetAsync(system.Id, R(args, "task"), ct);
      if (id == "connected_tasks.comment") return await connected.CommentAsync(system.Id, R(args, "task"), R(args, "body"), ct, ctx.EnsureCurrentAsync);
      if (id == "connected_tasks.update") return await connected.UpdateAsync(system.Id, R(args, "task"), S(args, "status"), S(args, "due_date"), S(args, "assignee"), B(args, "confirm"), ct, ctx.EnsureCurrentAsync);
      throw new McpRefusal("This connected-task action is unavailable.");
    }
    if (id == "tasks.goals")
    {
      var action = R(args, "do");
      var visibleGoals = tasks.Goals().Where(g => ctx.Has("projects", g.ProjectId)).ToArray();
      var goal = S(args, "id") is { } goalId ? visibleGoals.FirstOrDefault(g => g.Id == goalId) ?? throw new McpRefusal("Choose a goal in this caller's projects.") : null;
      if (action == "list") return Value(new { goals = visibleGoals.Where(g => S(args, "projectId") is not { } filterProject || g.ProjectId == filterProject) });
      if (action == "get") return Value(new { goal = goal ?? throw new McpRefusal("Choose a goal."), tasks = tasks.List(new(Status: "all", GoalId: goal.Id)).Where(Visible).Select(View) });
      ctx.Require("tasks", "*");
      var projectId = S(args, "projectId") ?? goal?.ProjectId ?? ProjectIdentity.IndependentId; ctx.Require("projects", projectId);
      await ctx.EnsureCurrentAsync(ct);
      if (action == "delete") { if (goal is null) throw new McpRefusal("Choose a goal."); tasks.DeleteGoal(goal.Id, Actor()); return Value(new { removed = true }); }
      if (action == "save") return Value(tasks.SaveGoal(new(R(args, "title"), S(args, "description") ?? "", projectId, S(args, "status") ?? "active", S(args, "parentId")), Actor(), goal?.Id,
        args.TryGetProperty("revision", out var revision) ? revision.GetInt64() : null));
      throw new McpRefusal("Choose list, get, save or delete.");
    }
    if (id == "tasks.views")
    {
      ctx.Require("settings", "tasks");
      var action = R(args, "do");
      bool ViewAllowed(TaskFilter filter) => (filter.ProjectId is null || ctx.Has("projects", filter.ProjectId)) && (filter.ProjectIds.IsDefaultOrEmpty || filter.ProjectIds.All(p => ctx.Has("projects", p)));
      var views = tasks.Views(machine).Where(v => ViewAllowed(v.State)).ToArray();
      var selected = S(args, "id") is { } viewId ? views.FirstOrDefault(v => v.Id == viewId) ?? throw new McpRefusal("Choose one of this caller's saved task views.") : null;
      var state = args.TryGetProperty("state", out var raw) ? raw.Deserialize<TaskFilter>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new McpRefusal("Choose task filters.") : tasks.Filter(machine);
      if (state.ProjectId is { } p) ctx.Require("projects", p);
      if (!state.ProjectIds.IsDefault) foreach (var project in state.ProjectIds) ctx.Require("projects", project);
      await ctx.EnsureCurrentAsync(ct);
      if (action == "update") tasks.RememberFilter(machine, state);
      else if (action == "save") tasks.SaveView(machine, selected?.Id, R(args, "name"), state);
      else if (action == "rename") { if (selected is null) throw new McpRefusal("Choose a saved view."); tasks.SaveView(machine, selected.Id, R(args, "name"), selected.State); }
      else if (action is "select" or "revert") { if (selected is null) throw new McpRefusal("Choose a saved view."); tasks.RememberFilter(machine, selected.State); }
      else if (action == "delete") { if (selected is null) throw new McpRefusal("Choose a saved view."); tasks.DeleteView(machine, selected.Id); }
      return Value(new { state = tasks.Filter(machine), changed = action != "list", tabs = tasks.Views(machine).Where(v => ViewAllowed(v.State)) });
    }

    if (id is "tasks.list" || id == "tasks.local" && R(args, "do") is "list" or "trash")
    {
      var projectId = S(args, "projectId"); var folder = S(args, "project");
      if (folder is not null) { ctx.Require("folders", folder); projectId = projects.Resolve(null, folder); }
      if (projectId is not null) ctx.Require("projects", projectId);
      // A session's task read defaults to its registered project. all_projects is
      // explicit and still filtered by current grants; it never grants more access.
      if (projectId is null && !B(args, "all_projects")) projectId = HomeProject();
      var filter = new TaskFilter(projectId, Status: S(args, "status") ?? "all", Assignee: S(args, "assignee") ?? "", Archived: B(args, "archived"), Trash: S(args, "do") == "trash");
      var limit = args.TryGetProperty("limit", out var n) ? n.GetInt32() : 200;
      return Value(new { tasks = tasks.List(filter).Where(Visible).Take(limit).Select(View), statuses = TaskStatuses.All });
    }
    if (id == "tasks.local_change" && R(args, "do") == "create")
    {
      // "project" is a folder; AIs also pass the project's name or id there.
      var named = S(args, "project") is { } given && !LooksLikeFolder(given) ? projects.List().SingleOrDefault(p => p.Id == given || p.Name.Equals(given.Trim(), StringComparison.OrdinalIgnoreCase)) : null;
      if (S(args, "project") is { } spelled && !LooksLikeFolder(spelled) && named is null) throw new McpRefusal("Choose a project folder, or the exact name of one of this caller's projects.");
      var projectId = S(args, "projectId") ?? named?.Id ?? (S(args, "project") is { } f ? projects.Resolve(null, f) : HomeProject() ?? ProjectIdentity.IndependentId);
      var folder = (named is null ? S(args, "project") : null) ?? projects.Get(projectId).HomeFolder;
      Project(projectId, folder); ctx.Require("tasks", "*");
      // Patch reads "project" as the folder again; a project name must not become one.
      var draft = Patch(new(R(args, "title"), ProjectId: projectId, Folder: folder), args) with { ProjectId = projectId, Folder = folder };
      // Validate and authorize the requested agent before even creating the row.
      var assignee = Canonical(draft.Assignee);
      if (assignee is not ("me" or "none")) { RequireAgent(ctx, assignee); if (recipient(assignee) is null) throw new McpRefusal("Choose a current agent before creating this task."); }
      await ctx.EnsureCurrentAsync(ct);
      var row = tasks.Create(draft with { Assignee = assignee == "none" ? "none" : "me" }, Actor());
      if (assignee is not ("me" or "none")) row = await Assign(row.Id, assignee, Actor(row));
      return View(row);
    }
    var task = TaskOf(trash: S(args, "do") == "restore" || id == "tasks.get" || id == "tasks.local" && S(args, "do") is "get" or "comments" or "activity"); var by = Actor(task);
    if (id == "tasks.get" || id == "tasks.local" && S(args, "do") == "get") return Value(new { task = View(task), details = task.Details, runs = tasks.Runs(task.Id), mentions = tasks.Mentions(task.Id) });
    if (id == "tasks.local") return S(args, "do") switch
    {
      "comments" => Value(new { comments = task.Comments }), "activity" => Value(new { activity = task.Activity }),
      _ => throw new McpRefusal("Choose a supported task read.")
    };
    await ctx.EnsureCurrentAsync(ct);
    if (id == "tasks.local_change" && S(args, "do") == "duplicate")
    {
      ctx.Require("tasks", "*"); return View(tasks.Duplicate(task.Id, by, S(args, "title")));
    }
    if (id == "tasks.comment" || id == "tasks.local_change" && S(args, "do") == "comment")
    {
      var body = id == "tasks.comment" ? R(args, "body") : R(args, "text");
      foreach (var mention in MentionIds(body))
      {
        if (mention.StartsWith("session:", StringComparison.Ordinal)) ctx.Require("sessions", mention[8..]);
        else if (mention is not ("me" or "none")) RequireAgent(ctx, mention);
        if (recipient(mention) is { } target)
        {
          TaskMentionPolicy.RequireNotSelf(by, ctx.Grant.SessionId, target);
          if (target.SessionId is { } targetSession) ctx.Require("sessions", targetSession);
        }
      }
      var authority = new TaskMentionAuthorization(ctx.Grant.CallerId, ctx.Grant.SessionId, ctx.Grant.SeatId, async (target, token) =>
      {
        ctx.Require("projects", task.ProjectId);
        if (task.Folder.Length > 0) ctx.Require("folders", task.Folder);
        ctx.Require("sessions", target.SessionId ?? throw new McpRefusal("Choose a running agent chat for this mention."));
        TaskMentionPolicy.RequireNotSelf(by, ctx.Grant.SessionId, target);
        await ctx.EnsureCurrentAsync(token);
      });
      var comment = await tasks.CommentAsync(task.Id, body, by, S(args, "reply_to"), ct, authority); return Value(new { posted = true, comment });
    }
    if (id == "tasks.set_status") return View(tasks.Status(task.Id, R(args, "status"), by));
    if (id is "tasks.retry" or "tasks.reassign" || id == "tasks.local_change" && S(args, "do") == "assign")
    {
      var agent = Canonical(id == "tasks.retry" ? task.Assignee : R(args, id == "tasks.reassign" ? "agent" : "assignee"));
      if (agent is not ("me" or "none")) RequireAgent(ctx, agent);
      return View(await Assign(task.Id, agent, by));
    }
    if (id == "tasks.local_change") return R(args, "do") switch
    {
      "detail" => Detail(), "update" => Update(), "status" => View(tasks.Status(task.Id, R(args, "status"), by)),
      "archive" => View(tasks.Archive(task.Id, true, by)), "unarchive" => View(tasks.Archive(task.Id, false, by)),
      "delete" => View(tasks.Delete(task.Id, by)), "restore" => View(tasks.Restore(task.Id, by)),
      _ => throw new McpRefusal("Choose a supported task change.")
    };
    throw new McpRefusal("This task action is unavailable.");
    JsonElement Detail()
    {
      var action = R(args, "detail_action");
      if (action is "share" or "share-primary")
      {
        var person = R(args, "value");
        if (person.StartsWith("session:", StringComparison.Ordinal)) ctx.Require("sessions", person[8..]);
        else if (person != "me") RequireAgent(ctx, person);
      }
      if (action == "attach") ctx.Require("folders", S(args, "value") ?? "");
      if (action == "relate") _ = TaskOfRelated();
      return View(tasks.Detail(task.Id, action, S(args, "key"), S(args, "value"), by));
    }
    DeckTask TaskOfRelated()
    {
      var other = tasks.Get(R(args, "value"));
      if (!Visible(other)) throw new McpRefusal("The related task is outside this caller’s access.");
      return other;
    }
    JsonElement Update()
    {
      var draft = Patch(TaskService.Draft(task), args);
      if (args.TryGetProperty("projectId", out _) && !args.TryGetProperty("project", out _)) draft = draft with { Folder = projects.Get(draft.ProjectId).HomeFolder };
      Project(draft.ProjectId, draft.Folder ?? projects.Get(draft.ProjectId).HomeFolder);
      return View(tasks.Update(task.Id, draft, by, task.Revision));
    }
  }
  private static bool LooksLikeFolder(string value) => value.Length > 2 && (char.IsAsciiLetter(value[0]) && value[1] == ':' || value.StartsWith("\\\\", StringComparison.Ordinal) || value.StartsWith("//", StringComparison.Ordinal)) || value.StartsWith('/');
  private static IEnumerable<string> MentionIds(string body) => System.Text.RegularExpressions.Regex.Matches(body, @"(?<![\w@])@(?:\[([^\]\r\n]{1,160})\]|([a-zA-Z0-9][a-zA-Z0-9_:/-]{0,159}))")
    .Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value);
  private static void RequireAgent(McpCallContext ctx, string id)
  {
    if (id.StartsWith("lead:", StringComparison.Ordinal)) { ctx.Require("projects", id[5..]); ctx.Require("agents", id); }
    else ctx.Require("agents", id);
  }
  private static TaskDraft Patch(TaskDraft d, JsonElement a)
  {
    string? Pick(string key, string? fallback) => a.TryGetProperty(key, out _) ? S(a, key) : fallback;
    return d with { Title = Pick("title", d.Title)!, Details = Pick("details", d.Details)!, Status = Pick("status", d.Status)!,
      Assignee = Pick("assignee", d.Assignee)!, ProjectId = Pick("projectId", d.ProjectId)!, Folder = Pick("project", d.Folder),
      Priority = Pick("priority", d.Priority), StartDate = Pick("start_date", d.StartDate), DueDate = Pick("due_date", d.DueDate),
      StartTime = Pick("start_time", a.TryGetProperty("start_date", out var startDate) && startDate.ValueKind == JsonValueKind.Null ? null : d.StartTime), DueTime = Pick("due_time", a.TryGetProperty("due_date", out var dueDate) && dueDate.ValueKind == JsonValueKind.Null ? null : d.DueTime),
      GoalId = Pick("goalId", d.GoalId), Type = Pick("type", d.Type)!, Board = Pick("board", d.Board), Labels = a.TryGetProperty("labels", out var labels) ? labels.EnumerateArray().Select(x => x.GetString()!).ToImmutableArray() : d.Labels };
  }
  public JsonElement View(DeckTask task) => Value(new
  {
    task = task.Id, title = task.Title, status = task.Status, assignee = task.Assignee, assigneeName = task.Assignee switch { "me" => "You", "none" => "Unassigned", _ => recipient(task.Assignee)?.Name ?? task.Assignee },
    project = task.Folder, projectId = task.ProjectId, priority = task.Priority, startDate = task.StartDate, dueDate = task.DueDate, startTime = task.StartTime, dueTime = task.DueTime, labels = task.Labels,
    extras = TaskExtras.Of(task), participants = TaskExtras.Of(task).Participants, goalId = task.GoalId, type = task.Type, board = task.Board, archived = task.Archived, deletedAt = task.DeletedAt, needsYou = task.NeedsYou,
    agentWorking = tasks.Runs(task.Id).Any(r => r.Id == task.CurrentRunId && r.State == TaskRunState.Working), revision = task.Revision
  });
  public static JsonElement Value(object? value) => JsonSerializer.SerializeToElement(value, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
  private static string? S(JsonElement a, string k) => a.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
  private static string R(JsonElement a, string k) => S(a, k) is { Length: > 0 } s ? s : throw new McpRefusal("Give " + k + " for this task action.");
  private static bool B(JsonElement a, string k) => a.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
  private static object Words(params string[] values) => new { type = "string", @enum = values };
  private static McpToolSpec Spec(string id, McpTier tier, string[] required, params (string Key, object Shape)[] fields) => new(id, id.Replace('.', '_'), tier,
    Value(new { type = "object", properties = fields.ToDictionary(f => f.Key, f => f.Shape), required, additionalProperties = false }));
  private static IReadOnlyList<McpToolSpec> MakeSpecs()
  {
    var fields = new (string, object)[] { ("task", Text), ("title", Text), ("details", Text), ("status", Words([.. TaskStatuses.All])), ("assignee", Text), ("project", Text), ("projectId", Text),
      ("priority", NullableText), ("start_date", NullableText), ("due_date", NullableText), ("start_time", NullableText), ("due_time", NullableText), ("labels", new { type = "array", items = Text }), ("board", NullableText), ("text", Text), ("reply_to", Text), ("type", Words("Task", "Milestone")), ("goalId", NullableText) };
    return [
      Spec("tasks.local", McpTier.Read, ["do"], ("do", Words("list", "get", "comments", "activity", "trash")), ("task", Text), ("status", Text), ("assignee", Text), ("archived", Bool),
        ("limit", new { type = "integer", minimum = 1, maximum = 200 }), ("project", Text), ("all_projects", Bool)),
      Spec("tasks.local_change", McpTier.Act, ["do"], [("do", Words("create", "update", "status", "assign", "comment", "archive", "unarchive", "delete", "restore", "duplicate", "detail")), ("detail_action", Text), ("key", NullableText), ("value", NullableText), .. fields]),
      Spec("tasks.list", McpTier.Read, [], ("project", Text), ("all_projects", Bool)),
      Spec("tasks.get", McpTier.Read, ["task"], ("task", Text)),
      Spec("tasks.comment", McpTier.Act, ["task", "kind", "body"], ("task", Text), ("kind", Words("progress", "blocker", "question", "completion")), ("body", Text)),
      Spec("tasks.set_status", McpTier.Act, ["task", "status"], ("task", Text), ("status", Words([.. TaskStatuses.All]))),
      Spec("tasks.retry", McpTier.Alter, ["task"], ("task", Text)),
      Spec("tasks.reassign", McpTier.Alter, ["task", "agent"], ("task", Text), ("agent", Text)),
      Spec("tasks.goals", McpTier.Read, ["do"], ("do", Words("list", "get", "save", "delete")), ("id", Text), ("title", Text), ("description", Text), ("status", Words("planned", "active", "achieved", "cancelled")), ("projectId", Text), ("parentId", NullableText), ("revision", new { type = "integer", minimum = 1 })),
      Spec("tasks.views", McpTier.Read, ["do"], ("do", Words("list", "update", "save", "delete", "rename", "select", "revert")), ("id", Text), ("name", Text), ("state", Value(new { type = "object", properties = new Dictionary<string, object>
      { ["projectId"] = NullableText, ["projectIds"] = new { type = "array", items = Text }, ["statuses"] = new { type = "array", items = Words([.. TaskStatuses.All]) }, ["assignees"] = new { type = "array", items = Text }, ["goalId"] = NullableText, ["search"] = Text, ["status"] = Text, ["assignee"] = Text, ["groupBy"] = Words("date", "due", "status", "assignee", "priority", "tags", "type", "board", "project", "single", "none"),
        ["due"] = Words("any", "overdue", "today", "week", "none"), ["sort"] = Words("automatic", "due", "priority", "name", "created"), ["descending"] = Bool, ["needsYouOnly"] = Bool, ["view"] = Words("List", "Board", "Calendar"),
        ["columns"] = new { type = "array", items = Words([.. TaskPresentation.ColumnKeys]) }, ["columnOrder"] = new { type = "array", items = Words([.. TaskPresentation.ColumnKeys]) }, ["archived"] = Bool, ["trash"] = Bool, ["source"] = NullableText }, additionalProperties = false }))),
      Spec("connected_tasks.connect", McpTier.Alter, ["name", "url"], ("name", Text), ("url", Text), ("projectId", Text), ("changes", Words("off", "ask", "allow"))),
      Spec("connected_tasks.hand_to_agent", McpTier.Alter, ["task", "agent"], ("system", Text), ("task", Text), ("agent", Text), ("project", Text)),
      Spec("connected_tasks.systems", McpTier.Read, [], ("projectId", Text)),
      Spec("connected_tasks.list", McpTier.Read, [], ("system", Text), ("search", Text), ("include_done", Bool)),
      Spec("connected_tasks.get", McpTier.Read, ["task"], ("system", Text), ("task", Text)),
      Spec("connected_tasks.update", McpTier.Alter, ["task"], ("system", Text), ("task", Text), ("status", Text), ("due_date", Text), ("assignee", Text), ("confirm", Bool)),
      Spec("connected_tasks.comment", McpTier.Alter, ["task", "body"], ("system", Text), ("task", Text), ("body", Text))
    ];
  }
}
