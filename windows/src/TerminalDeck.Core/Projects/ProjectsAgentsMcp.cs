using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Projects;

public sealed record ProjectAgentTool(McpToolSpec Spec, McpToolHandler Handler);
public interface IProjectAgentPageActions
{
  ValueTask OpenAgentAsync(string id, CancellationToken cancellationToken);
  ValueTask OpenSetupAsync(string? projectId, string? folder, string? step, CancellationToken cancellationToken);
}

// Definitions are contributions to the app's existing authenticated tool door.
// They never open a second listener or bypass its approval broker.
public sealed class ProjectsAgentsMcp(IProjects projects, IAgents agents, IProjectFolders folders,
  Func<IReadOnlyList<ProjectSession>> sessions, AccountService? accounts = null, IProjectAgentPageActions? pages = null)
{
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
  private static readonly object Text = new { type = "string" };
  private static readonly object NullableText = new { type = new[] { "string", "null" } };
  private static readonly object Record = new { type = "object" };
  private static readonly object Strings = new { type = "array", items = Text };
  public static IReadOnlyList<McpToolSpec> Specs { get; } = MakeSpecs();
  public IReadOnlyList<ProjectAgentTool> Contributions() => Specs.Where(s => pages is not null || s.Id is not ("agents.open_profile" or "project_setup.open"))
    .Select(spec => new ProjectAgentTool(spec, (context, args, ct) => CallAsync(spec.Id, context, args, ct))).ToArray();
  public void Register(McpDoor door)
  {
    var known = McpCatalogue.Load().ToDictionary(s => s.Id);
    var rows = Contributions();
    if (rows.Any(r => !known.TryGetValue(r.Spec.Id, out var spec) || spec.Tier != r.Spec.Tier || !JsonElement.DeepEquals(spec.InputSchema, r.Spec.InputSchema)))
      throw new InvalidOperationException("The project and agent contracts must be installed in the central tool catalogue before registering these handlers.");
    if (McpCatalogue.EffectiveTier(Specs.Single(s => s.Id == "tasks.agents"), Value(new { @do = "save" })) != McpTier.Alter)
      throw new InvalidOperationException("Agent profile changes need the central tasks.agents permission rule.");
    try { McpSchema.Validate(Specs.Single(s => s.Id == "project_registry.switch").InputSchema, Value(new { projectId = (string?)null })); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { throw new InvalidOperationException("The central tool validator needs nullable project and agent arguments."); }
    foreach (var row in rows) door.Register(row.Spec.Id, row.Handler);
  }
  public static McpTier Tier(McpToolSpec spec, JsonElement args) => spec.Id == "tasks.agents" && S(args, "do") != "list" ? McpTier.Alter : spec.Tier;
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.Single(s => s.Id == tool);
    ProjectAgentSchema.Validate(spec.InputSchema, args);
    var tier = Tier(spec, args);
    if (!context.Grant.Tiers.Contains(tier)) throw new McpRefusal("This caller cannot make that change.");
    // A mixed read/write contract must never be installed behind a read-only gate.
    if (tool == "tasks.agents" && tier == McpTier.Alter && McpCatalogue.EffectiveTier(spec, args) != tier)
      throw new McpRefusal("Agent profile changes need the current tool permission service.");
    if (tier != McpTier.Read && context.Grant.PermissionMode == AiPermissionMode.Plan) throw new McpRefusal("This AI is in planning mode. Choose a mode that allows changes first.");
    await context.EnsureCurrentAsync(ct);
    bool CanProject(string id) => context.Has("projects", id);
    Project Project(string id) { context.Require("projects", id); return projects.Get(id); }
    SavedAgent Agent(string id) { context.Require("agents", id); var row = agents.Get(id); context.Require("projects", row.ProjectId); return row; }
    void Folders(IEnumerable<string> paths) { foreach (var path in paths) context.Require("folders", path); }
    var visible = agents.List().Where(a => context.Has("agents", a.Id) && CanProject(a.ProjectId)).ToArray();
    switch (tool)
    {
      case "projects.logo_suggestions":
      {
        IReadOnlyList<string> roots = S(args, "path") is { } path ? [path] : S(args, "projectId") is { } id ? Project(id).Folders : [];
        if (roots.Count == 0) throw new McpRefusal("Choose a project or folder for logo suggestions.");
        foreach (var root in roots) context.Require("folders", root);
        return Value(new { suggestions = ProjectLogoSuggestions.Find(roots) });
      }
      case "projects.create_folder":
      {
        if (!context.Grant.Attended) throw new McpRefusal("Creating a folder needs the person present.");
        var parent = Required(args, "parent"); context.Require("folders", parent); await context.EnsureCurrentAsync(ct);
        return Value(new { folder = projects.CreateFolder(parent, Required(args, "name")), registeredProject = false });
      }
      case "project_registry.list":
        return Value(new { projects = projects.List().Where(p => CanProject(p.Id)).Select(ProjectView), activeProjectId = projects.ActiveProjectId is { } active && CanProject(active) ? active : null });
      case "projects.list": return Value(projects.List().Where(p => p.IsOpen && CanProject(p.Id)).Select(ProjectView));
      case "project_registry.resolve":
      {
        if (S(args, "folder") is { } folder) context.Require("folders", folder);
        var id = projects.Resolve(S(args, "projectId"), S(args, "folder")); context.Require("projects", id); return Value(new { projectId = id });
      }
      case "project_registry.switch":
      {
        var id = S(args, "projectId"); if (id is null) context.Require("settings", "projects"); else _ = Project(id);
        await context.EnsureCurrentAsync(ct); projects.Select(id); return Value(new { activeProjectId = id });
      }
      case "project_registry.save":
      {
        var id = Required(args, "id"); context.Require("projects", id);
        var paths = args.GetProperty("folders").EnumerateArray().Select(p => p.GetString()!).ToImmutableArray(); Folders(paths);
        var before = projects.List().FirstOrDefault(p => p.Id == id);
        if (before is null) context.Require("settings", "projects");
        if (S(args, "logo") is { Length: > 0 } source) context.Require("folders", Path.GetDirectoryName(source) ?? source);
        await context.EnsureCurrentAsync(ct);
        var saved = projects.Save(new(id, Required(args, "name"), paths, S(args, "icon"), S(args, "colour")), before, createOnly: before is null);
        if (args.TryGetProperty("logo", out _)) saved = projects.SetPicture(id, S(args, "logo"));
        return Value(ProjectView(saved));
      }
      case "project_registry.remove_empty":
        _ = Project(Required(args, "id")); await context.EnsureCurrentAsync(ct); projects.RemoveEmpty(Required(args, "id")); return Value(new { removed = true });
      case "project_registry.set_lead":
      {
        var p = Project(Required(args, "projectId")); var lead = S(args, "lead");
        if (lead?.StartsWith("agent:", StringComparison.Ordinal) == true)
        {
          var a = Agent(lead[6..]); await context.EnsureCurrentAsync(ct); agents.SetProjectLead(p.Id, a.Id);
        }
        else if (lead?.StartsWith("session:", StringComparison.Ordinal) == true)
        {
          var id = lead[8..]; context.Require("sessions", id);
          var row = sessions().SingleOrDefault(s => s.Id == id) ?? throw new McpRefusal("Choose a current session.");
          if (projects.Resolve(row.ProjectId, row.Folder) != p.Id) throw new McpRefusal("Choose a session in this project.");
          await context.EnsureCurrentAsync(ct); projects.SetLead(p.Id, lead, S(args, "leadName") ?? row.Title);
        }
        else if (lead is null) { await context.EnsureCurrentAsync(ct); agents.SetProjectLead(p.Id, null); }
        else throw new McpRefusal("Choose agent:<id>, session:<id> or null for the lead.");
        return Value(ProjectView(projects.Get(p.Id)));
      }
      case "project_registry.filter":
      {
        var id = args.TryGetProperty("projectId", out _) ? S(args, "projectId") : projects.ActiveProjectId;
        if (id is not null) _ = Project(id);
        var kind = Required(args, "kind");
        object rows = kind switch
        {
          "agents" => visible.Where(a => id is null || a.ProjectId == id).Select(AgentView).ToArray(),
          "settings" => projects.List().Where(p => CanProject(p.Id) && (id is null || p.Id == id)).Select(p => new { projectId = p.Id, values = SettingsView(p) }).ToArray(),
          _ => throw new McpRefusal("This Windows contribution currently supplies agents and settings. Other resource owners register their own reads.")
        };
        return Value(new { kind, projectId = id, rows });
      }
      case "projects.browse":
      {
        var path = S(args, "path") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); context.Require("folders", path); var rows = folders.Browse(path, B(args, "showHidden"));
        return Value(new { path, folders = rows.Take(300).Select(f => new { name = f.Name, path = f.Path, repo = f.Repository, open = projects.List().Any(p => p.IsOpen && CanProject(p.Id) && p.Folders.Any(pf => ProjectPaths.Equal(pf, f.Path))) }), more = rows.Count > 300 });
      }
      case "projects.add":
      {
        var path = Required(args, "path"); context.Require("folders", path); var id = projects.Resolve(null, path); _ = Project(id);
        await context.EnsureCurrentAsync(ct); return Value(ProjectView(projects.OpenFolder(path)));
      }
      case "projects.remove":
      {
        var path = Required(args, "path"); context.Require("folders", path); var p = Project(projects.Resolve(null, path));
        if (p.Id == ProjectIdentity.IndependentId) throw new McpRefusal("That folder is not a named project.");
        await context.EnsureCurrentAsync(ct); projects.SetOpen(p.Id, false);
        return Value(new { removed = true, stillRunning = sessions().Where(s => context.Has("sessions", s.Id) && projects.Resolve(s.ProjectId, s.Folder) == p.Id).Select(s => s.Id) });
      }
      case "projects.logo":
      {
        var id = Required(args, "project"); _ = Project(id); var path = S(args, "path");
        if (path is not null) context.Require("folders", Path.GetDirectoryName(path) ?? path);
        await context.EnsureCurrentAsync(ct); return Value(ProjectView(projects.SetPicture(id, path)));
      }
      case "project_settings.get": return Value(new { projectId = Required(args, "projectId"), values = SettingsView(Project(Required(args, "projectId"))) });
      case "project_settings.set":
      {
        var id = Required(args, "projectId"); _ = Project(id);
        var values = args.GetProperty("values").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
        if (values.TryGetValue("whoUsesWhat", out var choices) && choices.ValueKind == JsonValueKind.Array)
          foreach (var choice in choices.EnumerateArray()) if (S(choice, "accountId") is { } accountId)
          {
            context.Require("accounts", accountId);
            if (accounts is null || accounts.Get(accountId).Provider != Required(choice, "provider")) throw new McpRefusal("Choose an account for the selected AI.");
          }
        await context.EnsureCurrentAsync(ct); var p = projects.PatchSettings(id, values); return Value(new { projectId = id, values = SettingsView(p) });
      }
      case "project_setup.guide": return Value(ProjectSetup.GuideSteps.Select((name, i) => new { number = i + 1, name, required = i < 2, skippable = i >= 2 }));
      case "project_setup.status":
      {
        var id = S(args, "projectId"); if (id is not null) _ = Project(id);
        return Value(projects.List().Where(p => p.Id != ProjectIdentity.IndependentId && CanProject(p.Id) && (id is null || p.Id == id)).Select(p => new { projectId = p.Id, score = projects.Setup(p.Id, visible.Select(a => new ProjectSetupAgent(a.Id, a.ProjectId, a.Skills, a.Status == SavedAgentStatus.Archived)), context.Has("memory", "lead:" + p.Id) ? agents.Seats().FirstOrDefault(s => s.SeatKey == "lead:" + p.Id)?.Card : null) }));
      }
      case "project_setup.open":
        if (S(args, "projectId") is { } setupId) _ = Project(setupId);
        if (S(args, "folder") is { } setupFolder) context.Require("folders", setupFolder);
        if (pages is null) throw new McpRefusal("No project window is connected.");
        await context.EnsureCurrentAsync(ct); await pages.OpenSetupAsync(S(args, "projectId"), S(args, "folder"), S(args, "step"), ct); return Value(new { opened = true });
      case "agents.directory":
      {
        var query = S(args, "query") ?? ""; var project = S(args, "project");
        var rows = visible.Where(a => (project is null || a.ProjectId == project || projects.List().FirstOrDefault(p => p.Id == a.ProjectId)?.Name.Equals(project, StringComparison.OrdinalIgnoreCase) == true) &&
          (a.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || a.Description.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        var group = S(args, "group") ?? "project";
        return Value(new { agents = rows.Select(AgentView), activity = rows.ToDictionary(a => a.Id, Activity), groups = rows.GroupBy(a => group == "reportsTo" ? a.ReportsTo ?? "Independent" : a.ProjectId).Select(g => new { title = g.Key, agents = g.Select(a => a.Id) }), total = rows.Length });
      }
      case "agents.profile":
      {
        var id = Required(args, "id");
        if (id == AgentSeats.HootId) { context.Require("agents", id); return Value(new { id, name = "Hoot", category = "orchestrator", description = "Gives leads their goals and assigns agents in projects with no lead." }); }
        var a = Agent(id);
        return Value(new { agent = AgentView(a), activity = Activity(a), memory = context.Has("memory", agents.SeatOf(a.Id).Key) ? agents.SeatMemory(a.Id) : null, pictureChoices = new { symbols = AgentPictures.Symbols, colours = ProjectIdentity.Colours, emojiFormat = "emoji:<one emoji>@<colour>" }, reports = visible.Where(r => r.ReportsTo == id).Select(AgentView), hands = agents.Runs().Where(r => r.AgentId == id && context.Has("sessions", r.SessionId)) });
      }
      case "agents.org_chart":
      {
        object Node(SavedAgent a) => new { agent = AgentView(a), reports = visible.Where(v => v.ReportsTo == a.Id).Select(Node).ToArray() };
        return Value(new { trees = visible.Where(a => a.ReportsTo == AgentSeats.HootId).Select(Node), independent = visible.Where(a => a.ReportsTo is null || !visible.Any(v => v.Id == a.ReportsTo) && a.ReportsTo != AgentSeats.HootId).Select(Node) });
      }
      case "agents.duplicate":
      {
        var source = Agent(Required(args, "id")); context.Require("agents", "*"); context.Require("settings", "agents"); context.Require("memory", "*");
        if (source.AccountId is { } account) context.Require("accounts", account);
        if (source.InstructionsFile is { } file) context.Require("folders", Path.GetDirectoryName(file) ?? file);
        await context.EnsureCurrentAsync(ct); return Value(AgentView(agents.Duplicate(source.Id, S(args, "name"))));
      }
      case "agents.set_icon":
      {
        var a = Agent(Required(args, "id")); await context.EnsureCurrentAsync(ct); return Value(AgentView(agents.Save(a with { Icon = S(args, "icon") ?? "person" }, a)));
      }
      case "agents.set_reports_to":
      {
        var a = Agent(Required(args, "id")); var boss = S(args, "reportsTo"); if (boss is not null) context.Require("agents", boss);
        await context.EnsureCurrentAsync(ct); return Value(AgentView(agents.Save(a with { ReportsTo = boss }, a)));
      }
      case "agents.set_role":
      {
        var a = Agent(Required(args, "agent")); await context.EnsureCurrentAsync(ct); return Value(AgentView(agents.Save(a with { Seat = S(args, "role") ?? a.Id[..Math.Min(64, a.Id.Length)] }, a)));
      }
      case "agents.edit_profile":
      {
        var a = Agent(Required(args, "id")); return await SaveAgentAsync(a, args.GetProperty("fields"), context, ct);
      }
      case "agents.skills":
      {
        var folders = S(args, "agent") is { } who ? Project(Agent(who).ProjectId).Folders : S(args, "projectId") is { } pid ? Project(pid).Folders : [];
        foreach (var f in folders) context.Require("folders", f);
        var assigned = S(args, "agent") is { } owner ? agents.Get(owner).Skills : [];
        return Value(new { installed = AgentSkills.Find(AgentSkills.Roots(folders)).Select(k => new { k.Name, k.Description, k.Where, assigned = !assigned.IsDefault && assigned.Contains(k.Name) }), assigned = assigned.IsDefault ? [] : assigned });
      }
      case "agents.stop_hands":
      {
        var a = Agent(Required(args, "agent"));
        foreach (var run in agents.Runs().Where(r => r.AgentId == a.Id && r.State != AgentRunState.Ended)) context.Require("sessions", run.SessionId);
        await context.EnsureCurrentAsync(ct); return Value(new { stopped = await agents.StopHandsAsync(a.Id, ct) });
      }
      case "memory.notes.save":
      {
        var seat = AgentSeats.Parse(S(args, "seat") is { } named ? named == "hoot" ? "orchestrator" : named : context.Grant.SeatId ?? "orchestrator"); context.Require("memory", seat.Key);
        if (seat.ProjectId is { } project) _ = Project(project);
        var old = agents.Seats().FirstOrDefault(s => s.SeatKey == seat.Key);
        await context.EnsureCurrentAsync(ct); return Value(agents.SaveSeatMemory(seat.Key, old?.Card ?? "", Required(args, "text", empty: true), old ?? new AgentSeatMemory(seat.Key)));
      }
      case "agents.hands": return Value(agents.Runs().Where(r => r.AgentId is { } id && context.Has("agents", id) && CanProject(r.ProjectId) && context.Has("sessions", r.SessionId) && r.State != AgentRunState.Ended));
      case "agents.add_hand":
      {
        var a = Agent(Required(args, "agent")); var p = Project(a.ProjectId);
        return await StartAsync(new(a.Id, p.Id, Mode: "chat", Job: Required(args, "job") + (S(args, "details") is { Length: > 0 } details ? "\n\n" + details : ""), Helper: B(args, "helper")), context, ct);
      }
      case "agents.open_profile":
      {
        var id = Required(args, "agent"); if (id == AgentSeats.HootId) context.Require("agents", id); else _ = Agent(id);
        if (pages is null) throw new McpRefusal("No agent window is connected.");
        await context.EnsureCurrentAsync(ct); await pages.OpenAgentAsync(id, ct); return Value(new { opened = true });
      }
      case "tasks.agents":
      {
        var action = Required(args, "do");
        if (action == "list") return Value(visible.Select(AgentView));
        if (action == "save-many") throw new McpRefusal("Save one agent at a time in this Windows contribution.");
        if (action == "save")
        {
          var patch = args.GetProperty("agent"); var id = S(patch, "id") ?? agents.NewId(Required(patch, "name"));
          context.Require("agents", id);
          var old = agents.List().FirstOrDefault(a => a.Id == id);
          if (old is null) context.Require("settings", "agents");
          return await SaveAgentAsync(old ?? new(id, Required(patch, "name"), S(patch, "provider") ?? "claude"), patch, context, ct, create: old is null);
        }
        var a = Agent(Required(args, "id")); await context.EnsureCurrentAsync(ct);
        if (action == "remove") { agents.Remove(a.Id); return Value(new { removed = true }); }
        var status = action switch { "pause" => SavedAgentStatus.Paused, "archive" => SavedAgentStatus.Archived, "resume" or "restore" => SavedAgentStatus.Active, _ => throw new McpRefusal("Choose list, save, remove, pause, resume, archive or restore.") };
        return Value(AgentView(agents.Save(a with { Status = status }, a)));
      }
      case "memory.template.read":
        context.Require("settings", "agent-templates"); return Value(TemplateView(agents.Templates().Single(t => t.Category == Category(Required(args, "category")))));
      case "memory.template.save":
      {
        context.Require("settings", "agent-templates"); var old = agents.Templates().Single(t => t.Category == Category(Required(args, "category")));
        var row = old with { Instructions = S(args, "card") ?? old.Instructions, Checklist = S(args, "checklist") ?? old.Checklist, HelperAI = S(args, "helperAI") ?? old.HelperAI, HelperModel = S(args, "helperModel") ?? old.HelperModel,
          MaxHandsPerSeat = N(args, "handsPerSeat", old.MaxHandsPerSeat), MaxHandsPerProject = N(args, "handsPerProject", old.MaxHandsPerProject), CardLimit = N(args, "cardLimit", old.CardLimit),
          Parts = args.TryGetProperty("parts", out var parts) ? parts.EnumerateArray().Select(p => p.GetString()!).ToImmutableArray() : old.Parts };
        await context.EnsureCurrentAsync(ct); agents.SaveTemplate(row, old); return Value(TemplateView(row));
      }
      case "memory.card.read":
      {
        // Mac DeckMemoryTools: your card is the category template followed by your seat's own additions.
        var seat = AgentSeats.Parse(S(args, "seat") is { } named ? named == "hoot" ? "orchestrator" : named : context.Grant.SeatId ?? "orchestrator"); context.Require("memory", seat.Key);
        var row = agents.Seats().FirstOrDefault(s => s.SeatKey == seat.Key) ?? new AgentSeatMemory(seat.Key);
        var shared = agents.Templates().FirstOrDefault(t => t.Category == seat.Category)?.Instructions ?? "";
        var card = string.Join("\n\n", new[] { shared, row.Card }.Where(t => t.Length > 0));
        return Value(new { seat = seat.Key, category = seat.Category.ToString().ToLowerInvariant(), card, sharedByTheCategory = shared, thisSeatsOwn = row.Card, notes = row.Notes });
      }
      case "memory.card.save":
      {
        // With no seat named, a session saves to its own seat; Hoot's desk is the orchestrator seat.
        var seat = AgentSeats.Parse(S(args, "seat") is { } named ? named == "hoot" ? "orchestrator" : named : context.Grant.SeatId ?? "orchestrator"); context.Require("memory", seat.Key);
        if (seat.ProjectId is { } project) _ = Project(project);
        var old = agents.Seats().FirstOrDefault(s => s.SeatKey == seat.Key);
        await context.EnsureCurrentAsync(ct); return Value(agents.SaveSeatMemory(seat.Key, Required(args, "text", empty: true), old?.Notes ?? "", old ?? new AgentSeatMemory(seat.Key)));
      }
      default: throw new McpRefusal("That project or agent tool is not connected.");
    }
  }
  public async ValueTask<JsonElement> StartAsync(NewAgentSession request, McpCallContext context, CancellationToken ct)
  {
    SavedAgent? agent = request.AgentId is { } id ? agents.Get(id) : null;
    if (agent is not null) context.Require("agents", agent.Id);
    var p = projects.Get(request.ProjectId ?? agent?.ProjectId ?? projects.ActiveProjectId ?? ProjectIdentity.IndependentId); context.Require("projects", p.Id);
    var folder = request.Folder ?? p.HomeFolder ?? throw new McpRefusal("Choose a session folder."); context.Require("folders", folder);
    var choice = p.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == (request.Mode == "chat" ? "chats" : "sessions"));
    var helperTemplate = request.Helper && agent is not null ? agents.Templates().Single(t => t.Category == agents.SeatOf(agent.Id).Category) : null;
    var provider = helperTemplate?.HelperAI ?? agent?.Provider ?? request.Provider ?? choice?.Provider ?? throw new McpRefusal("Choose an AI.");
    if (accounts is null) throw new McpRefusal("The account service is not connected.");
    var accountId = request.AccountId ?? (agent?.Provider == provider ? agent.AccountId : null) ?? (choice?.Provider == provider ? choice.AccountId : null) ?? accounts.Preferred(provider, folder, CallerAccount(context))?.Id;
    if (accountId is null) throw new McpRefusal("Choose an account for this AI."); context.Require("accounts", accounts.Get(accountId).Id);
    // Agent instructions are part of this agent's approved profile; arbitrary caller file paths are never read here.
    await context.EnsureCurrentAsync(ct);
    var run = await agents.StartAsync(request with { ProjectId = p.Id, Folder = folder, Provider = provider, AccountId = accountId }, ct, async (plan, token) =>
    {
      context.Require("projects", plan.ProjectId); context.Require("folders", plan.Folder); context.Require("accounts", plan.AccountId);
      if (plan.AgentId is { } owner) context.Require("agents", owner);
      await context.EnsureCurrentAsync(token);
    });
    context.NoteStarted(run.SessionId); return Value(run);
  }
  // The calling session's own account, from its grant (a chat's grant names exactly one).
  private static string? CallerAccount(McpCallContext context) => context.Grant.Resources.Where(r => r.StartsWith("accounts:", StringComparison.Ordinal)).Select(r => r[9..]).ToArray() is [var only] ? only : null;
  public McpToolHandler SessionStartHandler(McpToolHandler fallback) => async (context, args, ct) =>
  {
    if (!args.TryGetProperty("differ", out var differ) || S(differ, "agentId") is not { } id) return await fallback(context, args, ct);
    _ = Required(differ, "reason");
    if (differ.EnumerateObject().Any(p => p.Name is not ("agentId" or "reason"))) throw new McpRefusal("Use the saved agent's model, effort and instructions here. Change its profile to change those choices.");
    if (args.TryGetProperty("resume", out _) || args.TryGetProperty("conversation", out _) || args.TryGetProperty("brief", out _)) throw new McpRefusal("Start an agent's new session without resume or a separate brief.");
    return await StartAsync(new(id, S(args, "projectId"), Required(args, "cwd"), AccountId: S(args, "account"), Mode: S(args, "mode") ?? "chat", Job: S(args, "title") ?? S(args, "job") ?? ""), context, ct);
  };
  private async ValueTask<JsonElement> SaveAgentAsync(SavedAgent original, JsonElement patch, McpCallContext c, CancellationToken ct, bool create = false)
  {
    var allowed = new[] { "id", "name", "provider", "role", "description", "model", "effort", "projectId", "defaultProject", "seat", "reportsTo", "instructionsFile", "instructions", "icon", "skills", "accountId", "status", "expectedInstructions", "maxConcurrentTasks", "permissionMode", "workingFolder", "toolsPreferred", "toolsAvoided", "skillsOff" };
    if (patch.EnumerateObject().Any(p => !allowed.Contains(p.Name))) throw new McpRefusal("This profile field is not supported here. Use name, provider, role, model, effort, projectId, seat, reportsTo, instructions, icon, skills, accountId or status.");
    var projectId = S(patch, "projectId") ?? original.ProjectId;
    if (S(patch, "defaultProject") is { } folder) { c.Require("folders", folder); projectId = projects.Resolve(null, folder); }
    c.Require("projects", original.ProjectId); c.Require("projects", projectId);
    var boss = patch.TryGetProperty("reportsTo", out _) ? S(patch, "reportsTo") : original.ReportsTo;
    if (boss is not null) c.Require("agents", boss);
    var status = original.Status;
    if (S(patch, "status") is { } savedStatus && (!Enum.TryParse<SavedAgentStatus>(savedStatus, true, out status) || !Enum.IsDefined(status)))
      throw new McpRefusal("Choose active, paused or archived for the agent status.");
    var row = original with { MaxConcurrentTasks = patch.TryGetProperty("maxConcurrentTasks", out var cap) ? cap.ValueKind == JsonValueKind.Null ? null : cap.GetInt32() : original.MaxConcurrentTasks, Status = status, Name = S(patch, "name") ?? original.Name, Provider = S(patch, "provider") ?? original.Provider,
      Description = S(patch, "role") ?? S(patch, "description") ?? original.Description, Model = S(patch, "model") ?? original.Model, Effort = S(patch, "effort") ?? original.Effort,
      ProjectId = projectId, Seat = S(patch, "seat") ?? original.Seat, ReportsTo = boss, Icon = S(patch, "icon") ?? original.Icon,
      InstructionsFile = patch.TryGetProperty("instructionsFile", out _) ? S(patch, "instructionsFile") : original.InstructionsFile,
      AccountId = patch.TryGetProperty("accountId", out _) ? S(patch, "accountId") : original.AccountId,
      Skills = patch.TryGetProperty("skills", out var skills) ? skills.EnumerateArray().Select(s => s.GetString()!).ToImmutableArray() : original.Skills };
    var o = original.Settings;
    ImmutableArray<string> List(string key, ImmutableArray<string> fallback) => patch.TryGetProperty(key, out var v) ? v.ValueKind == JsonValueKind.Null ? [] : v.EnumerateArray().Select(x => x.GetString() ?? "").ToImmutableArray() : fallback;
    row = row with { Options = o with {
      PermissionMode = patch.TryGetProperty("permissionMode", out _) ? S(patch, "permissionMode") : o.PermissionMode,
      WorkingFolder = patch.TryGetProperty("workingFolder", out _) ? S(patch, "workingFolder") : o.WorkingFolder,
      ToolsPreferred = List("toolsPreferred", o.ToolsPreferred), ToolsAvoided = List("toolsAvoided", o.ToolsAvoided),
      SkillsOff = patch.TryGetProperty("skillsOff", out var off) ? off.ValueKind == JsonValueKind.True : o.SkillsOff } };
    if (row.Settings.WorkingFolder is { } working && working != o.WorkingFolder) c.Require("folders", working);
    if (row.AccountId is { } account) c.Require("accounts", account);
    if (row.InstructionsFile is { } file && file != original.InstructionsFile) c.Require("folders", Path.GetDirectoryName(file) ?? file);
    await c.EnsureCurrentAsync(ct); var saved = agents.Save(row, create ? null : original, createOnly: create);
    if (S(patch, "instructions") is { } body) { await c.EnsureCurrentAsync(ct); saved = agents.SaveInstructions(saved.Id, body, S(patch, "expectedInstructions")); }
    return Value(AgentView(saved));
  }
  private static object SettingsView(Project p) => p.Preferences.Values.SetItem("whoUsesWhat", Value(p.Preferences.WhoUsesWhat));
  private static object ProjectView(Project p) => new { p.Id, p.Name, path = p.HomeFolder, p.Folders, p.Icon, p.Colour, p.Logo, p.Lead, p.LeadName, p.IsOpen };
  private static object AgentView(SavedAgent a) => new { a.Id, a.Name, provider = a.Provider, role = a.Description, a.Model, a.Effort, a.ProjectId, a.Seat, a.ReportsTo, a.InstructionsFile, a.Icon, a.Status, a.MaxConcurrentTasks, skills = a.Skills.IsDefault ? [] : a.Skills, a.AccountId,
    permissionMode = a.Settings.PermissionMode, workingFolder = a.Settings.WorkingFolder, toolsPreferred = a.Settings.ToolsPreferred.IsDefault ? [] : a.Settings.ToolsPreferred,
    toolsAvoided = a.Settings.ToolsAvoided.IsDefault ? [] : a.Settings.ToolsAvoided, skillsOff = a.Settings.SkillsOff };
  private object Activity(SavedAgent a) { var x = AgentActivity.For(a, agents.Runs(), sessions()); return new { state = x.Wire, label = x.Label, live = x.Live, busy = x.Busy }; }
  private static object TemplateView(AgentTemplate t) => new { t.Category, card = t.Instructions, t.Checklist, parts = t.Parts.IsDefault ? [] : t.Parts, t.HelperAI, t.HelperModel, t.CardLimit, handsPerSeat = t.MaxHandsPerSeat, handsPerProject = t.MaxHandsPerProject };
  private static AgentCategory Category(string s) => Enum.TryParse<AgentCategory>(s, true, out var category) && Enum.IsDefined(category) ? category : throw new McpRefusal("Choose orchestrator, lead or agent.");
  private static JsonElement Value(object value) => JsonSerializer.SerializeToElement(value, Json);
  private static string? S(JsonElement a, string key) => a.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null ? value.GetString() : null;
  private static string Required(JsonElement a, string key, bool empty = false) => S(a, key) is { } s && (empty || !string.IsNullOrWhiteSpace(s)) ? s : throw new McpRefusal("Choose a value for " + key + ".");
  private static bool B(JsonElement a, string key) => a.TryGetProperty(key, out var value) && value.GetBoolean();
  private static int N(JsonElement a, string key, int fallback) => !a.TryGetProperty(key, out var value) ? fallback : value.TryGetInt32(out var n) ? n : throw new McpRefusal("Choose a whole number for " + key + ".");
  private static IReadOnlyList<McpToolSpec> MakeSpecs()
  {
    static object EnumOf(params string[] values) => new { type = "string", @enum = values };
    static McpToolSpec Spec(string id, McpTier tier, string[] required, params (string Name, object Shape)[] properties) => new(id, id.Replace('.', '_'), tier,
      Value(new { type = "object", properties = properties.ToDictionary(p => p.Name, p => p.Shape), required, additionalProperties = false }));
    return
    [
      Spec("project_registry.list", McpTier.Read, []),
      Spec("project_registry.resolve", McpTier.Read, [], ("folder", Text), ("projectId", Text)),
      Spec("project_registry.switch", McpTier.Alter, ["projectId"], ("projectId", NullableText)),
      Spec("project_registry.save", McpTier.Alter, ["id", "name", "folders"], ("id", Text), ("name", Text), ("folders", Strings), ("icon", Text), ("colour", Text), ("logo", Text)),
      Spec("project_registry.remove_empty", McpTier.Alter, ["id"], ("id", Text)),
      Spec("project_registry.set_lead", McpTier.Alter, ["projectId", "lead"], ("projectId", Text), ("lead", NullableText), ("leadName", Text)),
      Spec("project_registry.filter", McpTier.Read, ["kind"], ("kind", EnumOf("tasks", "agents", "servers", "task-sources", "routines", "receiver-sources", "artifacts", "settings")), ("projectId", NullableText)),
      Spec("projects.list", McpTier.Read, []),
      Spec("projects.logo_suggestions", McpTier.Read, [], ("projectId", Text), ("path", Text)),
      Spec("projects.create_folder", McpTier.Alter, ["parent", "name"], ("parent", Text), ("name", Text)),
      Spec("projects.browse", McpTier.Read, [], ("path", Text), ("showHidden", new { type = "boolean" })),
      Spec("projects.add", McpTier.Alter, ["path"], ("path", Text)),
      Spec("projects.remove", McpTier.Alter, ["path"], ("path", Text)),
      Spec("projects.logo", McpTier.Alter, ["project", "path"], ("project", Text), ("path", NullableText)),
      Spec("project_settings.get", McpTier.Read, ["projectId"], ("projectId", Text)),
      Spec("project_settings.set", McpTier.Alter, ["projectId", "values"], ("projectId", Text), ("values", Record)),
      Spec("project_setup.status", McpTier.Read, [], ("projectId", Text)),
      Spec("project_setup.guide", McpTier.Read, []),
      Spec("project_setup.open", McpTier.Act, [], ("projectId", Text), ("folder", Text), ("step", EnumOf("name", "folders", "lead", "team", "skills", "card", "connections", "review"))),
      Spec("agents.directory", McpTier.Read, [], ("query", Text), ("project", Text), ("group", EnumOf("project", "reportsTo"))),
      Spec("agents.profile", McpTier.Read, ["id"], ("id", Text)),
      Spec("agents.org_chart", McpTier.Read, []),
      Spec("agents.duplicate", McpTier.Alter, ["id"], ("id", Text), ("name", Text)),
      Spec("agents.set_icon", McpTier.Alter, ["id", "icon"], ("id", Text), ("icon", NullableText)),
      Spec("agents.set_reports_to", McpTier.Alter, ["id", "reportsTo"], ("id", Text), ("reportsTo", NullableText)),
      Spec("agents.edit_profile", McpTier.Alter, ["id", "fields"], ("id", Text), ("fields", Record)),
      Spec("agents.set_role", McpTier.Alter, ["agent", "role"], ("agent", Text), ("role", NullableText), ("title", Text)),
      Spec("agents.hands", McpTier.Read, []),
      Spec("agents.skills", McpTier.Read, [], ("agent", Text), ("projectId", Text)),
      Spec("agents.stop_hands", McpTier.Act, ["agent"], ("agent", Text)),
      Spec("memory.notes.save", McpTier.Alter, ["text"], ("seat", Text), ("text", new { type = "string", maxLength = 128000 })),
      Spec("agents.add_hand", McpTier.Act, ["agent", "job"], ("agent", Text), ("job", Text), ("details", Text), ("helper", new { type = "boolean" })),
      Spec("agents.open_profile", McpTier.Act, ["agent"], ("agent", Text)),
      Spec("tasks.agents", McpTier.Read, ["do"], ("do", EnumOf("list", "save", "save-many", "remove", "pause", "resume", "archive", "restore")), ("agent", Record), ("agents", new { type = "array", maxItems = 50, items = Record }), ("id", Text), ("ids", new { type = "array", maxItems = 50, items = Text })),
      Spec("memory.template.read", McpTier.Read, ["category"], ("category", EnumOf("orchestrator", "lead", "agent"))),
      Spec("memory.template.save", McpTier.Alter, ["category"], ("category", EnumOf("orchestrator", "lead", "agent")), ("card", new { type = "string", maxLength = 40000 }), ("checklist", new { type = "string", maxLength = 20000 }),
        ("parts", new { type = "array", items = EnumOf("card", "notes", "diary", "topics", "playbook", "board", "helper") }), ("helperAI", EnumOf("claude", "codex", "gemini")), ("helperModel", Text),
        ("cardLimit", new { type = "number", minimum = 500, maximum = 40000 }), ("handsPerSeat", new { type = "integer", minimum = 0 }), ("handsPerProject", new { type = "integer", minimum = 0 })),
      Spec("memory.card.save", McpTier.Alter, ["text"], ("seat", Text), ("text", new { type = "string", maxLength = 40000 })),
      Spec("memory.card.read", McpTier.Read, [], ("seat", Text))
    ];
  }
}

