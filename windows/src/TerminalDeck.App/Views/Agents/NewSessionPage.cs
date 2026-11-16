using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using Windows.Storage.Pickers;

namespace TerminalDeck.App.Views.Agents;

// A file added with "+" before the session exists: a photo for a chat, its path for a terminal.
internal sealed record NewSessionFile(string Name, string Path, PreparedChatImage Image);

// What the page needs from the window. It never starts anything by itself: Start runs only for
// his own send.
internal sealed record NewSessionPageServices(
  Func<NewSessionWorld> World,
  Func<string, string> ProjectName,
  Func<string, string> AgentName,
  Func<string, IReadOnlyList<AccountProfile>> Accounts,
  Func<string, string?, IReadOnlyList<ProviderModel>> InstantModels,
  Func<string, CancellationToken, Task<IReadOnlyList<ProviderModel>>> LiveModels,
  Func<NewSessionStart, (string Model, string? Effort, bool OwnedByAgent)> ModelAndEffort,
  Func<NewSessionStart, AiPermissionMode?> StartPermission,
  Func<string, string> ProviderName,
  Func<NewSessionStart, string, IReadOnlyList<NewSessionFile>, CancellationToken, Task<string>> Start,
  Action<string> Started,
  Action<string?> AllChoices,
  Action OpenCodingAis,
  Func<nint> WindowHandle,
  Func<Task> Ready,
  Func<NewSessionStart, string, string, IReadOnlyList<NewSessionFile>, CancellationToken, Task<string>>? StartInFolder = null);
// AllChoices is no longer opened from this page (owner, 15 Nov: "Only two options instead of a very big
// line and all choices thing"); the full form stays for its other callers. StartInFolder starts in the
// folder he picked with "Choose folder…" (start, folder, text, files); the item shows only when it is wired.

