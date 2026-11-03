using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.App.Views;

// Settings → Coding AIs (Mac: NativeCodingAIAccounts). Each AI: installation, the
// model and level new sessions start with, then every account it holds — several
// subscription logins and API keys side by side — each with sign in/out, rename,
// colour, API key edit/check and remove. Which account is used where lives in
// "Who uses what"; the Default badge here only reports it.
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
    stack.Children.Remove(loading);
    if (accounts.Count == 0) stack.Children.Add(Description("No accounts yet"));
    foreach (var provider in CodingAis)
    {
      var group = accounts.Where(a => a.Provider == provider).ToArray();
      stack.Children.Add(new TextBlock { Text = AccountMcp.AgentName(provider), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      var status = Description("Reading installation…"); stack.Children.Add(status);
      var installNeeded = true;
      if (group.Length > 0)
      {
        if (!installations.TryGetValue(provider, out var task)) installations[provider] = task = runtime.Accounts.InstallationAsync(group[0].Id).AsTask();
        try
        {
          var installation = await task.WaitAsync(ct);
          installNeeded = installation.Installed != true || installation.Version is null;
          status.Text = (installation.Installed == true ? "Installed" : installation.Installed == false ? "Not installed" : "Installation unknown") + (installation.Version is null ? "" : " · " + installation.Version) + " · Checked " + installation.CheckedAt.ToLocalTime().ToString("t") + "\n" + installation.Note;
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException) { status.Text = "Couldn’t read installation status. Try again."; }
      }
      else status.Text = "No accounts yet. Add one below to sign in or use an API key.";
      var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      var install = new Button { Content = "Install", Visibility = installNeeded && group.Length > 0 ? Visibility.Visible : Visibility.Collapsed };
      install.Click += async (_, _) => { await runtime.InstallAiAsync(provider); installations.Remove(provider); await RenderAsync(); }; tools.Children.Add(install);
      var retry = new Button { Content = "Read installation", Visibility = group.Length > 0 ? Visibility.Visible : Visibility.Collapsed };
      retry.Click += async (_, _) => { installations.Remove(provider); await RenderAsync(); }; tools.Children.Add(retry);
      var add = new Button { Content = "Add " + AccountMcp.AgentName(provider) + " account…" };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(add, "accounts.add." + provider);
      add.Click += async (_, _) => await ShowAddAccountAsync(provider); tools.Children.Add(add);
      stack.Children.Add(tools);
      stack.Children.Add(LaunchModelRow(provider));
      var defaultAccount = runtime.Accounts.Default(provider);
      foreach (var account in group) stack.Children.Add(AccountCard(account, defaultAccount?.Id == account.Id));
    }
    stack.Children.Add(Card("Custom terminal CLIs", "Add another coding tool using its exact Windows executable, literal arguments and private environment values.", "Manage…", () => { Agents.CustomTerminalProviderWindow.Open(runtime.CustomProviders, ActualTheme); return Task.CompletedTask; }));
  }

  // "New sessions start with": the app-wide model and level (one place; sessions,
  // chats, agents and hands without their own choice, and Hoot use it).
  private FrameworkElement LaunchModelRow(string provider)
  {
    var (savedModel, savedEffort) = LaunchDefaults.For(provider, runtime.General.Read());
    var signedIn = runtime.Accounts.Preferred(provider);
    var models = ModelCatalog.Merge(provider, runtime.Accounts.InstantModels(provider, signedIn?.Id).Models, savedModel);
    var model = new ComboBox { Header = "Model", ItemsSource = models.Select(m => m.Name).ToArray(), SelectedIndex = Math.Max(0, models.ToList().FindIndex(m => m.Id == savedModel)), MinWidth = 200 };
    var levels = ModelEfforts.For(provider, models.FirstOrDefault(m => m.Id == savedModel)).ToArray();
    var effort = new ComboBox { Header = "Effort", ItemsSource = levels.Select(ModelCatalog.EffortName).ToArray(), SelectedIndex = Math.Max(0, Array.IndexOf(levels, savedEffort ?? "")), MinWidth = 140, Visibility = levels.Length == 0 ? Visibility.Collapsed : Visibility.Visible };
    var outcome = new Notices.CompactNotice();
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
        outcome.Text = "New sessions start with " + ModelCatalog.Label(provider, chosen.Id, level) + ". Running sessions keep theirs.";
      }
      catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { outcome.Text = "Couldn’t save that choice. Your previous one was kept."; }
      finally { saving = false; }
    }
    model.SelectionChanged += (_, _) => Save(); effort.SelectionChanged += (_, _) => Save();
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(model, "accounts.launchModel." + provider);
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(effort, "accounts.launchEffort." + provider);
    var pickers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; pickers.Children.Add(model); pickers.Children.Add(effort);
    var card = (Border)Settings.SettingsPanel.SettingRow("New sessions start with", "The model and effort every new " + AccountMcp.AgentName(provider) + " session, chat, agent and Hoot uses unless one is chosen for it. Change it for one session in its own picker.", pickers);
    if (card.Child is Grid row && row.Children.OfType<StackPanel>().FirstOrDefault() is { } words) words.Children.Add(outcome);
    return card;
  }

  private Border AccountCard(AccountProfile account, bool isDefault)
  {
    var api = account.Authentication == AccountAuthentication.ApiKey;
    var connection = api ? runtime.ApiAccounts.Read(account.Id) : null;
    var state = api ? ApiAccountService.Status(connection)
      : account.SignedIn ? account.Email ?? "Signed in · identity not reported"
      : account.Email is not null ? account.Email + " · Not signed in" : "Not signed in";
    var action = api ? "Check key" : account.SignedIn ? "View models" : account.Email is not null ? "Sign in again" : "Sign in";
    Func<Task> act = api ? async () => { await runtime.ApiAccounts.CheckAsync(account.Id); await RenderAsync(); }
      : account.SignedIn ? () => ShowAccountModelsAsync(account.Id) : () => SignInAccountAsync(account.Id);
    var card = Card(account.Name, "", action, act);
    if (card.Child is Grid grid && grid.Children.OfType<StackPanel>().FirstOrDefault() is { } words)
    {
      if (words.Children.FirstOrDefault() is Grid label && label.Children.OfType<TextBlock>().FirstOrDefault() is { } title)
      {
        title.Text = ""; title.Inlines.Clear();
        title.Inlines.Add(new Run { Text = "● ", Foreground = AccountBrush(account.Color) });
        title.Inlines.Add(new Run { Text = account.Name });
      }
      var badges = new List<string> { api ? "API key" : "Subscription" };
      if (isDefault) badges.Add("Whole-app account");
      if (account.HomeId == AccountHomes.ExistingLogin) badges.Add("Your own install");
      if (!string.IsNullOrWhiteSpace(account.Plan)) badges.Add(PlanName(account.Plan));
      words.Children.Insert(1, Description(string.Join(" · ", badges)));
      words.Children.Insert(2, Description(state));
      var extra = api ? (connection is null ? "Edit this account and paste its key." : ApiKinds.For(account.Provider).FirstOrDefault(k => k.Kind == connection.Kind).Name + (connection.BaseUrl is { } url ? " · " + url : "") + (connection.WorkspaceId is { } workspace ? " · Workspace " + workspace : "") + (connection.CheckedAt is { } at ? " · Checked " + at.ToLocalTime().ToString("g") : ""))
        + "\nUsage and reported cost appear in each chat. Subscription windows are separate."
        : account.HomeId == AccountHomes.ExistingLogin ? "Follows this AI’s existing Windows login." : "Kept in its own login folder in this app.";
      words.Children.Insert(3, Description(extra));
      var attached = AttachedSessions(account.Id);
      if (attached.Count > 0) words.Children.Insert(4, Description(attached.Count == 1 ? "1 open session uses it" : attached.Count + " open sessions use it"));
    }
    var actions = new MenuFlyout();
    void Item(string text, Func<Task> click, bool enabled = true)
    {
      var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
      item.Click += async (_, _) => { try { await click(); } catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException) { model.Notice = ex.Message; } };
      actions.Items.Add(item);
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
    if (api)
    {
      Item("Edit API connection and key…", () => ShowApiAccountAsync(account.Provider, account.Id));
      Item("Check key", async () => { await runtime.ApiAccounts.CheckAsync(account.Id); await RenderAsync(); });
    }
    else
    {
      if (account.SignedIn) Item("Sign in again…", () => SignInAccountAsync(account.Id));
      Item("Sign out…", () => SignOutAccountAsync(account.Id), account.SignedIn);
    }
    actions.Items.Add(new MenuFlyoutSeparator());
    Item("Who uses what…", () => SelectSectionAsync(1));
    Item("Remove…", () => RemoveAccountAsync(account.Id));
    AddCardMenu(card, actions, "Account actions");
    return card;
  }
  private static string PlanName(string plan) => plan.ToLowerInvariant() switch
  {
    "max" => "Max plan", "pro" => "Pro plan", "team" => "Team plan", "enterprise" => "Enterprise plan", "plus" => "Plus plan", "free" => "Free plan", "business" => "Business plan",
    _ => char.ToUpperInvariant(plan[0]) + plan[1..] + " plan"
  };
  private Microsoft.UI.Xaml.Media.Brush AccountBrush(string? color) => (Microsoft.UI.Xaml.Media.Brush)TerminalDeck.App.Shell.ShellTheme.Resource(this, color switch
  {
    "green" => "DeckProjectGreenBrush", "amber" => "DeckProjectYellowBrush", "orange" => "DeckProjectOrangeBrush", "red" => "DeckAgentRedBrush",
    "purple" => "DeckProjectPurpleBrush", "teal" => "DeckProjectTealBrush", "pink" => "DeckProjectPinkBrush", _ => "DeckProjectBlueBrush"
  });

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
