using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using TerminalDeck.App.Shell;
using Windows.System;

namespace TerminalDeck.App.Views;

// The shell and the browser's MCP handlers share the very same retained pages.
// A split or pop-out moves the view; it never opens a second copy of the URL.
public sealed partial class BrowserPane
{
  private readonly Dictionary<string, Grid> shellViews = [];
  private readonly HashSet<string> shellObserved = [];
  private readonly Dictionary<string, Action> shellRefresh = [];
  private void RefreshShellViews()
  {
    foreach (var refresh in shellRefresh.Values.ToArray()) refresh();
  }
  internal event Action? ShellChanged;
  internal event Action<string>? ShellSelected;
  internal async Task PrepareShellAsync()
  {
    await Ready;
    if (Core.Read().StartUrl == "about:blank")
    {
      var legacyStart = new TerminalDeck.Core.Storage.JsonStateStore<TerminalDeck.Core.Browser.BrowserStartPage>(root, "browser-start-page").Load();
      if (legacyStart?.Url is { Length: > 0 } url) await Core.SetStartUrlAsync(TerminalDeck.Core.Browser.BrowserStartPage.Validate(url));
    }
    TabRail.Visibility = Visibility.Collapsed;
    ObserveShellPages();
  }
  internal void ObserveShellPages()
  {
    foreach (var tab in tabs.Where(t => !shellObserved.Contains(t.Id)).ToArray())
    {
      shellObserved.Add(tab.Id);
      tab.View.CoreWebView2.DocumentTitleChanged += (_, _) => ShellChanged?.Invoke();
      tab.View.CoreWebView2.NavigationCompleted += (_, _) => ShellChanged?.Invoke();
      tab.View.CoreWebView2.NewWindowRequested += (_, _) => DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { ObserveShellPages(); ShellChanged?.Invoke(); });
    }
    ShellChanged?.Invoke();
  }
  internal FrameworkElement ShellView(string id)
  {
    if (shellViews.TryGetValue(id, out var existing)) return existing;
    var tab = tabs.Single(t => t.Id == id);
    var panel = new Grid { RowSpacing = 0 };
    foreach (var height in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
      panel.RowDefinitions.Add(new() { Height = height });
    panel.SetResourceReference(Grid.BackgroundProperty, WorkspacePaper.Terminal);
    async void Run(string command, string? argument = null) => await RunForAsync(tab, command, argument);
    var chrome = new StackPanel { Spacing = 4, Padding = new(8, 5, 8, 5) }; WorkspacePaper.ApplyInk(chrome);
    var driving = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    driving.Children.Add(TextAction("Use this page", async () => await GuardAsync(async () => { await Core.TakeHumanControlAsync(tab.Id); SetTabStatus(tab, "You can navigate the page."); }, tab))); var drivingNotice = new Notices.CompactNotice { Scope = panel, Message = "An agent is using this page.", ActionButton = driving, AutoDismiss = false }; panel.Children.Add(drivingNotice);
    var bar = new Grid { ColumnSpacing = 4 };
    bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var back = WorkspaceSurface.IconButton("Back", "\uE72B", () => Run("back"));
    var forward = WorkspaceSurface.IconButton("Forward", "\uE72A", () => Run("forward"));
    var reload = WorkspaceSurface.IconButton("Reload page", "\uE72C", () => Run(tab.Loading ? "stop" : "reload", Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down) ? "bypass" : null));
    var home = WorkspaceSurface.IconButton("Home", "\uE80F", () => Run("home"));
    InstallHistoryMenu(tab, back, false); InstallHistoryMenu(tab, forward, true);
    navigation.Children.Add(back); navigation.Children.Add(forward); navigation.Children.Add(reload); navigation.Children.Add(home);
    var sessionButton = SessionButton(tab); navigation.Children.Add(sessionButton); bar.Children.Add(navigation);
    var address = new AutoSuggestBox { PlaceholderText = "Enter a URL, or search", MinWidth = 100, MinHeight = 28, Height = 28, Padding = new(10, 0, 10, 0), CornerRadius = new(8), Margin = new(4, 0, 4, 0), FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    InstallAddress(tab, address);
    address.Loaded += (_, _) => { if (tab.Address.Length == 0 && Core.Read().SelectedTabId == tab.Id) address.Focus(FocusState.Programmatic); };
    Grid.SetColumn(address, 1); bar.Children.Add(address);
    var profile = new Button { Width = 26, Height = 26, MinWidth = 26, MinHeight = 26, FontSize = 12, Padding = new(0), CornerRadius = new(13), Content = System.Globalization.StringInfo.GetNextTextElement(tab.Profile.Name).ToUpperInvariant(), Flyout = ProfileMenu(tab) };
    foreach (var button in navigation.Children.OfType<Button>())
    { button.Width = button.Height = button.MinWidth = button.MinHeight = 26; button.CornerRadius = new(8); button.Padding = new(0); }
    var profileActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var toolStrip = new ScrollViewer { Content = tools, Width = 194, MinWidth = 26, Height = 26, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    profileActions.Children.Add(toolStrip);
    var resetZoom = TextAction("100%", async () => await GuardAsync(() => SetZoomAsync(tab, 1), tab)); profileActions.Children.Add(resetZoom);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(profile, "Browser profile and actions");
    ToolTipService.SetToolTip(profile, "Profile · " + tab.Profile.Name); Grid.SetColumn(profileActions, 2); bar.Children.Add(profileActions); chrome.Children.Add(bar);
    var progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 2, Visibility = Visibility.Collapsed }; chrome.Children.Add(progress);
    var find = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    var query = new TextBox { PlaceholderText = "Find in Page", MinWidth = 160, Text = tab.FindText };
    var found = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
    query.TextChanged += async (_, _) => { tab.FindText = query.Text; await GuardAsync(() => FindAsync(tab), tab); };
    query.KeyDown += async (_, args) => { if (args.Key == VirtualKey.Enter) { args.Handled = true; await GuardAsync(() => FindAsync(tab), tab); } if (args.Key == VirtualKey.Escape) { tab.FindShown = false; RefreshShellViews(); args.Handled = true; } };
    find.Children.Add(query); find.Children.Add(TextAction("Previous", async () => await GuardAsync(() => FindAsync(tab, true), tab))); find.Children.Add(TextAction("Next", async () => await GuardAsync(() => FindAsync(tab), tab))); find.Children.Add(found);
    find.Children.Add(TextAction("Done", () => { tab.FindShown = false; RefreshShellViews(); })); chrome.Children.Add(find);
    var custom = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    var customWidth = new NumberBox { Header = "W", Minimum = 240, Maximum = 3840, Value = tab.Viewport.Width == 0 ? 1024 : tab.Viewport.Width, Width = 100 };
    var customHeight = new NumberBox { Header = "H", Minimum = 240, Maximum = 3840, Value = tab.Viewport.Height == 0 ? 768 : tab.Viewport.Height, Width = 100 };
    custom.Children.Add(customWidth); custom.Children.Add(customHeight);
    custom.Children.Add(TextAction("Apply", async () => await GuardAsync(async () =>
    {
      if (!double.IsFinite(customWidth.Value) || !double.IsFinite(customHeight.Value)) throw new ArgumentException("Enter a width and height.");
      tab.Viewport = TerminalDeck.Core.Browser.BrowserViewport.Custom((int)customWidth.Value, (int)customHeight.Value); await ApplyViewportAsync(tab);
    }, tab)));
    custom.Children.Add(TextAction("Done", () => { tab.SizeEditing = false; RefreshShellViews(); })); chrome.Children.Add(custom); panel.Children.Add(chrome);

    var details = new StackPanel { Spacing = 8, Padding = new(12, 8, 12, 8) };
    details.SetResourceReference(Grid.BackgroundProperty, "DeckRailBrush");
    var flow = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
    var flowHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var heading = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }; flowHeader.Children.Add(heading);
    var copy = TextAction("Copy", () => { CopyText(string.Join('\n', tab.Steps)); SetTabStatus(tab, "Recorded steps copied."); });
    var clear = TextAction("Clear", () => { tab.Steps.Clear(); RefreshShellViews(); });
    var hide = TextAction("Hide", () => { if (!tab.Recording) { tab.StepsShown = false; RefreshShellViews(); } });
    flowHeader.Children.Add(copy); flowHeader.Children.Add(clear); flowHeader.Children.Add(hide); flow.Children.Add(flowHeader);
    var stepsText = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 12 };
    flow.Children.Add(new ScrollViewer { MaxHeight = 130, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = stepsText });
    var flowDraft = new TextBox { PlaceholderText = "Anything to say about this flow?", Text = tab.FlowDraft, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 100 };
    flowDraft.TextChanged += (_, _) => tab.FlowDraft = flowDraft.Text; flow.Children.Add(flowDraft);
    var sendFlow = TextAction("Send flow", async () => await GuardAsync(async () => { var outcome = await ReviewSendAsync(tab, TerminalDeck.Core.Browser.BrowserContext.Create(tab.Address, tab.Title, string.Join('\n', tab.Steps)) + "\n\n" + tab.FlowDraft); if (outcome == BrowserSendOutcome.Sent) { tab.FlowDraft = ""; flowDraft.Text = ""; } }, tab)); flow.Children.Add(sendFlow); details.Children.Add(flow);
    var annotations = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
    var marks = new StackPanel { Spacing = 4 }; annotations.Children.Add(new ScrollViewer { MaxHeight = 130, Content = marks });
    var instruction = new TextBox { PlaceholderText = "What should change?", Text = tab.AnnotationDraft, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 100 };
    instruction.TextChanged += (_, _) => tab.AnnotationDraft = instruction.Text; annotations.Children.Add(instruction);
    var annotationActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var sendMarks = TextAction("Send annotations", async () => await GuardAsync(() => SendAnnotationsAsync(tab), tab)); annotationActions.Children.Add(sendMarks);
    annotationActions.Children.Add(TextAction("Done", async () => await GuardAsync(() => FinishInspectAsync(tab), tab))); annotations.Children.Add(annotationActions); details.Children.Add(annotations);
    Grid.SetRow(details, 1); panel.Children.Add(details);
    var status = new Notices.CompactNotice { Scope = panel };
    var lastStatus = "";
    var failure = StartView(tab);
    var page = new Grid(); SurfaceHost.Children.Remove(tab.View);
    var viewport = new Grid(); viewport.Children.Add(tab.View);
    var fitted = new Viewbox { Child = viewport, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    page.Children.Add(fitted); page.Children.Add(failure); Grid.SetRow(page, 3); panel.Children.Add(page);
    void FitViewport()
    {
      if (page.ActualWidth <= 0 || page.ActualHeight <= 0) return;
      viewport.Width = tab.Viewport.Width == 0 ? page.ActualWidth : tab.Viewport.Width;
      viewport.Height = tab.Viewport.Height == 0 ? page.ActualHeight : tab.Viewport.Height;
      page.Clip = new Microsoft.UI.Xaml.Media.RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, page.ActualWidth, page.ActualHeight) };
    }
    page.SizeChanged += (_, _) => FitViewport();

    Button Tool(string name, string glyph, Action run)
    {
      var button = WorkspaceSurface.IconButton(name, glyph, run); button.Width = button.Height = 26;
      button.MinWidth = button.MinHeight = 26; button.CornerRadius = new(8); button.Padding = new(0); tools.Children.Add(button); return button;
    }
    var mode = Tool(tab.Isolated ? "Isolated" : "Shared", "\uE72E", async () => await GuardAsync(() => SwitchStoreAsync(tab, tab.Profile.Id, !tab.Isolated), tab));
    ToolTipService.SetToolTip(mode, "Shared keeps this profile’s sign-ins. Isolated discards them when the tab closes.");
    var inspect = Tool("Annotate", "\uE77A", () => Run("inspect"));
    var record = Tool("Record", "\uE7C8", () => Run("record"));
    Tool("Shot", "\uE722", () => Run("shot"));
    Tool("Draw", "\uE70F", () => Run("draw"));
    var size = Tool("Size", "\uE8EA", () => { }); size.Flyout = SizeMenu(tab);
    Tool("Devtools", "\uE943", () => Run("devtools"));
    Button? downloadButton = null;
    downloadButton = WorkspaceSurface.IconButton("Downloads", "\uE896", async () => await GuardAsync(() => ShowDownloadsAsync(tab, downloadButton), tab));
    downloadButton.Width = downloadButton.Height = downloadButton.MinWidth = downloadButton.MinHeight = 26; downloadButton.CornerRadius = new(8); downloadButton.Padding = new(0);
    profileActions.Children.Add(downloadButton);
    Tool("Send", "\uE724", () => Run("send"));
    profileActions.Children.Add(profile);
    Grid.SetRow(status, 5); panel.Children.Add(status);
    var annotationCount = -1; var renderedSelection = -1;
    shellRefresh[id] = () =>
    {
      driving.Visibility = tab.AutomationOrigin is null ? Visibility.Collapsed : Visibility.Visible;
      drivingNotice.Message = (Core.Driver(tab.Id) ?? "An agent") + " is driving on " + (Uri.TryCreate(tab.Address, UriKind.Absolute, out var driverPage) ? driverPage.Host : "this page") + ".";
      drivingNotice.IsOpen = tab.AutomationOrigin is not null;
      resetZoom.Visibility = Math.Abs(tab.Zoom - 1) < 0.001 ? Visibility.Collapsed : Visibility.Visible; resetZoom.Content = $"{tab.Zoom:P0}";
      var binding = Core.Get(tab.Id);
      sessionButton.Visibility = SessionChoices().Count > 0 || binding.SessionId is not null ? Visibility.Visible : Visibility.Collapsed;
      sessionButton.Content = binding.SessionSlot is { } slot ? slot : new DeckIcon { Glyph = "\uE71B", FontSize = 14 };
      ToolTipService.SetToolTip(sessionButton, binding.SessionId is { } linked ? "Linked to " + (SessionChoices().FirstOrDefault(s => s.Id == linked)?.Title ?? "Session") : "Connect a session");
      back.IsEnabled = tab.View.CoreWebView2.CanGoBack; forward.IsEnabled = tab.View.CoreWebView2.CanGoForward;
      ((DeckIcon)reload.Content).Glyph = tab.Loading ? "\uE711" : "\uE72C";
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reload, tab.Loading ? "Stop loading" : "Reload page");
      progress.Visibility = tab.Loading ? Visibility.Visible : Visibility.Collapsed; progress.Value = tab.LoadProgress;
      if (lastStatus != tab.Status)
      {
        lastStatus = tab.Status; status.Message = tab.Status;
        status.IsOpen = tab.Status is not ("Page ready" or "New tab" or "Loading page…" or "Opening page…");
      }
      flow.Visibility = tab.StepsShown ? Visibility.Visible : Visibility.Collapsed; hide.IsEnabled = !tab.Recording;
      heading.Text = tab.Recording ? $"Recording · {tab.Steps.Count}" : $"Recorded steps · {tab.Steps.Count}";
      stepsText.Text = tab.Steps.Count > 0 ? string.Join('\n', tab.Steps) : "Use the page — clicks, entries and navigation appear here. Typed values are omitted.";
      copy.IsEnabled = clear.IsEnabled = sendFlow.IsEnabled = tab.Steps.Count > 0;
      ((DeckIcon)record.Content).Glyph = tab.Recording ? "\uE71A" : "\uE7C8";
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(record, tab.Recording ? $"Stop recording · {tab.Steps.Count}" : "Record");
      inspect.Opacity = tab.Inspecting ? 1 : .7;
      custom.Visibility = tab.SizeEditing ? Visibility.Visible : Visibility.Collapsed; FitViewport();
      find.Visibility = tab.FindShown ? Visibility.Visible : Visibility.Collapsed; found.Text = tab.FindResult;
      if (instruction.Text != tab.AnnotationDraft) instruction.Text = tab.AnnotationDraft;
      annotations.Visibility = tab.Inspecting ? Visibility.Visible : Visibility.Collapsed; sendMarks.IsEnabled = tab.Annotations.Count > 0;
      details.Visibility = tab.StepsShown || tab.Inspecting ? Visibility.Visible : Visibility.Collapsed;
      if (annotationCount != tab.Annotations.Count || renderedSelection != tab.SelectedAnnotation)
      {
        marks.Children.Clear(); annotationCount = tab.Annotations.Count; renderedSelection = tab.SelectedAnnotation;
        foreach (var mark in tab.Annotations)
        {
          var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
          var label = TextAction($"{mark.Number}. {mark.Description}", async () => await GuardAsync(async () =>
          {
            tab.SelectedAnnotation = mark.Number;
            if (mark.Url == tab.Address) await tab.Model.CommandAsync("Runtime.evaluate", new { expression = TerminalDeck.Core.Browser.BrowserInspection.Select(mark.Selector, mark.Number) });
            RefreshShellViews();
          }, tab));
          label.MaxWidth = 320; label.Opacity = tab.SelectedAnnotation == mark.Number ? 1 : 0.7;
          ToolTipService.SetToolTip(label, mark.Url + "\n" + mark.Selector); row.Children.Add(label);
          row.Children.Add(TextAction("Delete", async () => await GuardAsync(async () => { tab.Annotations.Remove(mark); await tab.Model.CommandAsync("Runtime.evaluate", new { expression = TerminalDeck.Core.Browser.BrowserInspection.Delete(mark.Number) }); RefreshShellViews(); }, tab))); marks.Children.Add(row);
        }
      }
      var running = downloads.Count(d => d.Operation.State == Microsoft.Web.WebView2.Core.CoreWebView2DownloadState.InProgress);
      ToolTipService.SetToolTip(downloadButton, running > 0 ? $"Downloads · {running}" : "Downloads");
      failure.Visibility = tab.Failed || tab.Address.Length == 0 ? Visibility.Visible : Visibility.Collapsed; tab.View.Visibility = tab.Failed || tab.Address.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    };
    void Shortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    { var shortcut = new KeyboardAccelerator { Key = key, Modifiers = modifiers }; shortcut.Invoked += (_, args) => { action(); args.Handled = true; }; panel.KeyboardAccelerators.Add(shortcut); }
    Shortcut(VirtualKey.L, VirtualKeyModifiers.Control, () => address.Focus(FocusState.Programmatic));
    Shortcut(VirtualKey.R, VirtualKeyModifiers.Control, () => Run("reload"));
    Shortcut(VirtualKey.R, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => Run("reload", "bypass"));
    Shortcut(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => Run("devtools"));
    Shortcut(VirtualKey.T, VirtualKeyModifiers.Control, async () => await GuardAsync(() => OpenAfterAsync(tab, false), tab));
    Shortcut(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, async () => await GuardAsync(() => OpenAfterAsync(tab, true), tab));
    Shortcut(VirtualKey.W, VirtualKeyModifiers.Control, async () => await GuardAsync(() => CloseAsync(tab), tab));
    Shortcut(VirtualKey.H, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => Run("home"));
    Shortcut(VirtualKey.F, VirtualKeyModifiers.Control, () => { tab.FindShown = true; RefreshShellViews(); query.Focus(FocusState.Programmatic); query.SelectAll(); });
    Shortcut(VirtualKey.G, VirtualKeyModifiers.Control, async () => await GuardAsync(() => FindAsync(tab), tab));
    Shortcut(VirtualKey.G, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, async () => await GuardAsync(() => FindAsync(tab, true), tab));
    Shortcut(VirtualKey.P, VirtualKeyModifiers.Control, () => tab.View.CoreWebView2.ShowPrintUI(Microsoft.Web.WebView2.Core.CoreWebView2PrintDialogKind.Browser));
    Shortcut((VirtualKey)187, VirtualKeyModifiers.Control, async () => await SetZoomAsync(tab, tab.Zoom * 1.1));
    Shortcut((VirtualKey)189, VirtualKeyModifiers.Control, async () => await SetZoomAsync(tab, tab.Zoom / 1.1));
    Shortcut((VirtualKey)187, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, async () => await SetZoomAsync(tab, tab.Zoom * 1.1));
    Shortcut(VirtualKey.Add, VirtualKeyModifiers.Control, async () => await SetZoomAsync(tab, tab.Zoom * 1.1));
    Shortcut(VirtualKey.Subtract, VirtualKeyModifiers.Control, async () => await SetZoomAsync(tab, tab.Zoom / 1.1));
    Shortcut(VirtualKey.Number0, VirtualKeyModifiers.Control, async () => await SetZoomAsync(tab, 1));
    Shortcut((VirtualKey)219, VirtualKeyModifiers.Control, () => Run("back"));
    Shortcut((VirtualKey)221, VirtualKeyModifiers.Control, () => Run("forward"));
    Shortcut((VirtualKey)190, VirtualKeyModifiers.Control, () => Run("stop"));
    async Task Cycle(bool backwards)
    {
      var siblings = Core.Read().Tabs.Where(t => t.SessionId == Core.Get(tab.Id).SessionId).ToArray();
      var at = Array.FindIndex(siblings, t => t.Id == tab.Id);
      var next = siblings[(at + (backwards ? siblings.Length - 1 : 1)) % siblings.Length];
      await Core.SelectAsync(next.Id); Present(tabs.Single(t => t.Id == next.Id)); ShellSelected?.Invoke(next.Id);
    }
    Shortcut(VirtualKey.Tab, VirtualKeyModifiers.Control, async () => await GuardAsync(() => Cycle(false), tab));
    Shortcut(VirtualKey.Tab, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, async () => await GuardAsync(() => Cycle(true), tab));
    var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
    escape.Invoked += async (_, args) =>
    {
      if (tab.Inspecting) { args.Handled = true; await GuardAsync(() => FinishInspectAsync(tab), tab); }
      else if (tab.FindShown) { args.Handled = true; tab.FindShown = false; RefreshShellViews(); }
    };
    panel.KeyboardAccelerators.Add(escape);
    tab.View.RegisterPropertyChangedCallback(VisibilityProperty, (_, _) =>
    {
      var desired = tab.Failed || tab.Address.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
      if (tab.View.Visibility != desired) tab.View.Visibility = desired;
    });
    tab.View.Visibility = Visibility.Visible;
    tab.View.CoreWebView2.NavigationCompleted += (_, _) => { address.Text = tab.Address; RefreshShellViews(); };
    tab.View.CoreWebView2.NavigationStarting += (_, _) => RefreshShellViews();
    tab.View.CoreWebView2.HistoryChanged += (_, _) => RefreshShellViews();
    shellViews.Add(id, panel); shellRefresh[id](); return panel;
  }
  internal async Task SelectShellWindowAsync(string id)
  {
    if (Core.Read().SelectedTabId != id) await Core.SelectAsync(id);
    Present(tabs.Single(t => t.Id == id));
  }
  internal void ShowShellHandover(string tabId)
  {
    if (HandoverBar.Parent is Panel parent) parent.Children.Remove(HandoverBar);
    if (HandoverBar.Parent is ContentControl holder) holder.Content = null;
    // Handover belongs to the requested page. Overlay its content without
    // reserving a row or shifting that page's toolbar.
    Canvas.SetZIndex(HandoverBar, 1000);
    if (shellViews.TryGetValue(tabId, out var panel))
    {
      Grid.SetRow(HandoverBar, 3); panel.Children.Add(HandoverBar);
    }
    else if (Content is Grid engine) { Grid.SetRow(HandoverBar, 4); engine.Children.Add(HandoverBar); }
  }
  internal void ForgetShellView(string id) { shellViews.Remove(id); shellRefresh.Remove(id); shellObserved.Remove(id); }
}
