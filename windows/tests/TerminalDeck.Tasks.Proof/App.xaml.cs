using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using TerminalDeck.App.ViewModels.Tasks;
using TerminalDeck.App.Views.Tasks;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Tasks.Proof;

public partial class App : Application
{
  private Window? window;
  private static FrameworkElement? visualRoot;
  public App() => InitializeComponent();
  protected override void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith(@"C:\TD\tasks-proof\", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Choose an isolated task proof root.");
    Directory.CreateDirectory(root.DirectoryPath);
    var host = new Grid { RequestedTheme = ElementTheme.Light, Style = TerminalDeck.App.Views.Projects.ProjectAgentUi.PageStyle() };
    host.RowDefinitions.Add(new() { Height = GridLength.Auto }); host.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    host.Children.Add(new TextBlock { Text = "TASKS · SAMPLE DATA", Margin = new Thickness(28, 12, 28, 0), Opacity = 0.65 });
    var content = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    Grid.SetRow(content, 1); host.Children.Add(content);
    visualRoot = host;
    window = new Window { Title = "Tasks · isolated Windows preview", Content = host };
    if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
    { window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(-20000, -20000, 1100, 760)); window.AppWindow.Show(false); }
    else { window.Activate(); window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(40, 20, 1100, 760)); }
    UnhandledException += (_, e) =>
    {
      e.Handled = true;
      File.WriteAllText(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { passed = 0, failed = 1, errorType = e.Exception.GetType().Name, error = e.Exception.Message,
        stack = new System.Diagnostics.StackTrace(e.Exception, true).GetFrames().Where(f => f.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck", StringComparison.Ordinal) == true).Select(f => new { method = f.GetMethod()?.Name, line = f.GetFileLineNumber() }) }));
    };
    host.DispatcherQueue.TryEnqueue(async () => await RunAsync(root, host, content));
  }
  private async Task RunAsync(AppDataRoot root, Grid host, ContentControl content)
  {
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool condition) => (condition ? passed : failed).Add(name);
    try
    {
      var data = AppDataRoot.Explicit(Path.Combine(root.DirectoryPath, "app-data"));
      var folder = Path.Combine(root.DirectoryPath, "fixtures", "Aurora"); Directory.CreateDirectory(folder);
      var projects = new ProjectService(new JsonStateStore<ProjectState>(data, "projects"), new LocalProjectFolders(data));
      projects.Save(new("aurora", "Aurora", [folder]));
      var runner = new ExampleRunner();
      var people = new[] { new TaskRecipient("reviewer", "Release reviewer", "agent", "preview-session") };
      var tasks = new TaskService(TaskStore.At(data), projects, id => people.FirstOrDefault(p => p.Id == id), runner, new TaskBriefFiles(data));
      var main = tasks.Create(new("Review the Windows task page", "Check the list, filters and comments in both appearances. Keep the result here so everyone can follow the work.", "aurora", Priority: "High", DueDate: DateTime.Today.ToString("yyyy-MM-dd"), Labels: ["windows", "review"]), TaskActor.Owner);
      var stuck = tasks.Create(new("Choose the next release date", "The owner needs to choose a date before this can continue.", "aurora", Status: "Stuck"), TaskActor.Owner);
      tasks.Create(new("Write the task brief", "A short brief keeps the job clear.", "aurora", Status: "Done"), TaskActor.Owner);
      await tasks.CommentAsync(main.Id, "Please keep questions, progress and the result in this task.", new("reviewer", "Reviewer", "agent"));
      using var model = new TasksViewModel(tasks, projects, "preview-pc", () => people);
      var nav = new Navigation(); var page = new TasksPage(model, nav); content.Content = page;
      await Task.Delay(300);
      if (Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
      {
        await W12Async(root, host, page, model, tasks, Check);
        await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
        window!.Close(); return;
      }
      if (Environment.GetEnvironmentVariable("TD_TASKS_PROOF_RESUME") == "visual")
      {
        await tasks.CommentAsync(main.Id, "Ready for @[reviewer] to check.", TaskActor.Owner);
        await tasks.AssignAsync(main.Id, "reviewer", TaskActor.Owner);
        await Snapshot(root, "01-tasks-light");
        page.OpenTask(main.Id); await Task.Delay(150); await Snapshot(root, "02-task-detail-light");
        var detailScroll = Tree(page).OfType<ScrollViewer>().First(); detailScroll.ChangeView(null, detailScroll.ScrollableHeight, null, true);
        await Snapshot(root, "03-task-comments-light");
        host.RequestedTheme = ElementTheme.Dark; await Snapshot(root, "04-task-comments-dark");
        detailScroll.ChangeView(null, 0, null, true); await Snapshot(root, "05-task-detail-dark");
        model.Select(null); await Task.Delay(150); await Snapshot(root, "06-tasks-dark");
        window!.AppWindow.Resize(new Windows.Graphics.SizeInt32(820, 760)); await Snapshot(root, "07-tasks-narrow-dark");
        await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, mode = "visual", passed = 0, failed = 0, assertionsRepeated = false, screenshots = 7 }));
        return;
      }
      if (Environment.GetEnvironmentVariable("TD_TASKS_PROOF_RESUME") != "comments")
      {
      Check("Open tasks list shows two rows", Tree(page).OfType<Button>().Count(b => AutomationProperties.GetAutomationId(b).StartsWith("tasks.row.", StringComparison.Ordinal)) == 2);
      await Snapshot(root, "01-tasks-light");
      var filter = Tree(page).OfType<ComboBox>().Single(c => c.Header?.ToString() == "Status"); filter.SelectedValue = "needs-you"; await Task.Delay(180);
      Check("Status filter shows only the task that needs you", model.Rows.Count == 1 && model.Rows[0].Id == stuck.Id);
      var search = Tree(page).OfType<AutoSuggestBox>().Single(); search.Text = "release"; await Task.Delay(180);
      Check("Search keeps its edit control mounted", ReferenceEquals(search, Tree(page).OfType<AutoSuggestBox>().Single()) && model.Filter.Search == "release");
      }
      if (Environment.GetEnvironmentVariable("TD_TASKS_PROOF_RESUME") == "comments") await Snapshot(root, "01-tasks-light");
      model.Filters(new()); await Task.Delay(150); page.OpenTask(main.Id); await Task.Delay(150);
      var comment = Tree(page).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "tasks.comment"); comment.Text = "Ready for @[reviewer] to check.";
      await Until(() => model.CommentDraft == "Ready for @[reviewer] to check.");
      Invoke(Tree(page).OfType<Button>().Single(b => b.Content?.ToString() == "Post comment")); await Until(() => !model.Busy && tasks.Get(main.Id).Comments.Length == 2);
      Check("Post comment uses the task store and notifies its mention", tasks.Get(main.Id).Comments.Last().Author.Id == "me" && runner.Notifications == 1);
      Invoke(Tree(page).OfType<Button>().Single(b => b.Content?.ToString() == "Assign / Start")); await Task.Delay(180);
      var popups = VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).SelectMany(p => Tree(p.Child)).ToArray();
      popups.OfType<ComboBox>().Single(c => c.Header?.ToString() == "Assign to").SelectedValue = "reviewer";
      Invoke(popups.OfType<Button>().Single(b => b.Name == "PrimaryButton")); await Until(() => !model.Busy && runner.Starts == 1);
      Check("Assign control starts one task chat through the runner interface", runner.Starts == 1 && runner.Mode == "chat" && tasks.Get(main.Id).Assignee == "reviewer");
      await Snapshot(root, "02-task-detail-light");
      Invoke(Tree(page).OfType<Button>().Single(b => b.Content?.ToString() == "Open session"));
      Check("Task session button opens its real recorded session id", nav.Opened == "preview-session");
      host.RequestedTheme = ElementTheme.Dark; await Snapshot(root, "03-task-detail-dark");
      model.Select(null); await Task.Delay(150); await Snapshot(root, "04-tasks-dark");
      window!.AppWindow.Resize(new Windows.Graphics.SizeInt32(820, 760)); await Task.Delay(150);
      var scroll = Tree(page).OfType<ScrollViewer>().First(); var body = (StackPanel)scroll.Content;
      Check("Task list fits the narrower window", body.ActualWidth + body.Margin.Left + body.Margin.Right <= scroll.ActualWidth + 1);
      await Snapshot(root, "05-tasks-narrow-dark");
      Check("Filters were remembered for this computer", new TaskService(TaskStore.At(data), projects, _ => null).Filter("preview-pc").Status == "open");
      Check("Both themes use the actual shared page resources", host.ActualTheme == ElementTheme.Dark && Current.Resources.ContainsKey("SurfaceCardStyle"));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      failed.Add("Proof stopped: " + ex.GetType().Name + " " + ex.Message);
      await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "failure.json"), JsonSerializer.Serialize(new { type = ex.GetType().Name,
        frames = new System.Diagnostics.StackTrace(ex, true).GetFrames().Where(f => f.GetMethod()?.DeclaringType?.Namespace?.StartsWith("TerminalDeck", StringComparison.Ordinal) == true).Select(f => new { method = f.GetMethod()?.Name, line = f.GetFileLineNumber() }) }));
    }
    await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed = passed.Count, failed = failed.Count, checksPassed = passed, checksFailed = failed }));
  }
  private static void Click(DependencyObject root, string name)
  {
    var button = Tree(root).OfType<Microsoft.UI.Xaml.Controls.Primitives.ButtonBase>().Single(b => b.Content as string == name || AutomationProperties.GetName(b) == name || b.Name == name);
    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button);
    if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
    else if (peer?.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
    else throw new InvalidOperationException("No action for " + name);
  }
  private static ContentDialog Dialog(Grid host) => VisualTreeHelper.GetOpenPopupsForXamlRoot(host.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().Single();
  private async Task W12Async(AppDataRoot root, Grid host, TasksPage page, TasksViewModel model, ITasks tasks, Action<string, bool> check)
  {
    await Snapshot(root, "w12-list-light");
    await Snapshot(root, "w12-task-row-detail-light", Tree(page).OfType<Grid>().First(g => g.ContextFlyout is MenuFlyout));
    var search = Tree(page).OfType<AutoSuggestBox>().Single(); search.Focus(FocusState.Programmatic); search.Text = "release"; await Until(() => model.Filter.Search == "release");
    await Snapshot(root, "w12-search-light");
    var nativeClear = Tree(search).OfType<Button>().FirstOrDefault(b => b.Name == "DeleteButton");
    check("Search has a real native clear action", nativeClear is not null);
    if (nativeClear is not null) { Invoke(nativeClear); await Until(() => model.Filter.Search.Length == 0); }
    else { search.Text = ""; await Until(() => model.Filter.Search.Length == 0); }
    check("Typing search keeps its input mounted", ReferenceEquals(search, Tree(page).OfType<AutoSuggestBox>().Single()));
    var filters = Tree(page).OfType<Button>().Single(b => b.Content as string == "Filter"); ((Flyout)filters.Flyout).ShowAt(filters); await Task.Delay(200);
    var filterPopup = (FrameworkElement)((Flyout)filters.Flyout).Content;
    foreach (var label in new[] { "Projects: Aurora", "Projects: Independent", "Status: To-Do", "Status: Stuck", "Assignees: Me" })
    {
      var box = Tree(filterPopup).OfType<CheckBox>().Single(c => AutomationProperties.GetName(c) == label); ((IToggleProvider)FrameworkElementAutomationPeer.CreatePeerForElement(box).GetPattern(PatternInterface.Toggle)).Toggle();
    }
    check("Multi-select filters keep their popup and apply every choice", model.Filter.ProjectIds.Length == 2 && model.Filter.Statuses.Length == 2 && model.Filter.Assignees.Length == 1 && model.Rows.Count == 2 && ReferenceEquals(filters, Tree(page).OfType<Button>().Single(b => b.Content as string is { } title && title.StartsWith("Filter", StringComparison.Ordinal))));
    await Snapshot(root, "w12-multi-filters-light", filterPopup); ((Flyout)filters.Flyout).Hide(); model.Filters(new()); await Task.Delay(200);
    model.Filters(model.Filter with { View = "Board" }); await Task.Delay(200); check("Board cards and columns expose drag interactions", Tree(page).OfType<Button>().Any(b => b.CanDrag) && Tree(page).OfType<Border>().Count(b => b.AllowDrop) >= 5); await Snapshot(root, "w12-board-light");
    model.Filters(model.Filter with { View = "Calendar" }); await Task.Delay(200); check("Calendar days expose date drop targets", Tree(page).OfType<Border>().Count(b => b.AllowDrop) >= 7);
    Invoke(Tree(page).OfType<Button>().First(b => b.Content as string == "+ Add Task")); await Task.Delay(200); var dayDialog = Dialog(host);
    var monday = DateOnly.FromDateTime(DateTime.Today).AddDays(-((7 + (int)DateTime.Today.DayOfWeek - 1) % 7));
    check("Add on a calendar day inherits that date", Tree(dayDialog).OfType<TextBox>().Single(t => t.Header as string == "Due date (YYYY-MM-DD)").Text == monday.ToString("yyyy-MM-dd"));
    var dateButton = Tree(dayDialog).OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Choose due date"); ((Flyout)dateButton.Flyout).ShowAt(dateButton); await Task.Delay(200);
    var datePopup = (FrameworkElement)((Flyout)dateButton.Flyout).Content; Click(datePopup, "Today");
    var addTime = Tree(datePopup).OfType<CheckBox>().Single(c => c.Content as string == "Add time"); ((IToggleProvider)FrameworkElementAutomationPeer.CreatePeerForElement(addTime).GetPattern(PatternInterface.Toggle)).Toggle();
    Tree(datePopup).OfType<TimePicker>().Single().Time = new TimeSpan(14, 45, 0); await Task.Delay(200);
    check("Calendar supports Today and optional time", Tree(dayDialog).OfType<TextBox>().Any(t => t.Header as string == "Due date (YYYY-MM-DD)" && t.Text == DateTime.Today.ToString("yyyy-MM-dd")) && Tree(dayDialog).OfType<TextBox>().Any(t => t.Header as string == "Time (HH:mm) · optional" && t.Text == "14:45"));
    await Snapshot(root, "w12-calendar-time-detail-light", datePopup); Click(datePopup, "Clear");
    check("Clear removes the date and its optional time", Tree(dayDialog).OfType<TextBox>().Single(t => t.Header as string == "Due date (YYYY-MM-DD)").Text.Length == 0);
    ((Flyout)dateButton.Flyout).Hide(); await Snapshot(root, "w12-calendar-create-light", dayDialog); Click(dayDialog, "Cancel"); model.Filters(new()); await Task.Delay(200);


    foreach (var grouping in new[] { "single", "status", "assignee", "priority", "tags", "date", "type", "board", "project" })
    {
      model.Filters(model.Filter with { GroupBy = grouping }); await Task.Delay(300);
      if (grouping == "tags")
      {
        await Snapshot(root, "w12-tags-light");
        await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "tags-diagnostics.json"), JsonSerializer.Serialize(new { groups = model.Groups(model.Rows).Select(g => new { g.Key, rows = g.Rows.Select(t => t.Title) }), text = Tree(page).OfType<TextBlock>().Select(t => t.Text).Take(100) }));
      }
      check("Grouping renders: " + grouping, Tree(page).OfType<TextBlock>().Any(t => t.Text == "Review the Windows task page"));
    }
    model.Filters(new(GroupBy: "status", Sort: "name", Columns: ["due", "created", "assignee"], ColumnOrder: ["created", "due", "assignee", "priority", "status", "project"])); await Task.Delay(200);
    var savedView = tasks.SaveView(model.Machine, null, "Review view", model.Filter); model.SelectView(savedView.Id); await Task.Delay(200);
    model.Descending = true; await Task.Delay(200);
    check("Saved view exposes Update and Revert after a change", Tree(page).OfType<Button>().Any(b => b.Content as string == "Update") && Tree(page).OfType<Button>().Any(b => b.Content as string == "Revert"));
    await Snapshot(root, "w12-saved-view-light"); Click(page, "Revert"); await Task.Delay(200); check("Revert restores sorting", !model.Filter.Descending);
    model.SelectedViewId = null; model.Filters(new()); await Task.Delay(200);

    Click(page, "New task"); await Task.Delay(200); var dialog = Dialog(host);
    var title = Tree(dialog).OfType<TextBox>().Single(t => t.Header as string == "Title");
    Click(dialog, "PrimaryButton"); await Task.Delay(200);
    check("Invalid task keeps the editor and draft", ReferenceEquals(dialog, Dialog(host)) && Tree(dialog).OfType<InfoBar>().Any(b => b.IsOpen));
    title.Text = "Created with an assignee";
    Tree(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Project").SelectedValue = "aurora";
    Tree(dialog).OfType<ComboBox>().Single(c => c.Header as string == "Assigned to").SelectedValue = "reviewer";
    await Snapshot(root, "w12-create-light", dialog);
    Click(dialog, "PrimaryButton"); await Until(() => model.SelectedId is not null && !model.Busy);
    var created = model.Selected!;
    check("Create starts the selected agent with the saved project folder", created.Assignee == "reviewer" && tasks.Runs(created.Id).Count == 1 && ProjectPaths.Equal(created.Folder, model.Projects.Get(created.ProjectId).HomeFolder!));
    await Until(() => Tree(page).OfType<TextBox>().Any(t => AutomationProperties.GetAutomationId(t) == "tasks.comment"));
    var mentionDraft = Tree(page).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "tasks.comment"); mentionDraft.Text = "Please @Release"; mentionDraft.SelectionStart = mentionDraft.Text.Length;
    await Until(() => Tree(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == "Mention Release reviewer"));
    await Snapshot(root, "w12-mention-picker-light"); Click(page, "Mention Release reviewer"); await Until(() => model.CommentDraft == "Please @[reviewer] ");
    check("Mention picker inserts the chosen identity for a name with spaces", model.CommentDraft == "Please @[reviewer] " && tasks.Get(created.Id).Comments.Length == 0);

    model.Select(null); await Task.Delay(200); Click(page, "Select all"); await Task.Delay(200);
    var bulk = Tree(page).OfType<Button>().Single(b => b.Content as string == "Selected task actions");
    ((MenuFlyout)bulk.Flyout).ShowAt(bulk); await Task.Delay(150);
    var done = ((MenuFlyout)bulk.Flyout).Items.OfType<MenuFlyoutItem>().Single(i => i.Text == "Mark done");
    ((IInvokeProvider)FrameworkElementAutomationPeer.CreatePeerForElement(done).GetPattern(PatternInterface.Invoke)).Invoke();
    await Until(() => !model.Busy && model.Message.Contains("could not change", StringComparison.Ordinal)); await Task.Delay(200);
    check("Bulk completion reports partial success and preserves the running task", tasks.Get(created.Id).Status == "Working on it" && tasks.List(new(Status: "Done")).Count == 3 && model.Message.Contains("3 changed; 1", StringComparison.Ordinal));
    await Snapshot(root, "w12-bulk-partial-light");
    model.Select(created.Id); await Task.Delay(200); Click(page, "Rename task"); await Task.Delay(150);
    var rename = Tree(page).OfType<TextBox>().Single(t => t.Header as string == "Task name"); rename.Text = "Renamed without losing the session";
    await Snapshot(root, "w12-rename-light"); Click(page, "Save name"); await Until(() => tasks.Get(created.Id).Title == "Renamed without losing the session");
    check("Inline rename keeps the task session", tasks.Get(created.Id).CurrentRunId == created.CurrentRunId);
    host.RequestedTheme = ElementTheme.Dark; await Snapshot(root, "w12-detail-dark");
    Click(page, "Activity " + (tasks.Get(created.Id).Activity.Length + tasks.Get(created.Id).Comments.Length));
    await Task.Delay(200); var category = Tree(page).OfType<ComboBox>().Single(c => c.Header as string == "Activity filter"); category.SelectedValue = "assignees";
    await Snapshot(root, "w12-activity-filter-dark");
    check("Activity category retains its selection", model.ActivityCategory == "assignees");
    model.Select(null); await Task.Delay(200); window!.AppWindow.Resize(new Windows.Graphics.SizeInt32(820, 760)); await Snapshot(root, "w12-list-narrow-dark");
    check("Task page renders inside the narrow host", page.ActualWidth <= host.ActualWidth + 1);
    window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 760)); await Task.Delay(150);
    Click(page, "Goals view"); await Task.Delay(200); Click(page, "Add goal"); await Task.Delay(200); var goalDialog = Dialog(host);
    Tree(goalDialog).OfType<TextBox>().Single(t => t.Header as string == "Title").Text = "Release outcome";
    Tree(goalDialog).OfType<ComboBox>().Single(c => c.Header as string == "Project").SelectedValue = "aurora";
    Click(goalDialog, "PrimaryButton"); await Until(() => tasks.Goals().Count == 1 && !model.Busy); await Task.Delay(200);
    var goal = tasks.Goals().Single(); Click(page, "Add subgoal"); await Task.Delay(200); goalDialog = Dialog(host);
    Tree(goalDialog).OfType<TextBox>().Single(t => t.Header as string == "Title").Text = "Quality gate"; Click(goalDialog, "PrimaryButton");
    await Until(() => tasks.Goals().Count == 2 && !model.Busy); await Task.Delay(200);
    check("Goal editor creates a real parent and subgoal", tasks.Goals().Single(g => g.Title == "Quality gate").ParentId == goal.Id);
    await Snapshot(root, "w12-goals-dark");
    Invoke(Tree(page).OfType<Button>().First(b => b.Content as string == "Add task")); await Task.Delay(200); var taskDialog = Dialog(host);
    Tree(taskDialog).OfType<TextBox>().Single(t => t.Header as string == "Title").Text = "Work for outcome"; Click(taskDialog, "PrimaryButton");
    await Until(() => model.Selected?.Title == "Work for outcome" && !model.Busy); check("Goal task creation inherits project and goal", model.Selected!.GoalId == goal.Id && model.Selected.ProjectId == "aurora");
    await Until(() => Tree(page).OfType<Button>().Any(b => AutomationProperties.GetName(b) == "Close task"));
    Click(page, "Close task"); await Until(() => Tree(page).OfType<Button>().Any(b => b.Content as string == "0 of 1 done"));
    await Snapshot(root, "w12-goal-progress-dark"); Click(page, "0 of 1 done"); await Task.Delay(200);
    check("Goal progress opens the matching tasks", model.Filter.GoalId == goal.Id && model.Rows.Count == 1 && model.Rows[0].Title == "Work for outcome");
    await Snapshot(root, "w12-goal-tasks-dark");

  }
  private static async Task Until(Func<bool> done) { var end = DateTimeOffset.UtcNow.AddSeconds(10); while (!done()) { if (DateTimeOffset.UtcNow > end) throw new TimeoutException("The task action did not finish."); await Task.Delay(100); } }
  private static async Task Snapshot(AppDataRoot root, string name, FrameworkElement? target = null)
  {
    await Task.Delay(350);
    if (Environment.GetEnvironmentVariable("TD_TASKS_PROOF_RESUME") == "visual" || Environment.GetEnvironmentVariable("TD_W12_OFFSCREEN") == "1")
    {
      var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(target ?? visualRoot!);
      if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0) throw new InvalidOperationException("Empty offscreen render.");
      var buffer = await bitmap.GetPixelsAsync(); var pixels = new byte[buffer.Length];
      using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
      using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
      await encoder.FlushAsync();
      using var output = new DataReader(stream.GetInputStreamAt(0)); await output.LoadAsync((uint)stream.Size);
      var bytes = new byte[checked((int)stream.Size)]; output.ReadBytes(bytes);
      await File.WriteAllBytesAsync(Path.Combine(root.DirectoryPath, name + ".png"), bytes);
      return;
    }
    var ack = Path.Combine(root.DirectoryPath, name + ".ack");
    await File.WriteAllTextAsync(Path.Combine(root.DirectoryPath, "stage.json"), JsonSerializer.Serialize(new { name }));
    await Until(() => File.Exists(ack));
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child; }
  private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
  private sealed class Navigation : ITasksNavigation { public string? Opened; public void OpenSession(string id) => Opened = id; }
  private sealed class ExampleRunner : ITaskRunner
  {
    public int Starts; public int Notifications; public string Mode = "";
    public bool CanStart(string mode) => mode is "chat" or "terminal";
    public async ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct)
    { Starts++; Mode = launch.Mode; await prepared(new("preview-session", launch.Task.ProjectId, launch.Task.Folder, "sample-account", launch.AgentId), ct); return "preview-session"; }
    public ValueTask NotifyAsync(string sessionId, string text, CancellationToken ct) { Notifications++; return ValueTask.CompletedTask; }
  }
}
