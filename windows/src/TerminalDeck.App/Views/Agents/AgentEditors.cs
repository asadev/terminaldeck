using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

public static class AgentEditors
{
  public static async Task HireAsync(XamlRoot root, IAgents agents, IProjects projects, IProjectsAgentsNavigation navigation, ProjectAgentViewModel operation, string? projectId = null, string? seatKey = null)
  {
    var name = Field("Name", max: 60); var description = Field("What it does", multiline: true);
    var category = Choice("Template", new[] { ("agent", "Agent · does the work of one role"), ("lead", "Lead · runs a project’s agents"), ("orchestrator", "Orchestrator · Hoot, built in") });
    var project = Choice("Project", projects.List().Where(p => p.IsOpen).Select(p => (p.Id, p.Name)), projectId ?? projects.ActiveProjectId ?? ProjectIdentity.IndependentId);
    var vacant = Choice("Seat", [], ""); var role = Field("New role · lowercase words and dashes", max: 64);
    var ai = Choice("Coding AI", Providers);
    var picture = new AgentPicturePicker();
    var manager = Choice("Reports to", new[] { ("", "No one · independent"), (AgentSeats.HootId, "Hoot") }.Concat(agents.List().Where(a => a.Status == SavedAgentStatus.Active).Select(a => (a.Id, a.Name))));
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var form = Stack(16); form.MinWidth = 460;
    form.Children.Add(Words("Choose a project and a role. An existing vacant role brings its memory with it.", muted: true));
    foreach (var control in new UIElement[] { category, project, vacant, role, name, picture, description, ai, manager, error }) form.Children.Add(control);
    var dialog = Dialog(root, "Add agent", form, "Add agent");
    void Seats()
    {
      vacant.Items.Clear(); vacant.Items.Add(new ChoiceRow("", "A new role"));
      var filled = agents.List().Where(a => a.Status != SavedAgentStatus.Archived).Select(a => AgentSeats.Role(a.ProjectId, a.Seat).Key).ToHashSet();
      foreach (var seat in agents.Seats().Select(s => AgentSeats.Parse(s.SeatKey)).Where(s => s.Category == AgentCategory.Agent && (s.ProjectId ?? ProjectIdentity.IndependentId) == Picked(project) && !filled.Contains(s.Key) && !s.Key.Contains("--helper-", StringComparison.Ordinal)))
        vacant.Items.Add(new ChoiceRow(seat.Key, seat.Role!.Replace('-', ' ') + " · existing memory"));
      vacant.SelectedIndex = 0;
    }
    project.SelectionChanged += (_, _) => Seats(); vacant.SelectionChanged += (_, _) => role.Visibility = Picked(vacant).Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    category.SelectionChanged += (_, _) =>
    {
      var builtIn = Picked(category) == "orchestrator"; picture.Visibility = builtIn ? Visibility.Collapsed : Visibility.Visible; dialog.PrimaryButtonText = builtIn ? "Open Hoot" : "Add agent";
      foreach (var c in new Control[] { name, description, project, vacant, role, ai, manager }) c.IsEnabled = !builtIn;
    };
    Seats();
    if (seatKey is not null) { vacant.SelectedValue = seatKey; if (vacant.SelectedIndex < 0) vacant.SelectedIndex = 0; }
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Cancel = true;
      if (Picked(category) == "orchestrator") { navigation.OpenAgent(AgentSeats.HootId); e.Cancel = false; deferral.Complete(); return; }
      SavedAgent? saved = null;
      var existingRole = Picked(vacant).Length > 0 ? AgentSeats.Parse(Picked(vacant)).Role : null;
      var ok = await operation.RunAsync(() =>
      {
        saved = agents.Hire(name.Text, Picked(ai), description.Text,
          Picked(category) == "lead" ? AgentCategory.Lead : AgentCategory.Agent, Picked(project), existingRole ?? (string.IsNullOrWhiteSpace(role.Text) ? null : role.Text.Trim()), string.IsNullOrEmpty(Picked(manager)) ? null : Picked(manager), picture.Value);
      }, "Agent saved.");
      if (ok && saved is not null) { e.Cancel = false; navigation.OpenAgent(saved.Id); }
      else { error.Message = operation.Message; error.IsOpen = true; }
      deferral.Complete();
    };
    await dialog.ShowAsync();
  }
  // Mac AGTAgentSettingsWindow: one window per agent with General, Coding AI, Limits,
  // Tools and Advanced. Every row here is applied when a session starts as this agent.
  public static async Task EditAsync(XamlRoot root, SavedAgent agent, IAgents agents, IProjects projects, ProjectAgentViewModel operation, string? focus = null)
  {
    if (AgentEditorWindow.FocusExisting(agents, agent.Id, focus)) return;
    var o = agent.Settings;
    var accounts = (operation as TerminalDeck.App.ViewModels.Agents.AgentsViewModel)?.Accounts ?? (operation as ProjectsViewModel)?.Accounts;
    // General
    var name = Field("Name", agent.Name, max: 60); var description = Field("What it does", agent.Description, true);
    var icon = new AgentPicturePicker(agent.Icon);
    var photo = Field("Profile photo", agent.PhotoPath ?? "", max: 4096);
    var choosePhoto = AsyncButton("Choose profile photo…", async () =>
    {
      var handle = AgentEditorWindow.Find(agents, agent.Id) is { } window ? WinRT.Interop.WindowNative.GetWindowHandle(window) : 0;
      if (handle != 0 && await PickPictureAsync(handle) is { } path) photo.Text = path;
    });
    var project = Choice("Project", projects.List().Select(p => (p.Id, p.Name)), agent.ProjectId); var seat = Field("Role · lowercase words and dashes", agent.Seat, max: 64);
    var boss = Choice("Reports to", new[] { ("", "No one · independent"), (AgentSeats.HootId, "Hoot") }.Concat(agents.List().Where(a => a.Id != agent.Id && (a.Status == SavedAgentStatus.Active || a.Id == agent.ReportsTo)).OrderBy(a => a.Name).Select(a => (a.Id, a.Name + " · " + (projects.List().FirstOrDefault(p => p.Id == a.ProjectId)?.Name ?? a.ProjectId)))), agent.ReportsTo ?? "");
    var status = Choice("Status", new[] { ("active", "Active"), ("paused", "Paused · takes no new work"), ("archived", "Archived") }, agent.Status.ToString().ToLowerInvariant());
    // Coding AI
    var providers = Providers.AsEnumerable(); if (!providers.Any(p => p.Item1 == agent.Provider)) providers = providers.Append((agent.Provider, agent.Provider + " · unavailable saved AI"));
    var ai = Choice("Coding AI", providers, agent.Provider); var model = Choice("Model", [], agent.Model);
    var account = Choice("Account", [], agent.AccountId ?? "");
    var accountLine = Words("", 12, true);
    void Accounts()
    {
      var provider = Picked(ai); var previous = account.Items.Count == 0 ? agent.AccountId ?? "" : Picked(account);
      account.Items.Clear(); account.Items.Add(new ChoiceRow("", "Use its role's account · project, then app default"));
      foreach (var row in accounts?.List(provider) ?? []) account.Items.Add(new ChoiceRow(row.Id, row.Name + (row.SignedIn ? "" : " · signed out")));
      if (provider == agent.Provider && agent.AccountId is { } saved && !(accounts?.List(provider).Any(a => a.Id == saved) ?? false)) account.Items.Add(new ChoiceRow(saved, "Unavailable saved account"));
      account.SelectedValue = provider == agent.Provider ? previous : ""; if (account.SelectedIndex < 0) account.SelectedIndex = 0;
      var home = projects.List().FirstOrDefault(p => p.Id == Picked(project));
      var fallback = home?.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Provider == provider && c.AccountId is not null)?.AccountId is { } chosen ? accounts?.List().FirstOrDefault(a => a.Id == chosen)
        : accounts?.Preferred(provider, home?.HomeFolder);
      accountLine.Text = "Its role's account now: " + (fallback?.Name ?? "none signed in for " + AgentSeats.ProviderName(provider)) + ". Accounts are added and signed in under Settings › Coding AIs.";
    }
    ai.SelectionChanged += (_, _) => Accounts(); project.SelectionChanged += (_, _) => Accounts(); Accounts();
    var modelRequest = 0;
    IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel> modelChoices = [];
    async Task ReadModels()
    {
      var request = ++modelRequest; var provider = Picked(ai); var saved = provider == agent.Provider ? agent.Model : "";
      try
      {
        var offered = await agents.ModelsAsync(provider, provider == agent.Provider ? agent.AccountId : null);
        if (request != modelRequest) return;
        modelChoices = offered;
        model.Items.Clear();
        foreach (var item in offered) model.Items.Add(new ChoiceRow(item.Id, item.Name));
        if (saved.Length > 0 && !offered.Any(m => m.Id == saved)) model.Items.Add(new ChoiceRow(saved, saved + " · unavailable saved model"));
        model.SelectedValue = saved;
        if (model.SelectedIndex < 0 && offered.Count > 0) model.SelectedValue = (offered.FirstOrDefault(m => m.IsDefault) ?? offered[0]).Id;
        model.PlaceholderText = offered.Count == 0 ? "Models unavailable · check Coding AIs" : "";
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { model.PlaceholderText = "Models unavailable · check Coding AIs"; }
    }
    ai.SelectionChanged += async (_, _) => await ReadModels(); _ = ReadModels();
    var effort = Choice("Effort", [], "");
    void EffortAvailability()
    {
      var previous = Picked(effort); var values = Picked(ai) == "gemini" ? new[] { "auto" } : TerminalDeck.Core.Accounts.ModelEfforts.For(Picked(ai), modelChoices.FirstOrDefault(m => m.Id == Picked(model))).ToArray();
      effort.Visibility = Picked(ai) == "gemini" ? Visibility.Collapsed : Visibility.Visible;
      effort.Items.Clear(); foreach (var value in values) effort.Items.Add(new ChoiceRow(value, value == "auto" ? "Automatic" : TerminalDeck.Core.Accounts.ModelCatalog.EffortName(value)));
      if (Picked(ai) == agent.Provider && !values.Contains(agent.Effort) && agent.Effort != "auto") effort.Items.Add(new ChoiceRow(agent.Effort, agent.Effort + " · unavailable saved effort"));
      effort.SelectedValue = previous.Length > 0 ? previous : agent.Effort; if (effort.SelectedIndex < 0) effort.SelectedValue = Picked(ai) == "gemini" ? "auto" : "medium";
    }
    ai.SelectionChanged += (_, _) => EffortAvailability(); model.SelectionChanged += (_, _) => EffortAvailability(); EffortAvailability();
    var permission = Choice("Before it changes files", new[] { ("", "App default") }.Concat(AgentOptions.PermissionModes.Select(m => (m, AgentOptions.PermissionLabel(m)))), o.PermissionMode ?? "");
    // Limits
    var limits = Choice("Tasks at once", new[] { ("none", "No limit"), ("limited", "Set a limit") }, agent.MaxConcurrentTasks is null ? "none" : "limited");
    var taskLimit = new NumberBox { Header = "Maximum tasks at once", Minimum = 1, Maximum = int.MaxValue, Value = agent.MaxConcurrentTasks ?? 1, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    void LimitVisibility() => taskLimit.Visibility = Picked(limits) == "none" ? Visibility.Collapsed : Visibility.Visible;
    limits.SelectionChanged += (_, _) => LimitVisibility(); LimitVisibility();
    // Tools
    static string Join(ImmutableArray<string> rows) => string.Join(", ", rows.IsDefault ? [] : rows);
    static ImmutableArray<string> Split(string text) => text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToImmutableArray();
    var preferred = Field("Tools it should use · names separated by commas", Join(o.ToolsPreferred), max: 4000);
    var avoided = Field("Tools it should avoid · names separated by commas", Join(o.ToolsAvoided), max: 4000);
    var skills = Field("Skills · names separated by commas", Join(agent.Skills));
    var skillsOff = new ToggleSwitch { Header = "Turn all skills off", IsOn = o.SkillsOff };
    // Advanced
    var folder = Field("Working folder · used when a task names none", o.WorkingFolder ?? "", max: 1000);
    folder.PlaceholderText = "Project home folder";
    var form = Stack(16); form.MinWidth = 460;
    var panels = new Dictionary<string, StackPanel>();
    StackPanel Panel(string title, params UIElement[] rows) { var p = Stack(14); foreach (var r in rows) p.Children.Add(r); panels[title] = p; return p; }
    var category = agents.SeatOf(agent.Id).Category; var template = agents.Templates().Single(t => t.Category == category);
    string Limit(int value) => value == 0 ? "No limit" : value.ToString();
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    Panel("General", name, photo, choosePhoto, icon, description, project, seat, boss, status, Words("Changing the role leaves its memory in the old seat for the next hire.", 12, true));
    Panel("Coding AI", ai, account, accountLine, model, effort, permission,
      Words("Before it changes files: App default uses the app's setting; Plan only lets it read and plan; Change without asking lets it edit files in its folder.", 12, true));
    Panel("Limits", limits, taskLimit, Words("Category template: " + Limit(template.MaxHandsPerSeat) + " hands per seat; " + Limit(template.MaxHandsPerProject) + " per project.", 12, true),
      AsyncButton("Edit category template", () => TemplatesAsync(form.XamlRoot, agents, operation, category)));
    Panel("Tools", preferred, avoided, Words("These are named in its brief as advice.", 12, true), skills, skillsOff);
    var chooseFolder = AsyncButton("Choose…", async () =>
    {
      var handle = AgentEditorWindow.Find(agents, agent.Id) is { } window ? WinRT.Interop.WindowNative.GetWindowHandle(window) : 0;
      if (handle != 0 && await PickFolderAsync(handle) is { } path) folder.Text = path;
    });
    Panel("Advanced", folder, chooseFolder, Words("Instructions and skills are written and chosen on its page, under Instructions and Skills.", 12, true),
      AsyncButton("Show its file", async () =>
      {
        await operation.RunAsync(() =>
        {
          var path = agents.Get(agent.Id).InstructionsFile ?? throw new InvalidOperationException("This agent has no file yet. Save its instructions to create one.");
          System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { Arguments = "/select,\"" + path.Replace("\"", "") + "\"", UseShellExecute = true });
        }, "Its file is shown in Explorer.");
        error.Message = operation.Message; error.Severity = operation.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational; error.IsOpen = operation.IsError;
      }));
    var current = "General";
    var tabs = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    void Show(string tab)
    {
      current = tab; foreach (var (title, panel) in panels) panel.Visibility = title == tab ? Visibility.Visible : Visibility.Collapsed;
      tabs.Content = ViewSwitch(tab, panels.Keys, Show);
    }
    form.Children.Add(tabs); foreach (var panel in panels.Values) form.Children.Add(panel); form.Children.Add(error); Show(current);
    void Focus(string? field)
    {
      var tab = field switch { "ai" or "model" or "effort" or "account" or "permission" => "Coding AI", "limits" => "Limits", "skills" or "tools" => "Tools", "folder" => "Advanced", _ => "General" };
      Show(tab);
      Control target = field switch { "description" => description, "ai" => ai, "model" => model, "effort" => effort, "account" => account, "permission" => permission, "role" => seat, "manager" => boss, "status" => status, "skills" => skills, "limits" => limits, "folder" => folder, "tools" => preferred, _ => name };
      target.Focus(FocusState.Programmatic);
    }
    await AgentEditorWindow.ShowAsync(agents, agent.Id, agent.Name + " — Agent settings", root, form, Focus, focus, async () =>
    {
      var ok = await operation.RunAsync(() => agents.Save(agent with
      {
        Name = name.Text, Description = description.Text, Provider = Picked(ai), Model = Picked(model) is { Length: > 0 } selectedModel ? selectedModel : throw new ArgumentException("Choose a model before saving."), Effort = Picked(effort), ProjectId = Picked(project), Seat = seat.Text,
        ReportsTo = Picked(boss).Length == 0 ? null : Picked(boss), Icon = icon.Value, PhotoPath = string.IsNullOrWhiteSpace(photo.Text) ? null : photo.Text.Trim(), Skills = Split(skills.Text),
        MaxConcurrentTasks = Picked(limits) == "none" ? null : double.IsFinite(taskLimit.Value) && taskLimit.Value >= 1 && taskLimit.Value <= int.MaxValue && taskLimit.Value == Math.Truncate(taskLimit.Value) ? (int)taskLimit.Value : throw new ArgumentException("Choose a whole number of tasks or No limit."),
        Status = Enum.Parse<SavedAgentStatus>(Picked(status), true), AccountId = Picked(account).Length == 0 ? null : Picked(account),
        Options = o with { PermissionMode = Picked(permission).Length == 0 ? null : Picked(permission), WorkingFolder = string.IsNullOrWhiteSpace(folder.Text) ? null : folder.Text.Trim(),
          ToolsPreferred = Split(preferred.Text), ToolsAvoided = Split(avoided.Text), SkillsOff = skillsOff.IsOn }
      }, agent));
      error.Message = operation.Message; error.Severity = InfoBarSeverity.Error; error.IsOpen = !ok; return ok;
    });
  }
  // Mac Skills tab "Give more": the skills really installed for this project and for the
  // person, each a checkbox. Saved names that are not installed stay assigned.
  public static async Task SkillsAsync(XamlRoot root, SavedAgent agent, IAgents agents, IProjects projects, ProjectAgentViewModel operation)
  {
    var folders = projects.List().FirstOrDefault(p => p.Id == agent.ProjectId)?.Folders ?? [];
    var installed = await Task.Run(() => AgentSkills.Find(AgentSkills.Roots(folders)));
    var assigned = (agent.Skills.IsDefault ? [] : agent.Skills).ToHashSet(StringComparer.OrdinalIgnoreCase);
    var form = Stack(8); form.MinWidth = 460;
    var search = new AutoSuggestBox { PlaceholderText = "Find a skill" }; form.Children.Add(search);
    var list = Stack(4); form.Children.Add(list);
    var boxes = new List<(InstalledSkill Skill, CheckBox Box)>();
    foreach (var skill in installed)
    {
      var box = new CheckBox { IsChecked = assigned.Contains(skill.Name) };
      var words = Stack(0); words.Children.Add(Words(skill.Name, 13)); words.Children.Add(Words((skill.Description.Length > 0 ? skill.Description + " · " : "") + skill.Where, 11, true));
      box.Content = words; boxes.Add((skill, box)); list.Children.Add(box);
    }
    if (installed.Count == 0) list.Children.Add(Words("No skills are installed for this project or for you. A skill is a folder with a SKILL.md file under .claude\\skills.", muted: true));
    search.TextChanged += (_, _) => { foreach (var (skill, box) in boxes) box.Visibility = skill.Name.Contains(search.Text, StringComparison.OrdinalIgnoreCase) || skill.Description.Contains(search.Text, StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed; };
    var missing = assigned.Where(n => !installed.Any(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase))).ToArray();
    if (missing.Length > 0) form.Children.Add(Words("Also assigned, not installed here: " + string.Join(", ", missing) + ". They stay assigned.", 12, true));
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; form.Children.Add(error);
    var dialog = Dialog(root, "Skills for " + agent.Name, form, "Save skills");
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral();
      try
      {
        var chosen = missing.Concat(boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Skill.Name)).Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        e.Cancel = !await operation.RunAsync(() => agents.Save(agent with { Skills = chosen }, agent), "Skills saved."); error.Message = operation.Message; error.IsOpen = e.Cancel;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }

  public static async Task InstructionsAsync(XamlRoot root, SavedAgent agent, IAgents agents, ProjectAgentViewModel operation)
  {
    var form = Stack(16); form.MinWidth = 460;
    var file = Words(agent.InstructionsFile ?? "Saving creates this agent’s Markdown instructions file in the app’s data folder.", 12, true);
    var text = Field("Instructions for this agent", multiline: true, max: 500000);
    if (!await operation.RunAsync(() => text.Text = agents.ReadInstructions(agent.Id), "Instructions opened.")) return;
    var baseline = text.Text;
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    form.Children.Add(file); form.Children.Add(text); form.Children.Add(Words("The category template and the role’s card are added when a session starts.", 13, true));
    var conflict = Stack(8); conflict.Visibility = Visibility.Collapsed; form.Children.Add(error); form.Children.Add(conflict);
    var dialog = Dialog(root, "Instructions", form);
    async Task<bool> Save(bool overwrite = false)
    {
      var draft = text.Text;
      var ok = await operation.RunAsync(() => agents.SaveInstructions(agent.Id, draft, overwrite ? null : baseline), "Instructions saved.");
      error.Message = operation.Message; error.IsOpen = !ok;
      if (!ok) conflict.Visibility = Visibility.Visible;
      return ok;
    }
    conflict.Children.Add(AsyncButton("Keep mine", async () => { if (await Save(overwrite: true)) dialog.Hide(); }));
    conflict.Children.Add(AsyncButton("Use file", async () =>
    {
      if (await operation.RunAsync(() => text.Text = agents.ReadInstructions(agent.Id), "Instructions reloaded."))
      { baseline = text.Text; conflict.Visibility = Visibility.Collapsed; error.IsOpen = false; }
      else { error.Message = operation.Message; error.IsOpen = true; }
    }));
    if (agent.InstructionsFile is { } path) form.Children.Add(AsyncButton("Show in Explorer", async () =>
    {
      await operation.RunAsync(() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { Arguments = "/select,\"" + path.Replace("\"", "") + "\"", UseShellExecute = true }), "Instructions file shown.");
    }));
    var shortcut = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.S, Modifiers = Windows.System.VirtualKeyModifiers.Control };
    shortcut.Invoked += async (_, e) => { if (!dialog.IsLoaded) return; e.Handled = true; if (await Save()) dialog.Hide(); }; dialog.KeyboardAccelerators.Add(shortcut);
    dialog.PrimaryButtonClick += async (_, e) => { var d = e.GetDeferral(); try { e.Cancel = !await Save(); } finally { d.Complete(); } };
    await dialog.ShowAsync();
  }
  public static async Task TemplatesAsync(XamlRoot root, IAgents agents, ProjectAgentViewModel operation, AgentCategory selected = AgentCategory.Agent)
  {
    var category = Choice("Category", Enum.GetValues<AgentCategory>().Select(c => (c.ToString(), c.ToString())), selected.ToString());
    var text = Field("Shared instructions", multiline: true, max: 40000);
    var helperAI = Choice("Helper AI", Providers); var helperModel = Field("Helper model", max: 160); var checklist = Field("Helper checklist", multiline: true, max: 20000);
    var perSeat = new NumberBox { Header = "Hands per seat · 0 means No limit", Minimum = 0, Maximum = int.MaxValue, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    var perProject = new NumberBox { Header = "Hands per project · 0 means No limit", Minimum = 0, Maximum = int.MaxValue, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    var cardLimit = new NumberBox { Header = "Card limit warning", Minimum = 500, Maximum = 40000, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    var card = new CheckBox { Content = "Card" }; var notes = new CheckBox { Content = "Notes" };
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var form = Stack(16); form.MinWidth = 460; form.Children.Add(Words("One template applies to every seat in its category, including future hires. Seat memory stays separate.", muted: true));
    foreach (var control in new UIElement[] { category, text, card, notes, helperAI, helperModel, checklist, cardLimit, perSeat, perProject, error }) form.Children.Add(control);
    var drafts = agents.Templates().ToDictionary(t => t.Category); var baselines = new Dictionary<AgentCategory, AgentTemplate>(drafts); var current = selected; var reading = false;
    int Whole(NumberBox box)
    {
      if (!double.IsFinite(box.Value) || box.Value < box.Minimum || box.Value > box.Maximum || box.Value != Math.Truncate(box.Value)) throw new ArgumentException("Choose a whole number within the displayed range.");
      return (int)box.Value;
    }
    void Read()
    {
      reading = true;
      try
      {
        var t = drafts[current]; text.Text = t.Instructions; perSeat.Value = t.MaxHandsPerSeat; perProject.Value = t.MaxHandsPerProject;
        helperAI.SelectedValue = t.HelperAI; helperModel.Text = t.HelperModel; checklist.Text = t.Checklist; cardLimit.Value = t.CardLimit;
        card.IsChecked = t.Parts.IsDefault || t.Parts.Contains("card"); notes.IsChecked = t.Parts.IsDefault || t.Parts.Contains("notes");
      }
      finally { reading = false; }
    }
    bool Keep()
    {
      try
      {
        var original = drafts[current]; var parts = (original.Parts.IsDefault ? [] : original.Parts).Where(p => p is not ("card" or "notes")).ToList();
        if (card.IsChecked == true) parts.Add("card"); if (notes.IsChecked == true) parts.Add("notes");
        drafts[current] = original with { Instructions = text.Text, MaxHandsPerSeat = Whole(perSeat), MaxHandsPerProject = Whole(perProject),
          HelperAI = Picked(helperAI), HelperModel = helperModel.Text, Checklist = checklist.Text, CardLimit = Whole(cardLimit), Parts = parts.ToImmutableArray() };
        error.IsOpen = false; return true;
      }
      catch (ArgumentException ex) { error.Message = ex.Message; error.IsOpen = true; return false; }
    }
    bool Same(AgentTemplate a, AgentTemplate b) => a with { Parts = default } == b with { Parts = default } &&
      (a.Parts.IsDefault ? new[] { "card", "notes" } : a.Parts.ToArray()).ToHashSet().SetEquals(b.Parts.IsDefault ? ["card", "notes"] : b.Parts);
    bool Dirty() => drafts.Values.Any(t => !Same(t, agents.Templates().Single(saved => saved.Category == t.Category)));
    category.SelectionChanged += (_, _) =>
    {
      if (reading) return;
      if (!Keep()) { reading = true; category.SelectedValue = current.ToString(); reading = false; return; }
      current = Enum.Parse<AgentCategory>(Picked(category)); Read();
    }; Read();
    form.Children.Add(AsyncButton("Save for category", async () =>
    {
      if (!Keep()) return;
      if (await operation.RunAsync(() => agents.SaveTemplate(drafts[current], baselines[current]), "Category template saved.")) baselines[current] = drafts[current] = agents.Templates().Single(t => t.Category == current);
      error.Message = operation.Message; error.Severity = operation.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Success; error.IsOpen = true;
    }));
    form.Children.Add(Button("Revert", () => { baselines[current] = drafts[current] = agents.Templates().Single(t => t.Category == current); Read(); error.IsOpen = false; }));
    var host = new Grid { MinWidth = 460 }; host.Children.Add(form);
    var discardNotice = Words("There are unsaved template changes."); discardNotice.Visibility = Visibility.Collapsed; host.Children.Add(discardNotice);
    var dialog = Dialog(root, "Templates", host, "Done"); var allowClose = false; var asking = false;
    void KeepEditing()
    {
      asking = false; dialog.Title = "Templates"; form.Visibility = Visibility.Visible; discardNotice.Visibility = Visibility.Collapsed; dialog.PrimaryButtonText = "Done"; dialog.SecondaryButtonText = ""; dialog.CloseButtonText = "Cancel";
    }
    dialog.PrimaryButtonClick += (_, e) => { if (asking) { e.Cancel = true; KeepEditing(); } };
    dialog.SecondaryButtonClick += (_, _) => { if (asking) allowClose = true; };
    dialog.Closing += (_, e) =>
    {
      if (allowClose) return;
      if (asking) { e.Cancel = true; KeepEditing(); return; }
      if (!Keep() || Dirty())
      {
        e.Cancel = true; asking = true; dialog.Title = "Unsaved template changes"; form.Visibility = Visibility.Collapsed; discardNotice.Visibility = Visibility.Visible;
        dialog.PrimaryButtonText = "Keep Editing"; dialog.SecondaryButtonText = "Close Without Saving"; dialog.CloseButtonText = ""; dialog.DefaultButton = ContentDialogButton.Primary;
      }
    };
    await dialog.ShowAsync();
  }
  public static async Task SeatCardAsync(XamlRoot root, string id, IAgents agents, ProjectAgentViewModel operation)
  {
    var seat = agents.SeatOf(id); var old = agents.Seats().FirstOrDefault(s => s.SeatKey == seat.Key) ?? new AgentSeatMemory(seat.Key);
    var card = Field("This role’s own card", old.Card, true, 40000); var form = Stack(16); form.MinWidth = 460;
    form.Children.Add(Words(seat.Key + " · memory stays here when this agent leaves.", 13, true)); form.Children.Add(card);
    if (old.Notes.Length > 0) { form.Children.Add(Heading("Kept notes", 16)); form.Children.Add(Words(old.Notes, 13, true)); }
    var template = agents.Templates().Single(t => t.Category == seat.Category);
    form.Children.Add(Heading("Shared template", 16)); form.Children.Add(Words(template.Instructions, 13, true));
    var warning = new TerminalDeck.App.Views.Notices.CompactNotice { Severity = InfoBarSeverity.Warning, IsClosable = false, Message = "This card is longer than its category template’s warning limit. You can still save it." };
    void Warn() => warning.IsOpen = card.Text.Length > template.CardLimit;
    card.TextChanged += (_, _) => Warn(); Warn(); form.Children.Add(warning);
    form.Children.Add(Button("Revert", () => card.Text = old.Card));
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { Severity = InfoBarSeverity.Error, IsClosable = false }; form.Children.Add(error);
    var dialog = Dialog(root, "Role memory", form);
    dialog.PrimaryButtonClick += async (_, e) => { var d = e.GetDeferral(); try { e.Cancel = !await operation.RunAsync(() => agents.SaveSeatMemory(seat.Key, card.Text, old.Notes, old)); error.Message = operation.Message; error.IsOpen = e.Cancel; } finally { d.Complete(); } };
    await dialog.ShowAsync();
  }
}
