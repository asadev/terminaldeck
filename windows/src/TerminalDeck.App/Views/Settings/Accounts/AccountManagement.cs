using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.App.Views;

// Settings → Coding AIs (Mac: NativeCodingAIAccounts, 15 Nov). One group per INSTALLED AI, titled with
// its mark and name (version in the info button): each account by its name with a state dot (green
// signed in, orange needs him), its plan as the second line and a "…" menu; "+ Add account" last.
// Then the model and effort new sessions start with. "Which account agents use" opens Who uses what.
// A signed-out login is said once, as that account's orange dot; e-mail only in the info button.
public sealed partial class SettingsPane
{
  private readonly Dictionary<string, Task<ProviderInstallation>> installations = [];
  private static readonly string[] CodingAis = ["claude", "codex", "gemini"];
  private async Task AddAccountRowsAsync(StackPanel stack, CancellationToken ct)
  {
    var loading = Description("Reading accounts…"); stack.Children.Add(loading);
    IReadOnlyList<AccountProfile> accounts;
    try { accounts = await Task.Run(() => runtime.Accounts.List()).WaitAsync(ct); }
    catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
    {
      stack.Children.Remove(loading);
      stack.Children.Add(Card("Couldn’t read accounts", "Your saved accounts have been kept. Try reading them again.", "Try again", RenderAsync));
      return;
    }
    // Each AI's installation is read once, all at the same time.
    foreach (var provider in CodingAis)
      if (!installations.ContainsKey(provider) && accounts.FirstOrDefault(a => a.Provider == provider) is { } first)
        installations[provider] = runtime.Accounts.InstallationAsync(first.Id).AsTask();
    var sections = new List<FrameworkElement>();
    var missing = new List<string>();
    foreach (var provider in CodingAis)
    {
      var group = accounts.Where(a => a.Provider == provider).ToArray();
      if (group.Length == 0) continue;
      ProviderInstallation? installation = null;
      try { installation = await installations[provider].WaitAsync(ct); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException) { installations.Remove(provider); }
      // Never a group for an AI that is not on this PC; only its Install row below.
      if (installation?.Installed == false) { missing.Add(provider); continue; }
      var rows = group.Select(a => (FrameworkElement)AccountRow(a)).ToList();
      rows.Add(AiPageAddRow("Add account", "accounts.add." + provider, () => ShowAddAccountAsync(provider)));
      sections.Add(AiPageSection(AccountMcp.AgentName(provider), provider, installation?.Version is { } version ? "Version " + version : null,
        Settings.SettingsPanel.GroupRows(rows), Settings.SettingsPanel.GroupRows(LaunchModelRows(provider))));
    }
    stack.Children.Remove(loading);
    if (accounts.Count == 0) stack.Children.Add(Description("No accounts yet"));
    foreach (var section in sections) stack.Children.Add(section);
    if (sections.Count == 0) stack.Children.Add(Settings.SettingsPanel.GroupRows([AiPageAddRow("Add account", "accounts.add", () => ShowAddAccountAsync())]));
    var more = new List<FrameworkElement> { AiPageLinkRow("Which account agents use", () => SelectSectionAsync(1)) };
    foreach (var provider in missing)
    {
      var install = new Button { Content = "Install" };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(install, "accounts.install." + provider);
      install.Click += async (_, _) => await AiPageRunAsync(install, async () => { await runtime.InstallAiAsync(provider); installations.Remove(provider); await RenderAsync(); });
      more.Add(AiPageRow(AccountMcp.AgentName(provider), "Not installed", install));
    }
    more.Add(AiPageLinkRow("Custom terminal CLIs", () => { Agents.CustomTerminalProviderWindow.Open(runtime.CustomProviders, ActualTheme); return Task.CompletedTask; }));
    stack.Children.Add(Settings.SettingsPanel.GroupRows(more));
  }

