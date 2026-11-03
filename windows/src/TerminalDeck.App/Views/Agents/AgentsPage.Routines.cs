using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Hoot;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Agents;

public interface IAgentRoutinesNavigation { HootRoutines AgentRoutines { get; } }

public sealed partial class AgentsPage
{
  private void RoutinesTab(StackPanel body, string? agentId)
  {
    if (navigation is not IAgentRoutinesNavigation owner) { body.Children.Add(Words("Routine service is not connected in this window.", muted: true)); return; }
    var service = owner.AgentRoutines;
    body.Children.Add(Header("Routines", "Scheduled and event-driven work. Status comes from the actual run receipts.", AsyncButton("New routine", () => EditRoutineAsync(service, null, agentId))));
    var routines = service.List().Where(r => agentId is null || r.AgentId == agentId).OrderBy(r => r.Name).ToArray();
    if (routines.Length == 0) body.Children.Add(Card(Words("No routines yet. Add an instruction and choose when it runs.", muted: true)));
    foreach (var routine in routines)
    {
      var content = Stack(8); var enabled = new ToggleSwitch { Header = routine.Name, IsOn = routine.Enabled };
      enabled.Toggled += async (_, _) => await Model.RunAsync(() => service.Save(routine with { Enabled = enabled.IsOn }), enabled.IsOn ? "Routine enabled." : "Routine disabled."); content.Children.Add(enabled);
      var current = routine.Runs.LastOrDefault(r => r.State is "running" or "queued");
      var status = routine.RecoveryHold ? "Needs review · previous delivery is uncertain" : current?.State == "running" ? "Running" : current?.State == "queued" ? "Queued" : routine.Enabled ? "Ready" : "Paused";
      content.Children.Add(Words(status + (routine.NextAt is { } next ? " · Next " + next.ToLocalTime().ToString("g") : ""), 12, true));
      content.Children.Add(Words((routine.AgentId == "@hoot" ? "Hoot" : Model.Agents.List().FirstOrDefault(a => a.Id == routine.AgentId)?.Name ?? routine.AgentId) + " · " + routine.Folder, 12, true));
      content.Children.Add(Words(routine.Triggers.Length == 0 ? "Every " + routine.EveryMinutes + " minutes" : string.Join(" · ", routine.Triggers), 12));
      if (routine.LastAt is { } last) content.Children.Add(Words("Last run " + last.ToLocalTime().ToString("g") + (routine.LastOutcome is { Length: > 0 } outcome ? " · " + outcome : ""), 12, true));
      if (routine.Problem is { Length: > 0 } problem) content.Children.Add(Words(problem, 12));
      var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      actions.Children.Add(AsyncButton("Edit", () => EditRoutineAsync(service, routine, agentId)));
      var runNow = AsyncButton(routine.RecoveryHold ? "Run a new attempt" : "Run now", () => Model.RunAsync(async () => await service.RunAsync(routine.Id, CancellationToken.None), "Run requested. Follow its receipt below.")); runNow.IsEnabled = routine.Enabled; ToolTipService.SetToolTip(runNow, routine.Enabled ? "Queue one run using this routine’s configured limits" : "Enable this routine to run it"); actions.Children.Add(runNow);
      actions.Children.Add(AsyncButton("Stop current work", () => Model.RunAsync(async () => await service.StopAsync(routine.Id, CancellationToken.None), "Stop requested for this routine.")));
      if (routine.RecoveryHold) actions.Children.Add(AsyncButton("Keep unconfirmed", () => Model.RunAsync(() => service.KeepUnconfirmed(routine.Id), "Previous delivery kept unconfirmed. It was not resent.")));
      actions.Children.Add(AsyncButton("Delete…", async () =>
      {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Delete " + routine.Name + "?", Content = "This removes the routine and stops its own active and queued work.", PrimaryButtonText = "Delete routine", CloseButtonText = "Keep", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.RunAsync(() => service.Remove(routine.Id), "Routine deleted.");
      })); content.Children.Add(new ScrollViewer { Content = actions, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
      var history = Stack(6);
      foreach (var run in routine.Runs.OrderByDescending(r => r.At).Take(30))
      {
        var row = Stack(2); row.Children.Add(Words(run.At.ToLocalTime().ToString("g") + " · " + run.State + " · " + run.Cause, 12));
        if (run.Problem is { Length: > 0 } issue) row.Children.Add(Words(issue, 12, true));
        if (run.SessionId is { } session) row.Children.Add(Button("Open run", () => navigation.OpenSession(session)));
        history.Children.Add(row);
      }
      content.Children.Add(new Expander { Header = "Run history · " + routine.Runs.Length, Content = history, HorizontalAlignment = HorizontalAlignment.Stretch }); body.Children.Add(Card(content));
    }
  }
  private async Task EditRoutineAsync(HootRoutines service, HootRoutine? previous, string? owner)
  {
    var form = Stack(12); var name = new TextBox { Header = "Name", Text = previous?.Name ?? "", MaxLength = 120 };
    var purpose = new TextBox { Header = "Purpose", Text = previous?.Purpose ?? "", MaxLength = 1000 };
    var folder = new TextBox { Header = "Working folder", Text = previous?.Folder ?? (owner is not null && Model.Agents.List().FirstOrDefault(a => a.Id == owner) is { } ownerAgent ? Model.Projects.Get(ownerAgent.ProjectId)?.Folders.FirstOrDefault() : null) ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
    var agentPicker = new ComboBox { Header = "Run as", HorizontalAlignment = HorizontalAlignment.Stretch }; agentPicker.Items.Add(new ComboBoxItem { Content = "Hoot", Tag = "@hoot" });
    foreach (var agent in Model.Agents.List().Where(a => a.Status == SavedAgentStatus.Active)) agentPicker.Items.Add(new ComboBoxItem { Content = agent.Name, Tag = agent.Id });
    agentPicker.SelectedItem = agentPicker.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == (previous?.AgentId ?? owner ?? "@hoot")) ?? agentPicker.Items[0];
    var text = new TextBox { Header = "Instruction", Text = previous?.Text ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120, MaxHeight = 240, MaxLength = 24000 };
    var triggers = new TextBox { Header = "Triggers · one per line", Text = string.Join('\n', previous?.Triggers ?? []), PlaceholderText = "schedule 09:00 weekdays\nsession-idle 15m\nfile-change src/**", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 120 };
    NumberBox Number(string label, double value, double minimum, double maximum) => new() { Header = label, Value = value, Minimum = minimum, Maximum = maximum };
    var minutes = Number("Fallback interval in minutes · when no triggers", previous?.EveryMinutes ?? 60, 1, 525600);
    ComboBox Pick(string label, string[] values, string selected) => new() { Header = label, ItemsSource = values, SelectedItem = selected, HorizontalAlignment = HorizontalAlignment.Stretch };
    var overlap = Pick("If already running", ["queue", "merge", "queue-all", "skip", "cancel"], previous?.Overlap ?? "queue");
    var catchUp = Pick("Missed schedules", ["skip", "once", "replay"], previous?.CatchUp ?? "once");
    var pending = Number("Maximum queued runs", previous?.MaxPending ?? 10, 1, 100); var missed = Number("Maximum catch-up runs", previous?.MaxCatchUp ?? 5, 1, 50);
    var quiet = Number("Quiet period in seconds", previous?.QuietSeconds ?? 30, 0, 86400); var hourly = Number("Maximum runs per hour", previous?.MaxRunsPerHour ?? 6, 1, 1000); var daily = Number("Maximum runs per day", previous?.MaxRunsPerDay ?? 24, 1, 10000);
    var expected = Number("Warn if no run within seconds · 0 turns off", previous?.ExpectEverySeconds ?? 0, 0, 604800);
    var on = new ToggleSwitch { Header = "Enabled", IsOn = previous?.Enabled ?? false }; var status = Words("", 12, true);
    foreach (var element in new UIElement[] { name, purpose, folder, agentPicker, text, triggers, minutes, overlap, catchUp, pending, missed, quiet, hourly, daily, expected, on, status }) form.Children.Add(element);
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = previous is null ? "New routine" : "Edit routine", Content = new ScrollViewer { Content = form, MaxHeight = 560 }, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    dialog.PrimaryButtonClick += (_, e) =>
    {
      try
      {
        var routine = previous ?? new HootRoutine(Guid.NewGuid().ToString(), "", "", folder.Text, 60, "");
        service.Save(routine with { Name = name.Text.Trim(), Purpose = purpose.Text.Trim(), Folder = folder.Text.Trim(), Text = text.Text, Enabled = on.IsOn, EveryMinutes = (int)minutes.Value, AgentId = (string)((ComboBoxItem)agentPicker.SelectedItem).Tag,
          Triggers = triggers.Text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries), Overlap = (string)overlap.SelectedItem, CatchUp = (string)catchUp.SelectedItem, MaxPending = (int)pending.Value, MaxCatchUp = (int)missed.Value, QuietSeconds = (int)quiet.Value, MaxRunsPerHour = (int)hourly.Value, MaxRunsPerDay = (int)daily.Value, ExpectEverySeconds = expected.Value > 0 ? (int)expected.Value : null });
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; e.Cancel = true; }
    };
    await dialog.ShowAsync(); Render();
  }
}