// The New session page IS the chat window with no session yet (owner, 14 Nov: "It should be looking
// like all other chat windows"). The bar, the frame and the box are the open chat's own parts
// (ChatBar, ChatFrame, ChatComposerBox); above the box the page stays calm and empty (15 Nov: no AI
// mark, no sentence). "New session" is written once, by the window bar. The only extra controls:
// project, folder and agent in ONE menu on the bar's line, and the Chat | Terminal switch at the
// bar's trailing end, where an open chat keeps its own controls.
internal sealed class NewSessionPage : Grid
{
  private readonly NewSessionPageServices services;
  private readonly NewSessionMemory memory;
  private readonly NewSessionFlow flow;
  private readonly ChatComposerBox box = new();
  private readonly Grid frame = new();
  private readonly ComposerEnter enter = new();
  private readonly StackPanel column = ChatFrame.Column();
  private readonly Button projectChip;
  private readonly Button accountChip;
  private readonly TextBlock dot = ChatBar.Dot();
  private readonly StackPanel modes = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
  private readonly Border modeSwitch = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(2), BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Center };
  private readonly ToggleButton chatMode = new() { Content = "Chat" };
  private readonly ToggleButton terminalMode = new() { Content = "Terminal" };
  private readonly Notices.CompactNotice problem = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
  private readonly List<NewSessionFile> files = [];
  private IReadOnlyList<NewSessionFile> sending = [];
  private NewSessionStart choices;
  // A folder picked with "Choose folder…" (the session runs there, with no project); null otherwise.
  private string? folder;
  private IReadOnlyList<ProviderModel> models = [];
  private int modelRead;

  public NewSessionPage(NewSessionPageServices services, NewSessionMemory memory, string? projectId)
  {
    this.services = services; this.memory = memory;
    flow = new((start, text, ct) => folder is { } picked && services.StartInFolder is { } inFolder
      ? inFolder(start, picked, text, sending, ct) : services.Start(start, text, sending, ct));
    choices = NewSessionPresets.Resolve(memory.Last(), services.World(), projectId);
    AutomationProperties.SetAutomationId(this, "newSession.page");
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    this.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");

    // The bar: the project (and agent) where the chat's folder is, then the dot and the same account
    // chip. No title here: the window bar already says "New session" (15 Nov: written once).
    var bar = ChatBar.Frame(false);
    bar.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");
    var identity = ChatBar.Identity();
    var line = ChatBar.Line();
    projectChip = ChatBar.ProjectChip("");
    AutomationProperties.SetAutomationId(projectChip, "newSession.project");
    projectChip.Flyout = ProjectMenu();
    accountChip = ChatBar.AccountChip("");
    AutomationProperties.SetAutomationId(accountChip, "newSession.account");
    accountChip.Flyout = AccountMenu();
    line.Children.Add(projectChip); line.Children.Add(dot); line.Children.Add(accountChip);
    // The bar says "New session" on this page (15 Nov); the page itself has no other heading.
    identity.Children.Add(ChatBar.Title("New session"));
    identity.Children.Add(line); bar.Children.Add(identity);
    Quiet(projectChip); Quiet(accountChip);
    foreach (var mode in new[] { chatMode, terminalMode })
    {
      mode.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      mode.MinHeight = 26; mode.MinWidth = 72; mode.Padding = new Thickness(10, 3, 10, 3); mode.FontSize = 12;
      mode.CornerRadius = new CornerRadius(6); mode.HorizontalContentAlignment = HorizontalAlignment.Center;
      modes.Children.Add(mode);
    }
    // One segmented switch: both choices in one rounded track, the chosen one filled.
    modeSwitch.Child = modes;
    modeSwitch.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush");
    modeSwitch.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
    chatMode.Click += (_, _) => { choices = NewSessionPresets.WithMode(choices, "chat"); Show(); };
    terminalMode.Click += (_, _) => { choices = NewSessionPresets.WithMode(choices, "terminal"); Show(); };
    AutomationProperties.SetName(modes, "Open as"); AutomationProperties.SetAutomationId(chatMode, "newSession.chat"); AutomationProperties.SetAutomationId(terminalMode, "newSession.terminal");
    SetColumn(modeSwitch, 1); bar.Children.Add(modeSwitch);
    Children.Add(bar);

    // The chat's own frame, column and box.
    ChatFrame.Layout(frame); SetRow(frame, 1);
    var scroll = ChatFrame.History(column, () => { });
    AutomationProperties.SetAutomationId(scroll, "newSession.history"); SetRow(scroll, 1); frame.Children.Add(scroll);
    problem.Scope = frame; frame.Children.Add(problem);
    var addMenu = new MenuFlyout();
    var photos = new MenuFlyoutItem { Text = "Add photos…" }; photos.Click += async (_, _) => await PickFilesAsync(); addMenu.Items.Add(photos);
    box.Attach.Flyout = addMenu;
    box.Dictate.Click += (_, _) =>
    {
      var sent = TerminalDeck.App.Shell.WindowsVoiceTyping.Start(box.Text);
      box.Feedback.Text = sent ? "Windows voice typing requested. Your words stay in the box." : "Click in the message and press Win+H to open Windows voice typing.";
      box.Feedback.Visibility = Visibility.Visible;
    };
    box.Stop.Visibility = Visibility.Collapsed;
    box.Model.Click += async (_, _) => await ShowModelsAsync();
    box.Effort.Click += (_, _) => ShowEffort();
    // "Before it changes files" is shown, not chosen, on this page: what shows is what starts.
    box.Permission.IsHitTestVisible = false; box.Permission.IsTabStop = false;
    box.Send.Click += async (_, _) => await SendAsync();
    frame.Children.Add(box.Assemble((Style)frame.Resources["ComposerGlass"], null));
    // Under the box: the same small quiet chips as the project and the account (15 Nov), not bare words.
    Quiet(box.Permission); Quiet(box.Model); Quiet(box.Effort);
    frame.SizeChanged += (_, _) => ChatFrame.Fit(frame, box);
    AutomationProperties.SetAutomationId(box.Text, "newSession.box");
    Children.Add(frame);

    box.Text.Text = memory.Draft();
    box.Text.LostFocus += (_, _) => KeepDraft();
    box.Text.PreviewKeyDown += async (_, e) =>
    {
      if (e.Handled || e.Key != Windows.System.VirtualKey.Enter) return;
      var shift = (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
      // Decided now, from the text in the box now.
      switch (enter.Decide(true, shift, NewSessionSend.Allowed(box.Text.Text, files.Count, flow.Starting)))
      {
        case ComposerEnterAction.Send: e.Handled = true; await SendAsync(); break;
        case ComposerEnterAction.Swallow: e.Handled = true; break;
      }
    };
    box.Text.TextCompositionStarted += (_, _) => enter.CompositionStarted();
    box.Text.TextCompositionEnded += (_, _) => enter.CompositionEnded();
    Show();
  }

  // The window learned something new (which AIs are installed): redraw with the same choices where they still fit.
  public void Refresh() { choices = Refit(choices); Show(); }

  // Shown again (New session pressed, or the app opened): take the keyboard and refresh the lists.
  public void Arrive(string? projectId)
  {
    if (projectId is not null && box.Text.Text.Length == 0) { folder = null; choices = NewSessionPresets.WithProject(choices, projectId, services.World()); }
    else choices = Refit(choices);
    Show();
    DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => box.Text.Focus(FocusState.Programmatic));
  }

  // The lists may have changed since the page was drawn (an account removed, a project closed).
  private NewSessionStart Refit(NewSessionStart start)
  {
    var world = services.World();
    var next = NewSessionPresets.WithProject(start, start.ProjectId, world);
    return world.Providers.Contains(next.Provider) ? NewSessionPresets.WithProvider(next, next.Provider, world, next.AccountId) : NewSessionPresets.Resolve(next, world);
  }

  private void Show()
  {
    var provider = choices.Provider; var name = services.ProviderName(provider);
    // Project (or the picked folder's name), and agent, on the bar's line, like the chat's folder.
    var where = folder is { } picked ? FolderName(picked) : services.ProjectName(choices.ProjectId);
    var place = where + (choices.AgentId is { } agent ? " · " + services.AgentName(agent) : "");
    projectChip.Content = Chip(place);
    ToolTipService.SetToolTip(projectChip, "Project and agent · " + place); AutomationProperties.SetName(projectChip, "Project and agent: " + place);
    var account = choices.AccountId is { } id ? services.Accounts(provider).FirstOrDefault(a => a.Id == id) : null;
    var accountLabel = NewSessionPresets.UsesAccount(provider) ? account is null ? name + " · add an account" : account.Name : name;
    // An account that needs sign-in carries an orange dot before its name, never words (15 Nov).
    var needsSignIn = account is { SignedIn: false } && NewSessionPresets.UsesAccount(provider);
    var chipLine = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    if (needsSignIn) chipLine.Children.Add(NeedsDot());
    chipLine.Children.Add(Chip(accountLabel));
    accountChip.Content = chipLine;
    var spoken = needsSignIn ? accountLabel + ", needs sign-in" : accountLabel;
    ToolTipService.SetToolTip(accountChip, spoken); AutomationProperties.SetName(accountChip, "AI and account: " + spoken);
    // Chat · Terminal only for an AI that can chat.
    modeSwitch.Visibility = NewSessionPresets.CanChat(provider) ? Visibility.Visible : Visibility.Collapsed;
    chatMode.IsChecked = choices.Mode == "chat"; terminalMode.IsChecked = choices.Mode == "terminal";
    // Calm and empty above the box: no AI mark, no sentence (owner, 15 Nov).
    column.Children.Clear();
    box.Text.PlaceholderText = NewSessionPresets.CanChat(provider) ? "Message " + name : "Type a command for " + name;
    // The line under the box: the chat's permission, model and effort places.
    var permission = services.StartPermission(choices);
    box.Permission.Visibility = permission is null ? Visibility.Collapsed : Visibility.Visible;
    if (permission is { } mode)
    {
      box.Permission.Content = Chip(ChatPermissionModes.Label(mode));
      AutomationProperties.SetName(box.Permission, "Before it changes files: " + ChatPermissionModes.Label(mode) + ", " + ChatPermissionModes.Explain(mode));
    }
    var (model, effort, owned) = services.ModelAndEffort(choices);
    box.Model.Visibility = NewSessionPresets.CanChat(provider) ? Visibility.Visible : Visibility.Collapsed;
    box.Effort.Visibility = provider is "claude" or "codex" ? Visibility.Visible : Visibility.Collapsed;
    var modelName = model.Length == 0 ? "Default model" : ModelCatalog.Label(provider, model, null) is { Length: > 0 } shown ? shown : model;
    box.Model.Content = Chip(modelName); box.Effort.Content = Chip(effort is null or "" ? "Default effort" : ChatAppearance.EffortName(effort));
    box.Model.IsEnabled = box.Effort.IsEnabled = !owned;
    var reason = owned && choices.AgentId is { } owner ? "Set by " + services.AgentName(owner) : "Model: " + modelName;
    ToolTipService.SetToolTip(box.Model, reason); ToolTipService.SetToolTip(box.Effort, owned ? reason : "Effort");
    box.Attach.Visibility = NewSessionPresets.CanChat(provider) ? Visibility.Visible : Visibility.Collapsed;
    RenderFiles();
  }
  private static string FolderName(string path) => Path.GetFileName(Path.TrimEndingDirectorySeparator(path)) is { Length: > 0 } name ? name : path;
  private static TextBlock Chip(string text)
  {
    var words = new TextBlock { Text = text, FontSize = 12, MaxWidth = 200, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    words.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return words;
  }

  // The app's small quiet chip: a soft fill, a small radius, one line of secondary text.
  private static void Quiet(Button chip)
  {
    chip.SetResourceReference(Control.BackgroundProperty, "DeckControlBrush");
    chip.CornerRadius = new CornerRadius(6); chip.Padding = new Thickness(8, 2, 8, 2);
    chip.Height = 24; chip.MinHeight = 24; chip.MinWidth = 0; chip.FontSize = 12; chip.VerticalAlignment = VerticalAlignment.Center;
  }

  private static Microsoft.UI.Xaml.Shapes.Ellipse NeedsDot()
  {
    var needs = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center };
    needs.SetResourceReference(Microsoft.UI.Xaml.Shapes.Shape.FillProperty, "DeckProjectOrangeBrush");
    return needs;
  }

  // ONE menu for where the session runs (owner, 15 Nov: "it should just give me projects ... instead,
  // we can have a choose folder here"): his projects, then "Choose folder…", then "Choose agent…" for
  // starting with a specific agent. No agents list and no "All choices…" here.
  private MenuFlyout ProjectMenu()
  {
    var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      var world = services.World();
      foreach (var id in new[] { ProjectIdentity.IndependentId }.Concat(world.ProjectIds.Where(p => p != ProjectIdentity.IndependentId)))
      {
        var item = new ToggleMenuFlyoutItem { Text = id == ProjectIdentity.IndependentId ? "No project" : services.ProjectName(id), IsChecked = folder is null && id == choices.ProjectId };
        var chosen = id;
        item.Click += (_, _) => { folder = null; choices = NewSessionPresets.WithProject(choices, chosen, services.World()); Show(); };
        menu.Items.Add(item);
      }
      menu.Items.Add(new MenuFlyoutSeparator());
      if (services.StartInFolder is not null)
      {
        var pick = new MenuFlyoutItem { Text = "Choose folder…" };
        AutomationProperties.SetAutomationId(pick, "newSession.chooseFolder");
        pick.Click += async (_, _) => await ChooseFolderAsync();
        menu.Items.Add(pick);
      }
      var agent = new MenuFlyoutItem { Text = "Choose agent…", IsEnabled = NewSessionPresets.AgentsFor(choices.ProjectId, world).Count > 0 };
      AutomationProperties.SetAutomationId(agent, "newSession.chooseAgent");
      agent.Click += (_, _) => DispatcherQueue.TryEnqueueHandled(ShowAgents);
      menu.Items.Add(agent);
    };
    return menu;
  }

  // The agents that can start here (the project's lead first), as a small menu under the chip.
  private void ShowAgents()
  {
    var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    var none = new ToggleMenuFlyoutItem { Text = "No agent", IsChecked = choices.AgentId is null };
    none.Click += (_, _) => { choices = NewSessionPresets.WithAgent(choices, null, services.World()); Show(); };
    menu.Items.Add(none);
    foreach (var agent in NewSessionPresets.AgentsFor(choices.ProjectId, services.World()))
    {
      var row = new ToggleMenuFlyoutItem { Text = agent.Name + (agent.Lead && agent.ProjectId == choices.ProjectId ? " (lead)" : ""), IsChecked = agent.Id == choices.AgentId };
      var chosen = agent.Id;
      row.Click += (_, _) => { choices = NewSessionPresets.WithAgent(choices, chosen, services.World()); Show(); };
      menu.Items.Add(row);
    }
    menu.ShowAt(projectChip);
  }

  // The folder picker the app uses elsewhere. A picked folder runs the session there, with no project.
  private async Task ChooseFolderAsync()
  {
    var handle = services.WindowHandle();
    if (handle == 0) return;
    try
    {
      if (await TerminalDeck.App.Views.Projects.ProjectAgentUi.PickFolderAsync(handle) is not { } picked) return;
      folder = picked;
      choices = NewSessionPresets.WithProject(choices, ProjectIdentity.IndependentId, services.World());
      Show();
    }
    catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException)
    { problem.Message = "That folder could not be opened. Choose another folder."; problem.IsOpen = true; }
  }

  // The same account list as the chat's chip, grouped by AI: picking another AI's account picks
  // that AI. An AI with no accounts (Shell) is one row under its name.
  private MenuFlyout AccountMenu()
  {
    var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      foreach (var provider in services.World().Providers)
      {
        if (menu.Items.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = services.ProviderName(provider), IsEnabled = false });
        var rows = NewSessionPresets.UsesAccount(provider) ? services.Accounts(provider) : Array.Empty<AccountProfile>();
        if (!NewSessionPresets.UsesAccount(provider) || rows.Count == 0)
        {
          var only = new ToggleMenuFlyoutItem { Text = NewSessionPresets.UsesAccount(provider) ? "No account yet · add one" : services.ProviderName(provider), IsChecked = choices.Provider == provider };
          var ai = provider;
          only.Click += (_, _) => { if (NewSessionPresets.UsesAccount(ai)) services.OpenCodingAis(); else { choices = NewSessionPresets.WithProvider(choices, ai, services.World()); Show(); } };
          menu.Items.Add(only); continue;
        }
        foreach (var account in rows)
        {
          // By name; an account that needs him carries one orange dot, the others nothing.
          var item = new ToggleMenuFlyoutItem { Text = account.Name, IsChecked = choices.Provider == provider && choices.AccountId == account.Id };
          if (!account.SignedIn)
          {
            var needs = new FontIcon { Glyph = "\u25CF", FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI"), FontSize = 10 };
            needs.SetResourceReference(IconElement.ForegroundProperty, "DeckProjectOrangeBrush");
            item.Icon = needs;
            AutomationProperties.SetName(item, account.Name + ", needs sign-in");
          }
          var ai = provider; var id = account.Id;
          item.Click += (_, _) => { choices = NewSessionPresets.WithProvider(choices, ai, services.World(), id); Show(); };
          menu.Items.Add(item);
        }
      }
      menu.Items.Add(new MenuFlyoutSeparator());
      var add = new MenuFlyoutItem { Text = "Add account…" }; add.Click += (_, _) => services.OpenCodingAis(); menu.Items.Add(add);
    };
    return menu;
  }

  private async Task ShowModelsAsync()
  {
    var provider = choices.Provider; var request = ++modelRead;
    var menu = new MenuFlyout();
    void Fill(IReadOnlyList<ProviderModel> rows)
    {
      models = ModelCatalog.Merge(provider, rows, choices.Model);
      menu.Items.Clear();
      var dflt = new ToggleMenuFlyoutItem { Text = "Default model", IsChecked = choices.Model is null };
      dflt.Click += (_, _) => { choices = choices with { Model = null }; Show(); };
      menu.Items.Add(dflt);
      foreach (var row in models)
      {
        var item = new ToggleMenuFlyoutItem { Text = row.Name + (row.ContextTokens >= 1_000_000 ? " · 1M context" : ""), IsChecked = row.Id == choices.Model };
        var id = row.Id; item.Click += (_, _) => { choices = choices with { Model = id }; Show(); };
        menu.Items.Add(item);
      }
    }
    Fill(services.InstantModels(provider, choices.AccountId));
    menu.ShowAt(box.Model);
    if (choices.AccountId is not { } accountId) return;
    try
    {
      var live = await services.LiveModels(accountId, CancellationToken.None);
      if (request == modelRead && choices.Provider == provider) Fill(live);
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
  }

  private void ShowEffort()
  {
    var menu = new MenuFlyout();
    foreach (var level in ModelEfforts.For(choices.Provider, models.FirstOrDefault(m => m.Id == choices.Model)))
    {
      var item = new ToggleMenuFlyoutItem { Text = level == "auto" ? "Automatic" : ChatAppearance.EffortName(level), IsChecked = level == choices.Effort };
      var chosen = level; item.Click += (_, _) => { choices = choices with { Effort = chosen }; Show(); };
      menu.Items.Add(item);
    }
    menu.ShowAt(box.Effort);
  }

  private async Task PickFilesAsync()
  {
    var handle = services.WindowHandle();
    if (handle == 0) return;
    try
    {
      var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, handle);
      foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp" }) picker.FileTypeFilter.Add(type);
      foreach (var file in await picker.PickMultipleFilesAsync())
      {
        if (files.Count >= 8) throw new InvalidOperationException("Send or remove an image before adding more.");
        files.Add(new(file.Name, file.Path, await ChatImageScaler.PrepareAsync(file)));
      }
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Runtime.InteropServices.COMException)
    { problem.Message = ex is System.Runtime.InteropServices.COMException ? "This image could not be opened. Choose a PNG or JPEG file." : ex.Message; problem.IsOpen = true; }
    RenderFiles();
  }

  private void RenderFiles()
  {
    box.Attachments.Children.Clear();
    foreach (var file in files)
    {
      var tile = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, MaxWidth = 280 };
      tile.Children.Add(new TextBlock { Text = file.Name, FontSize = 12, MaxWidth = 170, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
      var remove = new Button();
      ChatAppearance.IconButton(remove, "", "Remove " + file.Name);
      var kept = file; remove.Click += (_, _) => { files.Remove(kept); RenderFiles(); };
      tile.Children.Add(remove);
      box.Attachments.Children.Add(new Border { Child = tile, Style = (Style)frame.Resources["ChatCard"], Padding = new Thickness(8), CornerRadius = new CornerRadius(10) });
    }
    box.Attachments.Visibility = files.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
  }

  private void KeepDraft()
  {
    try { memory.KeepDraft(box.Text.Text); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }

  // His send: exactly one session with the choices as they are, the text as its first message.
  private async Task SendAsync()
  {
    var sent = box.Text.Text; var start = choices;
    sending = files.ToArray();
    box.Feedback.Text = "Starting the session…"; box.Feedback.Visibility = Visibility.Visible;
    var result = await flow.SendAsync(sent, sending.Count, start, services.Ready(), TimeSpan.FromSeconds(10));
    box.Feedback.Visibility = Visibility.Collapsed;
    switch (result.Outcome)
    {
      case NewSessionOutcome.Started:
        try { memory.Remember(start); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        box.Text.Text = NewSessionSend.AfterSend(box.Text.Text, sent);
        foreach (var file in sending) files.Remove(file);
        KeepDraft(); RenderFiles(); problem.IsOpen = false;
        services.Started(result.SessionId!);
        break;
      case NewSessionOutcome.NotReady or NewSessionOutcome.Failed:
        problem.Message = result.Message ?? "The session could not start. Your message is kept here."; problem.IsOpen = true;
        break;
    }
    sending = [];
  }
}
