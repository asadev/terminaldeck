using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core;
using TerminalDeck.Core.Storage;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Browser;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow : Window, IAgentTasksNavigation, IProjectsAgentsNavigation, IProjectAgentPageActions, TerminalDeck.App.Views.Tasks.ITasksNavigation, TerminalDeck.App.Views.Servers.IServerPageHost, TerminalDeck.Core.Hoot.IHootSurface
{
  public ShellViewModel Model { get; } = new();
  public AppRuntime Runtime { get; }
  private AppToolServer? tools;
  private TerminalDeck.App.Views.Tasks.TasksPage? tasksPage;
  private TerminalDeck.App.Views.Hoot.HootPage? hootPage;
  private TerminalDeck.App.Views.Servers.ServersPage? serversPage;
  private IDisposable? receiverDrop;
  public IReadOnlyList<TerminalDeck.App.Views.Servers.ServerAiAppChoice> AiApps => Runtime.CallerAuthority.List().Select(c => new TerminalDeck.App.Views.Servers.ServerAiAppChoice(c.CallerId, c.SeatId == TerminalDeck.Core.Hoot.HootDesk.Seat ? "Hoot" : c.CallerId.StartsWith("chat:", StringComparison.Ordinal) ? "Agent session" : "AI connection")).ToArray();
  public IReadOnlyList<TerminalDeck.App.Views.Servers.ServerProjectChoice> ServerProjects => Runtime.Projects.List().Select(p => new TerminalDeck.App.Views.Servers.ServerProjectChoice(p.Id, p.Name)).ToArray();
  IReadOnlyList<TerminalDeck.App.Views.Servers.ServerProjectChoice> TerminalDeck.App.Views.Servers.IServerPageHost.Projects => ServerProjects;
  private readonly TaskCompletionSource ready = new();
  public Task Ready => ready.Task;
  private readonly AppDataRoot dataRoot;
  private readonly BrowserPane browser;
  private readonly SettingsPane settings;
  public ProjectsPage Projects { get; }
  public AgentsPage Agents { get; }
  private readonly Dictionary<string, ChatPage> chatPanes = [];
  public nint WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);
  private readonly Dictionary<string, SessionPane> sessionPanes = [];
  private ShellPage? renderedPage;
  private bool syncingNavigation;
  private bool proofChatVisible;
  private ContentDialog? accountSheet;
  public BrowserPane Browser => browser;
  public SettingsPane Settings => settings;
  public FrameworkElement Frame => Root;
  public ShellWindow(AppDataRoot root)
  {
    InitializeComponent();
    AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "icons", "app.ico"));
    dataRoot = root;
    Runtime = new(root, null, DispatchTool);
    InitializeRecoveryActions();
    Runtime.ReceiverDispatcher = OnUiAsync;
    Runtime.SignInRequested = (account, home) => OnUiAsync(() => AccountSignInSheet.ShowAsync(Runtime, account, home, WindowHandle, Root));
    Runtime.HootSurface = this;
    Runtime.InitializeServers(new TerminalDeck.App.Views.Servers.ServerDialogAuthorizer(() => Root.XamlRoot, DispatcherQueue),
      new TerminalDeck.App.Views.Servers.ServerPersonKeyPicker(() => WinRT.Interop.WindowNative.GetWindowHandle(this), DispatcherQueue));
    Runtime.NotificationOpenRequested += (kind, id) => DispatcherQueue.TryEnqueueHandled(() =>
    {
      Activate();
      if (kind == "hoot") Model.Page = ShellPage.Hoot;
      else if (kind == "task") { Model.Page = ShellPage.Tasks; tasksPage?.OpenTask(id); }
      else OpenSession(id);
    });
    Runtime.ReceiverOutcome += message => DispatcherQueue.TryEnqueueHandled(() => Model.Notice = message);
    // A phone started watching or controlling this PC's screen: said on the PC, with where to stop it.
    Runtime.PhoneScreenNotice += message => { if (message.Length > 0) DispatcherQueue.TryEnqueueHandled(() => Model.Notice = message); };
    Runtime.Changed += () => DispatcherQueue.TryEnqueueHandled(() => { SyncSessions(); Projects?.Model.Refresh(); Agents?.Model.Refresh(); RefreshAccountChip(); if (Runtime.TaskProblem is { } problem) Model.Notice = problem; });
    Title = Brand.Name;
    BrandLabel.Text = Brand.Name;
    var work = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
    var width = Math.Min(1280, work.Width - 40);
    var height = Math.Min(840, work.Height - 40);
    AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
    AppWindow.Move(new Windows.Graphics.PointInt32(W12Proof || Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null ? -20000 : work.X + (work.Width - width) / 2, W12Proof || Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null ? -20000 : work.Y + (work.Height - height) / 2));
    SessionList.ItemsSource = Model.Sessions;
    browser = new BrowserPane(root, SendBrowserContextAsync);
    BindPhoneBrowserWorkspace(Runtime.PhoneBrowser);
    Runtime.InitializeStoreExtensions(new BrowserStoreExtensions(browser, OnUiAsync), new Store.StoreConsent(() => Root.XamlRoot, OnUiAsync));
    browser.SessionChoices = () => Model.Sessions.Where(s => s.IsLive && s.State is not ("ended" or "exited"))
      .Select(s => new BrowserSessionChoice(s.Id, s.Title)).ToArray();
    browser.SendRequest = async request => await ReviewBrowserSendAsync(request.Message, request.ImagePath, request.SessionId, request.Root)
      ? BrowserSendOutcome.Sent : BrowserSendOutcome.KeptDraft;
    settings = new SettingsPane(Model, Runtime);
    Runtime.InstallAiRequested = (provider, approved) => OnUiAsync(() => CodingAiInstallSheet.ShowAsync(Runtime, provider, settings, WindowHandle, approved, Root));
    Runtime.InstallFlowRequested = CodingAiInstallSheet.ControlAsync;
    Runtime.SignInFlowRequested = AccountSignInSheet.ControlAsync;
    settings.SettingsBrowser = browser.Core; settings.PrivacyBrowser = browser; browser.PrivacyWindowHandle = WindowHandle;
    browser.OpenSettingsRequested = () => OpenSettingsAsync("browser");
    InitializeGeneralSettings();
    InitializeSettingsPanel();
    InitializeWindows(root);
    settings.ReadCloseConfirmation = () => sidebar.Read.ConfirmDelete;
    settings.SaveCloseConfirmation = value => sidebar.AskBeforeDelete(value);
    settings.ResetWindowAppearance = () => SaveSettingsTheme(ElementTheme.Default);
    Runtime.ResetWindowPreferenceOwner = () => { SaveSettingsTheme(ElementTheme.Default); sidebar.AskBeforeDelete(true); };
    Runtime.ResetBrowserPreferenceOwner = ct => browser.ResetBrowserPreferencesAsync(ct);
    WindowMaterials.Attach(this, Root, TitleBarRow);
    FocusInputOnActivation(this, Root, "main");
    RoundedContentClip.Attach(ContentCard, topLeftOnly: true);
    Projects = new(new(Runtime.Projects, Runtime.Agents, Runtime.ProjectSessions, Runtime.Accounts), this);
    Agents = new(new(Runtime.Agents, Runtime.Projects, Runtime.Accounts), this);
    Runtime.ProjectAgentPages = this;
    Root.ActualThemeChanged += (_, _) => QueueSurfaceTheme();
    Closed += async (_, _) => { Runtime.ReleaseIdleStableKeeper(); Runtime.General.Changed -= ApplyGeneralSettings; keepAwake.Dispose(); closingShell = true; foreach (var child in detached.Values.ToArray()) child.Window.Close(); receiverDrop?.Dispose(); tasksPage?.Model.Dispose(); hootPage?.Dispose(); browser.DisposeViews(); foreach (var pane in sessionPanes.Values) pane.DisposeView(); foreach (var pane in chatPanes.Values) await pane.DisposeAsync(); Projects.Model.Dispose(); Agents.Model.Dispose(); if (tools is not null) await tools.DisposeAsync(); await Runtime.DisposeAsync(); };
    Model.PropertyChanged += (_, args) => { if (syncingWindows) return; if (args.PropertyName is nameof(ShellViewModel.Sessions) or nameof(ShellViewModel.Selected)) SyncWindows(); Refresh(); };
    Refresh();
    Root.Loaded += async (_, _) =>
    {
      try
      {
        await Runtime.InitializeAsync();
        tasksPage = new(new(Runtime.Tasks, Runtime.Projects, Runtime.TaskMachineIdentity, Runtime.TaskPeople, Runtime.ConnectedTasks), this, PresentTaskPopup);
        hootPage = new(Runtime.Hoot, () => Runtime.Accounts.List(), () => Runtime.ProjectSessions().Where(s => s.Id != Runtime.Hoot.Read().ChatId).Select(s => new TerminalDeck.App.Views.Hoot.HootSessionChoice(s.Id, s.Title)).ToArray(), OpenSession, OpenCodingAis, SignInForHootAsync) { SlashCommands = HootSlashCommands, Chats = Runtime.Chats, DataDirectory = Runtime.Root.DirectoryPath, McpNavigation = id => new ChatMcpNavigation(Runtime.Mcp, (server, tool, args, ct) => Runtime.CallChatAppToolAsync(id, server, tool, args, ct)) };
        serversPage = new(new(Runtime.Servers), this);
        Runtime.RegisterTools();
        RegisterWindowTools();
        RegisterShellReadTools();
        RegisterProjectRemovalTool();
        browser.RegisterPrivacyTools(Runtime.Door);
        BrowserTools.RegisterRecipes(Runtime.Door, browser.Core, id => Runtime.AppStore.Browse("Browser tools", installed: true).Any(r => r.Entry.Id == id));
        BrowserTools.RegisterWithSessionLookup(Runtime.Door, browser.Core, id => Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == id) ?? TerminalDeck.Core.Chats.ChatSessions.Session(Runtime.Chats.Get(id)));
        Runtime.Door.Register("ui.workspace", async (context, args, ct) =>
        {
          context.Require("settings", "workspace");
          if (args.EnumerateObject().Any()) await context.EnsureCurrentAsync(ct);
          if (args.TryGetProperty("shellCommand", out var shellCommand)) await ApplyShellCommandAsync(context, shellCommand.GetString()!, ct);
          if (args.TryGetProperty("taskPopup", out var taskPopup)) ApplyTaskPopup(context, taskPopup);
          if (args.TryGetProperty("sidebarAction", out var sidebarAction)) await ApplySidebarActionAsync(context, sidebarAction, ct);
          if (args.TryGetProperty("windowAction", out var windowAction)) await ApplyWindowActionAsync(context, windowAction, ct);
          if (args.TryGetProperty("sessionId", out var session))
          {
            var id = session.GetString()!; context.Require("sessions", id);
            SelectSessionWindow(Model.Sessions.Single(s => s.Id == id));
          }
          if (args.TryGetProperty("split", out var split)) { var mode = Enum.Parse<SplitPresentation>(split.GetString()!, true); if (mode == SplitPresentation.None) { if (windowState.Layout(Scope).Active is { } active) windowState.One(active, Scope); } else SplitWindows(mode == SplitPresentation.Browser); }
          if (args.TryGetProperty("theme", out var theme)) SetTheme(theme.GetString() switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default });
          if (args.TryGetProperty("page", out var page)) Model.Page = Enum.Parse<ShellPage>(page.GetString()!, true);
          if (args.TryGetProperty("settingsSection", out var section))
          {
            await OpenSettingsAsync(section.GetString() ?? "general");
          }
          return System.Text.Json.JsonSerializer.SerializeToElement(new { page = Model.Page.ToString(), selected = Model.Selected?.Id, devicesPresentation = "window", devicesPopupOpen, split = Model.Split.ToString(), theme = Root.RequestedTheme.ToString(), taskPopup = TaskPopupSnapshot(context), settings = settings.SelectedSection, settingsWindowOpen = settingsWindow is not null, settingsPanelOpen = false, windows = WindowSnapshot(context) });
        });
        RegisterSettingsPanelTools();
        settings.RegisterDirectionTools();
        RegisterGeneralSettingsTools();
        tools = new(Runtime.Door, dataRoot); Runtime.LocalToolAddress = tools.Address; await Runtime.StartHootToolConnectionAsync();
        renderedPage = null; Refresh();
        SyncSessions(); await browser.PrepareShellAsync(); renderedWindowsStructure = ""; Model.Notice = ""; ready.TrySetResult(); SyncWindows();
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { shellRecoveryRequired = true; UiRecovery.Report("Shell initialization", ex); Model.Notice = "The session service could not connect. Existing terminals were left alone."; ready.TrySetException(ex); }
      _ = CheckForUpdateOnOpenAsync();
      if (Environment.GetEnvironmentVariable("TD_UI_CONSISTENCY_PROOF") is not null) { await RunUiConsistencyProofAsync(); return; }
      if (Environment.GetEnvironmentVariable("TD_LOOK_MICA_PROOF") is not null) { await RunLookMicaProofAsync(); return; }
      if (Environment.GetEnvironmentVariable("TD_SIGNIN_PROOF") is not null) { await RunSignInProofAsync(); return; }
      if (Environment.GetEnvironmentVariable("TD_TASK_DETAIL_PROOF") is not null) { await RunTaskDetailProofAsync(); return; }
      if (Environment.GetEnvironmentVariable("TD_REAL_CHANNEL_PROOF") is not null) { await Verification.StableChannelProof.RunIfRequestedAsync(this); return; }
      if (Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null) { await RunW13ProofAsync(); return; }
      if (W12Proof) { await RunW12ShellProofAsync(); return; }
      await RunShellProofIfRequestedAsync();
      await Verification.W10Proof.RunIfRequestedAsync(this, dataRoot);
      var w7 = Environment.GetEnvironmentVariable("TD_W7_PROOF");
      if (w7 is not null && Path.GetFullPath(w7).StartsWith(root.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        await Verification.W7Proof.RunAsync(this, w7, Environment.GetEnvironmentVariable("TD_W7_PHASE") ?? "create");
      var integration = Environment.GetEnvironmentVariable("TD_INTEGRATION_PROOF");
      if (integration is not null && Path.GetFullPath(integration).StartsWith(root.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        await Verification.IntegrationProof.RunAsync(this, integration);
      var proof = Environment.GetEnvironmentVariable("TD_UI_PROOF_DIR");
      if (!string.IsNullOrEmpty(proof) && Path.GetFullPath(proof).StartsWith(root.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        await Verification.DesktopProof.RunAsync(this, proof, Environment.GetEnvironmentVariable("TD_UI_PROOF_MODE") == "checks");
    };
  }

  internal void ShowRecoveryError(string message)
  {
    // Bypass Model.PropertyChanged: it can be the rendering path that failed.
    shellRecoveryRequired = true;
    UpdateShellNotice(message, recovery: true);
  }

  internal ContentDialog? ToolApprovalForProof { get; private set; }
  private async Task<bool> RequestToolApprovalAsync(McpPermissionRequest request)
  {
    var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = "Allow app tool?", Content = request.Description + " requested by " + request.CallerId, PrimaryButtonText = "Allow once", CloseButtonText = "Cancel" };
    ToolApprovalForProof = dialog;
    try { return await dialog.ShowAsync() == ContentDialogResult.Primary; } finally { ToolApprovalForProof = null; }
  }
  private void SyncSessions()
  {
    var backing = Runtime.Hoot?.Read().Turns.Select(t => t.ChatId).OfType<string>().Append(Runtime.Hoot.Read().ChatId ?? "").ToHashSet() ?? [];
    archivedJobSessions = Runtime.Tasks?.Runs().Where(run => run.State is TerminalDeck.Core.Tasks.TaskRunState.Yielded or TerminalDeck.Core.Tasks.TaskRunState.Ended).Select(run => run.SessionId).OfType<string>().ToHashSet() ?? [];
    syncingWindows = true;
    try
    {
      Model.Sync(Runtime.Sessions, Runtime.Chats?.List().Where(c => !backing.Contains(c.Definition.Id)).ToArray());
      foreach (var terminal in Runtime.Sessions)
        if (Runtime.HookDesktopStatus(terminal) is { } status) Model.Sessions.FirstOrDefault(s => s.Id == terminal.Definition.Id)?.ObserveStatus(status);
      if (Model.Selected is { } restored && IsHistory(restored) && !windowState.Tabs.Any(tab => tab.Id == restored.Id))
      {
        Model.Selected = Model.Sessions.FirstOrDefault(row => !IsHistory(row) && !sidebar.Read.HiddenSessions.Contains(row.Id));
        workspaceOwner = Model.Selected is { } selected ? windowState.OwnerOf(selected.Id) : "";
      }
      var projects = Runtime.Projects.List().ToDictionary(p => p.Id);
      foreach (var group in Runtime.Projects.GroupSessions(Runtime.ProjectSessions()))
        foreach (var row in group.Sessions)
          Model.Sessions.FirstOrDefault(s => s.Id == row.Id)?.SetAppearance(projects.GetValueOrDefault(group.ProjectId)?.Name ?? "", Runtime.Projects.PicturePath(group.ProjectId), Runtime.Agents.SessionLabel(row.Id, row.Provider), group.ProjectId, Runtime.Agents.SessionFace(row.Id)?.Icon, Runtime.Agents.SessionFace(row.Id) is { } face && (face.Hoot || face.Id == TerminalDeck.Core.Agents.AgentSeats.HootId), Runtime.Agents.SessionFace(row.Id)?.PhotoPath);
    }
    finally { syncingWindows = false; }
    foreach (var row in Model.Sessions)
      if (row.Presentation != SessionPresentation.Chat && windowState.Tabs.FirstOrDefault(t => t.Subject == row.Id && t.CustomTitle) is { } named) row.Rename(named.Title);
    if (windowState.Layout(Scope).Active is { } active) Model.Sessions.FirstOrDefault(s => s.Id == active)?.MarkRead();
    foreach (var child in detached.Values) if (windowState.Layout(child.Owner, child.Host).Active is { } visible) Model.Sessions.FirstOrDefault(s => s.Id == visible)?.MarkRead();
    SyncWindows();
    SyncNavigation();
  }
  private bool proofUnlistedPage; // Set only by the parity capture fixture.
  private void SyncNavigation()
  {
    if (syncingNavigation) return;
    syncingNavigation = true;
    try
    {
      foreach (var route in NavigationRoutes.Children.OfType<Microsoft.UI.Xaml.Controls.Primitives.ToggleButton>().Concat(pageNavigation.Values).Append(ProjectsRoute))
        route.IsChecked = !proofUnlistedPage && route.Tag as string == Model.Page.ToString() && (route != ProjectsRoute || Projects?.Model.SelectedId is null);
      var active = windowState?.Layout(Scope).ActiveEmpty is null ? windowState?.Layout(Scope).Active : null;
      var shown = active is null ? null : windowState!.Get(active);
      var sessionId = shown is null ? null : shown.Kind == "browser" ? shown.Owner : sidebarSessions.Any(row => row.Id == shown.Subject) ? shown.Subject : windowState!.OwnerOf(shown.Subject);
      SessionList.SelectedItem = Model.Page == ShellPage.Sessions ? sidebarSessions.FirstOrDefault(s => s.Id == sessionId) : null;
      ArchivedSessionList.SelectedItem = Model.Page == ShellPage.Sessions ? archivedSessions.FirstOrDefault(s => s.Id == sessionId) : null;
    }
    finally { syncingNavigation = false; }
  }
  private void Refresh()
  {
    if (RouteDevicesPopup()) return;
    SyncNavigation();
    PageTitle.Text = Model.Title;
    if (windowState is not null) { RefreshProjectRows(); TrackPageTab(); }
    UpdateShellNotice(Model.Notice);
    RefreshAccountChip();
    EmptySidebar.Visibility = Model.Sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    if (proofChatVisible) return;
    if (Model.Page == ShellPage.Settings) { ShowSettingsPanel(); return; }
    RenderWindows();
  }

  private FrameworkElement Pane(SessionDraft draft)
  {
    if (draft.Presentation == SessionPresentation.Chat && draft.IsLive)
    {
      if (!chatPanes.TryGetValue(draft.Id, out var chat))
      {
        chat = new ChatPage(Runtime.Chats, draft.Id, WindowHandle, currentWindowHandle: () => ChatWindowHandle(draft.Id),
          navigation: new ChatNavigation(OpenCodingAis, OpenSession, Runtime.Agents.SessionFace(draft.Id)?.Name,
            Runtime.Projects.Get(Runtime.Projects.Resolve(null, draft.Folder)).Folders,
            async id => { await Runtime.Accounts.SignInAsync(id, draft.Folder); await Runtime.RefreshSessionsAsync(); }, new ChatMcpNavigation(Runtime.Mcp, (server, tool, args, ct) => Runtime.CallChatAppToolAsync(draft.Id, server, tool, args, ct)), id => Model.Sessions.FirstOrDefault(s => s.Id == id)), accountModels: Runtime.Accounts);
        chat.Model.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(ChatViewModel.Snapshot)) SyncSessions(); };

        chatPanes.Add(draft.Id, chat);
      }
      Grid.SetColumn(chat, 0); return chat;
    }
    if (!sessionPanes.TryGetValue(draft.Id, out var pane))
    {
      pane = new SessionPane(draft, dataRoot, text => Model.Notice = text, () => _ = StopSessionAsync(draft), Runtime);
      sessionPanes.Add(draft.Id, pane);
    }
    Grid.SetColumn(pane, 0);
    return pane;
  }
  private static StackPanel EmptyState(string title, string text)
  {
    var stack = new StackPanel { Spacing = 12, Margin = new Thickness(40), MaxWidth = 500, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    stack.Children.Add(new TextBlock { Text = title, FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
    stack.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.65 });
    return stack;
  }
  private async Task StopSessionAsync(SessionDraft draft)
  {
    try { if (draft.IsLive) await Runtime.StopAsync(draft.Id); SyncSessions(); }
    catch { Model.Notice = "The session could not stop. Reconnect before trying again."; }
  }
  private void CloseDraft(SessionDraft draft)
  {
    if (sessionPanes.Remove(draft.Id, out var pane)) { if (pane.Parent is Panel parent) parent.Children.Remove(pane); else if (pane.Parent is ContentControl holder) holder.Content = null; pane.DisposeView(); }
    if (windowState.Tabs.Any(t => t.Id == draft.Id)) windowState.Close(draft.Id);
    Model.CloseDraft(draft);
    renderedPage = null; Refresh();
    SyncNavigation();
  }
  internal ContentDialog? BrowserContextDialogForProof { get; private set; }
  private async Task SendBrowserContextAsync(string context)
  {
    if (!await ReviewBrowserSendAsync(context, null, Model.Selected?.Id, Root.XamlRoot)) throw new InvalidOperationException("Browser context is kept as an unsent draft.");
  }
  internal Task WaitForTerminalsAsync() => Task.WhenAll(sessionPanes.Values.Where(p => p.Draft.Presentation == SessionPresentation.Terminal).Select(p => p.Ready));
  public void SetTheme(ElementTheme theme)
  {
    try { SaveSettingsTheme(theme); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    { Model.Notice = "The appearance could not be saved. Please try again."; }
  }
  private void QueueSurfaceTheme()
  {
    // WebView2 also handles inherited theme events. Apply after its controls finish
    // so an old inherited value cannot overwrite the person's current choice.
    DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, async () =>
    {
      try
      {
        var theme = Root.ActualTheme;
        await browser.SetSurfaceThemeAsync(theme);
        foreach (var pane in sessionPanes.Values.ToArray()) await pane.SetSurfaceThemeAsync(theme);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The page theme could not update. Try choosing the theme again."; }
    });
  }

  private async void NewSession_Click(object sender, RoutedEventArgs e)
  {
    try { await NewSessionPicker.ShowAsync(Root.XamlRoot, Runtime.Agents, Runtime.Projects, Runtime.Accounts, this,
      terminalStart: async (folder, project) => { var row = await Runtime.StartShellForProjectAsync(folder, project); OpenSession(row.Definition.Id); }); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "The new session picker could not open."; }
  }
  public async void OpenSession(string id)
  {
    if (TerminalDeck.Core.Integration.W9TaskRunner.IsHootRun(id)) { Model.Page = ShellPage.Hoot; return; }
    try { var owner = pendingWindowOwner; var host = pendingWindowHost; await Runtime.RefreshSessionsAsync(); SyncSessions(); if (owner is { Length: > 0 }) windowState.Adopt(id, owner); if (host != "main") windowState.Transfer(id, host); SelectSessionWindow(Model.Sessions.Single(s => s.Id == id)); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "This session could not open. Check the session list before starting another."; }
  }
  public void OpenProject(string id) { Projects.OpenProject(id); Model.Page = ShellPage.Projects; }
  public void OpenAgent(string id) { Agents.OpenAgent(id); Model.Page = ShellPage.Agents; }
  public ValueTask OpenAgentAsync(string id, CancellationToken ct) { ct.ThrowIfCancellationRequested(); OpenAgent(id); return ValueTask.CompletedTask; }
  public async ValueTask OpenSetupAsync(string? projectId, string? folder, string? step, CancellationToken ct)
  { ct.ThrowIfCancellationRequested(); Model.Page = ShellPage.Projects; await Projects.ShowSetupAsync(projectId, folder, step); }
  private void Projects_Click(object sender, RoutedEventArgs e) { Projects.Model.SelectedId = null; Model.Page = ShellPage.Projects; }
  private void Agents_Click(object sender, RoutedEventArgs e) { Agents.Model.SelectedId = null; Model.Page = ShellPage.Agents; }
  public ValueTask OpenAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); Model.Page = ShellPage.Hoot; return ValueTask.CompletedTask; }
  private void Hoot_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Hoot;
  private void Tasks_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Tasks;
  private void Artifacts_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Artifacts;
  private void Servers_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Servers;
  private void Receiver_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Receiver;
  private async Task ShowReceiverKeyAsync()
  {
    var value = new PasswordBox { Header = "Browser intake key", Password = await Runtime.ReceiverIntake.OwnerTokenAsync() };
    try { await new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = "Browser intake", Content = value, CloseButtonText = "Done" }.ShowAsync(); }
    finally { value.Password = ""; }
  }
  public async void QueueReceiverActivation(Microsoft.Windows.AppLifecycle.AppActivationArguments activation)
  {
    if (activation.Kind != Microsoft.Windows.AppLifecycle.ExtendedActivationKind.ShareTarget) return;
    try { await Ready; await OnUiAsync(async () => { if (await Runtime.ReceiverActivation.ActivateAsync(activation)) Model.Page = ShellPage.Receiver; }); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { DispatcherQueue.TryEnqueueHandled(() => Model.Notice = "The shared item could not be saved. Open Receiver and try again."); }
  }
  private Task OnUiAsync(Func<Task> work)
  {
    if (DispatcherQueue.HasThreadAccess) return work();
    var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!DispatcherQueue.TryEnqueueHandled(async () => { try { await work(); done.TrySetResult(); } catch (Exception ex) { done.TrySetException(ex); } })) done.TrySetException(new IOException("The window is closing."));
    return done.Task;
  }
  private void Sessions_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Sessions;
  private void Browser_Click(object sender, RoutedEventArgs e) => Model.Page = ShellPage.Browser;
  private void Settings_Click(object sender, RoutedEventArgs e) => ShowSettingsPanel();
  private void SessionList_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (!syncingNavigation && SessionList.SelectedItem is SessionDraft draft) SelectSessionWindow(draft); }
  private void SplitSessions_Click(object sender, RoutedEventArgs e) => SplitWindows(false);
  private void SplitBrowser_Click(object sender, RoutedEventArgs e) => SplitWindows(true);
  private void OnePane_Click(object sender, RoutedEventArgs e) { if (windowState.Layout(Scope).Active is { } active) windowState.One(active, Scope); Model.Split = SplitPresentation.None; }
  private void SystemTheme_Click(object sender, RoutedEventArgs e) => SetTheme(ElementTheme.Default);
  private void LightTheme_Click(object sender, RoutedEventArgs e) => SetTheme(ElementTheme.Light);
  private void DarkTheme_Click(object sender, RoutedEventArgs e) => SetTheme(ElementTheme.Dark);
  private async void Account_Click(object sender, RoutedEventArgs e) => await ShowAccountAsync();
  internal void OpenCodingAIs() { ShowSettingsPanel(); _ = settingsPanel!.SelectAsync("coding-ais"); }
  internal void DismissAccountSheet() => accountSheet?.Hide();
  public async Task ShowAccountAsync(SessionDraft? session = null, FrameworkElement? dialogRoot = null)
  {
    var selectedDraft = session ?? Model.Selected;
    var hostRoot = dialogRoot ?? Root;
    if (selectedDraft is { Presentation: SessionPresentation.Chat } && Pane(selectedDraft) is ChatPage chatPage)
    {
      chatPage.ShowAccountPicker(hostRoot);
      return;
    }
    if (accountSheet is not null) return;
    var current = selectedDraft is { IsLive: true } live
      ? Runtime.Sessions.FirstOrDefault(row => row.Definition.Id == live.Id && row.Definition.Provider != "shell") : null;
    var accounts = Runtime.Accounts.List(selectedDraft?.Provider);
    var stack = new StackPanel { Spacing = 16 };
    var feedback = new TextBlock { TextWrapping = TextWrapping.Wrap };
    feedback.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    if (accounts.Count == 0) stack.Children.Add(new TextBlock { Text = "No accounts yet.", TextWrapping = TextWrapping.Wrap });
    foreach (var account in accounts)
    {
      var row = new StackPanel { Spacing = 6 };
      row.Children.Add(new TextBlock { Text = account.Name + " · " + (account.SignedIn ? account.Email ?? "Signed in" : "Not signed in"), TextWrapping = TextWrapping.Wrap });
      var isCurrent = account.SignedIn && current?.Definition.AccountId == account.Id;
      var button = new Button { Content = !account.SignedIn ? "Sign in" : isCurrent ? "Current account" : current is not null ? "Switch this conversation" : "Choose app default in Who uses what", IsEnabled = !isCurrent };
      var switchConfirmed = false;
      button.Click += async (_, _) =>
      {
        if (!account.SignedIn)
        {
          button.IsEnabled = false; feedback.Text = "Signing in…";
          try { await Runtime.Accounts.SignInAsync(account.Id, selectedDraft?.Folder ?? Runtime.Root.DirectoryPath); }
          catch (TerminalDeck.Core.Accounts.SignInCancelledException) { feedback.Text = ""; button.IsEnabled = true; return; }
          catch (Exception ex) when (ex is not OutOfMemoryException)
          { feedback.Text = ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "Sign-in could not open. Try again."; button.IsEnabled = true; return; }
          button.IsEnabled = true; feedback.Text = "";
          if (Runtime.Accounts.Get(account.Id).SignedIn) { RefreshAccountChip(); accountSheet?.Hide(); }
          return;
        }
        if (current is null) { accountSheet?.Hide(); await OpenSettingsAsync("accounts"); return; }
        if (!switchConfirmed)
        {
          feedback.Text = "The AI terminal will reopen using this account and the same saved conversation. This can interrupt work in progress. Your tab and previous output stay here.";
          button.Content = "Switch account"; switchConfirmed = true; return;
        }
        button.IsEnabled = false;
        try
        {
          await Runtime.AccountSwitches.PlanAsync(current.Definition.Id, account.Id);
          feedback.Text = "Switching to " + account.Name + "…";
          await Runtime.AccountSwitches.SwitchAsync(current.Definition.Id, account.Id);
          await Runtime.RefreshSessionsAsync(); RefreshAccountChip();
          feedback.Text = "Switched to " + account.Name;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        { feedback.Text = ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "The account could not switch. Check the session before trying again."; }
        finally { button.IsEnabled = true; }
      };
      row.Children.Add(button); row.Children.Add(feedback); stack.Children.Add(row);
    }
    var manage = new Button { Content = "Manage accounts…" };
    manage.Click += (_, _) => { accountSheet?.Hide(); OpenCodingAIs(); };
    stack.Children.Add(manage); stack.Children.Add(feedback);
    var dialog = new ContentDialog { XamlRoot = hostRoot.XamlRoot, RequestedTheme = hostRoot.ActualTheme, Title = "Switch account", Content = new ScrollViewer { Content = stack, MaxHeight = 480, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, CloseButtonText = "Done" };
    accountSheet = dialog;
    try { await dialog.ShowAsync(); } finally { if (ReferenceEquals(accountSheet, dialog)) accountSheet = null; }
  }
  private void RefreshAccountChip()
  {
    if (Runtime is null) return;
    var account = Model.Selected is { } selected ? Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == selected.Id)?.Definition.AccountId : null;
    account ??= Model.Selected is { } chat && Runtime.Chats is not null ? Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == chat.Id)?.Definition.AccountId : null;
    var profile = Runtime.Accounts.List().FirstOrDefault(candidate => candidate.Id == account);
    AccountChip.Content = !string.Equals(Model.Selected?.Provider, "shell", StringComparison.OrdinalIgnoreCase) && account is not null && profile is null
      ? "Unavailable account" : WorkspaceText.AccountIdentity(Model.Selected?.Provider, profile?.SignedIn == true, profile?.Email, profile?.Name);
  }
  private McpToolHandler DispatchTool(McpToolSpec spec, McpToolHandler handler) => async (context, arguments, ct) =>
  {
    async Task<System.Text.Json.JsonElement> RunAsync()
    {
      if (!browser.Ready.IsCompleted && (spec.Id is "browser.open" or "browser.page" or "browser.read" or "browser.step" or "browser.batch" or "browser.upload" or "browser.screenshot" or "browser.handover" || spec.Id == "browser.windows" && arguments.TryGetProperty("action", out var action) && action.GetString() == "open"))
      { await context.EnsureCurrentAsync(ct); await browser.Ready.WaitAsync(ct); }
      if (spec.Id == "browser.handover")
      {
        await context.EnsureCurrentAsync(ct);
        var wanted = arguments.TryGetProperty("window", out var named) ? named.GetString() : null;
        var target = browser.Core.Read().Tabs.FirstOrDefault(t => wanted is null ? t.Id == browser.Core.Read().SelectedTabId : t.Id == wanted || t.Window == wanted || t.SessionSlot == wanted);
        if (target is not null) { SyncWindows(); RevealBrowserWindow(target.Id); await browser.SelectShellWindowAsync(target.Id); browser.ShowShellHandover(target.Id); }
      }
      System.Text.Json.JsonElement result;
      var picture = spec.Id == "browser.screenshot" || spec.Id == "browser.page" && arguments.TryGetProperty("action", out var pageAction) && pageAction.GetString() == "screenshot";
      try { result = await handler(context, arguments, ct); }
      catch (TimeoutException) when (picture)
      {
        throw new InvalidOperationException("This background page could not draw a picture. DOM reads and steps can continue in the background. Use browser_handover only when the person needs to see the page.");
      }
      browser.ObserveShellPages(); SyncWindows(); QueueVisibleBrowserViews();
      return result;
    }
    if (DispatcherQueue.HasThreadAccess) return await RunAsync();
    var done = new TaskCompletionSource<System.Text.Json.JsonElement>();
    if (!DispatcherQueue.TryEnqueueHandled(async () => { try { done.TrySetResult(await RunAsync()); } catch (Exception ex) { done.TrySetException(ex); } })) throw new IOException("The app is closing.");
    return await done.Task.WaitAsync(ct);
  };
  internal string PageTitleForProof => PageTitle.Text;
  internal TerminalDeck.App.Views.Tasks.TasksPage TasksForProof => tasksPage!;
  internal TerminalDeck.App.Views.Servers.ServersPage ServersForProof => serversPage!;
  internal ChatPage SelectedChat => chatPanes[Model.Selected!.Id];
  internal void ShowProjectsForProof() { Projects.Model.SelectedId = null; Model.Page = ShellPage.Projects; }
  internal void ShowAgentsForProof() { Agents.Model.SelectedId = null; Model.Page = ShellPage.Agents; }
  internal void ShowProofChat(ChatPage page)
  {
    Model.Page = ShellPage.Settings;
    proofChatVisible = true; Workspace.Children.Clear(); Workspace.Children.Add(page); PageTitle.Text = "Chat · fake CLI demonstration";
  }
  internal void HideProofChat() { Workspace.Children.Clear(); proofChatVisible = false; renderedPage = null; Refresh(); }
  internal SessionPane SelectedPane => sessionPanes[Model.Selected!.Id];
  // Hoot's "/" menu: its chat's reported commands plus the skills of Hoot's folder and account.
  private IReadOnlyList<TerminalDeck.Core.Chats.ChatSlashCommand> HootSlashCommands()
  {
    var state = Runtime.Hoot.Read(); if (state.Settings is not { } settings) return [];
    var chat = state.ChatId is { } id ? Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id) : null;
    string? home = null; try { home = Runtime.Accounts.Get(settings.AccountId).HomeId; } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    return TerminalDeck.App.Views.Chat.ChatSlashSources.For(chat, settings.Provider, settings.Folder, home, Runtime.Root);
  }
}
