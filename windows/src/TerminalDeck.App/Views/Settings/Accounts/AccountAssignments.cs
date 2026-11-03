using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.App.Views;

// Settings → Who uses what (Mac: NativeAccountLevels): one place that assigns an
// account to the whole app, each project's sessions and chats, Hoot and each
// agent, with the effective "Uses <account> · <source>" on every row. Saving only
// affects new sessions; Switch everything now moves running ones after a preview.
public sealed partial class SettingsPane
{
  private int assignmentProvider;
  private string assignmentSearch = "";
  // Never "Choose model": an agent without its own choice runs the app-wide one.
  private string ModelDefaults(string provider, string? model, string? effort)
  {
    var (appModel, appEffort) = LaunchDefaults.For(provider, runtime.General.Read());
    var ownModel = !string.IsNullOrWhiteSpace(model); var ownEffort = !string.IsNullOrWhiteSpace(effort) && effort != "auto";
    return ModelCatalog.Label(provider, ownModel ? model : appModel, ownEffort ? effort : appEffort) + (ownModel || ownEffort ? "" : " · app-wide choice");
  }
  private void AddAssignmentRows(StackPanel stack)
  {
    var providers = CodingAis;
    var picker = new ComboBox { Header = "AI", ItemsSource = providers.Select(AccountMcp.AgentName).ToArray(), SelectedIndex = assignmentProvider, HorizontalAlignment = HorizontalAlignment.Stretch };
    var filter = new TextBox { PlaceholderText = "Find a project or role", Text = assignmentSearch };
    var switchAll = new Button { Content = "Switch everything now…" };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(switchAll, "accounts.switchAll");
    switchAll.Click += async (_, _) => await ShowBulkSwitchAsync(providers[picker.SelectedIndex]);
    var rows = new StackPanel { Spacing = 16 };
    stack.Children.Add(picker); stack.Children.Add(filter);
    stack.Children.Add(Description("Choices here apply to new sessions. Running sessions keep their account until you switch them."));
    stack.Children.Add(switchAll); stack.Children.Add(rows);
    bool Matches(string text) => text.Contains(filter.Text.Trim(), StringComparison.OrdinalIgnoreCase);
    void Populate()
    {
      rows.Children.Clear();
      var provider = providers[picker.SelectedIndex];
      var accounts = runtime.Accounts.List(provider).ToArray();
      var app = runtime.Accounts.Default(provider);
      string Label(AccountProfile a) => a.Name + (a.Authentication == AccountAuthentication.ApiKey ? " · API key" : "") + (a.SignedIn ? "" : " · sign in needed");
      string Identity(string? id, AccountProfile? fallback, string basis)
      {
        if (id is null) return fallback is null ? "No account chosen yet" : "Uses " + fallback.Name + " · " + basis + (fallback.SignedIn ? "" : " · Sign in again");
        var account = accounts.FirstOrDefault(a => a.Id == id);
        return account is null ? "Saved account is no longer available · choose another" : "Uses " + account.Name + " · Set here" + (account.SignedIn ? "" : " · Sign in again");
      }
      if (Matches("Whole app"))
      {
        var defaultPicker = new ComboBox { Header = "Whole app · account for new " + AccountMcp.AgentName(provider) + " sessions", ItemsSource = accounts.Select(Label).ToArray(), SelectedIndex = app is null ? -1 : Array.FindIndex(accounts, a => a.Id == app.Id), HorizontalAlignment = HorizontalAlignment.Stretch, PlaceholderText = accounts.Length == 0 ? "Add an account in Coding AIs" : "Pick an account" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(defaultPicker, "accounts.wholeApp");
        var outcome = new Notices.CompactNotice();
        var savedIndex = defaultPicker.SelectedIndex; var savingDefault = false;
        defaultPicker.SelectionChanged += async (_, _) =>
        {
          if (savingDefault || defaultPicker.SelectedIndex < 0 || defaultPicker.SelectedIndex == savedIndex) return;
          savingDefault = true; defaultPicker.IsEnabled = false; outcome.Text = "Saving…";
          try { await runtime.Accounts.SetDefaultAsync(provider, accounts[defaultPicker.SelectedIndex].Id); savedIndex = defaultPicker.SelectedIndex; outcome.Text = "Saved. Running sessions were kept."; }
          catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException) { defaultPicker.SelectedIndex = savedIndex; outcome.Text = "Couldn’t save the account. Your previous choice was kept. Try again."; }
          finally { savingDefault = false; defaultPicker.IsEnabled = true; }
        };
        rows.Children.Add(defaultPicker); rows.Children.Add(outcome);
        if (app is { SignedIn: false } && app.Authentication == AccountAuthentication.Subscription) rows.Children.Add(Card(app.Name, "This saved choice stays in place while you sign in again.", "Sign in again", () => SignInAccountAsync(app.Id)));
      }
      var hoot = runtime.Hoot.Read().Settings;
      if (hoot?.Provider == provider && Matches("Hoot")) rows.Children.Add(Card("Hoot", Identity(hoot.AccountId, null, "Hoot") + "\n" + ModelDefaults(provider, hoot.Options.Model, hoot.Options.Effort), "Hoot settings", () => { model.Page = ViewModels.ShellPage.Hoot; return Task.CompletedTask; }));
      foreach (var project in runtime.Projects.List().Where(p => p.IsOpen && p.Id != ProjectIdentity.IndependentId))
      {
        foreach (var use in new[] { "sessions", "chats" })
        {
          if (!Matches(project.Name + " " + use)) continue;
          var choice = project.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Use == use);
          var inherited = project.HomeFolder is null ? app : runtime.Accounts.Default(provider, project.HomeFolder);
          var mine = choice?.Provider == provider ? choice.AccountId : null;
          var otherAi = choice is not null && choice.Provider != provider;
          var options = accounts.Select(Label).Prepend("Same as whole app" + (inherited is null ? "" : " · " + inherited.Name)).ToArray();
          var row = new ComboBox { Header = project.Name + " · " + (use == "chats" ? "chats" : "terminal sessions"), ItemsSource = options, SelectedIndex = mine is null ? 0 : Array.FindIndex(accounts, a => a.Id == mine) + 1, HorizontalAlignment = HorizontalAlignment.Stretch };
          var note = Description(otherAi ? "This project uses " + AccountMcp.AgentName(choice!.Provider) + " for " + use + ". Picking an account here switches that to " + AccountMcp.AgentName(provider) + "."
            : Identity(mine, inherited, inherited?.Id == app?.Id ? "Whole app" : "Folder default"));
          var saved = row.SelectedIndex;
          row.SelectionChanged += (_, _) =>
          {
            if (row.SelectedIndex < 0 || row.SelectedIndex == saved) return;
            try
            {
              var current = runtime.Projects.Get(project.Id).Preferences.WhoUsesWhat.Where(c => c.Use != use).ToList();
              if (row.SelectedIndex > 0) current.Add(new ProjectAiChoice(use, provider, accounts[row.SelectedIndex - 1].Id));
              else if (otherAi) current.Add(choice!);
              runtime.Projects.SetWhoUsesWhat(project.Id, current);
              saved = row.SelectedIndex; note.Text = "Saved for new " + use + ". Running ones were kept.";
            }
            catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException) { row.SelectedIndex = saved; note.Text = "Couldn’t save. The previous choice was kept."; }
          };
          var block = new StackPanel { Spacing = 4 }; block.Children.Add(row); block.Children.Add(note); rows.Children.Add(block);
        }
      }
      foreach (var agent in runtime.Agents.List().Where(a => a.Provider == provider && a.Status == SavedAgentStatus.Active))
      {
        var project = runtime.Projects.List().FirstOrDefault(p => p.Id == agent.ProjectId);
        if (!Matches(agent.Name + " " + project?.Name + " " + agent.Seat)) continue;
        var inheritedId = AccountAssignment.Effective(runtime.Accounts, project, "sessions", provider);
        var inherited = accounts.FirstOrDefault(a => a.Id == inheritedId);
        var lead = project?.Lead == "agent:" + agent.Id;
        rows.Children.Add(Card(agent.Name + (lead ? " (lead)" : "") + " · " + (project?.Name ?? "Independent") + (agent.Seat.Length > 0 ? " · " + agent.Seat : ""),
          Identity(agent.AccountId, inherited, "Same as above") + "\n" + ModelDefaults(provider, agent.Model, agent.Effort), "Change in Agents…", () => { model.Page = ViewModels.ShellPage.Agents; return Task.CompletedTask; }));
      }
      if (rows.Children.Count == 0) rows.Children.Add(Description("No matching projects or roles"));
    }
    picker.SelectionChanged += (_, _) => { assignmentProvider = picker.SelectedIndex; Populate(); };
    filter.TextChanged += (_, _) => { assignmentSearch = filter.Text; Populate(); };
    Populate();
  }

  // Bulk Switch sheet: every running session of this AI with where it would go.
  // Each row has its own tick, so a session set on purpose can be left alone.
  private async Task ShowBulkSwitchAsync(string provider)
  {
    var running = new List<RunningAiSession>();
    foreach (var s in runtime.Sessions.Where(s => s.Definition.Provider == provider && s.State != TerminalDeck.Core.Sessions.SessionState.Exited && s.Definition.AccountId is not null))
      running.Add(new(s.Definition.Id, s.Definition.Title, "terminal", provider, s.Definition.AccountId!, s.Definition.Cwd, null, false));
    try
    {
      foreach (var c in runtime.Chats.List().Where(c => c.Definition.Provider == provider && !c.Ended))
        running.Add(new(c.Definition.Id, c.Definition.Title, "chat", provider, c.Definition.AccountId, c.Definition.Cwd, null, false));
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
    string? Target(RunningAiSession s)
    {
      var projectId = runtime.Projects.Resolve(null, s.Folder);
      var project = runtime.Projects.List().FirstOrDefault(p => p.Id == projectId);
      return AccountAssignment.Effective(runtime.Accounts, project, s.Kind == "chat" ? "chats" : "sessions", provider);
    }
    var plan = BulkSwitch.Plan(running, provider, Target, includeIndividual: true);
    string Name(string? id) { try { return id is null ? "no account" : runtime.Accounts.Get(id).Name; } catch (ArgumentException) { return "a removed account"; } }
    var list = new StackPanel { Spacing = 8 };
    list.Children.Add(Description(BulkSwitch.Summary(plan) + " Each one keeps its tab and conversation."));
    var ticks = new List<(BulkSwitchRow Row, CheckBox Tick, TextBlock Result)>();
    foreach (var row in plan)
    {
      var tick = new CheckBox { Content = row.Session.Title + " (" + row.Session.Kind + ") · " + Name(row.Session.AccountId) + " → " + Name(row.To), IsChecked = row.Action == BulkSwitchAction.Switch, IsEnabled = row.Action == BulkSwitchAction.Switch };
      var result = Description(row.Action == BulkSwitchAction.Already ? "Already uses its assigned account." : row.Action == BulkSwitchAction.NoAssignment ? "No account is assigned for it." : "");
      ticks.Add((row, tick, result)); list.Children.Add(tick); list.Children.Add(result);
    }
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Switch " + AccountMcp.AgentName(provider) + " sessions", Content = new ScrollViewer { Content = list, MaxHeight = 460 },
      PrimaryButtonText = plan.Any(r => r.Action == BulkSwitchAction.Switch) ? "Switch now" : "", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
    var done = false;
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      if (done) return;
      var deferral = args.GetDeferral(); args.Cancel = true; dialog.IsPrimaryButtonEnabled = false;
      try
      {
        foreach (var (row, tick, result) in ticks.Where(t => t.Tick.IsChecked == true && t.Row.To is not null))
        {
          result.Text = "Switching…";
          try
          {
            if (row.Session.Kind == "chat") await runtime.Chats.SetAccountAsync(row.Session.Id, row.To!);
            else { await runtime.AccountSwitches.PlanAsync(row.Session.Id, row.To!); await runtime.AccountSwitches.SwitchAsync(row.Session.Id, row.To!); }
            result.Text = "Switched to " + Name(row.To) + ".";
          }
          catch (Exception ex) when (ex is not OutOfMemoryException)
          { result.Text = (ex is ArgumentException or InvalidOperationException ? ex.Message : "Couldn’t switch.") + " It keeps " + Name(row.Session.AccountId) + "."; }
          tick.IsEnabled = false;
        }
        await runtime.RefreshSessionsAsync();
      }
      finally { done = true; dialog.CloseButtonText = "Done"; deferral.Complete(); }
    };
    await dialog.ShowAsync();
    await RenderAsync();
  }
}
