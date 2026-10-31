using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Services;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Storage;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using TerminalDeck.Core.Browser;
using TerminalDeck.Platform.Windows;
using CoreProfile = TerminalDeck.Core.Browser.BrowserProfile;
using CoreState = TerminalDeck.Core.Browser.BrowserState;

namespace TerminalDeck.App.Views;

public sealed record BrowserProfile(string Id, string Name);
internal sealed class BrowserTab(string id, BrowserProfile profile, bool isolated, WebView2 view, BrowserViewModel model)
{
  public string Id { get; } = id;
  public BrowserProfile Profile { get; set; } = profile;
  public bool Isolated { get; } = isolated;
  public WebView2 View { get; } = view;
  public BrowserViewModel Model { get; } = model;
  public string Address { get; set; } = "";
  public string Title { get; set; } = "New tab";
  public string Status { get; set; } = "Opening page…";
  public bool Loading { get; set; }
  public double LoadProgress { get; set; }
  public bool Recording { get; set; }
  public bool StepsShown { get; set; }
  public string? AutomationOrigin { get; set; }
  public List<string> Steps { get; } = [];
  public double Zoom { get; set; } = 1;
  public BrowserViewport Viewport { get; set; } = BrowserViewport.Presets[0];
  public bool PhoneAgent { get; set; }
  public bool SizeEditing { get; set; }
  public bool FindShown { get; set; }
  public string FindText { get; set; } = "";
  public string FindResult { get; set; } = "";
  public bool Inspecting { get; set; }
  public int NextAnnotation { get; set; } = 1;
  public int SelectedAnnotation { get; set; }
  public List<BrowserAnnotation> Annotations { get; } = [];
  public string AnnotationDraft { get; set; } = "";
  public string FlowDraft { get; set; } = "";
  public string ShotDraft { get; set; } = "";
  public string? CapturePath { get; set; }
  public BrowserDrawing Drawing { get; } = new();
  public byte[]? DrawingImage { get; set; }
  public Action? DrawingChanged { get; set; }
  public SemaphoreSlim CaptureGate { get; } = new(1, 1);
  public bool Failed { get; set; }
  public bool StopRequested { get; set; }

}

public sealed partial class BrowserPane : UserControl
{
  internal void HideEngineChrome()
  {
    if (Content is not Grid layout) return;
    foreach (var child in layout.Children.OfType<FrameworkElement>().Where(c => Grid.GetRow(c) <= 1)) child.Visibility = Visibility.Collapsed;
    IsTabStop = false; TabFocusNavigation = Microsoft.UI.Xaml.Input.KeyboardNavigationMode.Once;
  }

