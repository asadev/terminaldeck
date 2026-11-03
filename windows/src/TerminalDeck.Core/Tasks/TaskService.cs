using System.Collections.Immutable;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Tasks;

public sealed record TaskRecipient(string Id, string Name, string Kind, string? SessionId, string? Identity = null, string Icon = "person")
{
  public string CanonicalIdentity => Identity ?? Id;
}

public static class TaskMentionPolicy
{
  public static void RequireNotSelf(TaskActor actor, string? initiatingSession, TaskRecipient target)
  {
    if (actor.Kind == "hoot" && (target.CanonicalIdentity == "hoot" ||
      initiatingSession is not null && target.SessionId == initiatingSession))
      throw new InvalidOperationException("Hoot cannot send a task mention to itself. Ask the person in the task comments instead.");
  }
}

public sealed partial class TaskService : ITasks
{
  private sealed class MentionPending(string message) : InvalidOperationException(message);
  private readonly TaskStore store;
  private readonly IProjects projects;
  private readonly ITaskRunner? runner;
  private readonly Func<string, TaskRecipient?> recipient;
  private readonly ITaskBriefFiles? files;
  private readonly TimeProvider clock;
  private readonly SemaphoreSlim deliveries = new(1);
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, TaskMentionAuthorization> mentionAuthorities = new();
  public event Action? Changed;
  public TaskService(TaskStore store, IProjects projects, Func<string, TaskRecipient?> recipient,
    ITaskRunner? runner = null, ITaskBriefFiles? files = null, TimeProvider? clock = null, bool recoverStarts = true)
  {
    this.store = store; this.projects = projects; this.recipient = recipient; this.runner = runner; this.files = files;
    this.clock = clock ?? TimeProvider.System;
    if (recoverStarts) RecoverStarts();
    projects.SetRemovalGuard("tasks", id =>
    {
      var current = store.Read();
      if (current.Tasks.Any(t => t.ProjectId == id) || current.Goals.Any(g => g.ProjectId == id))
        throw new InvalidOperationException("This project still owns tasks or goals. Keep it registered or move that work first.");
    });
  }
  public bool CanRun(string mode) => runner?.CanStart(mode) == true;
  public DeckTask Get(string id, bool includeTrash = false) => Find(store.Read(), id, includeTrash);
  public IReadOnlyList<DeckTask> List(TaskFilter? filter = null)
  {
    var f = filter ?? new(); ValidateFilter(f);
    var snapshot = store.Read(); var goalIds = f.GoalId is { } goalId ? TaskGoalTree.Descendants(snapshot.Goals, goalId) : null;
    return snapshot.Tasks.Where(t => (t.DeletedAt is not null) == f.Trash && (f.Trash || t.Archived == f.Archived) &&
      (f.ProjectIds.IsDefaultOrEmpty ? f.ProjectId is null || t.ProjectId == f.ProjectId : f.ProjectIds.Contains(t.ProjectId)) && (goalIds is null || t.GoalId is { } goal && goalIds.Contains(goal)) && (f.Source is null || t.Connected?.SystemId == f.Source) &&
      (f.Statuses.IsDefaultOrEmpty ? f.Status switch { "all" => true, "open" => t.Status != "Done", "needs-you" => t.NeedsYou || t.Status == "Stuck", _ => t.Status == f.Status } : f.Statuses.Contains(t.Status)) &&
      (f.Assignees.IsDefaultOrEmpty ? AssigneeMatches(t, f.Assignee) : f.Assignees.Any(a => AssigneeMatches(t, a))) &&
      (!f.NeedsYouOnly || t.NeedsYou || t.Status == "Stuck") && (DueMatches(t, f.Due)) &&
      (f.Search.Length == 0 || string.Join(' ', t.Title, t.Details, t.Board, string.Join(' ', t.Labels)).Contains(f.Search, StringComparison.OrdinalIgnoreCase)))
      .OrderBy(t => t.Status == "Done").ThenBy(t => t.DueDate ?? "9999-99-99").ThenByDescending(t => t.UpdatedAt).ToArray();
  }
  public TaskFilter Filter(string machine) { Key(machine); return NormalizeFilter(store.Read().Filters.GetValueOrDefault(machine) ?? new()); }
  public void RememberFilter(string machine, TaskFilter filter)
  {
    Key(machine); filter = NormalizeFilter(filter); ValidateFilter(filter);
    store.Change(s => (s with { Filters = s.Filters.SetItem(machine, filter) }, true)); Changed?.Invoke();
  }
  public IReadOnlyList<SavedTaskView> Views(string machine) { Key(machine); return store.Read().Views.Where(v => v.Machine == machine).Select(v => v with { State = NormalizeFilter(v.State) }).ToArray(); }
  public SavedTaskView SaveView(string machine, string? id, string name, TaskFilter view)
  {
    Key(machine); view = NormalizeFilter(view); ValidateFilter(view); Text(name, 80, "Use a view name within 80 characters.");
    if (string.IsNullOrWhiteSpace(name) || name.Any(char.IsControl)) throw new ArgumentException("Give the view a name.");
    var saved = store.Change(s =>
    {
      var old = id is null ? null : s.Views.FirstOrDefault(v => v.Machine == machine && v.Id == id) ?? throw new ArgumentException("Choose a saved view from this computer.");
      var row = new SavedTaskView(old?.Id ?? Guid.NewGuid().ToString("N"), machine, name.Trim(), view);
      return (s with { Views = old is null ? s.Views.Add(row) : s.Views.Replace(old, row) }, row);
    }); Changed?.Invoke(); return saved;
  }
  public void DeleteView(string machine, string id)
  {
    Key(machine); store.Change(s =>
    {
      var old = s.Views.FirstOrDefault(v => v.Machine == machine && v.Id == id) ?? throw new ArgumentException("Choose a saved view from this computer.");
      return (s with { Views = s.Views.Remove(old) }, true);
    }); Changed?.Invoke();
  }
  private bool DueMatches(DeckTask task, string filter)
  {
    if (filter == "any") return true;
    if (filter == "none") return task.DueDate is null;
    if (!DateOnly.TryParseExact(task.DueDate, "yyyy-MM-dd", out var due)) return false;
    var today = DateOnly.FromDateTime(clock.GetLocalNow().DateTime);
    return filter switch { "today" => due == today, "overdue" => TaskDates.Overdue(task, clock.GetLocalNow()), "week" => due >= today && due <= today.AddDays(7), _ => false };
  }
  public DeckTask Duplicate(string id, TaskActor by, string? title = null)
  {
    var source = Get(id);
    return Create(Draft(source) with { Title = title ?? source.Title[..Math.Min(235, source.Title.Length)] + " copy", Status = "To-Do", Assignee = "none" }, by);
  }
  public DeckTask Create(TaskDraft draft, TaskActor by, ConnectedTaskLink? connected = null)
  {
    var d = Validate(draft); ValidateActor(by);
    if (d.Assignee is not ("me" or "none")) throw new ArgumentException("Create the task first, then give it to an agent.");
    var now = clock.GetUtcNow();
    var row = new DeckTask("local:" + Guid.NewGuid().ToString("N"), d.Title.Trim(), d.Details, d.ProjectId, d.Folder!, d.Status, d.Assignee,
      now, now, d.Priority, d.StartDate, d.DueDate, d.Labels, d.Board, Comments: [], Activity: [Activity("Created the task.", by)], NeedsYou: d.Status == "Stuck", Connected: connected, Type: d.Type, GoalId: d.GoalId, StartTime: d.StartTime, DueTime: d.DueTime);
    store.Change(s =>
    {
      GoalReference(s, d.ProjectId, d.GoalId);
      if (connected is not null)
      {
        Key(connected.SystemId); Key(connected.TaskId);
        if (s.Tasks.Any(t => t.Connected == connected && t.DeletedAt is null)) throw new InvalidOperationException("This connected task already has a local task.");
      }
      return (s with { Tasks = s.Tasks.Add(row) }, true);
    }); Changed?.Invoke(); return row;
  }
  public DeckTask Update(string id, TaskDraft draft, TaskActor by, long? expectedRevision = null)
  {
    var d = Validate(draft);
    return Change(id, by, "Updated the task.", (s, old) =>
    {
      GoalReference(s, d.ProjectId, d.GoalId);
      if (expectedRevision is not null && old.Revision != expectedRevision) throw new InvalidOperationException("This task changed. Reload it before saving your edits.");
      if (d.Assignee != old.Assignee) throw new ArgumentException("Use Assign to change who has this task.");
      if (Active(s, old) && (d.ProjectId != old.ProjectId || !SameFolder(d.Folder!, old.Folder) || d.Status == "Done"))
        throw new InvalidOperationException("Wait for this task's session to finish before moving or closing it.");
      return old with { Title = d.Title.Trim(), Details = d.Details, ProjectId = d.ProjectId, Folder = d.Folder!, Status = d.Status,
        Priority = d.Priority, StartDate = d.StartDate, DueDate = d.DueDate, Labels = d.Labels, Board = d.Board, Type = d.Type, GoalId = d.GoalId, StartTime = d.StartTime, DueTime = d.DueTime, NeedsYou = d.Status == "Stuck" || old.NeedsYou && d.Status != "Done" };
    });
  }
  public DeckTask Status(string id, string status, TaskActor by)
  {
    TaskStatuses.Require(status);
    return Change(id, by, "Status: " + status + ".", (s, row) =>
    {
      if (status == "Done" && Active(s, row)) throw new InvalidOperationException("Wait for this task's session to finish before closing it.");
      return row with { Status = status, NeedsYou = status == "Stuck" };
    });
  }
  public DeckTask Archive(string id, bool archived, TaskActor by) => Change(id, by, archived ? "Archived the task." : "Restored from the archive.", (s, row) =>
  {
    if (Active(s, row)) throw new InvalidOperationException("Wait for this task's session to finish before archiving it.");
    return row with { Archived = archived };
  });
  public DeckTask Delete(string id, TaskActor by) => Change(id, by, "Moved to Trash.", (s, row) =>
  {
    if (Active(s, row)) throw new InvalidOperationException("Wait for this task's session to finish before moving it to Trash.");
    return row with { DeletedAt = clock.GetUtcNow() };
  });
  public DeckTask Restore(string id, TaskActor by) => Change(id, by, "Restored from Trash.", (_, row) => row with { DeletedAt = null }, trash: true);
  public IReadOnlyList<TaskRun> Runs(string? taskId = null) => store.Read().Runs.Where(r => taskId is null || r.TaskId == taskId).ToArray();
  public IReadOnlyList<TaskMention> Mentions(string? taskId = null) => store.Read().Mentions.Where(m => taskId is null || m.TaskId == taskId).ToArray();
  public async ValueTask<DeckTask> AssignAsync(string id, string assignee, TaskActor by, string mode = "chat", CancellationToken cancellationToken = default,
    Func<CancellationToken, ValueTask>? beforeStart = null, Func<TaskPreparedSession, CancellationToken, ValueTask>? authorizeStart = null)
  {
    ValidateActor(by); cancellationToken.ThrowIfCancellationRequested();
    var target = RequireRecipient(assignee);
    if (assignee is "me" or "none") return Change(id, by, "Assigned to " + target.Name + ".", (s, row) =>
    {
      if (Active(s, row)) throw new InvalidOperationException("This task still has a session. Wait for it to finish before reassigning it.");
      return row with { Assignee = assignee };
    });
    if (!CanRun(mode)) throw new InvalidOperationException("Task sessions are not connected for this mode.");
    var initial = Get(id); if (initial.Folder.Length == 0) throw new InvalidOperationException("Choose a project folder before running this task.");
    if (initial.Status == "Done" || initial.Archived) throw new InvalidOperationException("Reopen this task before running it.");
    var runId = Guid.NewGuid().ToString("N");
    var brief = ShortBrief(TaskBrief.Compose(initial, projects.Get(initial.ProjectId).Name, by.Name), initial.Id, runId);
    var run = new TaskRun(runId, id, assignee, initial.Folder, mode, TaskRunState.Starting, clock.GetUtcNow());
    var assigned = store.Change(s =>
    {
      var old = Find(s, id);
      if (old.Revision != initial.Revision) throw new InvalidOperationException("The task changed. Read it again before starting it.");
      if (Active(s, old) || s.Runs.Any(r => HoldsFolder(r) && SameFolder(r.Folder, old.Folder)))
        throw new InvalidOperationException("An agent is already working on a task in this folder. Wait for it to finish.");
      var row = Stamp(old with { Assignee = assignee, Status = "Working on it", NeedsYou = false, CurrentRunId = runId }, "Given to " + target.Name + ".", by, old);
      return (s with { Tasks = s.Tasks.Replace(old, row), Runs = s.Runs.Add(run) }, row);
    });
    Changed?.Invoke();
    var prepared = false;
    try
    {
      if (beforeStart is not null) await beforeStart(cancellationToken);
      var session = await runner!.StartAsync(new(assigned, runId, assignee, mode, brief, by), async (plan, ct) =>
      {
        var sid = plan.SessionId;
        if (authorizeStart is not null) await authorizeStart(plan, ct);
        if (beforeStart is not null) await beforeStart(ct);
        ct.ThrowIfCancellationRequested();
        store.Change(s =>
        {
          var current = s.Runs.Single(r => r.Id == runId);
          if (current.SessionId is not null && current.SessionId != sid) throw new InvalidOperationException("This start returned a different session.");
          return (s with { Runs = s.Runs.Replace(current, current with { SessionId = sid }) }, true);
        });
        prepared = true;
      }, cancellationToken);
      store.Change(s =>
      {
        var current = s.Runs.Single(r => r.Id == runId);
        if (current.SessionId != session) throw new InvalidOperationException("The session start was not confirmed.");
        return (s with { Runs = s.Runs.Replace(current, current with { State = current.State == TaskRunState.Starting ? TaskRunState.Working : current.State }) }, true);
      });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      store.Change(s =>
      {
        var current = s.Runs.Single(r => r.Id == runId); var old = Find(s, id);
        if (current.State is TaskRunState.Ended or TaskRunState.Yielded or TaskRunState.NeedsYou) return (s, false);
        // The agent service's own refusals are written for people; show which check failed.
        var problem = prepared ? "The session start could not be confirmed. Check its session before starting again."
          : ex is ArgumentException or TerminalDeck.Core.Mcp.McpRefusal or TerminalDeck.Core.Accounts.SignInRequiredException && ex.Message.Length is > 0 and <= 300 ? "The task could not start: " + ex.Message
          : "The task could not start. Check the agent and account, then assign it again.";
        var row = Stamp(old with { Status = "Stuck", NeedsYou = true }, problem, TaskActor.App, old);
        return (s with { Runs = s.Runs.Replace(current, current with { State = prepared ? TaskRunState.Uncertain : TaskRunState.Ended, Problem = problem }), Tasks = s.Tasks.Replace(old, row) }, true);
      });
      Changed?.Invoke();
      if (ex is OperationCanceledException) throw;
      throw new InvalidOperationException("The task could not start. Its details show what to check.");
    }
    Changed?.Invoke(); return Get(id);
  }
  public async ValueTask<TaskComment> CommentAsync(string id, string text, TaskActor by, string? replyTo = null, CancellationToken cancellationToken = default, TaskMentionAuthorization? authorization = null)
  {
    ValidateActor(by); Text(text, 40000, "Write a comment of up to 40,000 characters.");
    if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("Write a comment first.");
    cancellationToken.ThrowIfCancellationRequested();
    var mentioned = MentionPattern().Matches(text).Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).Distinct(StringComparer.Ordinal).ToImmutableArray();
    var targets = mentioned.ToDictionary(name => name, RequireRecipient);
    foreach (var target in targets.Values) TaskMentionPolicy.RequireNotSelf(by, authorization?.SessionId, target);
    var source = Get(id);
    var authority = new TaskMentionAuthority(Guid.NewGuid().ToString("N"), authorization?.CallerId ?? by.Id, authorization?.SessionId,
      authorization?.SeatId, authorization is null && by == TaskActor.Owner, source.ProjectId, source.Folder);
    if (authorization is not null) mentionAuthorities[authority.Id] = authorization;
    var comment = new TaskComment(Guid.NewGuid().ToString("N"), by, text, clock.GetUtcNow(), mentioned, replyTo);
    store.Change(s =>
    {
      var old = Find(s, id);
      if (replyTo is not null && !old.Comments.Any(c => c.Id == replyTo)) throw new ArgumentException("Choose a comment on this task to reply to.");
      var row = Stamp(old with { Comments = old.Comments.Add(comment) }, "Added a comment.", by);
      var outbox = mentioned.Where(m => m is not ("me" or "none") && m != by.Id)
        .Select(m => new TaskMention(comment.Id + ":" + m, id, comment.Id, m, targets[m].SessionId, Authority: authority, TargetIdentity: targets[m].CanonicalIdentity));
      return (s with { Tasks = s.Tasks.Replace(old, row), Mentions = s.Mentions.AddRange(outbox) }, true);
    });
    Changed?.Invoke(); await DeliverMentionsAsync(id, cancellationToken); return comment;
  }
  public async ValueTask DeliverMentionsAsync(string taskId, CancellationToken cancellationToken = default)
  {
    await deliveries.WaitAsync(cancellationToken);
    try
    {
      foreach (var note in Mentions(taskId).Where(m => !m.Delivered))
      {
        var task = Get(taskId); var comment = task.Comments.Single(c => c.Id == note.CommentId);
        var target = recipient(note.Recipient);
        var session = note.SessionId ?? target?.SessionId;
        var pinnedSession = note.SessionId;
        try
        {
          if (note.Authority is not { } origin || note.TargetIdentity is null)
            throw new MentionPending("This saved mention has no delivery permission. Post the mention again to authorize it.");
          if (task.ProjectId != origin.ProjectId || !string.Equals(task.Folder, origin.Folder, StringComparison.OrdinalIgnoreCase))
            throw new MentionPending("The task moved outside this mention's approved project or folder. Post the mention again.");
          if (target is null || runner is null || session is null)
          { SaveMention(note with { Problem = "Waiting for a running session for this agent." }); continue; }
          if (target.CanonicalIdentity != note.TargetIdentity || target.SessionId != session)
            throw new MentionPending("This mention's approved destination changed. Post the mention again for the new session.");
          try { TaskMentionPolicy.RequireNotSelf(new(origin.CallerId, origin.CallerId, origin.SeatId == TerminalDeck.Core.Hoot.HootDesk.Seat || comment.Author.Kind == "hoot" ? "hoot" : "agent"), origin.SessionId, target); }
          catch (InvalidOperationException) { throw new MentionPending("Hoot cannot send a task mention to itself. Ask the person in the task comments instead."); }
          async ValueTask RecheckAuthority()
          {
            if (origin.Owner) return;
            if (!mentionAuthorities.TryGetValue(origin.Id, out var live))
              throw new MentionPending("The original caller is no longer connected. Post the mention again to authorize delivery.");
            try { await live.RequireCurrent(target, cancellationToken); }
            catch (Exception ex) when (ex is not OutOfMemoryException && ex is not OperationCanceledException)
            { throw new MentionPending("The original caller's delivery permission expired or changed. Post the mention again with current access."); }
          }
          await RecheckAuthority();
          cancellationToken.ThrowIfCancellationRequested();
          // Pin before the sink so a lost receipt retries the same destination.
          pinnedSession = session;
          SaveMention(note with { SessionId = session });
          var text = ShortBrief($"Task id: {task.Id}\nComment id: {comment.Id}\n{comment.Author.Name} mentioned you in {task.Title}:\n\n{comment.Text}\n\nReply in this task's comments.", task.Id, comment.Id);
          // Saving a long brief may take time. Check again after all preparation,
          // directly before the structured-chat boundary performs any delivery.
          await RecheckAuthority();
          var latest = Get(taskId); var destination = recipient(note.Recipient);
          if (latest.ProjectId != origin.ProjectId || !string.Equals(latest.Folder, origin.Folder, StringComparison.OrdinalIgnoreCase) ||
            destination?.CanonicalIdentity != note.TargetIdentity || destination?.SessionId != session)
            throw new MentionPending("This mention's task or destination changed before delivery. Post the mention again.");
          await runner.NotifyAsync(session, text, cancellationToken);
          SaveMention(note with { SessionId = session, Delivered = true, Problem = null });
        }
        catch (OperationCanceledException)
        {
          SaveMention(note with { SessionId = pinnedSession, Problem = "Delivery stopped before it was confirmed. Current caller permission will be checked before retrying." });
          throw;
        }
        catch (MentionPending ex) { SaveMention(note with { SessionId = pinnedSession, Problem = ex.Message }); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { SaveMention(note with { SessionId = pinnedSession, Problem = "The mention could not be delivered. Try it again when the session is ready." }); }
      }
    }
    finally { deliveries.Release(); Changed?.Invoke(); }
  }
  public void YieldSession(string sessionId, string reason)
  {
    store.Change(s =>
    {
      var run = s.Runs.FirstOrDefault(r => r.SessionId == sessionId && HoldsFolder(r));
      if (run is null) return (s, false);
      var old = Find(s, run.TaskId);
      var row = Stamp(old with { Status = "Stuck", NeedsYou = true }, reason, TaskActor.App, old);
      return (s with { Tasks = s.Tasks.Replace(old, row), Runs = s.Runs.Replace(run, run with { State = TaskRunState.Yielded, Problem = reason }) }, true);
    }); Changed?.Invoke();
  }
  public void ObserveSession(string sessionId, bool ended, bool needsYou, string? message = null)
  {
    store.Change(s =>
    {
      var run = s.Runs.FirstOrDefault(r => r.SessionId == sessionId && HoldsFolder(r));
      if (run is null) return (s, false);
      var old = Find(s, run.TaskId);
      var state = ended ? TaskRunState.Ended : needsYou ? TaskRunState.NeedsYou : TaskRunState.Working;
      if (run.State == state && run.Problem is null) return (s, false);
      var note = message ?? (ended ? "The task's session ended. Review its comments before closing the task." : needsYou ? "The agent needs you." : "The agent is working.");
      Text(note, 4000, "Keep the session note short.");
      var row = Stamp(old with { Status = ended || needsYou ? "Stuck" : "Working on it", NeedsYou = ended || needsYou }, note, TaskActor.App, old);
      return (s with { Runs = s.Runs.Replace(run, run with { State = state, Problem = null }), Tasks = s.Tasks.Replace(old, row) }, true);
    }); Changed?.Invoke();
  }
  public void SessionDisconnected(string sessionId)
  {
    var changed = store.Change(s =>
    {
      var run = s.Runs.FirstOrDefault(r => r.SessionId == sessionId && HoldsFolder(r));
      if (run is null || run.State == TaskRunState.Uncertain) return (s, false);
      var old = Find(s, run.TaskId);
      const string message = "The task's session is reconnecting. Its folder stays reserved until its state is known.";
      var row = Stamp(old with { NeedsYou = true, Status = "Stuck" }, message, TaskActor.App, old);
      return (s with { Tasks = s.Tasks.Replace(old, row), Runs = s.Runs.Replace(run, run with { State = TaskRunState.Uncertain, Problem = message }) }, true);
    });
    if (changed) Changed?.Invoke();
  }
  private void RecoverStarts()
  {
    if (!store.Read().Runs.Any(HoldsFolder)) return;
    store.Change(s =>
    {
      var tasks = s.Tasks;
      foreach (var run in s.Runs.Where(r => r.State is TaskRunState.Starting or TaskRunState.Working or TaskRunState.NeedsYou))
      {
        var old = Find(s, run.TaskId);
        var row = Stamp(old with { NeedsYou = true, Status = "Stuck" }, "The task is reconnecting. Check its session before starting this task again.", TaskActor.App, old);
        tasks = tasks.Replace(old, row);
      }
      return (s with { Tasks = tasks, Runs = s.Runs.Select(r => HoldsFolder(r) ? r with { State = TaskRunState.Uncertain } : r).ToImmutableArray() }, true);
    });
  }
  private void SaveMention(TaskMention note) => store.Change(s => (s with { Mentions = s.Mentions.Replace(s.Mentions.Single(m => m.Id == note.Id), note) }, true));
  private string ShortBrief(string text, string taskId, string runId)
  {
    if (text.Length <= 600) return text;
    var path = files?.Save(taskId, runId, text) ?? throw new InvalidOperationException("Long task messages need the task brief folder to be connected.");
    return "Read the task brief at " + path + ". Reply in the task comments.";
  }
  private TaskRecipient RequireRecipient(string id) => id switch
  {
    "me" => new("me", "You", "human", null), "none" => new("none", "Unassigned", "none", null),
    _ => recipient(id) ?? throw new ArgumentException("Choose a saved agent or a current session from the mention list.")
  };
  private DeckTask Change(string id, TaskActor by, string note, Func<TasksState, DeckTask, DeckTask> change, bool trash = false, string kind = "")
  {
    ValidateActor(by);
    var result = store.Change(s =>
    {
      var old = Find(s, id, trash); var changed = change(s, old);
      if (ReferenceEquals(changed, old)) return (s, old);
      var row = Stamp(changed, note, by, old);
      if (kind.Length > 0 && row.Activity.Length > old.Activity.Length) row = row with { Activity = row.Activity.SetItem(row.Activity.Length - 1, row.Activity[^1] with { Kind = kind }) };
      if (note == "Updated the task.")
      {
        var entries = new List<TaskActivity>();
        if (old.GoalId != changed.GoalId || old.Type != changed.Type || old.Title != changed.Title || old.Details != changed.Details || old.Board != changed.Board || old.ProjectId != changed.ProjectId || old.Folder != changed.Folder || !old.Labels.SequenceEqual(changed.Labels))
          entries.Add(Activity("Updated the name, description, tags, type or location.", by, "details"));
        if (old.DueDate != changed.DueDate || old.StartDate != changed.StartDate || old.StartTime != changed.StartTime || old.DueTime != changed.DueTime) entries.Add(Activity("Updated the dates.", by, "dates"));
        if (old.Priority != changed.Priority) entries.Add(Activity("Priority: " + (changed.Priority ?? "None") + ".", by, "priority"));
        if (old.Status != changed.Status) entries.Add(Activity("Status: " + changed.Status + ".", by, "status"));
        row = row with { Activity = entries.Count > 0 ? old.Activity.AddRange(entries) : row.Activity };
      }
      return (s with { Tasks = s.Tasks.Replace(old, row) }, row);
    });
    Changed?.Invoke(); return result;
  }
  private TaskDraft Validate(TaskDraft d)
  {
    Text(d.Title, 240, "Give the task a title of up to 240 characters.");
    if (string.IsNullOrWhiteSpace(d.Title) || d.Title.Any(char.IsControl)) throw new ArgumentException("Give the task a title.");
    Text(d.Details, 40000, "Keep the description within 40,000 characters."); TaskStatuses.Require(d.Status);
    _ = RequireRecipient(d.Assignee); var p = projects.Get(d.ProjectId);
    var folder = d.Folder ?? p.HomeFolder ?? "";
    if (folder.Length > 0) folder = ProjectPaths.Normalize(folder);
    if (p.Id != ProjectIdentity.IndependentId && !p.Folders.Any(f => ProjectPaths.Contains(f, folder))) throw new ArgumentException("Choose a folder in this task's project.");
    if (d.Priority is not (null or "" or "Low" or "Medium" or "High" or "Critical")) throw new ArgumentException("Choose a priority from the list.");
    Date(d.StartDate); Date(d.DueDate); TaskDates.RequireTime(d.StartTime); TaskDates.RequireTime(d.DueTime);
    if (d.StartTime is not null && d.StartDate is null || d.DueTime is not null && d.DueDate is null) throw new ArgumentException("Choose a date before adding its time.");
    if (d.StartDate == d.DueDate && d.StartTime is not null && d.DueTime is not null && string.CompareOrdinal(d.StartTime, d.DueTime) > 0) throw new ArgumentException("The due time must follow the start time.");
    if (d.StartDate is not null && d.DueDate is not null && string.CompareOrdinal(d.StartDate, d.DueDate) > 0) throw new ArgumentException("The due date must follow the start date.");
    if (d.Type is not ("Task" or "Milestone")) throw new ArgumentException("Choose Task or Milestone.");
    var labels = d.Labels.IsDefault ? ImmutableArray<string>.Empty : d.Labels;
    if (labels.Length > 50 || labels.Any(l => l.Length is 0 or > 80 || l.Any(char.IsControl))) throw new ArgumentException("Use up to 50 short tags.");
    if (d.Board is not null) Text(d.Board, 120, "Keep the board name short.");
    return d with { Folder = folder, Labels = labels.Distinct().ToImmutableArray() };
  }
  public static TaskDraft Draft(DeckTask t) => new(t.Title, t.Details, t.ProjectId, t.Folder, t.Status, t.Assignee, t.Priority, t.StartDate, t.DueDate, t.Labels, t.Board, t.Type, t.GoalId, t.StartTime, t.DueTime);
  private static void Date(string? value) { if (value is not null && (!DateOnly.TryParseExact(value, "yyyy-MM-dd", out _) || value.Length != 10)) throw new ArgumentException("Use a date such as 2026-10-29, or clear it."); }
  private static void ValidateActor(TaskActor by) { Key(by.Id); Text(by.Name, 120, "Choose a short author name."); if (by.Kind is not ("human" or "agent" or "hoot" or "app")) throw new ArgumentException("Choose a task author."); }
  private static void Key(string value) { if (string.IsNullOrWhiteSpace(value) || value.Length > 200 || value.Any(char.IsControl)) throw new ArgumentException("Choose a valid task identity."); }
  private static void Text(string text, int maximum, string error) { if (text.Length > maximum || text.Any(c => char.IsControl(c) && c is not ('\n' or '\r' or '\t'))) throw new ArgumentException(error); }
  private static bool AssigneeMatches(DeckTask task, string value) => value switch
  { "" => true, "others" => task.Assignee is not ("me" or "none") || TaskExtras.Of(task).Participants.Any(id => id != "me"), "unassigned" => task.Assignee == "none", _ => task.Assignee == value || TaskExtras.Of(task).Participants.Contains(value) };
  private static TaskFilter NormalizeFilter(TaskFilter filter) => filter with { ProjectId = filter.ProjectIds.IsDefaultOrEmpty ? filter.ProjectId : null, GroupBy = filter.GroupBy switch { "none" => "single", "due" => "date", _ => filter.GroupBy } };
  private void ValidateFilter(TaskFilter f)
  {
    if (f.ProjectId is { } projectId && !ProjectIdentity.ValidId(projectId)) throw new ArgumentException("Choose a valid project filter.");
    if (f.GoalId is { } goalId && !Goals().Any(g => g.Id == goalId && (f.ProjectId is null || g.ProjectId == f.ProjectId))) throw new ArgumentException("Choose a goal from this project.");
    if (f.Assignee.Length > 0) Key(f.Assignee);
    if (!f.ProjectIds.IsDefault && (f.ProjectIds.Distinct().Count() != f.ProjectIds.Length || f.ProjectIds.Any(id => !ProjectIdentity.ValidId(id))) ||
      !f.Statuses.IsDefault && (f.Statuses.Distinct().Count() != f.Statuses.Length || f.Statuses.Any(status => !TaskStatuses.All.Contains(status))) ||
      !f.Assignees.IsDefault && f.Assignees.Distinct().Count() != f.Assignees.Length) throw new ArgumentException("Choose distinct filters from the Tasks page.");
    if (!f.Assignees.IsDefault) foreach (var assignee in f.Assignees) { if (assignee.Length == 0) throw new ArgumentException("Choose a task assignee filter."); Key(assignee); }
    if (f.Search.Length > 240 || f.Search.Any(char.IsControl) || f.GroupBy is not ("date" or "due" or "status" or "assignee" or "priority" or "tags" or "type" or "board" or "project" or "single" or "none") ||
      f.Due is not ("any" or "overdue" or "today" or "week" or "none") || f.Sort is not ("automatic" or "due" or "priority" or "name" or "created") ||
      f.View is not ("List" or "Board" or "Calendar") || !TaskPresentation.ValidColumns(f) ||
      f.Status is not ("open" or "all" or "needs-you") && !TaskStatuses.All.Contains(f.Status)) throw new ArgumentException("Choose filters from the Tasks page.");
  }
  private DeckTask Stamp(DeckTask row, string note, TaskActor by, DeckTask? previous = null)
  {
    // Primary changes from the existing run/assignment path cannot leave the
    // same person listed twice in the local participation roster.
    if (row.Extras is { } extras && !extras.Participants.IsDefaultOrEmpty && extras.Participants.Contains(row.Assignee))
      row = row with { Extras = extras with { Participants = extras.Participants.Remove(row.Assignee) } };
    if (row.Assignee == "none" && row.Extras is { } unassigned && !unassigned.Participants.IsDefaultOrEmpty)
      row = row with { Assignee = unassigned.Participants[0], Extras = unassigned with { Participants = unassigned.Participants.RemoveAt(0) } };
    var entry = Activity(note, by); var activity = row.Activity.Add(entry);
    if (previous is not null && previous.Status != row.Status && TaskActivityKinds.Of(entry) != "status") activity = activity.Add(Activity("Status: " + row.Status + ".", by, "status"));
    return row with { UpdatedAt = clock.GetUtcNow(), Revision = row.Revision + 1, Activity = activity };
  }
  private TaskActivity Activity(string text, TaskActor by, string kind = "") => new(Guid.NewGuid().ToString("N"), text, by, clock.GetUtcNow(), kind);
  private static DeckTask Find(TasksState s, string id, bool trash = false) => s.Tasks.FirstOrDefault(t => t.Id == id && (trash || t.DeletedAt is null)) ?? throw new ArgumentException("This task is no longer available.");
  private static bool HoldsFolder(TaskRun r) => r.State is not (TaskRunState.Ended or TaskRunState.Yielded);
  private static bool Active(TasksState s, DeckTask row) => s.Runs.Any(r => r.Id == row.CurrentRunId && HoldsFolder(r));
  private static bool SameFolder(string a, string b) => a.Length > 0 && b.Length > 0 && ProjectPaths.Equal(a, b);
  [GeneratedRegex(@"(?<![\w@])@(?:\[([^\]\r\n]{1,160})\]|([a-zA-Z0-9][a-zA-Z0-9_:/-]{0,159}))", RegexOptions.CultureInvariant)]
  private static partial Regex MentionPattern();
}
