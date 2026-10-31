using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Storage;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private SidebarState sidebar = null!;
  private Flyout? morePagesFlyout;
  private readonly Dictionary<string, TextBlock> pageCounts = [];
  private readonly Dictionary<string, ToggleButton> pageNavigation = [];
  private readonly Dictionary<string, Button> pageCountButtons = [];
  private readonly Dictionary<ShellPage, SettingsPane> connectionPages = [];
  private void InitializeSidebar(AppDataRoot root, bool upgrading)
  {
    var store = new JsonStateStore<SidebarSaved>(root, "sidebar");
    SidebarSaved? saved = null;
    try { saved = store.Load(); }
    catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
    { Model.Notice = "Sidebar choices could not be read. Your sessions are still available."; }
    // An existing state file is evidence of use. Directory creation is not.
    upgrading |= new[] { "projects", "appearance" }.Any(name => File.Exists(Path.Combine(root.DirectoryPath, "state", name + ".json")));
    try { sidebar = new(saved, upgrading, store.Save); }
    catch (ArgumentException) { sidebar = new(null, upgrading, store.Save); Model.Notice = "The saved sidebar was invalid. Your sessions are still available; choose your pins again in More."; }
    sidebar.Changed += () => { RenderSidebarPages(); UpdateSidebarSessions(); ApplySidebarGeometry(); };
    RenderSidebarPages(); ApplySidebarGeometry();
    var resize = new Thumb { Width = 6, MinWidth = 0, MinHeight = 0, HorizontalAlignment = HorizontalAlignment.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), IsTabStop = false, UseSystemFocusVisuals = false, Opacity = 0 };
    AutomationProperties.SetName(resize, "Resize sidebar");
    Grid.SetRow(resize, 1); Root.Children.Add(resize);
    var width = sidebar.Read.Width;
    resize.DragStarted += (_, _) => width = sidebar.Read.Width;
    resize.DragDelta += (_, args) => { width = Math.Clamp(width + args.HorizontalChange, 240, 340); SidebarColumn.Width = TitleSidebarColumn.Width = new(width); };
    resize.DragCompleted += (_, _) => SidebarGuard(() => sidebar.Geometry(width, sidebar.Read.Visible));
    resize.DoubleTapped += (_, _) => SidebarGuard(() => sidebar.Geometry(264, true));
    resize.KeyDown += (_, args) =>
    {
      if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Home or VirtualKey.End)
      {
        SidebarGuard(() => sidebar.Geometry(args.Key == VirtualKey.Home ? 240 : args.Key == VirtualKey.End ? 340 : sidebar.Read.Width + (args.Key == VirtualKey.Left ? -8 : 8), sidebar.Read.Visible)); args.Handled = true;
      }
    };
    SidebarPanel.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => resize.Visibility = SidebarPanel.Visibility);
    resize.Visibility = SidebarPanel.Visibility;
    AddShellShortcut(VirtualKey.Up, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => StepSidebar(-1));
    AddShellShortcut(VirtualKey.Down, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => StepSidebar(1));
  }
  private void SidebarGuard(Action action)
  { try { action(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { Model.Notice = "Sidebar changes could not be saved. Please try again."; } }
  private void ApplySidebarGeometry()
  {
    sidebarVisible = sidebar.Read.Visible;
    SidebarPanel.Visibility = sidebarVisible ? Visibility.Visible : Visibility.Collapsed;
    SidebarColumn.Width = new(sidebarVisible ? sidebar.Read.Width : 0);
    TitleSidebarColumn.Width = new(sidebarVisible ? sidebar.Read.Width : 48);
    SidebarToggle.IsEnabled = true;
  }
  private void RenderSidebarPages()
  {
    PinnedPageRows.Children.Clear(); pageCounts.Clear(); pageNavigation.Clear(); pageCountButtons.Clear();
    ProjectsSection.Visibility = sidebar.Pinned("Projects") ? Visibility.Visible : Visibility.Collapsed;
    foreach (var id in sidebar.Read.Pages.Where(p => p is not ("Projects" or "Devices")))
    {
      var page = SidebarState.Catalogue.Single(p => p.Id == id);
      var row = new Grid { ColumnSpacing = 8 };
      row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      row.Children.Add(new DeckIcon { Glyph = page.Glyph, FontSize = 16 });
      var text = new TextBlock { Text = page.Title, TextTrimming = TextTrimming.CharacterEllipsis }; Grid.SetColumn(text, 1); row.Children.Add(text);
      var count = new TextBlock { FontSize = 12, Opacity = 0.65 }; pageCounts[id] = count;
      var button = new ToggleButton { Tag = id, Content = row, Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"], HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, CanDrag = true, AllowDrop = true };
      AutomationProperties.SetName(button, page.Title); button.Click += (_, _) => OpenSidebarPage(id);
      var menu = new MenuFlyout(); var unpin = new MenuFlyoutItem { Text = "Unpin from side panel" }; unpin.Click += (_, _) => SidebarGuard(() => sidebar.Pin(id, false)); menu.Items.Add(unpin);
      var up = new MenuFlyoutItem { Text = "Move up" }; up.Click += (_, _) => MovePinnedPage(id, -1); menu.Items.Add(up);
      var down = new MenuFlyoutItem { Text = "Move down" }; down.Click += (_, _) => MovePinnedPage(id, 1); menu.Items.Add(down);
      var tab = new MenuFlyoutItem { Text = "Move page to tab" }; tab.Click += (_, _) => OpenPageTab(id); menu.Items.Add(tab);
      var window = new MenuFlyoutItem { Text = "Move page to window" }; window.Click += (_, _) => { OpenPageTab(id); PopTab("page:" + id); }; menu.Items.Add(window); button.ContextFlyout = menu;
      button.DragStarting += (_, args) => { args.Data.Properties["deck-sidebar-page"] = id; args.Data.SetText("deck-page:" + id); args.Data.RequestedOperation = DataPackageOperation.Move; };
      button.DragOver += (_, args) => { if (args.DataView.Properties.ContainsKey("deck-sidebar-page")) args.AcceptedOperation = DataPackageOperation.Move; };
      button.Drop += async (_, args) =>
      {
        var deferred = args.GetDeferral();
        try { var value = await args.DataView.GetTextAsync(); if (value.StartsWith("deck-page:", StringComparison.Ordinal)) SidebarGuard(() => sidebar.MovePage(value[10..], id)); }
        finally { deferred.Complete(); }
      };
      pageNavigation[id] = button;
      var wrapper = new Grid(); wrapper.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); wrapper.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      wrapper.Children.Add(button);
      var badge = new Button { Content = count, Padding = new(0, 0, 8, 0), Width = 32, MinWidth = 32, MinHeight = 24, Height = 26, HorizontalContentAlignment = HorizontalAlignment.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Visibility = Visibility.Collapsed };
      AutomationProperties.SetName(badge, "Show " + page.Title + " count"); badge.Click += (_, _) => ShowPageCount(id, badge); Grid.SetColumn(badge, 1); wrapper.Children.Add(badge); pageCountButtons[id] = badge;
      PinnedPageRows.Children.Add(wrapper);
    }
    RefreshPageCounts();
  }
  private void MovePinnedPage(string id, int delta)
  {
    var at = Array.IndexOf(sidebar.Read.Pages, id); var next = at + delta;
    if (next >= 0 && next < sidebar.Read.Pages.Length) SidebarGuard(() => sidebar.MovePage(id, sidebar.Read.Pages[next]));
  }
  private int ProjectRunningCount(string id) => SidebarProjectSessions(id).Count(s => !Model.Sessions.Any(row => row.Id == s.Id && IsHistory(row)) && s.Status.ToLowerInvariant() is not ("ended" or "exited") && !sidebar.Read.SessionPins.Contains(s.Id) && !sidebar.Read.HiddenSessions.Contains(s.Id) && !sidebar.IsArchived(s.Id));
  private void InitializeSidebarSessionDrag()
  {
    SessionList.CanDragItems = true; SessionList.CanReorderItems = true; SessionList.AllowDrop = true;
    SessionList.DragItemsCompleted += (_, args) =>
    {
      SidebarGuard(() => sidebar.OrderSessions(sidebarSessions.Select(s => s.Id).ToArray()));
      if (args.DropResult == DataPackageOperation.None && WorkspaceDrag.Outside(this) && args.Items.OfType<SessionDraft>().FirstOrDefault() is { } row) PopSession(row.Id);
    };
  }
  private void ArchivedChats_Click(object sender, RoutedEventArgs args)
  {
    ArchivedChatRows.Visibility = ArchivedChatRows.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    UpdateSidebarSessions();
  }
  private void ArchivedSessionList_SelectionChanged(object sender, SelectionChangedEventArgs args)
  {
    if (!syncingNavigation && ArchivedSessionList.SelectedItem is SessionDraft row) SelectSessionWindow(row);
  }
  private void RefreshPageCounts()
  {
    if (sidebar is null) return;
    if (pageCounts.TryGetValue("Tasks", out var tasks))
    {
      var count = Runtime.Tasks?.List().Count ?? 0; tasks.Text = count > 0 ? count.ToString() : "";
      if (pageCountButtons.TryGetValue("Tasks", out var badge)) { badge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed; AutomationProperties.SetName(badge, "Show " + count + " open tasks"); }
    }
    if (pageCounts.TryGetValue("Agents", out var agents))
    {
      var count = Runtime.Agents.Runs().Count(r => r.State is TerminalDeck.Core.Agents.AgentRunState.Running or TerminalDeck.Core.Agents.AgentRunState.Starting);
      agents.Text = count > 0 ? count.ToString() : "";
      if (pageCountButtons.TryGetValue("Agents", out var badge)) { badge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed; AutomationProperties.SetName(badge, "Show " + count + " active agent runs"); }
    }
  }
  private void ShowProjectSessionsCount(string projectId, FrameworkElement target)
  {
    var menu = new MenuFlyout();
    foreach (var session in SidebarProjectSessions(projectId).Where(s => !Model.Sessions.Any(row => row.Id == s.Id && IsHistory(row)) && s.Status.ToLowerInvariant() is not ("ended" or "exited") && !sidebar.Read.SessionPins.Contains(s.Id) && !sidebar.Read.HiddenSessions.Contains(s.Id) && !sidebar.IsArchived(s.Id)))
    {
      var item = new MenuFlyoutItem { Text = session.Title }; item.Click += (_, _) => OpenSession(session.Id); menu.Items.Add(item);
    }
    if (menu.Items.Count == 0) menu.Items.Add(new MenuFlyoutItem { Text = "No unpinned running sessions", IsEnabled = false });
    menu.ShowAt(target);
  }
  private void ShowPageCount(string id, FrameworkElement target)
  {
    var menu = new MenuFlyout();
    if (id == "Tasks")
      foreach (var task in Runtime.Tasks.List())
      {
        var item = new MenuFlyoutItem { Text = task.Title + " · " + task.Status };
        item.Click += (_, _) => { Model.Page = ShellPage.Tasks; tasksPage?.OpenTask(task.Id); }; menu.Items.Add(item);
      }
    else if (id == "Agents")
      foreach (var run in Runtime.Agents.Runs().Where(r => r.State is TerminalDeck.Core.Agents.AgentRunState.Running or TerminalDeck.Core.Agents.AgentRunState.Starting))
      {
        var item = new MenuFlyoutItem { Text = run.AgentName + " · " + run.Job }; item.Click += (_, _) => OpenSession(run.SessionId); menu.Items.Add(item);
      }
    if (menu.Items.Count == 0) menu.Items.Add(new MenuFlyoutItem { Text = "Nothing pending", IsEnabled = false });
    menu.ShowAt(target);
  }
  private void OpenPageTab(string id)
  {
    if (id == "Devices") { ShowDevicesPopup(); return; }
    if (!Enum.TryParse<ShellPage>(id, out var page)) return;
    windowState.Reveal("page:" + id); windowState.Ensure("page:" + id, "pages", id, "page", SidebarState.Catalogue.FirstOrDefault(p => p.Id == id)?.Title ?? id, explicitPage: true);
    Model.Page = page; windowState.Select("page:" + id); RenderWindows();
  }
  private void OpenSidebarPage(string id)
  {
    morePagesFlyout?.Hide();
    if (id == "Devices") { ShowDevicesPopup(); return; }
    if (Enum.TryParse<ShellPage>(id, out var page)) Model.Page = page;
    SyncNavigation();
  }
  private void MorePages_Click(object sender, RoutedEventArgs args)
  {
    var rows = new StackPanel { Spacing = 2, MinWidth = 248 };
    var opens = new List<Button>();
    foreach (var page in SidebarState.Catalogue)
    {
      var row = new Grid { ColumnSpacing = 8 };
      row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
      label.Children.Add(new DeckIcon { Glyph = page.Glyph, FontSize = 16 }); label.Children.Add(new TextBlock { Text = page.Title });
      var open = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
      AutomationProperties.SetName(open, page.Title); open.Click += (_, _) => OpenSidebarPage(page.Id); row.Children.Add(open); opens.Add(open);
      if (page.Id == "Devices") { rows.Children.Add(row); continue; }
      var pin = new ToggleButton { Content = new DeckIcon { Glyph = "\uE718", FontSize = 14 }, IsChecked = sidebar.Pinned(page.Id), Tag = page.Id, Width = 36, MinWidth = 36, Height = 36, Padding = new(6) };
      void LabelPin() { var pinned = sidebar.Pinned(page.Id); AutomationProperties.SetName(pin, (pinned ? "Unpin " : "Pin ") + page.Title); ToolTipService.SetToolTip(pin, pinned ? "Unpin from side panel" : "Pin to side panel"); }
      LabelPin();
      var updatingPin = false;
      void ApplyPin()
      {
        if (updatingPin) return;
        SidebarGuard(() => sidebar.Pin(page.Id, pin.IsChecked == true)); updatingPin = true;
        try { pin.IsChecked = sidebar.Pinned(page.Id); LabelPin(); } finally { updatingPin = false; }
      }
      pin.Checked += (_, _) => ApplyPin(); pin.Unchecked += (_, _) => ApplyPin();
      Grid.SetColumn(pin, 1); row.Children.Add(pin); rows.Children.Add(row);
      row.KeyDown += (_, key) =>
      {
        if (key.Key is VirtualKey.Up or VirtualKey.Down)
        { var at = opens.IndexOf(open); opens[Math.Clamp(at + (key.Key == VirtualKey.Up ? -1 : 1), 0, opens.Count - 1)].Focus(FocusState.Keyboard); key.Handled = true; }
        else if (key.Key == VirtualKey.Escape) { morePagesFlyout?.Hide(); MorePages.Focus(FocusState.Keyboard); key.Handled = true; }
      };
    }
    var shortcuts = new Button { Content = "Keyboard Shortcuts  ·  Ctrl+/", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
    shortcuts.Click += async (_, _) => { morePagesFlyout?.Hide(); await RunShellCommandGuardedAsync("shortcuts"); };
    rows.Children.Add(shortcuts); opens.Add(shortcuts);
    morePagesFlyout = new Flyout { Content = rows };
    morePagesFlyout.Opened += (_, _) => opens[0].Focus(FocusState.Keyboard);
    if (!W12Proof) morePagesFlyout.ShowAt(MorePages);
  }
  private void StepSidebar(int delta)
  {
    var controls = NavigationRoutes.Children.OfType<Control>().Where(c => c is ButtonBase && !ReferenceEquals(c, MorePages))
      .Concat(sidebar.Read.Pages.Where(pageNavigation.ContainsKey).Select(id => (Control)pageNavigation[id])).Concat(new Control[] { MorePages })
      .Concat(sidebar.Pinned("Projects") ? new[] { ProjectsRoute }.Cast<Control>().Concat(projectNavigation) : [])
      .Concat(SessionList.Items.Cast<SessionDraft>().Select(row => SessionList.ContainerFromItem(row)).OfType<Control>()).Append(SettingsRoute).Append(DevicesButton).Distinct().ToArray();
    var focused = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject;
    while (focused is not null && !controls.Contains(focused)) focused = VisualTreeHelper.GetParent(focused);
    var index = focused is Control current ? Array.IndexOf(controls, current) : -1;
    if (controls.Length > 0) controls[Math.Clamp(index < 0 ? (delta > 0 ? 0 : controls.Length - 1) : index + delta, 0, controls.Length - 1)].Focus(FocusState.Keyboard);
  }
  private FrameworkElement ConnectionPage(ShellPage page)
  {
    if (!connectionPages.TryGetValue(page, out var pane))
    {
      pane = new(Model, Runtime); pane.Children[0].Visibility = Visibility.Collapsed; pane.ColumnDefinitions[0].Width = new(0); pane.ColumnSpacing = 0;
      connectionPages[page] = pane;
    }
    pane.SelectSection(page == ShellPage.Devices ? 2 : 3); return pane;
  }
}
