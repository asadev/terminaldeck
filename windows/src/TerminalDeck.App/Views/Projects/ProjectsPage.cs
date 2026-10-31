using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Projects;

public sealed class ProjectsPage : Grid
{
  public ProjectsViewModel Model { get; }
  private readonly IProjectsAgentsNavigation navigation;
  private string query = "";
  private string section = "Overview";
  private readonly Action changed;
  public ProjectsPage(ProjectsViewModel model, IProjectsAgentsNavigation navigation)
  {
    Model = model; this.navigation = navigation; Style = PageStyle();
    var dispatcher = DispatcherQueue; changed = () => dispatcher.TryEnqueueHandled(Render);
    Loaded += (_, _) => { Model.Changed += changed; Render(); };
    Unloaded += (_, _) => Model.Changed -= changed;
    Render();
  }
  public void OpenProject(string id, string tab = "Overview")
  {
    section = tab == "Settings" ? "Overview" : tab; Model.SelectedId = id; Render();
    if (tab != "Settings") return;
    if (XamlRoot is not null) _ = ShowSettingsAsync(id);
    else
    {
      RoutedEventHandler? ready = null;
      ready = async (_, _) => { Loaded -= ready; await ShowSettingsAsync(id); }; Loaded += ready;
    }
  }
  public Task ChooseLogoAsync(string id) => EditPictureAsync(Model.Projects.Get(id));
  public Task OpenProjectPickerAsync() => OpenSavedAsync();
  public Task ShowSettingsAsync(string id) => ProjectSettingsWindow.ShowAsync(XamlRoot, Model, id);
  private void Render()
  {
    Children.Clear();
    var body = Stack(16); body.Margin = new Thickness(24); body.MaxWidth = 1100; body.HorizontalAlignment = HorizontalAlignment.Stretch;
    if (Model.Selected is { } project) Detail(body, project); else Directory(body);
    if (Model.IsBusy) body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
    if (Model.Message.Length > 0) body.Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Severity = Model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = Model.Message });
    Children.Add(PageScroll(body));
  }
  private void Directory(StackPanel body)
  {
    body.Children.Add(PageHeader("Projects", "", null, null,
      AsyncButton("Open saved project", OpenSavedAsync), AsyncButton("New project", () => ShowSetupAsync(), true)));
    var search = new AutoSuggestBox { PlaceholderText = "Find a project", Text = query, MaxWidth = 420, HorizontalAlignment = HorizontalAlignment.Left };
    var list = Stack(4);
    void Fill()
    {
      list.Children.Clear(); var rows = Model.OpenProjects(query).Where(p => p.Id != ProjectIdentity.IndependentId).ToList();
      foreach (var project in rows)
      {
        // The directory is a single, full-width destination, like the Mac folder list.
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(12) };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(ProjectPicture(Model.Projects, project, 24));
        var name = Words(project.Name); name.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(name, 1); row.Children.Add(name);
        var arrow = new DeckIcon { Glyph = "\uE76C", FontSize = 12, Opacity = 0.5 }; Grid.SetColumn(arrow, 2); row.Children.Add(arrow);
        var open = Destination(row, "Open " + project.Name, () => OpenProject(project.Id));
        open.HorizontalAlignment = HorizontalAlignment.Stretch; open.HorizontalContentAlignment = HorizontalAlignment.Stretch; open.Padding = new Thickness(0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, "Open " + project.Name); list.Children.Add(open);
      }
      if (rows.Count == 0) list.Children.Add(Words(query.Length == 0 ? "No projects yet. Create one to keep its sessions together." : "No projects match that search.", muted: true));
    }
    search.TextChanged += (_, _) => { query = search.Text; Fill(); }; Fill();
    body.Children.Add(search); body.Children.Add(list);
  }
  private void Detail(StackPanel body, Project project)
  {
    body.Children.Add(Button("‹  Projects", () => { Model.SelectedId = null; }));
    var switcher = ViewSwitch(section, new[] { "Overview", "Sessions", "Agents" }, name => { section = name; Render(); });
    var actions = new List<UIElement>();
    if (project.Id != ProjectIdentity.IndependentId)
    {
      // Mac: the gear holds Project settings, Setup guide and the lead and description edits.
      var gear = new MenuFlyout();
      void Item(string text, Func<Task> act) { var item = new MenuFlyoutItem { Text = text }; item.Click += async (_, _) => await act(); gear.Items.Add(item); }
      Item("Project settings…", () => ShowSettingsAsync(project.Id));
      Item("Setup guide…", () => ShowSetupAsync(project.Id));
      Item("Choose project lead…", () => EditLeadAsync(project));
      Item("Edit what it is…", () => EditDescriptionAsync(project));
      Item("Change logo…", () => EditPictureAsync(project));
      var settings = IconButton("\uE713", "Project settings", () => { }); settings.Flyout = gear; actions.Add(settings);
    }
    actions.Add(AsyncButton("New session", () => NewSessionPicker.ShowAsync(XamlRoot, Model.Agents, Model.Projects, Model.Accounts, navigation, project.Id), true));
    var subtitle = project.HomeFolder is { } home ? home + (project.Folders.Length > 1 ? $" · +{project.Folders.Length - 1} folders" : "") : "Independent";
    body.Children.Add(PageHeader(project.Name, subtitle, ProjectPicture(Model.Projects, project, 30), switcher, actions.ToArray()));
    if (project.Id != ProjectIdentity.IndependentId)
    {
      var score = Model.SetupFor(project.Id);
      if (!score.Complete && section == "Overview")
      {
        var setup = Stack(8); setup.Children.Add(Heading($"Setup {score.Percent}%", 16));
        setup.Children.Add(Words("Still to add: " + string.Join(", ", score.Missing) + ". You can do these whenever you are ready.", 13, true));
        // One row of short steps, not a tall column of buttons.
        var steps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var missing in score.Missing)
          steps.Children.Add(AsyncButton(missing, () => ShowSetupAsync(project.Id, step: ProjectSetup.StepFor(missing))));
        setup.Children.Add(steps);
        body.Children.Add(Card(setup));
      }
    }
    if (section == "Overview")
    {
      var about = project.Preferences.Text("about");
      if (about.Length > 0) body.Children.Add(Card(Description(about)));
      var summary = Stack(4);
      summary.Children.Add(Fact("Sessions", Model.SessionsFor(project.Id).Count.ToString(), "Show project sessions", () => { section = "Sessions"; Render(); }));
      summary.Children.Add(Fact("Agents", Model.AgentsFor(project.Id).Count.ToString(), "Show project agents", () => { section = "Agents"; Render(); }));
      if (project.Id != ProjectIdentity.IndependentId) summary.Children.Add(Fact("Lead", project.LeadName.Length > 0 ? project.LeadName : project.Preferences.Flag("setup.hootLeads") ? "Hoot leads for now" : "No lead", "Choose project lead", () => _ = EditLeadAsync(project)));
      if (project.Id != ProjectIdentity.IndependentId) summary.Children.Add(Fact("Lead memory", Model.Agents.Seats().FirstOrDefault(s => s.SeatKey == "lead:" + project.Id)?.Card is { Length: > 0 } card ? card.Split('\n')[0] : "Empty", "Open the lead's memory",
        () => { if (project.Lead?.StartsWith("agent:", StringComparison.Ordinal) == true) navigation.OpenAgent(project.Lead[6..]); else _ = EditLeadAsync(project); }));
      body.Children.Add(Card(summary));
      var team = Model.AgentsFor(project.Id);
      if (team.Count > 0)
      {
        var working = team.Count(a => Model.Activity(a).State == AgentActivityState.Working);
        body.Children.Add(Header("Team", $"{team.Count} agents · {working} working now", Button("Show all", () => { section = "Agents"; Render(); })));
        body.Children.Add(AdaptiveColumns(team.OrderByDescending(a => Model.Leads(a, project)).ThenBy(a => a.Name).Take(8).Select(a => (UIElement)TeamRow(a, project)), 260));
      }
    }
    else if (section == "Sessions")
    {
      var sessions = Model.SessionsFor(project.Id); body.Children.Add(Heading($"Sessions · {sessions.Count}", 20));
      if (sessions.Count == 0) body.Children.Add(Card(Words("No sessions here yet. Start one with an agent or choose No agent to use an AI directly.", muted: true)));
      foreach (var session in sessions)
      {
        var identity = SessionIdentity(Model.Projects, Model.Agents, session.Id, session.Title, session.Provider, session.Mode, project.Id);
        body.Children.Add(Destination(SessionIdentityRow(identity), "Open " + session.Title + " · " + identity.DisplaySubtitle, () => navigation.OpenSession(session.Id)));
      }
    }
    else if (section == "Agents")
    {
      var agents = Model.AgentsFor(project.Id); body.Children.Add(Header($"Agents · {agents.Count}", "The roles and people working on this project.",
        AsyncButton("Add agent", () => AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, project.Id))));
      if (agents.Count == 0) body.Children.Add(Card(Words("No agents on this project yet. Add a role when you need one.", muted: true)));
      foreach (var agent in agents.OrderByDescending(a => Model.Leads(a, project)).ThenBy(a => a.Name)) body.Children.Add(TeamRow(agent, project));
      var filled = Model.Agents.List().Where(a => a.Status != SavedAgentStatus.Archived).Select(a => AgentSeats.Role(a.ProjectId, a.Seat).Key).ToHashSet();
      foreach (var seat in Model.Agents.Seats().Select(s => s.SeatKey).Where(k => k.StartsWith("role:" + project.Id + "/", StringComparison.Ordinal) && !filled.Contains(k) && !k.Contains("--helper-", StringComparison.Ordinal)))
        body.Children.Add(Fact("Vacant · " + seat[(seat.IndexOf('/') + 1)..].Replace('-', ' '), "Its memory is kept for the next hire", "Hire into this role",
          () => _ = AgentEditors.HireAsync(XamlRoot, Model.Agents, Model.Projects, navigation, Model, project.Id, seat)));
    }
    else body.Children.Add(Words("Choose Overview, Sessions or Agents for this project.", muted: true));
    if (project.Id != ProjectIdentity.IndependentId) body.Children.Add(AsyncButton("Remove from sidebar…", async () =>
    {
      await navigation.RemoveFromSidebarAsync(project.Id);
      if (!Model.Projects.Get(project.Id).IsOpen) Model.SelectedId = null;
    }));
  }
  private Button TeamRow(SavedAgent agent, Project project)
  {
    var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(12, 8, 12, 8) };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(AgentPicture(agent, 30));
    var words = Stack(2); words.Children.Add(Words(agent.Name));
    var activity = Model.Activity(agent);
    words.Children.Add(Words((Model.Leads(agent, project) ? "Lead" : TerminalDeck.App.ViewModels.Agents.AgentsViewModel.RoleWords(agent.Seat)) + " · " + activity.Label + " · " + TerminalDeck.App.Views.Agents.AgentsPage.AppWideModel(agent, effort: false), 12, true));
    Grid.SetColumn(words, 1); row.Children.Add(words);
    var arrow = new DeckIcon { Glyph = "\uE76C", FontSize = 12, Opacity = 0.5, VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(arrow, 2); row.Children.Add(arrow);
    return Destination(row, "Open " + agent.Name + ", " + activity.Label, () => navigation.OpenAgent(agent.Id));
  }
  private async Task OpenSavedAsync()
  {
    var closed = Model.Projects.List().Where(p => !p.IsOpen).ToArray();
    if (closed.Length == 0) { await new ContentDialog { XamlRoot = XamlRoot, Title = "All saved projects are open", Content = Words("Create a named project to add a new home folder."), CloseButtonText = "Done" }.ShowAsync(); return; }
    var picker = Choice("Project", closed.Select(p => (p.Id, p.Name))); var dialog = Dialog(XamlRoot, "Open saved project", picker, "Open");
    if (await dialog.ShowAsync() == ContentDialogResult.Primary && await Model.RunAsync(() => Model.Projects.SetOpen(Picked(picker), true), "Project opened.")) OpenProject(Picked(picker));
  }
  private async Task EditProjectAsync(Project project)
  {
    var name = Field("Name", project.Name, max: 80); var folder = Field("Home folder", project.HomeFolder ?? ""); var others = Field("Other folders · one per line", string.Join('\n', project.Folders.Skip(1)), true);
    var form = Stack(16); form.Children.Add(name); form.Children.Add(folder); form.Children.Add(AsyncButton("Choose home folder…", async () => { if (await PickFolderAsync(navigation.WindowHandle) is { } path) folder.Text = path; })); form.Children.Add(others);
    var error = new Notices.CompactNotice(); form.Children.Add(error); var dialog = Dialog(XamlRoot, "Project settings", form);
    dialog.PrimaryButtonClick += async (_, e) => { var deferral = e.GetDeferral(); e.Cancel = !await Model.RunAsync(() => Model.Projects.Save(new(project.Id, name.Text, new[] { folder.Text }.Concat(others.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)).ToImmutableArray()))); error.Text = Model.IsError ? Model.Message : ""; deferral.Complete(); };
    await dialog.ShowAsync();
  }
  private async Task EditDescriptionAsync(Project project)
  {
    var about = Field("What this project is for", project.Preferences.Text("about"), true); var dialog = Dialog(XamlRoot, "What it is", about);
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.SaveValuesAsync(project.Id, new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement(about.Text) });
  }
  private async Task EditPictureAsync(Project project)
  {
    var content = Stack(16); content.Children.Add(ProjectPicture(Model.Projects, project, 96)); content.Children.Add(Words("Choose an image. A small copy is saved with this project; the original stays where it is.", muted: true));
    var path = Field("Image file"); content.Children.Add(path); content.Children.Add(AsyncButton("Choose image…", async () => { if (await PickPictureAsync(navigation.WindowHandle) is { } chosen) path.Text = chosen; }));
    var dialog = Dialog(XamlRoot, "Project picture", content, "Use picture"); if (project.Logo.Length > 0) dialog.SecondaryButtonText = "Remove picture";
    var result = await dialog.ShowAsync();
    if (result == ContentDialogResult.Primary) await Model.RunAsync(() => Model.Projects.SetPicture(project.Id, path.Text));
    else if (result == ContentDialogResult.Secondary) await Model.RunAsync(() => Model.Projects.SetPicture(project.Id, null));
  }
  private async Task EditLeadAsync(Project project)
  {
    var options = new[] { ("", "No lead"), ("hoot", "Hoot leads for now") }.Concat(Model.AgentsFor(project.Id).Select(a => (a.Id, a.Name)));
    var lead = Choice("Lead", options, project.Lead?.StartsWith("agent:", StringComparison.Ordinal) == true ? project.Lead[6..] : project.Preferences.Flag("setup.hootLeads") ? "hoot" : "");
    var dialog = Dialog(XamlRoot, "Who leads this project?", lead);
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    await Model.RunAsync(() =>
    {
      var id = Picked(lead); Model.Agents.SetProjectLead(project.Id, id is "" or "hoot" ? null : id);
      Model.Projects.PatchSettings(project.Id, new Dictionary<string, JsonElement> { ["setup.hootLeads"] = JsonSerializer.SerializeToElement(id == "hoot") });
    });
  }
  public Task ShowSetupAsync(string? projectId = null, string? folder = null, string? step = null) => ProjectSetupDialog.ShowAsync(XamlRoot, Model, navigation, projectId, folder, step);
}
