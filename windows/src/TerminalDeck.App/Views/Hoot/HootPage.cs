using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views.Hoot;

public sealed record HootSessionChoice(string Id, string Title);

// Shell supplies its account list, live sessions and existing window actions.
// There is deliberately no island, floating window or notification-area icon.
public sealed class HootPage : Grid, IDisposable
{
  public HootViewModel Model { get; }
  private readonly Func<IReadOnlyList<AccountProfile>> accounts;
  private readonly Func<IReadOnlyList<HootSessionChoice>> sessions;
  private readonly Action<string>? openSession;
  private readonly Action? openCodingAis;
  private readonly Func<string, Task>? signIn;
  private readonly StackPanel messages = new() { Spacing = 20, MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Center };
  private readonly ScrollViewer history;
  private readonly TextBlock status = Words("Awake", 14);
  private readonly Notices.CompactNotice feedback = new();
  private readonly TextBox composer = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 36, MaxHeight = 180, MaxLength = 64000, PlaceholderText = "Message Hoot" };
  private readonly Button send; // not shown: Enter sends; carries the can-send state
  private readonly ComposerEnter enter = new();
  private readonly Button stop;
  private readonly Button resume;
  private readonly ProgressBar pending = new() { IsIndeterminate = true, Height = 3, Visibility = Visibility.Collapsed };
  private readonly Button modelChip = new() { MinHeight = 28, MaxWidth = 220 };
  private readonly Button accountChip = new() { MinHeight = 28, MaxWidth = 180 };
  private readonly StackPanel dock = new() { Spacing = 8, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
  private readonly StackPanel sections = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
  private string selectedSection = "Chat";
  private HootMemory? renderedMemory;
  private string? cardDraft;
  private string? playbookDraft;
  private int visibleMessages = 300;
  private long renderedSequence = -1;
  private string renderedChanges = "";
  // The "/" menu's list (the shell supplies it from Hoot's chat, folder and account).
  public Func<IReadOnlyList<ChatSlashCommand>>? SlashCommands { get; init; }
  public HootPage(IHoot hoot, Func<IReadOnlyList<AccountProfile>> accounts, Func<IReadOnlyList<HootSessionChoice>> sessions, Action<string>? openSession = null, Action? openCodingAis = null, Func<string, Task>? signIn = null)
  {
    this.accounts = accounts; this.sessions = sessions; this.openSession = openSession; this.openCodingAis = openCodingAis; this.signIn = signIn;
    Model = new(hoot, action => DispatcherQueue.TryEnqueueHandled(() => action()));
    Resources = (ResourceDictionary)XamlReader.Load("""
      <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
        <Style x:Key="Canvas" TargetType="Grid"><Setter Property="Background" Value="{ThemeResource SolidBackgroundFillColorBaseBrush}"/></Style>
        <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="{ThemeResource CardBackgroundFillColorDefaultBrush}"/><Setter Property="CornerRadius" Value="16"/><Setter Property="Padding" Value="16"/></Style>
        <Style x:Key="Person" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckSelectionBrush}"/><Setter Property="CornerRadius" Value="18,18,6,18"/><Setter Property="Padding" Value="14"/></Style>
        <Style x:Key="PersonText" TargetType="TextBlock"><Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}"/><Setter Property="Foreground" Value="{ThemeResource TextFillColorPrimaryBrush}"/></Style>
        <Style x:Key="Glass" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckGlassBrush}"/><Setter Property="CornerRadius" Value="22"/><Setter Property="Padding" Value="16"/></Style>
      </ResourceDictionary>
      """);
    Style = (Style)Resources["Canvas"]; Padding = new Thickness(24, 16, 24, 16); RowSpacing = 12;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto });
    var toolbar = new Grid { ColumnSpacing = 8 };
    toolbar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var identity = new StackPanel { Spacing = 2 };
    identity.Children.Add(new TextBlock { Text = "Hoot", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    identity.Children.Add(status);
    var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
    heading.Children.Add(ChatAppearance.Avatar("hoot", 38)); heading.Children.Add(identity); toolbar.Children.Add(heading);
    var menu = new MenuFlyout(); var options = new Button { Content = "Hoot settings", Flyout = menu, MinHeight = 40 };
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    actions.Children.Add(ActionButton("New chat", NewChatAsync));
    ChatAppearance.IconButton(options, "\uE713", "Hoot settings"); actions.Children.Add(options); SetColumn(actions, 1); toolbar.Children.Add(actions);
    var header = new StackPanel { Spacing = 12 }; header.Children.Add(toolbar);
    foreach (var name in new[] { "Chat", "Desk", "Playbook", "History" })
    {
      var tab = ActionButton(name, () => { SelectSection(name); return Task.CompletedTask; });
      AutomationProperties.SetAutomationId(tab, "hoot.section." + name.ToLowerInvariant()); sections.Children.Add(tab);
    }
    foreach (var name in new[] { "Chat", "Desk", "Playbook", "History" })
    { var route = name; AddMenu(menu, route, () => { SelectSection(route); return Task.CompletedTask; }); }
    Children.Add(header);
    AddMenu(menu, "Hoot settings", ShowSettingsAsync); AddMenu(menu, "Context handoff", ShowHandoffAsync); AddMenu(menu, "Background turns", ShowBackgroundAsync);
    history = new() { Content = messages, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled };
    history.SizeChanged += (_, _) => messages.Width = Math.Max(0, Math.Min(760, history.ActualWidth)); SetRow(history, 1); Children.Add(history);
    AutomationProperties.SetAutomationId(history, "hoot.history");
    var keep = ActionButton("Keep unconfirmed turn without sending again", () => Model.KeepUnconfirmedAsync());
    Model.PropertyChanged += (_, _) => { keep.Visibility = Model.State.Turns.Any(t => t.State == HootTurnState.Uncertain) ? Visibility.Visible : Visibility.Collapsed; keep.IsEnabled = !Model.Pending; };
    keep.Visibility = Model.State.Turns.Any(t => t.State == HootTurnState.Uncertain) ? Visibility.Visible : Visibility.Collapsed;
    var outcomes = new StackPanel { Spacing = 8 }; outcomes.Children.Add(feedback); outcomes.Children.Add(keep); outcomes.Children.Add(pending); SetRow(outcomes, 2); Children.Add(outcomes);
    // Mac "/" menu: Hoot's own AI commands and the skills of Hoot's working folder.
    var slash = new SlashCommandMenu(composer, () => SlashCommands?.Invoke() ?? Array.Empty<ChatSlashCommand>(), async () =>
    {
      if (Model.Pending || Model.State.Settings is null || string.IsNullOrWhiteSpace(composer.Text)) return;
      Model.Draft = composer.Text; await Model.SendAsync();
    }, control => _ = ShowSettingsAsync());
    var compose = new StackPanel { Spacing = 8 }; compose.Children.Add(slash.View); compose.Children.Add(composer);
    var buttons = new Grid { ColumnSpacing = 8 }; buttons.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); buttons.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); buttons.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); buttons.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    resume = ActionButton("Continue queued turns", () => Model.ContinueAsync()); stop = ActionButton("Stop", () => Model.StopAsync()); send = ActionButton("Send", () => Model.SendAsync());
    send.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    var add = new Button(); ChatAppearance.IconButton(add, "\uE710", "Mention a session");
    add.Click += (_, _) => {
      var choices = new MenuFlyout();
      foreach (var session in sessions()) { var target = session; AddMenu(choices, target.Title, () => { composer.Text += " @" + target.Title + " (session " + target.Id + ") "; composer.Focus(FocusState.Programmatic); return Task.CompletedTask; }); }
      if (choices.Items.Count == 0) AddMenu(choices, "Write a project question", () => { composer.Focus(FocusState.Programmatic); return Task.CompletedTask; });
      choices.ShowAt(add);
    };
    var leading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; leading.Children.Add(add); leading.Children.Add(resume); buttons.Children.Add(leading);
    var mic = new Button(); ChatAppearance.IconButton(mic, "\uE720", "Voice typing");
    mic.Click += (_, _) => { var started = TerminalDeck.App.Shell.WindowsVoiceTyping.Start(composer); feedback.Text = started ? "Windows voice typing requested. Your words stay in the draft." : "Click in the draft and press Win+H."; feedback.Visibility = Visibility.Visible; };
    SetColumn(mic, 1); buttons.Children.Add(mic); SetColumn(stop, 2); buttons.Children.Add(stop); compose.Children.Add(buttons);
    ChatAppearance.IconButton(stop, "\uE71A", "Stop the current answer");
    ChatAppearance.IconButton(send, "\uE74A", "Send message", accent: true);
    composer.MinHeight = 40;
    composer.BorderThickness = new Thickness(0); composer.Padding = new Thickness(0); composer.FontSize = 14;
    composer.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
    var glass = new Border { Child = compose, MaxWidth = 720, Style = (Style)Resources["Glass"], HorizontalAlignment = HorizontalAlignment.Stretch };
    dock.Children.Add(glass);
    var chips = new Grid { ColumnSpacing = 8 };
    chips.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); chips.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    foreach (var chip in new[] { modelChip, accountChip })
    {
      chip.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"]; chip.MinHeight = 28; chip.Padding = new Thickness(6, 4, 6, 4); chip.FontSize = 12;
      chip.Click += async (_, _) => await ShowSettingsAsync();
    }
    chips.Children.Add(accountChip); SetColumn(modelChip, 1); chips.Children.Add(modelChip); dock.Children.Add(chips);
    SetRow(dock, 3); Children.Add(dock);
    composer.PreviewKeyDown += async (_, e) => // before the multi-line TextBox adds a new line
    {
      if (e.Handled) return; // the "/" menu took this key (Enter picks a command)
      var shift = (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
      switch (enter.Decide(e.Key == Windows.System.VirtualKey.Enter, shift, send.IsEnabled))
      {
        case ComposerEnterAction.Send: e.Handled = true; await Model.SendAsync(); break;
        case ComposerEnterAction.Swallow: e.Handled = true; break;
      }
    };
    composer.TextCompositionStarted += (_, _) => enter.CompositionStarted();
    composer.TextCompositionEnded += (_, _) => enter.CompositionEnded();
    composer.TextChanged += (_, _) => { Model.Draft = composer.Text; Controls(); };
    Model.PropertyChanged += (_, e) =>
    {
      if (e.PropertyName == nameof(HootViewModel.Draft)) composer.Text = Model.Draft;
      if (e.PropertyName == nameof(HootViewModel.State)) Render(); Controls();
    };
    SizeChanged += (_, _) => { Padding = new Thickness(ActualWidth < 640 ? 12 : 24, 12, ActualWidth < 640 ? 12 : 24, 12); };
    AutomationProperties.SetAutomationId(this, "hoot.page"); AutomationProperties.SetAutomationId(composer, "hoot.composer"); AutomationProperties.SetAutomationId(send, "hoot.send"); AutomationProperties.SetAutomationId(stop, "hoot.stop");
    Render(); Controls();
    // Hoot is set up without a setup screen: whenever the page shows with Hoot
    // unconfigured and an AI signed in (here, in Settings or a chat), connect it.
    Loaded += async (_, _) => await ReadyIfSignedInAsync();
  }
  private bool AnySignedIn() => accounts().Any(a => a.SignedIn);
  private async Task ReadyIfSignedInAsync()
  {
    if (Model.State.Settings is not null || !AnySignedIn()) return;
    await Model.ReadyAsync(); renderedSequence = -1; Render(); Controls();
  }
  private async Task SignInToStartAsync(string provider)
  {
    if (signIn is null) { openCodingAis?.Invoke(); return; }
    try { await signIn(provider); }
    catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IOException)
    { feedback.Text = ex.Message; feedback.Visibility = Visibility.Visible; return; }
    await ReadyIfSignedInAsync();
  }
  private static TextBlock Words(string text, double size = 13.5) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
  private static Button ActionButton(string title, Func<Task> action)
  { var button = new Button { Content = title, MinHeight = 40 }; button.Click += async (_, _) => await action(); return button; }
  private static void AddMenu(MenuFlyout menu, string title, Func<Task> action)
  { var item = new MenuFlyoutItem { Text = title }; item.Click += async (_, _) => await action(); menu.Items.Add(item); }
  private Border Card(UIElement child) => new() { Child = child, Style = (Style)Resources["Card"], HorizontalAlignment = HorizontalAlignment.Stretch };
  private void Controls()
  {
    var state = Model.State; status.Text = state.Status + (state.Waiting > 0 ? $" · {state.Waiting} waiting" : "");
    feedback.Text = Model.Error ?? state.Problem ?? "";
    feedback.Visibility = feedback.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    pending.Visibility = Model.Pending ? Visibility.Visible : Visibility.Collapsed;
    // A signed-in AI is enough: the keeper connects Hoot to it on the first send.
    send.IsEnabled = !Model.Pending && (state.Settings is not null || AnySignedIn()) && !string.IsNullOrWhiteSpace(composer.Text);
    stop.IsEnabled = !Model.Pending && state.Active?.Source.Kind is "person" or "session";
    stop.Visibility = state.Busy ? Visibility.Visible : Visibility.Collapsed;
    AutomationProperties.SetName(send, state.Busy ? "Queue message" : "Send message");
    // Same words as every chat chip: the real model and level ("Opus 5.5 · Extra high"); an
    // empty choice shows the app-wide "New sessions start with" pick, never "Default".
    var hootProvider = state.Settings?.Provider ?? "claude";
    var wide = TerminalDeck.App.Views.Agents.NewSessionPicker.Services?.Launch(hootProvider) ?? TerminalDeck.Core.Settings.LaunchDefaults.For(hootProvider, (TerminalDeck.Core.Settings.GeneralPreferences?)null);
    modelChip.Content = TerminalDeck.Core.Accounts.ModelCatalog.Label(hootProvider,
      state.Settings?.Options.Model is { Length: > 0 } chosen ? chosen : wide.Model,
      state.Settings?.Options.Effort is { Length: > 0 } e && e != "auto" ? e : wide.Effort);
    accountChip.Content = accounts().FirstOrDefault(a => a.Id == state.Settings?.AccountId)?.Name ?? "Choose Coding AI";
    dock.Visibility = selectedSection == "Chat" ? Visibility.Visible : Visibility.Collapsed;
    foreach (var tab in sections.Children.OfType<Button>())
    {
      var chosenTab = tab.Content as string == selectedSection;
      tab.FontWeight = chosenTab ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
      AutomationProperties.SetName(tab, tab.Content + (chosenTab ? ", selected" : ""));
    }
    resume.Visibility = state.Paused ? Visibility.Visible : Visibility.Collapsed; resume.IsEnabled = !Model.Pending;
  }
  private void Render()
  {
    if (selectedSection != "Chat")
    {
      // Background chat tokens must not replace a focused memory editor.
      if (selectedSection == "History" || renderedMemory != Model.State.Memory) RenderSection();
      return;
    }
    var state = Model.State; var sequence = state.Lines.LastOrDefault()?.Sequence ?? 0;
    var changes = string.Join('|', state.Lines.TakeLast(30).Select(l => l.Id + l.Text + l.Waiting)) + string.Join('|', state.Turns.TakeLast(30).Select(t => t.State + t.Answer)) + state.Waiting + state.Busy;
    if (renderedSequence == sequence && renderedChanges == changes) return;
    var nearBottom = history.ScrollableHeight - history.VerticalOffset < 80; renderedSequence = sequence; renderedChanges = changes; messages.Children.Clear();
    if (state.Lines.Length == 0)
    {
      var empty = ChatAppearance.Empty("Ask Hoot anything about your projects.", "hoot");
      if (state.Settings is null && !AnySignedIn())
      {
        empty.Children.Add(Words(HootReady.SignInLine, 13));
        var start = ActionButton("Sign in to start Hoot", () => SignInToStartAsync("claude"));
        start.Style = (Style)Application.Current.Resources["AccentButtonStyle"]; AutomationProperties.SetAutomationId(start, "hoot.signin");
        var others = new MenuFlyout();
        AddMenu(others, "Sign in to Claude", () => SignInToStartAsync("claude")); AddMenu(others, "Sign in to Codex", () => SignInToStartAsync("codex")); AddMenu(others, "Sign in to Gemini", () => SignInToStartAsync("gemini"));
        var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; choices.Children.Add(start);
        choices.Children.Add(new Button { Content = "Other AIs", Flyout = others, MinHeight = 40 }); empty.Children.Add(choices);
      }
      else
      {
        var suggestions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var suggestion in new[] { "What needs me?", "What did the agents do overnight?", "Check a problem" })
          suggestions.Children.Add(ActionButton(suggestion, () => { composer.Text = suggestion; composer.Focus(FocusState.Programmatic); return Task.CompletedTask; }));
        empty.Children.Add(new ScrollViewer { Content = suggestions, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
      }
      messages.Children.Add(empty);
    }
    if (state.Lines.Length > visibleMessages) messages.Children.Add(ActionButton("Earlier messages", () =>
    { visibleMessages += 300; renderedSequence = -1; Render(); return Task.CompletedTask; }));
    foreach (var line in state.Lines.TakeLast(visibleMessages))
    {
      UIElement row;
      if (line.Kind == "user")
      {
        var text = Words(line.Text); text.Style = (Style)Resources["PersonText"];
        var bubble = new Border { Child = text, Style = (Style)Resources["Person"], MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Right };
        row = bubble;
        if (state.Turns.Any(t => t.Id == line.TurnId && t.State == HootTurnState.Queued))
        {
          bubble.Child = null;
          var queuedBody = new StackPanel { Spacing = 8 }; queuedBody.Children.Add(Words("Queued", 12)); queuedBody.Children.Add(text); bubble.Child = queuedBody;
          var queued = new Grid { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Right };
          bubble.HorizontalAlignment = HorizontalAlignment.Stretch; queued.Children.Add(bubble);
          queued.Children.Add((UIElement)XamlReader.Load("""
            <Rectangle xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" RadiusX="18" RadiusY="18" Stroke="{ThemeResource TextFillColorSecondaryBrush}" StrokeThickness="1" StrokeDashArray="4,4" IsHitTestVisible="False"/>
            """)); row = queued;
        }
      }
      else if (line.Kind == "approval")
      {
        var body = new StackPanel { Spacing = 10 }; body.Children.Add(Words("Approval needed", 15)); body.Children.Add(Words(line.Text.Length == 0 ? "Tool operation" : line.Text));
        if (line.Details.Length > 0) body.Children.Add(new Expander { Header = "Operation arguments", Content = Words(line.Details), HorizontalContentAlignment = HorizontalAlignment.Stretch });
        if (line.Waiting && line.RequestId is { } id)
        {
          var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
          actions.HorizontalAlignment = HorizontalAlignment.Right;
          actions.Children.Add(ActionButton("Deny", () => Model.AnswerAsync(id, false)));
          var allow = ActionButton("Allow once", () => Model.AnswerAsync(id, true)); allow.Style = (Style)Application.Current.Resources["AccentButtonStyle"]; actions.Children.Add(allow); body.Children.Add(actions);
        }
        else body.Children.Add(Words("Answered", 13));
        row = Card(body);
      }
      else if (line.Kind == "tool") row = ChatAppearance.ToolStep(line.Text, line.Details, line.Waiting);
      else if (line.Kind == "background")
      {
        var turn = state.Turns.FirstOrDefault(t => t.Id == line.TurnId); var body = new StackPanel { Spacing = 8 };
        body.Children.Add(Words(line.Text + (turn is null ? "" : " · " + TurnWords(turn.State)), 13));
        if (turn is { State: HootTurnState.Running or HootTurnState.Queued or HootTurnState.Dispatching }) body.Children.Add(ActionButton("Stop task", () => Model.CancelAsync(turn.Id)));
        if (turn?.Answer.Length > 0) body.Children.Add(new Expander { Header = "Task answer", Content = Words(turn.Answer), HorizontalContentAlignment = HorizontalAlignment.Stretch });
        row = body;
      }
      else row = line.Kind == "assistant" ? ChatAppearance.Reply(ChatMarkdownView.Render(line.Text, text => { var content = new Windows.ApplicationModel.DataTransfer.DataPackage(); content.SetText(text); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(content); }, error => { feedback.Text = error; feedback.Visibility = Visibility.Visible; }), "Hoot") : Card(Words(line.Text, 13));
      if (row is FrameworkElement element) element.MaxWidth = line.Kind == "user" ? 520 : 760; messages.Children.Add(row);
    }
    if (state.Busy && state.Active?.Source.Kind == "person" && !state.Lines.Any(l => l.TurnId == state.Active.Id && l.Kind == "assistant"))
      messages.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left });
    if (nearBottom) DispatcherQueue.TryEnqueueHandled(() => history.ChangeView(null, history.ScrollableHeight, null, true));
  }
  private static string TurnWords(HootTurnState state) => state switch
  { HootTurnState.Queued => "Waiting", HootTurnState.Finished => "Done", HootTurnState.Stopped => "Stopped", HootTurnState.Failed => "Needs attention", HootTurnState.Uncertain => "Delivery unconfirmed", _ => "Working" };
  private ContentDialog Dialog(string title, object content, string primary = "Save") => new() { Title = title, Content = content, PrimaryButtonText = primary, CloseButtonText = "Cancel", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary, RequestedTheme = ActualTheme };
  private async Task ShowSettingsAsync()
  {
    var current = Model.State.Settings; var rows = accounts().Where(a => a.SignedIn).OrderBy(a => a.Provider).ThenBy(a => a.Name).ToArray(); var account = new ComboBox { Header = "Hoot's account", ItemsSource = rows.Select(a => a.Name + " · " + a.Provider).ToArray(), HorizontalAlignment = HorizontalAlignment.Stretch };
    account.SelectedIndex = Array.FindIndex(rows, a => a.Id == current?.AccountId); if (account.SelectedIndex < 0 && rows.Length > 0) account.SelectedIndex = 0;
    var folder = new TextBox { Header = "Working folder", Text = current?.Folder ?? "", MaxLength = 2000 };
    var model = new ComboBox { Header = "Model", HorizontalAlignment = HorizontalAlignment.Stretch };
    var catalogStatus = new Notices.CompactNotice { Text = "Reading models…" }; var reading = new ProgressBar { IsIndeterminate = true, Height = 3 };
    var catalogueRequest = 0;
    IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel> modelChoices = [];
    async Task ReadModels()
    {
      var request = ++catalogueRequest; model.Items.Clear(); model.IsEnabled = false;
      if (account.SelectedIndex < 0) { catalogStatus.Text = "No signed-in account yet."; reading.Visibility = Visibility.Collapsed; return; }
      var selected = rows[account.SelectedIndex]; catalogStatus.Text = "Reading models…"; reading.Visibility = Visibility.Visible;
      try
      {
        var offered = await Model.ModelsAsync(selected.Id); if (request != catalogueRequest) return; modelChoices = offered;
        foreach (var choice in offered) model.Items.Add(new ComboBoxItem { Content = choice.Name, Tag = choice.Id });
        var saved = current is { } configured && selected.Id == configured.AccountId ? configured.Options.Model : "";
        model.SelectedIndex = model.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => i.Tag as string == saved);
        if (model.SelectedIndex < 0 && saved.Length > 0)
        { model.Items.Add(new ComboBoxItem { Content = saved + " · Unavailable", Tag = saved, IsEnabled = false }); model.SelectedIndex = model.Items.Count - 1; }
        if (model.SelectedIndex < 0) model.SelectedIndex = 0;
        model.IsEnabled = true; catalogStatus.Text = saved.Length > 0 && !offered.Any(m => m.Id == saved) ? "The saved model is unavailable. Choose a model from this account." : "";
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
      { if (request == catalogueRequest) catalogStatus.Text = "The model catalogue could not be read. Try again."; }
      finally { if (request == catalogueRequest) reading.Visibility = Visibility.Collapsed; }
    }
    var effort = new ComboBox { Header = "Effort", ItemsSource = new[] { "low", "medium", "high", "xhigh", "max" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    if (current?.Options.Effort is { Length: > 0 } chosen && chosen != "auto") effort.SelectedItem = chosen;
    var permission = new ComboBox { Header = "Before it changes files", HorizontalAlignment = HorizontalAlignment.Stretch };
    var bypass = new CheckBox { Content = "Allow Hoot to bypass the coding AI's permission questions", Visibility = Visibility.Collapsed };
    permission.SelectionChanged += (_, _) => { bypass.IsChecked = false; bypass.Visibility = permission.SelectedItem as string == ChatPermissionModes.Label(AiPermissionMode.Bypass) ? Visibility.Visible : Visibility.Collapsed; };
    IReadOnlyList<AiPermissionMode> modes = [];
    void UpdateModes()
    {
      var wanted = permission.SelectedIndex >= 0 && permission.SelectedIndex < modes.Count ? modes[permission.SelectedIndex] : current?.PermissionMode ?? AiPermissionMode.Ask;
      modes = account.SelectedIndex >= 0 ? ChatPermissionModes.Supported(rows[account.SelectedIndex].Provider) : [];
      permission.ItemsSource = modes.Select(ChatPermissionModes.Label).ToArray();
      permission.SelectedIndex = modes.Count == 0 ? -1 : Math.Max(0, modes.ToList().IndexOf(wanted));
    }
    void UpdateEfforts()
    {
      if (account.SelectedIndex < 0) return;
      var provider = rows[account.SelectedIndex].Provider; var previous = effort.SelectedItem as string ?? current?.Options.Effort;
      var modelId = (model.SelectedItem as ComboBoxItem)?.Tag as string;
      effort.ItemsSource = TerminalDeck.Core.Accounts.ModelEfforts.For(provider, modelChoices.FirstOrDefault(m => m.Id == modelId));
      effort.Visibility = provider == "gemini" ? Visibility.Collapsed : Visibility.Visible;
      effort.SelectedItem = previous; if (effort.SelectedIndex < 0) effort.SelectedItem = "medium"; if (effort.SelectedIndex < 0 && effort.Items.Count > 0) effort.SelectedIndex = 0;
    }
    model.SelectionChanged += (_, _) => UpdateEfforts();
    account.SelectionChanged += async (_, _) => { UpdateModes(); UpdateEfforts(); await ReadModels(); }; UpdateModes(); UpdateEfforts();
    var retryModels = ActionButton("Try again", ReadModels);
    var panel = new StackPanel { Spacing = 12, MinWidth = 280 }; foreach (var control in new UIElement[] { account, folder, model, reading, catalogStatus, retryModels, effort, permission, bypass }) panel.Children.Add(control);
    panel.Children.Add(Words("Only you can change Hoot's settings. Plan only refuses changes. Bypass skips the coding AI's permission questions; saved app access and server confirmations still apply.", 13));
    ContentDialog? setupDialog = null;
    if (openCodingAis is not null) panel.Children.Add(ActionButton("Add account…", () => { setupDialog?.Hide(); openCodingAis(); return Task.CompletedTask; }));
    var dialog = Dialog("Hoot settings", new ScrollViewer { Content = panel, MaxHeight = 540 });
    setupDialog = dialog;
    dialog.Opened += async (_, _) => await ReadModels();
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral(); args.Cancel = true;
      try
      {
        if (account.SelectedIndex < 0 || model.SelectedItem is not ComboBoxItem { IsEnabled: true, Tag: string modelId }) return;
        var selected = rows[account.SelectedIndex];
        if (modes[permission.SelectedIndex] == AiPermissionMode.Bypass && current?.PermissionMode != AiPermissionMode.Bypass)
        { if (bypass.IsChecked != true) { catalogStatus.Text = "Confirm Bypass permissions above before saving."; return; } }
        await Model.ConfigureAsync(new(selected.Provider, selected.Id, folder.Text, new(modelId, selected.Provider == "gemini" ? "" : effort.SelectedItem?.ToString() ?? "medium"), 0, 0, modes[permission.SelectedIndex]));
        if (Model.Error is not null) catalogStatus.Text = Model.Error; else args.Cancel = false;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }

  private async Task NewChatAsync()
  {
    var dialog = Dialog("New chat?", Words("Your current conversation stays in History. Hoot's memory and settings stay."), "New chat");
    if (await dialog.ShowAsync() == ContentDialogResult.Primary)
    {
      await Model.RefreshAsync();
      if (Model.Error is null) { SelectSection("Chat"); renderedSequence = -1; Render(); }
    }
  }
  private void SelectSection(string section)
  {
    selectedSection = section; renderedMemory = null; renderedSequence = -1; Render(); Controls();
    history.ChangeView(null, 0, null, true);
  }
  private void RenderSection()
  {
    messages.Children.Clear(); var saved = Model.State.Memory; renderedMemory = saved;
    var panel = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Stretch };
    if (selectedSection == "Desk")
    {
      panel.Children.Add(Words("Hoot's desk", 20));
      var card = new TextBox { Header = "Hoot's memory", Text = cardDraft ?? saved.Card, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120, MaxHeight = 240, MaxLength = 16000 };
      card.TextChanged += (_, _) => cardDraft = card.Text;
      panel.Children.Add(card); panel.Children.Add(ActionButton("Save", async () => { await Model.MemoryAsync(card.Text, Model.State.Memory.Playbook); if (Model.Error is null) cardDraft = null; }));
      panel.Children.Add(Words("Board", 15));
      if (saved.Board.Length == 0) panel.Children.Add(Words("Nothing on the board yet.", 13));
      foreach (var row in saved.Board)
      {
        var body = new StackPanel { Spacing = 8 }; body.Children.Add(Words(row.Title + " · " + row.State)); body.Children.Add(Words(row.Detail, 13));
        body.Children.Add(BoardEditor("Edit row", row));
        if (row.SessionId is { } id && openSession is not null) body.Children.Add(ActionButton("Open session", () => { openSession(id); return Task.CompletedTask; }));
        panel.Children.Add(Card(body));
      }
      panel.Children.Add(BoardEditor("Add board row", null));
    }
    else if (selectedSection == "Playbook")
    {
      panel.Children.Add(Words("Playbook", 20));
      var playbook = new TextBox { Header = "Playbook in use", Text = playbookDraft ?? saved.Playbook, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 240, MaxHeight = 480, MaxLength = 16000 };
      playbook.TextChanged += (_, _) => playbookDraft = playbook.Text;
      panel.Children.Add(playbook); panel.Children.Add(ActionButton("Save", async () => { await Model.MemoryAsync(Model.State.Memory.Card, playbook.Text); if (Model.Error is null) playbookDraft = null; }));
    }
    else
    {
      panel.Children.Add(Words("History", 20)); panel.Children.Add(Words("What Hoot has done", 15));
      if (Model.State.Turns.Length == 0) panel.Children.Add(Words("Nothing recorded yet.", 13));
      foreach (var turn in Model.State.Turns.TakeLast(100).Reverse())
      {
        var body = new StackPanel { Spacing = 8 }; body.Children.Add(Words(turn.Source.Title + " · " + TurnWords(turn.State)));
        body.Children.Add(Words(turn.At.ToLocalTime().ToString("g"), 12)); body.Children.Add(Words(turn.Text));
        if (turn.Answer.Length > 0) body.Children.Add(new Expander { Header = "Answer", Content = Words(turn.Answer), HorizontalContentAlignment = HorizontalAlignment.Stretch });
        if (turn.Problem is not null) body.Children.Add(Words(turn.Problem, 13));
        if (turn.State is HootTurnState.Running or HootTurnState.Dispatching or HootTurnState.Queued) body.Children.Add(ActionButton("Stop turn", () => Model.CancelAsync(turn.Id)));
        panel.Children.Add(Card(body));
      }
      panel.Children.Add(Words("Earlier conversations", 15));
      foreach (var conversation in Model.State.History.Reverse())
      {
        var transcript = new StackPanel { Spacing = 12 };
        foreach (var line in conversation.Lines) transcript.Children.Add(Words(line.Kind + ": " + line.Text));
        panel.Children.Add(new Expander { Header = conversation.ArchivedAt.ToLocalTime().ToString("g"), Content = transcript, HorizontalContentAlignment = HorizontalAlignment.Stretch });
      }
      panel.Children.Add(Words("Desk snapshots", 15));
      if (saved.Desks.Length == 0) panel.Children.Add(Words("No desk snapshots yet.", 13));
      foreach (var desk in saved.Desks.Reverse()) panel.Children.Add(new Expander { Header = desk.At.ToLocalTime().ToString("g"), Content = Words(desk.Text, 13), HorizontalContentAlignment = HorizontalAlignment.Stretch });
    }
    messages.Children.Add(panel);
  }
  private Button BoardEditor(string label, HootBoardRow? row)
  {
    // A ContentDialog cannot be stacked over another one on the same root.
    var flyout = new Flyout(); var title = new TextBox { Header = "Title", Text = row?.Title ?? "", MaxLength = 200 };
    var detail = new TextBox { Header = "Note", Text = row?.Detail ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 2000 };
    var state = new ComboBox { Header = "State", ItemsSource = new[] { "queued", "working", "waiting", "done" }, SelectedItem = row?.State ?? "queued", HorizontalAlignment = HorizontalAlignment.Stretch };
    var panel = new StackPanel { Spacing = 8, Width = 280, RequestedTheme = ActualTheme }; panel.Children.Add(title); panel.Children.Add(detail); panel.Children.Add(state);
    var result = new Notices.CompactNotice(); panel.Children.Add(result);
    panel.Children.Add(ActionButton("Save row", async () => { await Model.BoardAsync(new(row?.Id ?? Guid.NewGuid().ToString(), title.Text, state.SelectedItem?.ToString() ?? "queued", detail.Text, row?.SessionId, DateTimeOffset.UtcNow)); result.Text = Model.Error ?? "Saved"; }));
    flyout.Content = panel; return new Button { Content = label, Flyout = flyout, MinHeight = 40 };
  }
  private async Task ShowHandoffAsync()
  {
    var rows = sessions().ToArray(); var choice = new ComboBox { Header = "Send to session", ItemsSource = rows.Select(s => s.Title).ToArray(), SelectedIndex = rows.Length > 0 ? 0 : -1, HorizontalAlignment = HorizontalAlignment.Stretch };
    var text = new TextBox { Header = "Context handoff", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 180, MaxHeight = 300, MaxLength = 7000 };
    var panel = new StackPanel { Spacing = 12, MinWidth = 280 }; panel.Children.Add(choice); panel.Children.Add(text); panel.Children.Add(Words("Chat sessions receive the note. Terminal sessions get pasted context for you to send.", 13));
    if (await Dialog("Context handoff", panel, "Send context").ShowAsync() == ContentDialogResult.Primary && choice.SelectedIndex >= 0)
      await Model.HandoffAsync(Guid.NewGuid().ToString(), rows[choice.SelectedIndex].Id, text.Text);
  }
  private async Task ShowBackgroundAsync()
  {
    var panel = new StackPanel { Spacing = 12, MinWidth = 280 };
    foreach (var turn in Model.State.Turns.Where(t => t.Source.Kind is not ("person" or "session")).TakeLast(50).Reverse())
    {
      var body = new StackPanel { Spacing = 8 }; body.Children.Add(Words(turn.Source.Title + " · " + TurnWords(turn.State)));
      if (turn.State is HootTurnState.Running or HootTurnState.Dispatching or HootTurnState.Queued) body.Children.Add(ActionButton("Stop turn", () => Model.CancelAsync(turn.Id)));
      if (turn.Answer.Length > 0) body.Children.Add(new Expander { Header = "Answer", Content = Words(turn.Answer), HorizontalContentAlignment = HorizontalAlignment.Stretch });
      if (turn.Problem is not null) body.Children.Add(Words(turn.Problem, 13)); panel.Children.Add(Card(body));
    }
    if (panel.Children.Count == 0) panel.Children.Add(Words("No background turns yet."));
    await new ContentDialog { Title = "Background turns", Content = new ScrollViewer { Content = panel, MaxHeight = 540 }, CloseButtonText = "Done", XamlRoot = XamlRoot, RequestedTheme = ActualTheme }.ShowAsync();
  }
  public void Dispose() => Model.Dispose();
}
