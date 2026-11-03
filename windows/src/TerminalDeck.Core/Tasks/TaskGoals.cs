using System.Collections.Immutable;

namespace TerminalDeck.Core.Tasks;

public sealed record DeckGoal(string Id, string Title, string Description, string ProjectId, string Status = "active", string? ParentId = null, long Revision = 1);
public sealed record GoalDraft(string Title, string Description, string ProjectId, string Status = "active", string? ParentId = null);
public static class TaskGoalTree
{
  public static IReadOnlySet<string> Descendants(IReadOnlyList<DeckGoal> goals, string root)
  {
    var children = goals.Where(g => g.ParentId is not null).ToLookup(g => g.ParentId!);
    var ids = new HashSet<string> { root }; var pending = new Queue<string>(); pending.Enqueue(root);
    while (pending.TryDequeue(out var id)) foreach (var child in children[id]) if (ids.Add(child.Id)) pending.Enqueue(child.Id);
    return ids;
  }
}
public sealed partial class TaskService
{
  public IReadOnlyList<DeckGoal> Goals(string? projectId = null) => store.Read().Goals.Where(g => projectId is null || g.ProjectId == projectId).ToArray();
  public DeckGoal SaveGoal(GoalDraft draft, TaskActor by, string? id = null, long? expectedRevision = null)
  {
    ValidateActor(by); _ = projects.Get(draft.ProjectId);
    Text(draft.Title, 240, "Keep the goal title within 240 characters."); Text(draft.Description, 40000, "Keep the goal description within 40,000 characters.");
    if (string.IsNullOrWhiteSpace(draft.Title) || draft.Title.Any(char.IsControl)) throw new ArgumentException("Give the goal a title.");
    if (draft.Status is not ("planned" or "active" or "achieved" or "cancelled")) throw new ArgumentException("Choose Planned, Active, Achieved or Cancelled.");
    var saved = store.Change(s =>
    {
      var old = id is null ? null : s.Goals.FirstOrDefault(g => g.Id == id) ?? throw new ArgumentException("Choose a saved goal.");
      if (expectedRevision is not null && old?.Revision != expectedRevision) throw new InvalidOperationException("This goal changed. Reopen it before saving your edits.");
      if (old is not null && old.ProjectId != draft.ProjectId && (s.Tasks.Any(t => t.GoalId == id) || s.Goals.Any(g => g.ParentId == id)))
        throw new ArgumentException("Move this goal's tasks and subgoals before changing its project.");
      if (draft.ParentId is { } parent)
      {
        var seen = new HashSet<string>(); if (id is not null) seen.Add(id);
        while (parent is not null)
        {
          if (!seen.Add(parent)) throw new ArgumentException("A goal cannot be its own parent or sit under one of its subgoals.");
          var row = s.Goals.FirstOrDefault(g => g.Id == parent && g.ProjectId == draft.ProjectId) ?? throw new ArgumentException("Choose a parent goal in this project."); parent = row.ParentId;
        }
      }
      var goal = new DeckGoal(old?.Id ?? Guid.NewGuid().ToString("N"), draft.Title.Trim(), draft.Description.Trim(), draft.ProjectId, draft.Status, draft.ParentId, (old?.Revision ?? 0) + 1);
      return (s with { Goals = old is null ? s.Goals.Add(goal) : s.Goals.Replace(old, goal) }, goal);
    }); Changed?.Invoke(); return saved;
  }
  public void DeleteGoal(string id, TaskActor by)
  {
    ValidateActor(by); store.Change(s =>
    {
      var goal = s.Goals.FirstOrDefault(g => g.Id == id) ?? throw new ArgumentException("Choose a saved goal.");
      var tasks = s.Tasks.Select(t => t.GoalId == id ? Stamp(t with { GoalId = goal.ParentId }, "Moved from the removed goal.", by) : t).ToImmutableArray();
      var goals = s.Goals.Remove(goal).Select(g => g.ParentId == id ? g with { ParentId = goal.ParentId, Revision = g.Revision + 1 } : g).ToImmutableArray();
      var filters = s.Filters.ToImmutableDictionary(p => p.Key, p => p.Value.GoalId == id ? p.Value with { GoalId = goal.ParentId } : p.Value);
      var views = s.Views.Select(v => v.State.GoalId == id ? v with { State = v.State with { GoalId = goal.ParentId } } : v).ToImmutableArray();
      return (s with { Tasks = tasks, Goals = goals, Filters = filters, Views = views }, true);
    }); Changed?.Invoke();
  }
  private static void GoalReference(TasksState state, string projectId, string? goalId)
  {
    if (goalId is not null && !state.Goals.Any(g => g.Id == goalId && g.ProjectId == projectId)) throw new ArgumentException("Choose a goal in this task's project.");
  }
}
