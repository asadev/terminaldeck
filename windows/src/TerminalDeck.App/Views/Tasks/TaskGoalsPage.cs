using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels.Tasks;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

internal sealed class TaskGoalsPage : StackPanel
{
  public TaskGoalsPage(TasksViewModel model, FrameworkElement owner, Action work, Action<DeckGoal> showTasks, Func<DeckGoal, Task> addTask)
  {
    Spacing = 28; Margin = new Thickness(24, 20, 24, 32);
    var sections = TaskLayout.Sections("Goals", section => { if (section == "Work") work(); }); sections.HorizontalAlignment = HorizontalAlignment.Left; Children.Add(sections);
    Children.Add(Header("Goals", "Give related work a clear outcome.", AsyncButton("Add goal", () => EditAsync(owner, model), true)));
    var goals = model.Tasks.Goals(model.ProjectScope).Where(g => model.Filter.ProjectIds.IsDefaultOrEmpty || model.Filter.ProjectIds.Contains(g.ProjectId)).ToArray(); var tasks = model.Tasks.List(new(Status: "all")); var seen = new HashSet<string>();
    void Add(DeckGoal goal, int depth)
    {
      if (!seen.Add(goal.Id)) return;
      var body = Stack(8); body.Children.Add(Heading(goal.Title, 18));
      body.Children.Add(Words(goal.Status[..1].ToUpperInvariant() + goal.Status[1..] + " · " + (model.Projects.List().FirstOrDefault(p => p.Id == goal.ProjectId)?.Name ?? "Removed project"), 12, true));
      if (goal.Description.Length > 0) body.Children.Add(Words(goal.Description));
      var goalIds = TaskGoalTree.Descendants(goals, goal.Id);
      var rows = tasks.Where(t => t.GoalId is { } id && goalIds.Contains(id)).ToArray(); var done = rows.Count(t => t.Status == "Done");
      body.Children.Add(Button(rows.Length == 0 ? "No tasks yet" : $"{done} of {rows.Length} done", () => showTasks(goal)));
      var actions = Stack(8); actions.Orientation = Orientation.Horizontal;
      actions.Children.Add(AsyncButton("Add task", () => addTask(goal))); actions.Children.Add(AsyncButton("Edit", () => EditAsync(owner, model, goal)));
      actions.Children.Add(AsyncButton("Add subgoal", () => EditAsync(owner, model, parent: goal)));
      actions.Children.Add(AsyncButton("Remove…", async () =>
      {
        if (!await ConfirmAsync(owner.XamlRoot, "Remove this goal?", "Its tasks and subgoals move to its parent goal. Their work stays.", "Remove goal")) return;
        await model.RunAsync(() => { model.Tasks.DeleteGoal(goal.Id, TaskActor.Owner); return Task.CompletedTask; }, "Goal removed. Tasks and subgoals were kept.");
      })); body.Children.Add(actions);
      var card = Card(body); card.Margin = new Thickness(Math.Min(depth, 6) * 16, 0, 0, 0); Children.Add(card);
      foreach (var child in goals.Where(g => g.ParentId == goal.Id)) Add(child, depth + 1);
    }
    foreach (var goal in goals.Where(g => g.ParentId is null || !goals.Any(p => p.Id == g.ParentId))) Add(goal, 0);
    if (goals.Length == 0) Children.Add(Words("No goals yet. Add an outcome, then give it tasks.", muted: true));
    if (model.Busy) Children.Add(new ProgressBar { IsIndeterminate = true });
    if (model.Message.Length > 0) Children.Add(new TerminalDeck.App.Views.Notices.CompactNotice { IsOpen = true, IsClosable = false, Severity = model.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = model.Message });
  }
  public static ComboBox GoalPicker(TasksViewModel model, string projectId, string? selected)
  {
    var picker = Choice("Goal", [], ""); FillGoals(picker, model, projectId, selected); return picker;
  }
  public static void FillGoals(ComboBox picker, TasksViewModel model, string projectId, string? selected)
  {
    picker.Items.Clear(); picker.Items.Add(new ChoiceRow("", "No goal"));
    foreach (var goal in model.Tasks.Goals(projectId)) picker.Items.Add(new ChoiceRow(goal.Id, goal.Title));
    picker.SelectedValue = selected ?? ""; if (picker.SelectedIndex < 0) picker.SelectedIndex = 0;
  }
  private static async Task EditAsync(FrameworkElement owner, TasksViewModel model, DeckGoal? goal = null, DeckGoal? parent = null)
  {
    var title = Field("Title", goal?.Title ?? "", max: 240); var description = Field("Description", goal?.Description ?? "", true, 40000);
    var project = Choice("Project", model.Projects.List().Select(p => (p.Id, p.Name)), goal?.ProjectId ?? parent?.ProjectId ?? model.ProjectScope);
    var status = Choice("Status", new[] { ("planned", "Planned"), ("active", "Active"), ("achieved", "Achieved"), ("cancelled", "Cancelled") }, goal?.Status ?? "active");
    var parentPicker = Choice("Parent goal", [], "");
    void Parents()
    {
      var all = model.Tasks.Goals(Picked(project));
      bool Available(DeckGoal candidate)
      {
        var seen = new HashSet<string>(); var current = candidate;
        while (true)
        {
          if (current.Id == goal?.Id || !seen.Add(current.Id)) return false;
          if (current.ParentId is not { } id || all.FirstOrDefault(g => g.Id == id) is not { } next) return true;
          current = next;
        }
      }
      parentPicker.Items.Clear(); parentPicker.Items.Add(new ChoiceRow("", "No parent goal"));
      foreach (var candidate in all.Where(Available)) parentPicker.Items.Add(new ChoiceRow(candidate.Id, candidate.Title));
      parentPicker.SelectedValue = goal?.ParentId ?? parent?.Id ?? ""; if (parentPicker.SelectedIndex < 0) parentPicker.SelectedIndex = 0;
    }
    project.SelectionChanged += (_, _) => Parents(); Parents();
    var body = Stack(); foreach (var field in new UIElement[] { title, description, project, status, parentPicker }) body.Children.Add(field);
    var error = new TerminalDeck.App.Views.Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error }; body.Children.Add(error);
    var dialog = Dialog(owner.XamlRoot, goal is null ? "Add goal" : "Edit goal", body, goal is null ? "Add goal" : "Save");
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral();
      try
      {
        e.Cancel = !await model.RunAsync(() => { model.Tasks.SaveGoal(new(title.Text, description.Text, Picked(project), Picked(status), TasksPage.Empty(Picked(parentPicker))), TaskActor.Owner, goal?.Id, goal?.Revision); return Task.CompletedTask; }, "Goal saved.");
        error.Message = model.Message; error.IsOpen = e.Cancel;
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }
}
