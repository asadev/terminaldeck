using System.Collections.Immutable;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.ViewModels.Tasks;

public sealed record TaskGroup(string Key, string Label, IReadOnlyList<DeckTask> Rows, string? Tag = null);

public sealed class TasksViewModel : IDisposable
{
  public ITasks Tasks { get; }
  public IProjects Projects { get; }
  public ConnectedTasksService? Connected { get; }
  public Func<IReadOnlyList<TaskRecipient>> People { get; }
  public string Machine { get; }
  public string? SelectedId { get; private set; }
  public bool Busy { get; private set; }
  public bool Failed { get; private set; }
  public string Message { get; private set; } = "";
  public bool EditingTitle { get; private set; }
  public string TitleDraft { get; set; } = "";
  private long titleRevision;
  public void BeginRename(DeckTask task) { EditingTitle = true; TitleDraft = task.Title; titleRevision = task.Revision; Changed?.Invoke(); }
  public void CancelRename() { EditingTitle = false; TitleDraft = ""; Changed?.Invoke(); }
  public Task<bool> RenameAsync()
  {
    var id = SelectedId ?? throw new InvalidOperationException("Open a task first.");
    var title = TitleDraft; var revision = titleRevision;
    return RunAsync(() =>
    {
      var task = Tasks.Get(id); Tasks.Update(id, TaskService.Draft(task) with { Title = title }, TaskActor.Owner, revision);
      if (SelectedId == id && TitleDraft == title) { EditingTitle = false; TitleDraft = ""; }
      return Task.CompletedTask;
    }, "Name saved.");
  }
  public string CommentDraft { get; set; } = "";
  public string? ReplyTo { get; set; }
  public string ThreadPane { get; set; } = "Comments";
  public string ActivityCategory { get; set; } = "all";
  public string ThreadSearch { get; set; } = "";
  public bool ThreadSearchOpen { get; set; }
  public bool TaskThreadOpen { get; set; } = true;
  public bool HideEmptyFields { get; set; }
  public string Sort { get => Filter.Sort; set => Filters(Filter with { Sort = value }); }
  public bool Descending { get => Filter.Descending; set => Filters(Filter with { Descending = value }); }
  public IReadOnlySet<string> Columns => TaskPresentation.Columns(Filter).ToHashSet();
  public IReadOnlyList<string> ColumnOrder => TaskPresentation.Order(Filter);
  public string? SelectedViewId { get; set; }
  public SavedTaskView? SavedView => Tasks.Views(Machine).FirstOrDefault(v => v.Id == SelectedViewId);
  public bool ViewChanged => SavedView is { } saved && !TaskPresentation.Same(saved.State, Filter);
  public void Column(string key, bool visible) => Filters(Filter with { Columns = visible ? TaskPresentation.Columns(Filter).Add(key).Distinct().ToImmutableArray() : TaskPresentation.Columns(Filter).Remove(key) });
  public void MoveColumn(string key, int direction)
  {
    var order = TaskPresentation.Order(Filter).ToArray(); var at = Array.IndexOf(order, key); var to = at + direction;
    if (at < 0 || to < 0 || to >= order.Length) return;
    (order[at], order[to]) = (order[to], order[at]); Filters(Filter with { ColumnOrder = order.ToImmutableArray() });
  }
  public void SelectView(string? id) { SelectedViewId = id; if (SavedView is { } saved) Filters(saved.State); else Changed?.Invoke(); }
  public void PresentationChanged() => Changed?.Invoke();
  public void Notice(string message) { Message = message; Failed = false; Changed?.Invoke(); }
  public event Action? Changed;
  public TasksViewModel(ITasks tasks, IProjects projects, string machine, Func<IReadOnlyList<TaskRecipient>> people, ConnectedTasksService? connected = null)
  {
    Tasks = tasks; Projects = projects; Machine = machine; People = people; Connected = connected;
    tasks.Changed += OnChanged; projects.Changed += OnChanged; if (connected is not null) connected.Changed += OnChanged;
  }
  public TaskFilter Filter => Tasks.Filter(Machine);
  public string? ProjectScope { get { var filter = Filter; return filter.ProjectIds.IsDefaultOrEmpty ? filter.ProjectId : filter.ProjectIds.Length == 1 ? filter.ProjectIds[0] : null; } }
  public IReadOnlyList<DeckTask> Rows => Ordered(Tasks.List(Filter));
  public IReadOnlyList<DeckTask> Ordered(IEnumerable<DeckTask> rows)
  {
    var ordered = Sort switch
    {
      "name" => rows.OrderBy(t => t.Title, StringComparer.CurrentCultureIgnoreCase),
      "created" => rows.OrderBy(t => t.CreatedAt),
      "priority" => rows.OrderBy(t => Array.IndexOf(new[] { "Critical", "High", "Medium", "Low", "" }, t.Priority ?? "")),
      "due" => rows.OrderBy(t => (t.DueDate ?? "9999") + " " + (t.DueTime ?? "99:99"), StringComparer.Ordinal),
      _ => rows
    };
    return (Descending ? ordered.Reverse() : ordered).ToArray();
  }
  public DeckTask? Selected => SelectedId is { } id ? Tasks.Get(id, includeTrash: true) : null;
  public void Select(string? id, bool keepFeedback = false) { SelectedId = id; EditingTitle = false; TitleDraft = ""; CommentDraft = ""; ReplyTo = null; ThreadSearch = ""; if (!keepFeedback) Message = ""; Changed?.Invoke(); }
  public void Filters(TaskFilter filter) => Tasks.RememberFilter(Machine, filter);
  public async Task<bool> RunAsync(Func<Task> action, string success)
  {
    if (Busy) return false;
    Busy = true; Failed = false; Message = "Working…"; Changed?.Invoke();
    try { await action(); Message = success; return true; }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // Provider and transport exceptions can include protected addresses or text.
      Failed = true; Message = ex is ArgumentException || ex is InvalidOperationException && ex.GetType() == typeof(InvalidOperationException)
        ? ex.Message : "The task action could not finish. Your task is kept; check its details and try again.";
      return false;
    }
    finally { Busy = false; Changed?.Invoke(); }
  }
  public Task<bool> CommentAsync()
  {
    var id = SelectedId ?? throw new InvalidOperationException("Open a task first.");
    var text = CommentDraft; var reply = ReplyTo;
    return RunAsync(async () =>
    {
      await Tasks.CommentAsync(id, text, TaskActor.Owner, reply);
      if (SelectedId == id && CommentDraft == text) { CommentDraft = ""; ReplyTo = null; }
    }, "Comment added.");
  }
  public string Assignee(DeckTask row) => row.Assignee switch
  {
    "me" => "Me", "none" => "Unassigned", _ => People().FirstOrDefault(p => p.Id == row.Assignee)?.Name ?? row.Assignee
  };
  public string CommentText(string text)
  {
    // Keep stable recipient IDs on disk; display the current person's name.
    foreach (var person in People()) text = text.Replace("@[" + person.Id + "]", "@" + person.Name, StringComparison.Ordinal);
    return text;
  }
  public string Group(DeckTask row) => Filter.GroupBy switch
  {
    "status" => row.Status, "priority" => row.Priority ?? "No priority", "project" => Projects.Get(row.ProjectId).Name,
    "date" or "due" => DateGroup(row, Filter.Status != "all"), _ => "Tasks"
  };
  public IReadOnlyList<TaskGroup> Groups(IEnumerable<DeckTask> source)
  {
    var rows = source.ToArray(); var done = Filter.Status == "open" ? rows.Where(t => t.Status == "Done").ToArray() : [];
    var open = Filter.Status == "open" ? rows.Where(t => t.Status != "Done").ToArray() : rows;
    IEnumerable<TaskGroup> groups;
    if (Filter.GroupBy == "tags")
    {
      var tags = open.SelectMany(t => t.Labels).Distinct(StringComparer.Ordinal).Order(StringComparer.CurrentCultureIgnoreCase);
      groups = tags.Select(tag => new TaskGroup("tag:" + tag, tag, open.Where(t => t.Labels.Contains(tag)).ToArray(), tag));
      var untagged = open.Where(t => t.Labels.IsEmpty).ToArray(); if (untagged.Length > 0) groups = groups.Append(new("untagged", "No tags", untagged));
    }
    else
    {
      string Key(DeckTask row) => Filter.GroupBy switch { "assignee" => row.Assignee, "board" => row.Board ?? "", "type" => row.Type, "project" => row.ProjectId, _ => Group(row) };
      string Label(DeckTask row) => Filter.GroupBy switch { "assignee" => Assignee(row), "board" => row.Board ?? "No board", "type" => row.Type, _ => Group(row) };
      groups = open.GroupBy(Key).Select(g => new TaskGroup(g.Key, Label(g.First()), g.ToArray()));
    }
    if (done.Length > 0) groups = groups.Append(new("closed", "Done", done));
    return groups.OrderBy(g => GroupOrder(g.Label)).ToArray();
  }
  public static string DateGroup(DeckTask row, bool separateClosed = true)
  {
    if (separateClosed && row.Status == "Done") return "Done";
    if (!DateOnly.TryParseExact(row.DueDate, "yyyy-MM-dd", out var due)) return "Unscheduled";
    var today = DateOnly.FromDateTime(DateTime.Today);
    if (due < today || TaskDates.Overdue(row, DateTimeOffset.Now)) return "Overdue";
    if (due == today) return "Today";
    var mondayOffset = ((int)today.DayOfWeek + 6) % 7;
    return due <= today.AddDays(13 - mondayOffset) ? "Next" : "Later";
  }
  public int GroupOrder(string group) => group == "Done" ? int.MaxValue : Filter.GroupBy switch
  {
    "date" or "due" => Array.IndexOf(new[] { "Overdue", "Today", "Next", "Later", "Unscheduled", "Done" }, group),
    "status" => TaskStatuses.All.IndexOf(group),
    "priority" => Array.IndexOf(new[] { "Critical", "High", "Medium", "Low", "No priority" }, group), _ => 0
  };
  public static string DueLabel(DeckTask row)
  {
    if (!DateOnly.TryParseExact(row.DueDate, "yyyy-MM-dd", out var due)) return "—";
    var today = DateOnly.FromDateTime(DateTime.Today);
    var label = due == today ? "Today" : due == today.AddDays(1) ? "Tomorrow" : due == today.AddDays(-1) ? "Yesterday"
      : due.ToString(due.Year == today.Year ? "d MMM" : "d MMM yyyy");
    return label + (row.DueTime is null ? "" : " · " + row.DueTime);
  }
  public static string CreatedLabel(DeckTask row)
  {
    var created = DateOnly.FromDateTime(row.CreatedAt.LocalDateTime); var today = DateOnly.FromDateTime(DateTime.Today);
    return created == today ? "Today" : created == today.AddDays(-1) ? "Yesterday" : created.ToString(created.Year == today.Year ? "MMM d" : "MMM d, yyyy");
  }
  private void OnChanged() => Changed?.Invoke();
  public void Dispose() { Tasks.Changed -= OnChanged; Projects.Changed -= OnChanged; if (Connected is not null) Connected.Changed -= OnChanged; }
}
