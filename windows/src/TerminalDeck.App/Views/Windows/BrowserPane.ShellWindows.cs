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
    InstallHistoryMenu(tab, back, false); InstallHistoryMenu(tab, forward, true);
    navigation.Children.Add(back); navigation.Children.Add(forward); navigation.Children.Add(reload);
    var sessionButton = SessionButton(tab, out var refreshConnection); bar.Children.Add(navigation);
    var address = new AutoSuggestBox { PlaceholderText = "Enter a URL, or search", MinWidth = 100, MinHeight = 28, Height = 28, Padding = new(10, 0, 10, 0), CornerRadius = new(15), Margin = new(0), FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    InstallAddress(tab, address);
    address.Loaded += (_, _) => { if (tab.Address.Length == 0 && Core.Read().SelectedTabId == tab.Id) address.Focus(FocusState.Programmatic); };
    var addressGroup = new Grid { CornerRadius = new(15), Margin = new(4, 0, 4, 0), ColumnSpacing = 2 };
    addressGroup.SetResourceReference(Grid.BackgroundProperty, "DeckControlBrush");
    addressGroup.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); addressGroup.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); addressGroup.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    addressGroup.Children.Add(address);
    var star = WorkspaceSurface.IconButton("Save bookmark", "\uE734", async () => await GuardAsync(() => ToggleBookmarkAsync(tab), tab)); star.Width = star.Height = star.MinWidth = star.MinHeight = 26; star.Padding = new(0); star.CornerRadius = new(13); Grid.SetColumn(star, 2); addressGroup.Children.Add(star);
    Grid.SetColumn(addressGroup, 1); bar.Children.Add(addressGroup);
    var profile = new Button { Width = 26, Height = 26, MinWidth = 26, MinHeight = 26, FontSize = 12, Padding = new(0), CornerRadius = new(13), Content = ProfileAvatar(tab.Profile, 24, tab.Isolated), Flyout = ProfileCard(tab) };
    foreach (var button in navigation.Children.OfType<Button>())
    { button.Width = button.Height = button.MinWidth = button.MinHeight = 26; button.CornerRadius = new(8); button.Padding = new(0); }
    var profileActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
    var toolStrip = tools;
    var phoneMode = TextAction("Page size", async () => await GuardAsync(async () => { tab.Viewport = TerminalDeck.Core.Browser.BrowserViewport.Presets[0]; tab.PhoneAgent = false; await ApplyViewportAsync(tab); }, tab));
    DeckMenu.Pill(phoneMode); phoneMode.Height = phoneMode.MinHeight = 26; profileActions.Children.Add(phoneMode);
    profileActions.Children.Add(toolStrip);
    var resetZoom = TextAction("100%", async () => await GuardAsync(() => SetZoomAsync(tab, 1), tab)); Grid.SetColumn(resetZoom, 1); addressGroup.Children.Add(resetZoom);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(profile, "Browser profile and actions");
    ToolTipService.SetToolTip(profile, "Profile · " + tab.Profile.Name); Grid.SetColumn(profileActions, 2); bar.Children.Add(profileActions); chrome.Children.Add(bar);
    var bookmarks = BookmarkBar(tab, out var refreshBookmarks); chrome.Children.Add(bookmarks);
    panel.SizeChanged += (_, _) => toolStrip.Visibility = panel.ActualWidth < 620 ? Visibility.Collapsed : Visibility.Visible;
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
    custom.Children.Add(TextAction("Done", () => { tab.SizeEditing = false; RefreshShellViews(); })); chrome.Children.Add(custom);
    var questionBar = new Grid { ColumnSpacing = 8, Padding = new(8, 6, 8, 6), CornerRadius = new(8), Visibility = Visibility.Collapsed }; questionBar.SetResourceReference(Grid.BackgroundProperty, "DeckControlBrush");
    questionBar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); questionBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); questionBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var questionText = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }; questionBar.Children.Add(questionText);
    var reviewQuestion = TextAction("Review", () => ReviewPageQuestion(tab)); Grid.SetColumn(reviewQuestion, 1); questionBar.Children.Add(reviewQuestion);
    var cancelQuestion = TextAction("Cancel", () => CancelPageQuestion(tab)); Grid.SetColumn(cancelQuestion, 2); questionBar.Children.Add(cancelQuestion); chrome.Children.Add(questionBar); panel.Children.Add(chrome);

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
    var page = new Grid();
    var viewport = new Grid(); pageSlots[id] = viewport;
    viewport.Loaded += (_, _) => { TrackBrowserRoot(panel); RefreshBackgroundPages(); };
    viewport.Unloaded += (_, _) => DispatcherQueue.TryEnqueueHandled(() => RefreshBackgroundPages());
    viewport.LayoutUpdated += (_, _) => RefreshBackgroundPage(tab);
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
    var inspect = Tool("Annotate page", "\uE77A", () => Run("inspect"));
    Tool("Screenshot", "\uE722", () => Run("shot"));
    var record = Tool("Record steps", "\uE7C8", () => Run("record"));
    profileActions.Children.Add(sessionButton);
    Button? downloadButton = null;
    downloadButton = WorkspaceSurface.IconButton("Downloads", "\uE896", async () => await GuardAsync(() => ShowDownloadsAsync(tab, downloadButton), tab));
    downloadButton.Width = downloadButton.Height = downloadButton.MinWidth = downloadButton.MinHeight = 26; downloadButton.CornerRadius = new(8); downloadButton.Padding = new(0);
    profileActions.Children.Add(downloadButton);
    profileActions.Children.Add(profile);
    var more = WorkspaceSurface.IconButton("More browser actions", "\uE712", () => { }); more.Flyout = MoreMenu(tab);
    more.Width = more.Height = more.MinWidth = more.MinHeight = 26; more.CornerRadius = new(13); more.Padding = new(0); profileActions.Children.Add(more);
    Grid.SetRow(status, 5); panel.Children.Add(status);
    var annotationCount = -1; var renderedSelection = -1;
    shellRefresh[id] = () =>
    {
      questionBar.Visibility = tab.PageRequestNote is null ? Visibility.Collapsed : Visibility.Visible; questionText.Text = tab.PageRequestNote ?? "";
      var waitingQuestion = pageQuestions.TryGetValue(tab.Id, out var questions) && questions.Count > 0;
      reviewQuestion.Visibility = waitingQuestion ? Visibility.Visible : Visibility.Collapsed; reviewQuestion.IsEnabled = PersonCanAnswer(tab); cancelQuestion.Content = waitingQuestion ? "Cancel" : "Dismiss";
      driving.Visibility = tab.AutomationOrigin is null ? Visibility.Collapsed : Visibility.Visible;
      drivingNotice.Message = (Core.Driver(tab.Id) ?? "An agent") + " is driving on " + (Uri.TryCreate(tab.Address, UriKind.Absolute, out var driverPage) ? driverPage.Host : "this page") + ".";
      drivingNotice.IsOpen = tab.AutomationOrigin is not null;
      resetZoom.Visibility = Math.Abs(tab.Zoom - 1) < 0.001 ? Visibility.Collapsed : Visibility.Visible; resetZoom.Content = $"{tab.Zoom:P0}";
      refreshBookmarks();
      star.IsEnabled = Uri.TryCreate(tab.Address, UriKind.Absolute, out var bookmarkAddress) && bookmarkAddress.Scheme is "http" or "https";
      var savedBookmark = Core.Bookmarks(tab.Profile.Id).Any(b => b.Url == tab.Address);
      star.Content = BookmarkGlyph(savedBookmark);
      profile.Content = ProfileAvatar(tab.Profile, 24, tab.Isolated);
      ToolTipService.SetToolTip(profile, (tab.Isolated ? "Isolated tab · " : "Profile · ") + tab.Profile.Name);
      ToolTipService.SetToolTip(star, savedBookmark ? "Remove bookmark" : "Save bookmark");
      var binding = Core.Get(tab.Id);
      sessionButton.Visibility = Visibility.Visible;
      refreshConnection(panel.ActualWidth >= 740 && !tab.Recording && !tab.Inspecting && tab.Viewport.Width == 0);
      phoneMode.Visibility = (tab.Viewport.Width > 0 || tab.PhoneAgent) && panel.ActualWidth >= 500 ? Visibility.Visible : Visibility.Collapsed;
      phoneMode.Width = panel.ActualWidth >= 900 ? double.NaN : 26; phoneMode.Padding = panel.ActualWidth >= 900 ? new(8, 0, 8, 0) : new(0);
      phoneMode.Content = panel.ActualWidth >= 900 ? tab.Viewport.Name + " ×" : new DeckIcon { Glyph = "\uE8EA", FontSize = 14 };
      ToolTipService.SetToolTip(phoneMode, tab.Viewport.Name + " · Click to fill the window");
      ToolTipService.SetToolTip(sessionButton, binding.SessionId is { } linked ? "Linked to " + (SessionChoices().FirstOrDefault(s => s.Id == linked)?.Title ?? "Session") : "Connect a session");
      back.IsEnabled = tab.View.CoreWebView2.CanGoBack; forward.IsEnabled = tab.View.CoreWebView2.CanGoForward;
      ((DeckIcon)reload.Content).Glyph = tab.Loading ? "\uE711" : "\uE72C";
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reload, tab.Loading ? "Stop loading" : "Reload page");
      progress.Visibility = tab.Loading ? Visibility.Visible : Visibility.Collapsed; progress.Value = tab.LoadProgress;
      if (lastStatus != tab.Status)
      {
        lastStatus = tab.Status; status.Message = tab.Status;
        status.IsOpen = tab.Status is not ("Page ready" or "Popup ready" or "New tab" or "Loading page…" or "Opening page…");
      }
      flow.Visibility = tab.StepsShown ? Visibility.Visible : Visibility.Collapsed; hide.IsEnabled = !tab.Recording;
      heading.Text = tab.Recording ? $"Recording · {tab.Steps.Count}" : $"Recorded steps · {tab.Steps.Count}";
      stepsText.Text = tab.Steps.Count > 0 ? string.Join('\n', tab.Steps) : "Use the page — clicks, entries and navigation appear here. Typed values are omitted.";
      copy.IsEnabled = clear.IsEnabled = sendFlow.IsEnabled = tab.Steps.Count > 0;
      record.Width = tab.Recording ? double.NaN : 26;
      record.Content = tab.Recording ? $"Recording · {tab.Steps.Count}" : new DeckIcon { Glyph = "\uE7C8", FontSize = 14 };
      if (tab.Recording) DeckMenu.Pill(record);
      record.Height = record.MinHeight = 26; record.CornerRadius = new(13);
      record.SetResourceReference(Control.ForegroundProperty, tab.Recording ? "DeckAgentRedBrush" : WorkspacePaper.Ink);
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(record, tab.Recording ? $"Stop recording · {tab.Steps.Count}" : "Record");
      inspect.Width = tab.Inspecting ? double.NaN : 26;
      inspect.Content = tab.Inspecting ? "Annotating" : new DeckIcon { Glyph = "\uE77A", FontSize = 14 };
      if (tab.Inspecting) DeckMenu.Pill(inspect);
      inspect.Height = inspect.MinHeight = 26; inspect.CornerRadius = new(13);
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
      failure.Visibility = tab.Failed || tab.Address.Length == 0 && !tab.NativePopup ? Visibility.Visible : Visibility.Collapsed; tab.View.Visibility = Visibility.Visible;
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
    tab.View.Visibility = Visibility.Visible;
    tab.View.CoreWebView2.NavigationCompleted += (_, _) => { address.Text = tab.Address; RefreshShellViews(); };
    tab.View.CoreWebView2.NavigationStarting += (_, _) => RefreshShellViews();
    tab.View.CoreWebView2.HistoryChanged += (_, _) => RefreshShellViews();
    shellViews.Add(id, panel); shellRefresh[id]();
    panel.SizeChanged += (_, _) => { if (shellRefresh.TryGetValue(id, out var refresh)) refresh(); };
    return panel;
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
    if (retainedPages.TryGetValue(tabId, out var retained))
    {
      Grid.SetRow(HandoverBar, 0); retained.Host.Children.Add(HandoverBar);
    }
    else if (Content is Grid engine) { Grid.SetRow(HandoverBar, 4); engine.Children.Add(HandoverBar); }
  }
  internal void ForgetShellView(string id) { shellViews.Remove(id); shellRefresh.Remove(id); shellObserved.Remove(id); }
}