  private readonly AppDataRoot root;
  private readonly Func<string, Task> send;
  private readonly List<BrowserTab> tabs = [];
  private readonly List<BrowserProfile> profiles = [new("default", "Default")];
  private BrowserTab? selected;
  private string defaultProfile = "default";
  private readonly WindowsBrowserProfileStorage storage;
  public BrowserModel Core { get; }
  private bool initialized;
  private bool disposed;
  private readonly TaskCompletionSource ready = new();
  public Task Ready => ready.Task;
  public int TabCount => tabs.Count;
  public string CurrentAddress => selected?.Address ?? "";
  internal string StatusForProof => BrowserStatus.Text;
  public bool IsRecording => selected?.Recording == true;
  public int StepCount => selected?.Steps.Count ?? 0;
  public BrowserPane(AppDataRoot dataRoot, Func<string, Task> sendContext)
  {
    InitializeComponent(); root = dataRoot; send = sendContext;
    var notice = new Notices.CompactNotice { Scope = this }; ((Grid)Content).Children.Add(notice);
    BrowserStatus.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) =>
    {
      notice.Message = BrowserStatus.Text;
      notice.IsOpen = BrowserStatus.Text is not ("Page ready" or "New tab" or "Loading page…" or "Opening page…" or "Opening browser…");
    });
    storage = new(root);
    Core = new(new JsonStateStore<CoreState>(root, "browser-core"), new SurfaceFactory(this), storage);
    Loaded += async (_, _) => { if (!initialized) { initialized = true; await GuardAsync(InitializeAsync); } };
    KeyDown += Browser_KeyDown;
    ActualThemeChanged += async (_, _) => await GuardAsync(ApplyBrowserThemeAsync);
  }

  private async Task InitializeAsync()
  {
    Pending.IsActive = true;
    await Core.RestoreAsync();
    SyncCore();
    if (tabs.Count == 0) await AddTabAsync();
    _ = WatchCoreAsync();
    Pending.IsActive = false; ready.TrySetResult();
    _ = RunBrowserProofIfRequestedAsync();
  }
  private async Task WatchCoreAsync()
  {
    await foreach (var _ in Core.Changes()) SyncCore();
  }
  private void SyncCore()
  {
    var state = Core.Read();
    profiles.Clear(); profiles.AddRange(state.Profiles.Select(p => new BrowserProfile(p.Id, p.Name)));
    defaultProfile = state.ActiveProfileId;
    foreach (var existing in tabs)
      if (profiles.FirstOrDefault(p => p.Id == existing.Profile.Id) is { } renamed) existing.Profile = renamed;
    if (tabs.FirstOrDefault(t => t.Id == state.SelectedTabId) is { } tab) Present(tab);
    RenderTabs();
  }
  public async Task AddTabAsync(BrowserProfile? profile = null, bool isolated = false, string address = "", string? restoredId = null)
  {
    var tab = await Core.OpenAsync(string.IsNullOrWhiteSpace(address) ? StartAddress : BrowserViewModel.ResolveAddress(address).AbsoluteUri, isolated, profile?.Id);
    SyncCore();
    Present(tabs.Single(t => t.Id == tab.Id));
  }
  private async ValueTask<IBrowserPage> CreatePageAsync(BrowserSurfaceOptions options, CancellationToken ct)
  {
    var profile = Core.Read().Profiles.Single(p => p.Id == options.ProfileId);
    var id = options.TabId; var isolated = options.Isolated;
    var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, storage.PathFor(options), null);
    var view = new WebView2(); SurfaceHost.Children.Add(view);
    var controller = environment.CreateCoreWebView2ControllerOptions();
    controller.ProfileName = "Deck"; controller.IsInPrivateModeEnabled = isolated;
    try { await view.EnsureCoreWebView2Async(environment, controller); }
    catch { SurfaceHost.Children.Remove(view); view.Close(); throw; }
    ct.ThrowIfCancellationRequested();
    if (disposed) { view.Close(); throw new IOException("The browser is closing."); }
    view.CoreWebView2.Settings.IsStatusBarEnabled = false;
    view.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
    view.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
    var tab = new BrowserTab(id, new BrowserProfile(profile.Id, profile.Name), isolated, view, new BrowserViewModel(new WebViewBrowserSurface(view, id))) { AutomationOrigin = options.AutomationOrigin };
    // Navigation cancellation can arrive after Chromium has followed a redirect.
    // Intercept before the network stack adds cookies/authentication headers.
    view.CoreWebView2.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
    view.CoreWebView2.WebResourceRequested += (_, args) =>
    {
      if (tab.AutomationOrigin is not { } origin) return;
      if (Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var destination) && destination.Scheme is "http" or "https" && destination.GetLeftPart(UriPartial.Authority) == origin) return;
      args.Response = environment.CreateWebResourceResponse(null, 403, "Origin not granted", "Content-Type: text/plain");
      SetTabStatus(tab, "The page request is outside the origin granted to its driver.");
    };
    view.CoreWebView2.NavigationStarting += async (_, args) =>
    {
      if (tab.AutomationOrigin is { } origin && Uri.TryCreate(args.Uri, UriKind.Absolute, out var automationDestination) && automationDestination.GetLeftPart(UriPartial.Authority) != origin) { args.Cancel = true; SetTabStatus(tab, "The page tried to leave the origin granted to its driver."); return; }
      if (!AllowedAddress(args.Uri))
      {
        args.Cancel = true;
        if (args.IsUserInitiated && Uri.TryCreate(args.Uri, UriKind.Absolute, out var external) && external.Scheme is not ("file" or "javascript" or "data" or "about"))
          await GuardAsync(async () => { if (!await Launcher.LaunchUriAsync(external)) throw new InvalidOperationException("Windows has no app registered for this link."); }, tab);
        else SetTabStatus(tab, "Only http and https pages can open here.");
        return;
      }
      tab.StopRequested = false;
      tab.Address = args.Uri == "https://start.deck.invalid/index.html" ? "" : args.Uri;
      tab.Failed = false; tab.Loading = true; tab.LoadProgress = 0.1; tab.Status = "Loading page…";
      if (selected == tab) { ReloadIcon.Glyph = "\uE711"; BrowserStatus.Text = tab.Status; }
    };
    view.CoreWebView2.ContentLoading += (_, _) => { tab.LoadProgress = 0.45; RefreshShellViews(); };
    view.CoreWebView2.DOMContentLoaded += (_, _) => { tab.LoadProgress = 0.8; RefreshShellViews(); };
    view.CoreWebView2.NavigationCompleted += async (_, args) =>
    {
      tab.Address = view.CoreWebView2.Source;
      if (tab.Address is "about:blank" or "https://start.deck.invalid/index.html") tab.Address = "";
      var stopped = tab.StopRequested && args.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled;
      tab.Failed = !args.IsSuccess && !stopped; tab.Loading = false; tab.LoadProgress = 1; tab.Status = stopped ? "Loading stopped." : args.IsSuccess ? (tab.Address.Length == 0 ? "New tab" : "Page ready") : "Page could not load. Check the address or reload to try again.";
      if (selected == tab) { UpdateChrome(); BrowserStatus.Text = tab.Status; }
      if (tab.Recording)
      {
        if (args.IsSuccess && Uri.TryCreate(tab.Address, UriKind.Absolute, out var destination) && destination.Scheme is "http" or "https" && tab.Steps.Count < 200)
          tab.Steps.Add($"{tab.Steps.Count + 1}. navigate: {destination.Scheme}://{destination.Authority} (path and query omitted)");
        await GuardAsync(() => InstallRecorderAsync(tab), tab);
        if (tab.Steps.Count >= 200) { tab.Recording = false; SetTabStatus(tab, "Recording stopped: the 200-step limit was reached."); }
        if (selected == tab) UpdateChrome();
      }
      if (args.IsSuccess && tab.Inspecting) await GuardAsync(() => InspectAsync(tab, true), tab);
      RefreshShellViews();
      await ObserveAsync(tab);
    };
    view.CoreWebView2.DocumentTitleChanged += async (_, _) => { tab.Title = view.CoreWebView2.DocumentTitle; RenderTabs(); await ObserveAsync(tab); };
    view.CoreWebView2.HistoryChanged += (_, _) => { if (selected == tab) UpdateChrome(); };
    view.CoreWebView2.NewWindowRequested += async (_, args) =>
    {
      args.Handled = true;
      if (!AllowedAddress(args.Uri)) { SetTabStatus(tab, "Only http and https pages can open here."); return; }
      // Core checks the source pin before creating a view, and passes that pin
      // to the popup before its first navigation (including redirects).
      var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
      var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
      var middle = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.MiddleButton).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
      var background = args.IsUserInitiated && !shift && (control || middle);
      await GuardAsync(async () =>
      {
        var made = await Core.OpenPopupAsync(tab.Id, args.Uri);
        if (background) await Core.SelectAsync(tab.Id);
        SyncCore(); ObserveShellPages(); ShellChanged?.Invoke();
        if (!background) ShellSelected?.Invoke(made.Id);
      }, tab);
    };
    view.CoreWebView2.PermissionRequested += (_, args) => { args.State = CoreWebView2PermissionState.Deny; SetTabStatus(tab, "This preview does not grant camera, microphone or location access."); };
    view.CoreWebView2.DownloadStarting += (_, args) => StartDownload(tab, args);
    view.CoreWebView2.WindowCloseRequested += async (_, _) => await GuardAsync(() => CloseAsync(tab), tab);
    view.CoreWebView2.ProcessFailed += (_, args) =>
    {
      if (args.ProcessFailedKind is CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive or CoreWebView2ProcessFailedKind.BrowserProcessExited)
      { tab.Failed = true; tab.Loading = false; SetTabStatus(tab, "The page process stopped. Try again, or open a new tab."); }
    };
    view.CoreWebView2.WebMessageReceived += (_, args) =>
    {
      if (args.Source != view.CoreWebView2.Source) return;

      try
      {
        using var message = JsonDocument.Parse(args.WebMessageAsJson);
        var data = message.RootElement;
        if (data.GetProperty("kind").GetString() == "td-inspect") { ReceiveAnnotation(tab, data); return; }
        if (!tab.Recording || tab.Steps.Count >= 200 || data.GetProperty("kind").GetString() != "td-record") return;
        var action = data.GetProperty("action").GetString();
        var target = data.GetProperty("target").GetString() ?? "element";
        if (action is not ("click" or "entry") || target.Length > 200 || target.Any(char.IsControl)) return;
        // All entered values are omitted, including ordinary text, so secrets never reach the flow.
        tab.Steps.Add($"{tab.Steps.Count + 1}. {action}: {target}" + (action == "entry" ? " (value omitted)" : ""));
        if (tab.Steps.Count >= 200) { tab.Recording = false; SetTabStatus(tab, "Recording stopped: the 200-step limit was reached. Copy, send or clear this flow."); }
        if (selected == tab) UpdateChrome();
        else RefreshShellViews();
      }
      catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { /* Untrusted page messages carry no authority. */ }
    };
    tabs.Add(tab);
    await ApplyBrowserThemeAsync();
    view.CoreWebView2.SetVirtualHostNameToFolderMapping("start.deck.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "browser"), CoreWebView2HostResourceAccessKind.DenyCors);
    await RebindRetainedPageAsync(tab);
    DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => ObserveShellPages());
    return new Page(this, tab);
  }
  private void SetTabStatus(BrowserTab tab, string message)
  {
    tab.Status = message;
    if (selected == tab) BrowserStatus.Text = message;
    RefreshShellViews();
  }
  private async Task ObserveAsync(BrowserTab tab)
  {
    if (disposed || !Core.Read().Tabs.Any(t => t.Id == tab.Id)) return;
    try { await Core.ObserveNavigationAsync(tab.Id, string.IsNullOrEmpty(tab.Address) ? "https://start.deck.invalid/index.html" : tab.Address, tab.Title); }
    catch (Exception ex) when (ex is IOException or ArgumentException or ObjectDisposedException) { SetTabStatus(tab, "The page details could not be saved."); }
  }
  private static bool AllowedAddress(string address) => address == "about:blank" || (Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && string.IsNullOrEmpty(uri.UserInfo));
  private void Select(BrowserTab tab) => _ = SelectCoreAsync(tab);
  private async Task SelectCoreAsync(BrowserTab tab) { await Core.SelectAsync(tab.Id); Present(tab); }
  private void Present(BrowserTab tab)
  {
    selected = tab;
    foreach (var item in tabs) item.View.Visibility = item == tab ? Visibility.Visible : Visibility.Collapsed;
    UpdateChrome(); BrowserStatus.Text = tab.Status; RenderTabs();
  }
  private void UpdateChrome()
  {
    RefreshShellViews();
    if (selected is null) return;
    Address.Text = selected.Address;
    Back.IsEnabled = selected.View.CoreWebView2.CanGoBack;
    Forward.IsEnabled = selected.View.CoreWebView2.CanGoForward;
    Reload.IsEnabled = true;
    ReloadIcon.Glyph = selected.Loading ? "\uE711" : "\uE72C";
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Reload, selected.Loading ? "Stop loading" : "Reload page");
    ProfileButton.Content = selected.Isolated ? new DeckIcon { Glyph = "\uE72E", FontSize = 14 } : System.Globalization.StringInfo.GetNextTextElement(selected.Profile.Name).ToUpperInvariant();
    ToolTipService.SetToolTip(ProfileButton, (selected.Isolated ? "Private · " : "Profile · ") + selected.Profile.Name);
    RecordLabel.Text = selected.Recording ? "Stop" : "Record";
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(RecordButton, selected.Recording ? "Stop recording" : "Record");
    RecordIcon.Glyph = selected.Recording ? "\uE71A" : "\uEA3A";
    StepsLabel.Text = selected.Steps.Count > 0 ? $"Steps · {selected.Steps.Count}" : "Steps";
    RecordedPanel.Visibility = selected.StepsShown ? Visibility.Visible : Visibility.Collapsed;
    RecordedHeading.Text = selected.Recording ? "Recording" : $"Recorded steps · {selected.Steps.Count}";
    RecordedText.Text = selected.Steps.Count > 0 ? string.Join('\n', selected.Steps) : selected.Recording ? "Use the page — clicks, entries and navigation appear here. Typed values are omitted." : "No steps yet. Start Record, then interact with the page.";
    CopyStepsButton.IsEnabled = ClearStepsButton.IsEnabled = selected.Steps.Count > 0;
  }
  private void RenderTabs()
  {
    TabRail.Children.Clear();
    foreach (var tab in tabs)
    {
      var row = new Grid { ColumnSpacing = 2 };
      row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
      row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
      var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
      label.Children.Add(new DeckIcon { Glyph = tab.Isolated ? "\uE72E" : "\uE774", FontSize = 12 });
      label.Children.Add(new TextBlock { Text = string.IsNullOrWhiteSpace(tab.Title) ? "New tab" : tab.Title, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 160, FontSize = 12 });
      var button = new Button { Content = label, Background = null, Padding = new Thickness(10, 5, 2, 5), MinHeight = 30, HorizontalAlignment = HorizontalAlignment.Stretch };
      button.Click += (_, _) => Select(tab);
      ToolTipService.SetToolTip(button, tab.Title);
      var close = new Button { Content = new DeckIcon { Glyph = "\uE711", FontSize = 10 }, Background = null, MinWidth = 28, MinHeight = 28, Padding = new Thickness(6), VerticalAlignment = VerticalAlignment.Center };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close, "Close " + tab.Title);
      close.Click += async (_, _) => await GuardAsync(() => CloseAsync(tab));
      row.Children.Add(button); Grid.SetColumn(close, 1); row.Children.Add(close);
      var capsule = new Border { Child = row, CornerRadius = new CornerRadius(9), Opacity = selected == tab ? 1 : 0.65 };
      // A theme resource expression keeps the selected tab correct after an appearance switch.
      if (selected == tab) capsule.Style = (Style)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"Border\"><Setter Property=\"Background\" Value=\"{ThemeResource DeckCardBrush}\"/></Style>");
      TabRail.Children.Add(capsule);
    }
    var add = new Button { Content = new DeckIcon { Glyph = "\uE710", FontSize = 12 }, Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"] };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(add, "New browser tab");
    add.Click += async (_, _) => await GuardAsync(() => AddTabAsync());
    TabRail.Children.Add(add);
  }
  private async Task CloseAsync(BrowserTab tab)
  {
    await Core.CloseAsync(tab.Id);
    if (tabs.Count == 0) { selected = null; BrowserStatus.Text = "This browser tab is closed"; Address.Text = ""; Back.IsEnabled = Forward.IsEnabled = Reload.IsEnabled = false; }
    else Present(tabs.Single(t => t.Id == Core.Read().SelectedTabId));
    ShellChanged?.Invoke();
    SyncCore();
  }
  public async Task ExecuteAsync(string command, string? argument = null)
  {
    var tab = selected ?? throw new InvalidOperationException("The browser is still opening.");
    await Core.TakeHumanControlAsync(tab.Id); await ExecuteTabAsync(tab, command, argument);
  }
  private async Task ExecuteTabAsync(BrowserTab tab, string command, string? argument = null)
  {
    switch (command)
    {
      case "navigate": await Core.NavigateAsync(tab.Id, BrowserViewModel.ResolveAddress(argument ?? "").AbsoluteUri); break;
      case "back": if (tab.View.CoreWebView2.CanGoBack) tab.View.CoreWebView2.GoBack(); break;
      case "forward": if (tab.View.CoreWebView2.CanGoForward) tab.View.CoreWebView2.GoForward(); break;
      case "home": await Core.NavigateAsync(tab.Id, StartAddress); break;
      case "reload":
        if (argument == "bypass") await tab.Model.CommandAsync("Page.reload", new { ignoreCache = true });
        else tab.View.CoreWebView2.Reload(); break;
      case "stop": tab.StopRequested = true; tab.View.CoreWebView2.Stop(); break;
      case "inspect": await InspectAsync(tab, !tab.Inspecting); break;
      case "devtools": tab.View.CoreWebView2.OpenDevToolsWindow(); tab.Status = "Developer tools opened for this tab."; break;
      case "shot": await ShotAsync(tab); break;
      case "draw": await DrawAsync(tab); break;
      case "size":
        if (argument == "fill") tab.Viewport = BrowserViewport.Presets[0];
        else
        {
          var parts = (argument ?? "").Split('x');
          if (parts.Length != 2 || !int.TryParse(parts[0], out var width) || !int.TryParse(parts[1], out var height)) throw new ArgumentException("Choose a width and height between 240 and 3840.");
          tab.Viewport = BrowserViewport.Custom(width, height);
        }
        await ApplyViewportAsync(tab); break;
      case "record":
        tab.Recording = !tab.Recording;
        if (tab.Recording) { tab.StepsShown = true; await InstallRecorderAsync(tab); }
        else await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.__tdRecordOn=false" });
        tab.Status = tab.Recording ? "Recording clicks, entries and navigation. Typed values are omitted." : $"Recording stopped. {tab.Steps.Count} steps kept."; UpdateChrome(); break;
      case "send":
        var result = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "({title:document.title,selection:String(getSelection()).slice(0,4000)})", returnByValue = true });
        var context = result.GetProperty("result").GetProperty("value");
        var address = Uri.TryCreate(tab.Address, UriKind.Absolute, out var url) ? url.GetLeftPart(UriPartial.Path) : "New tab";
        var outcome = await ReviewSendAsync(tab, BrowserContext.Create(address, context.GetProperty("title").GetString() ?? "", context.GetProperty("selection").GetString() ?? ""));
        tab.Status = outcome == BrowserSendOutcome.Sent ? "Page context sent." : "Page context reviewed. Your send window keeps any unsent draft."; break;
      default: throw new ArgumentException("That browser action is not available.");
    }
    if (selected == tab) BrowserStatus.Text = tab.Status;
    RefreshShellViews();
  }
  private static Task InstallRecorderAsync(BrowserTab tab) => tab.Model.CommandAsync("Runtime.evaluate", new { expression = RecorderScript });
  private async Task GuardAsync(Func<Task> action, BrowserTab? tab = null)
  {
    try { await action(); }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      var message = ex is ArgumentException or InvalidOperationException ? ex.Message : "The browser action failed. Try again or open a new tab.";
      if ((tab ?? selected) is { } target) SetTabStatus(target, message); else BrowserStatus.Text = message;
      Pending.IsActive = false;
      if (!ready.Task.IsCompleted) ready.TrySetException(new IOException("The browser could not start."));
    }
  }
  private async void Address_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Escape) { Address.Text = selected?.Address ?? ""; e.Handled = true; } if (e.Key == VirtualKey.Enter) { e.Handled = true; await GuardAsync(() => ExecuteAsync("navigate", Address.Text)); } }
  private async void Back_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync("back"));
  private async void Forward_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync("forward"));
  private async void Reload_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync(selected?.Loading == true ? "stop" : "reload", Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down) ? "bypass" : null));
  private async void Inspect_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync("inspect"));
  private async void Record_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync("record"));
  private async void Send_Click(object sender, RoutedEventArgs e) => await GuardAsync(() => ExecuteAsync("send"));
  private void Profiles_Click(object sender, RoutedEventArgs e) { if (selected is not null) ProfileMenu(selected).ShowAt(ProfileButton); }
  private async void Size_Click(object sender, RoutedEventArgs e) { if (selected is not null) await GuardAsync(() => ShowSizeAsync(selected)); }
  private void Steps_Click(object sender, RoutedEventArgs e)
  {
    if (selected is null) return;
    selected.StepsShown = selected.Recording || !selected.StepsShown; UpdateChrome();
  }
  private void HideSteps_Click(object sender, RoutedEventArgs e) { if (selected is { Recording: false }) selected.StepsShown = false; UpdateChrome(); }
  private void CopySteps_Click(object sender, RoutedEventArgs e)
  {
    if (selected is null || selected.Steps.Count == 0) return;
    var data = new DataPackage(); data.SetText(string.Join('\n', selected.Steps)); Clipboard.SetContent(data);
    BrowserStatus.Text = "Recorded steps copied.";
  }
  private void ClearSteps_Click(object sender, RoutedEventArgs e) { selected?.Steps.Clear(); UpdateChrome(); }
  private async void Browser_KeyDown(object sender, KeyRoutedEventArgs e)
  {
    var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    if (!control || e.Handled) return;
    var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    switch (e.Key)
    {
      case VirtualKey.L: Address.Focus(FocusState.Programmatic); Address.SelectAll(); e.Handled = true; break;
      case VirtualKey.T: e.Handled = true; await GuardAsync(() => AddTabAsync()); break;
      case VirtualKey.N when shift: e.Handled = true; await GuardAsync(() => AddTabAsync(selected?.Profile, true)); break;
      case VirtualKey.W when selected is not null: e.Handled = true; await GuardAsync(() => CloseAsync(selected)); break;
      case VirtualKey.R: e.Handled = true; await GuardAsync(() => ExecuteAsync("reload")); break;
      case VirtualKey.Tab when selected is not null:
        e.Handled = true; Select(tabs[(tabs.IndexOf(selected) + (shift ? tabs.Count - 1 : 1)) % tabs.Count]); break;
    }
  }
  internal async Task SetSurfaceThemeAsync(ElementTheme theme)
  {
    RequestedTheme = theme;
    foreach (var tab in tabs) tab.View.RequestedTheme = theme;
    await ApplyBrowserThemeAsync();
  }
  private async Task ApplyBrowserThemeAsync()
  {
    var dark = ActualTheme == ElementTheme.Dark;
    foreach (var tab in tabs)
    {
      tab.View.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
      tab.View.CoreWebView2.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
      await tab.Model.CommandAsync("Emulation.setEmulatedMedia", new { features = new[] { new { name = "prefers-color-scheme", value = dark ? "dark" : "light" } } });
    }
  }
  internal Task NavigateForProofAsync(string address) => NavigateCommandForProofAsync("navigate", address);
  internal async Task NavigateCommandForProofAsync(string command, string? argument = null)
  {
    if (selected is null) throw new InvalidOperationException("Browser is not ready.");
    var completion = new TaskCompletionSource();
    void Completed(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
      if (args.IsSuccess) completion.TrySetResult();
      else completion.TrySetException(new IOException("The local fixture could not load."));
    }
    var core = selected.View.CoreWebView2;
    core.NavigationCompleted += Completed;
    try { await ExecuteAsync(command, argument); await completion.Task.WaitAsync(TimeSpan.FromSeconds(20)); }
    finally { core.NavigationCompleted -= Completed; }
  }
  internal Task<JsonElement> EvaluateForProofAsync(string expression) => selected!.Model.CommandAsync("Runtime.evaluate", new { expression, returnByValue = true });
  internal Task CloseSelectedForProofAsync() => CloseAsync(selected!);
  internal string[] StepsForProof() => selected!.Steps.ToArray();
  internal string ProfileForProof() => selected!.View.CoreWebView2.Profile.ProfileName;
  internal bool PrivateForProof() => selected!.View.CoreWebView2.Profile.IsInPrivateModeEnabled;

  public void DisposeViews()
  {
    disposed = true; _ = Core.DisposeAsync();
  }
  private sealed class SurfaceFactory(BrowserPane owner) : IBrowserSurfaceFactory
  {
    public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken ct) => owner.CreatePageAsync(options, ct);
  }
  private sealed class Page(BrowserPane owner, BrowserTab tab) : IBrowserPage
  {
    public string TabId => tab.Id;
    public async Task NavigateAsync(Uri address, CancellationToken ct = default)
    {
      var done = new TaskCompletionSource();
      void Completed(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
      { done.TrySetResult(); }
      tab.View.CoreWebView2.NavigationCompleted += Completed;
      try { tab.View.CoreWebView2.Navigate(address.AbsoluteUri); await done.Task.WaitAsync(TimeSpan.FromSeconds(30), ct); }
      finally { tab.View.CoreWebView2.NavigationCompleted -= Completed; }
    }
    public Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken ct = default) => tab.Model.CommandAsync(method, arguments);
    public ValueTask ReloadAsync(bool bypassCache, CancellationToken ct) => new(owner.ExecuteTabAsync(tab, "reload", bypassCache ? "bypass" : null));
    public async ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement args, CancellationToken ct)
    {
      string? Text(string key) => args.TryGetProperty(key, out var v) ? v.GetString() : null;
      switch (action)
      {
        case BrowserPageAction.TakeOver: tab.AutomationOrigin = null; owner.RefreshShellViews(); break;
        case BrowserPageAction.WorkspaceRead: return owner.ReadWorkspace(tab, args);
        case BrowserPageAction.WorkspaceChange: return await owner.ChangeWorkspaceAsync(tab, args);
        case BrowserPageAction.Read:
          var timeout = args.TryGetProperty("timeoutMs", out var wait) ? Math.Clamp(wait.GetInt32(), 1, 30000) : 5000;
          var until = DateTimeOffset.UtcNow.AddMilliseconds(timeout);
          var query = args.TryGetProperty("waitFor", out var waitFor) ? JsonSerializer.SerializeToElement(new { selector = waitFor.GetString() }) : args;
          while (true)
          {
            var found = await EvaluateAsync(BrowserAutomation.ReadScript(query));
            if (found.GetProperty("found").GetBoolean()) break;
            if (DateTimeOffset.UtcNow >= until) throw new InvalidOperationException("The requested page element did not appear.");
            await Task.Delay(100, ct);
          }
          return await EvaluateAsync(BrowserAutomation.ReadScript(args));
        case BrowserPageAction.Step:
          tab.AutomationOrigin = new Uri(tab.View.CoreWebView2.Source).GetLeftPart(UriPartial.Authority); owner.RefreshShellViews();
          var stepped = await EvaluateAsync(BrowserAutomation.StepScript(args));
          if (Text("verb") == "press")
          {
            var key = Text("key") ?? throw new ArgumentException("Choose a key.");
            var code = key switch { "Enter" => 13, "Tab" => 9, "Escape" => 27, "Backspace" => 8, "Delete" => 46, "ArrowDown" => 40, "ArrowUp" => 38, "ArrowLeft" => 37, "ArrowRight" => 39, _ => throw new ArgumentException("Choose a listed key.") };
            await tab.Model.CommandAsync("Input.dispatchKeyEvent", new { type = "keyDown", key, windowsVirtualKeyCode = code, text = key == "Enter" ? "\r" : "" });
            await tab.Model.CommandAsync("Input.dispatchKeyEvent", new { type = "keyUp", key, windowsVirtualKeyCode = code });
          }
          return stepped;
        case BrowserPageAction.Screenshot:
          var captured = await CaptureAsync(tab);
          return JsonSerializer.SerializeToElement(new { url = tab.View.CoreWebView2.Source, mimeType = "image/png", data = Convert.ToBase64String(captured), privateFieldsHidden = true });
        case BrowserPageAction.Handover:
          var continued = await owner.HandoverAsync(tab.Id, Text("prompt") ?? "Finish the step in the page, then carry on.", ct);
          return JsonSerializer.SerializeToElement(new { url = tab.View.CoreWebView2.Source, continued });
        case BrowserPageAction.Reveal:
          throw new InvalidOperationException("Captures are returned directly. Save the returned PNG before opening its folder.");
        case BrowserPageAction.Back: case BrowserPageAction.Forward: case BrowserPageAction.Stop:
          await owner.ExecuteTabAsync(tab, action.ToString().ToLowerInvariant()); break;
        case BrowserPageAction.Inspect: await owner.InspectAsync(tab, !args.TryGetProperty("on", out var inspectOn) || inspectOn.GetBoolean()); break;
        case BrowserPageAction.DevTools: await owner.ExecuteTabAsync(tab, "devtools"); break;
        case BrowserPageAction.Size:
          await owner.ExecuteTabAsync(tab, "size", args.TryGetProperty("width", out var width) && args.TryGetProperty("height", out var height) ? $"{width.GetInt32()}x{height.GetInt32()}" : "fill"); break;
        case BrowserPageAction.Send: await owner.ExecuteTabAsync(tab, "send"); break;
        case BrowserPageAction.Record:
          var on = !args.TryGetProperty("on", out var requested) || requested.GetBoolean();
          if (tab.Recording != on) await owner.ExecuteTabAsync(tab, "record"); break;
        case BrowserPageAction.Recording: return JsonSerializer.SerializeToElement(new { on = tab.Recording, steps = tab.Steps });
        case BrowserPageAction.RecordClear: tab.Steps.Clear(); owner.UpdateChrome(); break;
        case BrowserPageAction.Zoom: await owner.SetZoomAsync(tab, args.GetProperty("factor").GetDouble()); break;
        case BrowserPageAction.Find:
          await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.find(" + JsonSerializer.Serialize(Text("text") ?? "") + ",false," + (args.TryGetProperty("backwards", out var backwards) && backwards.GetBoolean() ? "true" : "false") + ")" }); break;
        case BrowserPageAction.FindStop: await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "getSelection().removeAllRanges()" }); break;
        case BrowserPageAction.Print: tab.View.CoreWebView2.ShowPrintUI(CoreWebView2PrintDialogKind.Browser); break;
        case BrowserPageAction.UserAgent: await tab.Model.CommandAsync("Network.setUserAgentOverride", new { userAgent = Text("userAgent") ?? "" }); break;
        default: throw new InvalidOperationException("This page action is not connected yet.");
      }
      return JsonSerializer.SerializeToElement(new { done = true });
    }
    private async Task<JsonElement> EvaluateAsync(string script)
    {
      var result = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = script, returnByValue = true });
      if (result.TryGetProperty("exceptionDetails", out _)) throw new InvalidOperationException("The page element could not be used. Check its selector and try again.");
      return result.GetProperty("result").GetProperty("value").Clone();
    }
    public ValueTask DisposeAsync()
    { owner.StageReplacement(tab); owner.ForgetShellView(tab.Id); owner.tabs.Remove(tab); if (tab.View.Parent is Panel parent) parent.Children.Remove(tab.View); tab.View.Close(); return ValueTask.CompletedTask; }
  }
  private TaskCompletionSource<bool>? handover;
  private async Task<bool> HandoverAsync(string tabId, string prompt, CancellationToken ct)
  {
    if (handover is not null) throw new InvalidOperationException("Finish the current page handover first.");
    handover = new(TaskCreationOptions.RunContinuationsAsynchronously); HandoverPrompt.Text = prompt; HandoverBar.Visibility = Visibility.Visible;
    ShowShellHandover(tabId);
    try { return await handover.Task.WaitAsync(ct); }
    finally { HandoverBar.Visibility = Visibility.Collapsed; handover = null; }
  }
  private void HandoverContinue_Click(object sender, RoutedEventArgs args) => handover?.TrySetResult(true);
  private void HandoverStop_Click(object sender, RoutedEventArgs args) => handover?.TrySetResult(false);
  private const string RecorderScript = """
(()=>{window.__tdRecordOn=true;if(window.__tdRecorderInstalled)return;window.__tdRecorderInstalled=true;const report=(action,e)=>{if(!window.__tdRecordOn)return;let t=e.target;if(!(t instanceof Element))return;if(t.closest('input[type=password],[autocomplete*=password],[autocomplete*=cc-]'))return;const selector=[];for(let n=t;n&&selector.length<5;n=n.parentElement){const tag=n.tagName.toLowerCase();const peers=n.parentElement?[...n.parentElement.children].filter(x=>x.tagName===n.tagName):[n];selector.unshift(tag+':nth-of-type('+(peers.indexOf(n)+1)+')');}window.chrome.webview.postMessage({kind:'td-record',action,target:selector.join(' > ')});};document.addEventListener('click',e=>report('click',e),true);document.addEventListener('change',e=>report('entry',e),true);})();
""";
}
