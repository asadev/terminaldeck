using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane : Grid
{
  private readonly ShellViewModel model;
  private readonly AppRuntime runtime;
  private readonly Grid content = new();
  private readonly ListView destinations = new() { ItemsSource = new[] { "Coding AIs", "Who uses what", "Devices & pairing", "MCP servers", "Outside AI apps" }, SelectionMode = ListViewSelectionMode.Single };
  internal bool PopupPresentation { get; set; }
  private bool selectingSection;
  private int renderRequest;
  private Task? renderTask;
  private CancellationTokenSource? renderCancellation;
  public event Action? RenderCompleted;
  public string SelectedSection => (string?)destinations.SelectedItem ?? "Coding AIs";
  public string? ActiveCode { get; private set; }
  public SettingsPane(ShellViewModel shell, AppRuntime services, int initialSection = 0, bool popupPresentation = false)
  {
    model = shell; runtime = services; PopupPresentation = popupPresentation;
    ColumnSpacing = 24;
    ColumnDefinitions.Add(new() { Width = new GridLength(190) });
    ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    Children.Add(destinations);
    var scroll = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(8, 8, 24, 24) };
    SetColumn(scroll, 1); Children.Add(scroll);
    destinations.SelectionChanged += async (_, _) => { if (!selectingSection) await RenderAsync(); };
    runtime.Changed += () => DispatcherQueue.TryEnqueueHandled(async () => { if (IsLoaded) await RenderAsync(); });
    runtime.Mcp.Changed += () => DispatcherQueue.TryEnqueueHandled(async () => { if (IsLoaded) await RenderAsync(); });
    runtime.Remote.Changed += () => DispatcherQueue.TryEnqueueHandled(async () => { if (IsLoaded) await RenderAsync(); });
    destinations.SelectedIndex = initialSection;
  }
  private void SelectIndex(int index)
  {
    selectingSection = true;
    try { destinations.SelectedIndex = index; } finally { selectingSection = false; }
  }
  public void SelectSection(int index)
  {
    if (index == 0) installations.Clear();
    SelectIndex(index); DispatcherQueue.TryEnqueueHandled(async () => await RenderAsync());
  }
  public Task SelectSectionAsync(int index) { if (index == 0) installations.Clear(); SelectIndex(index); return RenderAsync(); }
  internal void ActiveCodeForProofClear() => ActiveCode = null;
  public async Task ShowCodeAsync()
  {
    var offer = await runtime.Remote.ShowCodeAsync(); ActiveCode = offer.Code;
    await RenderAsync();
    _ = ExpireAsync(offer.Code, offer.ExpiresAt);
  }
  private async Task ExpireAsync(string code, DateTimeOffset expires)
  {
    await Task.Delay(expires - DateTimeOffset.UtcNow > TimeSpan.Zero ? expires - DateTimeOffset.UtcNow : TimeSpan.Zero);
    if (ActiveCode == code) { ActiveCode = null; await RenderAsync(); }
  }
  public Task RenderAsync()
  {
    renderRequest++; renderCancellation?.Cancel();
    if (renderTask is { IsCompleted: false }) return renderTask;
    var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    renderTask = done.Task; _ = RenderPendingAsync(done); return done.Task;
  }
  private async Task RenderPendingAsync(TaskCompletionSource done)
  {
    try
    {
      while (true)
      {
        var request = renderRequest;
        using var stop = new CancellationTokenSource(); renderCancellation = stop;
        try { await RenderSectionAsync(stop.Token); }
        catch (OperationCanceledException) when (stop.IsCancellationRequested && request != renderRequest) { }
        finally { renderCancellation = null; }
        if (request == renderRequest) { done.TrySetResult(); return; }
      }
    }
    catch (Exception ex) { done.TrySetException(ex); }
  }
  private async Task RenderSectionAsync(CancellationToken ct)
  {
    var section = destinations.SelectedIndex;
    content.Children.Clear();
    var stack = new StackPanel { Spacing = 20, MaxWidth = 700, HorizontalAlignment = HorizontalAlignment.Stretch };
    stack.Children.Add(new TextBlock { Text = PopupPresentation ? "Devices" : SelectedSection, FontSize = PopupPresentation ? 17 : 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    content.Children.Add(stack);
    switch (section)
    {
      case 0:
        stack.Children.Add(Description("Add as many accounts for each AI as you like: subscription logins (Sign in opens the AI’s own login and browser step) and API keys. Choose who uses which account under Who uses what."));
        await AddAccountRowsAsync(stack, ct);
        stack.Children.Add(Card("Account status", "Read each account’s current sign-in.", "Refresh", async () =>
        { await RefreshCodingAccountsAsync(); await RenderAsync(); }));
        stack.Children.Add(Card("SIGN-IN READINESS CHECK", "See the reply, model list, account switch and approval checks waiting for your sign-in. Opening this report sends no message.", "View readiness", ShowSignInReadinessAsync));
        stack.Children.Add(Description("When the CLI saves your sign-in, account status and models refresh here. Default follows your existing login in the real app. Test copies keep their own sign-ins. Open Accounts on an AI session to switch its saved conversation to another account for the same AI."));
        break;
      case 1:
        AddAssignmentRows(stack);
        break;
      case 2:
        AddDeviceRows(stack);
        break;
      case 3:
        await AddMcpRowsAsync(stack, ct);
        break;
      case 4:
        stack.Children.Add(Description("Connect each AI app with its own key, conversation and grants. Its own permission setting controls questions; planning mode cannot make changes."));
        stack.Children.Add(Card("Connect an AI app", "Grant one conversation and specific browser origins. Connection files stay in this preview’s private folder.", "Connect", ConnectAiAppAsync));
        await AddCallerRowsAsync(stack, ct);
        stack.Children.Add(Card("Remote app tools", runtime.RemoteToolsEnabled ? "Enabled until this app closes. Each connected AI keeps its own grants and permission flow." : "Off. Local connection tokens do not work over the relay.", runtime.RemoteToolsEnabled ? "Turn off" : "Enable remote tools", async () => { await runtime.SetRemoteToolsAsync(!runtime.RemoteToolsEnabled); await RenderAsync(); }));
        break;
    }
    ct.ThrowIfCancellationRequested();
    RenderCompleted?.Invoke();
    UpdateLayout();

    SettingsContentRendered?.Invoke();
  }
  private static TextBlock Description(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.7, MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Left };
  private Border Card(string title, string description, string action, Func<Task> clicked)
  {
    var feedback = new Notices.CompactNotice();
    var button = new Button { Content = action, VerticalAlignment = VerticalAlignment.Center };
    button.Click += async (_, _) =>
    {
      button.IsEnabled = false; feedback.Text = "Working…";
      try { await clicked(); feedback.Text = "Done."; }
      catch (Exception ex) when (ex is not OutOfMemoryException) { feedback.Text = ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "That action could not finish. Your sessions are still available."; }
      finally { button.IsEnabled = true; }
    };
    var card = (Border)Settings.SettingsPanel.SettingRow(title, description, button);
    if (card.Child is Grid row && row.Children.OfType<StackPanel>().FirstOrDefault() is { } words) words.Children.Add(feedback);
    return card;
  }
  private static void AddCardMenu(Border card, MenuFlyout menu, string label)
  {
    if (card.Child is not Grid row || row.Children.OfType<Button>().FirstOrDefault() is not { } action) return;
    row.Children.Remove(action);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
    actions.Children.Add(action);
    var more = new Button { Content = new DeckIcon { Glyph = "\uE712", FontSize = 14 }, Flyout = menu };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, label); ToolTipService.SetToolTip(more, label);
    actions.Children.Add(more); Grid.SetColumn(actions, 1); row.Children.Add(actions);
  }
  private async Task ConnectAiAppAsync()
  {
    var sessions = runtime.ProjectSessions().Where(s => s.Status is not ("Exited" or "exited" or "ended")).ToArray();
    if (sessions.Length == 0) throw new InvalidOperationException("Start a conversation before connecting an AI app.");
    var name = new TextBox { Header = "AI app name", MaxLength = 80 };
    var session = new ComboBox { Header = "Granted conversation", ItemsSource = sessions, DisplayMemberPath = "Title", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var mode = new ComboBox { Header = "Calling AI’s permission setting", ItemsSource = Enum.GetValues<AiPermissionMode>(), SelectedItem = AiPermissionMode.Ask, HorizontalAlignment = HorizontalAlignment.Stretch };
    var origins = new TextBox { Header = "Granted browser origins · one per line", AcceptsReturn = true, PlaceholderText = "https://example.com", MaxHeight = 160 };
    var relay = new CheckBox { Content = "Allow this key over the enabled relay", IsEnabled = runtime.RemoteToolsEnabled };
    var note = Description("Match the permission setting in the calling AI. Ask uses that AI’s own tool approval. This key cannot manage browser profiles, app security or other conversations. The key expires in eight hours or when this app closes.");
    var form = new StackPanel { Spacing = 16 }; foreach (var control in new UIElement[] { note, name, session, mode, origins, relay }) form.Children.Add(control);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Connect an AI app", Content = form, PrimaryButtonText = "Create connection", CloseButtonText = "Cancel" };
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try
      {
        if (string.IsNullOrWhiteSpace(name.Text)) throw new ArgumentException("Enter the AI app’s name.");
        var selected = (TerminalDeck.Core.Projects.ProjectSession)session.SelectedItem;
        var registration = runtime.ConnectCaller(name.Text.Trim(), selected.Id, (AiPermissionMode)mode.SelectedItem,
          origins.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries), relay.IsChecked == true);
        model.Notice = "Private connection saved in mcp/callers/" + registration.Id.ToString("N") + ".json. Use that file’s URL and key in this AI app’s MCP settings.";
      }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException or McpRefusal) { args.Cancel = true; note.Text = ex.Message; }
    };
    await dialog.ShowAsync();
  }
  private async Task ShowPhoneWorkspaceAsync(TerminalDeck.Core.Remote.ApprovedDevice device)
  {
    var pending = runtime.Remote.Trust.Pending().Any(d => d.Id == device.Id);
    var stack = new StackPanel { Spacing = 12 };
    stack.Children.Add(Description("Full control: this phone sees every session and chat on this PC, can open terminals and type, and can send Hoot messages. Work and Look only: it sees the sessions and Tasks of the projects ticked below. Hoot only: messages go through Hoot with limited tool access, and other pages stay private. Hoot's own settings stay on the computer."));
    var checks = runtime.Projects.List().Where(p => p.IsOpen && p.Folders.Length > 0).Select(p => (Project: p, Check: new CheckBox { Content = p.Name, IsChecked = runtime.TaskGrants.HasProject(device, p.Id) })).ToArray();
    foreach (var pair in checks) stack.Children.Add(pair.Check);
    var hoot = new CheckBox { Content = "Allow this phone to use Hoot", IsChecked = runtime.PhoneHootGrants.Allows(device, runtime.Hoot.Read()), IsEnabled = runtime.Hoot.Read().Settings is not null };
    stack.Children.Add(hoot);
    var levels = new[] { TerminalDeck.Core.Remote.PhoneAccess.Full, TerminalDeck.Core.Remote.PhoneAccess.Work, TerminalDeck.Core.Remote.PhoneAccess.Hoot, TerminalDeck.Core.Remote.PhoneAccess.Look };
    var access = new ComboBox { Header = "Device access", ItemsSource = new[] { "Full control", "Work", "Hoot only", "Look only" }, SelectedIndex = Array.IndexOf(levels, device.Access), HorizontalAlignment = HorizontalAlignment.Stretch };
    access.SelectionChanged += (_, _) => { var onlyHoot = access.SelectedIndex == 2; foreach (var pair in checks) pair.Check.Visibility = onlyHoot ? Visibility.Collapsed : Visibility.Visible; if (onlyHoot && hoot.IsEnabled) hoot.IsChecked = true; };
    stack.Children.Add(access);
    var feedback = new Notices.CompactNotice(); stack.Children.Add(feedback);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = device.Name + " · Workspace access", Content = new ScrollViewer { Content = stack, MaxHeight = 440 }, PrimaryButtonText = runtime.Remote.Trust.Pending().Any(d => d.Id == device.Id) ? "Let it in" : "Save", CloseButtonText = runtime.Remote.Trust.Pending().Any(d => d.Id == device.Id) ? "Not now" : "Cancel" };
    dialog.PrimaryButtonClick += (_, args) =>
    {
      try { runtime.SetPhoneWorkspace(device.Id, checks.Where(p => p.Check.IsChecked == true).Select(p => p.Project.Id).ToArray(), hoot.IsChecked == true, levels[Math.Clamp(access.SelectedIndex, 0, levels.Length - 1)]); }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException) { args.Cancel = true; feedback.Text = ex.Message; }
    };
    var result = await dialog.ShowAsync();
    if (result != ContentDialogResult.Primary && pending) runtime.Remote.Trust.DenyPending(device.Id);
    await RenderAsync();
  }
  private async Task ShowAddServerAsync()
  {
    var projects = runtime.Projects.List().SelectMany(p => p.Folders.Select(f => (p.Name, f))).ToArray();
    if (await McpServerForm.ShowAsync(runtime.Mcp, XamlRoot, ActualTheme, projects)) await RenderAsync();
  }
}