  // "Default model" and "Default effort": what every new session, chat, agent and Hoot starts with
  // unless one is chosen for it (one place). The list shows the models' real names, never "Default".
  private List<FrameworkElement> LaunchModelRows(string provider)
  {
    var (savedModel, savedEffort) = LaunchDefaults.For(provider, runtime.General.Read());
    var signedIn = runtime.Accounts.Preferred(provider);
    var models = ModelCatalog.Merge(provider, runtime.Accounts.InstantModels(provider, signedIn?.Id).Models, savedModel);
    var model = new ComboBox { ItemsSource = models.Select(m => m.Name).ToArray(), SelectedIndex = Math.Max(0, models.ToList().FindIndex(m => m.Id == savedModel)), MinWidth = 200 };
    var levels = ModelEfforts.For(provider, models.FirstOrDefault(m => m.Id == savedModel)).ToArray();
    var effort = new ComboBox { ItemsSource = levels.Select(ModelCatalog.EffortName).ToArray(), SelectedIndex = Math.Max(0, Array.IndexOf(levels, savedEffort ?? "")), MinWidth = 140, Visibility = levels.Length == 0 ? Visibility.Collapsed : Visibility.Visible };
    var saving = false;
    void Save()
    {
      if (saving || model.SelectedIndex < 0) return;
      saving = true;
      try
      {
        var chosen = models[model.SelectedIndex];
        var offered = ModelEfforts.For(provider, chosen).ToArray();
        var level = effort.SelectedIndex >= 0 && effort.SelectedIndex < levels.Length ? levels[effort.SelectedIndex] : null;
        if (level is null || !offered.Contains(level)) level = offered.Contains(ModelCatalog.TopEffort(provider) ?? "") ? ModelCatalog.TopEffort(provider) : offered.LastOrDefault();
        if (!offered.SequenceEqual(levels)) { levels = offered; effort.ItemsSource = levels.Select(ModelCatalog.EffortName).ToArray(); }
        effort.SelectedIndex = Array.IndexOf(levels, level ?? ""); effort.Visibility = levels.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        runtime.General.Save(LaunchDefaults.With(runtime.General.Read(), provider, chosen.Id, level));
      }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { this.model.Notice = "Couldn’t save that choice. Your previous one was kept."; }
      finally { saving = false; }
    }
    model.SelectionChanged += (_, _) => Save(); effort.SelectionChanged += (_, _) => Save();
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(model, "accounts.launchModel." + provider);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(effort, "accounts.launchEffort." + provider);
    var rows = new List<FrameworkElement> { Settings.SettingsPanel.SettingRow("Default model", "New " + AccountMcp.AgentName(provider) + " sessions, chats, agents and Hoot start with it unless one is chosen for them. Running sessions keep theirs.", model) };
    if (levels.Length > 0) rows.Add(Settings.SettingsPanel.SettingRow("Default effort", "How hard the model thinks by default. Change it for one session in its own picker.", effort));
    return rows;
  }

