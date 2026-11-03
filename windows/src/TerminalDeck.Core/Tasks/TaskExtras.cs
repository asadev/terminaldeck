using System.Collections.Immutable;
using System.Text.Json.Serialization;

namespace TerminalDeck.Core.Tasks;

public sealed record TaskItem(string Id, string Name, string Value = "", bool Done = false);
public sealed record TaskExtras(bool OwnWorkspace = false, bool Starred = false, bool Following = false,
  DateTimeOffset? TimerStarted = null, double TrackedSeconds = 0,
  ImmutableArray<TaskItem> Fields = default, ImmutableArray<TaskItem> Checklist = default,
  ImmutableArray<TaskItem> Relations = default, ImmutableArray<TaskItem> Attachments = default,
  ImmutableArray<string> LikedComments = default)
{
  // Additional local people; the main person remains DeckTask.Assignee.
  [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
  public ImmutableArray<string> Participants { get; init; }
  public static TaskExtras Of(DeckTask task)
  {
    var e = task.Extras ?? new();
    return e with { Fields = e.Fields.IsDefault ? [] : e.Fields, Checklist = e.Checklist.IsDefault ? [] : e.Checklist,
      Relations = e.Relations.IsDefault ? [] : e.Relations, Attachments = e.Attachments.IsDefault ? [] : e.Attachments,
      LikedComments = e.LikedComments.IsDefault ? [] : e.LikedComments, Participants = e.Participants.IsDefault ? [] : e.Participants };
  }
}

public sealed partial class TaskService
{
  // Reload and modify under the ledger's existing cross-process write lease.
  public DeckTask Detail(string id, string action, string? key, string? value, TaskActor by)
  {
    if (action is "share" or "unshare" or "share-primary") return ChangePeople(id, action, value, by);
    Text(value ?? "", 4000, "Keep the field within 4,000 characters.");
    return Change(id, by, action switch { "timer" => "Changed time tracking.", "check" or "checklist" => "Updated the checklist.",
      "relate" => "Related a task.", "attach" => "Attached a file.", _ => "Updated task fields." }, (state, task) =>
    {
      var e = TaskExtras.Of(task);
      TaskItem Item(string name) => new(Guid.NewGuid().ToString("N"), name);
      string Required() => !string.IsNullOrWhiteSpace(value) ? value.Trim() : throw new ArgumentException("Enter a value.");
      var now = clock.GetUtcNow();
      e = action switch
      {
        "workspace" => e with { OwnWorkspace = value == "true" },
        "star" => e with { Starred = !e.Starred },
        "follow" => e with { Following = !e.Following },
        "timer" => e.TimerStarted is { } started ? e with { TimerStarted = null, TrackedSeconds = e.TrackedSeconds + Math.Max(0, (now - started).TotalSeconds) } : e with { TimerStarted = now },
        "field" when e.Fields.Length < 100 => e with { Fields = e.Fields.Add(Item(Required())) },
        "field-value" when e.Fields.FirstOrDefault(f => f.Id == key) is { } field => e with { Fields = e.Fields.Replace(field, field with { Value = value ?? "" }) },
        "checklist" when e.Checklist.Length < 200 => e with { Checklist = e.Checklist.Add(Item(Required())) },
        "check" when e.Checklist.FirstOrDefault(f => f.Id == key) is { } check => e with { Checklist = e.Checklist.Replace(check, check with { Done = !check.Done }) },
        "relate" when key is null or "Related" or "Subtask" or "Blocks" or "Blocked by" && value != id && state.Tasks.Any(t => t.Id == value && t.ProjectId == task.ProjectId && t.DeletedAt is null) && !e.Relations.Any(t => t.Value == value) => e with { Relations = e.Relations.Add(Item(key ?? "Related") with { Value = value! }) },
        "attach" when Path.IsPathFullyQualified(Required()) && File.Exists(value) && !e.Attachments.Any(f => f.Value == value) => e with { Attachments = e.Attachments.Add(Item(Path.GetFileName(value!)) with { Value = value! }) },
        "like" when task.Comments.Any(c => c.Id == key) => e with { LikedComments = e.LikedComments.Contains(by.Id + ":" + key) ? e.LikedComments.Remove(by.Id + ":" + key) : e.LikedComments.Add(by.Id + ":" + key) },
        _ => throw new ArgumentException("Choose an available task action and value.")
      };
      return task with { Extras = e };
    }, kind: action switch { "timer" => "time", "checklist" or "check" => "checklists", "relate" => "relationships", "attach" => "attachments", "like" => "comments", _ => "details" });
  }
}
