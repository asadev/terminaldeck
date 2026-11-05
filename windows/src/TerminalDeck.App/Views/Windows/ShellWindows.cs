using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Projects;
using TerminalDeck.App.Views.Projects;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Mcp;
using System.Text.Json;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private static bool W12Proof => Environment.GetEnvironmentVariable("TD_W12_SHELL_PROOF") is not null;
  private static void ActivateWindow(Window window) { if (W12Proof) window.AppWindow.Show(false); else window.Activate(); }
  private WorkspaceState windowState = null!;
  private WorkspaceSurface mainSurface = null!;
  private readonly Dictionary<string, DetachedWorkspace> detached = [];
  private readonly HashSet<string> hiddenTabs = [];
  private readonly System.Collections.ObjectModel.ObservableCollection<SessionDraft> sidebarSessions = [];
  private readonly System.Collections.ObjectModel.ObservableCollection<SessionDraft> archivedSessions = [];
  private string workspaceOwner = "";
  private HashSet<string> archivedJobSessions = [];
  private bool IsHistory(SessionDraft row) => SidebarHistory.IsHistory(row, archivedJobSessions);
  private bool syncingWindows;
  private bool renderingWindows;
  private string renderedWindowsStructure = "";
  private string renderedTabsStructure = "";
  private int renderBatch;
  private bool closingShell;
  private bool mainWindowHidden;
  private bool sidebarVisible = true;
  private string? pendingWindowOwner;
  private string pendingWindowHost = "main";
  private void InitializeWindows(AppDataRoot root)
  {
    var store = new JsonStateStore<WorkspaceSaved>(root, "shell-windows");
    WorkspaceSaved? saved = null;
    try { saved = Runtime.General.Read().RestoreSessions ? store.Load() : null; } catch (Exception ex) when (ex is IOException or JsonException) { Model.Notice = "The saved window layout could not open. Your sessions are still available."; }
    InitializeWindowGeometry();
    InitializeSidebar(root, saved is not null);
    try { windowState = new(saved, store.Save); }
    catch (ArgumentException) { windowState = new(persist: store.Save); Model.Notice = "The saved window layout was invalid. Your sessions are still available."; }
    // Devices now has one anchored surface; retire only its obsolete page tabs.
    foreach (var legacy in windowState.Tabs.Where(t => t.Kind == "page" && t.Subject == "Devices").ToArray()) windowState.Close(legacy.Id);
    mainSurface = MakeSurface("main"); WorkspaceHeader.Content = mainSurface.Header;
    SessionPicture.Projects = Runtime.Projects;
    BrowserEngineHost.Children.Add(browser);
    // The 1x1 engine host keeps the legacy pane's own toolbar in the tree. It took
    // first keyboard focus at launch and showed a stray "Reload page" tooltip over
    // the sidebar; shell browser tabs draw their own toolbar, so collapse this one.
    browser.HideEngineChrome();
    browser.Core.ResolveDriverName = grant => Runtime.Agents.Runs().FirstOrDefault(r => r.SessionId == grant.SessionId)?.AgentName ?? TerminalDeck.Core.Browser.BrowserModel.DriverLabel(grant);
    browser.ShellChanged += () => { SyncWindows(); QueueVisibleBrowserViews(); };
    browser.ShellSelected += RevealBrowserWindow;
    // The sidebar lists sessions, not which tab is selected: refreshing it can
    // wait for the frame that shows a change, and several changes share one refresh.
    windowState.Changed += () => { if (!syncingWindows) { RenderWindows(); UpdateSidebarSessionsSoon(); } };
    _ = new WorkspaceTitleBar(this, Root, TitleBarRow, CaptionSpace);
    AppWindow.Closing += (_, args) =>
    {
      CloseSettingsPanel();
      if (closingShell || detached.Count == 0) return;
      // Keep the shared runtime and retained pages alive while another app
      // window is open. Returning a page can reveal this same main window.
      args.Cancel = true; mainWindowHidden = true; AppWindow.Hide();
    };
    Root.ActualThemeChanged += (_, _) =>
    {
      foreach (var child in detached.Values) child.Root.RequestedTheme = Root.RequestedTheme;
    };
    InitializeShellCommands(Root);
    SessionList.ItemsSource = sidebarSessions; ArchivedSessionList.ItemsSource = archivedSessions;
    InitializeSidebarSessionDrag();
    SessionList.RightTapped += (_, args) =>
    {
      if (args.OriginalSource is not DependencyObject source) return;
      var element = source as FrameworkElement;
      while (element is not null && element.DataContext is not SessionDraft) element = VisualTreeHelper.GetParent(element) as FrameworkElement;
      if (element?.DataContext is not SessionDraft row) return;
      var flyout = SessionMenu(row);
      flyout.ShowAt(SessionList, args.GetPosition(SessionList)); args.Handled = true;
    };
  }
  private WorkspaceSurface MakeSurface(string host)
  {
    var surface = new WorkspaceSurface(windowState, host, WindowView, FocusWindow, CloseWindowAsync, RenameWindowAsync, PopTab, DockTab, DockOwner, (owner, kind) => CreateWindowAsync(owner, kind, host), WindowAccountLabel, WindowLocationLabel, tab => Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject), ShowWindowAccountAsync, StopWindowAsync, message => Model.Notice = message);
    surface.SessionMenu = tab => Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject) is { } row ? SessionMenu(row) : new MenuFlyout();
    surface.SaveTitle = SaveWindowTitleAsync;
    surface.Batch = work => { renderBatch++; try { work(); } finally { if (--renderBatch == 0) RenderWindows(); } };
    surface.IsModalOpen = () => host == "main" ? IsShellModalOpen(Root.XamlRoot) : detached.TryGetValue(host, out var child) && IsShellModalOpen(child.Root.XamlRoot);
    surface.BrowserIdentity = tab => tab.Kind == "browser" ? browser.ShellIdentity(tab.Subject) : null;
    surface.ProjectIdentity = tab => Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject)?.ProjectId is { } id && Runtime.Projects.List().FirstOrDefault(p => p.Id == id) is { } project
      ? ShellProjectPicture(project, 14) : null;
    surface.AccountBadge = WindowAccountBadge;
    surface.UsageMeter = WindowUsageMeter;
    surface.DeploymentStrip = tab => new Quality.DeploymentStrip(Runtime.Deployments, session: tab.Subject);
    surface.BeginManualSplit = LeaveSwarm;
    surface.DragOutside = id =>
    {
      var window = host == "main" ? (Window)this : detached.TryGetValue(host, out var child) ? child.Window : null;
      if (window is not null && host == "main" && WorkspaceDrag.Outside(window)) PopTab(id);
    };
    surface.MergeDrop = (source, target) =>
    {
      var tab = windowState.Get(source); var old = tab.Host;
      windowState.Transfer(source, host); windowState.Move(source, windowState.Tabs.Where(t => t.Host == host).ToList().FindIndex(t => t.Id == target));
      if (old != "main" && detached.TryGetValue(old, out var child))
    {
      if (windowState.Tabs.FirstOrDefault(t => t.Host == old) is { } next)
      { windowState.Select(next.Id); detached[old] = child with { Owner = next.Owner }; }
      else child.Window.Close();
    }
      FocusWindow(tab.Owner, source);
    };
    return surface;
  }
  private UIElement ShellProjectPicture(Project project, double size)
  {
    var picture = ProjectAgentUi.ProjectPicture(Runtime.Projects, project, size);
    if (picture is Border tile) { tile.CornerRadius = new(size / 4); RoundedContentClip.Attach(tile, radius: size / 4); }
    return picture;
  }
  private string WindowFolder(WorkspaceTab tab) => Model.Sessions.FirstOrDefault(s => s.Id == (tab.Kind == "browser" ? tab.Owner : tab.Subject))?.Folder ?? "";
  private string WindowLocationLabel(WorkspaceTab tab)
  {
    var path = WindowFolder(tab);
    var serverId = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition.ServerId;
    if (serverId is null) return path;
    var server = Runtime.Servers.List(TerminalDeck.Core.Servers.ServerCaller.Person).FirstOrDefault(s => s.Id == serverId);
    return (server?.Name ?? "Server unavailable") + " · " + path;
  }
  private string WindowAccountLabel(WorkspaceTab tab)
  {
    var accountId = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition.AccountId
      ?? Runtime.Chats?.List().FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition.AccountId;
    var account = Runtime.Accounts.List().FirstOrDefault(a => a.Id == accountId);
    var provider = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition.Provider ?? Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject)?.Provider;
    if (!string.Equals(provider, "shell", StringComparison.OrdinalIgnoreCase) && accountId is not null && account is null) return "Unavailable account";
    return WorkspaceText.AccountIdentity(provider, account?.SignedIn == true, account?.Email, account?.Name);
  }
  private string? WindowAccountBadge(WorkspaceTab tab)
  {
    var definition = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition;
    var chat = Runtime.Chats?.List().FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition;
    var id = definition?.AccountId ?? chat?.AccountId;
    var provider = definition?.Provider ?? chat?.Provider;
    if (id is null || provider is null) return null;
    var profile = Runtime.Accounts.List().FirstOrDefault(a => a.Id == id);
    return profile is null || Runtime.Accounts.Default(provider, definition?.Cwd ?? chat?.Cwd)?.Id == id ? null : profile.Name;
  }
  private Task ShowWindowAccountAsync(WorkspaceTab tab, FrameworkElement anchor)
  {
    if (tab.Kind == "chat" && WindowView(tab) is TerminalDeck.App.Views.Chat.ChatPage chat)
    {
      chat.ShowAccountPicker(anchor);
      return Task.CompletedTask;
    }
    if (string.Equals(Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject)?.Provider, "shell", StringComparison.OrdinalIgnoreCase))
    {
      new Flyout { Content = new TextBlock { Text = "This shell session does not use an AI account." } }.ShowAt(anchor);
      return Task.CompletedTask;
    }
    return ShowAccountAsync(Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject), tab.Host == "main" ? Root : detached[tab.Host].Root);
  }
  // Context window + plan limits for this session's own login (Mac: NativeUsageBar). Nothing is drawn where no
  // figure can exist (shells, Gemini, server terminals), never the word "unknown".
  private FrameworkElement? WindowUsageMeter(WorkspaceTab tab)
  {
    if (tab.Kind is "browser" or "page") return null;
    var record = Runtime.Sessions.FirstOrDefault(s => s.Definition.Id == tab.Subject)?.Definition;
    var provider = record?.Provider ?? Runtime.Chats?.List().FirstOrDefault(c => c.Definition.Id == tab.Subject)?.Definition.Provider;
    if (record?.ServerId is not null) return null;
    var meters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    meters.Children.Add(new TerminalDeck.App.Views.Usage.DesktopResourceMeter(Runtime));
    if (TerminalDeck.App.Views.Usage.UsageMeter.Applies(provider, false))
      meters.Children.Add(new TerminalDeck.App.Views.Usage.UsageMeter(Runtime.Usage, tab.Subject, provider!));
    return meters;
  }
  private Task StopWindowAsync(WorkspaceTab tab) => Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject) is { } row ? StopSessionAsync(row) : Task.CompletedTask;
  private string Scope => Model.Page == ShellPage.Browser ? "browser" : Model.Page == ShellPage.Sessions ? swarm ? "swarm" : workspaceOwner : "pages";
  private void SyncWindows()
  {
    // An empty startup catalogue is not evidence that saved tabs were closed.
    if (!Ready.IsCompletedSuccessfully || windowState is null || syncingWindows) return;
    syncingWindows = true;
    try
    {
      foreach (var row in Model.Sessions)
        if (!hiddenTabs.Contains(row.Id) && !windowState.IsClosed(row.Id) && (!row.IsLive || Runtime.Tasks is not null) && (windowState.Tabs.Any(t => t.Id == row.Id) || !IsHistory(row))) windowState.Ensure(row.Id, windowState.OwnerOf(row.Id), row.Id, row.Presentation == SessionPresentation.Chat ? "chat" : "terminal", row.Title);
      foreach (var tab in windowState.Tabs.Where(t => t.Kind is not ("browser" or "page") && !Model.Sessions.Any(s => s.Id == t.Subject)).ToArray()) windowState.Close(tab.Id);
      var pages = browser.Core.Read().Tabs;
      foreach (var page in pages.Where(p => !windowState.IsClosed(p.Id)))
        windowState.Ensure(page.Id, page.SessionId is { } session ? windowState.OwnerOf(session) : "browser", page.Id, "browser", (page.SessionSlot ?? page.Window) + " · " + (page.Title.Length == 0 ? "New browser" : page.Title));
      foreach (var tab in windowState.Tabs.Where(t => t.Kind == "browser" && !pages.Any(p => p.Id == t.Subject)).ToArray()) { windowState.Close(tab.Id); browser.ForgetShellView(tab.Subject); }
      if (swarm) windowState.RefreshSwarm(windowState.Tabs.Where(tab => tab.Kind is "terminal" or "chat" && Model.Sessions.Any(row => row.Id == tab.Subject && row.State is not ("ended" or "exited") && !sidebar.Read.HiddenSessions.Contains(row.Id))).Select(tab => tab.Id).ToArray());
      if (workspaceOwner.Length == 0 && Model.Selected is { } selected) workspaceOwner = windowState.OwnerOf(selected.Id);
      if (Scope.Length > 0 && windowState.Layout(Scope).Active is null && windowState.Tabs.FirstOrDefault(t => t.Owner == Scope && t.Host == "main") is { } first) windowState.Select(first.Id);
    }
    finally { syncingWindows = false; }
    UpdateSidebarSessions(); RenderWindows();
  }
  private void UpdateSidebarSessions()
  {
    if (windowState is null) return;
    var rows = Model.Sessions.Where(s => windowState.OwnerOf(s.Id) == s.Id && !sidebar.Read.HiddenSessions.Contains(s.Id)).ToArray();
    void SyncRows(System.Collections.ObjectModel.ObservableCollection<SessionDraft> list, SessionDraft[] values)
    {
      for (var i = list.Count - 1; i >= 0; i--) if (!values.Contains(list[i])) list.RemoveAt(i);
      for (var i = 0; i < values.Length; i++)
      { var at = list.IndexOf(values[i]); if (at < 0) list.Insert(i, values[i]); else if (at != i) list.Move(at, i); }
    }
    SyncRows(sidebarSessions, sidebar.Sort(rows.Where(r => !IsHistory(r) && !sidebar.IsArchived(r.Id)), r => r.Id).ToArray());
    SyncRows(archivedSessions, rows.Where(r => r.Presentation == SessionPresentation.Chat && sidebar.IsArchived(r.Id)).ToArray());
    ArchivedSessions.Visibility = archivedSessions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    ArchivedChatsToggle.Content = (ArchivedChatRows.Visibility == Visibility.Visible ? "⌄ " : "› ") + "Archived chats (" + archivedSessions.Count + ")";
    ArchivedChatRows.Children.Clear();
    foreach (var chat in archivedSessions)
    {
      var row = new Grid(); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var open = new Button { Content = ProjectAgentUi.SessionIdentityRow(chat), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"] };
      if (open.Content is Grid identity)
      {
        var selected = Model.Page == ShellPage.Sessions && Model.Selected == chat;
        // One line each with "…", fixed row height, like the running rows (Mac).
        foreach (var line in WorkspaceVisuals.Tree(identity).OfType<TextBlock>()) { line.TextWrapping = TextWrapping.NoWrap; line.TextTrimming = TextTrimming.CharacterEllipsis; line.MaxLines = 1; }
        foreach (var picture in WorkspaceVisuals.Tree(identity).OfType<SessionPicture>()) { picture.OnAccent = selected; picture.RowSurface("DeckRailBrush"); }
        if (selected)
        {
          open.SetResourceReference(Control.BackgroundProperty, "DeckSidebarSelectionBrush");
          foreach (var text in WorkspaceVisuals.Tree(identity).OfType<TextBlock>().Where(t => !WorkspaceVisuals.Tree(identity).OfType<SessionPicture>().Any(p => WorkspaceVisuals.Tree(p).Contains(t))))
            text.SetResourceReference(TextBlock.ForegroundProperty, "DeckSidebarSelectionInkBrush");
        }
      }
      open.Click += (_, _) => SelectSessionWindow(chat); row.Children.Add(open);
      var restore = new Button { Content = "Restore", Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"], FontSize = 12 };
      restore.Click += (_, _) => SidebarGuard(() => sidebar.ArchiveChat(chat.Id, false)); Grid.SetColumn(restore, 1); row.Children.Add(restore); ArchivedChatRows.Children.Add(row);
    }
    EmptySidebar.Visibility = sidebarSessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    RefreshProjectRows(); SyncNavigation();
  }
  private string renderedProjects = "";
  private readonly List<Control> projectNavigation = [];
  private void RefreshProjectRows()
  {
    var projects = Runtime.Projects.List().Where(p => p.IsOpen).ToArray();
    var key = JsonSerializer.Serialize(new { rows = projects.Select(p => new { p.Id, p.Name, p.Colour, p.Logo, count = ProjectRunningCount(p.Id) }), selected = Model.Page == ShellPage.Projects ? Projects?.Model.SelectedId : null, page = Model.Page });
    RefreshPageCounts();
    if (key == renderedProjects) return; renderedProjects = key; ProjectRows.Children.Clear(); projectNavigation.Clear();
    if (projects.Length == 0)
    {
      var create = new Button { Content = "New project…", Style = (Style)Application.Current.Resources["DeckSidebarActionStyle"], HorizontalAlignment = HorizontalAlignment.Stretch };
      create.Click += NewProject_Click; ProjectRows.Children.Add(create); projectNavigation.Add(create);
    }
    foreach (var project in projects)
    {
      var picture = ShellProjectPicture(project, 14);
      var label = new Grid(); label.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var count = new TextBlock { Text = ProjectRunningCount(project.Id) is var total && total > 0 ? total.ToString() : "", FontSize = 12, Opacity = 0.6 };
      label.Children.Add(new TextBlock { Text = project.Name, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis }); Grid.SetColumn(count, 1);
      var content = new Grid { ColumnSpacing = 8 }; content.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); content.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
      content.Children.Add(picture); Grid.SetColumn(label, 1); content.Children.Add(label);
      var button = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = content, IsChecked = Model.Page == ShellPage.Projects && Projects?.Model.SelectedId == project.Id, Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"], HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
      button.ContextFlyout = ProjectMenu(project);
      button.Click += (_, _) => { OpenProject(project.Id); RefreshProjectRows(); }; projectNavigation.Add(button);
      var wrapper = new Grid(); wrapper.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); wrapper.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); wrapper.Children.Add(button);
      var badge = new Button { Content = count, Width = 32, MinWidth = 32, MinHeight = 24, Height = 26, HorizontalContentAlignment = HorizontalAlignment.Right, Padding = new(0, 0, 8, 0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Visibility = count.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(badge, "Show running unpinned sessions in " + project.Name);
      badge.Click += (_, _) => ShowProjectSessionsCount(project.Id, badge); Grid.SetColumn(badge, 1); wrapper.Children.Add(badge); ProjectRows.Children.Add(wrapper);
    }
  }
  private async void NewProject_Click(object sender, RoutedEventArgs args)
  {
    try { Model.Page = ShellPage.Projects; await Projects.ShowSetupAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The project setup could not open. Try again from Projects."; }
  }
  private void PopActive_Click(object sender, RoutedEventArgs args) { if (windowState.Layout(Scope).Active is { } id) PopTab(id); }
  private readonly Dictionary<ShellPage, FrameworkElement> pageViews = [];
  private FrameworkElement WindowView(WorkspaceTab tab)
  {
    if (tab.Kind == "browser") return browser.Ready.IsCompletedSuccessfully ? browser.ShellView(tab.Subject) : new WorkspaceLoadingView(browser: true);
    if (tab.Kind != "page") return Pane(Model.Sessions.Single(s => s.Id == tab.Subject));
    return PageView(Enum.Parse<ShellPage>(tab.Subject));
  }
  private FrameworkElement PageView(ShellPage page)
  {
    if (pageViews.TryGetValue(page, out var retained)) return retained;
    FrameworkElement content = page switch
    {
      ShellPage.Projects => Projects, ShellPage.Agents => Agents,
      ShellPage.Tasks when tasksPage is not null => tasksPage,
      ShellPage.Hoot when hootPage is not null => hootPage,
      ShellPage.Servers when serversPage is not null => serversPage,
      ShellPage.Hooks => new Hooks.HooksPage(Runtime),
      ShellPage.Store => new Store.StorePage(Runtime.AppStore, () => { Model.Page = ShellPage.Mcp; }),
      ShellPage.Mcp => ConnectionPage(page),
      ShellPage.Files or ShellPage.SourceControl or ShellPage.GitHub => CodePageView(page),
      ShellPage.Receiver when Runtime.Receiver is not null => new TerminalDeck.App.Views.Receiver.ReceiverPage(new(Runtime.Receiver, Runtime.ReceiverIntake), Runtime.ReceiverProjectChoices(), ShowReceiverKeyAsync, sourceSettings: Runtime.ReceiverSources),
      ShellPage.Artifacts when Runtime.Artifacts is not null && Runtime.Receiver is not null => new TerminalDeck.App.Views.Receiver.ArtifactsPage(Runtime.Artifacts, Runtime.Receiver, Runtime.ReceiverArtifactFolders(), OpenSession),
      _ => new WorkspaceLoadingView()
    };
    if (content is not WorkspaceLoadingView) pageViews[page] = content;
    if (page == ShellPage.Receiver) { receiverDrop?.Dispose(); receiverDrop = Runtime.ReceiverActivation.BindDrop(content); }
    return content;
  }

  private void RenderWindows()
  {
    if (!Ready.IsCompletedSuccessfully || mainSurface is null || renderingWindows || syncingWindows || renderBatch > 0 || proofChatVisible || closingShell || Model.Page == ShellPage.Settings) return;
    // What the tab chips show, apart from which one is selected.
    var tabsStructure = JsonSerializer.Serialize(new { page = Model.Page, tabs = windowState.Tabs, identities = Model.Sessions.Select(s => new { s.Id, s.ProjectId, s.PictureUri, colour = Runtime.Projects.List().FirstOrDefault(p => p.Id == s.ProjectId)?.Colour, badge = windowState.Tabs.FirstOrDefault(t => t.Subject == s.Id) is { } tab ? WindowAccountBadge(tab) : null }), browserIdentity = windowState.Tabs.Where(t => t.Kind == "browser").Select(t => browser.ShellIdentity(t.Subject)) });
    var structure = JsonSerializer.Serialize(new { scope = Scope, roots = windowState.Layouts.Select(l => new { l.Owner, l.Host, l.Root }) }) + tabsStructure;
    if (renderedWindowsStructure == structure) { mainSurface.UpdateFocus(); foreach (var child in detached.Values) child.Surface.UpdateFocus(); QueueVisibleBrowserViews(); return; }
    // A tab switch changes the scope or layout but not the tabs: rebuilding every
    // chip (icons, menus, pictures) on each click made switching visibly slow.
    var panesOnly = renderedWindowsStructure.Length > 0 && renderedTabsStructure == tabsStructure && Model.Page is (ShellPage.Sessions or ShellPage.Browser) && Workspace.Children.Contains(mainSurface);
    renderedWindowsStructure = structure; renderedTabsStructure = tabsStructure;
    renderingWindows = true;
    try
    {
      if (panesOnly)
      {
        mainSurface.RenderPanes(Scope); renderedPage = Model.Page;
        foreach (var child in detached.Values.ToArray())
        {
          child.Surface.RenderPanes(child.Owner);
          child.Window.Title = windowState.Layout(child.Owner, child.Host).Active is { } active ? windowState.Get(active).Title : TerminalDeck.Core.Brand.Name;
        }
        return;
      }
      mainSurface.ReleaseViews(); foreach (var child in detached.Values) child.Surface.ReleaseViews();
      WorkspaceHeader.Visibility = Visibility.Visible; PageTitle.Visibility = Visibility.Collapsed;
      if (!Workspace.Children.Contains(mainSurface)) { Workspace.Children.Clear(); Workspace.Children.Add(mainSurface); }
      mainSurface.Render(Scope); renderedPage = Model.Page;
      if (Model.Page is not (ShellPage.Sessions or ShellPage.Browser))
      {
        var pageTab = windowState.Tabs.FirstOrDefault(t => t.Id == "page:" + Model.Page);
        if (pageTab is null) { Workspace.Children.Clear(); var pageView = PageView(Model.Page); if (pageView.Parent is Panel parent) parent.Children.Remove(pageView); Workspace.Children.Add(pageView); mainSurface.RenderHeader(null); }
      }
      if (Model.Page is not (ShellPage.Sessions or ShellPage.Browser) && windowState.Tabs.FirstOrDefault(t => t.Id == "page:" + Model.Page) is { Host: not "main" } separate)
      {
        var reveal = new Button { Content = "Show " + separate.Title + " window", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        reveal.Click += (_, _) => { if (detached.TryGetValue(separate.Host, out var open)) ActivateWindow(open.Window); };
        Workspace.Children.Clear(); Workspace.Children.Add(reveal);
      }
      foreach (var child in detached.Values.ToArray())
      {
        child.Surface.Render(child.Owner);
        child.Window.Title = windowState.Layout(child.Owner, child.Host).Active is { } active ? windowState.Get(active).Title : TerminalDeck.Core.Brand.Name;
      }
    }
    finally { renderingWindows = false; QueueVisibleBrowserViews(); }
  }
  private void TrackPageTab()
  {
    if (windowState is null || Model.Page is ShellPage.Sessions or ShellPage.Browser or ShellPage.Settings) return;
    syncingWindows = true;
    try { var id = "page:" + Model.Page; if (windowState.Tabs.FirstOrDefault(t => t.Id == id) is { Host: "main" }) windowState.Select(id); }
    finally { syncingWindows = false; }
  }
  private void SelectSessionWindow(SessionDraft draft)
  {
    var focusedLayout = windowState.Layout(Scope);
    if (focusedLayout.ActiveEmpty is { } emptyId)
    {
      EnsureSessionTab(draft);
      if (windowState.Get(draft.Id).Host != "main") { ActivateWindow(detached[windowState.Get(draft.Id).Host].Window); return; }
      windowState.FillEmpty(Scope, "main", emptyId, draft.Id); FocusWindow(Scope, draft.Id); return;
    }
    if (swarm && windowState.Layout("swarm").Root?.Tabs.Contains(draft.Id) == true) windowState.Focus(draft.Id, "swarm");
    else swarm = false;
    var scopeOwner = windowState.OwnerOf(draft.Id);
    hiddenTabs.Remove(draft.Id); sidebar.HideSession(draft.Id, false); windowState.Reveal(draft.Id);
    windowState.Ensure(draft.Id, scopeOwner, draft.Id, draft.Presentation == SessionPresentation.Chat ? "chat" : "terminal", draft.Title);
    var target = windowState.Get(draft.Id);
    if (target.Host != "main" && detached.TryGetValue(target.Host, out var child))
    { windowState.Select(draft.Id); FocusWindow(scopeOwner, draft.Id); ActivateWindow(child.Window); return; }
    workspaceOwner = scopeOwner; windowState.Select(draft.Id); Model.Select(draft); RenderWindows();
  }
  private void FocusWindow(string owner, string id)
  {
    if (owner != "swarm") swarm = false;
    var tab = windowState.Get(id);
    if (tab.Host != "main" && detached.TryGetValue(tab.Host, out var hostWindow) && hostWindow.Owner != owner)
    { detached[tab.Host] = hostWindow with { Owner = owner }; renderedWindowsStructure = ""; RenderWindows(); }
    if (tab.Kind == "page") { if (tab.Host != "main" && detached.TryGetValue(tab.Host, out var pageWindow)) ActivateWindow(pageWindow.Window); else Model.Page = Enum.Parse<ShellPage>(tab.Subject); return; }
    if (tab.Kind == "browser") _ = SelectBrowserForShellAsync(tab.Subject);
    if (tab.Host != "main") return;
    workspaceOwner = owner;
    // The panes render from workspaceOwner alone. When the window already shows
    // sessions (a tab switch), the selection's bookkeeping (the view model's
    // Selected, which re-syncs windows and the sidebar, read marks, the account
    // chip, navigation) waits until the frame showing the new tab is drawn.
    if (Model.Page is ShellPage.Sessions or ShellPage.Browser) AfterNextFrame(Follow); else Follow();
    void Follow()
    {
      if (!windowState.Tabs.Any(t => t.Id == id)) return;
      if (tab.Kind == "browser" && owner != "browser" && Model.Sessions.FirstOrDefault(s => s.Id == owner) is { } parent) Model.Select(parent);
      else if (tab.Kind != "browser" && Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject) is { } row)
      {
        if (Model.Selected != row || Model.Page != ShellPage.Sessions) Model.Select(row);
      }
      else if (Model.Page is not (ShellPage.Sessions or ShellPage.Browser)) Model.Page = owner == "browser" ? ShellPage.Browser : ShellPage.Sessions;
      Model.Sessions.FirstOrDefault(s => s.Id == tab.Subject)?.MarkRead();
      RefreshAccountChip(); SyncNavigation();
    }
  }
  // Work that only follows what is on screen runs once the next frame has been
  // drawn: Rendering fires as a frame starts, so the second call comes after the
  // frame that shows the change. Subscribing also makes sure that frame happens.
  private readonly List<Action> afterFrame = [];
  private void AfterNextFrame(Action work)
  {
    afterFrame.Add(work);
    if (afterFrame.Count > 1) return;
    var frames = 0;
    void Tick(object? sender, object args)
    {
      if (++frames < 2) return;
      Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= Tick;
      var pending = afterFrame.ToArray(); afterFrame.Clear();
      foreach (var item in pending) item();
    }
    Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += Tick;
  }
  private bool sidebarPending;
  private void UpdateSidebarSessionsSoon()
  {
    if (sidebarPending) return;
    sidebarPending = true;
    AfterNextFrame(() => { sidebarPending = false; UpdateSidebarSessions(); });
  }
  private void RevealBrowserWindow(string id)
  {
    if (!windowState.Tabs.Any(t => t.Id == id)) return;
    var tab = windowState.Get(id); windowState.Select(id);
    if (tab.Host != "main") { FocusWindow(tab.Owner, id); if (detached.TryGetValue(tab.Host, out var child)) ActivateWindow(child.Window); }
    else { workspaceOwner = tab.Owner; Model.Page = tab.Owner == "browser" ? ShellPage.Browser : ShellPage.Sessions; }
  }
  private async Task CreateWindowAsync(string owner, string kind, string host = "main")
  {
    if (owner is "pages" or "swarm") owner = "";
    Model.Notice = "Opening window…";
    try
    {
      if (kind == "browser")
      {
        var session = Model.Sessions.FirstOrDefault(s => s.Id == owner);
        if (host == "main") { Model.Page = session is null ? ShellPage.Browser : ShellPage.Sessions; if (session is not null) workspaceOwner = owner; }
        await browser.PrepareShellAsync();
        var page = await browser.Core.OpenAsync("https://start.deck.invalid/index.html", sessionId: session?.Id);
        browser.ObserveShellPages(); SyncWindows(); windowState.Select(page.Id); if (host != "main") windowState.Transfer(page.Id, host); RenderWindows();
      }
      else if (kind == "terminal" && Model.Sessions.FirstOrDefault(s => s.Id == owner) is { } session)
      {
        var project = Runtime.Projects.Resolve(null, session.Folder);
        var row = await Runtime.StartShellForProjectAsync(session.Folder, project);
        SyncSessions(); windowState.Adopt(row.Definition.Id, owner); if (host != "main") windowState.Transfer(row.Definition.Id, host); else { workspaceOwner = owner; Model.Select(Model.Sessions.Single(s => s.Id == row.Definition.Id)); }
      }
      else if (kind == "terminal")
      {
        // The top bar's terminal button opens a plain shell (PowerShell) right away, like a new
        // terminal tab anywhere else: in the active project's home folder, else the person's home.
        var projectId = Runtime.Projects.ActiveProjectId is { } active && active != TerminalDeck.Core.Projects.ProjectIdentity.IndependentId ? active : TerminalDeck.Core.Projects.ProjectIdentity.IndependentId;
        var folder = (projectId != TerminalDeck.Core.Projects.ProjectIdentity.IndependentId ? Runtime.Projects.Get(projectId).HomeFolder : null)
          is { } home && Directory.Exists(home) ? home : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (folder == Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) projectId = TerminalDeck.Core.Projects.ProjectIdentity.IndependentId;
        var row = await Runtime.StartShellForProjectAsync(folder, projectId);
        if (host != "main") { SyncSessions(); windowState.Transfer(row.Definition.Id, host); } else OpenSession(row.Definition.Id);
      }
      else
      {
        pendingWindowOwner = owner is "" or "browser" ? null : owner; pendingWindowHost = host;
        await NewSessionPicker.ShowAsync(Root.XamlRoot, Runtime.Agents, Runtime.Projects, Runtime.Accounts, this, mode: kind == "terminal" ? "terminal" : "chat",
          terminalStart: async (folder, project) => { var row = await Runtime.StartShellForProjectAsync(folder, project); OpenSession(row.Definition.Id); });
      }
      Model.Notice = "";
    }
    finally { pendingWindowOwner = null; pendingWindowHost = "main"; }
  }
  private async Task CloseWindowAsync(string id)
  {
    var tab = windowState.Get(id);
    var peers = windowState.Tabs.Where(t => t.Host == tab.Host).ToArray(); var index = Array.FindIndex(peers, t => t.Id == id);
    var active = FocusedTab(tab.Host)?.Id == id;
    if (tab.Kind == "browser") await CloseBrowserWindowAsync(tab);
    else { if (tab.Kind != "page") hiddenTabs.Add(id); windowState.Close(id); }
    if (active)
    {
      var remaining = windowState.Tabs.Where(t => t.Host == tab.Host).ToArray();
      if (remaining.Length > 0)
      {
        var next = remaining[Math.Clamp(index, 0, remaining.Length - 1)]; windowState.Select(next.Id); FocusWindow(next.Owner, next.Id);
      }
      else if (tab.Host != "main" && detached.TryGetValue(tab.Host, out var child)) child.Window.Close();
      else { Model.Page = ShellPage.Sessions; workspaceOwner = ""; }
    }
    RenderWindows();
  }
  private async Task CloseBrowserWindowAsync(WorkspaceTab tab)
  { await browser.Core.CloseAsync(tab.Subject); browser.ForgetShellView(tab.Subject); SyncWindows(); }
  private async Task RenameWindowAsync(string id)
  {
    var tab = windowState.Get(id);
    var host = tab.Host == "main" ? Root : detached[tab.Host].Root;
    var input = new TextBox { Text = tab.Title, MaxLength = 40 };
    var dialog = new ContentDialog { XamlRoot = host.XamlRoot, RequestedTheme = host.ActualTheme, Title = "Rename session", Content = input, PrimaryButtonText = "Rename", CloseButtonText = "Cancel" };
    if (await ShowShellDialogAsync(dialog) == ContentDialogResult.Primary) await SaveWindowTitleAsync(tab, input.Text);
  }
  private void PopSession(string id)
  {
    var owner = windowState.OwnerOf(id); var tabs = windowState.Tabs.Where(t => t.Owner == owner && t.Host == "main").ToArray();
    if (tabs.Length == 0) { if (windowState.Tabs.FirstOrDefault(t => t.Owner == owner && detached.ContainsKey(t.Host)) is { } open) ActivateWindow(detached[open.Host].Window); return; }
    var child = NewDetached(owner, "session:" + owner);
    try { windowState.TransferSession(owner, "main", child.Host); ActivateWindow(child.Window); }
    catch { detached.Remove(child.Host); child.Surface.ReleaseViews(); child.Window.Close(); throw; }
  }
  private void PopTab(string id)
  {
    var tab = windowState.Get(id);
    if (tab.Host != "main") { ActivateWindow(detached[tab.Host].Window); return; }
    var child = NewDetached(tab.Owner, tab.Id);
    try { windowState.Transfer(id, child.Host); ActivateWindow(child.Window); }
    catch { detached.Remove(child.Host); child.Surface.ReleaseViews(); child.Window.Close(); throw; }
  }
  private DetachedWorkspace NewDetached(string owner, string geometryId)
  {
    var host = Guid.NewGuid().ToString("N"); var surface = MakeSurface(host);
    var window = new Window { Title = TerminalDeck.Core.Brand.Name };
    var root = new Grid { RequestedTheme = Root.RequestedTheme };
    root.SetResourceReference(Grid.BackgroundProperty, "DeckCanvasBrush");
    root.RowDefinitions.Add(new() { Height = new(40) }); root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var header = new Grid { ColumnSpacing = 4 }; header.SetResourceReference(Grid.BackgroundProperty, "DeckTopBarBrush");
    header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new() { Width = new(48) }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    header.Children.Add(surface.Header);
    var drag = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) }; Grid.SetColumn(drag, 1); header.Children.Add(drag);
    var backLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
    backLabel.Children.Add(new DeckIcon { Glyph = "\uE72B", FontSize = 13 }); backLabel.Children.Add(new TextBlock { Text = "Move back", FontSize = 12 });
    var back = new Button { Content = backLabel, MinHeight = 28, Height = 32, Padding = new(8, 4, 8, 4), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(back, "Move back to main window"); ToolTipService.SetToolTip(back, "Move back to main window");
    back.Click += (_, _) => DockHost(host); Grid.SetColumn(back, 2); header.Children.Add(back);
    var caption = new Grid { Width = 138 }; Grid.SetColumn(caption, 3); header.Children.Add(caption);
    root.Children.Add(header); Grid.SetRow(surface, 1); root.Children.Add(surface); window.Content = root;
    RememberWindow(window, geometryId, 1000, 720);
    _ = new WorkspaceTitleBar(window, root, header, caption);
    var child = new DetachedWorkspace(host, owner, window, root, surface); detached.Add(host, child);
    InitializeShellCommands(root, host);
    FocusInputOnActivation(window, root, host);
    window.Closed += async (_, _) =>
    {
      surface.ReleaseViews(); detached.Remove(host);
      if (!closingShell)
      {
        foreach (var tab in windowState.Tabs.Where(t => t.Host == host).ToArray())
        {
          if (tab.Kind is not ("page" or "browser")) hiddenTabs.Add(tab.Id);
          // Closing an app window closes its views. Keeper processes and browser
          // records remain available through their explicit history/list routes.
          if (tab.Kind == "browser")
          {
            try { await browser.Core.CloseAsync(tab.Subject); browser.ForgetShellView(tab.Subject); }
            catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The browser window could not close completely. Check its window list before retrying."; }
          }
          if (windowState.Tabs.Any(t => t.Id == tab.Id)) windowState.Close(tab.Id);
        }
        RenderWindows();
        if (mainWindowHidden && detached.Count == 0 && settingsWindow is null) { closingShell = true; Close(); }
      }
    };
    if (Environment.GetEnvironmentVariable("TD_W10_PROOF") is not null || W12Proof) window.AppWindow.Move(new Windows.Graphics.PointInt32(-20000, -20000));
    return child;
  }
  private void DockOwner(string owner)
  {
    foreach (var host in windowState.Tabs.Where(t => t.Owner == owner && t.Host != "main").Select(t => t.Host).Distinct().ToArray()) DockHost(host);
  }
  private void DockHost(string host)
  {
    mainWindowHidden = false;
    var owners = windowState.Tabs.Where(t => t.Host == host).Select(t => t.Owner).Distinct().ToArray();
    foreach (var owner in owners) windowState.TransferSession(owner, host, "main");
    if (detached.TryGetValue(host, out var child)) child.Window.Close();
    if (owners.FirstOrDefault() is { } first) { workspaceOwner = first; Model.Page = first == "browser" ? ShellPage.Browser : first == "pages" && windowState.Layout("pages").Active is { } page ? Enum.Parse<ShellPage>(windowState.Get(page).Subject) : ShellPage.Sessions; }
    mainWindowHidden = false; AppWindow.Show(!W12Proof); ActivateWindow(this); RenderWindows();
  }
  private void DockTab(string id)
  {
    mainWindowHidden = false;
    var tab = windowState.Get(id); var old = tab.Host;
    windowState.Transfer(id, "main"); workspaceOwner = tab.Owner; Model.Page = tab.Owner == "browser" ? ShellPage.Browser : ShellPage.Sessions;
    if (tab.Kind == "page") Model.Page = Enum.Parse<ShellPage>(tab.Subject);
    if (old != "main" && detached.TryGetValue(old, out var child))
    {
      if (windowState.Tabs.FirstOrDefault(t => t.Host == old) is { } next)
      { windowState.Select(next.Id); detached[old] = child with { Owner = next.Owner }; }
      else child.Window.Close();
    }
    mainWindowHidden = false; AppWindow.Show(!W12Proof); ActivateWindow(this); RenderWindows();
  }
  private nint ChatWindowHandle(string sessionId)
  {
    var tab = windowState.Tabs.FirstOrDefault(t => t.Subject == sessionId);
    return tab is { Host: not "main" } && detached.TryGetValue(tab.Host, out var child)
      ? WinRT.Interop.WindowNative.GetWindowHandle(child.Window) : WindowHandle;
  }
  private void SidebarToggle_Click(object sender, RoutedEventArgs args)
  { sidebar.Geometry(sidebar.Read.Width, !sidebar.Read.Visible); }
  private void AddShellShortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
  { var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers }; shortcut.Invoked += (_, args) => { if (!ShellModalOpen) action(); args.Handled = true; }; Root.KeyboardAccelerators.Add(shortcut); }
  private void SplitWindows(bool withBrowser)
  {
    if (Scope.Length == 0) return;
    var active = windowState.Layout(Scope).Active;
    var other = windowState.Tabs.FirstOrDefault(t => t.Id != active && t.Host == "main" && (withBrowser ? t.Kind == "browser" : t.Kind != "browser"));
    if (active is not null && other is not null) { windowState.Split(active, other.Id, owner: Scope); Model.Split = withBrowser ? SplitPresentation.Browser : SplitPresentation.Sessions; }
    else Model.Notice = withBrowser ? "Open a browser window first, then add it to the split." : "Open another session window first, then add it to the split.";
  }
  private sealed record DetachedWorkspace(string Host, string Owner, Window Window, Grid Root, WorkspaceSurface Surface);
}