  private Border AccountRow(AccountProfile account)
  {
    var api = account.Authentication == AccountAuthentication.ApiKey;
    var connection = api ? runtime.ApiAccounts.Read(account.Id) : null;
    var ready = api ? connection is { Configured: true } && connection.CheckState is not ("invalid" or "no-access" or "needs-key") : account.SignedIn;
    var state = api ? ApiAccountService.Status(connection) : account.SignedIn ? "Signed in" : "Needs sign-in";
    var plan = api ? "API key" : string.IsNullOrWhiteSpace(account.Plan) ? null : PlanName(account.Plan);
    var info = new List<string>();
    if (!api && account.Email is not null) info.Add(account.Email);
    if (api && connection is not null)
      info.Add(ApiKinds.For(account.Provider).FirstOrDefault(k => k.Kind == connection.Kind).Name + (connection.CheckedAt is { } at ? " · Checked " + at.ToLocalTime().ToString("g") : ""));
    var attached = AttachedSessions(account.Id).Count;
    if (attached > 0) info.Add(attached == 1 ? "1 open session uses it" : attached + " open sessions use it");
    var actions = new MenuFlyout();
    void Item(string text, Func<Task> click, bool enabled = true)
    {
      var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
      item.Click += async (_, _) => { try { await click(); } catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException) { model.Notice = ex.Message; } };
      actions.Items.Add(item);
    }
    if (api)
    {
      Item("Edit key…", () => ShowApiAccountAsync(account.Provider, account.Id));
      Item("Check key", async () => { await runtime.ApiAccounts.CheckAsync(account.Id); await RenderAsync(); });
    }
    else
    {
      Item(account.SignedIn || account.Email is not null ? "Sign in again…" : "Sign in…", () => SignInAccountAsync(account.Id));
      Item("Sign out…", () => SignOutAccountAsync(account.Id), account.SignedIn);
    }
    Item("Rename…", () => RenameAccountAsync(account.Id));
    var colours = new MenuFlyoutSubItem { Text = "Colour" };
    foreach (var colour in AccountColors.All)
    {
      var choice = new ToggleMenuFlyoutItem { Text = AccountColors.Name(colour), IsChecked = (account.Color ?? "blue") == colour };
      choice.Click += async (_, _) => { await runtime.Accounts.SetColorAsync(account.Id, colour); await RenderAsync(); };
      colours.Items.Add(choice);
    }
    actions.Items.Add(colours);
    actions.Items.Add(new MenuFlyoutSeparator());
    Item("Remove…", () => RemoveAccountAsync(account.Id));
    return AiPageRow(account.Name, plan, AiPageMenu(actions, "Account actions"), AiPageDot(ready, state), info.Count == 0 ? null : string.Join("\n", info));
  }
  private static string PlanName(string plan) => plan.ToLowerInvariant() switch
  {
    "max" => "Max plan", "pro" => "Pro plan", "team" => "Team plan", "enterprise" => "Enterprise plan", "plus" => "Plus plan", "free" => "Free plan", "business" => "Business plan",
    _ => char.ToUpperInvariant(plan[0]) + plan[1..] + " plan"
  };

  // Open terminals and chats using this account (Remove shows them and can close them).
  private List<(string Id, string Title, bool Chat)> AttachedSessions(string accountId)
  {
    var rows = runtime.Sessions.Where(s => s.Definition.AccountId == accountId && s.State != TerminalDeck.Core.Sessions.SessionState.Exited)
      .Select(s => (s.Definition.Id, s.Definition.Title, false)).ToList();
    // Chats connect a moment after the window opens; until then there are none to list.
    if (runtime.Chats is null) return rows;
    try { rows.AddRange(runtime.Chats.List().Where(c => c.Definition.AccountId == accountId && !c.Ended).Select(c => (c.Definition.Id, c.Definition.Title, true))); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
    return rows;
  }

  private async Task RemoveAccountAsync(string id)
  {
    var account = runtime.Accounts.Get(id);
    var attached = AttachedSessions(id);
    var words = new StackPanel { Spacing = 8 };
    words.Children.Add(Description("Remove " + account.Name + " from " + TerminalDeck.Core.Brand.Name + "? " + (account.Authentication == AccountAuthentication.ApiKey
      ? "Its saved key is deleted from Windows Credential Manager."
      : account.HomeId == AccountHomes.ExistingLogin ? "The AI’s own Windows login is not signed out." : "Its login folder stays on disk; nothing is deleted from it.") + " Its conversations stay saved."));
    if (attached.Count > 0)
    {
      words.Children.Add(Description((attached.Count == 1 ? "This session uses it:" : "These sessions use it:") + "\n" + string.Join("\n", attached.Take(12).Select(s => "• " + s.Title + (s.Chat ? " (chat)" : " (terminal)")))));
      words.Children.Add(Description("Switch them to another account first, or close them and remove."));
    }
    var feedback = new Notices.CompactNotice(); words.Children.Add(feedback);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Remove account", Content = new ScrollViewer { Content = words, MaxHeight = 440 },
      PrimaryButtonText = attached.Count > 0 ? "Close them and remove" : "Remove", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral();
      try
      {
        foreach (var session in attached)
        {
          if (session.Chat) await runtime.Chats.EndAsync(session.Id); else await runtime.StopAsync(session.Id);
        }
        await runtime.RefreshSessionsAsync();
        bool InUse(string accountId) => AttachedSessions(accountId).Count > 0;
        if (account.Authentication == AccountAuthentication.ApiKey) await runtime.ApiAccounts.RemoveAsync(id, InUse);
        else await runtime.Accounts.DeleteAsync(id, InUse);
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or UnauthorizedAccessException)
      { args.Cancel = true; feedback.Text = ex is InvalidOperationException ? ex.Message : "The account could not be removed. It is still saved; try again."; }
      finally { deferral.Complete(); }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) { installations.Clear(); await RenderAsync(); }
  }

  private async Task SignInAccountAsync(string id)
  {
    try { await runtime.Accounts.SignInAsync(id, runtime.Root.DirectoryPath); }
    catch (SignInCancelledException) { }
    await RenderAsync();
  }

  private async Task RenameAccountAsync(string id)
  {
    var account = runtime.Accounts.Get(id);
    var name = new TextBox { Header = "Name", Text = account.Name, MaxLength = 80 };
    var feedback = new Notices.CompactNotice();
    var form = new StackPanel { Spacing = 12 }; form.Children.Add(name); form.Children.Add(feedback);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Rename account", Content = form, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text) && !name.Text.Any(char.IsControl);
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral();
      try { await runtime.Accounts.RenameAsync(id, name.Text); }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { args.Cancel = true; feedback.Text = "The name could not be saved. Check it and try again."; }
      finally { deferral.Complete(); }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }

  private async Task SignOutAccountAsync(string id)
  {
    var account = runtime.Accounts.Get(id);
    var explanation = Description("Sign out of " + account.Name + "? " + (account.HomeId == AccountHomes.ExistingLogin ? "This is this computer’s own " + AccountMcp.AgentName(account.Provider) + " login, not one the app keeps: your terminal and every other app using it are signed out too. " : "This signs out this account’s separate login. ") + "Its name, assignments and conversations stay saved.");
    var feedback = new Notices.CompactNotice();
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Sign out", Content = new StackPanel { Spacing = 8, Children = { explanation, feedback } }, PrimaryButtonText = account.HomeId == AccountHomes.ExistingLogin ? "Sign out on this computer" : "Sign out", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var deferral = args.GetDeferral();
      try { await runtime.Accounts.SignOutAsync(id); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException) { args.Cancel = true; feedback.Text = "The AI could not finish signing out. Read account status, then try again."; }
      finally { deferral.Complete(); }
    };
    if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RenderAsync();
  }
}
