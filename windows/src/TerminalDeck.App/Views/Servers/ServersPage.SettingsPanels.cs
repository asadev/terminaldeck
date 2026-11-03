using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage
{
  private FrameworkElement SettingFact(string label, string value)
  {
    var title = Words(label, 13); var detail = Words(value, 12, true); detail.IsTextSelectionEnabled = true;
    return DataRow(title, detail);
  }
  private async Task SaveServerSettingsAsync(SavedServer server, ServerSettingsPatch patch, string success)
  {
    if (await Model.RunAsync(async () => await Model.Servers.SaveSettingsAsync(server.Id, patch, ServerCaller.Person), "Waiting for approval…", success)) await Model.LoadSettingsAsync();
  }
  private void ShownAppsSettings(StackPanel body, SavedServer server)
  {
    var content = Stack(8); var heading = Words("Show only these apps", 15); heading.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; content.Children.Add(heading);
    var names = (Model.Settings?.SeenApps ?? []).Concat(server.ShownApps ?? []).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
    if (names.Length == 0) content.Children.Add(Words(Model.Settings is null ? "Reading this server's apps…" : "No apps seen yet. Open the server once, then choose here.", 12, true));
    var choices = names.Select(name => (Name: name, Check: new CheckBox { Content = name, IsChecked = server.ShownApps is null || server.ShownApps.Contains(name, StringComparer.Ordinal) })).ToArray();
    foreach (var (_, check) in choices) content.Children.Add(check);
    if (names.Length > 0)
    {
      content.Children.Add(Button("Save shown apps", () => SaveServerSettingsAsync(server, new() { SetShownApps = true, ShownApps = choices.All(row => row.Check.IsChecked == true) ? null : choices.Where(row => row.Check.IsChecked == true).Select(row => row.Name).ToArray() }, "App visibility saved.")));
      if (server.ShownApps is not null) content.Children.Add(Button("Show every app", () => SaveServerSettingsAsync(server, new() { SetShownApps = true, ShownApps = null }, "Every app is shown.")));
    }
    content.Children.Add(Words(server.ShownApps is null ? "Every app on this server is shown." : "Unticked apps are hidden everywhere in Terminal Deck, and AI apps can't see or use them.", 12, true)); body.Children.Add(Card(content));
  }
  private void ServerSignInSettings(StackPanel body, SavedServer server)
  {
    var facts = Stack(0); facts.Children.Add(SettingFact("SSH alias", server.SshAlias ?? "Direct connection")); facts.Children.Add(SettingFact("Address", server.Host + ":" + server.Port)); facts.Children.Add(SettingFact("Sign in as", server.User)); facts.Children.Add(SettingFact("Sign-in kept here", server.Authentication == ServerAuthentication.Key ? "Protected SSH key" : "Windows Credential Manager"));
    facts.Children.Add(Words("Your SSH settings and keys stay on this PC.", 12, true)); body.Children.Add(Card(facts));
    var folder = Field("Landing folder", server.LandingFolder ?? ""); folder.PlaceholderText = "Home"; body.Children.Add(folder);
    var choose = Button("Choose folder…", async () => { if (await ChooseServerFolderAsync(server) is { } selected) folder.Text = selected; });
    choose.IsEnabled = server.Access.Folders.Length > 0; ToolTipService.SetToolTip(choose, choose.IsEnabled ? "Choose within the folders allowed in Access." : "Choose the folders this app may open in Access first. You can still type an exact landing folder."); body.Children.Add(choose);
    body.Children.Add(Button("Save landing folder", () => SaveServerSettingsAsync(server, new() { SetLandingFolder = true, LandingFolder = string.IsNullOrWhiteSpace(folder.Text) ? null : folder.Text.Trim() }, "Landing folder saved.")));
    var open = Button("Open terminal here", () => Model.RunAsync(async () => host.OpenSession(await Model.Servers.OpenTerminalAtAsync(server.Id, string.IsNullOrWhiteSpace(folder.Text) ? null : folder.Text.Trim(), ServerCaller.Person)), "Waiting for approval…", "Server terminal opened."), true); open.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; body.Children.Add(open);
  }
  private async Task<string?> ChooseServerFolderAsync(SavedServer server)
  {
    using var lifetime = new CancellationTokenSource(); var panel = Stack(8); var path = Words("", 12, true); var notice = Words("", 12, true); var rows = Stack(4);
    var roots = new ComboBox { Header = "Allowed folder", ItemsSource = server.Access.Folders, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var history = new Stack<string>(); string? current = null; var busy = false; var closed = false;
    Button? back = null;
    var dialog = Dialog(XamlRoot, "Landing folder", panel, "Use folder"); dialog.IsPrimaryButtonEnabled = false;
    async Task Load(string next, bool remember = true)
    {
      if (busy || closed) return; busy = true; roots.IsEnabled = false; dialog.IsPrimaryButtonEnabled = false; notice.Text = "Opening folder…";
      try
      {
        var page = await Model.Servers.FilesAsync(server.Id, next, ServerCaller.Person, lifetime.Token);
        if (closed) return; if (remember && current is { } prior && prior != page.Path) history.Push(prior); current = page.Path; path.Text = page.Path; rows.Children.Clear();
        foreach (var folder in page.Entries.Where(file => file.Kind == "folder")) rows.Children.Add(Button(folder.Name, () => Load(folder.Path)));
        notice.Text = page.Entries.Any(file => file.Kind == "folder") ? "" : "No folders inside this folder."; dialog.IsPrimaryButtonEnabled = true; back!.IsEnabled = history.Count > 0;
      }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is ServerRefusal or IOException or ArgumentException or UnauthorizedAccessException) { notice.Text = ex is ServerRefusal ? ex.Message : "This folder could not be read. Check the connection and allowed folders."; }
      finally { busy = false; if (!closed) roots.IsEnabled = true; }
    }
    back = Button("Back", async () => { if (history.Count > 0) await Load(history.Pop(), false); }); back.IsEnabled = false;
    roots.SelectionChanged += async (_, _) => { if (roots.SelectedItem is string selected) { history.Clear(); await Load(selected, false); } };
    panel.Children.Add(roots); panel.Children.Add(path); panel.Children.Add(back); panel.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 320, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }); panel.Children.Add(notice);
    dialog.Opened += async (_, _) => { if (roots.SelectedItem is string selected) await Load(selected, false); };
    var result = await dialog.ShowAsync(); closed = true; lifetime.Cancel(); return result == ContentDialogResult.Primary ? current : null;
  }
  private void ServerHostingSettings(StackPanel body, SavedServer server)
  {
    if (Model.Settings?.Hosting is not { } status) { MissingServerSettings(body, "Server setup could not be checked."); return; }
    if (!status.Observed) { MissingServerSettings(body, status.Problem ?? "This server did not answer. Its setup state has not been read."); return; }
    var facts = Stack(0); facts.Children.Add(SettingFact("Set up for Apps", status.Installed ? "Yes, helper set " + (status.InstalledVersion ?? "installed") : "Not yet")); facts.Children.Add(SettingFact("Docker", status.Docker is { Length: > 0 } docker ? "Version " + docker : "Not installed yet"));
    if (!string.IsNullOrWhiteSpace(status.RouterSummary)) facts.Children.Add(SettingFact("Web addresses", status.RouterSummary));
    if (status.Installed) facts.Children.Add(SettingFact("Server duties", status.Duties.Length > 0 ? string.Join(" · ", status.Duties) : "Not reported yet."));
    body.Children.Add(Card(facts));
    if (status.Problem is { Length: > 0 } problem) body.Children.Add(Words(problem, 12, true));
    body.Children.Add(Words("How this server runs your apps when this PC is off. You review the exact server change before it runs.", 12, true));
    if (!status.Administrator) body.Children.Add(Words("Setup needs administrator access (root, or sudo without a password). Terminals and the Docker view keep working without it.", 12, true));
    if (status.SetupState == "running") body.Children.Add(Words("Setup is running on the server. It keeps going if this PC closes. Check again for its result.", 12, true));
    if (status.SetupProblem is { Length: > 0 } setupProblem) body.Children.Add(Words(ServerText.Mask(setupProblem), 12, true));
    if (status.SetupState != "running" && (!status.Installed || status.InstalledVersion != status.HelperVersion))
    {
      var setup = Button(status.Installed ? "Update the helper set" : "Set up this server", () => ChangeServerHostingAsync(server, "setup"), true); setup.IsEnabled = !server.Access.LookOnly && status.Supported && status.Administrator && !Model.IsBusy; body.Children.Add(setup);
    }
    if (status.Installed)
    {
      body.Children.Add(Words("Removes Terminal Deck's helpers, duties and settings from this server. Your apps, their data and backups stay.", 12, true));
      var remove = Button("Remove Terminal Deck from this server…", () => ChangeServerHostingAsync(server, "remove")); remove.IsEnabled = !server.Access.LookOnly && !Model.IsBusy; body.Children.Add(remove);
    }
    body.Children.Add(Button("Check again", async () => await Model.LoadSettingsAsync()));
  }
  private async Task ChangeServerHostingAsync(SavedServer server, string action)
  {
    if (await Model.RunAsync(async () => { var status = await Model.Servers.HostingAsync(server.Id, action, ServerCaller.Person); if (action == "setup" && !status.Installed || action == "remove" && status.Installed) throw new ServerRefusal(status.Problem ?? "The server did not confirm that change. Check it again."); }, "Waiting for approval…", action == "remove" ? "Server helper removed. Apps and data were kept." : "Server setup finished.")) await Model.LoadSettingsAsync();
  }
  private void ServerAdvancedSettings(StackPanel body, SavedServer server)
  {
    var facts = Stack(0); var hostFacts = Model.Settings?.Hosting.Facts;
    facts.Children.Add(SettingFact("System", hostFacts?.System ?? "Not reported yet.")); facts.Children.Add(SettingFact("Its own name for itself", hostFacts?.Hostname ?? Model.Settings?.Hosting.Hostname ?? "Not reported yet.")); facts.Children.Add(SettingFact("Signed in as", server.User));
    facts.Children.Add(SettingFact("Accepting connections", hostFacts is null ? "Not reported yet." : hostFacts.Listeners.Length > 0 ? string.Join(" · ", hostFacts.Listeners) : "Nothing.")); facts.Children.Add(SettingFact("Installs software with", hostFacts?.PackageManager ?? "Nothing we recognise."));
    facts.Children.Add(SettingFact("How you sign in", server.Authentication == ServerAuthentication.Key ? "Protected SSH key" : "Saved password")); body.Children.Add(Card(facts));
    body.Children.Add(Words("To sign in a different way, forget this server below and add it again. Nothing on the server changes either way.", 12, true));
    var hoot = Stack(8); var title = Words("Let Hoot use this server", 15); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; hoot.Children.Add(title); hoot.Children.Add(Words("Off unless you turn it on, and then only for this one server and only for a while. It covers the named app actions on that server's page, not the terminal, sign-in or forgetting it.", 12, true));
    if (server.HootGrantUntil is { } until && until > DateTimeOffset.UtcNow)
    {
      hoot.Children.Add(Words("Allowed until " + until.LocalDateTime.ToString("t"), 12, true));
      hoot.Children.Add(Button("Stop allowing it", () => SaveServerSettingsAsync(server, new() { SetHootGrant = true }, "Hoot's timed access stopped.")));
    }
    else { var allow = Button("Allow it for an hour", () => SaveServerSettingsAsync(server, new() { SetHootGrant = true, HootGrantUntil = DateTimeOffset.UtcNow.AddHours(1) }, "Hoot may use these app actions for one hour.")); allow.IsEnabled = !server.Access.LookOnly; hoot.Children.Add(allow); }
    body.Children.Add(Card(hoot));
    var browser = new CheckBox { Content = "Sessions on " + server.Name + " may act on browser windows here", IsChecked = server.DrivesBrowser };
    body.Children.Add(browser); body.Children.Add(Button("Save browser access", () => SaveServerSettingsAsync(server, new() { DrivesBrowser = browser.IsChecked == true }, "Server browser access saved.")));
    Connection(body, server);
  }
  private void MissingServerSettings(StackPanel body, string text)
  {
    body.Children.Add(Card(Words(Model.IsBusy ? "Checking this server…" : text, 12, true)));
    if (!Model.IsBusy) body.Children.Add(Button("Check again", async () => await Model.LoadSettingsAsync()));
  }
}
