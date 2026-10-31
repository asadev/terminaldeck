using System.Collections.Immutable;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Tasks;

public static class TaskStatuses
{
  public static readonly ImmutableArray<string> All = ["To-Do", "In Progress", "Working on it", "Stuck", "Done"];
  public static string? Next(string value) => value switch { "To-Do" => "Working on it", "Working on it" or "Stuck" => "In Progress", "In Progress" => "Done", _ => null };
  public static string Require(string value) => All.Contains(value) ? value : throw new ArgumentException("Choose a status from the task list.");
}
public sealed record TaskActor(string Id, string Name, string Kind = "human")
{
  public static TaskActor Owner { get; } = new("me", "You");
  public static TaskActor App { get; } = new("app", "App", "app");
}
public sealed record TaskComment(string Id, TaskActor Author, string Text, DateTimeOffset At, ImmutableArray<string> Mentions, string? ReplyTo = null);
public sealed record TaskActivity(string Id, string Text, TaskActor By, DateTimeOffset At, string Kind = "");
public static class TaskActivityKinds
{
  public static string Of(TaskActivity activity) => activity.Kind.Length > 0 ? activity.Kind : activity.Text.StartsWith("Status:", StringComparison.Ordinal) ? "status"
    : activity.Text.StartsWith("Given to ", StringComparison.Ordinal) || activity.Text.StartsWith("Assigned to ", StringComparison.Ordinal) ? "assignees" : "details";
}
public enum TaskRunState { Starting, Working, NeedsYou, Uncertain, Yielded, Ended }
public sealed record TaskRun(string Id, string TaskId, string AgentId, string Folder, string Mode, TaskRunState State,
  DateTimeOffset StartedAt, string? SessionId = null, string? Problem = null);
public sealed record TaskMention(string Id, string TaskId, string CommentId, string Recipient, string? SessionId = null,
  bool Delivered = false, string? Problem = null, TaskMentionAuthority? Authority = null, string? TargetIdentity = null);
public sealed record TaskMentionAuthority(string Id, string CallerId, string? SessionId, string? SeatId, bool Owner, string ProjectId, string Folder);
// Live permission cannot be reconstructed from saved caller names. A reopened
// outbox stays pending until a new comment explicitly authorizes delivery.
public sealed record TaskMentionAuthorization(string CallerId, string? SessionId, string? SeatId,
  Func<TaskRecipient, CancellationToken, ValueTask> RequireCurrent);
public sealed record ConnectedTaskLink(string SystemId, string TaskId);
public sealed record DeckTask(string Id, string Title, string Details, string ProjectId, string Folder, string Status, string Assignee,
  DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, string? Priority = null, string? StartDate = null, string? DueDate = null,
  ImmutableArray<string> Labels = default, string? Board = null, bool Archived = false, DateTimeOffset? DeletedAt = null,
  ImmutableArray<TaskComment> Comments = default, ImmutableArray<TaskActivity> Activity = default, string? CurrentRunId = null,
  bool NeedsYou = false, ConnectedTaskLink? Connected = null, long Revision = 1, string Type = "Task", string? GoalId = null, string? StartTime = null, string? DueTime = null, TaskExtras? Extras = null);
public sealed record TaskDraft(string Title, string Details = "", string ProjectId = ProjectIdentity.IndependentId, string? Folder = null,
  string Status = "To-Do", string Assignee = "me", string? Priority = null, string? StartDate = null, string? DueDate = null,
  ImmutableArray<string> Labels = default, string? Board = null, string Type = "Task", string? GoalId = null, string? StartTime = null, string? DueTime = null);
public sealed record TaskFilter(string? ProjectId = null, string Search = "", string Status = "open", string Assignee = "",
  string GroupBy = "date", bool Archived = false, bool Trash = false, string? Source = null,
  string Due = "any", string Sort = "automatic", bool Descending = false, string View = "List",
  [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] ImmutableArray<string> Columns = default,
  [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] ImmutableArray<string> ColumnOrder = default, string? GoalId = null,
  [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] ImmutableArray<string> ProjectIds = default,
  [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] ImmutableArray<string> Statuses = default,
  [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)] ImmutableArray<string> Assignees = default, bool NeedsYouOnly = false);
public sealed record SavedTaskView(string Id, string Machine, string Name, TaskFilter State);
public sealed record TasksState(int Version, ImmutableArray<DeckTask> Tasks, ImmutableArray<TaskRun> Runs,
  ImmutableArray<TaskMention> Mentions, ImmutableDictionary<string, TaskFilter> Filters, ImmutableArray<SavedTaskView> Views = default, ImmutableArray<DeckGoal> Goals = default);
public sealed record TaskPreparedSession(string SessionId, string ProjectId, string Folder, string AccountId, string AgentId);
public sealed record TaskLaunch(DeckTask Task, string RunId, string AgentId, string Mode, string Brief, TaskActor? AssignedBy = null);
public interface ITaskRunner
{
  bool CanStart(string mode);
  ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken cancellationToken);
  ValueTask NotifyAsync(string sessionId, string text, CancellationToken cancellationToken);
}
public interface ITaskBriefFiles { string Save(string taskId, string runId, string text); }
public interface ITasks
{
  event Action? Changed;
  IReadOnlyList<DeckTask> List(TaskFilter? filter = null);
  DeckTask Get(string id, bool includeTrash = false);
  TaskFilter Filter(string machine);
  void RememberFilter(string machine, TaskFilter filter);
  IReadOnlyList<DeckGoal> Goals(string? projectId = null);
  DeckGoal SaveGoal(GoalDraft draft, TaskActor by, string? id = null, long? expectedRevision = null);
  void DeleteGoal(string id, TaskActor by);
  IReadOnlyList<SavedTaskView> Views(string machine);
  SavedTaskView SaveView(string machine, string? id, string name, TaskFilter state);
  void DeleteView(string machine, string id);
  DeckTask Duplicate(string id, TaskActor by, string? title = null);
  DeckTask Create(TaskDraft draft, TaskActor by, ConnectedTaskLink? connected = null);
  DeckTask Update(string id, TaskDraft draft, TaskActor by, long? expectedRevision = null);
  // share/unshare/share-primary take a local recipient ID in value; these
  // change participation only. AssignAsync is the separate work-launch action.
  DeckTask Detail(string id, string action, string? key, string? value, TaskActor by);
  DeckTask Status(string id, string status, TaskActor by);
  DeckTask Archive(string id, bool archived, TaskActor by);
  DeckTask Delete(string id, TaskActor by);
  DeckTask Restore(string id, TaskActor by);
  ValueTask<DeckTask> AssignAsync(string id, string assignee, TaskActor by, string mode = "chat", CancellationToken cancellationToken = default,
    Func<CancellationToken, ValueTask>? beforeStart = null, Func<TaskPreparedSession, CancellationToken, ValueTask>? authorizeStart = null);
  ValueTask<TaskComment> CommentAsync(string id, string text, TaskActor by, string? replyTo = null, CancellationToken cancellationToken = default, TaskMentionAuthorization? authorization = null);
  IReadOnlyList<TaskRun> Runs(string? taskId = null);
  IReadOnlyList<TaskMention> Mentions(string? taskId = null);
  ValueTask DeliverMentionsAsync(string taskId, CancellationToken cancellationToken = default);
  void ObserveSession(string sessionId, bool ended, bool needsYou, string? message = null);
  bool CanRun(string mode);
}
