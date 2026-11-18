using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  // The shell supplies its existing model. A second model would overwrite its saved tabs.
  public BrowserModel? SettingsBrowser { get; set; }
  public void RegisterDirectionTools() => new BrowserStartPageSettings(new JsonStateStore<BrowserStartPage>(runtime.Root, "browser-start-page"), SettingsBrowser).Register(runtime.Door);
  public Func<bool>? ReadCloseConfirmation { get; set; }
  public Action<bool>? SaveCloseConfirmation { get; set; }
  private Notices.CompactNotice directionStatus = new();

  // Settings > Advanced > "Paired with a code" opens the paired devices' own window.
  public Func<bool>? OpenPairedDevices { get; set; }
  // Settings > Profile > Cloud > "Manage files": the Your Cloud page, a full page of the main window.
  public Func<bool>? OpenYourCloud { get; set; }
  // Opens a page of the Settings window through its history (set by SettingsPanel; null in other hosts).
  internal Func<string, Task>? NavigateSettings { get; set; }
  // The account the Settings list's profile row shows.
  internal TerminalDeck.Core.Cloud.CloudAccountClient CloudAccount => runtime.Cloud;
  // Devices and Cloud live inside Profile (Mac, 15 Nov); a device's own page is "device:<id>".
  // "browser" is drawn for the Browser's own small settings window, never for the Settings list.
  internal string ResolveSettingsAccess(string id)
  {
    var snapshot = runtime.Cloud.Snapshot.Subscription;
    if (id == TerminalDeck.Core.Cloud.CloudSubscriptionPageText.Id && !snapshot.ShowsSubscription) return "profile";
    if (!snapshot.AllowsCloudServices && (id == "cloud" || SettingsNavigation.IsDevice(id) || id is "devices" or "devices.older")) return TerminalDeck.Core.Cloud.CloudSubscriptionPageText.Id;
    return id;
  }
  internal FrameworkElement? DirectionPage(string id, Action<string> select) => id switch
  {
    TerminalDeck.Core.Cloud.CloudSubscriptionPageText.Id => new CloudSubscriptionPage(runtime.Cloud),
    "profile" => new ProfilePage(runtime.Cloud, select, async id => { if (runtime.Reach is { } reach) await reach.RemoveIfOnAsync(id); }, ProfilePairedDevices()),
    "personal" => new PersonalPage(runtime.Cloud),
    "sign-in" => new SignInPage(runtime.Cloud),
    _ when SettingsNavigation.IsDevice(id) => new DevicePage(runtime.Cloud, id[SettingsNavigation.DevicePrefix.Length..], select),
    "cloud" => new CloudPage(runtime.Cloud, runtime.CloudSync, () => OpenYourCloud?.Invoke(), () => select("profile")),
    "general" => GeneralSettings(),
    "notifications" => NotificationSettings(),
    "privacy" => PrivacySettings(),
    "advanced" => AdvancedSettings(),
    "agent-defaults" => AgentSettings(),
    "browser" => BrowserSettings(),
    "tasks" => TaskSettings(select),
    "custom-clis" => CustomCliSettings(),
    _ => null
  };

  private FrameworkElement GeneralSettings()
  {
    ToggleSwitch Toggle(bool value, Action<bool> save)
    {
      var toggle = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 40 };
      toggle.Toggled += async (_, _) => await DirectionRunAsync(() => { save(toggle.IsOn); return Task.CompletedTask; });
      return toggle;
    }
    var current = runtime.General.Read();
    var restore = Toggle(current.RestoreSessions, value => runtime.General.Save(runtime.General.Read() with { RestoreSessions = value }));
    // "When Terminal Deck opens" (Mac, 14 Nov): the New session page or where he left off. Windows has no Overview page.
    var opens = new ComboBox { MinWidth = 220, ItemsSource = TerminalDeck.Core.Sessions.OpensOn.OnWindows.Select(TerminalDeck.Core.Sessions.OpensOn.Label).ToArray() };
    opens.SelectedIndex = TerminalDeck.Core.Sessions.OpensOn.OnWindows.ToList().IndexOf(TerminalDeck.Core.Sessions.OpensOn.Normal(current.WhenOpens));
    opens.SelectionChanged += async (_, _) => { if (opens.SelectedIndex >= 0) { var chosen = TerminalDeck.Core.Sessions.OpensOn.OnWindows[opens.SelectedIndex]; await DirectionRunAsync(() => { runtime.General.Save(runtime.General.Read() with { WhenOpens = chosen }); return Task.CompletedTask; }); } };
    AutomationProperties.SetName(opens, "When Terminal Deck opens");
    var rows = new List<FrameworkElement> {
      SettingsPanel.SettingRow("When " + TerminalDeck.Core.Brand.Name + " opens", "New session opens a new chat ready for your first message. Nothing starts until you send it.", opens),
      SettingsPanel.SettingRow("Reopen sessions after a restart", "Reopens projects and sessions after a restart. Sessions that kept running are always kept.", restore),
      SettingsPanel.SettingRow("Name sessions from the conversation", "A tab takes the conversation’s title.", Toggle(current.AutoNameSessions, value => runtime.General.Save(runtime.General.Read() with { AutoNameSessions = value })))
    };
    if (ReadCloseConfirmation is not null && SaveCloseConfirmation is not null)
      rows.Add(SettingsPanel.SettingRow("Confirm before closing a session", "Asks before a working session is closed. “Don’t ask again” turns this off; turn it back on here.", Toggle(ReadCloseConfirmation(), SaveCloseConfirmation)));
    rows.Add(SettingsPanel.SettingRow("Copy on select", "Selecting text in a session copies it.", Toggle(current.CopyOnSelect, value => runtime.General.Save(runtime.General.Read() with { CopyOnSelect = value }))));
    rows.Add(SettingsPanel.SettingRow("Terminal shell", "New terminal tabs open this shell. Open tabs keep theirs.",
      TerminalDeck.App.Views.Settings.TerminalShellChoice.Create(runtime.General, work => DirectionRunAsync(work))));
    {
      // One default for new chats. Each AI offers only the modes it really supports; an unset choice means Bypass (Auto where the AI has it).
      var modes = Enum.GetValues<TerminalDeck.Core.Mcp.AiPermissionMode>().Where(m => new[] { "claude", "codex", "gemini" }.Any(p => TerminalDeck.Core.Chats.ChatPermissionModes.Supported(p).Contains(m))).ToArray();
      var picker = new ComboBox { MinWidth = 220, ItemsSource = modes.Select(m => TerminalDeck.Core.Chats.ChatPermissionModes.Label(m)).ToArray() };
      var shown = current.DefaultPermission ?? TerminalDeck.Core.Chats.ChatPermissionModes.DefaultFor("claude");
      picker.SelectedIndex = Array.IndexOf(modes, shown);
      picker.SelectionChanged += async (_, _) => { if (picker.SelectedIndex >= 0) { var chosen = modes[picker.SelectedIndex]; await DirectionRunAsync(() => { runtime.General.Save(runtime.General.Read() with { DefaultPermission = chosen }); return Task.CompletedTask; }); } };
      AutomationProperties.SetName(picker, "Default permission mode for new chats");
      rows.Add(SettingsPanel.SettingRow("Permission mode for new chats", "New chats start in this mode. You can change it in any chat. An AI that lacks the mode uses its closest default.", picker));
    }
    {
      // Terminal text size (Mac, 15 Nov): moved here from Appearance; the same saved value.
      var size = new NumberBox { Minimum = 9, Maximum = 24, SmallChange = 1, Value = runtime.TerminalAppearance.Preferences().FontSize, Width = 120, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
      size.ValueChanged += async (_, _) => { if (double.IsFinite(size.Value)) await DirectionRunAsync(() => { runtime.TerminalAppearance.Set(fontSize: (int)Math.Clamp(Math.Round(size.Value), 9, 24)); return Task.CompletedTask; }); };
      rows.Add(SettingsPanel.SettingRow("Terminal text size", "The text size of terminal sessions. Open sessions change at once.", size));
    }
    // One place per option (26 Oct): Settings checks; the side panel's card just above Settings holds
    // Restart to update (release 27), so it is not repeated here.
    var updates = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    updates.Children.Add(ReadOnly(Services.WindowsUpdateStatus.Version()));
    var check = new Button { Content = "Check for updates" };
    check.Click += async (_, _) => {
      check.IsEnabled = false;
      try { directionStatus.Text = "Checking…"; directionStatus.Text = await Services.WindowsUpdateStatus.CheckAsync(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { directionStatus.Text = "Could not check for updates. " + ex.Message; }
      finally { check.IsEnabled = true; }
    };
    updates.Children.Add(check);
    return DirectionPage([
      ("Sessions", null, rows.ToArray()),
      ("This PC", null, new[] { SettingsPanel.SettingRow("Keep this PC awake while " + TerminalDeck.Core.Brand.Name + " is open", "Prevents idle sleep while the app is open. Closing the app releases its request; Windows still controls manual sleep and lid actions.", Toggle(current.KeepAwake, value => runtime.General.Save(runtime.General.Read() with { KeepAwake = value }))) }),
      ("Updates", null, new[] { SettingsPanel.SettingRow("Check for updates", "", updates) })
    ]);
  }

  // Notifications (Mac, 15 Nov): one group, three rows. Other saved choices keep working as they are.
  private FrameworkElement NotificationSettings()
  {
    if (runtime.Notifications is not { } owner) return DirectionPage([(null, null, new[] { SettingsPanel.SettingRow("Notifications are starting…", "", null) })]);
    ToggleSwitch Switch(bool value, Func<TerminalDeck.Core.Notifications.NotificationPreferences, bool, TerminalDeck.Core.Notifications.NotificationPreferences> change)
    {
      var toggle = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 40 };
      toggle.Toggled += async (_, _) => await DirectionRunAsync(() => { owner.Save(change(owner.Read(), toggle.IsOn)); return Task.CompletedTask; });
      return toggle;
    }
    var current = owner.Read();
    var finished = Switch(current.Finished, (p, value) => p with { Finished = value });
    // The sound pop-up sits at the switch's left while the switch is on.
    var shown = current.Sound switch { "default" => "chime", "im" => "blip", "reminder" => "knock", var value => value };
    var sound = new ComboBox { ItemsSource = new[] { "chime", "blip", "knock" }, SelectedItem = shown, MinWidth = 110, Visibility = current.PlaySound ? Visibility.Visible : Visibility.Collapsed };
    sound.SelectionChanged += async (_, _) => { if (sound.SelectedItem is string selected) await DirectionRunAsync(() => { owner.Save(owner.Read() with { Sound = selected }); return Task.CompletedTask; }); };
    AutomationProperties.SetName(sound, "Sound");
    var play = Switch(current.PlaySound, (p, value) => p with { PlaySound = value });
    play.Toggled += (_, _) => sound.Visibility = play.IsOn ? Visibility.Visible : Visibility.Collapsed;
    var playing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    playing.Children.Add(sound); playing.Children.Add(play);
    var send = new Button { Content = "Send", VerticalAlignment = VerticalAlignment.Center };
    send.Click += async (_, _) =>
    {
      send.IsEnabled = false;
      try { directionStatus.Text = "Sending…"; directionStatus.Text = (await owner.TestAsync(false)).Message; }
      catch (Exception ex) when (ex is not OutOfMemoryException) { directionStatus.Text = "Windows could not send a test notification. See Privacy."; }
      finally { send.IsEnabled = true; }
    };
    return DirectionPage([(null, null, new[] {
      SettingsPanel.SettingRow("When a session finishes", "Shows a Windows notification when a session finishes its work.", finished),
      SettingsPanel.SettingRow("Play a sound", "Plays the chosen sound with a notification.", playing),
      SettingsPanel.SettingRow("Test notification", "Sends one test notification to this PC.", send)
    })]);
  }

  // Privacy (Mac, 15 Nov): this PC's own permissions, each with its real state and one small "Open".
  private FrameworkElement PrivacySettings()
  {
    string? state = null; var allowed = false;
    try
    {
      allowed = Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Setting == Microsoft.Windows.AppNotifications.AppNotificationSetting.Enabled;
      state = allowed ? "Allowed" : "Not allowed";
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { state = null; }
    var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
    if (state is not null) controls.Children.Add(SettingsPanel.StateText(state, allowed ? "DeckSecondaryInkBrush" : "DeckProjectOrangeBrush"));
    controls.Children.Add(DirectionAction("Open", async () =>
    {
      if (!await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"))) throw new InvalidOperationException("Windows could not open its notification settings.");
    }));
    return DirectionPage([("This PC's permissions",
      "Windows decides what " + TerminalDeck.Core.Brand.Name + " may do on this PC. Open takes you to the place in Windows Settings where you can change it.",
      new[] { SettingsPanel.SettingRow("Notifications", "", controls) })]);
  }

  // Agents (Mac, 15 Nov): one kind at a time, chosen at the top; three groups, every row title + control + info.
  private AgentCategory agentCategory = AgentCategory.Agent;
  private FrameworkElement AgentSettings()
  {
    var templates = runtime.Agents.Templates();
    if (templates.Count == 0) return DirectionPage([]);
    if (!templates.Any(t => t.Category == agentCategory)) agentCategory = templates[0].Category;
    var template = templates.Single(t => t.Category == agentCategory);
    var category = template.Category;
    // Each control saves through AgentService's validation; defaults never rewrite an active hand.
    AgentTemplate Current() => runtime.Agents.Templates().Single(t => t.Category == category);
    var kinds = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
    foreach (var kind in templates.Select(t => t.Category))
    {
      var choice = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = kind.ToString(), IsChecked = kind == category, Padding = new Thickness(12, 5, 12, 5), MinHeight = 30 };
      AutomationProperties.SetName(choice, kind.ToString());
      choice.Click += (_, _) => { agentCategory = kind; RefreshDirection("agent-defaults"); };
      kinds.Children.Add(choice);
    }
    var chooser = new Border { Child = kinds, CornerRadius = new CornerRadius(8), Padding = new Thickness(3), HorizontalAlignment = HorizontalAlignment.Center };
    chooser.SetResourceReference(Border.BackgroundProperty, "DeckControlBrush");
    var seat = IntegerSetting(template.MaxHandsPerSeat, 1, 12, n => runtime.Agents.SaveTemplate(Current() with { MaxHandsPerSeat = n }));
    var project = IntegerSetting(template.MaxHandsPerProject, 1, 60, n => runtime.Agents.SaveTemplate(Current() with { MaxHandsPerProject = n }));
    var limit = IntegerSetting(template.CardLimit, 500, 40000, n => runtime.Agents.SaveTemplate(Current() with { CardLimit = n }));
    var helper = new ComboBox { MinWidth = 140 };
    foreach (var provider in new[] { "claude", "codex", "gemini" })
    {
      var item = new ComboBoxItem { Content = AgentSeats.ProviderName(provider), Tag = provider };
      helper.Items.Add(item); if (provider == template.HelperAI) helper.SelectedItem = item;
    }
    helper.SelectionChanged += async (_, _) => await DirectionRunAsync(() => { runtime.Agents.SaveTemplate(Current() with { HelperAI = (string)((ComboBoxItem)helper.SelectedItem).Tag }); return Task.CompletedTask; });
    var parts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    foreach (var (key, label) in new[] { ("card", "Card"), ("notes", "Notes"), ("helper", "Helper instructions") })
    {
      var enabled = template.Parts.IsDefault ? key is "card" or "notes" : template.Parts.Contains(key);
      // No 120 px minimum per box (WinUI's default): the three fit the row, or the row stacks.
      var part = new CheckBox { Content = label, IsChecked = enabled, MinWidth = 0 };
      part.Click += async (_, _) => await DirectionRunAsync(() => {
        var current = Current(); var saved = current.Parts.IsDefault ? System.Collections.Immutable.ImmutableArray.Create("card", "notes") : current.Parts;
        runtime.Agents.SaveTemplate(current with { Parts = part.IsChecked == true ? saved.Where(p => p != key).Append(key).ToImmutableArray() : saved.Where(p => p != key).ToImmutableArray() });
        return Task.CompletedTask;
      });
      parts.Children.Add(part);
    }
    return DirectionPage([
      ("New sessions start with", "Shared with Coding AIs. Used when an agent or task has no explicit choice; running sessions keep their choices.", AgentLaunchDefaultRows()),
      ("Defaults", null, new[] {
        SettingsPanel.SettingRow("Helper AI", "The coding AI used when a hand asks for help.", helper),
        SettingsPanel.SettingRow("Helper model", "Model name used for new helpers. Empty means the AI's default.", DirectionAction("Edit…", () => EditTemplateTextAsync(category, "Helper model", t => t.HelperModel, (t, value) => t with { HelperModel = value }, 160))),
        SettingsPanel.SettingRow("Memory", "Parts included in a new hand's instructions.", parts)
      }),
      ("Budgets", null, new[] {
        SettingsPanel.SettingRow("Hands per seat", "Maximum simultaneous hands using one seat.", seat),
        SettingsPanel.SettingRow("Hands per project", "Maximum simultaneous hands in one project.", project),
        SettingsPanel.SettingRow("Card limit", "Maximum number of characters kept in a seat card.", limit)
      }),
      ("Behaviour", null, new[] {
        SettingsPanel.SettingRow("Shared instructions", "Instructions for every seat of this kind, including future hires.", DirectionAction("Edit…", () => EditTemplateTextAsync(category, "Shared instructions", t => t.Instructions, (t, value) => t with { Instructions = value }, 40000))),
        SettingsPanel.SettingRow("Checklist", "Checks a hand follows before finishing its work.", DirectionAction("Edit…", () => EditTemplateTextAsync(category, "Checklist", t => t.Checklist, (t, value) => t with { Checklist = value }, 20000)))
      })
    ], chooser);
  }

  private FrameworkElement[] AgentLaunchDefaultRows()
  {
    var rows = new List<FrameworkElement>();
    foreach (var provider in new[] { "claude", "codex", "gemini" })
    {
      var saved = TerminalDeck.Core.Settings.LaunchDefaults.For(provider, runtime.General.Read());
      var preferred = runtime.Accounts.Preferred(provider);
      var models = TerminalDeck.Core.Accounts.ModelCatalog.Merge(provider, runtime.Accounts.InstantModels(provider, preferred?.Id).Models, saved.Model).ToList();
      var model = new ComboBox { Header = "Model", MinWidth = 160 };
      foreach (var choice in models)
      {
        var item = new ComboBoxItem { Content = choice.Name, Tag = choice.Id };
        model.Items.Add(item); if (choice.Id == saved.Model) model.SelectedItem = item;
      }
      var effort = new ComboBox { Header = "Effort", MinWidth = 100 };
      void ReadEfforts(string? wanted)
      {
        var id = (model.SelectedItem as ComboBoxItem)?.Tag as string;
        var levels = TerminalDeck.Core.Accounts.ModelEfforts.For(provider, models.FirstOrDefault(m => m.Id == id));
        effort.ItemsSource = levels;
        effort.SelectedItem = wanted;
        if (effort.SelectedIndex < 0) effort.SelectedItem = TerminalDeck.Core.Accounts.ModelCatalog.TopEffort(provider);
        if (effort.SelectedIndex < 0 && levels.Count > 0) effort.SelectedIndex = 0;
      }
      ReadEfforts(saved.Effort);
      var saving = false;
      async Task Save()
      {
        if (saving || model.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        saving = true;
        try { await DirectionRunAsync(() => { runtime.General.Save(TerminalDeck.Core.Settings.LaunchDefaults.With(runtime.General.Read(), provider, id, effort.SelectedItem as string)); return Task.CompletedTask; }); }
        finally { saving = false; }
      }
      model.SelectionChanged += async (_, _) => { if (saving) return; saving = true; try { ReadEfforts(effort.SelectedItem as string); } finally { saving = false; } await Save(); };
      effort.SelectionChanged += async (_, _) => await Save();
      AutomationProperties.SetAutomationId(model, "agents.launchModel." + provider);
      AutomationProperties.SetAutomationId(effort, "agents.launchEffort." + provider);
      AutomationProperties.SetName(model, AgentSeats.ProviderName(provider) + " default model");
      AutomationProperties.SetName(effort, AgentSeats.ProviderName(provider) + " default effort");
      var controls = new StackPanel { Spacing = 8 };
      controls.Children.Add(model);
      if (provider != "gemini") controls.Children.Add(effort);
      var modes = TerminalDeck.Core.Chats.ChatPermissionModes.Supported(provider);
      var permission = new ComboBox { Header = "Before it changes files", MinWidth = 160 };
      permission.Items.Add("Use global default");
      foreach (var mode in modes) permission.Items.Add(TerminalDeck.Core.Chats.ChatPermissionModes.Label(mode));
      void ReadPermission()
      {
        var explicitChoice = runtime.General.Read().LaunchPermissions?.FirstOrDefault(p => p.Provider == provider);
        permission.SelectedIndex = explicitChoice is null ? 0 : modes.ToList().IndexOf(explicitChoice.PermissionMode) + 1;
      }
      ReadPermission();
      var changingPermission = false;
      permission.SelectionChanged += async (_, _) =>
      {
        if (changingPermission || permission.SelectedIndex < 0) return;
        changingPermission = true; permission.IsEnabled = false;
        try
        {
          TerminalDeck.Core.Mcp.AiPermissionMode? selected = permission.SelectedIndex == 0 ? null : modes[permission.SelectedIndex - 1];
          var effective = TerminalDeck.Core.Settings.LaunchPermissions.For(provider, TerminalDeck.Core.Settings.LaunchPermissions.With(runtime.General.Read(), provider, selected));
          if (effective == TerminalDeck.Core.Mcp.AiPermissionMode.Bypass && runtime.General.NewChatPermission(provider) != effective)
          {
            var confirm = new ContentDialog { XamlRoot = DialogRoot, RequestedTheme = ActualTheme, Title = "Allow Bypass permissions?", Content = "New sessions skip the coding AI's permission questions. Saved app access and server confirmations still apply.", PrimaryButtonText = "Allow Bypass", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
          }
          await DirectionRunAsync(() => { runtime.General.Save(TerminalDeck.Core.Settings.LaunchPermissions.With(runtime.General.Read(), provider, selected)); return Task.CompletedTask; });
        }
        finally { ReadPermission(); permission.IsEnabled = true; changingPermission = false; }
      };
      AutomationProperties.SetAutomationId(permission, "agents.launchPermission." + provider);
      AutomationProperties.SetName(permission, AgentSeats.ProviderName(provider) + " default permission");
      controls.Children.Add(permission);
      rows.Add(SettingsPanel.SettingRow(AgentSeats.ProviderName(provider), "Choices for new sessions without their own choice. The global permission default is set in General.", controls));
    }
    return rows.ToArray();
  }

  // Coding AIs > Custom terminal CLIs, a second page of this window (15 Nov), not its own window.
  private FrameworkElement CustomCliSettings()
  {
    FrameworkElement? form = null;
    nint Handle() => form?.XamlRoot?.ContentIslandEnvironment is { } island ? Microsoft.UI.Win32Interop.GetWindowFromWindowId(island.AppWindowId) : 0;
    var body = Agents.CustomTerminalProviderWindow.Form(runtime.CustomProviders, Handle, false);
    form = body;
    return DirectionPage([], bottom: body);
  }

  private FrameworkElement BrowserSettings()
  {
    var store = new JsonStateStore<BrowserStartPage>(runtime.Root, "browser-start-page");
    var address = new TextBox { PlaceholderText = "New tab page", MaxWidth = 240, MinWidth = 140, MaxLength = 2048 };
    string? loadProblem = null;
    try { address.Text = SettingsBrowser is { } model ? model.Read().StartUrl == "about:blank" ? "" : model.Read().StartUrl : store.Load()?.Url ?? ""; }
    catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or UnauthorizedAccessException) { loadProblem = "The start page could not be read. Choose it again below."; }
    Task SaveStartPageAsync() => DirectionRunAsync(async () => {
      var value = BrowserStartPage.Validate(address.Text);
      if (SettingsBrowser is { } model) await model.SetStartUrlAsync(value.Length == 0 ? "about:blank" : value);
      else throw new InvalidOperationException("The browser is still loading. Your address is kept here.");
    });
    address.LostFocus += async (_, _) => await SaveStartPageAsync();
    address.KeyDown += async (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) { args.Handled = true; await SaveStartPageAsync(); } };
    AutomationProperties.SetName(address, "Start page");
    var rows = new List<FrameworkElement> {
      SettingsPanel.SettingRow("Start page", "New browser tabs open this page. Leave empty for the New tab page.", address)
    };
    var profiles = new List<FrameworkElement>();
    if (SettingsBrowser is { } browser)
    {
      var state = browser.Read();
      foreach (var profile in state.Profiles)
      {
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (profile.Id == state.ActiveProfileId) actions.Children.Add(ReadOnly("In use"));
        else actions.Children.Add(DirectionAction("Use it", async () => { await browser.ActivateProfileAsync(profile.Id); RefreshDirection("browser"); }));
        actions.Children.Add(DirectionAction("Rename…", async () => {
          var name = await DirectionTextAsync("Rename profile", profile.Name, 40);
          if (name is not null) { await browser.UpdateProfileAsync(profile.Id, name); RefreshDirection("browser"); }
        }));
        if (profile.Id != BrowserModel.DefaultProfileId) actions.Children.Add(DirectionAction("Delete…", async () => {
          var dialog = new ContentDialog { XamlRoot = DialogRoot, RequestedTheme = ActualTheme, Title = "Delete " + profile.Name + "?", Content = "Close tabs using this profile first. Its cookies, website data and saved passwords will be deleted; this cannot be undone.", PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
          if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
          await browser.DeleteProfileAsync(profile.Id); if (PrivacyBrowser is { } owner) await owner.Privacy.ForgetAsync(profile.Id); RefreshDirection("browser");
        }));
        profiles.Add(SettingsPanel.SettingRow(profile.Name, "", actions));
      }
      profiles.Add(SettingsPanel.SettingRow("Add a profile", "Keep work and personal sign-ins separate.", DirectionAction("Add…", async () => {
        var name = await DirectionTextAsync("Add a profile", "", 40);
        if (name is not null) { await browser.CreateProfileAsync(name); RefreshDirection("browser"); }
      })));
    }
    else profiles.Add(SettingsPanel.SettingRow("Profiles", "Open Browser to manage profiles and sign-ins.", null));
    // Every row inside its group's card, one line each (15 Nov).
    var privacy = PrivacyBrowser is { } privacyBrowser ? new BrowserPrivacyPage(privacyBrowser) : null;
    if (privacy is not null) profiles.AddRange(privacy.SignInRows);
    var result = DirectionPage([("Pages", null, rows.ToArray()),
      ("Cookies and sign-ins", "Each profile is a separate set of logins and cookies. Shared tabs keep sign-ins between app launches.", profiles.ToArray())], bottom: privacy);
    if (loadProblem is not null) directionStatus.Text = loadProblem;
    return result;
  }

  private FrameworkElement TaskSettings(Action<string> select)
  {
    var rows = new List<FrameworkElement>();
    if (runtime.ConnectedTasks is { } connected)
    {
      foreach (var system in connected.Systems())
        rows.Add(SettingsPanel.SettingRow(system.Name,
          runtime.Projects.Get(system.ProjectId).Name + (system.AllowChanges ? " · Changes allowed" : " · Read only"),
          DirectionAction("Edit…", () => EditTaskSystemAsync(system))));
      rows.Add(SettingsPanel.SettingRow("Connect a task system", "Choose an existing HTTP MCP server that offers tasks.", DirectionAction("Connect…", () => EditTaskSystemAsync(null))));
    }
    else rows.Add(SettingsPanel.SettingRow("Connected task systems", "Task services are starting. Reopen this page when they are ready.", null));
    return DirectionPage([
      ("Task agents", null, new[] { SettingsPanel.SettingRow("Agent defaults", "Shared instructions, helper AI and hand limits live in Agents.", DirectionAction("Agents", () => { select("agent-defaults"); return Task.CompletedTask; })) }),
      ("Connected task systems", null, rows.ToArray())
    ]);
  }

  private async Task EditTaskSystemAsync(ConnectedTaskSystem? system)
  {
    var connected = runtime.ConnectedTasks ?? throw new InvalidOperationException("Task services are not ready.");
    var servers = await connected.ServersAsync();
    if (servers.Count == 0) throw new InvalidOperationException("Add an HTTP server under AI apps → MCP servers first.");
    var server = new ComboBox { Header = "MCP server", ItemsSource = servers, DisplayMemberPath = "Name", SelectedItem = servers.FirstOrDefault(s => s.Id == system?.ServerId) ?? servers[0], HorizontalAlignment = HorizontalAlignment.Stretch };
    var projects = runtime.Projects.List().ToArray();
    var project = new ComboBox { Header = "Project", ItemsSource = projects, DisplayMemberPath = "Name", SelectedItem = projects.FirstOrDefault(p => p.Id == system?.ProjectId) ?? projects.FirstOrDefault(), HorizontalAlignment = HorizontalAlignment.Stretch };
    var changes = new ToggleSwitch { Header = "Allow changes", IsOn = system?.AllowChanges ?? false };
    var note = new TextBlock { Text = "The existing MCP server keeps its sign-in. Changes use the calling AI’s approval rules.", TextWrapping = TextWrapping.Wrap, MaxWidth = 400 };
    var body = new StackPanel { Spacing = 12 }; foreach (var control in new FrameworkElement[] { note, server, project, changes }) body.Children.Add(control);
    var dialog = new ContentDialog { XamlRoot = DialogRoot, RequestedTheme = ActualTheme, Title = system?.Name ?? "Connect a task system", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
    dialog.PrimaryButtonClick += async (_, args) => {
      var deferral = args.GetDeferral();
      try {
        if (server.SelectedItem is not ConnectedTaskServer selected || project.SelectedItem is not Project scope) throw new InvalidOperationException("Choose a server and a project.");
        if (system is null) await connected.ConnectExistingAsync(selected.Name, selected.Url, scope.Id, changes.IsOn ? "ask" : "off");
        else await connected.BindAsync(system.Id, system.Name, selected.Id, scope.Id, changes.IsOn);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { args.Cancel = true; note.Text = ex.Message; }
      finally { deferral.Complete(); }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) RefreshDirection("tasks");
  }

  private async Task EditTemplateTextAsync(AgentCategory category, string title, Func<AgentTemplate, string> read, Func<AgentTemplate, string, AgentTemplate> update, int maximum)
  {
    var old = runtime.Agents.Templates().Single(t => t.Category == category);
    var text = new TextBox { Text = read(old), AcceptsReturn = maximum > 160, TextWrapping = TextWrapping.Wrap, MaxLength = maximum, MinWidth = 280, MaxHeight = 300, PlaceholderText = "Default" };
    var note = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 400 };
    var body = new StackPanel { Spacing = 12 }; body.Children.Add(text); body.Children.Add(note);
    var dialog = new ContentDialog { XamlRoot = DialogRoot, RequestedTheme = ActualTheme, Title = title, Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
    dialog.PrimaryButtonClick += (_, args) => {
      try { runtime.Agents.SaveTemplate(update(runtime.Agents.Templates().Single(t => t.Category == category), text.Text)); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { args.Cancel = true; note.Text = ex.Message; }
    };
    await dialog.ShowAsync();
  }

  private async Task<string?> DirectionTextAsync(string title, string value, int maximum)
  {
    var input = new TextBox { Text = value, MaxLength = maximum, MinWidth = 280 };
    var dialog = new ContentDialog { XamlRoot = DialogRoot, RequestedTheme = ActualTheme, Title = title, Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(value) };
    input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(input.Text);
    return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text.Trim() : null;
  }

  private NumberBox IntegerSetting(int value, int minimum, int maximum, Action<int> save)
  {
    var box = new NumberBox { Value = value, Minimum = minimum, Maximum = maximum, SmallChange = 1, Width = 120, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    box.ValueChanged += async (_, _) => {
      if (!double.IsFinite(box.Value) || box.Value != Math.Truncate(box.Value)) { directionStatus.Text = "Choose a whole number."; return; }
      await DirectionRunAsync(() => { save((int)box.Value); return Task.CompletedTask; });
    };
    return box;
  }

  private Button DirectionAction(string label, Func<Task> work)
  {
    var button = new Button { Content = label, VerticalAlignment = VerticalAlignment.Center };
    button.Click += async (_, _) => { button.IsEnabled = false; try { await DirectionRunAsync(work); } finally { button.IsEnabled = true; } };
    return button;
  }
  private async Task DirectionRunAsync(Func<Task> work)
  {
    directionStatus.Text = "Working…";
    try { await work(); directionStatus.IsOpen = false; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { directionStatus.Text = ex is ArgumentException or InvalidOperationException ? ex.Message : "That change could not be saved. Please try again."; }
  }
  internal event Action? SettingsContentRendered;
  internal event Action<string>? DirectionRefreshRequested;
  private void RefreshDirection(string id) => DirectionRefreshRequested?.Invoke(id);
  private static TextBlock ReadOnly(string value) => new() { Text = value, FontSize = 12, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };

  // The page last drawn here: its window is where a dialog of this page opens (Settings, or the Browser's own window).
  private FrameworkElement? directionSurface;
  private XamlRoot? DialogRoot => directionSurface?.XamlRoot ?? XamlRoot;

  // One centred column; no heading inside the page (the top bar is the heading); groups apart by space; a group's
  // explanation sits behind the info button beside its title.
  private FrameworkElement DirectionPage(IEnumerable<(string? Heading, string? Help, FrameworkElement[] Rows)> groups, FrameworkElement? top = null, FrameworkElement? bottom = null)
  {
    var body = SettingsPanel.Column();
    if (top is not null) body.Children.Add(top);
    foreach (var (heading, help, rows) in groups)
    {
      if (rows.Length == 0) continue;
      if (!string.IsNullOrWhiteSpace(heading)) body.Children.Add(SettingsPanel.GroupTitle(heading, help));
      body.Children.Add(SettingsPanel.GroupRows(rows));
    }
    if (bottom is not null) body.Children.Add(bottom);
    var surface = new Grid();
    var scroll = SettingsPanel.Scroll(body); surface.Children.Add(scroll);
    directionStatus = new Notices.CompactNotice { Scope = surface };
    AutomationProperties.SetLiveSetting(directionStatus, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
    surface.Children.Add(directionStatus);
    directionSurface = surface;
    return surface;
  }
}
