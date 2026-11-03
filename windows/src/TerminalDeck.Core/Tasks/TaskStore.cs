using System.Collections.Immutable;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tasks;

// Keeper and foreground task edits share one durable ledger. A write reloads
// under the same cross-process lock before checking reservations or revisions.
// Save succeeds before the visible state changes, including the delivery outbox.
public sealed class TaskStore
{
  private readonly object gate = new();
  private readonly IStateStore<TasksState> persistence;
  private TasksState state;
  public TaskStore(IStateStore<TasksState> persistence)
  {
    this.persistence = persistence;
    using var lease = AcquireFileLease();
    state = Load();
  }
  private TasksState Load()
  {
    var state = persistence.Load() ?? new(1, [], [], [], ImmutableDictionary<string, TaskFilter>.Empty);
    if (state.Version is not (1 or 2 or 3 or 4) || state.Tasks.IsDefault || state.Runs.IsDefault || state.Mentions.IsDefault || state.Filters is null ||
      state.Tasks.Select(t => t.Id).Distinct().Count() != state.Tasks.Length || state.Runs.Select(t => t.Id).Distinct().Count() != state.Runs.Length ||
      state.Tasks.Any(t => t.Comments.IsDefault || t.Activity.IsDefault || t.Labels.IsDefault || t.Revision < 1 || t.Type is not ("Task" or "Milestone") || !TaskStatuses.All.Contains(t.Status)) ||
      state.Mentions.Select(m => m.Id).Distinct().Count() != state.Mentions.Length ||
      state.Runs.Any(r => !Enum.IsDefined(r.State) || !state.Tasks.Any(t => t.Id == r.TaskId)) ||
      state.Tasks.Any(t => t.CurrentRunId is { } id && !state.Runs.Any(r => r.Id == id && r.TaskId == t.Id)) ||
      state.Mentions.Any(m => !state.Tasks.Any(t => t.Id == m.TaskId && t.Comments.Any(c => c.Id == m.CommentId))))
      throw new IOException("The saved tasks could not be read safely. The file was kept.");
    foreach (var task in state.Tasks)
    {
      var participants = TaskExtras.Of(task).Participants;
      if (participants.Length > 100 || participants.Any(id => string.IsNullOrWhiteSpace(id) || id.Length > 200 || id.Any(char.IsControl) || id == "none" || id == task.Assignee) ||
        participants.Distinct(StringComparer.Ordinal).Count() != participants.Length || task.Assignee == "none" && participants.Length > 0)
        throw new IOException("The saved task people could not be read safely. The file was kept.");
    }
    var goals = state.Goals.IsDefault ? [] : state.Goals;
    if (goals.Select(g => g.Id).Distinct().Count() != goals.Length || goals.Any(g => string.IsNullOrWhiteSpace(g.Id) || string.IsNullOrWhiteSpace(g.Title) || g.Status is not ("planned" or "active" or "achieved" or "cancelled")) ||
      state.Tasks.Any(t => t.GoalId is not null && !goals.Any(g => g.Id == t.GoalId && g.ProjectId == t.ProjectId))) throw new IOException("The saved goals could not be read safely. The file was kept.");
    var byId = goals.ToDictionary(g => g.Id); var complete = new HashSet<string>();
    foreach (var goal in goals)
    {
      var seen = new HashSet<string>(); var current = goal;
      while (!complete.Contains(current.Id))
      {
        if (!seen.Add(current.Id)) throw new IOException("The saved goal hierarchy could not be read safely. The file was kept.");
        if (current.ParentId is not { } parent) break;
        if (!byId.TryGetValue(parent, out var next) || next.ProjectId != current.ProjectId) throw new IOException("A saved goal's parent could not be read safely. The file was kept.");
        current = next;
      }
      complete.UnionWith(seen);
    }
    // A previous Keeper must refuse this ledger rather than round-trip it through
    // an older DTO and silently drop goals, view settings or detail fields.
    return state with { Version = 4, Views = state.Views.IsDefault ? [] : state.Views, Goals = goals };
  }
  public TasksState Read()
  {
    lock (gate)
    {
      if (persistence is not JsonStateStore<TasksState>) return state;
      // Windows replacement can race even a delete-sharing reader. Both
      // processes use the ledger lock for the entire read/replace boundary.
      using var lease = AcquireFileLease();
      return Load();
    }
  }
  private IDisposable? AcquireFileLease()
  {
    if (persistence is not JsonStateStore<TasksState> shared) return null;
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    try { return Task.Run(async () => await shared.AcquireWriteAsync(timeout.Token).ConfigureAwait(false)).GetAwaiter().GetResult(); }
    catch (OperationCanceledException) { throw new IOException("Tasks are busy saving another change. Try again in a moment."); }
  }
  public T Change<T>(Func<TasksState, (TasksState State, T Value)> change)
  {
    lock (gate)
    {
      using var lease = AcquireFileLease();
      if (persistence is JsonStateStore<TasksState>) state = Load();
      var next = change(state);
      if (next.State != state) persistence.Save(next.State);
      state = next.State; return next.Value;
    }
  }
  public static TaskStore At(AppDataRoot root) => new(new JsonStateStore<TasksState>(root, "hoot-tasks"));
}
