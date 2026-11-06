using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Agents;

public sealed class AgentService : IAgents
{
  private readonly object gate = new();
  private readonly IStateStore<AgentState> store;
  private readonly IProjects projects;
  private readonly IAgentInstructions instructions;
  private readonly AccountService? accounts;
  private readonly IAgentSessionGateway? sessions;
  private readonly TimeProvider clock;
  private AgentState state;
  public event Action? Changed;
  public bool CanStartSessions => sessions is not null && accounts is not null;
  public bool CanStart(string mode) => CanStartSessions && sessions!.SupportsMode(mode);
  public AgentService(IStateStore<AgentState> store, IProjects projects, IAgentInstructions instructions,
    AccountService? accounts = null, IAgentSessionGateway? sessions = null, TimeProvider? clock = null)
  {
    this.store = store; this.projects = projects; this.instructions = instructions; this.accounts = accounts; this.sessions = sessions; this.clock = clock ?? TimeProvider.System;
    state = store.Load() ?? new(1, [], DefaultTemplates(), [new("orchestrator")], []);
    if (state.Version != 1 || state.Agents.IsDefault || state.Templates.IsDefault || state.Seats.IsDefault || state.Runs.IsDefault ||
      state.Agents.Select(a => a.Id).Distinct().Count() != state.Agents.Length || state.Templates.Select(t => t.Category).Distinct().Count() != 3 ||
      state.Seats.Select(s => s.SeatKey).Distinct().Count() != state.Seats.Length || state.Runs.Select(r => r.SessionId).Distinct().Count() != state.Runs.Length)
      throw new IOException("The saved agents could not be read safely.");
    state = state with { RetiredIds = state.RetiredIds.IsDefault ? [] : state.RetiredIds };
    foreach (var row in state.Agents) Validate(row, allowSavedUnsupportedChoices: true);
    state = state with { Agents = state.Agents.Select(a => a with { Seat = a.Seat.Length == 0 ? a.Id[..Math.Min(64, a.Id.Length)] : a.Seat, Skills = a.Skills.IsDefault ? [] : a.Skills, Options = Normalize(a.Options) }).ToImmutableArray() };
    foreach (var seat in state.Seats) _ = AgentSeats.Parse(seat.SeatKey);
    foreach (var row in state.Agents) CheckManager(row);
  }
  public IReadOnlyList<SavedAgent> List() => Volatile.Read(ref state).Agents;
  public SavedAgent Get(string id) => List().FirstOrDefault(a => a.Id == id) ?? throw new ArgumentException("Choose a saved agent from the list.");
  public string NewId(string name)
  {
    lock (gate) return ProjectIdentity.NewId(name, state.Agents.Select(a => a.Id).Concat(state.RetiredIds).Concat(state.Runs.Select(r => r.AgentId).OfType<string>()));
  }
  public SavedAgent Save(SavedAgent agent, SavedAgent? expected = null, bool createOnly = false, AgentSeatMemory? initialMemory = null)
  {
    var savedChoice = List().FirstOrDefault(a => a.Id == agent.Id);
    static bool SameChoice(SavedAgent a, SavedAgent? b) => b is not null && a.Provider == b.Provider && a.Model == b.Model && a.Effort == b.Effort;
    Validate(agent, allowSavedUnsupportedChoices: SameChoice(agent, savedChoice)); _ = projects.Get(agent.ProjectId);
    if (agent.AccountId is { } accountId && !(savedChoice is not null && savedChoice.AccountId == accountId && savedChoice.Provider == agent.Provider) && (accounts is null || accounts.Get(accountId).Provider != agent.Provider)) throw new ArgumentException("Choose an account for this agent's AI.");
    agent = agent with { Name = agent.Name.Trim(), Seat = agent.Seat.Length == 0 ? agent.Id[..Math.Min(64, agent.Id.Length)] : agent.Seat, Skills = agent.Skills.IsDefault ? [] : agent.Skills, Options = Normalize(agent.Options) };
    if (agent.Options?.WorkingFolder is { } workingFolder)
    {
      var project = projects.Get(agent.ProjectId);
      if (project.Id != ProjectIdentity.IndependentId && !project.Folders.Any(f => ProjectPaths.Contains(f, workingFolder))) throw new ArgumentException("Choose a working folder inside this agent's project.");
    }
    lock (gate)
    {
      if (state.RetiredIds.Contains(agent.Id)) throw new ArgumentException("This agent ID belongs to a former hire. Add a new agent instead.");
      CheckManager(agent);
      if (state.Agents.Any(a => a.Id != agent.Id && a.ProjectId == agent.ProjectId && a.Seat == agent.Seat && a.Status != SavedAgentStatus.Archived && agent.Status != SavedAgentStatus.Archived))
        throw new ArgumentException("That role already has an agent. Choose a vacant role or add a hand.");
      var old = state.Agents.FirstOrDefault(a => a.Id == agent.Id);
      Validate(agent, allowSavedUnsupportedChoices: SameChoice(agent, old));
      if (createOnly && old is not null) throw new InvalidOperationException("An agent was just added with this ID. Choose a new ID and try again.");
      if (expected is not null && old != expected) throw new InvalidOperationException("This agent changed while you were editing. Close and reopen its settings to use the saved version.");
      if (old is not null && old.ProjectId != agent.ProjectId && projects.List().Any(p => p.Lead == "agent:" + agent.Id))
        throw new ArgumentException("Change this project's lead before moving its agent to another project.");
      var seat = AgentSeats.Role(agent.ProjectId, agent.Seat);
      if (initialMemory is not null && (initialMemory.SeatKey != seat.Key || state.Seats.Any(s => s.SeatKey == seat.Key) || initialMemory.Card.Length > 64000 || initialMemory.Notes.Length > 128000 || initialMemory.Card.Contains('\0') || initialMemory.Notes.Contains('\0')))
        throw new ArgumentException("Copy memory only into a new role's seat.");
      var seats = state.Seats.Any(s => s.SeatKey == seat.Key) ? state.Seats : state.Seats.Add(initialMemory ?? new(seat.Key));
      Persist(state with { Agents = old is null ? state.Agents.Add(agent) : state.Agents.Replace(old, agent), Seats = seats });
    }
    Changed?.Invoke(); return agent;
  }
  public SavedAgent Hire(string name, string provider, string description, AgentCategory category, string projectId, string? role = null, string? reportsTo = null, string icon = "person")
  {
    lock (gate)
    {
    if (category == AgentCategory.Orchestrator) throw new ArgumentException("Hoot is the one Orchestrator. Edit its template from Templates.");
    if (!Enum.IsDefined(category)) throw new ArgumentException("Choose Lead or Agent.");
    if (category == AgentCategory.Lead)
    {
      _ = AgentSeats.Lead(projectId);
      if (projects.Get(projectId).Lead is not null) throw new ArgumentException("This project already has a lead. Change it on the project page first.");
    }
    var id = NewId(name);
    var agent = Save(new(id, name, provider, description, ProjectId: projectId, Seat: role ?? id[..Math.Min(64, id.Length)], ReportsTo: reportsTo, Icon: icon));
    if (category == AgentCategory.Lead)
    {
      SetProjectLead(projectId, id);
    }
    return agent;
    }
  }
  public SavedAgent Duplicate(string id, string? name = null)
  {
    lock (gate)
    {
      var source = Get(id); name ??= source.Name[..Math.Min(55, source.Name.Length)] + " copy";
      var copyId = NewId(name); var role = ProjectIdentity.NewId(source.Seat[..Math.Min(40, source.Seat.Length)] + "-copy", state.Agents.Where(a => a.ProjectId == source.ProjectId).Select(a => a.Seat));
      var memory = state.Seats.FirstOrDefault(s => s.SeatKey == SeatOf(id).Key);
      var copy = source with { Id = copyId, Name = name, Seat = role, Status = SavedAgentStatus.Active, InstructionsFile = null };
      Validate(copy); _ = projects.Get(copy.ProjectId);
      if (source.InstructionsFile is { } file) copy = copy with { InstructionsFile = instructions.Save(copyId, instructions.Read(file)) };
      var target = AgentSeats.Role(copy.ProjectId, role);
      return Save(copy, createOnly: true, initialMemory: new(target.Key, memory?.Card ?? "", memory?.Notes ?? ""));
    }
  }
  public void Remove(string id)
  {
    lock (gate)
    {
      var old = Get(id);
      if (state.Runs.Any(r => r.AgentId == id && r.State is AgentRunState.Starting or AgentRunState.Running or AgentRunState.Uncertain)) throw new ArgumentException("This agent still has a hand at work. End its session before removing it.");
      if (old.Status != SavedAgentStatus.Archived) throw new ArgumentException("Archive this agent before deleting it permanently.");
      // The seat and its notes deliberately outlive the hire. Reports become independent.
      Persist(state with { RetiredIds = state.RetiredIds.Add(id), Agents = state.Agents.Remove(old).Select(a => a.ReportsTo == id ? a with { ReportsTo = null } : a).ToImmutableArray() });
    }
    foreach (var p in projects.List().Where(p => p.Lead == "agent:" + id)) projects.SetLead(p.Id, null);
    Changed?.Invoke();
  }
  public SavedAgent SaveInstructions(string id, string text, string? expectedText = null)
  {
    lock (gate)
    {
      var agent = Get(id);
      if (expectedText is not null && ReadInstructions(id) != expectedText)
        throw new InvalidOperationException("Instructions changed on disk. Choose Keep mine or Use file.");
      var path = instructions.Save(id, text); return Save(agent with { InstructionsFile = path });
    }
  }
  public string ReadInstructions(string id) => Get(id).InstructionsFile is { } path ? instructions.Read(path) : "";
  public IReadOnlyList<AgentTemplate> Templates() => Volatile.Read(ref state).Templates;
  public void SaveTemplate(AgentTemplate template, AgentTemplate? expected = null)
  {
    if (!Enum.IsDefined(template.Category) || template.Instructions.Length > 40_000 || template.Instructions.Contains('\0') || template.MaxHandsPerSeat < 0 || template.MaxHandsPerProject < 0 ||
      template.Checklist.Length > 20_000 || template.CardLimit is < 500 or > 40_000 || template.HelperAI is not ("claude" or "codex" or "gemini") || template.HelperModel.Length > 160 ||
      !template.Parts.IsDefault && template.Parts.Any(p => p is not ("card" or "notes" or "diary" or "topics" or "playbook" or "board" or "helper")))
      throw new ArgumentException("Use a short template and nonnegative hand limits. Zero means No limit.");
    if (!template.Parts.IsDefault && template.Parts.Any(p => p is not ("card" or "notes" or "helper"))) throw new ArgumentException("This Windows version supports cards, notes and helper instructions. Other memory parts are not connected yet.");
    if (template.Parts.IsDefault) template = template with { Parts = ["card", "notes"] };
    lock (gate) { var old = state.Templates.Single(t => t.Category == template.Category); if (expected is not null && old != expected) throw new InvalidOperationException("This template changed while you were editing. Revert to the saved version before editing it again."); Persist(state with { Templates = state.Templates.Replace(old, template) }); }
    Changed?.Invoke();
  }
  public AgentSeat SeatOf(string id)
  {
    if (id == AgentSeats.HootId) return AgentSeats.Orchestrator;
    var agent = Get(id); var led = projects.List().FirstOrDefault(p => p.Lead == "agent:" + id);
    return led is null ? AgentSeats.Role(agent.ProjectId, agent.Seat) : AgentSeats.Lead(led.Id);
  }
  public IReadOnlyList<AgentSeatMemory> Seats() => Volatile.Read(ref state).Seats;
  public AgentSeatMemory SaveSeatMemory(string key, string card, string notes, AgentSeatMemory? expected = null)
  {
    var seat = AgentSeats.Parse(key); if (seat.ProjectId is { } project) _ = projects.Get(project);
    if (card.Length > 64_000 || notes.Length > 128_000 || card.Contains('\0') || notes.Contains('\0')) throw new ArgumentException("Keep the seat's card and notes short enough to read.");
    var memory = new AgentSeatMemory(key, card, notes);
    lock (gate) { var old = state.Seats.FirstOrDefault(s => s.SeatKey == key); if (expected is not null && old != expected && (old is not null || expected != new AgentSeatMemory(key))) throw new InvalidOperationException("This role memory changed while you were editing. Reopen it before saving your edits."); Persist(state with { Seats = old is null ? state.Seats.Add(memory) : state.Seats.Replace(old, memory) }); }
    Changed?.Invoke(); return memory;
  }
  public IReadOnlyList<AgentRun> Runs() => Volatile.Read(ref state).Runs;
  public void SetProjectLead(string projectId, string? agentId)
  {
    _ = AgentSeats.Lead(projectId);
    if (agentId is null) { projects.SetLead(projectId, null); return; }
    var agent = Get(agentId);
    if (agent.ProjectId != projectId || agent.Status == SavedAgentStatus.Archived) throw new ArgumentException("Choose an active agent in this project as the lead.");
    if (projects.List().Any(p => p.Id != projectId && p.Lead == "agent:" + agentId)) throw new ArgumentException("This agent already leads another project.");
    projects.SetLead(projectId, "agent:" + agentId, agent.Name);
    if (!Seats().Any(s => s.SeatKey == AgentSeats.Lead(projectId).Key)) SaveSeatMemory(AgentSeats.Lead(projectId).Key, "", "");
    Changed?.Invoke();
  }
  public IReadOnlyList<AgentTreeNode> OrgChart()
  {
    var rows = List();
    AgentTreeNode Node(SavedAgent a) => new(a, rows.Where(r => r.ReportsTo == a.Id).OrderBy(r => r.Name).Select(Node).ToImmutableArray());
    return rows.Where(a => a.ReportsTo is null or AgentSeats.HootId).OrderBy(a => a.Name).Select(Node).ToArray();
  }
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string provider, string? accountId = null, CancellationToken cancellationToken = default)
  {
    var account = accountId is null ? accounts?.Default(provider) ?? accounts?.List(provider).FirstOrDefault(a => a.SignedIn) : accounts?.Get(accountId);
    return account is null || accounts is null ? [] : (await accounts.ModelsAsync(account.Id, cancellationToken: cancellationToken)).Models;
  }
  public async ValueTask<AgentRun> StartAsync(NewAgentSession request, CancellationToken cancellationToken = default, Func<AgentLaunchPlan, CancellationToken, ValueTask>? beforeStart = null)
  {
    if (sessions is null || accounts is null) throw new InvalidOperationException("Starting sessions is not connected. The saved agent is ready for the session service.");
    if (request.Mode is not ("terminal" or "chat") || request.Helper && request.AgentId is null || request.Job.Length > 4000 || request.Title is { Length: > 120 } || request.Title?.Any(char.IsControl) == true || request.Job.Any(c => char.IsControl(c) && c is not '\n' and not '\r' and not '\t')) throw new ArgumentException("Choose terminal or chat and a short job for this hand.");
    var agent = request.AgentId is null ? null : Get(request.AgentId);
    if (!request.Helper && agent is not null && agent.Effort is not ("auto" or "low" or "medium" or "high" or "xhigh" or "max")) throw new ArgumentException("This saved effort is unavailable in the current driver. Choose a supported effort in Agent settings.");
    if (agent is not null && agent.Status != SavedAgentStatus.Active) throw new ArgumentException("Resume this agent before starting a session as it.");
    var project = projects.Get(request.ProjectId ?? agent?.ProjectId ?? projects.ActiveProjectId ?? ProjectIdentity.IndependentId);
    if (agent is not null && agent.ProjectId != ProjectIdentity.IndependentId && agent.ProjectId != project.Id) throw new ArgumentException("This agent belongs to another project.");
    var folder = request.Folder ?? (request.Helper ? null : agent?.Settings.WorkingFolder) ?? project.HomeFolder ?? throw new ArgumentException("Choose a home folder for this session.");
    folder = ProjectPaths.Normalize(folder);
    if (project.Id != ProjectIdentity.IndependentId && !project.Folders.Any(f => ProjectPaths.Contains(f, folder))) throw new ArgumentException("Choose a folder inside this project.");
    // Start where the team's .claude lives (the project home); other project
    // folders become extra access at launch (Umer, 30 Oct: skills went missing).
    // An agent's own saved working folder is the person's choice and is kept.
    var ownFolder = request.Folder is null && !request.Helper && agent?.Settings.WorkingFolder is not null;
    var start = ownFolder ? new ProjectStart(folder, [], null) : ProjectStartFolders.Choose(project, folder); folder = start.Folder;
    AgentSeat? seat = agent is null ? null : SeatOf(agent.Id);
    var parentTemplate = seat is null ? null : Templates().Single(t => t.Category == seat.Category);
    var template = request.Helper ? Templates().Single(t => t.Category == AgentCategory.Agent) : parentTemplate;
    var choice = project.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == (request.Mode == "chat" ? "chats" : "sessions"));
    var provider = request.Helper ? parentTemplate!.HelperAI : agent?.Provider ?? request.Provider ?? choice?.Provider ?? throw new ArgumentException("Choose the AI for this session.");
    if (provider is not ("claude" or "codex" or "gemini")) throw new ArgumentException("Choose Claude Code, Codex or Gemini.");
    var accountId = request.AccountId ?? (agent?.Provider == provider ? agent.AccountId : null) ?? (choice?.Provider == provider ? choice.AccountId : null);
    // A task or tool start names no account. Use the folder's or AI's default,
    // else the one signed-in account the picker would preselect (Mac: same).
    var account = accountId is null ? accounts.Preferred(provider, folder) : accounts.Get(accountId);
    if (account is null || account.Provider != provider) throw new ArgumentException("Choose an account for this AI under Coding AIs.");
    try { if (request.Mode != "chat" || agent is not null) account = await accounts.RequireSignedInAsync(account.Id, cancellationToken); }
    catch (SignInRequiredException) { throw; }
    catch (OperationCanceledException) { throw; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { throw new InvalidOperationException("This account's sign-in status could not be checked. Open Coding AIs and refresh it before starting a session."); }
    if (account.Provider != provider) throw new ArgumentException("Choose an account for this AI.");
    var parentSeatKey = request.Helper ? seat?.Key : null;
    var ownInstructions = agent?.InstructionsFile is { } file ? instructions.Read(file) : "";
    AgentRun run; AgentLaunchPlan plan;
    lock (gate)
    {
      cancellationToken.ThrowIfCancellationRequested();
      if (agent is not null && Get(agent.Id) != agent) throw new InvalidOperationException("This agent changed while the account was checked. Start again with its current settings.");
      if (seat is not null && request.Helper)
      {
        var baseRole = agent!.Seat[..Math.Min(40, agent.Seat.Length)];
        var number = 1; while (state.Seats.Any(s => s.SeatKey == AgentSeats.Role(project.Id, baseRole + "--helper-" + number).Key)) number++;
        seat = AgentSeats.Role(project.Id, baseRole + "--helper-" + number);
      }
      var live = state.Runs.Where(r => r.State is AgentRunState.Starting or AgentRunState.Running or AgentRunState.Uncertain).ToArray();
      if (agent?.MaxConcurrentTasks is { } limit && live.Count(r => r.AgentId == agent.Id) >= limit)
        throw new InvalidOperationException("This agent has reached its Tasks at once limit. Finish a task or change its limit in Agent settings.");
      if (seat is not null && template is not null && (template.MaxHandsPerSeat > 0 && live.Count(r => r.AgentId == agent!.Id) >= template.MaxHandsPerSeat || template.MaxHandsPerProject > 0 && live.Count(r => r.ProjectId == project.Id && r.SeatKey is { } k && AgentSeats.Parse(k).Category == template.Category) >= template.MaxHandsPerProject))
        throw new InvalidOperationException("This seat or project has reached its hand limit. Finish a hand or change its category template.");
      var numberOnSeat = seat is null ? 0 : state.Runs.Where(r => r.SeatKey == seat.Key).Select(r => r.HandNumber).DefaultIfEmpty(0).Max() + 1;
      var id = Guid.NewGuid().ToString();
      run = new(id, agent?.Id, agent?.Name ?? "", provider, project.Id, seat?.Key, numberOnSeat, request.Job.Trim(), request.Mode, AgentRunState.Starting, clock.GetUtcNow(), ParentSeatKey: parentSeatKey);
      var memory = seat is null ? null : state.Seats.FirstOrDefault(m => m.SeatKey == seat.Key);
      var contextMemory = request.Helper ? state.Seats.FirstOrDefault(m => m.SeatKey == parentSeatKey) : memory;
      var parts = template?.Parts ?? [];
      var skillAdvice = agent is not null && !agent.Settings.SkillsOff && !agent.Skills.IsDefaultOrEmpty
        ? "Saved skill references (advice, not tool restrictions). If these skills are installed for this working folder or AI account, consult their instructions when useful: " + JsonSerializer.Serialize(agent.Skills)
        : agent?.Settings.SkillsOff == true ? "Skills are turned off for this agent. Do not use any skills." : null;
      var prompt = string.Join("\n\n", new[] { template?.Instructions, parts.Contains("card") ? contextMemory?.Card : null, parts.Contains("notes") ? contextMemory?.Notes : null, request.Helper ? parentTemplate?.Checklist : null, ownInstructions, skillAdvice, request.Helper ? null : ToolAdvice(agent), LinkedServers(project) }.Where(s => !string.IsNullOrWhiteSpace(s)));
      // Only a start that already carries instructions or a job says where the work is;
      // a plain session must not gain a first message it never had.
      if (start.AskedFolder is { } asked && (prompt.Length > 0 || request.Job.Trim().Length > 0)) prompt = string.Join("\n\n", new[] { prompt, ProjectStartFolders.Note(asked) }.Where(s => s.Length > 0));
      plan = new(id, agent?.Id, seat?.Key, project.Id, folder, provider, account.Id, account.HomeId, request.Model ?? (request.Helper ? parentTemplate!.HelperModel : agent?.Model ?? ""), request.Effort ?? (request.Helper ? "auto" : agent?.Effort ?? "auto"), prompt,
        agent?.InstructionsFile, request.Title ?? agent?.Name ?? AgentSeats.ProviderName(provider), request.Job.Trim(), request.Mode,
        request.Permission ?? (request.Helper ? null : AgentOptions.ToMode(agent?.Settings.PermissionMode ?? DefaultPermission(project))));
      if (plan.Provider == "gemini" && plan.Effort is not ("" or "auto")) throw new ArgumentException("This Windows session path does not support the saved Gemini effort. Choose Automatic in Agent settings before starting.");
      sessions.Validate(plan);
      var seats = seat is not null && memory is null ? state.Seats.Add(new(seat.Key)) : state.Seats;
      Persist(state with { Runs = state.Runs.Add(run), Seats = seats });
    }
    Changed?.Invoke();
    var handedToGateway = false;
    try
    {
      if (beforeStart is not null) await beforeStart(plan, cancellationToken);
      projects.BindSession(run.SessionId, project.Id);
      if (beforeStart is not null) await beforeStart(plan, cancellationToken);
      handedToGateway = true;
      var started = await sessions.StartAsync(plan, cancellationToken);
      if (started.SessionId != plan.SessionId || started.Mode != plan.Mode) throw new InvalidOperationException("The session service returned a different session. Check its state before trying again.");
      return SetRun(run.SessionId, AgentRunState.Running);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // Provider and file errors can contain credentials. Keep only a safe status.
      SetRun(run.SessionId, handedToGateway ? AgentRunState.Uncertain : AgentRunState.Ended, "The start could not be confirmed. Check the session list before starting another hand.");
      throw new InvalidOperationException("The start could not be confirmed. Check the session list before starting another hand.");
    }
  }
  // Only the session/chat lifecycle adapter calls this after the process ended.
  // Helper notes fold into the original parent seat once, even if the hire moved.
  public void EndHand(string sessionId)
  {
    lock (gate)
    {
      var run = state.Runs.Single(r => r.SessionId == sessionId);
      if (run.State == AgentRunState.Ended) return;
      var seats = state.Seats;
      if (run.ParentSeatKey is { } parentKey && seats.FirstOrDefault(s => s.SeatKey == run.SeatKey) is { Notes.Length: > 0 } helper)
      {
        var parent = seats.FirstOrDefault(s => s.SeatKey == parentKey) ?? new AgentSeatMemory(parentKey);
        var updated = parent with { Notes = parent.Notes + (parent.Notes.Length > 0 ? "\n\n" : "") + helper.Notes };
        seats = seats.Contains(parent) ? seats.Replace(parent, updated) : seats.Add(updated);
      }
      Persist(state with { Runs = state.Runs.Replace(run, run with { State = AgentRunState.Ended }), Seats = seats });
    }
    Changed?.Invoke();
  }
  public void ReconcileSessions(IEnumerable<ProjectSession> sessions)
  {
    var rows = sessions.ToDictionary(s => s.Id);
    foreach (var run in Runs().Where(r => r.State != AgentRunState.Ended))
      if (rows.TryGetValue(run.SessionId, out var row) && row.Status is "Exited" or "exited" or "ended") EndHand(run.SessionId);
  }
  public void InheritChatIdentity(string parentId, string childId)
  {
    lock (gate)
    {
      if (parentId == childId || state.Runs.Any(r => r.SessionId == childId)) return;
      var parent = state.Runs.FirstOrDefault(r => r.SessionId == parentId && r.Mode == "chat");
      if (parent is null) return;
      var nextHand = state.Runs.Where(r => r.SeatKey == parent.SeatKey).Select(r => r.HandNumber).DefaultIfEmpty().Max() + 1;
      Persist(state with { Runs = state.Runs.Add(parent with { SessionId = childId, HandNumber = nextHand, State = AgentRunState.Running, StartedAt = clock.GetUtcNow(), Problem = null }) });
    }
    Changed?.Invoke();
  }
  public string SessionLabel(string sessionId, string provider) => SessionFace(sessionId)?.Name ?? AgentSeats.ProviderName(provider);
  public AgentFace? SessionFace(string sessionId)
  {
    var run = Runs().FirstOrDefault(r => r.SessionId == sessionId);
    if (run?.AgentId is not { } id) return null;
    var agent = List().FirstOrDefault(a => a.Id == id);
    return new(id, agent?.Name ?? run.AgentName, agent?.Icon ?? "person", PhotoPath: agent?.PhotoPath);
  }
  public IReadOnlyList<ProjectSetupAgent> SetupAgents() => List().Select(a => new ProjectSetupAgent(a.Id, a.ProjectId, a.Skills.IsDefault ? [] : a.Skills, a.Status == SavedAgentStatus.Archived)).ToArray();
  private AgentRun SetRun(string id, AgentRunState next, string? problem = null)
  {
    AgentRun row;
    lock (gate) { var old = state.Runs.Single(r => r.SessionId == id); row = old with { State = next, Problem = problem }; Persist(state with { Runs = state.Runs.Replace(old, row) }); }
    Changed?.Invoke(); return row;
  }
  private void CheckManager(SavedAgent row)
  {
    var seen = new HashSet<string>(StringComparer.Ordinal) { row.Id }; var target = row.ReportsTo;
    while (target is not null && target != AgentSeats.HootId)
    {
      if (!seen.Add(target)) throw new ArgumentException("An agent cannot report to itself or make a loop.");
      target = state.Agents.FirstOrDefault(a => a.Id == target)?.ReportsTo ?? (state.Agents.Any(a => a.Id == target) ? null : throw new ArgumentException("Choose a manager from the saved agents or Hoot."));
    }
  }
  // "Stop everything it is running": each live hand's session is closed through the
  // session owner; the run ends when that owner reports the exit.
  public async ValueTask<int> StopHandsAsync(string agentId, CancellationToken cancellationToken = default)
  {
    _ = Get(agentId);
    if (sessions is null || !sessions.CanStop) throw new InvalidOperationException("Stopping sessions is not connected here. Close the sessions from their tabs.");
    var live = Runs().Where(r => r.AgentId == agentId && r.State is AgentRunState.Starting or AgentRunState.Running or AgentRunState.Uncertain).ToArray();
    var stopped = 0;
    foreach (var run in live)
    {
      cancellationToken.ThrowIfCancellationRequested();
      try { await sessions.StopAsync(run.SessionId, cancellationToken); stopped++; }
      catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or KeyNotFoundException or IOException)
      { if (run.State == AgentRunState.Uncertain) { EndHand(run.SessionId); stopped++; } }
    }
    return stopped;
  }
  private static string? ToolAdvice(SavedAgent? agent)
  {
    if (agent is null) return null;
    var o = agent.Settings; var lines = new List<string>();
    if (!o.ToolsPreferred.IsDefaultOrEmpty) lines.Add("Tools this agent should use where they fit: " + string.Join(", ", o.ToolsPreferred) + ".");
    if (!o.ToolsAvoided.IsDefaultOrEmpty) lines.Add("Tools this agent should avoid: " + string.Join(", ", o.ToolsAvoided) + ".");
    return lines.Count == 0 ? null : string.Join("\n", lines);
  }
  // Mac SETTINGS-TRUTH row 42: a project's linked servers are named in every brief for work in it.
  private static string? LinkedServers(Project project) => project.Preferences.Text("linkedServers").Trim() is { Length: > 0 } names
    ? "Servers linked to this project: " + names + ". Use them by these names." : null;
  private static string? DefaultPermission(Project project) => project.Preferences.Text("defaultPermission") is "ask" or "plan" or "auto" ? project.Preferences.Text("defaultPermission") : null;
  private static AgentOptions? Normalize(AgentOptions? o)
  {
    if (o is null) return null;
    static ImmutableArray<string> Clean(ImmutableArray<string> rows) => rows.IsDefault ? [] : rows.Select(r => r.Trim()).Where(r => r.Length > 0).Distinct(StringComparer.Ordinal).ToImmutableArray();
    o = o with { PermissionMode = string.IsNullOrWhiteSpace(o.PermissionMode) ? null : o.PermissionMode, WorkingFolder = string.IsNullOrWhiteSpace(o.WorkingFolder) ? null : ProjectPaths.Normalize(o.WorkingFolder),
      ToolsPreferred = Clean(o.ToolsPreferred), ToolsAvoided = Clean(o.ToolsAvoided) };
    if (o.PermissionMode is not null && !AgentOptions.PermissionModes.Contains(o.PermissionMode)) throw new ArgumentException("Choose App default, Ask before changes, Plan only or Change without asking.");
    if (o.ToolsPreferred.Length > 40 || o.ToolsAvoided.Length > 40 || o.ToolsPreferred.Concat(o.ToolsAvoided).Any(t => t.Length > 100 || t.Any(char.IsControl))) throw new ArgumentException("Name up to 40 tools, each in a few words.");
    return o.PermissionMode is null && o.WorkingFolder is null && o.ToolsPreferred.IsEmpty && o.ToolsAvoided.IsEmpty && !o.SkillsOff ? null : o;
  }
  private static void Validate(SavedAgent agent, bool allowSavedUnsupportedChoices = false)
  {
    if (!allowSavedUnsupportedChoices && agent.Provider == "gemini" && agent.Effort != "auto")
      throw new ArgumentException("This Windows session path does not support the saved Gemini effort. Choose Automatic in Agent settings before starting.");
    if (!ProjectIdentity.ValidId(agent.Id) || agent.Id is "hoot" or "independent" || string.IsNullOrWhiteSpace(agent.Name) || agent.Name.Length > 60 || agent.Name.Any(char.IsControl) ||
      agent.Provider.Length is 0 or > 40 || agent.Provider.Any(char.IsControl) || !allowSavedUnsupportedChoices && agent.Provider is not ("claude" or "codex" or "gemini") || agent.Description.Length > 4000 || agent.Description.Contains('\0') || agent.Model.Length > 160 || agent.Model.Any(char.IsControl) ||
      agent.Effort.Length is 0 or > 40 || agent.Effort.Any(char.IsControl) || !allowSavedUnsupportedChoices && agent.Effort is not ("auto" or "low" or "medium" or "high" or "xhigh" or "max") || !ProjectIdentity.ValidId(agent.ProjectId) || agent.Seat.Length > 0 && !AgentSeats.ValidRole(agent.Seat) ||
      agent.PhotoPath is { } photo && (photo.Length > 4096 || !Path.IsPathFullyQualified(photo) || photo.Any(char.IsControl)) ||
      agent.MaxConcurrentTasks is < 1 || agent.Icon.Length is 0 or > 100 || agent.Icon.Any(char.IsControl) || !Enum.IsDefined(agent.Status) || !agent.Skills.IsDefault && (agent.Skills.Length > 80 || agent.Skills.Any(s => s.Length is 0 or > 200)))
      throw new ArgumentException("Choose a name, AI, project, model and role for this agent.");
  }
  private static ImmutableArray<AgentTemplate> DefaultTemplates() =>
  [
    new(AgentCategory.Orchestrator, "Give project leads clear goals. Where a project has no lead, assign its agents directly. Ask before changing shared settings.", 0, 0, Parts: ["card", "notes"]),
    new(AgentCategory.Lead, "Run this project's agents. Give each hand a distinct job, review the evidence, and report progress to Hoot.", 0, 0, Parts: ["card", "notes"]),
    new(AgentCategory.Agent, "Do the work of this role. Read its card and notes first. Keep useful findings with the seat and report to your manager.", Parts: ["card", "notes"])
  ];
  private void Persist(AgentState next) { store.Save(next); Volatile.Write(ref state, next); }
}
