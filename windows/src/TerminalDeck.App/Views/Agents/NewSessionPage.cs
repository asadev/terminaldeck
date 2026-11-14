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
  Func<Task> Ready);

// The New session page IS the chat window with no session yet (owner, 14 Nov: "It should be looking
// like all other chat windows"). The bar, the frame, the empty line and the box are the open chat's
// own parts (ChatBar, ChatFrame, ChatAppearance.Empty, ChatComposerBox). The only extra controls:
// project and agent in ONE menu on the bar's second line, and the small Chat · Terminal switch at the
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
  private readonly StackPanel modes = new() { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
  private readonly ToggleButton chatMode = new() { Content = "Chat" };
  private readonly ToggleButton terminalMode = new() { Content = "Terminal" };
  private readonly Notices.CompactNotice problem = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
  private readonly List<NewSessionFile> files = [];
  private IReadOnlyList<NewSessionFile> sending = [];
  private NewSessionStart choices;
  private IReadOnlyList<ProviderModel> models = [];
  private int modelRead;

  public NewSessionPage(NewSessionPageServices services, NewSessionMemory memory, string? projectId)
  {
    this.services = services; this.memory = memory;
    flow = new((start, text, ct) => services.Start(start, text, sending, ct));
    choices = NewSessionPresets.Resolve(memory.Last(), services.World(), projectId);
    AutomationProperties.SetAutomationId(this, "newSession.page");
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    this.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");

    // The bar: "New session" where the chat's title is; the project (and agent) where the chat's
    // folder is, then the dot and the same account chip.
    var bar = ChatBar.Frame(false);
    bar.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");
    var identity = ChatBar.Identity();
    identity.Children.Add(ChatBar.Title("New session"));
    var line = ChatBar.Line();
    projectChip = ChatBar.ProjectChip("");
    AutomationProperties.SetAutomationId(projectChip, "newSession.project");
    projectChip.Flyout = ProjectMenu();
    accountChip = ChatBar.AccountChip("");
    AutomationProperties.SetAutomationId(accountChip, "newSession.account");
    accountChip.Flyout = AccountMenu();
    line.Children.Add(projectChip); line.Children.Add(dot); line.Children.Add(accountChip);
    identity.Children.Add(line); bar.Children.Add(identity);
    foreach (var mode in new[] { chatMode, terminalMode })
    {
      mode.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      mode.MinHeight = 28; mode.MinWidth = 32; mode.Padding = new Thickness(8, 4, 8, 4); mode.FontSize = 12;
      modes.Children.Add(mode);
    }
    chatMode.Click += (_, _) => { choices = NewSessionPresets.WithMode(choices, "chat"); Show(); };
    terminalMode.Click += (_, _) => { choices = NewSessionPresets.WithMode(choices, "terminal"); Show(); };
    AutomationProperties.SetName(modes, "Open as"); AutomationProperties.SetAutomationId(chatMode, "newSession.chat"); AutomationProperties.SetAutomationId(terminalMode, "newSession.terminal");
    SetColumn(modes, 1); bar.Children.Add(modes);
    Children.Add(bar);

    // The chat's own frame, column, empty line and box.
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

  // Shown again (New session pressed, or the app opened): take the keyboard and refresh the lists.
  public void Arrive(string? projectId)
  {
    if (projectId is not null && box.Text.Text.Length == 0) choices = NewSessionPresets.WithProject(choices, projectId, services.World());
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
    // Project (and agent) on the bar's second line, like the chat's folder.
    var place = services.ProjectName(choices.ProjectId) + (choices.AgentId is { } agent ? " · " + services.AgentName(agent) : "");
    ((TextBlock)projectChip.Content).Text = place;
    ToolTipService.SetToolTip(projectChip, "Project and agent · " + place); AutomationProperties.SetName(projectChip, "Project and agent: " + place);
    var account = choices.AccountId is { } id ? services.Accounts(provider).FirstOrDefault(a => a.Id == id) : null;
    var accountLabel = NewSessionPresets.UsesAccount(provider) ? account is null ? name + " · add an account" : account.Name + (account.SignedIn ? "" : " · sign-in needed") : name;
    accountChip.Content = accountLabel; ToolTipService.SetToolTip(accountChip, accountLabel); AutomationProperties.SetName(accountChip, "AI and account: " + accountLabel);
    // Chat · Terminal only for an AI that can chat.
    modes.Visibility = NewSessionPresets.CanChat(provider) ? Visibility.Visible : Visibility.Collapsed;
    chatMode.IsChecked = choices.Mode == "chat"; terminalMode.IsChecked = choices.Mode == "terminal";
    // The empty line: the chat's own, with what this page does.
    column.Children.Clear();
    var line = choices.AgentId is { } who ? "Ask " + services.AgentName(who) + " anything. Your first message starts the session." : "Ask " + name + " anything. Your first message starts the session.";
    column.Children.Add(ChatAppearance.Empty(line, provider));
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
  private TextBlock Chip(string text) => new() { Text = text, TextTrimming = TextTrimming.CharacterEllipsis, Style = (Style)frame.Resources["ChatChoiceText"] };

  // ONE menu for where the session runs: his projects, the chosen project's agents, No project,
  // Choose folder is the full form's job, so "All choices…" sits at its foot.
  private MenuFlyout ProjectMenu()
  {
    var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      var world = services.World();
      foreach (var id in new[] { ProjectIdentity.IndependentId }.Concat(world.ProjectIds.Where(p => p != ProjectIdentity.IndependentId)))
      {
        var item = new ToggleMenuFlyoutItem { Text = id == ProjectIdentity.IndependentId ? "No project" : services.ProjectName(id), IsChecked = id == choices.ProjectId };
        var chosen = id;
        item.Click += (_, _) => { choices = NewSessionPresets.WithProject(choices, chosen, services.World()); Show(); };
        menu.Items.Add(item);
      }
      var agents = NewSessionPresets.AgentsFor(choices.ProjectId, world);
      if (agents.Count > 0)
      {
        var sub = new MenuFlyoutSubItem { Text = "Agent in " + services.ProjectName(choices.ProjectId) };
        var none = new ToggleMenuFlyoutItem { Text = "No agent", IsChecked = choices.AgentId is null };
        none.Click += (_, _) => { choices = NewSessionPresets.WithAgent(choices, null, services.World()); Show(); };
        sub.Items.Add(none);
        foreach (var agent in agents)
        {
          var row = new ToggleMenuFlyoutItem { Text = agent.Name + (agent.Lead && agent.ProjectId == choices.ProjectId ? " (lead)" : ""), IsChecked = agent.Id == choices.AgentId };
          var chosen = agent.Id;
          row.Click += (_, _) => { choices = NewSessionPresets.WithAgent(choices, chosen, services.World()); Show(); };
          sub.Items.Add(row);
        }
        menu.Items.Add(new MenuFlyoutSeparator()); menu.Items.Add(sub);
      }
      menu.Items.Add(new MenuFlyoutSeparator());
      var all = new MenuFlyoutItem { Text = "All choices…" };
      AutomationProperties.SetAutomationId(all, "newSession.allChoices");
      all.Click += (_, _) => services.AllChoices(choices.ProjectId == ProjectIdentity.IndependentId ? null : choices.ProjectId);
      menu.Items.Add(all);
    };
    return menu;
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
          var item = new ToggleMenuFlyoutItem { Text = account.Name + (account.SignedIn ? "" : " · Not signed in"), IsChecked = choices.Provider == provider && choices.AccountId == account.Id };
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
