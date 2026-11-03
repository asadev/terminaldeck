using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

public sealed partial class TaskDetailPage
{
  private readonly List<FrameworkElement> emptyFields = [];
  private Task<bool> SaveAsync(TaskDraft draft) => model.RunAsync(() => { model.Tasks.Update(taskId, draft, TaskActor.Owner, Task.Revision); return System.Threading.Tasks.Task.CompletedTask; }, "Task saved.");
  private Task<bool> DetailAsync(string action, string? key = null, string? value = null) => model.RunAsync(() => { model.Tasks.Detail(taskId, action, key, value, TaskActor.Owner); return System.Threading.Tasks.Task.CompletedTask; }, "Task saved.");
  private async System.Threading.Tasks.Task ChooseGoalAsync()
  {
    var goal = TaskGoalsPage.GoalPicker(model, Task.ProjectId, Task.GoalId);
    if (await Dialog(XamlRoot, "Business decision", goal).ShowAsync() == ContentDialogResult.Primary)
      await SaveAsync(TaskService.Draft(Task) with { GoalId = TasksPage.Empty(Picked(goal)) });
  }
  private Grid Properties(DeckTask task)
  {
    var extras = TaskExtras.Of(task);
    var grid = new Grid { ColumnSpacing = 12, RowSpacing = 8 };
    AutomationProperties.SetAutomationId(grid, "tasks.properties");
    foreach (var width in new[] { new GridLength(132), new GridLength(1.4, GridUnitType.Star), new GridLength(116), new GridLength(0.6, GridUnitType.Star) }) grid.ColumnDefinitions.Add(new() { Width = width });
    for (var i = 0; i < 5; i++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
    void FieldRow(int row, int column, string glyph, string label, FrameworkElement value, bool empty = false, int span = 1, bool grayEmpty = true)
    {
      var name = Stack(8); name.Orientation = Orientation.Horizontal; name.VerticalAlignment = VerticalAlignment.Center;
      name.Children.Add(TaskLayout.Glyph(glyph)); name.Children.Add(TaskLayout.Cell(label, true));
      AutomationProperties.SetAutomationId(name, "tasks.label." + label);
      Grid.SetRow(name, row); Grid.SetColumn(name, column); grid.Children.Add(name);
      Grid.SetRow(value, row); Grid.SetColumn(value, column + 1); Grid.SetColumnSpan(value, span); grid.Children.Add(value);
      value.HorizontalAlignment = HorizontalAlignment.Stretch;
      if (value is ContentControl control) control.HorizontalContentAlignment = HorizontalAlignment.Left;
      if (empty) { if (grayEmpty) value.Opacity = 0.45; emptyFields.Add(name); emptyFields.Add(value); }
    }
    var statusRow = Stack(5); statusRow.Orientation = Orientation.Horizontal;
    var status = TaskLayout.Quiet(task.Status.ToUpperInvariant(), () => { });
    status.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White); status.FontSize = 11; status.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    var tone = task.Status switch { "Working on it" => "DeckProjectOrangeBrush", "Done" => "SystemFillColorSuccessBrush", "Stuck" => "SystemFillColorCriticalBrush", "To-Do" => "TextFillColorSecondaryBrush", "In Progress" => "DeckProjectPurpleBrush", _ => "AccentFillColorDefaultBrush" };
    status.SetResourceReference(Control.BackgroundProperty, tone); status.CornerRadius = new CornerRadius(5, 0, 0, 5);
    var menu = new MenuFlyout();
    foreach (var state in TaskStatuses.All) { var item = new MenuFlyoutItem { Text = state }; item.Click += async (_, _) => await SetStatusAsync(state); menu.Items.Add(item); }
    status.Flyout = menu;
    statusRow.Spacing = 0; statusRow.Children.Add(status);
    if (TaskStatuses.Next(task.Status) is { } nextStatus)
    {
      var next = TaskLayout.Icon("\uE76C", "Next status: " + nextStatus, async () => await SetStatusAsync(nextStatus));
      next.Width = 20; next.MinWidth = 20; next.Padding = new Thickness(0); next.Opacity = 0.85;
      next.SetResourceReference(Control.BackgroundProperty, tone); next.Foreground = status.Foreground; next.CornerRadius = new CornerRadius(0, 5, 5, 0); statusRow.Children.Add(next);
    }
    else status.CornerRadius = new CornerRadius(5);
    if (task.Status != "Done")
    {
      var done = TaskLayout.Icon("\uE73E", "Mark complete", async () => await SetStatusAsync("Done")); done.Margin = new Thickness(6, 0, 0, 0); done.BorderThickness = new Thickness(1); done.CornerRadius = new CornerRadius(5); done.SetResourceReference(Control.BorderBrushProperty, "CardStrokeColorDefaultBrush"); statusRow.Children.Add(done);
    }
    FieldRow(0, 0, "\uEA3A", "Status", statusRow);
    var shared = SharedPeople(task);
    var who = new Grid { ColumnSpacing = 6 };
    who.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); who.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    var faces = new Grid { Width = shared.Length == 0 ? 0 : shared.Length == 1 ? 20 : 34, Height = 20, VerticalAlignment = VerticalAlignment.Center };
    for (var i = 0; i < Math.Min(2, shared.Length); i++)
    {
      var face = TaskAvatar(shared[i]); face.HorizontalAlignment = HorizontalAlignment.Left; face.Margin = new Thickness(i * 14, 0, 0, 0); faces.Children.Add(face);
    }
    who.Children.Add(faces);
    var names = shared.Select(id => id == "me" ? "You" : model.People().FirstOrDefault(p => p.Id == id)?.Name ?? id).ToArray();
    var summary = TaskLayout.Cell(shared.Length == 0 ? "Empty" : shared.Length > 2 ? "+" + (shared.Length - 2) : string.Join(", ", names), shared.Length == 0);
    summary.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(summary, 1); who.Children.Add(summary);
    var assignee = TaskLayout.Quiet("", () => { }); assignee.Content = who; assignee.Flyout = ShareFlyout();
    assignee.HorizontalContentAlignment = HorizontalAlignment.Stretch;
    AutomationProperties.SetAutomationId(assignee, "tasks.assignees"); AutomationProperties.SetName(assignee, "Assignees: " + (names.Length == 0 ? "Empty" : string.Join(", ", names)));
    ToolTipService.SetToolTip(assignee, names.Length == 0 ? "Empty" : string.Join(", ", names)); FieldRow(0, 2, "\uE77B", "Assignees", assignee);
    assignee.HorizontalContentAlignment = HorizontalAlignment.Stretch;
    var folder = new Grid(); folder.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); folder.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var path = TaskLayout.Cell(task.Folder.Length == 0 ? "Empty" : task.Folder, task.Folder.Length == 0); path.VerticalAlignment = VerticalAlignment.Center; folder.Children.Add(path);
    var choose = TaskLayout.Quiet("Choose…", async () => { var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId); if (await PickFolderAsync(hwnd) is { } selected) await SaveAsync(TaskService.Draft(Task) with { Folder = selected }); });
    choose.FontSize = 11; Grid.SetColumn(choose, 1); folder.Children.Add(choose); FieldRow(1, 0, "\uE8B7", "Project folder", folder, span: 3);
    var own = new CheckBox { Content = "Own workspace", IsChecked = extras.OwnWorkspace, FontSize = 11, MinHeight = 28, CornerRadius = new CornerRadius(4) };
    own.Click += async (_, _) => await DetailAsync("workspace", value: own.IsChecked == true ? "true" : "false"); FieldRow(2, 0, "branch", "Workspace", own, span: 3);
    var dates = TaskLayout.Quiet("▦ " + TaskDates.Label(task.StartDate, task.StartTime, "Start") + "  →  ▦ " + TaskDates.Label(task.DueDate, task.DueTime, "Due"), () => { });
    dates.Flyout = DatesFlyout(); AutomationProperties.SetAutomationId(dates, "tasks.dates");
    var dateLabel = Stack(6); dateLabel.Orientation = Orientation.Horizontal;
    foreach (var part in new[] { TaskDates.Label(task.StartDate, task.StartTime, "Start"), TaskDates.Label(task.DueDate, task.DueTime, "Due") }) { if (dateLabel.Children.Count > 0) dateLabel.Children.Add(TaskLayout.Cell("→", true)); dateLabel.Children.Add(new DeckIcon { Glyph = "\uE787", FontSize = 10, Opacity = 0.5 }); dateLabel.Children.Add(TaskLayout.Cell(part, true)); }
    dates.Content = dateLabel;
    dates.SetResourceReference(Control.BackgroundProperty, "SubtleFillColorSecondaryBrush"); dates.FontSize = 12; FieldRow(3, 0, "\uE787", "Dates", dates, task.StartDate is null && task.DueDate is null, grayEmpty: false);
    var priority = TaskLayout.Quiet(task.Priority ?? "Empty", () => { }); priority.Flyout = PriorityFlyout(); AutomationProperties.SetAutomationId(priority, "tasks.priority");
    FieldRow(3, 2, "\uE7C1", "Priority", priority, task.Priority is null);
    var seconds = extras.TrackedSeconds + (extras.TimerStarted is { } start ? Math.Max(0, (DateTimeOffset.UtcNow - start).TotalSeconds) : 0);
    var timer = TaskLayout.Quiet((extras.TimerStarted is null ? "▷ Start" : "Ⅱ Stop") + (seconds > 0 ? " · " + TimeSpan.FromSeconds(seconds).ToString(@"hh\:mm\:ss") : ""), async () => await DetailAsync("timer"));
    timer.Opacity = extras.TimerStarted is null ? 0.65 : 1;
    FieldRow(4, 0, "\uE916", "Track time", timer, extras.TimerStarted is null && seconds == 0, grayEmpty: false);
    var tags = TaskLayout.Quiet("Empty", () => { }); tags.Flyout = TagsFlyout(); AutomationProperties.SetAutomationId(tags, "tasks.tags");
    if (!task.Labels.IsEmpty) tags.Content = TagSummary(task);
    ToolTipService.SetToolTip(tags, task.Labels.IsEmpty ? "Empty" : string.Join(", ", task.Labels));
    FieldRow(4, 2, "\uE8EC", "Tags", tags, task.Labels.IsEmpty); tags.HorizontalContentAlignment = HorizontalAlignment.Stretch;
    grid.SizeChanged += (_, _) => { grid.ColumnDefinitions[1].Width = new GridLength(grid.ActualWidth < 700 ? 1.4 : 1, GridUnitType.Star); grid.ColumnDefinitions[3].Width = new GridLength(grid.ActualWidth < 700 ? 0.6 : 1, GridUnitType.Star); grid.ColumnDefinitions[0].Width = new GridLength(grid.ActualWidth < 700 ? 120 : 144); grid.ColumnDefinitions[2].Width = new GridLength(grid.ActualWidth < 700 ? 96 : 144); };
    return grid;
  }
  private Task<bool> SetStatusAsync(string value) => model.RunAsync(() => { model.Tasks.Status(taskId, value, TaskActor.Owner); return System.Threading.Tasks.Task.CompletedTask; }, "Status saved.");
  private StackPanel DetailSections(DeckTask task)
  {
    var extra = TaskExtras.Of(task); var body = Stack(12);
    body.Children.Add(Words("Fields", 13, true));
    foreach (var field in extra.Fields)
    {
      var edit = new TextBox { Header = field.Name, Text = field.Value, MaxLength = 4000 };
      edit.LostFocus += async (_, _) => { if (edit.Text != field.Value) await DetailAsync("field-value", field.Id, edit.Text); }; body.Children.Add(edit);
    }
    var create = TaskLayout.Quiet("+  Create new field", async () => await AddTextAsync("Create new field", "Field name", "field"));
    create.CornerRadius = new CornerRadius(14); create.FontSize = 11; create.HorizontalAlignment = HorizontalAlignment.Left; create.SetResourceReference(Control.BackgroundProperty, "SubtleFillColorSecondaryBrush"); body.Children.Add(create);
    foreach (var item in extra.Checklist)
    {
      var check = new CheckBox { Content = item.Name, IsChecked = item.Done }; check.Click += async (_, _) => await DetailAsync("check", item.Id); body.Children.Add(check);
    }
    foreach (var link in extra.Relations)
    {
      var related = model.Tasks.List(new(Status: "all")).FirstOrDefault(t => t.Id == link.Value);
      if (related is not null) body.Children.Add(TaskLayout.Quiet(link.Name + " · " + related.Title, () => model.Select(related.Id)));
    }
    foreach (var file in extra.Attachments)
      body.Children.Add(TaskLayout.Quiet("▧ " + file.Name, async () => { if (await Windows.Storage.StorageFile.GetFileFromPathAsync(file.Value) is { } saved) await Windows.System.Launcher.LaunchFileAsync(saved); }));
    foreach (var entry in new (string Glyph, string Label, Func<System.Threading.Tasks.Task> Run)[] {
      ("branch", "Add subtask", SubtaskAsync), ("\uE71B", "Relate items or add dependencies", RelateAsync),
      ("\uE9D5", "Create checklist", () => AddTextAsync("Create checklist", "First checklist item", "checklist")), ("\uE723", "Attach file", AttachAsync) })
    {
      var row = Stack(10); row.Orientation = Orientation.Horizontal; row.Children.Add(TaskLayout.Glyph(entry.Glyph)); row.Children.Add(Words(entry.Label, 13, true));
      var button = TaskLayout.Quiet("", async () => await entry.Run()); button.Content = row; button.HorizontalAlignment = HorizontalAlignment.Left; body.Children.Add(button);
    }
    return body;
  }
  private async System.Threading.Tasks.Task AddTextAsync(string title, string label, string action)
  {
    var text = Field(label, "", max: 4000);
    if (await Dialog(XamlRoot, title, text, "Create").ShowAsync() == ContentDialogResult.Primary) await DetailAsync(action, value: text.Text);
  }
  private async System.Threading.Tasks.Task SubtaskAsync()
  {
    var title = Field("Task name", "", max: 240);
    if (await Dialog(XamlRoot, "Add subtask", title, "Create").ShowAsync() != ContentDialogResult.Primary) return;
    await model.RunAsync(() => { var child = model.Tasks.Create(new TaskDraft(title.Text, ProjectId: Task.ProjectId, Folder: Task.Folder), TaskActor.Owner); model.Tasks.Detail(taskId, "relate", "Subtask", child.Id, TaskActor.Owner); return System.Threading.Tasks.Task.CompletedTask; }, "Subtask created.");
  }
  private async System.Threading.Tasks.Task RelateAsync()
  {
    var choices = model.Tasks.List(new(Status: "all")).Where(t => t.Id != taskId && t.ProjectId == Task.ProjectId).Select(t => (t.Id, t.Title)).ToArray();
    if (choices.Length == 0) { model.Notice("Create another task in this project first."); return; }
    var other = Choice("Task", choices, choices[0].Id);
    var kind = Choice("Relationship", new[] { ("Related", "Related"), ("Blocks", "Blocks"), ("Blocked by", "Blocked by") }, "Related");
    var form = Stack(); form.Children.Add(other); form.Children.Add(kind);
    if (await Dialog(XamlRoot, "Relate items or add dependencies", form, "Relate").ShowAsync() == ContentDialogResult.Primary) await DetailAsync("relate", Picked(kind), Picked(other));
  }
  private async System.Threading.Tasks.Task AttachAsync()
  {
    var picker = new Windows.Storage.Pickers.FileOpenPicker(); picker.FileTypeFilter.Add("*");
    WinRT.Interop.InitializeWithWindow.Initialize(picker, Microsoft.UI.Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId));
    if (await picker.PickSingleFileAsync() is { } file) await DetailAsync("attach", value: file.Path);
  }
  private Grid ActivityLine(TaskActivity entry)
  {
    var line = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 8, 0, 0) };
    line.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    line.Children.Add(Words("•  " + entry.By.Name + " " + entry.Text, 12, true));
    var time = Words(entry.At.ToLocalTime().ToString("MMM d 'at' h:mm tt"), 10, true); time.Opacity = 0.45; Grid.SetColumn(time, 1); line.Children.Add(time); return line;
  }
  private static UIElement PersonPicture(TaskRecipient person)
  {
    var row = new SessionDraft(person.Name, "codex", "", SessionPresentation.Chat);
    row.SetAppearance("Independent", null, person.Name, TerminalDeck.Core.Projects.ProjectIdentity.IndependentId, person.Icon, person.Kind == "hoot");
    return new SessionPicture { Session = row, Width = 20, Height = 20 };
  }
  private Border CommentCard(TaskComment comment)
  {
    var body = Stack(16); body.Margin = new Thickness(16, 12, 16, 16);
    var author = Stack(8); author.Orientation = Orientation.Horizontal;
    if (model.People().FirstOrDefault(p => p.Id == comment.Author.Id) is { } person) author.Children.Add(PersonPicture(person));
    else if (comment.Author.Id is "codex" or "claude" or "gemini") author.Children.Add(new BrandIcon { Kind = comment.Author.Id, Width = 20, Height = 20 });
    else author.Children.Add(new DeckIcon { Glyph = comment.Author.Kind == "agent" ? "\uE9D9" : "\uE77B", FontSize = 16, Opacity = 0.7 });
    author.Children.Add(Heading(comment.Author.Name, 12));
    if (comment.Author.Kind == "agent") { var tag = new Border { Child = Words("agent", 10, true), Padding = new Thickness(4, 0, 4, 0), CornerRadius = new CornerRadius(2) }; tag.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush"); author.Children.Add(tag); }
    author.Children.Add(Words(comment.At.ToLocalTime().ToString("MMM d 'at' h:mm tt"), 10, true)); body.Children.Add(author);
    body.Children.Add(Words(model.CommentText(comment.Text), 13));
    var footer = new Grid { Padding = new Thickness(8, 0, 8, 0), BorderThickness = new Thickness(0, 1, 0, 0) };
    footer.SetResourceReference(Grid.BorderBrushProperty, "CardStrokeColorDefaultBrush"); footer.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var like = TaskLayout.Icon("\uE76E", "React to comment", async () => await DetailAsync("like", comment.Id));
    if (TaskExtras.Of(Task).LikedComments.Contains("me:" + comment.Id)) like.Content = "☺ 1";
    like.HorizontalAlignment = HorizontalAlignment.Left; footer.Children.Add(like);
    var reply = TaskLayout.Quiet("↶  Reply", () => { model.ReplyTo = comment.Id; model.PresentationChanged(); }); Grid.SetColumn(reply, 1); footer.Children.Add(reply);
    var layout = new StackPanel(); layout.Children.Add(body); layout.Children.Add(footer);
    var card = TaskLayout.Surface(layout); card.Padding = new Thickness(0); card.BorderThickness = new Thickness(1); card.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
    return card;
  }
}
