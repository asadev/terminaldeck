using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Shell;

internal sealed partial class WorkspaceSurface : Grid
{
  public Func<WorkspaceTab, TerminalDeck.App.Views.BrowserShellIdentity?>? BrowserIdentity { get; set; }
  public Func<WorkspaceTab, UIElement?>? ProjectIdentity { get; set; }
  public Func<WorkspaceTab, string?>? AccountBadge { get; set; }
  public Func<WorkspaceTab, FrameworkElement>? UsageReport { get; set; }
  // The header's usage meter (context strip + plan ring, hover cards), first in the controls as on the Mac.
  public Func<WorkspaceTab, FrameworkElement?>? UsageMeter { get; set; }
  public Action<WorkspaceTab>? OpenDevice { get; set; }
  public Func<bool>? IsModalOpen { get; set; }
  public Action<string>? DragOutside { get; set; }
  public Action<string, string>? MergeDrop { get; set; }
  public Action? BeginManualSplit { get; set; }
  public Func<WorkspaceTab, MenuFlyout>? SessionMenu { get; set; }
  public Func<WorkspaceTab, string, Task>? SaveTitle { get; set; }
  private readonly WorkspaceState state;
  private readonly Func<WorkspaceTab, FrameworkElement> view;
  private readonly Action<string, string> focus;
  private readonly Func<string, Task> close;
  private readonly Func<string, Task> rename;
  private readonly Action<string> pop;
  private readonly Action<string> dock;
  private readonly Action<string> dockOwner;
  private readonly Func<string, string, Task> create;
  private readonly Func<WorkspaceTab, string> accountLabel;
  private readonly Func<WorkspaceTab, string> folder;
  private readonly Func<WorkspaceTab, TerminalDeck.App.ViewModels.SessionDraft?> session;
  private readonly Func<WorkspaceTab, FrameworkElement, Task> account;
  private readonly Func<WorkspaceTab, Task> stop;
  private readonly Dictionary<string, Button> accountButtons = [];
  private readonly Action<string> notice;
  private string owner = "";
  private string? headerActive;
  public string Host { get; }
  public Grid Header { get; } = new() { Height = 40, ColumnSpacing = 2, Margin = new(16, 0, 0, 0) };
  private readonly Grid stripHost = new() { MinWidth = 0 };
  private StackPanel actions = null!;
  private readonly Button previousTabs;
  private readonly Button nextTabs;
  private readonly Grid strip = new() { ColumnSpacing = 0, MinWidth = 0 };
  private readonly ScrollViewer stripViewport = new() { HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, MinWidth = 0, ZoomMode = ZoomMode.Disabled };
  private readonly Grid body = new();
  private readonly Dictionary<string, Border> paneFrames = [];
  private readonly Dictionary<string, Grid> tabFrames = [];
  private readonly Dictionary<string, Button> tabButtons = [];
  private readonly Dictionary<string, TextBlock> tabTitles = [];
  public WorkspaceSurface(WorkspaceState state, string host, Func<WorkspaceTab, FrameworkElement> view,
    Action<string, string> focus, Func<string, Task> close, Func<string, Task> rename,
    Action<string> pop, Action<string> dock, Action<string> dockOwner, Func<string, string, Task> create, Func<WorkspaceTab, string> accountLabel, Func<WorkspaceTab, string> folder, Func<WorkspaceTab, TerminalDeck.App.ViewModels.SessionDraft?> session, Func<WorkspaceTab, FrameworkElement, Task> account, Func<WorkspaceTab, Task> stop, Action<string> notice)
  {
    this.state = state; Host = host; this.view = view; this.focus = focus; this.close = close;
    this.rename = rename; this.pop = pop; this.dock = dock; this.dockOwner = dockOwner; this.create = create; this.accountLabel = accountLabel; this.folder = folder; this.session = session; this.account = account; this.stop = stop; this.notice = notice;
    body.Margin = new(0);
    Children.Add(body);
    // Like Chrome: the new-tab buttons sit right after the last tab and move with
    // the tabs; when the strip is full they stay visible at its end.
    Header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
    stripHost.HorizontalAlignment = HorizontalAlignment.Left;
    stripHost.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    stripHost.ColumnDefinitions.Add(new() { Width = GridLength.Auto, MinWidth = 0 });
    stripHost.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    stripHost.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    previousTabs = IconButton("Scroll tabs left", "\uE76B", () => ScrollTabs(-1));
    nextTabs = IconButton("Scroll tabs right", "\uE76C", () => ScrollTabs(1));
    previousTabs.Width = nextTabs.Width = WorkspaceTabSizing.ArrowWidth;
    previousTabs.MinWidth = nextTabs.MinWidth = 0;
    previousTabs.Visibility = nextTabs.Visibility = Visibility.Collapsed;
    SetColumn(stripViewport, 1); SetColumn(nextTabs, 2);
    stripHost.Children.Add(previousTabs); stripHost.Children.Add(stripViewport); stripHost.Children.Add(nextTabs);
    stripViewport.Content = strip; Header.Children.Add(stripHost);
    Header.SizeChanged += (_, _) => FitTabs();
    stripViewport.ViewChanged += (_, _) => UpdateScrollButtons();
    stripViewport.PointerWheelChanged += (_, args) =>
    {
      if (stripViewport.ScrollableWidth <= 0) return;
      var point = args.GetCurrentPoint(stripViewport);
      stripViewport.ChangeView(stripViewport.HorizontalOffset + (point.Properties.IsHorizontalMouseWheel ? 1 : -1) * point.Properties.MouseWheelDelta, null, null);
      args.Handled = true;
    };
    Header.SizeChanged += (_, _) => Header.Clip = new RectangleGeometry { Rect = new(0, 0, Header.ActualWidth, Header.ActualHeight) };
    actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Margin = new(4, 0, 0, 0) };
    actions.Children.Add(NewWindowButton("New terminal tab", "terminal", () => Guard(() => create(state.CreationOwner(owner, Host), "terminal"))));
    actions.Children.Add(NewWindowButton("New browser tab", "browser", () => Guard(() => create(state.CreationOwner(owner, Host), "browser"))));
    SetColumn(actions, 3); stripHost.Children.Add(actions); actions.SizeChanged += (_, _) => FitTabs();
    AddShortcut(VirtualKey.Tab, VirtualKeyModifiers.Control, () => Step(1));
    AddShortcut(VirtualKey.Tab, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => Step(-1));
    AddShortcut(VirtualKey.Left, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => Step(-1, true));
    AddShortcut(VirtualKey.Right, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => Step(1, true));
    AddShortcut(VirtualKey.W, VirtualKeyModifiers.Control, () => { if (headerActive is { } id) Guard(() => close(id)); });
    for (var i = 0; i < 9; i++)
    {
      var index = i;
      AddShortcut((VirtualKey)((int)VirtualKey.Number1 + i), VirtualKeyModifiers.Control, () =>
      {
        var peers = state.Tabs.Where(t => t.Host == Host).ToArray();
        if (peers.Length > index) Select(peers[index].Id);
      });
    }
  }
  public void ReleaseViews()
  {
    void Release(DependencyObject parent)
    {
      for (var i = VisualTreeHelper.GetChildrenCount(parent) - 1; i >= 0; i--)
      {
        var child = VisualTreeHelper.GetChild(parent, i);
        if (child is ContentControl { Tag: "workspace-view" } holder) holder.Content = null;
        else Release(child);
      }
    }
    Release(body); body.Children.Clear();
  }
  public void Render(string scope)
  {
    owner = scope; paneFrames.Clear(); accountButtons.Clear();
    var layout = state.Layout(owner, Host);
    RenderHeader(layout.ActiveEmpty ?? layout.Active);
    body.Children.Clear();
    if (layout.Root is { } root) body.Children.Add(RenderNode(root, layout));
    else
    {
      var empty = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
      empty.Children.Add(new TextBlock { Text = scope == "swarm" ? "No sessions yet" : "Empty pane", FontSize = 20 });
      empty.Children.Add(new TextBlock { Text = "Nothing here yet. Choose a session or browser tab, or start a new session.", TextWrapping = TextWrapping.Wrap, MaxWidth = 360, Opacity = 0.65 });
      var start = new Button { Content = "New session…" }; start.Click += (_, _) => Guard(() => create(state.CreationOwner(owner, Host), "chat")); empty.Children.Add(start); body.Children.Add(empty);
    }
  }
  public void RenderHeader(string? active)
  {
    headerActive = active;
    strip.Children.Clear(); strip.ColumnDefinitions.Clear(); tabFrames.Clear(); tabTitles.Clear(); tabButtons.Clear();
    foreach (var tab in state.Tabs.Where(t => t.Host == Host))
    {
      strip.ColumnDefinitions.Add(new() { Width = new(WorkspaceTabSizing.Minimum), MinWidth = WorkspaceTabSizing.Minimum });
      var chip = new Grid { CornerRadius = new(6, 6, 0, 0), Margin = new(0, 5, 0, 0), Height = 35, VerticalAlignment = VerticalAlignment.Bottom, MinWidth = 0 };
      SetColumn(chip, strip.ColumnDefinitions.Count - 1);
      chip.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); chip.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      chip.SetResourceReference(BackgroundProperty, "DeckTransparentBrush");
      // The flared bottom shares the opaque page fill and reaches its top edge.
      var selected = headerActive == tab.Id;
      var flare = (double)Application.Current.Resources["DeckTabFlare"];
      var shape = new Microsoft.UI.Xaml.Shapes.Path { Tag = "selected-tab", Margin = new(-flare, 0, -flare, 0), IsHitTestVisible = false, Visibility = selected ? Visibility.Visible : Visibility.Collapsed };
      shape.SetResourceReference(Microsoft.UI.Xaml.Shapes.Shape.FillProperty, "DeckCanvasBrush");
      SetColumnSpan(shape, 2); chip.Children.Add(shape);
      void Shape() => shape.Data = WorkspaceTabShape.Outline(chip.ActualWidth, chip.Height, (double)Application.Current.Resources["DeckTabCorner"], flare);
      chip.SizeChanged += (_, _) => Shape();
      chip.PointerEntered += (_, _) => { if (!selected) chip.Background = (Brush)ShellTheme.Resource(chip, "DeckHoverBrush"); };
      chip.PointerExited += (_, _) => chip.Background = (Brush)ShellTheme.Resource(chip, "DeckTransparentBrush");
      var divider = new Border { Width = 1, Height = 14, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
      divider.Visibility = selected ? Visibility.Collapsed : Visibility.Visible;
      divider.SetResourceReference(Border.BackgroundProperty, "DeckTabDividerBrush"); SetColumnSpan(divider, 2); chip.Children.Add(divider);
      var label = new Grid { ColumnSpacing = 6, HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 0 };
      if (tab.Subject == "Hoot" && tab.Kind == "page") label.Children.Add(new Image { Width = 14, Height = 14, Source = new Microsoft.UI.Xaml.Media.Imaging.SvgImageSource(new Uri("ms-appx:///Assets/icons/hoot.svg")) });
      else if (tab.Kind == "browser" && BrowserIdentity?.Invoke(tab) is { } browser)
      {
        if (browser.Favicon is { } favicon) label.Children.Add(new Image { Width = 14, Height = 14, Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(favicon)) });
        else label.Children.Add(new TerminalDeck.App.Views.DeckIcon { Glyph = WorkspaceIcons.For("browser"), FontSize = 13 });
        if (browser.Loading) label.Children.Add(new ProgressRing { Width = 12, Height = 12, MinWidth = 0, MinHeight = 0, IsActive = true });
      }
      else if (session(tab) is { } row)
      {
        if (ProjectIdentity?.Invoke(tab) is { } project) label.Children.Add(project);
        label.Children.Add(new TerminalDeck.App.Views.BrandIcon { Kind = row.Provider, Width = 14, Height = 14 });
      }
      else label.Children.Add(new TerminalDeck.App.Views.DeckIcon { Glyph = WorkspaceIcons.For(tab.Kind == "page" ? tab.Subject : tab.Kind), FontSize = 13 });
      var title = new TextBlock { Text = tab.Title, FontWeight = active == tab.Id ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal, FontSize = 12, LineHeight = 13, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center }; label.Children.Add(title); tabTitles[tab.Id] = title;
      Border? accountBadge = null;
      if (AccountBadge?.Invoke(tab) is { Length: > 0 } accountName)
      {
        var initials = string.Concat(accountName.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(word => System.Globalization.StringInfo.GetNextTextElement(word)).Take(3));
        var badgeText = new TextBlock { Text = accountName.Length <= 4 ? accountName : initials, FontSize = 9, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 24 };
        badgeText.SetResourceReference(TextBlock.ForegroundProperty, "DeckBadgeInkBrush");
        accountBadge = new Border { Child = badgeText, Width = 30, CornerRadius = new(3), Padding = new(3, 1, 3, 1), VerticalAlignment = VerticalAlignment.Center };
        accountBadge.SetResourceReference(Border.BackgroundProperty, "DeckAccountBadgeBrush");
        ToolTipService.SetToolTip(accountBadge, accountName); AutomationProperties.SetName(accountBadge, "Account: " + accountName); label.Children.Add(accountBadge);
      }
      // A star column gives the title a finite measure, so ellipsis happens
      // inside the tab rather than letting a horizontal StackPanel spill out.
      foreach (var child in label.Children.OfType<FrameworkElement>())
      {
        SetColumn(child, label.ColumnDefinitions.Count);
        label.ColumnDefinitions.Add(new() { Width = ReferenceEquals(child, title) ? new(1, GridUnitType.Star) : GridLength.Auto });
      }
      var select = new Button { Style = (Style)Application.Current.Resources["DeckTabButtonStyle"], Content = label, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new(0), Padding = new(8, 4, 4, 4), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, MinWidth = 0, MinHeight = 0, Height = 35 };
      void TabInk() => select.Foreground = (Brush)ShellTheme.Resource(select, headerActive == tab.Id ? "DeckInkBrush" : "DeckSecondaryInkBrush");
      TabInk(); select.ActualThemeChanged += (_, _) => TabInk();
      ToolTipService.SetToolTip(select, tab.Title + " · " + tab.Kind + (BrowserIdentity?.Invoke(tab) is { } identity ? "\n" + identity.Address + "\n" + identity.Status : "")); AutomationProperties.SetName(select, TabAccessibility(tab)); tabButtons[tab.Id] = select; AutomationProperties.SetHelpText(select, tab.Kind + " window. Right-click for split, rename and move actions.");
      select.SizeChanged += (_, _) => select.Clip = new RectangleGeometry { Rect = new(0, 0, Math.Max(0, select.ActualWidth), select.ActualHeight) };
      select.Click += (_, _) => Select(tab.Id);
      chip.Children.Add(select);
      // Like Chrome: the selected tab always shows its ×, at every width; other tabs
      // show it on hover (or focus). Middle-click closes any tab.
      var closable = tab.Id != "page:Hoot"; var hovering = false; var narrow = false;
      var x = IconButton("Close " + tab.Title, "\uE711", () => Guard(() => close(tab.Id))); x.Width = 24; x.MinWidth = 24; x.Height = 24; x.MinHeight = 0; x.Padding = new(4); x.Opacity = selected ? 1 : 0;
      void CloseButton()
      {
        x.Visibility = closable && (selected || hovering || !narrow) ? Visibility.Visible : Visibility.Collapsed;
        x.Opacity = selected || hovering ? 1 : 0;
      }
      chip.PointerEntered += (_, _) => { hovering = true; CloseButton(); }; chip.PointerExited += (_, _) => { hovering = false; CloseButton(); };
      chip.GotFocus += (_, _) => { hovering = true; CloseButton(); }; chip.LostFocus += (_, _) => { hovering = false; CloseButton(); }; SetColumn(x, 1); chip.Children.Add(x);
      chip.AddHandler(PointerPressedEvent, new PointerEventHandler((_, e) =>
      {
        if (closable && e.GetCurrentPoint(chip).Properties.IsMiddleButtonPressed) { e.Handled = true; Guard(() => close(tab.Id)); }
      }), true);
      chip.Loaded += (_, _) => { if (headerActive == tab.Id) RevealActiveTab(); };
      chip.SizeChanged += (_, _) =>
      {
        var detail = WorkspaceTabSizing.ForWidth(chip.ActualWidth);
        narrow = !detail.Close; CloseButton();
        title.Visibility = detail.Title ? Visibility.Visible : Visibility.Collapsed;
        var icons = label.Children.OfType<FrameworkElement>().Where(element => !ReferenceEquals(element, title) && !ReferenceEquals(element, accountBadge)).ToArray();
        // Keep one identity at the icon-only floor. Project/account decoration
        // yields first, and every tab stays the same width.
        for (var i = 0; i < icons.Length; i++) icons[i].Visibility = detail.ProjectPicture || i == icons.Length - 1 ? Visibility.Visible : Visibility.Collapsed;
        if (selected && closable && chip.ActualWidth < WorkspaceTabSizing.Minimum + 24) foreach (var icon in icons) icon.Visibility = Visibility.Collapsed; // too small for icon + ×
        if (accountBadge is not null) accountBadge.Visibility = chip.ActualWidth >= 176 ? Visibility.Visible : Visibility.Collapsed;
        label.ColumnSpacing = detail.Title ? 6 : 0;
        label.HorizontalAlignment = detail.Title ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
        title.MaxWidth = double.PositiveInfinity;
      };
      var menu = new MenuFlyout();
      if (tab.Kind != "page") Add(menu, "Rename…", () => Guard(() => rename(tab.Id)));
      var currentLayout = state.Layout(owner, Host);
      if (tab.Kind != "page" && currentLayout.ActiveEmpty is null && currentLayout.Active is { } current && state.Tabs.Any(candidate => candidate.Id == current && candidate.Kind != "page") && current != tab.Id && !(currentLayout.Root?.Tabs.Contains(tab.Id) ?? false))
      {
        Add(menu, "Open in Split View", () => Split(tab.Id, false));
        Add(menu, "Open below active pane", () => Split(tab.Id, true));
      }
      Add(menu, "Move left", () => state.Move(tab.Id, Index(tab) - 1));
      Add(menu, "Move right", () => state.Move(tab.Id, Index(tab) + 1));
      Add(menu, Host == "main" ? "Open in New Window" : "Move back to main window", () => { if (Host == "main") pop(tab.Id); else dock(tab.Id); });
      if (closable) Add(menu, "Close Tab", () => Guard(() => close(tab.Id)));
      CloseButton();
      select.ContextFlyout = menu;
      select.CanDrag = true; select.AllowDrop = true;
      select.DragStarting += (_, args) => { args.Data.Properties["deck-workspace"] = tab.Id; args.Data.SetText("deck-window:" + tab.Id); args.Data.RequestedOperation = DataPackageOperation.Move; };
      select.DropCompleted += (_, args) => { if (args.DropResult == DataPackageOperation.None) DragOutside?.Invoke(tab.Id); };
      select.DragOver += (_, args) => { if (args.DataView.Properties.ContainsKey("deck-workspace")) args.AcceptedOperation = DataPackageOperation.Move; };
      select.Drop += async (_, args) =>
      {
        var deferral = args.GetDeferral();
        try { var text = await args.DataView.GetTextAsync(); if (text.StartsWith("deck-window:", StringComparison.Ordinal)) { var source = text[12..]; if (state.Get(source).Host != Host) MergeDrop?.Invoke(source, tab.Id); else state.Move(source, Index(tab)); } }
        catch (Exception ex) when (ex is not OutOfMemoryException) { notice("This tab could not move."); }
        finally { deferral.Complete(); }
      };
      if (session(tab) is { } unreadSession)
      {
        var unread = new TerminalDeck.App.Views.SessionStatusMark { OnlyUnread = true, Width = 7, Height = 7, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new(0, 2, 3, 0), IsHitTestVisible = false };
        unread.SetBinding(TerminalDeck.App.Views.SessionStatusMark.UnreadProperty, new Microsoft.UI.Xaml.Data.Binding { Source = unreadSession, Path = new PropertyPath("Unread") });
        SetColumnSpan(unread, 2); chip.Children.Add(unread);
      }
      tabFrames[tab.Id] = chip; strip.Children.Add(chip);
    }
    FitTabs(); RevealActiveTab();
  }
  private void FitTabs()
  {
    var count = strip.ColumnDefinitions.Count;
    // Room for tabs = the header minus the new-tab buttons that follow them.
    var buttons = actions.ActualWidth > 0 ? actions.ActualWidth + actions.Margin.Left : 64;
    var available = Math.Max(0, Header.ActualWidth - buttons);
    var overflow = WorkspaceTabSizing.Overflows(count, available);
    previousTabs.Visibility = nextTabs.Visibility = overflow ? Visibility.Visible : Visibility.Collapsed;
    var viewport = WorkspaceTabSizing.Viewport(count, available);
    var width = WorkspaceTabSizing.Width(count, viewport);
    foreach (var column in strip.ColumnDefinitions) column.Width = new(width);
    stripViewport.Width = Math.Min(count * width, viewport);
    if (!overflow) stripViewport.ChangeView(0, null, null, true);
    else DispatcherQueue.TryEnqueue(RevealActiveTab); // after a resize the selected tab (and its ×) scrolls back into view
    UpdateScrollButtons();
  }
  private void ScrollTabs(int direction) => stripViewport.ChangeView(stripViewport.HorizontalOffset + direction * Math.Max(WorkspaceTabSizing.Minimum, stripViewport.ViewportWidth * 0.7), null, null, true);
  private void UpdateScrollButtons()
  {
    previousTabs.IsEnabled = stripViewport.HorizontalOffset > 0.5;
    nextTabs.IsEnabled = stripViewport.HorizontalOffset < stripViewport.ScrollableWidth - 0.5;
  }
  private void RevealActiveTab()
  {
    if (headerActive is not { } id || !tabFrames.TryGetValue(id, out var chip)) return;
    chip.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
  }
  private FrameworkElement RenderNode(PaneTree node, WorkspaceLayout layout)
  {
    if (node.EmptyId is { } emptyId)
    {
      var empty = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 320 };
      empty.Children.Add(new TextBlock { Text = "Empty pane", FontSize = 20 });
      empty.Children.Add(new TextBlock { Text = "Nothing here yet. Choose a session or browser for this pane.", TextWrapping = TextWrapping.Wrap, Opacity = 0.65 });
      var choose = new Button { Content = "Choose session or browser", HorizontalAlignment = HorizontalAlignment.Stretch };
      var choices = new MenuFlyout();
      foreach (var tab in state.Tabs.Where(t => t.Host == Host && t.Kind != "page")) Add(choices, tab.Title, () => { state.FillEmpty(owner, Host, emptyId, tab.Id); focus(owner, tab.Id); FocusPane(tab.Id); });
      choose.Flyout = choices; empty.Children.Add(choose);
      var closePane = new Button { Content = "Close this pane" }; closePane.Click += (_, _) => ClosePaneView(emptyId); empty.Children.Add(closePane);
      var frame = new Border { Child = empty, CornerRadius = new(0), Padding = new(12), BorderThickness = new(1) };
      frame.SetResourceReference(Border.BackgroundProperty, "DeckCanvasBrush"); frame.SetResourceReference(Border.BorderBrushProperty, layout.ActiveEmpty == emptyId ? "AccentFillColorDefaultBrush" : "DeckDividerBrush");
      frame.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => { state.FocusEmpty(owner, Host, emptyId); FocusPane(emptyId); }), true);
      frame.GotFocus += (_, _) => state.FocusEmpty(owner, Host, emptyId);
      paneFrames[emptyId] = frame; // Only the outer workspace clips a corner; pane frames meet each other and the window.
      RoundedContentClip.Attach(frame, radius: 0); return frame;
    }
    if (node.Tab is { } id)
    {
      var tab = state.Get(id);
      if (tab.Host != Host)
      {
        var placeholder = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 320 };
        placeholder.Children.Add(new TextBlock { Text = tab.Title, FontSize = 16, TextTrimming = TextTrimming.CharacterEllipsis });
        placeholder.Children.Add(new TextBlock { Text = "Open in its own window", Opacity = 0.65 });
        var show = new Button { Content = "Show window" }; show.Click += (_, _) => pop(tab.Id); placeholder.Children.Add(show);
        var bring = new Button { Content = "Move back here" }; bring.Click += (_, _) => dock(tab.Id); placeholder.Children.Add(bring);
        var remove = new Button { Content = "Close this pane" }; remove.Click += (_, _) => ClosePaneView(tab.Id); placeholder.Children.Add(remove);
        return placeholder;
      }
      if (tab.Kind == "page") return new ContentControl { Tag = "workspace-view", Content = view(tab), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
      var pane = new Grid { RowSpacing = 0 };
      pane.RowDefinitions.Add(new() { Height = GridLength.Auto }); pane.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
      var splitPane = layout.Root?.Tab is null;
      if (splitPane || tab.Kind != "browser")
      {
        var bar = new Grid { MinHeight = splitPane ? 34 : 48, Padding = splitPane ? new(10, 0, 10, 0) : new(16, 6, 16, 6), ColumnSpacing = 8 };
        bar.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");
        bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var identity = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        var title = new TextBlock { Text = tab.Title, FontSize = splitPane ? 13 : 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var titleHost = new ContentControl { Content = title, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void EditTitle()
        {
          var saveTitle = SaveTitle;
          if (saveTitle is null) return;
          var input = new TextBox { Text = tab.Title, MaxLength = 40, MinHeight = 24, MinWidth = 120, MaxWidth = 280, HorizontalAlignment = HorizontalAlignment.Left, Padding = new(3, 0, 3, 0) };
          titleHost.Content = input;
          var finished = false;
          async Task Finish(bool save)
          {
            if (finished) return;
            finished = true;
            try
            {
              if (save) { await saveTitle(tab, input.Text); title.Text = input.Text.Trim(); }
              titleHost.Content = title;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            { finished = false; notice(ex is ArgumentException or InvalidOperationException ? ex.Message : "The title could not be saved."); }
          }
          input.KeyDown += async (_, key) =>
          {
            if (key.Key is VirtualKey.Escape or VirtualKey.Enter)
            { key.Handled = true; await Finish(key.Key == VirtualKey.Enter); }
          };
          input.LostFocus += async (_, _) => await Finish(true);
          input.Loaded += (_, _) => { input.Focus(FocusState.Keyboard); input.SelectAll(); };
        }
        title.DoubleTapped += (_, args) => { args.Handled = true; EditTitle(); };
        AutomationProperties.SetName(titleHost, "Session title: " + tab.Title);
        AutomationProperties.SetHelpText(titleHost, "Double-click or use Rename in Session actions. F2 also renames the selected session.");
        title.SetResourceReference(TextBlock.ForegroundProperty, "DeckInkBrush");
        identity.Children.Add(titleHost);
        void ShowInfo(FrameworkElement anchor)
        {
          var info = new StackPanel { Spacing = 8, MaxWidth = 400 };
          info.Children.Add(new TextBlock { Text = "Project folder", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
          info.Children.Add(new TextBlock { Text = folder(tab), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
          if (!string.IsNullOrEmpty(accountLabel(tab))) info.Children.Add(new TextBlock { Text = "Account: " + accountLabel(tab), TextWrapping = TextWrapping.Wrap });
          if (UsageReport is { } readUsage) info.Children.Add(readUsage(tab));
          new Flyout { Content = info }.ShowAt(anchor);
        }
        bar.CanDrag = true; bar.AllowDrop = true;
        bar.DragStarting += (_, args) => { args.Data.Properties["deck-workspace"] = tab.Id; args.Data.SetText("deck-pane:" + tab.Id); args.Data.RequestedOperation = DataPackageOperation.Move; };
        bar.DropCompleted += (_, args) => { if (args.DropResult == DataPackageOperation.None) DragOutside?.Invoke(tab.Id); };
        var preview = new Border { CornerRadius = new(12), Opacity = 0.85, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        preview.SetResourceReference(Border.BackgroundProperty, "DeckSelectionBrush");
        var previewText = new TextBlock { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 14 };
        preview.Child = previewText; SetRowSpan(preview, 2); Canvas.SetZIndex(preview, 100);
        string Edge(DragEventArgs args)
        {
          var point = args.GetPosition(pane);
          if (point.X < pane.ActualWidth / 3) return "left";
          if (point.X > pane.ActualWidth * 2 / 3) return "right";
          if (point.Y < pane.ActualHeight / 3) return "above";
          if (point.Y > pane.ActualHeight * 2 / 3) return "below";
          return "swap";
        }
        pane.AllowDrop = true;
        pane.DragOver += (_, args) =>
        {
          if (!args.DataView.Properties.ContainsKey("deck-workspace")) return;
          args.AcceptedOperation = DataPackageOperation.Move;
          var edge = Edge(args); previewText.Text = edge == "swap" ? "Swap panes" : "Move " + edge;
          preview.Width = edge is "left" or "right" ? pane.ActualWidth / 2 : double.NaN;
          preview.Height = edge is "above" or "below" ? pane.ActualHeight / 2 : double.NaN;
          preview.HorizontalAlignment = edge == "left" ? HorizontalAlignment.Left : edge == "right" ? HorizontalAlignment.Right : HorizontalAlignment.Stretch;
          preview.VerticalAlignment = edge == "above" ? VerticalAlignment.Top : edge == "below" ? VerticalAlignment.Bottom : VerticalAlignment.Stretch;
          preview.Visibility = Visibility.Visible; args.Handled = true;
        };
        pane.DragLeave += (_, _) => preview.Visibility = Visibility.Collapsed;
        pane.Drop += async (_, args) =>
        {
          if (!args.DataView.Properties.ContainsKey("deck-workspace")) return;
          var defer = args.GetDeferral(); var layoutOwner = owner; var edge = Edge(args); preview.Visibility = Visibility.Collapsed; args.Handled = true;
          try
          {
            var value = await args.DataView.GetTextAsync();
            var source = value.StartsWith("deck-pane:", StringComparison.Ordinal) ? value[10..] : value.StartsWith("deck-window:", StringComparison.Ordinal) ? value[12..] : null;
            if (source is null || source == tab.Id || state.Get(source).Kind == "page") return;
            if (state.Get(source).Host != Host) MergeDrop?.Invoke(source, tab.Id);
            if (state.Layout(layoutOwner, Host).Root?.Tabs.Contains(source) != true) state.Split(tab.Id, source, edge is "above" or "below", layoutOwner, Host);
            state.MovePane(layoutOwner, Host, source, tab.Id, edge); focus(layoutOwner, source);
          }
          catch (Exception ex) when (ex is not OutOfMemoryException) { notice("These panes could not move. Try again."); }
          finally { defer.Complete(); }
        };
        pane.Children.Add(preview);
        bar.Children.Add(identity);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var location = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        identity.SizeChanged += (_, _) => identity.Clip = new RectangleGeometry { Rect = new(0, 0, identity.ActualWidth, identity.ActualHeight) };
        Button? folderChip = null;
        var folderName = folder(tab);
        if (!string.IsNullOrWhiteSpace(folderName))
        {
          folderChip = new Button { Content = new TextBlock { Text = folderName.TrimEnd('\\', '/').Split('\\', '/').LastOrDefault(), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 }, Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"], FontSize = 11, MinHeight = 20, Height = 20, Width = double.NaN, MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Left, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new(0) };
          folderChip.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
          ToolTipService.SetToolTip(folderChip, folderName); AutomationProperties.SetName(folderChip, "Project folder: " + folderName);
          folderChip.Click += (_, _) => ShowInfo(folderChip); location.Children.Add(folderChip);
          identity.SizeChanged += (_, _) => folderChip.MaxWidth = Math.Max(24, Math.Min(180, identity.ActualWidth));
        }
        identity.Children.Add(location);
        if (tab.Kind != "browser")
        {
          var accountName = accountLabel(tab);
          var chip = new Button { Content = accountName, FontSize = 11, MaxWidth = 150, MinWidth = 0, Height = 24, MinHeight = 24, Padding = new(6, 0, 6, 0) };
          ToolTipService.SetToolTip(chip, accountName); AutomationProperties.SetName(chip, "Account for " + tab.Title + ": " + accountName);
          chip.Click += (_, _) => Guard(() => account(tab, chip));
          // Mac uses no account chip when no AI/default run command is available.
          chip.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
          chip.Width = double.NaN; chip.HorizontalAlignment = HorizontalAlignment.Left;
          chip.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
          accountButtons[tab.Id] = chip;
          if (!string.IsNullOrEmpty(accountName))
          {
            if (location.Children.Count > 0)
            {
              location.Children.Add(new TextBlock { Text = "·", VerticalAlignment = VerticalAlignment.Center });
            }
            location.Children.Add(chip);
          }
          if (UsageMeter?.Invoke(tab) is { } meter) controls.Children.Add(meter);
          identity.SizeChanged += (_, _) =>
          {
            chip.MaxWidth = Math.Max(24, Math.Min(150, identity.ActualWidth * 0.45));
            if (folderChip is not null && !string.IsNullOrEmpty(accountName)) folderChip.MaxWidth = Math.Max(24, Math.Min(180, identity.ActualWidth - chip.MaxWidth - 15));
          };

        }
        var actions = IconButton(tab.Kind == "browser" ? "Pane actions" : "Session actions", "\uE712", () => { });
        controls.Children.Add(actions);
        if (OpenDevice is { } openDevice) controls.Children.Add(IconButton("Session devices", "\uE8EA", () => openDevice(tab)));
        var splitChoice = IconButton("Split view", "\uE89F", () => { });
        var splitMenu = new MenuFlyout();
        foreach (var other in state.Tabs.Where(t => t.Id != tab.Id && t.Kind != "page" && t.Host == Host))
        {
          var beside = new MenuFlyoutItem { Text = "Beside " + other.Title };
          beside.Click += (_, _) => { BeginManualSplit?.Invoke(); state.Split(tab.Id, other.Id, owner: owner, host: Host); focus(owner, other.Id); FocusPane(other.Id); }; splitMenu.Items.Add(beside);
        }
        Add(splitMenu, "Empty pane beside", () => ChangeManualLayout(() => state.EmptySplit(tab.Id, owner: owner, host: Host)));
        Add(splitMenu, "Empty pane below", () => ChangeManualLayout(() => state.EmptySplit(tab.Id, true, owner, Host)));
        if (splitMenu.Items.Count > 0) { Add(splitMenu, "One pane", () => ChangeManualLayout(() => state.One(tab.Id, owner, Host))); Add(splitMenu, "Restore split", () => ChangeManualLayout(() => state.RestoreSplit(owner, Host))); splitChoice.Flyout = splitMenu; controls.Children.Add(splitChoice); }
        var popControl = IconButton(Host == "main" ? "Open " + tab.Title + " in new app window" : "Bring " + tab.Title + " back to main window", Host == "main" ? "\uE8A7" : "\uE72B", () => { if (Host == "main") pop(tab.Id); else dock(tab.Id); });
        controls.Children.Add(popControl);
        bar.SizeChanged += (_, _) => { var compact = bar.ActualWidth < 420; splitChoice.Visibility = popControl.Visibility = compact ? Visibility.Collapsed : Visibility.Visible; };
        actions.Click += (_, _) =>
        {
          var menu = tab.Kind != "browser" && SessionMenu is not null ? SessionMenu(tab) : new MenuFlyout();
          // Layout and account controls have one home in the header. The sidebar's
          // context menu still offers them when no session is on screen.
          foreach (var duplicate in menu.Items.Where(item => item is MenuFlyoutSubItem { Text: "Split view" } || item is MenuFlyoutItem { Text: "Account…" or "Open in new window" or "Move back to main window" }).ToArray()) menu.Items.Remove(duplicate);
          var info = new MenuFlyoutItem { Text = "Session info" }; info.Click += (_, _) => ShowInfo(actions); menu.Items.Insert(0, info);
          if (splitChoice.Visibility == Visibility.Collapsed)
          {
            Add(menu, "Split view…", () => DispatcherQueue.TryEnqueue(() => splitMenu.ShowAt(actions)));
            Add(menu, Host == "main" ? "Open in new window" : "Move back to main window", () => { if (Host == "main") pop(tab.Id); else dock(tab.Id); });
          }
          menu.ShowAt(actions);
        };
        if (splitPane) controls.Children.Add(IconButton("Close this pane", "\uE711", () => ClosePaneView(id)));
        SetColumn(controls, 1); bar.Children.Add(controls); pane.Children.Add(bar);
      }
      var content = view(tab);
      if (content is TerminalDeck.App.Views.SessionPane terminal)
      {
        terminal.HeaderElement.Visibility = Visibility.Collapsed;
        foreach (var area in terminal.Children.OfType<FrameworkElement>().Where(child => GetRow(child) == 1)) area.Margin = new(0);
      }
      var holder = new ContentControl { Tag = "workspace-view", Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
      SetRow(holder, 1); pane.Children.Add(holder);
      var frame = new Border { Child = pane, BorderThickness = new(layout.Root?.Tab is null ? 1 : 0), CornerRadius = new(0) };
      frame.SetResourceReference(Border.BorderBrushProperty, layout.ActiveEmpty is null && layout.Active == id ? "AccentFillColorDefaultBrush" : "DeckDividerBrush");
      frame.ActualThemeChanged += (_, _) => frame.BorderBrush = (Brush)ShellTheme.Resource(frame, (state.Layout(owner, Host).ActiveEmpty ?? state.Layout(owner, Host).Active) == id ? "AccentFillColorDefaultBrush" : "DeckDividerBrush");
      pane.AddHandler(PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => { state.Focus(id, owner, Host); focus(owner, id); }), true);
      pane.GotFocus += (_, _) => { state.Focus(id, owner, Host); focus(owner, id); };
      // Only the outer workspace clips a corner; pane frames meet each other and the window.
      RoundedContentClip.Attach(frame, radius: 0);
      paneFrames[id] = frame; return frame;
    }
    var split = new Grid();
    var first = node.First is null ? new Grid() : RenderNode(node.First, layout);
    var second = node.Second is null ? new Grid() : RenderNode(node.Second, layout);
    var divider = new Thumb { MinWidth = 0, MinHeight = 0, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    var dividerName = node.Vertical ? "Resize panes above and below" : "Resize panes side by side";
    AutomationProperties.SetName(divider, dividerName + " · " + Math.Round(node.Ratio * 100) + "%");
    AutomationProperties.SetHelpText(divider, "Arrow keys resize. Home and End move to the limits. Enter or Space resets to half.");
    divider.IsTabStop = true;
    divider.SetResourceReference(Control.BorderBrushProperty, "DeckDividerBrush");
    var ratio = node.Ratio;
    void Resize(double next)
    {
      ratio = Math.Clamp(next, 0.15, 0.85);
      AutomationProperties.SetName(divider, dividerName + " · " + Math.Round(ratio * 100) + "%");
      if (node.Vertical) { split.RowDefinitions[0].Height = new(ratio, GridUnitType.Star); split.RowDefinitions[2].Height = new(1 - ratio, GridUnitType.Star); }
      else { split.ColumnDefinitions[0].Width = new(ratio, GridUnitType.Star); split.ColumnDefinitions[2].Width = new(1 - ratio, GridUnitType.Star); }
    }
    if (node.Vertical)
    {
      split.RowDefinitions.Add(new() { Height = new(ratio, GridUnitType.Star), MinHeight = 80 }); split.RowDefinitions.Add(new() { Height = new(8) }); split.RowDefinitions.Add(new() { Height = new(1 - ratio, GridUnitType.Star), MinHeight = 80 });
      SetRow(divider, 1); SetRow(second, 2);
    }
    else
    {
      split.ColumnDefinitions.Add(new() { Width = new(ratio, GridUnitType.Star), MinWidth = 120 }); split.ColumnDefinitions.Add(new() { Width = new(8) }); split.ColumnDefinitions.Add(new() { Width = new(1 - ratio, GridUnitType.Star), MinWidth = 120 });
      SetColumn(divider, 1); SetColumn(second, 2);
    }
    divider.DragDelta += (_, args) => Resize(ratio + (node.Vertical ? args.VerticalChange / Math.Max(1, split.ActualHeight) : args.HorizontalChange / Math.Max(1, split.ActualWidth)));
    divider.DoubleTapped += (_, _) => state.Resize(owner, Host, node, 0.5);
    divider.DragCompleted += (_, _) => state.Resize(owner, Host, node, ratio);
    divider.KeyDown += (_, args) =>
    {
      if (args.Key is VirtualKey.Enter or VirtualKey.Space or VirtualKey.Home or VirtualKey.End) { state.Resize(owner, Host, node, args.Key == VirtualKey.Home ? 0.15 : args.Key == VirtualKey.End ? 0.85 : 0.5); args.Handled = true; }
      if (args.Key is VirtualKey.Left or VirtualKey.Up or VirtualKey.Right or VirtualKey.Down)
      { state.Resize(owner, Host, node, ratio + (args.Key is VirtualKey.Left or VirtualKey.Up ? -0.05 : 0.05)); args.Handled = true; }
    };
    split.Children.Add(first); split.Children.Add(divider); split.Children.Add(second); return split;
  }
  internal void UpdateFocus()
  {
    var active = headerActive?.StartsWith("page:", StringComparison.Ordinal) == true ? headerActive : state.Layout(owner, Host).ActiveEmpty ?? state.Layout(owner, Host).Active;
    var changed = headerActive != active;
    headerActive = active;
    foreach (var (id, button) in tabButtons) AutomationProperties.SetName(button, TabAccessibility(state.Get(id)));
    foreach (var (id, button) in accountButtons)
    {
      var label = accountLabel(state.Get(id)); button.Content = label; ToolTipService.SetToolTip(button, label);
      AutomationProperties.SetName(button, "Account for " + state.Get(id).Title + ": " + label);
    }
    foreach (var (id, frame) in paneFrames) frame.BorderBrush = (Brush)ShellTheme.Resource(frame, active == id ? "AccentFillColorDefaultBrush" : "DeckDividerBrush");
    foreach (var (id, title) in tabTitles) title.FontWeight = active == id ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal;
    foreach (var (id, button) in tabButtons) button.Foreground = (Brush)ShellTheme.Resource(button, active == id ? "DeckInkBrush" : "DeckSecondaryInkBrush");
    if (changed) RevealActiveTab();
  }
  private string TabAccessibility(WorkspaceTab tab)
  {
    if (session(tab) is { } row) return tab.Title + ", " + row.DisplaySubtitle + ", " + SessionStatus.From(row.State).Label + (row.Unread ? ", unread output" : "") + ", " + row.Folder;
    if (BrowserIdentity?.Invoke(tab) is { } browser) return tab.Title + ", " + browser.Binding + (browser.Loading ? ", loading" : "") + ", " + browser.Address;
    return tab.Title;
  }
  private int Index(WorkspaceTab tab) => state.Tabs.Where(t => t.Host == tab.Host).ToList().IndexOf(tab);
  private void Select(string id)
  {
    if (state.Layout(owner, Host).ActiveEmpty is { } empty && state.Get(id).Kind != "page")
    { state.FillEmpty(owner, Host, empty, id); focus(owner, id); FocusPane(id); return; }
    state.Select(id); owner = state.Get(id).Owner; focus(owner, id); FocusPane(id);
  }
  internal void FocusInput(string id) => FocusPane(id);
  private void FocusPane(string id) => Guard(async () =>
  {
    if (IsModalOpen?.Invoke() == true) return;
    await PaneLoaded(id);
    if (!paneFrames.TryGetValue(id, out var frame))
    {
      if (state.Get(id).Kind == "page" && FocusManager.FindFirstFocusableElement(view(state.Get(id))) is Control pageInput) pageInput.Focus(FocusState.Programmatic);
      return;
    }
    var content = WorkspaceVisuals.Tree(frame).ToArray();
    if (content.OfType<WebView2>().FirstOrDefault() is { } web)
    {
      web.Focus(FocusState.Programmatic);
      if (state.Get(id).Kind == "terminal" && web.CoreWebView2 is { } core) await core.ExecuteScriptAsync("document.querySelector('.xterm-helper-textarea')?.focus()");
    }
    else if (content.OfType<TextBox>().FirstOrDefault(input => input.AcceptsReturn && !input.IsReadOnly) is { } composer) composer.Focus(FocusState.Programmatic);
    else if (FocusManager.FindFirstFocusableElement(frame) is Control input) input.Focus(FocusState.Programmatic);
  });
  // Selecting a tab can rebuild the panes, so the frame found for it may be
  // brand new: until it is loaded it has no template and no WebView2 in its
  // tree, and focus would land nowhere. Wait for it (a later rebuild may
  // replace it again, hence the short loop).
  private async Task PaneLoaded(string id)
  {
    for (var wait = 0; wait < 3 && paneFrames.TryGetValue(id, out var frame) && !frame.IsLoaded; wait++)
    {
      var loaded = new TaskCompletionSource();
      void Done(object sender, RoutedEventArgs e) => loaded.TrySetResult();
      frame.Loaded += Done;
      try { await Task.WhenAny(loaded.Task, Task.Delay(1000)); }
      finally { frame.Loaded -= Done; }
    }
  }
  private void ClosePaneView(string id)
  {
    state.ClosePane(owner, Host, id); var layout = state.Layout(owner, Host);
    if (layout.Active is { } active) { focus(owner, active); FocusPane(active); }
    else if (layout.Root?.EmptyIds.FirstOrDefault() is { } empty) { state.FocusEmpty(owner, Host, empty); FocusPane(empty); }
  }
  private void ChangeManualLayout(Action change) { BeginManualSplit?.Invoke(); change(); }
  private void Split(string id, bool vertical) { BeginManualSplit?.Invoke(); if (state.Layout(owner, Host).Active is { } active && active != id) { state.Split(active, id, vertical, owner, Host); focus(owner, id); FocusPane(id); } }
  private void Step(int delta, bool panes = false)
  {
    var ids = panes ? state.Layout(owner, Host).Root?.Tabs.ToArray() ?? [] : state.Tabs.Where(t => t.Host == Host).Select(t => t.Id).ToArray();
    if (ids.Length == 0) return;
    var active = panes ? state.Layout(owner, Host).Active : headerActive;
    var id = ids[(Math.Max(0, Array.IndexOf(ids, active)) + delta + ids.Length) % ids.Length];
    if (panes) { state.Focus(id, owner, Host); focus(owner, id); FocusPane(id); } else Select(id);
  }
  private async void Guard(Func<Task> work) { try { await work(); } catch (Exception ex) when (ex is not OutOfMemoryException) { notice(ex is ArgumentException or InvalidOperationException ? ex.Message : "The window action could not finish. Try again."); } }
  private void AddShortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
  {
    foreach (var target in new UIElement[] { this, Header })
    {
      target.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
      var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
      shortcut.Invoked += (_, args) => { if (IsModalOpen?.Invoke() != true) action(); args.Handled = true; }; target.KeyboardAccelerators.Add(shortcut);
    }
  }
  private static void Add(MenuFlyout menu, string title, Action action) { var item = new MenuFlyoutItem { Text = title }; item.Click += (_, _) => action(); menu.Items.Add(item); }
  private static Button NewWindowButton(string name, string kind, Action action)
  {
    var button = IconButton(name, WorkspaceIcons.For(kind), action);
    button.Content = new TerminalDeck.App.Views.DeckIcon { Glyph = kind, FontSize = 16 };
    return button;
  }
  internal static Button IconButton(string name, string glyph, Action action)
  {
    var button = new Button { Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"], Content = new TerminalDeck.App.Views.DeckIcon { Glyph = glyph, FontSize = 14 }, Width = 28, Height = 32, MinHeight = 28, Padding = new(4), BorderThickness = new(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name); button.Click += (_, _) => action(); return button;
  }
}
