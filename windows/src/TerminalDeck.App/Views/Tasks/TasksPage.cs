using System.Collections.Immutable;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TerminalDeck.App.ViewModels.Tasks;
using TerminalDeck.Core.Tasks;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

public interface ITasksNavigation { void OpenSession(string id); }
public sealed partial class TasksPage : Grid
{
  public TasksViewModel Model { get; }
  private readonly ITasksNavigation navigation;
  private readonly Action<FrameworkElement?>? presentPopup;
  private readonly Action changed;
  private StackPanel list = Stack(0);
  private readonly HashSet<string> selected = [];
  private readonly HashSet<string> folded = [];
  private readonly HashSet<string> expandedDone = [];
  private TextBlock count = Words("");
  private bool rendering;
  private string area = "Work";
  private TaskFilter? beforeTrash;
  private sealed record TaskDrag(string Id, string Machine);
  private string view { get => Model.Filter.View; set => Model.Filters(Model.Filter with { View = value }); }
  private DateOnly week = DateOnly.FromDateTime(DateTime.Today).AddDays(-((7 + (int)DateTime.Today.DayOfWeek - 1) % 7));
  public TasksPage(TasksViewModel model, ITasksNavigation navigation, Action<FrameworkElement?>? presentPopup = null)
  {
    Model = model; this.navigation = navigation; this.presentPopup = presentPopup; Style = PageStyle();
    changed = () => { if (!rendering) DispatcherQueue.TryEnqueueHandled(Render); };
    Loaded += (_, _) => { Model.Changed += changed; Render(); };
    Unloaded += (_, _) => { Model.Changed -= changed; popupEditorTask = null; presentPopup?.Invoke(null); };
    Render();
  }
  public void OpenTask(string id) => Model.Select(id);
  public async Task NewForAgentAsync(string projectId, string agentId)
  {
    Model.Select(null);
    if (!IsLoaded)
    {
      var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); RoutedEventHandler loaded = (_, _) => ready.TrySetResult(); Loaded += loaded;
      try { await ready.Task.WaitAsync(TimeSpan.FromSeconds(5)); } finally { Loaded -= loaded; }
    }
    creatingProject = projectId; creatingAssignee = agentId; creatingGoal = "";
    try { await NewAsync(); } finally { creatingProject = null; creatingAssignee = null; creatingGoal = null; }
  }
  private void Render()
  {
    // Keep the live roster anchored while its saved changes update the task list.
    if (rendering || popupEditorTask is not null && popupEditorTask == Model.SelectedId) return;
    popupEditorTask = null;
    rendering = true;
    try
    {
      selected.IntersectWith(VisibleRows().Select(t => t.Id));
      presentPopup?.Invoke(null);
      Children.Clear();
      if (area == "Goals")
      {
        var goals = new TaskGoalsPage(Model, this, () => { area = "Work"; Render(); }, goal =>
        { area = "Work"; Model.Filters(new(ProjectId: goal.ProjectId, Status: "all", GoalId: goal.Id)); }, async goal =>
        {
          creatingProject = goal.ProjectId; creatingGoal = goal.Id;
          try { await NewAsync(); } finally { creatingProject = null; creatingGoal = null; }
        }); Children.Add(PageScroll(goals)); return;
      }
      list = Stack(0); count = Words("", 12, true);
      var body = Stack(12); body.Margin = new Thickness(20, 12, 20, 20);
      body.Children.Add(Words("Tasks created in Terminal Deck and tasks from connected systems.", 12, true));
      var sections = TaskLayout.Sections("Work", section => { area = section; Render(); }); sections.HorizontalAlignment = HorizontalAlignment.Left;
      var views = new Grid { ColumnSpacing = 12 };
      views.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      views.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      var viewTabs = Stack(12); viewTabs.Orientation = Orientation.Horizontal;
      foreach (var name in new[] { "List", "Board", "Calendar" })
      {
        var tabLabel = Stack(6); tabLabel.Orientation = Orientation.Horizontal;
        tabLabel.Children.Add(new DeckIcon { Glyph = name == "List" ? "\uE8FD" : name == "Board" ? "\uE8A9" : "\uE787", FontSize = 13 });
        tabLabel.Children.Add(TaskLayout.Cell(name));
        var label = Stack(5); label.Children.Add(tabLabel);
        label.Children.Add(new Border { Height = 2, CornerRadius = new CornerRadius(1), Background = view == name ? (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) });
        var tab = TaskLayout.Quiet("", () => { }); tab.Content = label; tab.Opacity = view == name ? 1 : 0.68;
        AutomationProperties.SetName(tab, name + " view"); tab.Click += (_, _) => { view = name; Render(); }; viewTabs.Children.Add(tab);
      }
      viewTabs.Children.Add(SavedViews());
      var sectionBar = new Grid { ColumnSpacing = 12 };
      sectionBar.ColumnDefinitions.Add(new()); sectionBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); sectionBar.Children.Add(sections);
      var newTask = AsyncButton("New task", NewAsync, true); Grid.SetColumn(newTask, 1); sectionBar.Children.Add(newTask); body.Children.Add(sectionBar);
      views.Children.Add(new ScrollViewer { Content = viewTabs, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
      var actions = Stack(8); actions.Orientation = Orientation.Horizontal;
      actions.Children.Add(count);
      actions.Children.Add(TaskLayout.Quiet(Model.Filter.Trash ? "Back to tasks" : "Trash " + Model.Tasks.List(TrashFilter()).Count, () =>
      {
        if (Model.Filter.Trash) { Model.Filters(beforeTrash ?? new(ProjectId: Model.Filter.ProjectId)); beforeTrash = null; }
        else { beforeTrash = Model.Filter; Model.Filters(TrashFilter()); }
      }));
      Grid.SetColumn(actions, 1); views.Children.Add(actions); body.Children.Add(views);
      var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      var group = Choice("Group by", new[] { ("single", "None"), ("status", "Status"), ("assignee", "Assignee"), ("priority", "Priority"), ("tags", "Tags"), ("date", "Due date"), ("type", "Task type"), ("board", "Board"), ("project", "Project") }, Model.Filter.GroupBy);
      group.Header = null; group.Width = 150; AutomationProperties.SetName(group, "Group by");
      group.SelectionChanged += (_, _) => Model.Filters(Model.Filter with { GroupBy = Picked(group) }); controls.Children.Add(group);
      var sort = Choice("Sort by", new[] { ("automatic", "Sort: Default"), ("name", "Sort: Name"), ("due", "Sort: Due date"), ("priority", "Sort: Priority"), ("created", "Sort: Date created") }, Model.Sort);
      sort.Header = null; sort.SelectionChanged += (_, _) => { Model.Sort = Picked(sort); Fill(); }; controls.Children.Add(sort);
      var direction = new ToggleButton { Content = Model.Descending ? "Descending" : "Ascending", IsChecked = Model.Descending, MinHeight = 28 };
      direction.Click += (_, _) => { Model.Descending = direction.IsChecked == true; direction.Content = Model.Descending ? "Descending" : "Ascending"; Fill(); }; controls.Children.Add(direction);
      var columnOptions = Stack(8);
      var columnLabels = new Dictionary<string, string> { ["assignee"] = "Assignee", ["due"] = "Due date", ["priority"] = "Priority", ["status"] = "Status", ["created"] = "Date created", ["project"] = "Project", ["goal"] = "Goal" };
      foreach (var key in Model.ColumnOrder)
      {
        var label = columnLabels[key];
        var option = new CheckBox { Content = label, IsChecked = Model.Columns.Contains(key) };
        option.Click += (_, _) => Model.Column(key, option.IsChecked == true);
        var row = Stack(6); row.Orientation = Orientation.Horizontal; row.Children.Add(option);
        row.Children.Add(TaskLayout.Quiet("Move up", () => Model.MoveColumn(key, -1))); row.Children.Add(TaskLayout.Quiet("Move down", () => Model.MoveColumn(key, 1)));
        columnOptions.Children.Add(row);
      }
      var columns = new Button { Content = "Columns", Flyout = new Flyout { Content = columnOptions }, MinHeight = 28 }; MatchFlyoutTheme(columns, columns.Flyout); controls.Children.Add(columns);
      ToggleButton? closed = null; ToggleButton? me = null;
      var filterBody = Stack(12);
      HashSet<string> Selected(ImmutableArray<string> values, string? single = null) => values.IsDefaultOrEmpty ? single is { Length: > 0 } ? [single] : [] : values.ToHashSet();
      var projectValues = Selected(Model.Filter.ProjectIds, Model.Filter.ProjectId);
      var statusValues = Selected(Model.Filter.Statuses, TaskStatuses.All.Contains(Model.Filter.Status) ? Model.Filter.Status : null);
      var assigneeValues = Selected(Model.Filter.Assignees, Model.Filter.Assignee == "unassigned" ? "none" : Model.Filter.Assignee);
      List<(string Id, CheckBox Box)> CheckList(string label, IEnumerable<(string Id, string Name)> choices, IReadOnlySet<string> selected, StackPanel? container = null)
      {
        var owner = container ?? filterBody; owner.Children.Add(Heading(label, 15)); var result = new List<(string, CheckBox)>();
        foreach (var choice in choices)
        {
          var option = new CheckBox { Content = choice.Name, IsChecked = selected.Contains(choice.Id) };
          AutomationProperties.SetName(option, label + ": " + choice.Name); owner.Children.Add(option); result.Add((choice.Id, option));
        }
        return result;
      }
      var projectOptions = Model.Projects.List().Select(p => (Id: p.Id, Name: p.Name)).ToList();
      projectOptions.AddRange(projectValues.Where(id => !projectOptions.Any(p => p.Id == id)).Select(id => (id, id + " · unavailable saved project")));
      var projectChoices = Stack(8);
      var projects = CheckList("Projects", projectOptions, projectValues, projectChoices);
      var projectPicker = new Button { MinHeight = 28, MaxWidth = 240, Flyout = new Flyout { Content = new ScrollViewer { Content = projectChoices, MaxHeight = 420, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } } };
      MatchFlyoutTheme(projectPicker, projectPicker.Flyout); AutomationProperties.SetName(projectPicker, "Choose task projects");
      projectChoices.Children.Insert(0, TaskLayout.Quiet("All projects", () => { Model.Filters(Model.Filter with { ProjectId = null, ProjectIds = [] }); Render(); }));
      var projectBar = new Grid { ColumnSpacing = 12 }; projectBar.ColumnDefinitions.Add(new()); projectBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      projectBar.Children.Add(Heading("Tasks", 20)); Grid.SetColumn(projectPicker, 1); projectBar.Children.Add(projectPicker); body.Children.Insert(1, projectBar);
      var statuses = CheckList("Status", TaskStatuses.All.Select(s => (s, s)), statusValues);
      var peopleOptions = new[] { (Id: "me", Name: "Me"), (Id: "none", Name: "Unassigned"), (Id: "others", Name: "With agents") }.Concat(Model.People().Select(p => (p.Id, p.Name))).DistinctBy(p => p.Id).ToList();
      peopleOptions.AddRange(assigneeValues.Where(id => !peopleOptions.Any(p => p.Id == id)).Select(id => (id, id + " · unavailable saved assignee")));
      var people = CheckList("Assignees", peopleOptions, assigneeValues);
      var needsYou = new CheckBox { Content = "Needs you", IsChecked = Model.Filter.NeedsYouOnly || Model.Filter.Status == "needs-you" }; filterBody.Children.Add(needsYou);
      var dueFilter = Choice("Due date", new[] { ("any", "Any time"), ("overdue", "Overdue"), ("today", "Due today"), ("week", "Next 7 days"), ("none", "No due date") }, Model.Filter.Due); filterBody.Children.Add(dueFilter);
      var archive = new CheckBox { Content = "Archived", IsChecked = Model.Filter.Archived, Visibility = Model.Filter.Trash ? Visibility.Collapsed : Visibility.Visible }; filterBody.Children.Add(archive);
      filterBody.Children.Add(TaskLayout.Quiet("Reset filters", ResetFilters));
      var filter = new Button { Content = "Filter", Flyout = new Flyout { Content = new ScrollViewer { Content = filterBody, Width = 300, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } }, MinHeight = 28 };
      MatchFlyoutTheme(filter, filter.Flyout);
      void CountFilters()
      {
        var state = Model.Filter; var active = (!state.ProjectIds.IsDefaultOrEmpty || state.ProjectId is not null ? 1 : 0) + (!state.Statuses.IsDefaultOrEmpty || state.Status is not ("open" or "all") || state.NeedsYouOnly ? 1 : 0) + (!state.Assignees.IsDefaultOrEmpty || state.Assignee.Length > 0 ? 1 : 0) + (state.Due != "any" ? 1 : 0) + (state.Archived ? 1 : 0) + (state.GoalId is not null ? 1 : 0) + (state.Source is not null ? 1 : 0);
        filter.Content = active == 0 ? "Filter" : $"Filter · {active}";
        projectPicker.Content = !state.ProjectIds.IsDefaultOrEmpty && state.ProjectIds.Length > 1 ? state.ProjectIds.Length + " projects" : Model.ProjectScope is { } projectId ? Model.Projects.List().FirstOrDefault(p => p.Id == projectId)?.Name ?? "Unavailable project" : "All projects";
      }
      void SaveFilters()
      {
        var selectedStatuses = statuses.Where(c => c.Box.IsChecked == true).Select(c => c.Id).ToImmutableArray();
        rendering = true;
        try
        {
          Model.Filters(Model.Filter with { ProjectId = null, ProjectIds = projects.Where(c => c.Box.IsChecked == true).Select(c => c.Id).ToImmutableArray(),
            Statuses = selectedStatuses, Status = Model.Filter.Trash || Model.Filter.Status == "all" || selectedStatuses.Contains("Done") ? "all" : "open", Assignee = "", Assignees = people.Where(c => c.Box.IsChecked == true).Select(c => c.Id).ToImmutableArray(),
            NeedsYouOnly = needsYou.IsChecked == true, Due = Picked(dueFilter), Archived = archive.IsChecked == true });
          Fill(); CountFilters();
          if (closed is not null) closed.IsChecked = Model.Filter.Status == "all";
          if (me is not null) me.IsChecked = Model.Filter.Assignees.IsDefaultOrEmpty ? Model.Filter.Assignee == "me" : Model.Filter.Assignees.Length == 1 && Model.Filter.Assignees[0] == "me";
        }
        finally { rendering = false; }
      }
      foreach (var option in projects.Concat(statuses).Concat(people)) { option.Box.Checked += (_, _) => SaveFilters(); option.Box.Unchecked += (_, _) => SaveFilters(); }
      needsYou.Click += (_, _) => SaveFilters(); archive.Click += (_, _) => SaveFilters(); dueFilter.SelectionChanged += (_, _) => SaveFilters();
      CountFilters(); controls.Children.Add(filter);
      if (Model.Filter.GoalId is { } goalFilter)
      {
        filterBody.Children.Add(Words("Goal: " + (Model.Tasks.Goals().FirstOrDefault(g => g.Id == goalFilter)?.Title ?? "Unavailable saved goal"), 12, true));
        filterBody.Children.Add(TaskLayout.Quiet("Clear goal filter", () => Model.Filters(Model.Filter with { GoalId = null })));
      }
      ((Flyout)filter.Flyout).Closed += (_, _) => { if (IsLoaded) Render(); };
      closed = new ToggleButton { Content = "Closed", IsChecked = Model.Filter.Status == "all", MinHeight = 28 };
      closed.Click += (_, _) => Model.Filters(Model.Filter with { Status = closed.IsChecked == true ? "all" : "open" }); controls.Children.Add(closed);
      me = new ToggleButton { Content = "Me", IsChecked = Model.Filter.Assignees.IsDefaultOrEmpty ? Model.Filter.Assignee == "me" : Model.Filter.Assignees.Length == 1 && Model.Filter.Assignees[0] == "me", MinHeight = 28 };
      me.Click += (_, _) => Model.Filters(Model.Filter with { Assignee = me.IsChecked == true ? "me" : "", Assignees = [] }); controls.Children.Add(me);
      if (Model.Connected is not null) controls.Children.Add(AsyncButton("Connected systems", ConnectedAsync));
      var search = new AutoSuggestBox { PlaceholderText = "Search tasks", Text = Model.Filter.Search, HorizontalAlignment = HorizontalAlignment.Right, Width = 240 };
      AutomationProperties.SetAutomationId(search, "tasks.search");
      search.TextChanged += (_, _) =>
      {
        rendering = true;
        try { if (search.Text.Length > 240) { search.Text = search.Text[..240]; return; } Model.Filters(Model.Filter with { Search = search.Text }); Fill(); }
        finally { rendering = false; }
      };
      var bar = new Grid { ColumnSpacing = 12 };
      bar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
      bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      bar.RowDefinitions.Add(new() { Height = GridLength.Auto }); bar.RowDefinitions.Add(new() { Height = GridLength.Auto });
      var controlsScroll = new ScrollViewer { Content = controls, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
      bar.Children.Add(controlsScroll); Grid.SetColumn(search, 1); bar.Children.Add(search);
      bar.SizeChanged += (_, _) => { var wide = bar.ActualWidth >= 1080; Grid.SetColumn(search, wide ? 1 : 0); Grid.SetRow(search, wide ? 0 : 1); search.Margin = wide ? new Thickness(0) : new Thickness(0, 8, 0, 0); };
      foreach (var control in controls.Children.OfType<Control>())
      { control.MinHeight = 24; control.Height = 24; control.CornerRadius = new CornerRadius(8); control.FontSize = 12; control.Padding = new Thickness(8, 2, 8, 2); }
      body.Children.Add(bar);

      var bulk = Stack(8); bulk.Orientation = Orientation.Horizontal;
      var selectedCount = Words($"{selected.Count} selected", 12, true); bulk.Children.Add(selectedCount);
      bulk.Children.Add(TaskLayout.Quiet("Select all", () => { foreach (var row in VisibleRows()) selected.Add(row.Id); Render(); }));
      bulk.Children.Add(TaskLayout.Quiet("Clear selection", () => { selected.Clear(); Render(); }));
      var bulkActions = new MenuFlyout();
      void BulkItem(string title, Func<Task> action)
      {
        var item = new MenuFlyoutItem { Text = title }; item.Click += async (_, _) => await action(); bulkActions.Items.Add(item);
      }
      if (Model.Filter.Trash) BulkItem("Restore", () => BulkAsync(t => Model.Tasks.Restore(t.Id, TaskActor.Owner)));
      else
      {
        foreach (var state in TaskStatuses.All) BulkItem(state == "Done" ? "Mark done" : "Status: " + state, () => BulkAsync(t => Model.Tasks.Status(t.Id, state, TaskActor.Owner)));
        foreach (var priority in new[] { "", "Low", "Medium", "High", "Critical" })
          BulkItem(priority.Length == 0 ? "No priority" : "Priority: " + priority, () => BulkAsync(t => Model.Tasks.Update(t.Id, TaskService.Draft(t) with { Priority = Empty(priority) }, TaskActor.Owner, t.Revision)));
        BulkItem("Due date…", BulkDueAsync); BulkItem("Add tags…", () => BulkTagsAsync("add")); BulkItem("Remove tags…", () => BulkTagsAsync("remove"));
        BulkItem("Clear tags", () => BulkAsync(t => Model.Tasks.Update(t.Id, TaskService.Draft(t) with { Labels = [] }, TaskActor.Owner, t.Revision)));
        BulkItem(Model.Filter.Archived ? "Restore from archive" : "Archive", () => BulkAsync(t => Model.Tasks.Archive(t.Id, !Model.Filter.Archived, TaskActor.Owner)));
        BulkItem("Delete", async () => { if (await ConfirmAsync(XamlRoot, "Delete selected tasks?", "These tasks go to Trash and can be restored.", "Delete")) await BulkAsync(t => Model.Tasks.Delete(t.Id, TaskActor.Owner)); });
      }
      var bulkButton = new Button { Content = "Selected task actions", Flyout = bulkActions, IsEnabled = selected.Count > 0 && !Model.Busy }; MatchFlyoutTheme(bulkButton, bulkActions); bulk.Children.Add(bulkButton);
      bulk.Visibility = selected.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
      // Selection remains reachable through each task's checkbox and context menu.
      body.Children.Add(bulk); Fill();
      var feedback = Stack(8);
      if (Model.Busy) feedback.Children.Add(new Notices.CompactNotice { Scope = this, Text = "Saving task…" });
      if (Model.Message.Length > 0) feedback.Children.Add(new Notices.CompactNotice { Scope = this, IsOpen = true, IsClosable = false, Severity = Model.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Informational, Message = Model.Message });
      var frame = new Grid();
      frame.RowDefinitions.Add(new() { Height = GridLength.Auto });
      frame.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
      frame.RowDefinitions.Add(new() { Height = GridLength.Auto });
      body.Margin = new Thickness(24, 20, 24, 10); frame.Children.Add(body);
      list.Margin = new Thickness(24, 0, 24, 32);
      list.MinWidth = view == "List" ? TaskLayout.RequiredWidth(Model.Columns, Model.Filter.GroupBy == "status", Model.ProjectScope is null || Model.Filter.GroupBy == "project") : 0;
      var scroll = new ScrollViewer { Content = list, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
      Grid.SetRow(scroll, 1); frame.Children.Add(scroll);
      Grid.SetRow(feedback, 2); frame.Children.Add(feedback); Children.Add(frame);
      if (Model.Selected is { } task) { var popup = TaskPopup(task); if (presentPopup is not null && IsLoaded) presentPopup(popup); else Children.Add(popup); }
    }
    finally { rendering = false; }
  }
  private void Fill()
  {
    list.Children.Clear();
    var rows = VisibleRows();
    var total = Model.Tasks.List(Model.Filter with { Search = "", Status = "all", Statuses = [], Assignee = "", Assignees = [], Due = "any", NeedsYouOnly = false }).Count;
    count.Text = rows.Count == total ? $"{total} task{(total == 1 ? "" : "s")}" : $"{rows.Count} of {total} tasks";
    if (view == "Calendar") { FillCalendar(rows); return; }
    if (view == "Board") { FillBoard(rows); return; }
    if (rows.Count == 0)
    {
      var empty = Stack(8); empty.Margin = new Thickness(24, 56, 24, 56); empty.Children.Add(Heading(Model.Filter.Trash ? "Trash is empty" : total == 0 ? "No tasks yet" : "No tasks match", 20));
      empty.Children.Add(Words(Model.Filter.Trash ? "Deleted tasks can be restored here." : total == 0 ? "Use New task to add work for yourself, Hoot or a task agent." : "Try another search or change the filters.", muted: true));
      if (!Model.Filter.Trash && total > 0) empty.Children.Add(TaskLayout.Quiet("Clear search and filters", ResetFilters));
      list.Children.Add(empty); return;
    }
    var byProject = Model.ProjectScope is null && Model.Filter.GroupBy != "project";
    foreach (var section in rows.GroupBy(t => byProject ? t.ProjectId : "").OrderBy(g => g.Key.Length == 0 ? "" : Model.Projects.Get(g.Key).Name))
    {
      if (byProject)
      {
        var sectionKey = "project:" + section.Key;
        var sectionOpen = !folded.Contains(sectionKey);
        var projectHeading = TaskLayout.Quiet((sectionOpen ? "⌄  " : "›  ") + "  " + Model.Projects.Get(section.Key).Name + "  " + section.Count(), () => { if (!folded.Add(sectionKey)) folded.Remove(sectionKey); Fill(); });
        projectHeading.Margin = new Thickness(0, 18, 0, 6); list.Children.Add(projectHeading);
        if (!sectionOpen) continue;
      }
      foreach (var group in Model.Groups(section))
      {
        var isDone = group.Key == "closed" || Model.Filter.GroupBy == "status" && group.Label == "Done";
        var key = section.Key + ":" + Model.Filter.GroupBy + ":" + group.Key;
        var open = isDone ? (Model.Filter.Status != "open" ? !folded.Contains(key) : expandedDone.Contains(key)) : !folded.Contains(key);
        var heading = TaskLayout.Quiet("", () => { var set = isDone && Model.Filter.Status == "open" ? expandedDone : folded; if (!set.Add(key)) set.Remove(key); Fill(); });
        var groupTitle = Stack(8); groupTitle.Orientation = Orientation.Horizontal;
        groupTitle.Children.Add(TaskLayout.Cell(open ? "⌄" : "›", true));
        groupTitle.Children.Add(Model.Filter.GroupBy == "status" || isDone ? TaskLayout.Status(group.Label, true) : TaskLayout.Cell(group.Label));
        groupTitle.Children.Add(TaskLayout.Cell(group.Rows.Count.ToString(), true)); heading.Content = groupTitle;
        AutomationProperties.SetName(heading, $"{group.Label}, {group.Rows.Count} tasks, {(open ? "expanded" : "collapsed")}");
        var header = TaskLayout.Columns(Model.Columns, Model.ColumnOrder, Model.Filter.GroupBy == "status", byProject || Model.Filter.GroupBy == "project", heading, TaskLayout.Cell("Assignee", true), TaskLayout.Cell("Due date", true), TaskLayout.Cell("Priority", true), TaskLayout.Cell("Status", true), TaskLayout.Cell("Project", true), TaskLayout.Cell("Date created", true), TaskLayout.Cell("Goal", true));
        header.MinHeight = 36; list.Children.Add(header);
        if (!open) continue;
        foreach (var task in group.Rows)
        {
          var title = new Grid { ColumnSpacing = 8 };
          title.ColumnDefinitions.Add(new() { Width = new GridLength(62) });
          title.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
          title.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
          var done = TaskLayout.Icon(task.Status == "Done" ? "\uE73E" : "\uEA3A", task.Status == "Done" ? "Reopen task" : "Complete task", async () => await Model.RunAsync(() => { Model.Tasks.Status(task.Id, task.Status == "Done" ? "To-Do" : "Done", TaskActor.Owner); return Task.CompletedTask; }, "Status saved."));
          var selection = new CheckBox { IsChecked = selected.Contains(task.Id), MinWidth = 24, Padding = new Thickness(0) };
          AutomationProperties.SetName(selection, "Select " + task.Title);
          selection.Click += (_, _) => { if (selection.IsChecked == true) selected.Add(task.Id); else selected.Remove(task.Id); Render(); };
          var rowActions = Stack(2); rowActions.Orientation = Orientation.Horizontal; rowActions.Children.Add(selection); rowActions.Children.Add(done);
          done.IsEnabled = task.DeletedAt is null && !Model.Busy; title.Children.Add(rowActions);
          var name = Stack(3); name.Children.Add(TaskLayout.Cell(task.Title));
          if (!Model.Columns.Contains("created")) name.Children.Add(new TextBlock { Text = "Created " + TasksViewModel.CreatedLabel(task), FontSize = 12, Opacity = 0.6 });
          var openTask = TaskLayout.Quiet("", () => Model.Select(task.Id)); openTask.Content = name; openTask.HorizontalAlignment = HorizontalAlignment.Stretch; openTask.HorizontalContentAlignment = HorizontalAlignment.Stretch;
          AutomationProperties.SetName(openTask, task.Title + ", " + task.Status + ", " + Model.Assignee(task)); AutomationProperties.SetAutomationId(openTask, "tasks.row." + task.Id);
          Grid.SetColumn(openTask, 1); title.Children.Add(openTask);
          var badges = Stack(6); badges.Orientation = Orientation.Horizontal; badges.VerticalAlignment = VerticalAlignment.Center; badges.Margin = new Thickness(0, 0, 16, 0);
          if (task.Details.Length > 0) badges.Children.Add(new DeckIcon { Glyph = "\uE8A5", FontSize = 12, Opacity = 0.5 });
          if (task.NeedsYou)
          {
            var needs = new Border { Child = new TextBlock { Text = "Needs you", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, Padding = new Thickness(7, 1, 7, 2), CornerRadius = new CornerRadius(8), VerticalAlignment = VerticalAlignment.Center };
            TerminalDeck.App.Shell.ShellTheme.SetResourceReference(needs, Border.BackgroundProperty, "DeckControlBrush"); badges.Children.Add(needs);
          }
          if (task.Comments.Length > 0) { badges.Children.Add(new DeckIcon { Glyph = "\uE90A", FontSize = 12, Opacity = 0.6 }); badges.Children.Add(TaskLayout.Cell(task.Comments.Length.ToString(), true)); }
          Grid.SetColumn(badges, 2); title.Children.Add(badges);
          var row = TaskLayout.Columns(Model.Columns, Model.ColumnOrder, Model.Filter.GroupBy == "status", byProject || Model.Filter.GroupBy == "project", title, TaskLayout.Cell(Model.Assignee(task)), TaskLayout.Cell(TasksViewModel.DueLabel(task), true), TaskLayout.Cell(task.Priority ?? "—", true), TaskLayout.Status(task.Status), TaskLayout.Cell(Model.Projects.Get(task.ProjectId).Name, true), TaskLayout.Cell(TasksViewModel.CreatedLabel(task), true), TaskLayout.Cell(Model.Tasks.Goals().FirstOrDefault(g => g.Id == task.GoalId)?.Title ?? "—", true));
          var menu = new MenuFlyout();
          void Item(string label, Func<Task> action)
          {
            var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await action(); menu.Items.Add(item);
          }
          Item("Open", () => { Model.Select(task.Id); return Task.CompletedTask; });
          if (task.DeletedAt is null)
          {
            Item("Move next", () => Model.RunAsync(() => { var at = TaskStatuses.All.IndexOf(task.Status); Model.Tasks.Status(task.Id, TaskStatuses.All[Math.Min(at + 1, TaskStatuses.All.Length - 1)], TaskActor.Owner); return Task.CompletedTask; }, "Status saved."));
            Item(task.Status == "Done" ? "Reopen" : "Mark done", () => Model.RunAsync(() => { Model.Tasks.Status(task.Id, task.Status == "Done" ? "To-Do" : "Done", TaskActor.Owner); return Task.CompletedTask; }, "Status saved."));
            Item("Delete", async () =>
            {
              if (await ConfirmAsync(XamlRoot, "Delete this task?", "It will go to Trash, where you can restore it.", "Delete"))
                await Model.RunAsync(() => { Model.Tasks.Delete(task.Id, TaskActor.Owner); return Task.CompletedTask; }, "Task moved to Trash.");
            });
          }
          row.ContextFlyout = menu; MatchFlyoutTheme(row, menu);
          row.CornerRadius = new CornerRadius(8);
          void RowFill(string resource) => row.Background = (Microsoft.UI.Xaml.Media.Brush)TerminalDeck.App.Shell.ShellTheme.Resource(row, resource);
          var hovered = false;
          void SelectionVisibility() => selection.Opacity = hovered || selected.Count > 0 || selection.FocusState != FocusState.Unfocused ? 1 : 0;
          selection.GotFocus += (_, _) => SelectionVisibility(); selection.LostFocus += (_, _) => SelectionVisibility(); SelectionVisibility();
          row.PointerEntered += (_, _) => { hovered = true; SelectionVisibility(); RowFill(selected.Contains(task.Id) ? "DeckSelectionBrush" : "DeckHoverBrush"); };
          row.PointerExited += (_, _) => { hovered = false; SelectionVisibility(); RowFill(selected.Contains(task.Id) ? "DeckSelectionBrush" : "DeckTransparentBrush"); };
          row.PointerPressed += (_, _) => RowFill("DeckPressedBrush");
          row.PointerReleased += (_, _) => RowFill(selected.Contains(task.Id) ? "DeckSelectionBrush" : "DeckHoverBrush");
          row.ActualThemeChanged += (_, _) => RowFill(selected.Contains(task.Id) ? "DeckSelectionBrush" : "DeckTransparentBrush");
          RowFill(selected.Contains(task.Id) ? "DeckSelectionBrush" : "DeckTransparentBrush"); list.Children.Add(row);
        }
        if (!Model.Filter.Trash && !Model.Filter.Archived)
        {
          var add = TaskLayout.Quiet("+ Add Task", async () => await NewInGroupAsync(group.Rows.First(), group.Tag)); add.Margin = new Thickness(44, 0, 0, 10); add.HorizontalAlignment = HorizontalAlignment.Left; list.Children.Add(add);
        }
      }
    }
  }
  private StackPanel SavedViews()
  {
    var row = Stack(8); row.Orientation = Orientation.Horizontal;
    var views = Model.Tasks.Views(Model.Machine);
    var picker = Choice("Saved views", new[] { ("", "Current view") }.Concat(views.Select(v => (v.Id, v.Name))), Model.SelectedViewId ?? "");
    picker.Header = null; picker.SelectionChanged += (_, _) => Model.SelectView(Empty(Picked(picker))); row.Children.Add(picker);
    row.Children.Add(AsyncButton("+ View", async () =>
    {
      var name = Field("View name", max: 80); if (await Dialog(XamlRoot, "Save view", name, "Save").ShowAsync() != ContentDialogResult.Primary) return;
      await Model.RunAsync(() => { Model.SelectedViewId = Model.Tasks.SaveView(Model.Machine, null, name.Text, Model.Filter).Id; return Task.CompletedTask; }, "View saved.");
    }));
    if (Model.SavedView is { } selectedView)
    {
      if (Model.ViewChanged)
      {
        row.Children.Add(AsyncButton("Update", () => Model.RunAsync(() => { Model.Tasks.SaveView(Model.Machine, selectedView.Id, selectedView.Name, Model.Filter); return Task.CompletedTask; }, "View updated.")));
        row.Children.Add(TaskLayout.Quiet("Revert", () => Model.SelectView(selectedView.Id)));
      }
      row.Children.Add(AsyncButton("Rename", async () =>
      {
        var name = Field("View name", selectedView.Name, max: 80); if (await Dialog(XamlRoot, "Rename view", name).ShowAsync() != ContentDialogResult.Primary) return;
        await Model.RunAsync(() => { Model.Tasks.SaveView(Model.Machine, selectedView.Id, name.Text, selectedView.State); return Task.CompletedTask; }, "View renamed.");
      }));
      row.Children.Add(AsyncButton("Delete view", async () =>
      {
        if (!await ConfirmAsync(XamlRoot, "Delete this view?", "Tasks are kept.", "Delete view")) return;
        await Model.RunAsync(() => { Model.Tasks.DeleteView(Model.Machine, selectedView.Id); Model.SelectedViewId = null; return Task.CompletedTask; }, "View deleted.");
      }));
    }
    return row;
  }
  private void ResetFilters() => Model.Filters(Model.Filter with { ProjectId = null, ProjectIds = [], Search = "", Status = Model.Filter.Trash || Model.Filter.Status == "all" ? "all" : "open", Statuses = [], Assignee = "", Assignees = [], NeedsYouOnly = false, Due = "any", Archived = false, GoalId = null, Source = null });
  private TaskFilter TrashFilter() => Model.Filter with { Trash = true, Archived = false, Status = "all", Search = "", Assignee = "", Due = "any", GoalId = null, Source = null, Statuses = [], Assignees = [], NeedsYouOnly = false };
  private IReadOnlyList<DeckTask> VisibleRows() => Model.Filter.Status == "open" && Model.Filter.Statuses.IsDefaultOrEmpty
    ? Model.Ordered(Model.Rows.Concat(Model.Tasks.List(Model.Filter with { Status = "Done" }))) : Model.Rows;
  private async Task BulkAsync(Func<DeckTask, DeckTask> action)
  {
    var ids = VisibleRows().Where(t => selected.Contains(t.Id)).Select(t => t.Id).ToArray();
    await Model.RunAsync(() =>
    {
      var done = 0; var failed = 0;
      foreach (var id in ids)
      {
        try { action(Model.Tasks.Get(id, includeTrash: true)); selected.Remove(id); done++; }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.IO.IOException) { failed++; }
      }
      if (failed > 0) throw new InvalidOperationException($"{done} changed; {failed} could not change. The remaining tasks stay selected. Open them to check their current sessions or saved state, then try again.");
      return Task.CompletedTask;
    }, $"{ids.Length} tasks changed.");
  }
  private async Task BulkDueAsync()
  {
    var due = new TaskDateField("Due date");
    var body = Stack(); body.Children.Add(due);
    if (await Dialog(XamlRoot, "Set due date", body).ShowAsync() == ContentDialogResult.Primary)
      await BulkAsync(t => Model.Tasks.Update(t.Id, TaskService.Draft(t) with { DueDate = due.Date, DueTime = due.Time }, TaskActor.Owner, t.Revision));
  }
  private async Task BulkTagsAsync(string mode)
  {
    var tags = Field("Tags, separated by commas", max: 4000);
    if (await Dialog(XamlRoot, mode == "add" ? "Add tags" : "Remove tags", tags).ShowAsync() != ContentDialogResult.Primary) return;
    var names = tags.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    await BulkAsync(t => Model.Tasks.Update(t.Id, TaskService.Draft(t) with { Labels = (mode == "add" ? t.Labels.Concat(names).Distinct() : t.Labels.Except(names)).ToImmutableArray() }, TaskActor.Owner, t.Revision));
  }
  private Task NewInGroupAsync(DeckTask first, string? tag) => NewAsync(first, tag);
  private void FillBoard(IReadOnlyList<DeckTask> rows)
  {
    var board = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
    foreach (var status in TaskStatuses.All)
    {
      var tasks = rows.Where(t => t.Status == status).ToArray(); var column = Stack(8); column.Width = 260;
      var heading = Stack(8); heading.Orientation = Orientation.Horizontal;
      heading.Children.Add(TaskLayout.Status(status)); heading.Children.Add(TaskLayout.Cell(tasks.Length.ToString(), true)); column.Children.Add(heading);
      foreach (var task in tasks) column.Children.Add(TaskTile(task));
      if (!Model.Filter.Trash && !Model.Filter.Archived)
        column.Children.Add(AsyncButton("+ Add Task", () => NewForStatusAsync(status)));
      var surface = TaskLayout.Surface(column);
      TaskDropTarget(surface, task => Model.Tasks.Status(task.Id, status, TaskActor.Owner)); board.Children.Add(surface);
    }
    list.Children.Add(new ScrollViewer { Content = board, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
  }
  private string? creatingStatus;
  private string? creatingDate;
  private string? creatingGoal;
  private string? creatingProject;
  private string? creatingAssignee;
  private async Task NewForStatusAsync(string status)
  {
    creatingStatus = status;
    try { await NewAsync(); } finally { creatingStatus = null; }
  }
  private Button TaskTile(DeckTask task)
  {
    var words = Stack(6); words.Children.Add(Words(task.Title));
    words.Children.Add(Words(Model.Assignee(task) + " · " + Model.Projects.Get(task.ProjectId).Name, 12, true));
    words.Children.Add(Words(task.Status + (task.DueDate is { } due ? " · " + due : "") + (task.Comments.Length > 0 ? $" · {task.Comments.Length} comments" : ""), 12, true));
    var button = TaskLayout.Quiet("", () => Model.Select(task.Id)); button.Content = TaskLayout.Surface(words);
    button.Padding = new Thickness(0); button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.HorizontalAlignment = HorizontalAlignment.Stretch;
    button.CanDrag = task.DeletedAt is null && !task.Archived && !Model.Busy;
    button.DragStarting += (_, e) => { e.Data.SetData("TerminalDeck.Task", JsonSerializer.Serialize(new TaskDrag(task.Id, Model.Machine))); e.Data.RequestedOperation = DataPackageOperation.Move; };
    AutomationProperties.SetAutomationId(button, "tasks.row." + task.Id); AutomationProperties.SetName(button, task.Title); return button;
  }
  private void TaskDropTarget(FrameworkElement target, Func<DeckTask, DeckTask> move)
  {
    target.AllowDrop = !Model.Filter.Trash && !Model.Filter.Archived;
    target.DragOver += (_, e) =>
    {
      if (!Model.Busy && e.DataView.Contains("TerminalDeck.Task")) { e.AcceptedOperation = DataPackageOperation.Move; e.Handled = true; }
    };
    target.Drop += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Handled = true;
      try
      {
        if (Model.Busy) { e.AcceptedOperation = DataPackageOperation.None; return; }
        await Model.RunAsync(async () =>
        {
          if (!e.DataView.Contains("TerminalDeck.Task") || await e.DataView.GetDataAsync("TerminalDeck.Task") is not string raw || raw.Length > 1024) throw new ArgumentException("Drag a task from this workspace.");
          TaskDrag? transfer;
          try { transfer = JsonSerializer.Deserialize<TaskDrag>(raw); } catch (JsonException) { throw new ArgumentException("Drag a task from this workspace."); }
          if (transfer is null || transfer.Machine != Model.Machine) throw new ArgumentException("This task belongs to another app workspace.");
          move(Model.Tasks.Get(transfer.Id));
        }, "Task moved.");
      }
      finally { deferral.Complete(); }
    };
  }
  private void FillCalendar(IReadOnlyList<DeckTask> rows)
  {
    var navigation = Stack(8); navigation.Orientation = Orientation.Horizontal;
    navigation.Children.Add(TaskLayout.Icon("\uE76B", "Previous week", () => { week = week.AddDays(-7); Fill(); }));
    navigation.Children.Add(TaskLayout.Quiet("Today", () => { week = DateOnly.FromDateTime(DateTime.Today).AddDays(-((7 + (int)DateTime.Today.DayOfWeek - 1) % 7)); Fill(); }));
    navigation.Children.Add(TaskLayout.Icon("\uE76C", "Next week", () => { week = week.AddDays(7); Fill(); }));
    navigation.Children.Add(TaskLayout.Cell(week.ToString("MMM d") + " – " + week.AddDays(6).ToString("MMM d, yyyy"))); list.Children.Add(navigation);
    var days = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    for (var i = 0; i < 7; i++)
    {
      var date = week.AddDays(i); var day = Stack(8); day.Width = 180;
      day.Children.Add(Heading(date.ToString("ddd d"), 14));
      foreach (var task in rows.Where(t => t.DueDate == date.ToString("yyyy-MM-dd"))) day.Children.Add(TaskTile(task));
      if (day.Children.Count == 1) day.Children.Add(Words("No tasks", 12, true));
      if (!Model.Filter.Trash && !Model.Filter.Archived)
        day.Children.Add(AsyncButton("+ Add Task", async () =>
        {
          creatingDate = date.ToString("yyyy-MM-dd");
          try { await NewAsync(); } finally { creatingDate = null; }
        }));
      var surface = TaskLayout.Surface(day);
      TaskDropTarget(surface, task => Model.Tasks.Update(task.Id, TaskService.Draft(task) with { DueDate = date.ToString("yyyy-MM-dd") }, TaskActor.Owner, task.Revision)); days.Children.Add(surface);
    }
    list.Children.Add(new ScrollViewer { Content = days, HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    var undated = rows.Where(t => t.DueDate is null).ToArray();
    if (undated.Length > 0) { list.Children.Add(Heading("No due date · " + undated.Length, 14)); foreach (var task in undated) list.Children.Add(TaskTile(task)); }
  }
  private Task NewAsync() => NewAsync(null);
  private async Task NewAsync(DeckTask? groupDefault, string? groupTag = null)
  {
    var title = Field("Title", max: 240); var details = Field("Description", multiline: true, max: 40000);
    var project = Choice("Project", Model.Projects.List().Select(p => (p.Id, p.Name)), creatingProject ?? groupDefault?.ProjectId ?? Model.ProjectScope);
    var status = Choice("Status", TaskStatuses.All.Select(s => (s, s)), creatingStatus ?? (Model.Filter.GroupBy == "status" ? groupDefault?.Status ?? "To-Do" : "To-Do"));
    var priority = Choice("Priority", new[] { ("", "None"), ("Low", "Low"), ("Medium", "Medium"), ("High", "High"), ("Critical", "Critical") }, Model.Filter.GroupBy == "priority" ? groupDefault?.Priority : null);
    var due = new TaskDateField("Due date", creatingDate ?? (Model.Filter.GroupBy == "date" ? groupDefault?.DueDate : null), Model.Filter.GroupBy == "date" ? groupDefault?.DueTime : null);
    var assigned = Choice("Assigned to", new[] { ("me", "Me"), ("none", "Unassigned") }.Concat(Model.People().Where(p => p.Kind is "agent" or "hoot" && !p.Id.StartsWith("session:", StringComparison.Ordinal)).Select(p => (p.Id, p.Name))), creatingAssignee ?? (Model.Filter.GroupBy == "assignee" ? groupDefault?.Assignee ?? "me" : "me"));
    var folder = Field("Project folder · full path", Model.Projects.Get(Picked(project)).HomeFolder ?? "");
    project.SelectionChanged += (_, _) => folder.Text = Model.Projects.Get(Picked(project)).HomeFolder ?? "";
    var goal = TaskGoalsPage.GoalPicker(Model, Picked(project), creatingGoal ?? Model.Filter.GoalId);
    project.SelectionChanged += (_, _) => TaskGoalsPage.FillGoals(goal, Model, Picked(project), null);
    var board = Field("Board", Model.Filter.GroupBy == "board" ? groupDefault?.Board ?? "" : "", max: 120);
    var tags = Field("Tags, separated by commas", groupTag ?? "");
    var type = Choice("Task type", new[] { ("Task", "Task"), ("Milestone", "Milestone") }, Model.Filter.GroupBy == "type" ? groupDefault?.Type ?? "Task" : "Task");
    var error = new Notices.CompactNotice { IsClosable = false, Severity = InfoBarSeverity.Error };
    var body = Stack(); foreach (var field in new UIElement[] { title, details, project, folder, assigned, goal, type, board, tags, status, priority, due, error }) body.Children.Add(field);
    body.Children.Add(Words("Choosing an agent starts its task session. If the session cannot start, the saved task stays available to retry.", 12, true));
    body.Children.Add(AsyncButton("Choose folder…", async () =>
    {
      var hwnd = Microsoft.UI.Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
      if (await PickFolderAsync(hwnd) is { } selected) folder.Text = selected;
    }));
    var dialog = Dialog(XamlRoot, "New task", body, "Add task");
    dialog.PrimaryButtonClick += async (_, e) =>
    {
      var deferral = e.GetDeferral(); e.Cancel = true;
      DeckTask? created = null;
      try
      {
        var ok = await Model.RunAsync(async () =>
        {
          var assignee = Picked(assigned);
          if (assignee is not ("me" or "none") && !Model.People().Any(p => p.Id == assignee && !p.Id.StartsWith("session:", StringComparison.Ordinal))) throw new InvalidOperationException("This assignee is unavailable. Choose a current agent before creating the task.");
          if (assignee is not ("me" or "none") && !Model.Tasks.CanRun("chat")) throw new InvalidOperationException("Task sessions are not connected. Choose Me or Unassigned, or connect the task runner first.");
          created = Model.Tasks.Create(new(title.Text, details.Text, Picked(project), Empty(folder.Text), Status: Picked(status),
            Assignee: assignee == "none" ? "none" : "me", Priority: Empty(Picked(priority)), DueDate: due.Date, DueTime: due.Time, Board: Empty(board.Text),
            Labels: tags.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToImmutableArray(), Type: Picked(type), GoalId: Empty(Picked(goal))), TaskActor.Owner);
          if (assignee is not ("me" or "none")) await Model.Tasks.AssignAsync(created.Id, assignee, TaskActor.Owner);
        }, "Task added.");
        if (created is not null) { Model.Select(created.Id, keepFeedback: true); e.Cancel = false; }
        if (!ok) { error.Message = Model.Message; error.IsOpen = true; }
      }
      finally { deferral.Complete(); }
    };
    await dialog.ShowAsync();
  }

  private async Task ConnectedAsync()
  {
    if (Model.Connected is not { } connected) return;
    var body = Stack(); var systems = connected.Systems();
    foreach (var system in systems)
      body.Children.Add(AsyncButton(system.Name + " · " + (system.AllowChanges ? "Changes allowed" : "Read only"), () => ShowConnectedAsync(system)));
    body.Children.Add(Words("Connection settings live in Settings → Tasks.", muted: true));
    body.Children.Add(AsyncButton("Manage connections…", async () =>
    {
      // A nested ContentDialog is not allowed by WinUI; close this one first.
      if (connectionsDialog is { } current) current.Hide();
      await Task.Yield();
      if (navigation is ISettingsPageNavigation settings) await settings.OpenSettingsAsync("tasks");
    }));
    connectionsDialog = Dialog(XamlRoot, "Connected task systems", body); connectionsDialog.PrimaryButtonText = ""; connectionsDialog.CloseButtonText = "Close";
    await connectionsDialog.ShowAsync(); connectionsDialog = null;
  }
  private ContentDialog? connectionsDialog;
  private async Task ShowConnectedAsync(ConnectedTaskSystem system)
  {
    connectionsDialog?.Hide(); await Task.Yield();
    IReadOnlyList<ConnectedTask> tasks = [];
    if (!await Model.RunAsync(async () => tasks = await Model.Connected!.ListAsync(system.Id), "Task list read.")) return;
    var body = Stack();
    foreach (var task in tasks) body.Children.Add(AsyncButton(task.Title + " · " + task.Status, async () =>
    {
      connectedListDialog?.Hide(); await Task.Yield(); await ConnectedDetailAsync(system, task);
    }));
    if (tasks.Count == 0) body.Children.Add(Words("No open tasks in this system."));
    connectedListDialog = Dialog(XamlRoot, system.Name, body); connectedListDialog.PrimaryButtonText = ""; connectedListDialog.CloseButtonText = "Close";
    await connectedListDialog.ShowAsync(); connectedListDialog = null;
  }
  private ContentDialog? connectedListDialog;
  private async Task ConnectedDetailAsync(ConnectedTaskSystem system, ConnectedTask task)
  {
    System.Text.Json.JsonElement detail = default;
    if (!await Model.RunAsync(async () => detail = await Model.Connected!.GetAsync(system.Id, task.Id), "Task read.")) return;
    var value = detail.TryGetProperty("task", out var nested) ? nested : detail; var row = ConnectedTaskMapping.Task(value);
    var body = Stack(); body.Children.Add(Words(row.Details)); body.Children.Add(Words("Status: " + row.Status, muted: true));
    if (system.AllowChanges)
    {
      var comment = Field("Comment", multiline: true, max: 2000); body.Children.Add(comment);
      var dialog = Dialog(XamlRoot, row.Title, body, "Post comment");
      if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Model.RunAsync(async () => { await Model.Connected!.CommentAsync(system.Id, task.Id, comment.Text); }, "Comment posted.");
    }
    else { var dialog = Dialog(XamlRoot, row.Title, body); dialog.PrimaryButtonText = ""; dialog.CloseButtonText = "Close"; await dialog.ShowAsync(); }
  }
  internal static string? Empty(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}
