using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
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

  internal FrameworkElement? DirectionPage(string id, Action<string> select) => id switch
  {
    "cloud" => new CloudPage(runtime.Cloud, runtime.CloudSync),
    "general" => GeneralSettings(),
    "notifications" => NotificationSettings(),
    "advanced" => AdvancedSettings(),
    "agent-defaults" => AgentSettings(),
    "browser" => BrowserSettings(),
    "tasks" => TaskSettings(select),
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
    ToolTipService.SetToolTip(restore, "Choose whether saved tabs and windows reopen. Running sessions stay available either way.");
    var rows = new List<FrameworkElement> {
      SettingsPanel.SettingRow("Pick up where you left off", "Reopens projects and sessions after a restart. Sessions that kept running are always kept.", restore),
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
    return DirectionPage("General", [
      ("Sessions", rows.ToArray()),
      ("This PC", new[] { SettingsPanel.SettingRow("Keep this PC awake while " + TerminalDeck.Core.Brand.Name + " is open", "Prevents idle sleep while the app is open. Closing the app releases its request; Windows still controls manual sleep and lid actions.", Toggle(current.KeepAwake, value => runtime.General.Save(runtime.General.Read() with { KeepAwake = value }))) }),
      ("Updates", new[] { SettingsPanel.SettingRow("Check for updates", "", updates) })
    ]);
  }

  private FrameworkElement NotificationSettings() => runtime.Notifications is null ? new TextBlock { Text = "Notification settings are starting…", TextWrapping = TextWrapping.Wrap } : new Notifications.NotificationPreferencesPage(runtime.Notifications);

  private FrameworkElement AgentSettings()
  {
    var groups = new List<(string, FrameworkElement[])>();
    foreach (var template in runtime.Agents.Templates())
    {
      // Each control saves through AgentService's validation; defaults never rewrite an active hand.
      AgentTemplate Current() => runtime.Agents.Templates().Single(t => t.Category == template.Category);
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
        var part = new CheckBox { Content = label, IsChecked = enabled };
        part.Click += async (_, _) => await DirectionRunAsync(() => {
          var current = Current(); var saved = current.Parts.IsDefault ? System.Collections.Immutable.ImmutableArray.Create("card", "notes") : current.Parts;
          runtime.Agents.SaveTemplate(current with { Parts = part.IsChecked == true ? saved.Where(p => p != key).Append(key).ToImmutableArray() : saved.Where(p => p != key).ToImmutableArray() });
          return Task.CompletedTask;
        });
        parts.Children.Add(part);
      }
      groups.Add((template.Category.ToString(), [
        SettingsPanel.SettingRow("Memory", "Parts included in a new hand’s instructions.", parts),
        SettingsPanel.SettingRow("Hands per seat", "Maximum simultaneous hands using one seat.", seat),
        SettingsPanel.SettingRow("Hands per project", "Maximum simultaneous hands in one project.", project),
        SettingsPanel.SettingRow("Card limit", "Maximum number of characters kept in a seat card.", limit),
        SettingsPanel.SettingRow("Helper AI", "The coding AI used when a hand asks for help.", helper),
        SettingsPanel.SettingRow("Helper model", "Model name used for new helpers.", DirectionAction("Edit…", () => EditTemplateTextAsync(template.Category, "Helper model", t => t.HelperModel, (t, value) => t with { HelperModel = value }, 160))),
        SettingsPanel.SettingRow("Shared instructions", "Instructions for every seat in this category, including future hires.", DirectionAction("Edit…", () => EditTemplateTextAsync(template.Category, "Shared instructions", t => t.Instructions, (t, value) => t with { Instructions = value }, 40000))),
        SettingsPanel.SettingRow("Checklist", "Checks a hand follows before finishing its work.", DirectionAction("Edit…", () => EditTemplateTextAsync(template.Category, "Checklist", t => t.Checklist, (t, value) => t with { Checklist = value }, 20000)))
      ]));
    }
    return DirectionPage("Agents", groups);
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
          var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Delete " + profile.Name + "?", Content = "Close tabs using this profile first. Its cookies, website data and saved passwords will be deleted; this cannot be undone.", PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
          if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
          await browser.DeleteProfileAsync(profile.Id); if (PrivacyBrowser is { } owner) await owner.Privacy.ForgetAsync(profile.Id); RefreshDirection("browser");
        }));
        profiles.Add(SettingsPanel.SettingRow(profile.Name, "A separate set of logins and cookies. Shared tabs keep sign-ins between app launches.", actions));
      }
      profiles.Add(SettingsPanel.SettingRow("Add a profile", "Keep work and personal sign-ins separate.", DirectionAction("Add…", async () => {
        var name = await DirectionTextAsync("Add a profile", "", 40);
        if (name is not null) { await browser.CreateProfileAsync(name); RefreshDirection("browser"); }
      })));
    }
    else profiles.Add(SettingsPanel.SettingRow("Profiles", "Open Browser to manage profiles and sign-ins.", null));
    if (PrivacyBrowser is { } privacyBrowser) profiles.Add(new BrowserPrivacyPage(privacyBrowser));
    var result = DirectionPage("Browser", [("Pages", rows.ToArray()), ("Cookies and sign-ins", profiles.ToArray())]);
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
    return DirectionPage("Tasks", [
      ("Task agents", new[] { SettingsPanel.SettingRow("Agent defaults", "Shared instructions, helper AI and hand limits live in Agents.", DirectionAction("Agents", () => { select("agent-defaults"); return Task.CompletedTask; })) }),
      ("Connected task systems", rows.ToArray())
    ]);
  }

  private async Task EditTaskSystemAsync(ConnectedTaskSystem? system)
  {
    var connected = runtime.ConnectedTasks ?? throw new InvalidOperationException("Task services are not ready.");
    var servers = await connected.ServersAsync();
    if (servers.Count == 0) throw new InvalidOperationException("Add an HTTP server under Outside AI apps → MCP servers first.");
    var server = new ComboBox { Header = "MCP server", ItemsSource = servers, DisplayMemberPath = "Name", SelectedItem = servers.FirstOrDefault(s => s.Id == system?.ServerId) ?? servers[0], HorizontalAlignment = HorizontalAlignment.Stretch };
    var projects = runtime.Projects.List().ToArray();
    var project = new ComboBox { Header = "Project", ItemsSource = projects, DisplayMemberPath = "Name", SelectedItem = projects.FirstOrDefault(p => p.Id == system?.ProjectId) ?? projects.FirstOrDefault(), HorizontalAlignment = HorizontalAlignment.Stretch };
    var changes = new ToggleSwitch { Header = "Allow changes", IsOn = system?.AllowChanges ?? false };
    var note = new TextBlock { Text = "The existing MCP server keeps its sign-in. Changes use the calling AI’s approval rules.", TextWrapping = TextWrapping.Wrap, MaxWidth = 400 };
    var body = new StackPanel { Spacing = 12 }; foreach (var control in new FrameworkElement[] { note, server, project, changes }) body.Children.Add(control);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = system?.Name ?? "Connect a task system", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
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
    var text = new TextBox { Text = read(old), AcceptsReturn = maximum > 160, TextWrapping = TextWrapping.Wrap, MaxLength = maximum, MinWidth = 280, MaxHeight = 300 };
    var note = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 400 };
    var body = new StackPanel { Spacing = 12 }; body.Children.Add(text); body.Children.Add(note);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = title, Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
    dialog.PrimaryButtonClick += (_, args) => {
      try { runtime.Agents.SaveTemplate(update(runtime.Agents.Templates().Single(t => t.Category == category), text.Text)); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { args.Cancel = true; note.Text = ex.Message; }
    };
    await dialog.ShowAsync();
  }

  private async Task<string?> DirectionTextAsync(string title, string value, int maximum)
  {
    var input = new TextBox { Text = value, MaxLength = maximum, MinWidth = 280 };
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = title, Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(value) };
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

  private FrameworkElement DirectionPage(string title, IEnumerable<(string Heading, FrameworkElement[] Rows)> groups)
  {
    var body = new StackPanel { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20, 0, 20, 20) };
    body.Children.Add(SettingsPanel.PageHead(title));
    foreach (var (heading, rows) in groups)
    {
      body.Children.Add(new TextBlock { Text = heading, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(8, 20, 0, 0) });
      body.Children.Add(SettingsPanel.GroupRows(rows));
    }
    var surface = new Grid();
    var scroll = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; surface.Children.Add(scroll);
    directionStatus = new Notices.CompactNotice { Scope = surface };
    AutomationProperties.SetLiveSetting(directionStatus, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
    surface.Children.Add(directionStatus);
    return surface;
  }
}
