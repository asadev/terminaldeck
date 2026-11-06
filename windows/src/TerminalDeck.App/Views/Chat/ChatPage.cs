using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Chats;
using TerminalDeck.App.Shell;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Chat;

// W4 supplies the selected chat and the owning window handle. No navigation,
// account runtime or CLI process is created by this view.
public sealed partial class ChatPage : Grid, IAsyncDisposable
{
  public ChatViewModel Model { get; }
  private readonly Func<nint> currentWindowHandle;
  private readonly ChatNavigation? navigation;
  private readonly StackPanel messages = new() { Spacing = 20, MaxWidth = 688, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 20, 0, 0) };
  private readonly StackPanel pending = new() { Spacing = 8 };
  private readonly StackPanel attachments = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
  private readonly StackPanel problem = new() { Spacing = 8 };
  private readonly TextBox composer = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 36, MaxHeight = 180, PlaceholderText = "Message" };
  // Not in the visual tree: Enter sends. The button only carries the "can send now" state.
  private readonly Button send = new() { Content = "Send", MinHeight = 40 };
  private readonly ComposerEnter enter = new();
  private readonly Button stop = new() { Content = "Stop", MinHeight = 40 };
  private readonly Button model = new() { MinHeight = 40, MaxWidth = 240, HorizontalAlignment = HorizontalAlignment.Left };
  private readonly Button effort = new() { MinHeight = 40, HorizontalAlignment = HorizontalAlignment.Stretch };
  private readonly Button account = new() { MinHeight = 40, MaxWidth = 200, HorizontalAlignment = HorizontalAlignment.Left };
  private readonly TextBlock title = new() { FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
  private readonly ScrollViewer scroll;
  private readonly Dictionary<string, RichChatWebView> richMessages = [];
  private int visibleMessages = 200;
  private Button? earlierMessages;
  public ChatPage(IChatSessions chats, string chatId, nint ownerWindowHandle = 0, Func<nint>? currentWindowHandle = null, ChatNavigation? navigation = null, TerminalDeck.Core.Accounts.AccountService? accountModels = null)
  {
    this.navigation = navigation;
    this.currentWindowHandle = currentWindowHandle ?? (() => ownerWindowHandle);
    Resources = (ResourceDictionary)XamlReader.Load("""
      <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
        <Style x:Key="ChatChoiceText" TargetType="TextBlock"><Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}"/><Setter Property="Foreground" Value="{ThemeResource TextFillColorPrimaryBrush}"/></Style>
        <Style x:Key="ChatCanvas" TargetType="Grid"><Setter Property="Background" Value="{ThemeResource DeckCanvasBrush}"/></Style>
        <Style x:Key="ChatCard" TargetType="Border"><Setter Property="Background" Value="{ThemeResource CardBackgroundFillColorDefaultBrush}"/><Setter Property="CornerRadius" Value="16"/><Setter Property="Padding" Value="16"/></Style>
        <Style x:Key="UserText" TargetType="TextBlock"><Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}"/><Setter Property="Foreground" Value="{ThemeResource TextFillColorPrimaryBrush}"/></Style>
        <Style x:Key="UserBubble" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckSelectionBrush}"/><Setter Property="CornerRadius" Value="18,18,6,18"/><Setter Property="Padding" Value="14"/></Style>
        <Style x:Key="ChatSkeleton" TargetType="Border"><Setter Property="Background" Value="{ThemeResource ControlFillColorSecondaryBrush}"/><Setter Property="CornerRadius" Value="6"/></Style>
        <Style x:Key="ComposerGlass" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckGlassBrush}"/><Setter Property="CornerRadius" Value="22"/><Setter Property="Padding" Value="16"/></Style>
      </ResourceDictionary>
      """);
    Style = (Style)Resources["ChatCanvas"];
    Padding = new Thickness(20, 0, 20, 12); RowSpacing = 6;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto });
    Model = new(chats, chatId, action => DispatcherQueue.TryEnqueueHandled(() => action()), accountModels);
    if (navigation?.SignIn is { } signIn) Model.SignInRequested = () => signIn(Model.Snapshot.Definition.AccountId);
    var heading = new Grid { ColumnSpacing = 12, Height = 0, MaxWidth = 688, HorizontalAlignment = HorizontalAlignment.Stretch };
    heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); title.Visibility = Visibility.Collapsed; heading.Children.Add(title);
    var headerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    SetupConversationTools(headerActions); SetColumn(headerActions, 1); heading.Children.Add(headerActions);
    Children.Add(heading);
    send.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    send.SetResourceReference(Control.BackgroundProperty, "DeckProjectBlueBrush");
    scroll = new() { Content = messages, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled, VerticalContentAlignment = VerticalAlignment.Top };
    scroll.SizeChanged += (_, _) =>
    {
      messages.Width = Math.Max(0, Math.Min(688, scroll.ActualWidth));
      FitRows();
    };
    AutomationProperties.SetAutomationId(scroll, "chat.history"); SetRow(scroll, 1); Children.Add(scroll);
    var feedback = new StackPanel { Spacing = 8, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
    feedback.Children.Add(searchBar); feedback.Children.Add(unread); SetRow(feedback, 2); Children.Add(feedback); Children.Add(problem);
    var composition = new StackPanel { Spacing = 8 }; composition.Children.Add(promptSummary); composition.Children.Add(new ScrollViewer { Content = attachments, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    // Mac "/" menu: the session's commands and skills, above the text like the Mac composer.
    var slash = new SlashCommandMenu(composer, () => ChatSlashSources.For(Model.Snapshot, chats.DataRoot), async () => { if (send.IsEnabled) await Model.SendAsync(); }, control =>
    {
      switch (control) { case "model": _ = ShowModelsAsync(); break; case "effort": ShowEffort(); break; case "permission": ShowPermissions(); break; }
    });
    composition.Children.Add(slash.View); composition.Children.Add(composer);
    // Mac keeps the choices below the floating box, leaving the text room to breathe.
    var choices = new Grid { ColumnSpacing = 4, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
    choices.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    choices.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    choices.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    foreach (var chip in new[] { account, model, effort, permission })
    {
      chip.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      chip.MinHeight = 28; chip.MinWidth = 32; chip.Padding = new Thickness(6, 4, 6, 4); chip.FontSize = 12;
    }
    account.MaxWidth = 180; model.MaxWidth = 220; effort.MaxWidth = 100;
    choices.Padding = new Thickness(12, 0, 12, 0);
    choices.Children.Add(permission); SetColumn(model, 1); choices.Children.Add(model); SetColumn(effort, 2); choices.Children.Add(effort);
    var controls = new Grid { ColumnSpacing = 8 };
    controls.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var attach = Button("Add", () => Task.CompletedTask);
    var addMenu = new MenuFlyout();
    var photos = new MenuFlyoutItem { Text = "Add photos…" }; photos.Click += async (_, _) => await PickImagesAsync(); addMenu.Items.Add(photos);
    var editPrompt = new MenuFlyoutItem { Text = "Edit full prompt…" }; editPrompt.Click += async (_, _) => await EditFullPromptAsync(); addMenu.Items.Add(editPrompt);
    attach.Flyout = addMenu; attach.HorizontalAlignment = HorizontalAlignment.Left;
    ChatAppearance.IconButton(attach, "\uE710", "Add to message"); controls.Children.Add(attach);
    ChatAppearance.IconButton(stop, "\uE71A", "Stop the current answer");
    ChatAppearance.IconButton(send, "\uE74A", "Send message", accent: true);
    var dictate = Button("Dictate", StartVoiceTypingAsync);
    ChatAppearance.IconButton(dictate, "\uE720", "Dictate with Windows voice typing (Win+H)");
    AutomationProperties.SetAutomationId(dictate, "chat.dictate");
    SetColumn(dictate, 1); controls.Children.Add(dictate);
    Model.PropertyChanged += (_, _) => dictate.IsEnabled = !Model.Snapshot.Ended;
    dictate.IsEnabled = !Model.Snapshot.Ended;
    SetColumn(stop, 2); controls.Children.Add(stop); composition.Children.Add(controls);
    composer.BorderThickness = new Thickness(0); composer.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    composer.Padding = new Thickness(0); composer.FontSize = 14;
    var glass = new Border { Child = composition, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch, Style = (Style)Resources["ComposerGlass"], Margin = new Thickness(0, 8, 0, 0) };
    var dock = new StackPanel { Spacing = 8, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
    dock.Children.Add(glass); dock.Children.Add(controlFeedback); dock.Children.Add(choices); SetRow(dock, 3); Children.Add(dock);
    ObserveText(composer, () => { if (composer.Text != Model.Draft) Model.Draft = composer.Text; UpdatePromptSummary(); UpdateControls(); });
    composer.KeyDown += async (_, e) =>
    {
      if (e.Key is Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down)
      {
        if (IsKeyPressed(Windows.System.VirtualKey.Shift) || IsKeyPressed(Windows.System.VirtualKey.Control) || IsKeyPressed(Windows.System.VirtualKey.Menu)) return;
        var previous = e.Key == Windows.System.VirtualKey.Up;
        var eligible = composer.SelectionLength == 0 && (previous && composer.Text.Length == 0 || Model.IsRecalledPrompt && composer.SelectionStart == composer.Text.Length);
        if (Model.RecallPrompt(previous, eligible)) { composer.SelectionStart = composer.Text.Length; e.Handled = true; }
      }
    };
    // Enter must be decided BEFORE the multi-line TextBox inserts its new line,
    // so it runs on PreviewKeyDown (KeyDown arrives after the TextBox handled it).
    composer.PreviewKeyDown += async (_, e) =>
    {
      if (e.Handled || e.Key != Windows.System.VirtualKey.Enter) return; // the "/" menu may have taken Enter
      var shift = (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
      switch (enter.Decide(e.Key == Windows.System.VirtualKey.Enter, shift, send.IsEnabled))
      {
        case ComposerEnterAction.Send: e.Handled = true; await Model.SendAsync(); break;
        case ComposerEnterAction.Swallow: e.Handled = true; break;
      }
    };
    composer.TextCompositionStarted += (_, _) => enter.CompositionStarted();
    composer.TextCompositionEnded += (_, _) => enter.CompositionEnded();
    composer.Paste += async (_, e) =>
    {
      try
      {
        var data = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Bitmap))
        {
          e.Handled = true;
          if (Model.Attachments.Count >= 8) throw new InvalidOperationException("Send or remove an image before adding more.");
          var image = await ChatImageScaler.PrepareClipboardAsync(await data.GetBitmapAsync());
          await Model.AddImageAsync(image.Name, image.MimeType, image.Bytes, image.Width, image.Height);
        }
        else if (data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
        {
          e.Handled = true;
          foreach (var file in (await data.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>())
          {
            if (Model.Attachments.Count >= 8) throw new InvalidOperationException("Send or remove an image before adding more.");
            var image = await ChatImageScaler.PrepareAsync(file); await Model.AddImageAsync(image.Name, image.MimeType, image.Bytes, image.Width, image.Height);
          }
        }
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.COMException)
      { e.Handled = true; await Model.RunAsync(() => throw new InvalidOperationException("This image could not be pasted. Choose a supported image up to 32 MB.")); }
    };
    composer.AllowDrop = true;
    composer.DragOver += (_, e) => { e.AcceptedOperation = e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems) ? Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy : Windows.ApplicationModel.DataTransfer.DataPackageOperation.None; };
    composer.Drop += async (_, e) =>
    {
      if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
      var deferral = e.GetDeferral();
      try
      {
        foreach (var file in (await e.DataView.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>())
        {
          if (Model.Attachments.Count >= 8) throw new InvalidOperationException("Send or remove an image before adding more.");
          var image = await ChatImageScaler.PrepareAsync(file);
          await Model.AddImageAsync(image.Name, image.MimeType, image.Bytes, image.Width, image.Height);
        }
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or System.Runtime.InteropServices.COMException)
      { await Model.RunAsync(() => throw new InvalidOperationException("This image could not be opened. Choose a PNG or JPEG file.")); }
      finally { deferral.Complete(); }
    };
    send.Click += async (_, _) => await Model.SendAsync(); stop.Click += async (_, _) => await Model.StopAsync();
    model.Click += async (_, _) => await ShowModelsAsync(); effort.Click += (_, _) => ShowEffort(); account.Click += (_, _) => ShowAccounts();
    Model.PropertyChanged += (_, args) =>
    {
      if (args.PropertyName is nameof(ChatViewModel.Snapshot) or nameof(ChatViewModel.Error) or nameof(ChatViewModel.Sending)) Render();
      if (args.PropertyName == nameof(ChatViewModel.Draft)) { if (composer.Text != Model.Draft) composer.Text = Model.Draft; UpdatePromptSummary(); }
      if (args.PropertyName == nameof(ChatViewModel.Attachments)) RenderAttachments();
      UpdateControls();
    };
    AutomationProperties.SetAutomationId(this, "chat.page"); AutomationProperties.SetAutomationId(composer, "chat.composer");
    AutomationProperties.SetAutomationId(effort, "chat.effort"); AutomationProperties.SetAutomationId(model, "chat.model"); AutomationProperties.SetAutomationId(account, "chat.account");
    AutomationProperties.SetAutomationId(send, "chat.send"); AutomationProperties.SetAutomationId(stop, "chat.stop");
    SizeChanged += (_, _) =>
    {
      var compact = ActualWidth < 640; Padding = new Thickness(compact ? 12 : 24, 12, compact ? 12 : 24, 12);
      composer.MinHeight = 36; model.MaxWidth = compact ? 180 : 220; account.MaxWidth = 180;
      SetColumn(permission, 0); SetColumn(model, 1); SetColumn(effort, 2);
      permission.MaxWidth = compact ? 150 : 240;
      model.MaxWidth = compact ? 150 : 220;
      choices.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
      choices.ColumnDefinitions[1].Width = GridLength.Auto;
      choices.ColumnDefinitions[2].Width = GridLength.Auto;
    };
    composer.Text = Model.Draft; UpdatePromptSummary(); Render();
  }
  // Imports and typing must validate at the same Text-property boundary.
  private static void ObserveText(TextBox box, Action changed) => box.RegisterPropertyChangedCallback(TextBox.TextProperty, (_, _) => changed());
  private TextBlock ChipText(string text) => new() { Text = text, TextTrimming = TextTrimming.CharacterEllipsis, Style = (Style)Resources["ChatChoiceText"] };
  private static TextBlock Words(string text, double size = ChatAppearance.BodySize) => new() { Text = text, FontSize = size, FontWeight = size >= ChatAppearance.BodySize ? ChatAppearance.BodyWeight : Microsoft.UI.Text.FontWeights.Normal, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
  private static Button Button(string label, Func<Task> run)
  {
    var button = new Button { Content = label, MinHeight = 40 }; button.Click += async (_, _) => await run(); return button;
  }
  private Border Card(UIElement content, bool user = false) => new() { Child = content, Style = (Style)Resources[user ? "UserBubble" : "ChatCard"], MaxWidth = user ? 520 : 760, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left };
  private void UpdateControls()
  {
    composer.IsEnabled = !Model.Snapshot.Ended;
    send.IsEnabled = !Model.ChangingControl && !Model.Snapshot.Ended && !Model.Sending && (Model.HasUnconfirmedSend || !string.IsNullOrWhiteSpace(composer.Text) || Model.Attachments.Count > 0);
    var sendLabel = Model.Sending ? "Sending…" : Model.HasUnconfirmedSend ? "Check send" : Model.Snapshot.Busy ? "Queue message" : "Send message";
    AutomationProperties.SetName(send, sendLabel); ToolTipService.SetToolTip(send, sendLabel);
    AutomationProperties.SetName(stop, Model.Snapshot.Stopping ? "Stopping…" : "Stop the current answer"); stop.IsEnabled = !Model.Snapshot.Stopping;
    stop.Visibility = Model.Snapshot.Busy ? Visibility.Visible : Visibility.Collapsed;
    var modelText = Model.SelectedModelName;
    var modelChip = ChipText(modelText); var fallbackReason = Model.AccountName == "Not signed in" ? "Sign in to read this AI's models." : Model.AvailableModels.Count == 0 ? "Read models from Coding AIs." : "";
    if (Model.ModelIsFallback && fallbackReason.Length > 0) { modelChip.Opacity = 0.6; ToolTipService.SetToolTip(model, modelText + " · " + fallbackReason); }
    else ToolTipService.SetToolTip(model, "Model: " + modelText);
    model.Content = modelChip;
    effort.Content = ChipText(ChatAppearance.EffortName(Model.EffectiveEffort));
    effort.Visibility = Model.Snapshot.Definition.Provider is "claude" or "codex" ? Visibility.Visible : Visibility.Collapsed;
    account.Content = ChipText(Model.AccountName);
    ToolTipService.SetToolTip(account, Model.Accounts.Any(a => a.Id == Model.Snapshot.Definition.AccountId) ? (Model.Accounts.FirstOrDefault(a => a.Id == Model.Snapshot.Definition.AccountId)?.Email is { } email ? email + " · " : "") + "Switch account and keep this conversation" : "This saved account is unavailable. Choose an available account or open Coding AIs.");
    var unresolvedApproval = Model.Rows.Any(r => r.Kind == "approval" && r.Waiting);
    var canChange = !Model.Sending && !Model.ChangingControl && !unresolvedApproval && !Model.Snapshot.Ended && !Model.Snapshot.Busy && !Model.Snapshot.Messages.Any(m => m.State == ChatMessageState.Queued || ChatSessions.Unconfirmed(Model.Snapshot, m));
    permission.Content = ChipText(ChatPermissionModes.Label(Model.ShownPermission));
    permission.IsEnabled = !Model.Snapshot.Ended;
    controlFeedback.Text = Model.ChangingControl ? "Working…" : Model.Sending ? "Sending…" : Model.Snapshot.Stopping ? "Stopping…" : Model.ControlNotice ?? "";
    controlFeedback.Visibility = controlFeedback.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    var controlReason = canChange ? "Saved choices apply on the next message." : Model.Snapshot.Ended ? "This chat has ended." : "Finish this answer, its approval requests and its queued messages first.";
    foreach (var chip in new[] { model, effort }) ToolTipService.SetToolTip(chip, controlReason);
    ToolTipService.SetToolTip(permission, Model.Snapshot.Ended ? "This chat has ended." : "Permission mode: applies from your next message.");
    effort.IsEnabled = canChange; model.IsEnabled = canChange; account.IsEnabled = canChange && (Model.Accounts.Any(a => a.Id != Model.Snapshot.Definition.AccountId) || navigation is not null);
  }
  private void Render()
  {
    var thisRender = ++renderSerial;
    var nearBottom = scroll.ScrollableHeight - scroll.VerticalOffset < 100;
    var previousOffset = scroll.VerticalOffset;
    PrepareUnread(nearBottom);
    messageElements.Clear();
    UpdateSearchMatches();
    title.Text = Model.Snapshot.Definition.Title;
    var desired = new List<UIElement>();
    var rows = Model.Rows;
    if (searchWindowStart is null && rows.Count > visibleMessages) desired.Add(earlierMessages ??= Button("Show earlier messages", () => { visibleMessages += 200; Render(); return Task.CompletedTask; }));
    var visible = searchWindowStart is { } start && searchBar.Visibility == Visibility.Visible ? rows.Skip(start).Take(200) : rows.TakeLast(visibleMessages);
    foreach (var row in visible)
    {
      if (row.Kind == "error" && row.Text == Model.Snapshot.Problem) continue;
      var rowKey = row.Kind + ":" + row.Id;
      var message = row.Kind == "user" ? Model.Snapshot.Messages.FirstOrDefault(m => m.ClientId == row.ClientId) : null;
      var mediaKey = message is null ? "" : message.State + ":" + ChatSessions.Unconfirmed(Model.Snapshot, message) + ":" + string.Join(',', message.Media.Select(m => m.Id));
      var query = searchBar.Visibility == Visibility.Visible ? searchBox.Text : "";
      void AddRow(FrameworkElement element)
      { desired.Add(element); messageElements[rowKey] = element; rowCache[rowKey] = new(row, query, Model.Snapshot.Stopping, mediaKey, element); }
      if (rowCache.TryGetValue(rowKey, out var cached) && cached.Query == query && cached.Stopping == Model.Snapshot.Stopping && cached.MediaKey == mediaKey)
      {
        if (cached.Row == row) { AddRow(cached.Element); continue; }
        if (query.Length == 0 && row.Kind is "user" or "assistant" && richMessages.TryGetValue(rowKey, out var rich))
        { rich.UpdateHtml(ChatRichContent.Html(row.Text, Model.Snapshot.Definition.Cwd)); AddRow(cached.Element); continue; }
      }
      var content = new StackPanel { Spacing = 8 };
      if (row.Kind == "reasoning")
      {
        var summary = new Expander { Header = "Reasoning", Content = Words(row.Text, 12), HorizontalAlignment = HorizontalAlignment.Stretch };
        RetainExpansion(summary, rowKey); AddRow(summary); continue;
      }
      if (row.Kind == "tool")
      {
        var expander = ChatAppearance.ToolStep(row.Text, row.Details, row.Waiting, row.Status == "Failed");
        RetainExpansion(expander, rowKey); content.Children.Add(expander); content.Children.Add(ChatToolContent.Render(Model.Snapshot, row, Model.DataDirectory, navigation?.Mcp, () => Model.Snapshot, CopyText, ShowLinkError, ShowChatDialogAsync, this)); AddRow(content); continue;
      }
      if (searchBar.Visibility == Visibility.Visible && searchBox.Text.Length > 0) content.Children.Add(SearchText(row.Text));
      else if (row.Kind is "assistant" or "user")
      {
        var rich = (RichChatWebView)ChatMarkdownView.Render(row.Text, CopyText, ShowLinkError, Model.Snapshot.Definition.Cwd, Model.DataDirectory);
        richMessages[rowKey] = rich; content.Children.Add(rich);
      }
      else content.Children.Add(Words(row.Text));
      if (row.Kind == "user" && row.ClientId is { } client)
      {
        message = Model.Snapshot.Messages.FirstOrDefault(m => m.ClientId == client);
        foreach (var image in message?.Media ?? []) content.Children.Add(ImagePreview(image));
        if (message?.State == ChatMessageState.Uncertain) content.Children.Add(Words(ChatSessions.Unconfirmed(Model.Snapshot, message) ? "Delivery is being checked. This message will not be sent twice." : "Kept without resending. Delivery remains uncertain.", 12));
      }
      if (row.Kind is "user" or "assistant")
      {
        var copy = Button("Copy", () => { CopyText(Model.Rows.FirstOrDefault(r => r.Id == row.Id && r.Kind == row.Kind)?.Text ?? row.Text); return Task.CompletedTask; }); copy.MinHeight = 28; copy.FontSize = 11;
        var at = Model.Snapshot.Events.FirstOrDefault(e => e.Id == row.Id)?.At;
        if (at is { } time && time != default) ToolTipService.SetToolTip(content, time.ToLocalTime().ToString("F"));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(copy);
        actions.Children.Add(Button("Rewind", () => BranchMessageAsync(row, true)));
        actions.Children.Add(Button("Fork", () => BranchMessageAsync(row, false)));
        content.Children.Add(actions);
      }
      if (row.Kind == "approval")
      {
        content.Children.Insert(0, Words("Approval needed", 15));
        content.Children.Add(Words("Working folder: " + Model.Snapshot.Definition.Cwd, 12));
        var preview = ChatApprovalPreview.Read(row.Details);
        if (preview.Path is { } path) content.Children.Add(Words("Requested path: " + path, 12));
        var changes = new StackPanel { Spacing = 4 };
        if (preview.Patch is { } patch) changes.Children.Add(Words(patch, 12));
        else
        {
          if (preview.Before is { } before) changes.Children.Add(Words("− Before\n" + before, 12));
          else changes.Children.Add(Words("Before text was not reported. This is not a complete file diff.", 12));
          if (preview.After is { } after) changes.Children.Add(Words("+ After\n" + after, 12));
        }
        if (!preview.HasPreview) changes.Children.Add(Words("This provider did not include a change preview. Check the exact operation arguments before deciding.", 12));
        if (preview.Truncated) changes.Children.Add(Words("Preview truncated at 20000 characters per field. Exact operation arguments are kept below.", 12));
        var changePreview = new Expander { Header = "Change preview", Content = changes, HorizontalAlignment = HorizontalAlignment.Stretch }; RetainExpansion(changePreview, rowKey + ":changes"); content.Children.Add(changePreview);
        var details = new Expander { Header = "Operation arguments", Content = Words(row.Details, 13) }; RetainExpansion(details, rowKey + ":arguments"); content.Children.Add(details);
        if (row.Waiting)
        {
          var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
          var allow = Button("Allow once", () => Model.AnswerAsync(row.Id, true)); var refuse = Button("Deny", () => Model.AnswerAsync(row.Id, false));
          allow.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
          allow.IsEnabled = refuse.IsEnabled = !Model.Snapshot.Stopping; actions.Children.Add(refuse); actions.Children.Add(allow); content.Children.Add(actions);
        }
        else content.Children.Add(Words(row.Status, 12));
      }
      if (row.Kind == "user") foreach (var words in content.Children.OfType<TextBlock>()) words.Style = (Style)Resources["UserText"];
      FrameworkElement card = row.Kind == "assistant" ? ChatAppearance.Reply(content, Model.Snapshot.Definition.Provider) : Card(content, row.Kind == "user");
      AutomationProperties.SetName(card, row.Kind + ": " + row.Text); AddRow(card);
    }
    RenderPending();
    if (pending.Children.Count > 0) desired.Add(pending);
    if (Model.Snapshot.Busy || Model.Sending)
    {
      var loading = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Left };
      // Content-sized pending feedback remains visible before the first token.
      loading.Children.Add(Words(Model.Sending && !Model.Snapshot.Busy ? "Sending…" : Model.Snapshot.Stopping ? "Stopping…" : "Working…", 13));
      loading.Children.Add(new Border { Width = 260, Height = 12, Style = (Style)Resources["ChatSkeleton"] });
      loading.Children.Add(new Border { Width = 180, Height = 12, HorizontalAlignment = HorizontalAlignment.Left, Style = (Style)Resources["ChatSkeleton"] }); desired.Add(loading);
    }
    if (rows.Count == 0 && pending.Children.Count == 0 && !Model.Sending && !Model.Snapshot.Busy)
    {
      var name = navigation?.AgentName ?? ChatAppearance.ProviderName(Model.Snapshot.Definition.Provider);
      var empty = ChatAppearance.Empty("Ask " + name + " anything in this session.", Model.Snapshot.Definition.Provider);
      if (Model.Accounts.FirstOrDefault(a => a.Id == Model.Snapshot.Definition.AccountId) is not { SignedIn: true })
        empty.Children.Add(Button("Sign in", () => Model.SignInAsync()));
      desired.Add(empty);
    }
    var retained = new HashSet<UIElement>(desired);
    for (var i = messages.Children.Count - 1; i >= 0; i--) if (!retained.Contains(messages.Children[i])) messages.Children.RemoveAt(i);
    for (var i = 0; i < desired.Count; i++)
    {
      if (i < messages.Children.Count && ReferenceEquals(messages.Children[i], desired[i])) continue;
      var previousIndex = messages.Children.IndexOf(desired[i]); if (previousIndex >= 0) messages.Children.RemoveAt(previousIndex);
      messages.Children.Insert(i, desired[i]);
    }
    while (messages.Children.Count > desired.Count) messages.Children.RemoveAt(messages.Children.Count - 1);
    foreach (var key in rowCache.Keys.Where(key => !messageElements.ContainsKey(key)).ToArray()) { rowCache.Remove(key); richMessages.Remove(key); }
    FitRows(); RenderProblem(); UpdateControls();
    if (!nearBottom) _ = DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { if (thisRender != renderSerial || findNavigationPending) return; scroll.UpdateLayout(); scroll.ChangeView(null, previousOffset, null, true); });
    if (nearBottom) _ = DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
    {
      if (thisRender != renderSerial || findNavigationPending) return;
      // Queue cards change the history viewport after this render. Measure that
      // layout before following the bottom, so approval buttons stay reachable.
      scroll.UpdateLayout(); scroll.ChangeView(null, scroll.ScrollableHeight, null, true);
    });
  }
  private void FitRows()
  {
    var width = Math.Max(0, Math.Min(688, messages.Width));
    if (double.IsNaN(width)) return;
    foreach (var row in messages.Children.OfType<FrameworkElement>()) row.MaxWidth = row is Border && row.HorizontalAlignment == HorizontalAlignment.Right ? Math.Min(520, width) : width;
    foreach (var row in pending.Children.OfType<FrameworkElement>()) row.MaxWidth = Math.Min(520, width);
  }
  private void RenderPending()
  {
    pending.Children.Clear();
    foreach (var message in Model.Pending)
    {
      var body = new StackPanel { Spacing = 8 }; body.Children.Add(Words("Queued", 12)); body.Children.Add(Words(message.Text));
      foreach (var image in message.Media) body.Children.Add(ImagePreview(image));
      var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      actions.Children.Add(Button("Send now", () => Model.SendNowAsync(message.ClientId)));
      actions.Children.Add(Button("Edit", async () =>
      {
        var text = new TextBox { Text = message.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinWidth = 260 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Edit queued message", Content = text, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.EditAsync(message.ClientId, text.Text);
      }));
      actions.Children.Add(Button("Remove", () => Model.RemoveAsync(message.ClientId))); body.Children.Add(actions);
      var card = Card(body, true); card.HorizontalAlignment = HorizontalAlignment.Stretch;
      var outline = (Microsoft.UI.Xaml.Shapes.Rectangle)XamlReader.Load("""
        <Rectangle xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" RadiusX="18" RadiusY="18" Stroke="{ThemeResource TextFillColorSecondaryBrush}" StrokeThickness="1" StrokeDashArray="4,4" IsHitTestVisible="False"/>
        """);
      var queued = new Grid { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
      queued.Children.Add(card); queued.Children.Add(outline); pending.Children.Add(queued);
    }
  }
  private string? displayedProblem;
  private void RenderProblem()
  {
    var text = Model.Snapshot.Ended ? null : Model.Error ?? Model.Snapshot.Problem;
    if (text == displayedProblem) return;
    displayedProblem = text; problem.Children.Clear(); if (text is null) return;
    var actions = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Left };
    if (text == ChatErrors.OriginalFilesNeeded)
    {
      actions.Children.Add(Button("Prepare failed prompt", () =>
      {
        if (Model.Snapshot.Messages.LastOrDefault(m => m.State == ChatMessageState.Failed) is { } failed)
          Model.Draft += (Model.Draft.Length > 0 ? "\n\n" : "") + failed.Text;
        return Task.CompletedTask;
      }));
      actions.Children.Add(Button("Reattach original photos…", PickImagesAsync));
    }
    else if (ChatErrors.IsUsageLimit(text))
    {
      // Same account menu as the chip: switching keeps this conversation.
      actions.Children.Add(Button("Switch account", () => { ShowAccounts(); return Task.CompletedTask; }));
      if (Model.Snapshot.Messages.Any(m => m.State == ChatMessageState.Failed)) actions.Children.Add(Button("Retry message", () => Model.RetryAsync()));
    }
    else if (text.StartsWith("Not signed in", StringComparison.Ordinal))
    {
      actions.Children.Add(Button("Sign in", () => Model.SignInAsync()));
      if (Model.Snapshot.Messages.Any(m => m.State == ChatMessageState.Failed)) actions.Children.Add(Button("Retry message", () => Model.RetryAsync()));
    }
    else if (Model.Snapshot.Messages.Any(m => ChatSessions.Unconfirmed(Model.Snapshot, m)) || text.Contains("connect", StringComparison.OrdinalIgnoreCase) || text.Contains("may have reached", StringComparison.Ordinal))
    {
      actions.Children.Add(Button("Reconnect", () => Model.ReconnectAsync()));
      if (!Model.Snapshot.Busy && Model.Snapshot.Messages.Any(m => m.State == ChatMessageState.Uncertain && ChatSessions.Unconfirmed(Model.Snapshot, m)))
        actions.Children.Add(Button("Continue without resending", () => Model.ContinueWithoutResendingAsync()));
    }
    else if (Model.Error is not null) actions.Children.Add(Button("Dismiss", () => { Model.ClearError(); return Task.CompletedTask; }));
    else actions.Children.Add(Button("Retry", () => Model.RetryAsync()));
    // A "Dismiss" action already clears the error; never show a second close control.
    var notice = new Notices.CompactNotice { Message = text, Severity = InfoBarSeverity.Error, ActionButton = actions.Children.Count > 0 ? actions : null, Scope = this, IsOpen = true, IsClosable = !actions.Children.OfType<Button>().Any(b => Equals(b.Content, "Dismiss")) };
    AutomationProperties.SetAutomationId(notice, "chat.error"); problem.Children.Add(notice);
  }
  private FrameworkElement ImagePreview(ChatMedia media)
  {
    if (media.MimeType == "application/pdf")
    {
      var document = new Button { Content = "PDF · " + media.Name + " · " + Math.Ceiling(media.Bytes / 1024d) + " KB", HorizontalAlignment = HorizontalAlignment.Left };
      document.Click += async (_, _) =>
      {
        try
        {
          var bytes = await Model.ReadImageAsync(media); var directory = Model.AttachmentPreviewDirectory; TerminalDeck.Platform.Windows.WindowsPrivateDirectory.Ensure(directory);
          var path = Path.Combine(directory, media.Id + ".pdf"); await File.WriteAllBytesAsync(path, bytes); await Windows.System.Launcher.LaunchFileAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(path));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
          problem.Children.Clear();
          problem.Children.Add(new Notices.CompactNotice { Message = ex.Message, Severity = InfoBarSeverity.Error, Scope = this, IsOpen = true, IsClosable = true });
        }
      };
      return document;
    }
    var image = new Image { MaxWidth = 300, MaxHeight = 220, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
    AutomationProperties.SetName(image, media.Name);
    async Task Load()
    {
      try
      {
        var bytes = await Model.ReadImageAsync(media); using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
        stream.Seek(0); var bitmap = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(); await bitmap.SetSourceAsync(stream); image.Source = bitmap;
      }
      catch (Exception ex) when (ex is IOException or ArgumentException or OperationCanceledException or System.Runtime.InteropServices.COMException) { image.Visibility = Visibility.Collapsed; }
    }
    _ = Load(); return image;
  }
  private void RenderAttachments()
  {
    attachments.Children.Clear();
    foreach (var image in Model.Attachments)
    {
      var tile = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, MaxWidth = 280 };
      var preview = ImagePreview(image); preview.Width = 48; preview.Height = 40; tile.Children.Add(preview);
      tile.Children.Add(new TextBlock { Text = image.Name, FontSize = 12, MaxWidth = 170, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
      var remove = Button("Remove " + image.Name, () => { Model.RemoveAttachment(image.Id); return Task.CompletedTask; });
      ChatAppearance.IconButton(remove, "\uE711", "Remove " + image.Name); tile.Children.Add(remove);
      attachments.Children.Add(new Border { Child = tile, Style = (Style)Resources["ChatCard"], Padding = new Thickness(8), CornerRadius = new CornerRadius(10) });
    }
    attachments.Visibility = Model.Attachments.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
  }
  internal ContentDialog? UnavailableModelsForProof { get; private set; }
  internal MenuFlyout? ModelMenuForProof { get; private set; }
  private async Task ShowModelsAsync()
  {
    if (Model.Snapshot.Busy || Model.Snapshot.Ended) return;
    var menu = new MenuFlyout();
    void Populate(IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel> choices, bool loading)
    {
      menu.Items.Clear();
      if (choices.Count == 0)
      {
        menu.Items.Add(new MenuFlyoutItem { Text = loading ? "Loading models…" : Model.ModelReadProblem ?? "Models unavailable · check Coding AIs", IsEnabled = false });
        return;
      }
      if (Model.SelectedModelId is { Length: > 0 } saved && !choices.Any(m => m.Id == saved))
        menu.Items.Add(new MenuFlyoutItem { Text = "Saved model: " + saved + " · not offered by this account", IsEnabled = false });
      foreach (var choice in choices)
      {
        var item = new ToggleMenuFlyoutItem { Text = choice.Name + (choice.ContextTokens >= 1_000_000 ? " · 1M context" : ""), IsChecked = choice.Id == Model.SelectedModelId };
        item.Click += async (_, _) => await Model.SetOptionsAsync(Model.Snapshot.Definition.Options with { Model = choice.Id });
        menu.Items.Add(item);
      }
    }
    ModelMenuForProof = menu;
    Populate(Model.AvailableModels, true); menu.ShowAt(model);
    var choices = await Model.ModelsAsync();
    if (!Model.Snapshot.Busy && !Model.Snapshot.Ended) Populate(choices, false);
    UpdateControls();
  }
  private void ShowEffort()
  {
    var menu = new MenuFlyout();
    foreach (var choice in TerminalDeck.Core.Accounts.ModelEfforts.For(Model.Snapshot.Definition.Provider, Model.AvailableModels.FirstOrDefault(m => m.Id == Model.SelectedModelId)))
    {
      var item = new ToggleMenuFlyoutItem { Text = choice == "auto" ? "Automatic" : ChatAppearance.EffortName(choice), IsChecked = choice == Model.Snapshot.Definition.Options.Effort || choice == "auto" && Model.Snapshot.Definition.Options.Effort.Length == 0 };
      item.Click += async (_, _) => await Model.SetOptionsAsync(Model.Snapshot.Definition.Options with { Effort = choice }); menu.Items.Add(item);
    }
    menu.ShowAt(effort);
  }
  private void ShowAccounts(FrameworkElement? anchor = null)
  {
    if (!account.IsEnabled)
    {
      controlFeedback.Text = "Finish the current answer and queued messages before switching, or open Coding AIs to manage accounts.";
      controlFeedback.Visibility = Visibility.Visible;
      return;
    }
    var menu = new MenuFlyout();
    foreach (var choice in Model.Accounts)
    {
      var item = new ToggleMenuFlyoutItem { Text = choice.Name + (choice.SignedIn ? "" : " · Not signed in"), IsChecked = choice.Id == Model.Snapshot.Definition.AccountId };
      item.Click += async (_, _) =>
      {
        if (!choice.SignedIn)
        {
          if (navigation?.SignIn is not { } signIn) { await Model.SignInAsync(); return; }
          try { await signIn(choice.Id); }
          catch (TerminalDeck.Core.Accounts.SignInCancelledException) { return; }
          if (!Model.Accounts.Any(a => a.Id == choice.Id && a.SignedIn)) return;
        }
        await Model.SetAccountAsync(choice.Id);
      }; menu.Items.Add(item);
    }
    if (navigation is not null)
    { var add = new MenuFlyoutItem { Text = "Add account…" }; add.Click += (_, _) => navigation.OpenCodingAis(); menu.Items.Add(add); }
    menu.ShowAt(anchor ?? this);
  }
  private async Task PickImagesAsync()
  {
    // A retained chat may have moved to another app window since it was created.
    var windowHandle = currentWindowHandle();
    if (windowHandle == 0) { await Model.RunAsync(() => throw new InvalidOperationException("This window needs to be connected before choosing images.")); return; }
    try
    {
      var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);
      picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg"); picker.FileTypeFilter.Add(".gif"); picker.FileTypeFilter.Add(".webp"); if (Model.Snapshot.Definition.Provider == "claude") picker.FileTypeFilter.Add(".pdf");
      foreach (var file in await picker.PickMultipleFilesAsync())
      {
        if (Model.Attachments.Count >= 8) throw new InvalidOperationException("Send or remove an image before adding more.");
        var image = await ChatImageScaler.PrepareAsync(file);
        await Model.AddImageAsync(image.Name, image.MimeType, image.Bytes, image.Width, image.Height);
      }
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Runtime.InteropServices.COMException)
    { await Model.RunAsync(() => throw new InvalidOperationException(ex is System.Runtime.InteropServices.COMException ? "This image could not be opened. Choose a PNG or JPEG file." : ex.Message)); }
  }
  public ValueTask DisposeAsync() => Model.DisposeAsync();
}
