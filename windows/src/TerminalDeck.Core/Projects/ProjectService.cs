using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Projects;

public sealed class ProjectService : IProjects
{
  private readonly object gate = new();
  private readonly IStateStore<ProjectState> store;
  private readonly IProjectFolders folders;
  private readonly IProjectPictures? pictures;
  private ProjectState state;
  public event Action? Changed;
  public Action<string>? BeforeRemove { get; set; }
  private readonly Dictionary<string, Action<string>> removalGuards = [];
  public void SetRemovalGuard(string owner, Action<string> check) { lock (gate) removalGuards[owner] = check; }
  private void CheckRemoval(string id) { BeforeRemove?.Invoke(id); foreach (var check in removalGuards.Values) check(id); }
  public ProjectService(IStateStore<ProjectState> store, IProjectFolders folders, IProjectPictures? pictures = null)
  {
    this.store = store; this.folders = folders; this.pictures = pictures;
    state = store.Load() ?? new(1, [ProjectIdentity.Independent], null, []);
    if (state.Version != 1 || state.Projects.IsDefault || state.Sessions.IsDefault || state.Projects.Select(p => p.Id).Distinct().Count() != state.Projects.Length ||
      state.Projects.Any(p => !ProjectIdentity.ValidId(p.Id) || string.IsNullOrWhiteSpace(p.Name) || p.Folders.IsDefault) ||
      state.Sessions.Select(s => s.SessionId).Distinct().Count() != state.Sessions.Length)
      throw new IOException("The saved projects could not be read safely.");
    if (!state.Projects.Any(p => p.Id == ProjectIdentity.IndependentId)) state = state with { Projects = state.Projects.Add(ProjectIdentity.Independent) };
    if (state.ActiveProjectId is { } active && !state.Projects.Any(p => p.Id == active)) throw new IOException("The saved active project is missing.");
  }
  public IReadOnlyList<Project> List() => Volatile.Read(ref state).Projects;
  public Project Get(string id) => List().FirstOrDefault(p => p.Id == id) ?? throw new ArgumentException("Choose a project from the list.");
  public string? ActiveProjectId => Volatile.Read(ref state).ActiveProjectId;
  public Project Create(string name, string homeFolder)
  {
    lock (gate) return Save(new(ProjectIdentity.NewId(name, state.Projects.Select(p => p.Id)), name, [homeFolder]));
  }
  public Project Save(ProjectDraft draft, Project? expected = null, bool createOnly = false)
  {
    if (!ProjectIdentity.ValidId(draft.Id) || string.IsNullOrWhiteSpace(draft.Name) || draft.Name.Trim().Length > 80 || draft.Name.Any(char.IsControl))
      throw new ArgumentException("Give the project a name of up to 80 characters.");
    if (draft.Id == ProjectIdentity.IndependentId) throw new ArgumentException("Independent is kept for work outside a project.");
    if (draft.Folders.IsDefaultOrEmpty) throw new ArgumentException("Choose a home folder for this project.");
    var paths = draft.Folders.Select(folders.RequireFolder).Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal).ToImmutableArray();
    Project result;
    lock (gate)
    {
      var existing = state.Projects.FirstOrDefault(p => p.Id == draft.Id);
      if (createOnly && existing is not null) throw new InvalidOperationException("A project was just added with this ID. Choose a new ID and try again.");
      if (expected is not null && existing != expected) throw new InvalidOperationException("This project changed while you were editing. Reopen its settings before saving.");
      if (state.Projects.Any(p => p.Id != draft.Id && p.Folders.Any(f => paths.Any(path => ProjectPaths.Equal(f, path)))))
        throw new ArgumentException("That folder already belongs to another project. Open that project instead.");
      var colour = draft.Colour ?? existing?.Colour ?? ProjectIdentity.Colours[(state.Projects.Length - 1) % ProjectIdentity.Colours.Length];
      if (!ProjectIdentity.Colours.Contains(colour)) throw new ArgumentException("Choose a project colour from the list.");
      var icon = draft.Icon ?? existing?.Icon ?? "folder";
      if (icon.Length is 0 or > 80 || icon.Any(char.IsControl)) throw new ArgumentException("Choose a simple project picture.");
      result = existing is null ? new(draft.Id, draft.Name.Trim(), paths, icon, colour) : existing with { Name = draft.Name.Trim(), Folders = paths, Icon = icon, Colour = colour };
      Persist(state with { Projects = existing is null ? state.Projects.Add(result) : state.Projects.Replace(existing, result) });
    }
    Changed?.Invoke(); return result;
  }
  public string CreateFolder(string parent, string name) => folders.Create(parent, name);
  public Project Rename(string id, string name, string expectedName)
  {
    if (id == ProjectIdentity.IndependentId || string.IsNullOrWhiteSpace(name) || name.Trim().Length > 80 || name.Any(char.IsControl)) throw new ArgumentException("Give the project a name of up to 80 characters.");
    return Update(id, row => row.Name == expectedName ? row with { Name = name.Trim() } : throw new InvalidOperationException("The project name changed elsewhere. Choose Keep mine or Use saved."));
  }
  public Project OpenFolder(string folder)
  {
    var normalized = folders.RequireFolder(folder);
    var known = List().FirstOrDefault(p => p.Folders.Any(f => ProjectPaths.Equal(f, normalized)));
    if (known is null) throw new ArgumentException("Create a project with a name and home folder first. A folder alone belongs to Independent.");
    return SetOpen(known.Id, true);
  }
  public Project SetOpen(string id, bool open)
  {
    if (id == ProjectIdentity.IndependentId && !open) throw new ArgumentException("Independent is always kept open.");
    return Update(id, row => row with { IsOpen = open });
  }
  public void Select(string? id)
  {
    lock (gate) { if (id is not null) _ = Get(id); Persist(state with { ActiveProjectId = id }); }
    Changed?.Invoke();
  }
  public void Remove(string id)
  {
    lock (gate)
    {
      RequireRemovable(id); _ = Get(id); CheckRemoval(id);
      // Files, sessions, agents and seat memory survive removing a registry entry.
      Persist(state with { Projects = state.Projects.Remove(Get(id)), ActiveProjectId = state.ActiveProjectId == id ? null : state.ActiveProjectId });
    }
    Changed?.Invoke();
  }
  public void RemoveEmpty(string id)
  {
    lock (gate)
    {
      RequireRemovable(id); var p = Get(id);
      if (!p.Folders.IsEmpty || p.Lead is not null) throw new ArgumentException("This project still has folders or a lead. Use the project removal action instead.");
      CheckRemoval(id);
      Remove(id);
    }
  }
  private static void RequireRemovable(string id)
  { if (id == ProjectIdentity.IndependentId) throw new ArgumentException("Independent is always kept."); }
  public Project SetLead(string id, string? lead, string name = "")
  {
    RequireRemovable(id);
    if (lead is not null && (!(lead.StartsWith("agent:", StringComparison.Ordinal) || lead.StartsWith("session:", StringComparison.Ordinal)) || lead[(lead.IndexOf(':') + 1)..].Length == 0 || lead.Any(char.IsControl)))
      throw new ArgumentException("Choose a saved agent or a session as the lead.");
    if (name.Length > 120 || name.Any(char.IsControl)) throw new ArgumentException("Choose a short lead name.");
    return Update(id, row => row with { Lead = lead, LeadName = lead is null ? "" : name });
  }
  public Project SetPicture(string id, string? source)
  {
    if (pictures is null) throw new InvalidOperationException("Project pictures are not connected.");
    Project result;
    lock (gate)
    {
      var old = Get(id); if (id == ProjectIdentity.IndependentId) throw new ArgumentException("Independent has no project picture.");
      var logo = string.IsNullOrWhiteSpace(source) ? "" : pictures.Adopt(id, source);
      // Removing a logo is a choice: the folder's own picture is not put back by itself.
      var values = logo.Length == 0 ? old.Preferences.Values.SetItem(ProjectLogoAuto.OffKey, JsonSerializer.SerializeToElement(true)) : old.Preferences.Values.Remove(ProjectLogoAuto.OffKey);
      try { result = old with { Logo = logo, Settings = old.Preferences with { Values = values } }; Persist(state with { Projects = state.Projects.Replace(old, result) }); }
      catch { if (logo.Length > 0 && logo != old.Logo) pictures.Discard(logo); throw; }
      // Old pictures remain valid for snapshots held by remote readers. Cleanup can collect them later.
    }
    Changed?.Invoke(); return result;
  }
  public string? PicturePath(string id) => pictures?.PathFor(Get(id).Logo);
  public Project PatchSettings(string id, IReadOnlyDictionary<string, JsonElement> values)
  {
    if (values.Count > 80 || values.Any(v => v.Key.Length is 0 or > 120 || v.Key.Any(char.IsControl) || v.Value.ValueKind == JsonValueKind.Undefined) || JsonSerializer.Serialize(values).Length > 128 * 1024)
      throw new ArgumentException("Use short named settings for this project.");
    ImmutableArray<ProjectAiChoice>? choices = null;
    if (values.TryGetValue("whoUsesWhat", out var ai))
    {
      choices = ai.ValueKind == JsonValueKind.Null ? [] : JsonSerializer.Deserialize<ImmutableArray<ProjectAiChoice>>(ai, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
      ValidateChoices(choices.Value);
    }
    return Update(id, row =>
    {
      var settings = row.Preferences;
      var merged = settings.Values;
      foreach (var (key, value) in values.Where(v => v.Key != "whoUsesWhat")) merged = value.ValueKind == JsonValueKind.Null ? merged.Remove(key) : merged.SetItem(key, value.Clone());
      return row with { Settings = settings with { Values = merged, WhoUsesWhat = choices ?? settings.WhoUsesWhat } };
    });
  }
  public Project SetWhoUsesWhat(string id, IReadOnlyList<ProjectAiChoice> choices)
  {
    ValidateChoices(choices);
    return Update(id, row => row with { Settings = row.Preferences with { WhoUsesWhat = choices.ToImmutableArray() } });
  }
  private static void ValidateChoices(IReadOnlyList<ProjectAiChoice> choices)
  {
    if (choices.Count > 3 || choices.Select(c => c.Use).Distinct().Count() != choices.Count || choices.Any(c => c.Use is not ("sessions" or "chats" or "tasks") || c.Provider is not ("claude" or "codex" or "gemini") || c.AccountId is { Length: > 128 }))
      throw new ArgumentException("Choose one AI and account for each use.");
  }
  public string Resolve(string? projectId, string? folder)
  {
    if (!string.IsNullOrWhiteSpace(projectId)) return projectId;
    if (string.IsNullOrWhiteSpace(folder)) return ProjectIdentity.IndependentId;
    return List().SelectMany(p => p.Folders.Select(f => (p.Id, Folder: f))).Where(p => ProjectPaths.Contains(p.Folder, folder))
      .OrderByDescending(p => ProjectPaths.Normalize(p.Folder).Length).ThenBy(p => p.Id, StringComparer.Ordinal).FirstOrDefault().Id ?? ProjectIdentity.IndependentId;
  }
  public void BindSession(string sessionId, string projectId)
  {
    if (!Guid.TryParse(sessionId, out _) || !ProjectIdentity.ValidId(projectId)) throw new ArgumentException("Choose a session and project.");
    lock (gate) { _ = Get(projectId); Persist(state with { Sessions = state.Sessions.Where(s => s.SessionId != sessionId).Append(new(sessionId, projectId)).ToImmutableArray() }); }
    Changed?.Invoke();
  }
  public IReadOnlyList<ProjectSessionGroup> GroupSessions(IEnumerable<ProjectSession> sessions)
  {
    var snapshot = Volatile.Read(ref state); var links = snapshot.Sessions.ToDictionary(s => s.SessionId, s => s.ProjectId);
    return sessions.DistinctBy(s => s.Id).GroupBy(s => Resolve(s.ProjectId ?? links.GetValueOrDefault(s.Id), s.Folder))
      .OrderBy(g => g.Key, StringComparer.Ordinal).Select(g =>
      {
        var project = snapshot.Projects.FirstOrDefault(p => p.Id == g.Key);
        return new ProjectSessionGroup(g.Key, project?.Name ?? g.Key, project?.Logo ?? "", g.ToImmutableArray());
      }).ToArray();
  }
  public ProjectSetupScore Setup(string id, IEnumerable<ProjectSetupAgent> agents, string? card = null) => ProjectSetup.Score(Get(id), agents, card);
  private Project Update(string id, Func<Project, Project> update)
  {
    Project result;
    lock (gate) { var old = Get(id); result = update(old); Persist(state with { Projects = state.Projects.Replace(old, result) }); }
    Changed?.Invoke(); return result;
  }
  private void Persist(ProjectState next) { store.Save(next); Volatile.Write(ref state, next); }
}