// The central base snapshot predates nullable project arguments. Kept here as
// the contribution's validator until the integrate lane adds the same support.
public static class ProjectAgentSchema
{
  public static void Validate(JsonElement schema, JsonElement value)
  {
    if (schema.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.Array)
    {
      if (value.ValueKind == JsonValueKind.Null && type.EnumerateArray().Any(t => t.GetString() == "null")) return;
      if (value.ValueKind == JsonValueKind.String && type.EnumerateArray().Any(t => t.GetString() == "string")) return;
      throw new McpRefusal("Choose text or null for that argument.");
    }
    if (value.ValueKind != JsonValueKind.Object) { McpSchema.Validate(schema, value); return; }
    if (value.EnumerateObject().Select(p => p.Name).Distinct().Count() != value.EnumerateObject().Count()) throw new McpRefusal("A tool argument was repeated.");
    if (schema.TryGetProperty("required", out var required)) foreach (var field in required.EnumerateArray()) if (!value.TryGetProperty(field.GetString()!, out _)) throw new McpRefusal("A required tool argument is missing.");
    var properties = schema.GetProperty("properties");
    foreach (var property in value.EnumerateObject())
    {
      if (!properties.TryGetProperty(property.Name, out var shape)) throw new McpRefusal("An unexpected tool argument was supplied.");
      if (shape.TryGetProperty("type", out var kind) && kind.ValueKind == JsonValueKind.Array) Validate(shape, property.Value);
      else McpSchema.Validate(shape, property.Value);
    }
  }
}
