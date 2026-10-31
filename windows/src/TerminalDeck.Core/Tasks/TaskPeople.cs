using System.Collections.Immutable;

namespace TerminalDeck.Core.Tasks;

public sealed partial class TaskService
{
  private DeckTask ChangePeople(string id, string action, string? personId, TaskActor by)
  {
    Key(personId ?? "");
    if (personId == "none") throw new ArgumentException("Choose someone from the local task people list.");
    // Stored membership outlives a session or saved agent. Removing it needs
    // only the saved ID; new invitations still require the live directory.
    var target = action == "unshare" ? personId == "me" ? new TaskRecipient("me", "You", "human", null) : recipient(personId!) : RequireRecipient(personId!);
    if (action != "unshare" && (target!.Id != personId || target.Kind == "none")) throw new ArgumentException("Choose someone from the local task people list.");
    var name = target?.Name ?? personId;
    return Change(id, by, action == "unshare" ? "Removed " + name + " from the task." : "Added " + name + " to the task.", (_, task) =>
    {
      var extras = TaskExtras.Of(task); var others = extras.Participants; var primary = task.Assignee;
      if (action == "share" && (primary == personId || others.Contains(personId!)) || action == "share-primary" && primary == personId ||
        action == "unshare" && primary != personId && !others.Contains(personId!)) return task;
      if (action == "unshare")
      {
        if (primary == personId)
        {
          if (others.IsEmpty) throw new InvalidOperationException("A task needs a main person. Add someone else before taking the main person off.");
          primary = others[0]; others = others.RemoveAt(0);
        }
        else others = others.Remove(personId!);
      }
      else if (action == "share-primary")
      {
        if (primary != personId)
        {
          others = others.Remove(personId!);
          if (primary != "none" && !others.Contains(primary)) others = others.Insert(0, primary);
          primary = personId!;
        }
      }
      else if (primary != personId && !others.Contains(personId!))
      {
        // A personal task becomes the invited person's task. Once shared,
        // further invitations join its roster without changing its main person.
        if (primary == "none" || primary == "me" && others.IsEmpty) primary = personId!;
        else others = others.Add(personId!);
      }
      if (others.Length > 100) throw new ArgumentException("A task can include up to 100 additional people.");
      return task with { Assignee = primary, Extras = extras with { Participants = others } };
    }, kind: "assignees");
  }
}
