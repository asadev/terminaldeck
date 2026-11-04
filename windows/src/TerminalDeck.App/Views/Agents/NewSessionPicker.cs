using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

public static class NewSessionPicker
{
  internal static TerminalDeck.App.Integration.OtherComputersService? Computers { get; set; }
  internal static CustomTerminalProviders? TerminalProviders { get; set; }
  internal static Func<string, string, string, Task>? CustomTerminalStart { get; set; }
  internal static ContentDialog? ActiveDialogForProof { get; private set; }
  // App-wide inputs the many callers do not carry: recently used folders, the
  // app-wide model/effort (Settings → Coding AIs) and the permission default.
  internal sealed record PickerServices(Func<IEnumerable<string>> RecentFolders, Func<string, (string Model, string? Effort)> Launch, Func<string, AiPermissionMode> Permission, Func<string>? ShellLabel = null);
  internal static PickerServices? Services { get; set; }
  public static async Task ShowAsync(XamlRoot root, IAgents agents, IProjects projects, AccountService? accounts,
    IProjectsAgentsNavigation navigation, string? projectId = null, string? agentId = null, string mode = "chat", CancellationToken cancellationToken = default, Func<string, string, Task>? terminalStart = null, bool requireJob = false, Func<FrameworkElement, Task>? renderForProof = null)
  {
    if (renderForProof is not null && (Environment.GetEnvironmentVariable("TD_PARITY_PROOF") != "1" || accounts is not null)) throw new InvalidOperationException("Nonmodal picker proof requires the isolated parity renderer and no account service.");
    if (Computers is { } computers && projectId is null && agentId is null && !requireJob && await TerminalDeck.App.Views.Computers.ComputerSessionPicker.ChooseAsync(root, computers, cancellationToken)) return;
    var homeFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var initialProjects = NewSessionProjects.Choices(projects.List());
    var initialProject = NewSessionProjects.Selection(initialProjects, projectId ?? (agentId is null ? null : agents.Get(agentId).ProjectId) ?? projects.ActiveProjectId);
    var project = Choice("Project · optional", initialProjects.Select(p => (p.Id, p.Name + (p.HomeFolder is { } home ? " · " + home : ""))).Append((NewSessionProjects.CreateId, "New project…")), initialProject);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(project, "session.project");
    IEnumerable<(string Id, string Name)> ProviderChoices() => (terminalStart is null ? Providers : Providers.Append(("shell", Services?.ShellLabel?.Invoke() ?? "PowerShell"))).Concat(CustomTerminalStart is null ? [] : TerminalProviders?.List().Where(p => p.Enabled).Select(p => (p.Id, p.Name + " · Terminal")) ?? []);
    var agent = Choice("Agent", [], ""); var provider = Choice("AI", ProviderChoices());
    var account = Choice("Account", [], ""); var folder = Field("Working folder", NewSessionProjects.Folder(projects.Get(Picked(project)), homeFolder));
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(folder, "session.folder");
    var presentation = Choice("Open as", new[] { ("chat", "Chat"), ("terminal", "Terminal") }, mode);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(provider, "session.provider");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(presentation, "session.presentation");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(account, "session.account");
    var job = Field(requireJob ? "Job for this hand" : "Job for this session · optional", max: 4000); job.Header = null;
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(job, "agents.hand.job");
    var helper = new CheckBox { Content = "Temporary helper · uses the category helper AI and folds its notes back into this role" };
    var form = Stack(20); form.Width = 520;
    var filter = new TextBox { PlaceholderText = "Filter saved project folders…" };
    var folderStatus = Words("", 12, true); folderStatus.Visibility = Visibility.Collapsed; form.Children.Add(filter); form.Children.Add(folderStatus);
    var identity = new Grid { ColumnSpacing = 12 };
    identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    identity.Children.Add(project); Grid.SetColumn(agent, 1); identity.Children.Add(agent); form.Children.Add(identity);
    var chosenWords = Words("", 12, true);
    var folderRow = new Grid { ColumnSpacing = 8 };
    folderRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); folderRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    folderRow.Children.Add(folder);
    var browse = AsyncButton("Choose folder…", async () => { if (await PickFolderAsync(navigation.WindowHandle) is { } selected) folder.Text = selected; });
    browse.VerticalAlignment = VerticalAlignment.Bottom; Grid.SetColumn(browse, 1); folderRow.Children.Add(browse);
    // Folder dropdown (Mac: Project menu + recent list): open projects, recent
    // folders, Independent/home, Choose folder…; the box above still takes a typed path.
    folderRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var folderMenu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
    var folders = new DropDownButton { Content = "Folders", Flyout = folderMenu, VerticalAlignment = VerticalAlignment.Bottom, MinHeight = 32 };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(folders, "session.folders");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(folders, "Choose a folder from the list");
    Grid.SetColumn(folders, 2); folderRow.Children.Add(folders); form.Children.Add(folderRow);
    Action<string, string?> chooseFolder = (_, _) => { };
    folderMenu.Opening += (_, _) =>
    {
      folderMenu.Items.Clear();
      IEnumerable<string> recent;
      try { recent = Services?.RecentFolders() ?? []; } catch (Exception ex) when (ex is IOException or InvalidOperationException) { recent = []; }
      FolderChoiceKind? last = null;
      foreach (var choice in NewSessionFolders.Choices(projects.List(), recent, homeFolder))
      {
        if (last is not null && last != choice.Kind) folderMenu.Items.Add(new MenuFlyoutSeparator());
        last = choice.Kind;
        var item = new ToggleMenuFlyoutItem { Text = choice.Label + "  ·  " + choice.Path, IsChecked = string.Equals(NewSessionFolders.Key(choice.Path), NewSessionFolders.Key(folder.Text), StringComparison.OrdinalIgnoreCase) };
        ToolTipService.SetToolTip(item, choice.Path);
        item.Click += (_, _) => chooseFolder(choice.Path, choice.ProjectId ?? projects.List().FirstOrDefault(p => p.IsOpen && p.Folders.Any(f => string.Equals(f, choice.Path, StringComparison.OrdinalIgnoreCase)))?.Id);
        folderMenu.Items.Add(item);
      }
      folderMenu.Items.Add(new MenuFlyoutSeparator());
      var pick = new MenuFlyoutItem { Text = "Choose folder…" };
      pick.Click += async (_, _) => { if (await PickFolderAsync(navigation.WindowHandle) is { } selected) folder.Text = selected; };
      folderMenu.Items.Add(pick);
    };
    var aiSection = Stack(8); aiSection.Children.Add(Heading("AI", 14));
    var aiButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var providerButtons = new List<(string Id, Microsoft.UI.Xaml.Controls.Primitives.ToggleButton Button)>();
    void ProviderButtons()
    {
      aiButtons.Children.Clear(); providerButtons.Clear();
      foreach (ChoiceRow row in provider.Items)
      {
        var button = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = row.Name, MinHeight = 34, IsChecked = row.Id == Picked(provider) };
        button.Click += (_, _) => { provider.SelectedValue = row.Id; foreach (var item in providerButtons) item.Button.IsChecked = item.Id == Picked(provider); };
        providerButtons.Add((row.Id, button)); aiButtons.Children.Add(button);
      }
    }
    ProviderButtons();
    provider.Visibility = Visibility.Collapsed; aiSection.Children.Add(provider); aiSection.Children.Add(new ScrollViewer { Content = aiButtons, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled }); aiSection.Children.Add(chosenWords);
    if (TerminalProviders is { } customProviders) aiSection.Children.Add(AsyncButton("Manage custom CLIs…", () => { CustomTerminalProviderWindow.Open(customProviders, (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default); return Task.CompletedTask; }));
    form.Children.Add(aiSection);
    var modeRow = new Grid { ColumnSpacing = 12 };
    modeRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); modeRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    modeRow.Children.Add(Heading("Open as", 14));
    var modes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    var modeButtons = new List<(string Id, Microsoft.UI.Xaml.Controls.Primitives.ToggleButton Button)>();
    foreach (ChoiceRow row in presentation.Items)
    {
      var button = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = row.Name, IsChecked = row.Id == Picked(presentation), MinHeight = 32 };
      button.Click += (_, _) => { presentation.SelectedValue = row.Id; foreach (var item in modeButtons) item.Button.IsChecked = item.Id == Picked(presentation); };
      modeButtons.Add((row.Id, button)); modes.Children.Add(button);
    }
    presentation.Visibility = Visibility.Collapsed; form.Children.Add(presentation);
    Grid.SetColumn(modes, 1); modeRow.Children.Add(modes); form.Children.Add(modeRow);
    form.Children.Add(account);
    var model = Choice("Model", [], ""); model.PlaceholderText = "";
    var effort = Choice("Effort", new[] { "low", "medium", "high", "xhigh", "max" }.Select(e => (e, ModelCatalog.EffortName(e))), "xhigh");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(model, "session.model");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(effort, "session.effort");
    string? wantedEffort = null;
    (string Model, string? Effort) Launch(string ai) => CustomTerminalProviders.IsKey(ai) ? ("", null) : Services?.Launch(ai) ?? LaunchDefaults.For(ai, (GeneralPreferences?)null);
    var modelRow = new Grid { ColumnSpacing = 12 };
    modelRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); modelRow.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    modelRow.Children.Add(model); Grid.SetColumn(effort, 1); modelRow.Children.Add(effort); form.Children.Add(modelRow);
    var permission = Choice("Permission mode", [], "");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(permission, "session.permission");
    form.Children.Add(permission);
    var title = Field("Name · optional", max: 120); title.PlaceholderText = "Named from the conversation if left empty";
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, "session.name");
    form.Children.Add(title);
    var modelRequest = 0;
    IReadOnlyList<ProviderModel> modelChoices = [];
    Action refreshAccounts = () => { };
    var signIn = AsyncButton("Sign in…", async () =>
    {
      if (accounts is null || Picked(account).Length == 0) return;
      var selectedId = Picked(account); var selectedFolder = folder.Text;
      try { await accounts.SignInAsync(selectedId, selectedFolder, cancellationToken); await accounts.RefreshAsync(selectedId, cancellationToken); refreshAccounts(); }
      catch (SignInCancelledException) { }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { chosenWords.Text = ex.Message; }
    });
    signIn.Visibility = Visibility.Collapsed; form.Children.Add(signIn);
    var remember = new CheckBox { Content = "Remember AI and account for this project" }; form.Children.Add(remember);
    form.Children.Add(helper);
    form.Children.Add(new Expander { Header = requireJob ? "Job for this hand" : "Job for this session · optional", IsExpanded = requireJob, Content = job, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; form.Children.Add(error);
    var dialog = Dialog(root, "New session", form, "Start");
    var createProjectRequested = false;
    var projectBeforeCreate = initialProject;
    void UpdateCanStart()
    {
      var shell = (Picked(provider) == "shell" || CustomTerminalProviders.IsKey(Picked(provider))) && Picked(agent).Length == 0;
      var missing = !Directory.Exists(folder.Text) ? "Choose an existing working folder with Choose folder…. A project is optional." :
        requireJob && string.IsNullOrWhiteSpace(job.Text) ? "Add the job for this hand before starting." :
        !shell && account.Items.Count == 0 ? "Add an account in Settings → Coding AIs, or choose a shell to open a terminal now." :
        !shell && !agents.CanStart(Picked(presentation)) ? "The session service is unavailable. Choose a shell for a terminal, or retry the connection." : "";
      folderStatus.Text = missing; folderStatus.Visibility = missing.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
      // Signed-out accounts start their sign-in flow; a model catalogue is not
      // available until then and must never deadlock a clean first launch.
      dialog.IsPrimaryButtonEnabled = missing.Length == 0 && (shell ? Picked(provider) == "shell" ? terminalStart is not null : CustomTerminalStart is not null : true);
    }
    async Task ReadModels()
    {
      var request = ++modelRequest; var ai = Picked(provider); var accountId = Picked(account);
      model.Visibility = ai == "shell" || CustomTerminalProviders.IsKey(ai) ? Visibility.Collapsed : Visibility.Visible;
      effort.Visibility = ai is "shell" or "gemini" || CustomTerminalProviders.IsKey(ai) ? Visibility.Collapsed : Visibility.Visible;
      if (ai == "shell" || CustomTerminalProviders.IsKey(ai)) { UpdateCanStart(); return; }
      var selectedAgent = Picked(agent) is { Length: > 0 } agentKey ? agents.Get(agentKey) : null;
      var launch = Launch(ai);
      var saved = selectedAgent?.Model is { Length: > 0 } own ? own : launch.Model;
      if (helper.IsChecked == true && selectedAgent is not null) saved = agents.Templates().Single(t => t.Category == agents.SeatOf(selectedAgent.Id).Category).HelperModel;
      wantedEffort = selectedAgent?.Effort is { Length: > 0 } savedEffort && savedEffort != "auto" ? savedEffort : launch.Effort;
      // The list shows at once (last live list, else the preloaded one); the live
      // list replaces it when the signed-in CLI answers, keeping the selection.
      void Fill(IReadOnlyList<ProviderModel> rows, string keep)
      {
        modelChoices = ModelCatalog.Merge(ai, rows, keep);
        model.Items.Clear();
        foreach (var item in modelChoices) model.Items.Add(new ChoiceRow(item.Id, item.Name));
        model.SelectedValue = keep;
        if (model.SelectedIndex < 0 && model.Items.Count > 0) model.SelectedIndex = 0;
      }
      Fill(accounts?.InstantModels(ai, accountId.Length == 0 ? null : accountId).Models ?? ModelCatalog.For(ai), saved);
      UpdateCanStart();
      if (accounts is null || accountId.Length == 0 || accounts.List(ai).FirstOrDefault(a => a.Id == accountId) is not { SignedIn: true }) return;
      try
      {
        var offered = (await accounts.ModelsAsync(accountId, cancellationToken: cancellationToken)).Models;
        if (request != modelRequest || accountId != Picked(account)) return;
        var keep = Picked(model) is { Length: > 0 } current ? current : saved; wantedEffort = Picked(effort) is { Length: > 0 } level ? level : wantedEffort;
        Fill(offered, keep);
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
      UpdateCanStart();
    }
    effort.SelectionChanged += (_, _) => { if (Picked(effort) is { Length: > 0 } level) wantedEffort = level; };
    model.SelectionChanged += (_, _) =>
    {
      var previous = Picked(effort); effort.Items.Clear();
      var ai = Picked(agent) is { Length: > 0 } chosenAgent ? agents.Get(chosenAgent).Provider : Picked(provider);
      foreach (var level in ModelEfforts.For(ai, modelChoices.FirstOrDefault(m => m.Id == Picked(model)))) effort.Items.Add(new ChoiceRow(level, ModelCatalog.EffortName(level)));
      effort.SelectedValue = wantedEffort ?? previous; if (effort.SelectedIndex < 0) effort.SelectedValue = previous;
      if (effort.SelectedIndex < 0 && effort.Items.Count > 0) effort.SelectedValue = Launch(ai).Effort ?? "";
      if (effort.SelectedIndex < 0 && effort.Items.Count > 0) effort.SelectedIndex = 0;
      UpdateCanStart();
    };
    ToolTipService.SetToolTip(folder, folder.Text);
    folder.TextChanged += (_, _) => { ToolTipService.SetToolTip(folder, folder.Text); UpdateCanStart(); };
    job.TextChanged += (_, _) => UpdateCanStart();
    var updatingChoices = false;
    string? lastAi = null; string? lastAgent = null; string? lastProject = null; string? permissionAi = null;
    void AccountChoices()
    {
      if (updatingChoices || Picked(project).Length == 0) return;
      updatingChoices = true;
      try
      {
        var a = Picked(agent) is { Length: > 0 } id ? agents.Get(id) : null;
        helper.Visibility = a is null ? Visibility.Collapsed : Visibility.Visible;
        if (a is null) helper.IsChecked = false;
        var template = a is null ? null : agents.Templates().Single(t => t.Category == agents.SeatOf(a.Id).Category);
        var helping = helper.IsChecked == true && a is not null;
        var ai = helping ? template!.HelperAI : a?.Provider ?? Picked(provider); var p = projects.Get(Picked(project));
        ToolTipService.SetToolTip(project, p.HomeFolder ?? p.Name);
        var use = Picked(presentation) == "chat" ? "chats" : "sessions"; var defaults = p.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == use && c.Provider == ai);
        var previous = lastAi == ai && lastAgent == a?.Id && lastProject == p.Id ? Picked(account) : "";
        lastAi = ai; lastAgent = a?.Id; lastProject = p.Id;
        account.Items.Clear();
        foreach (var row in accounts?.List(ai) ?? []) account.Items.Add(new ChoiceRow(row.Id, row.Name + (row.SignedIn ? "" : " · sign-in needed")));
        account.SelectedValue = previous.Length > 0 ? previous : (a?.Provider == ai ? a.AccountId : null) ?? defaults?.AccountId ?? accounts?.Default(ai, folder.Text)?.Id;
        if (account.SelectedIndex < 0 && account.Items.Count > 0) account.SelectedIndex = 0;
        if (a is not null) provider.SelectedValue = ai;
        provider.IsEnabled = a is null;
        foreach (var item in providerButtons) { item.Button.IsChecked = item.Id == ai; item.Button.IsEnabled = a is null; }
        chosenWords.Text = helping ? "Temporary helper · " + AgentSeats.ProviderName(ai) + " · " + template!.HelperModel : a is null ? "No agent · use the AI and account above." : AgentSeats.ProviderName(a.Provider) + " · " + ModelCatalog.Label(a.Provider, a.Model.Length == 0 ? Launch(a.Provider).Model : a.Model, a.Effort is "auto" or "" ? Launch(a.Provider).Effort : a.Effort);
        var shell = ai == "shell" || CustomTerminalProviders.IsKey(ai);
        if (shell) { presentation.SelectedValue = "terminal"; } presentation.IsEnabled = !shell;
        foreach (var item in modeButtons) { item.Button.IsChecked = item.Id == Picked(presentation); item.Button.IsEnabled = !shell || item.Id == "terminal"; }
        account.Visibility = shell ? Visibility.Collapsed : Visibility.Visible;
        var keptPermission = Picked(permission);
        permission.Items.Clear();
        if (!shell)
        {
          foreach (var mode in ChatPermissionModes.Supported(ai)) permission.Items.Add(new ChoiceRow(mode.ToString(), ChatPermissionModes.Label(mode) + " · " + ChatPermissionModes.Explain(mode)));
          permission.SelectedValue = keptPermission.Length > 0 && permissionAi == ai ? keptPermission : (Services?.Permission(ai) ?? ChatPermissionModes.DefaultFor(ai)).ToString();
          if (permission.SelectedIndex < 0 && permission.Items.Count > 0) permission.SelectedIndex = 0;
        }
        permissionAi = ai;
        permission.Visibility = shell ? Visibility.Collapsed : Visibility.Visible; title.Visibility = shell ? Visibility.Collapsed : Visibility.Visible;
        var selectedAccount = accounts?.List(ai).FirstOrDefault(row => row.Id == Picked(account));
        signIn.Visibility = !shell && selectedAccount is { SignedIn: false } ? Visibility.Visible : Visibility.Collapsed;
        signIn.Content = "Sign in to " + AgentSeats.ProviderName(ai) + "…";
        remember.Content = "Remember AI and account for " + p.Name;
        remember.IsEnabled = !shell && p.Id != ProjectIdentity.IndependentId;
        UpdateCanStart();
        if (shell) error.IsOpen = false;
        else if (account.Items.Count == 0) { error.Message = "Add an account under Coding AIs before starting this session."; error.IsOpen = true; }
        else if (!agents.CanStartSessions) { error.Message = "The session service is unavailable. Your saved agents and projects are kept."; error.IsOpen = true; }
        else if (!agents.CanStart(Picked(presentation))) { error.Message = "This view is unavailable. Choose another view for this session."; error.IsOpen = true; }
        else error.IsOpen = false;
      }
      finally { updatingChoices = false; }
      _ = ReadModels();
    }
    refreshAccounts = AccountChoices;
    void AgentChoices()
    {
      if (updatingChoices) return;
      if (Picked(project).Length == 0) { UpdateCanStart(); return; }
      var selected = agentId ?? Picked(agent); agentId = null;
      updatingChoices = true;
      agent.Items.Clear(); agent.Items.Add(new ChoiceRow("", "No agent"));
      var p = projects.Get(Picked(project));
      foreach (var row in agents.List().Where(a => a.Status == SavedAgentStatus.Active && (a.ProjectId == p.Id || a.ProjectId == ProjectIdentity.IndependentId)).OrderByDescending(a => p.Lead == "agent:" + a.Id).ThenBy(a => a.Name))
        agent.Items.Add(new ChoiceRow(row.Id, row.Name + (p.Lead == "agent:" + row.Id ? " (lead)" : "")));
      agent.SelectedValue = selected; if (agent.SelectedIndex < 0) agent.SelectedIndex = 0;
      folder.Text = NewSessionProjects.Folder(projects.Get(Picked(project)), homeFolder);
      var use = Picked(presentation) == "chat" ? "chats" : "sessions";
      var defaultAi = projects.Get(Picked(project)).Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == use)?.Provider;
      if (defaultAi is not null) provider.SelectedValue = defaultAi;
      updatingChoices = false; AccountChoices();
    }
    chooseFolder = (path, projectId) =>
    {
      if (projectId is not null && projectId != Picked(project) && project.Items.OfType<ChoiceRow>().Any(r => r.Id == projectId))
      { project.SelectedValue = projectId; projectBeforeCreate = projectId; }
      folder.Text = path;
    };
    void FillProjects(string preferred)
    {
      updatingChoices = true;
      project.Items.Clear();
      var rows = NewSessionProjects.Choices(projects.List(), filter.Text);
      foreach (var row in rows) project.Items.Add(new ChoiceRow(row.Id, row.Name + (row.HomeFolder is { } home ? " · " + home : "")));
      project.Items.Add(new ChoiceRow(NewSessionProjects.CreateId, "New project…"));
      project.SelectedValue = NewSessionProjects.Selection(rows, preferred);
      updatingChoices = false;
    }
    filter.TextChanged += (_, _) =>
    {
      var selected = Picked(project); FillProjects(selected);
      if (Picked(project) != selected) AgentChoices(); else AccountChoices(); UpdateCanStart();
    };
    account.SelectionChanged += (_, _) =>
    {
      if (updatingChoices) return;
      _ = ReadModels();
      signIn.Visibility = accounts?.List(Picked(provider)).FirstOrDefault(a => a.Id == Picked(account)) is { SignedIn: false } ? Visibility.Visible : Visibility.Collapsed;
    };
    helper.Checked += (_, _) => AccountChoices(); helper.Unchecked += (_, _) => AccountChoices();
    project.SelectionChanged += (_, _) =>
    {
      if (updatingChoices) return;
      if (Picked(project) == NewSessionProjects.CreateId)
      {
        createProjectRequested = true; dialog.Hide(); return;
      }
      projectBeforeCreate = Picked(project); AgentChoices();
    };
    agent.SelectionChanged += (_, _) => AccountChoices();
    provider.SelectionChanged += (_, _) => AccountChoices(); presentation.SelectionChanged += (_, _) => AccountChoices(); AgentChoices();
    var operation = new PickerOperation();
    var starting = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed }; form.Children.Add(starting);
    var preparing = false;
    dialog.CloseButtonClick += (_, e) => e.Cancel = operation.IsBusy || preparing;
    string? startedSessionId = null;
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Cancel = true; dialog.IsPrimaryButtonEnabled = false; preparing = true;
      form.IsHitTestVisible = false; starting.Visibility = Visibility.Visible; dialog.PrimaryButtonText = "Starting…";
      try
      {
        if (startedSessionId is { } existing)
        { navigation.OpenSession(existing); e.Cancel = false; return; }
        if (CustomTerminalProviders.IsKey(Picked(provider)) && Picked(agent).Length == 0 && CustomTerminalStart is { } customStart)
        {
          var customOk = await operation.RunAsync(() => customStart(Picked(provider), folder.Text, Picked(project)), "Session started."); e.Cancel = !customOk;
          if (!customOk) { error.Message = operation.Message; error.IsOpen = true; } return;
        }
        if (Picked(provider) == "shell" && Picked(agent).Length == 0 && terminalStart is not null)
        {
          var shellOk = await operation.RunAsync(() => terminalStart(folder.Text, Picked(project)), "Session started.");
          e.Cancel = !shellOk;
          if (!shellOk) { error.Message = operation.Message; error.IsOpen = true; }
          return;
        }
        if (accounts is not null && Picked(account) is { Length: > 0 } chosenAccount)
        {
          var current = await accounts.RefreshAsync(chosenAccount, cancellationToken);
          if (!current.SignedIn)
          {
            await accounts.SignInAsync(current.Id, folder.Text, cancellationToken);
            current = await accounts.RefreshAsync(current.Id, cancellationToken);
            if (!current.SignedIn) { error.Message = "Not signed in. Your session choices and draft are kept."; error.IsOpen = true; return; }
          }
        }
        AgentRun? started = null;
        var ok = await operation.RunAsync(async () => started = await agents.StartAsync(new(Picked(agent) is { Length: > 0 } id ? id : null,
          Picked(project), folder.Text, Picked(provider), Picked(account), Picked(presentation), job.Text, Helper: helper.IsChecked == true, Title: string.IsNullOrWhiteSpace(title.Text) ? null : title.Text.Trim(), Model: Picked(model),
          Effort: Picked(provider) == "gemini" ? "auto" : Picked(effort), Permission: Enum.TryParse<AiPermissionMode>(Picked(permission), out var chosenMode) ? chosenMode : null)), "Session started.");
        if (!ok || started is null) { error.Message = operation.Message; error.IsOpen = true; return; }
        startedSessionId = started.SessionId;
        if (remember.IsChecked == true && remember.IsEnabled)
        {
          try
          {
            var p = projects.Get(Picked(project)); var use = Picked(presentation) == "chat" ? "chats" : "sessions";
            projects.SetWhoUsesWhat(p.Id, p.Preferences.WhoUsesWhat.Where(c => c.Use != use).Append(new ProjectAiChoice(use, Picked(provider), Picked(account))).ToArray());
          }
          catch (Exception ex) when (ex is not OutOfMemoryException)
          { error.Message = "Session started, but its project choices could not be saved. Done opens the started session without starting another one."; error.IsOpen = true; return; }
        }
        navigation.OpenSession(started.SessionId); e.Cancel = false;
      }
      catch (SignInCancelledException) { error.IsOpen = false; }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      { error.Message = startedSessionId is null ? ex is TerminalDeck.Core.Platform.ProviderUnavailableException or SignInRequiredException ? ex.Message : "This session could not start. Your choices are kept." : "Session started. Use Done to open it, or find it under Running."; error.IsOpen = true; }
      finally
      {
        preparing = false; form.IsHitTestVisible = true; starting.Visibility = Visibility.Collapsed;
        if (startedSessionId is null)
        {
          var selectedAi = Picked(agent) is { Length: > 0 } chosenAgent ? agents.Get(chosenAgent).Provider : Picked(provider);
          signIn.Visibility = accounts?.List(selectedAi).FirstOrDefault(a => a.Id == Picked(account)) is { SignedIn: false } ? Visibility.Visible : Visibility.Collapsed;
        }
        dialog.PrimaryButtonText = startedSessionId is null ? "Start" : "Done"; dialog.IsPrimaryButtonEnabled = true; deferral.Complete();
      }
    };
    var startShortcut = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Enter, Modifiers = Windows.System.VirtualKeyModifiers.Control };
    startShortcut.Invoked += (_, e) =>
    {
      if (!dialog.IsPrimaryButtonEnabled || operation.IsBusy) return;
      Button? FindPrimary(DependencyObject parent)
      {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
          var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
          if (child is Button { Name: "PrimaryButton" } primary) return primary;
          if (FindPrimary(child) is { } found) return found;
        }
        return null;
      }
      if (FindPrimary(dialog) is { } primary && new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(primary).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke) is Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider invoke)
      { invoke.Invoke(); e.Handled = true; }
    };
    dialog.KeyboardAccelerators.Add(startShortcut);
    var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread() ?? throw new InvalidOperationException("Open this dialog from the window thread.");
    void ProvidersChanged() => dispatcher.TryEnqueueHandled(() =>
    {
      var previous = Picked(provider); updatingChoices = true; provider.Items.Clear(); foreach (var option in ProviderChoices()) provider.Items.Add(new ChoiceRow(option.Id, option.Name));
      provider.SelectedValue = previous; if (provider.SelectedIndex < 0) provider.SelectedIndex = 0; ProviderButtons(); updatingChoices = false; AccountChoices();
    });
    if (renderForProof is not null) { if (dialog.Content is ScrollViewer proofScroll) proofScroll.Content = null; dialog.Content = null; await renderForProof(form); return; }
    if (TerminalProviders is { } registry) registry.Changed += ProvidersChanged;
    using var cancellation = cancellationToken.Register(() => dispatcher.TryEnqueueHandled(() => dialog.Hide()));
    try
    {
      while (!cancellationToken.IsCancellationRequested)
      {
        createProjectRequested = false; ActiveDialogForProof = dialog;
        await dialog.ShowAsync(); ActiveDialogForProof = null;
        if (!createProjectRequested || cancellationToken.IsCancellationRequested) break;
        // WinUI allows one ContentDialog at a time. Keep this form intact while
        // the existing guide runs, then bring the same draft back.
        using var setup = new ProjectsViewModel(projects, agents, () => [], accounts, autoLogos: false);
        Project? created = null;
        await ProjectSetupDialog.ShowAsync(root, setup, navigation, null, folder.Text, null, saved => created = saved, cancellationToken);
        if (created is not null) filter.Text = "";
        FillProjects(created?.Id ?? projectBeforeCreate);
        if (created is not null) AgentChoices();
        else AccountChoices();
        UpdateCanStart();
      }
    }
    finally { ActiveDialogForProof = null; if (TerminalProviders is { } finalRegistry) finalRegistry.Changed -= ProvidersChanged; }
  }
  private sealed class PickerOperation : ProjectAgentViewModel;
}
