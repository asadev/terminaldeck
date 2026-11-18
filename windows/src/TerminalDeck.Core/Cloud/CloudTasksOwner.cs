using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Cloud;

// This PC's OWN tasks in the Cloud (row I12, domain `tasks`), the Mac's BackendCloudKindsTasks on Windows.
// - Travels: the signed task table's shared fields in the Mac's row shape (title, details as `instructions`, status as
//   `crmStatus`, priority, tags, dates and times, kind, goal, its project as `projectRef`, list or Trash as `place`) and
//   the comments (`notes`, merged one by one). Per field the newest wins; a joining PC's first copy loses.
// - Never travels: who a task is given to, its run, its folder and everything the table marks "this device". A task
//   arrives stopped and unassigned: nothing starts from the Cloud, no run, no session, no mention is delivered.
// - Tasks of a CONNECTED task system are that system's data: never sent, never applied from the Cloud.
// - "Needs your approval" is the safe direction: it travels; an arriving "no approval needed" never turns it off here.
//   A larger spending limit is never taken from another device.
// - A task waits until its project is on this PC.
// - The delete rule (lane D2, the Mac's 87941cff8): the Trash is the Bin. A task moved to Trash carries who removed it
//   (person or AI, which device, which group) while every device reads table version 2; "Delete for good" travels and
//   applies over the Trash only (a live task edited elsewhere stays); each device ages its own Trash after 30 days by the
//   service clock, and that never travels.
// - Tasks everywhere (table version 2): who a task is assigned to, its links, board, page details and which Mac works it
//   arrive and are carried back unchanged; this PC never starts work from them.
// - A connected task system, a CRM task link and a CRM task's read-only copy (version 2 records) are not part of this
//   PC's app yet: they wait here, kept, and are never refused.
// - Values this PC cannot hold (a Mac's estimate, result, model, approval, a goal not on this PC) are kept here
//   exactly as they came and travel back unchanged, so an edit here never overwrites them on the Macs.
public sealed class CloudTasksOwner : ICloudRecordOwner, ICloudDeleteOwning
{
  public const string DomainName = "tasks", InventoryRowName = "I12", SourceIdName = "task-list";
  public static readonly CloudRecordKind Kind = new("task:", CloudMergeTablesV2.Task, "", new HashSet<string>(StringComparer.Ordinal) { "title" });
  public static readonly CloudRecordKind SystemKind = new("task-system:", CloudMergeTablesV2.TaskSystem, "", new HashSet<string>(StringComparer.Ordinal) { "name" });
  public static readonly CloudRecordKind LinkKind = new("task-link:", CloudMergeTablesV2.TaskLink, "", new HashSet<string>(StringComparer.Ordinal) { "name" });
  public static readonly CloudRecordKind CrmKind = new("crm-task:", CloudMergeTablesV2.CrmTask, "", new HashSet<string>(StringComparer.Ordinal) { "title" });
  public const string NotOnThisPcYet = "Connected task systems and CRM task links are not part of this PC's app yet; kept until they are.";
  public const long TrashDays = 30;
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Tasks from a connected task system come to each device from that system, not through your Cloud.",
    "Who a task is assigned to, its running session and its folder stay on the device that runs it; on another device it arrives stopped and unassigned.",
    "A task that needs your approval needs it on every device; a copy saying it does not never turns approval off here.",
  ];
  public const string WaitsForProject = "Waits until its project is on this PC.";
  public const string ConnectedSystem = "This task belongs to a connected task system; this PC gets it from that system.";
  public const string ApprovalStays = "Approval for this task stays on until you turn it off on this PC.";
  public const string BudgetStays = "A larger spending limit for this task is never taken from another device.";
  public const string NotHeldHere = "This PC cannot hold this value; it stays as it is on your other devices.";
  public const string LocalPrefix = "local:";
  /// Comments travel as the Mac's notes of this kind; every other kind of note arrives as task activity.
  public const string CommentKind = "reply";
  private static readonly string[] CarriedOnly = ["estimateMinutes", "result", "effort", "model", "decisionRequired", "hops"];

  private sealed class Ledger
  {
    /// The last value the Cloud gave each task: fields this PC cannot hold travel back from here unchanged.
    public Dictionary<string, string> Carried { get; set; } = [];
    /// When this PC first saw a task done or archived (`completedAt`, `archivedAt`), so the time never changes by itself.
    public Dictionary<string, long> Times { get; set; } = [];
  }

  private readonly TaskStore tasks;
  private readonly IProjects projects;
  private readonly CloudKindsKept? kept;
  private readonly CloudKindsSettle settle;
  private readonly Func<long> now;
  private readonly string? ledgerFile;
  private readonly Action changed;
  private Ledger ledger = new();
  /// The goals of the task list read last (set at every entry point, never read again inside a write).
  private ImmutableArray<DeckGoal> goals = [];
  private readonly CloudRecordsDeleteLedger deletes;
  private string receivingDevice = ""; private long receivingAt;
  private long? trashAgedAt;
  public CloudRecordsDeleteLedger Deletes => deletes;

  /// `tasks`: this PC's one task ledger (the same file the Tasks page and the Keeper use, under its own lock).
  /// `changed`: display only, after tasks arrived. `ledgerFile`: this PC's own carried values and times (never sent).
  public CloudTasksOwner(TaskStore tasks, IProjects projects, CloudRecordsDeleteLedger deletes, CloudKindsKept? kept = null, CloudKindsSettle? settle = null,
    string? ledgerFile = null, Func<long>? now = null, Action? changed = null)
  {
    this.tasks = tasks; this.deletes = deletes; this.projects = projects; this.kept = kept; this.ledgerFile = ledgerFile; this.changed = changed ?? (() => { });
    this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.settle = settle ?? new CloudKindsSettle(0, () => 0);
    if (ledgerFile is not null && File.Exists(ledgerFile))
      try { ledger = JsonSerializer.Deserialize<Ledger>(File.ReadAllBytes(ledgerFile)) ?? new Ledger(); } catch (JsonException) { }
  }
  private void SaveLedger() { if (ledgerFile is not null) new CloudFileSlot(ledgerFile).Write(JsonSerializer.SerializeToUtf8Bytes(ledger)); }

  public CloudRecordAdapter Adapter(CloudRecordStore store, string account, string deviceId, CloudRecordOrigins origins)
  {
    deletes.Bind(store, deviceId);
    return new(DomainName, InventoryRowName, SourceIdName, [Kind, SystemKind, LinkKind, CrmKind], store, account, deviceId, this, origins, Exclusions);
  }

  // ---- the Mac's row shape ↔ this PC's DeckTask ----

  private static long Ms(DateTimeOffset at) => at.ToUnixTimeMilliseconds();
  private static DateTimeOffset At(CloudJson? value, DateTimeOffset fallback) =>
    CloudRecordJson.Number(value) is { } n && CloudRecordJson.Exact(Math.Floor(n)) is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds(ms) : fallback;
  private static CloudJson? Text(string? value) => value is null ? null : CloudJson.From(value);
  private static string? TextIn(CloudJson? value) => CloudRecordJson.Text(value) is { Length: > 0 } s ? s : null;
  private static bool IsLocal(DeckTask task) => task.Connected is null && task.Id.StartsWith(LocalPrefix, StringComparison.Ordinal) && task.Id.Length > LocalPrefix.Length;
  private bool GoalHere(string? goal, string project) => goal is null || !goals.IsDefault && goals.Any(g => g.Id == goal && g.ProjectId == project);
  private TasksState ReadAll() { var state = tasks.Read(); goals = state.Goals.IsDefault ? [] : state.Goals; return state; }

  /// One field this PC holds: how a DeckTask writes it (null = absent) and how a value from the row is taken in.
  private sealed record Mapped(string Key, Func<DeckTask, CloudJson?> Out, Func<CloudJson?, DeckTask, DeckTask> In);
  private IReadOnlyList<Mapped> Fields() =>
  [
    new("title", t => CloudJson.From(t.Title), (v, t) => t with { Title = CloudRecordJson.Text(v) ?? t.Title }),
    new("instructions", t => CloudJson.From(t.Details), (v, t) => t with { Details = CloudRecordJson.Text(v) ?? "" }),
    new("crmStatus", t => CloudJson.From(t.Status), (v, t) => t with
    {
      Status = CloudRecordJson.Text(v) is { } s && TaskStatuses.All.Contains(s) ? s : t.Status,
      NeedsYou = CloudRecordJson.Text(v) == "Stuck" || t.NeedsYou && CloudRecordJson.Text(v) != "Done",
    }),
    new("priority", t => Text(t.Priority is { Length: > 0 } p ? p : null), (v, t) => t with { Priority = TextIn(v) }),
    new("labels", t => CloudJson.Arr((t.Labels.IsDefault ? ImmutableArray<string>.Empty : t.Labels).Select(l => (CloudJson)CloudJson.From(l))), (v, t) => t with
    {
      Labels = (CloudRecordJson.Items(v) ?? []).Select(CloudRecordJson.Text).OfType<string>().Distinct(StringComparer.Ordinal).ToImmutableArray()
    }),
    new("tokenBudget", t => TaskExtras.Of(t).TokenBudget is { } budget ? CloudJson.From((double)budget) : null, (v, t) =>
      v is null or CloudJson.Null ? t with { Extras = TaskExtras.Of(t) with { TokenBudget = null } }
      : v.AsInteger is >= 0 and <= 1_000_000_000 and var amount ? t with { Extras = TaskExtras.Of(t) with { TokenBudget = amount } } : t),
    new("startDate", t => Text(t.StartDate), (v, t) => t with { StartDate = TextIn(v) }),
    new("startTime", t => Text(t.StartTime), (v, t) => t with { StartTime = TextIn(v) }),
    new("dueDate", t => Text(t.DueDate), (v, t) => t with { DueDate = TextIn(v) }),
    new("dueTime", t => Text(t.DueTime), (v, t) => t with { DueTime = TextIn(v) }),
    new("taskType", t => CloudJson.From(t.Type == "Milestone" ? "milestone" : "task"), (v, t) => t with { Type = CloudRecordJson.Text(v) == "milestone" ? "Milestone" : "Task" }),
    // A goal is taken only when that goal is on this PC in the task's project; otherwise the Cloud's goal is carried.
    new("goalId", t => Text(t.GoalId), (v, t) => TextIn(v) is { } goal ? (GoalHere(goal, t.ProjectId) ? t with { GoalId = goal } : t) : t with { GoalId = null }),
    new("projectRef", t => t.ProjectId == ProjectIdentity.IndependentId ? null : CloudRecordJson.Object([("projectId", CloudJson.From(t.ProjectId))]), (v, t) =>
    {
      var wanted = TextIn(CloudRecordJson.Get(v, "projectId")) ?? ProjectIdentity.IndependentId;
      if (wanted == t.ProjectId) return t;
      var here = projects.List().FirstOrDefault(p => p.Id == wanted);
      if (here is null && wanted != ProjectIdentity.IndependentId) return t;
      return t with { ProjectId = wanted, Folder = here?.HomeFolder ?? "", GoalId = null };
    }),
    new("place", t => CloudJson.From(t.DeletedAt is null ? "tasks" : "trash"), (v, t) => CloudRecordJson.Text(v) switch
    {
      "trash" => t.DeletedAt is null ? t with { DeletedAt = DateTimeOffset.FromUnixTimeMilliseconds(now()) } : t,
      _ => t with { DeletedAt = null },
    }),
  ];

  private CloudJson.Object? Carried(string id) => ledger.Carried.TryGetValue(id, out var text) ? CloudJson.Parse(text) as CloudJson.Object : null;
  private long Time(string id, string field, bool observe)
  {
    var key = id + "|" + field;
    if (ledger.Times.TryGetValue(key, out var at)) return at;
    at = now();
    if (observe) { ledger.Times[key] = at; SaveLedger(); }
    return at;
  }
  private static CloudJson Note(TaskComment c) => CloudRecordJson.Sorted([("id", CloudJson.From(c.Id)), ("at", CloudJson.From(Ms(c.At))), ("by", CloudJson.From(c.Author.Id)),
    ("kind", CloudJson.From(CommentKind)), ("text", CloudJson.From(c.Text))]);
  private static CloudJson OnlyNoteKeys(CloudJson element) => element is CloudJson.Object o
    ? CloudRecordJson.Object(o.Members.Where(m => CloudMergeTables.NoteKeys.Contains(m.Key)).Select(m => (m.Key, m.Value))) : element;

  /// The task as the Mac's row (travelling fields only). A field whose value here is what the carried Cloud value already
  /// means travels as that carried value, so nothing is rewritten by the difference in shape.
  private CloudJson.Object Row(DeckTask task, CloudJson.Object? carried, bool observe, CloudJson.Object? meta = null, bool everywhere = false)
  {
    var external = task.Id[LocalPrefix.Length..];
    CloudJson Kept(string key, CloudJson fallback) => CloudRecordJson.Has(carried, key) ? CloudRecordJson.Get(carried, key)! : fallback;
    var fields = new List<(string, CloudJson)>
    {
      ("id", CloudJson.From(task.Id)), ("keyId", CloudJson.From("local")), ("externalTaskId", CloudJson.From(external)),
      ("originExternalTaskId", Kept("originExternalTaskId", CloudJson.From(external))), ("externalThreadId", Kept("externalThreadId", CloudJson.Null.Value)),
      ("creator", Kept("creator", CloudJson.From("me"))),
    };
    foreach (var map in Fields())
    {
      var mine = map.Out(task);
      var theirs = CloudRecordJson.Get(carried, map.Key);
      var same = carried is not null && CloudRecordJson.Same(map.Out(map.In(theirs, task)), mine);
      var value = same && CloudRecordJson.Has(carried, map.Key) ? theirs : mine;
      if (value is not null) fields.Add((map.Key, value));
    }
    foreach (var key in CarriedOnly) if (CloudRecordJson.Has(carried, key)) fields.Add((key, CloudRecordJson.Get(carried, key)!));
    // Version 2, only while every device reads it: the tasks-everywhere values as they came, and who moved it to Trash.
    if (everywhere) foreach (var key in CloudMergeTablesV2.TaskEverywhereFields) if (CloudRecordJson.Has(carried, key)) fields.Add((key, CloudRecordJson.Get(carried, key)!));
    if (task.DeletedAt is not null && meta is not null && everywhere && CloudDeleteText.IsUuid(CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedGroup"))))
      foreach (var key in CloudMergeTablesV2.RecordDeleteFields) if (CloudRecordJson.Has(meta, key)) fields.Add((key, CloudRecordJson.Get(meta, key)!));
    fields.Add(("createdAt", CloudJson.From(Ms(task.CreatedAt))));
    fields.Add(("updatedAt", CloudJson.From(Ms(task.UpdatedAt))));
    fields.Add(("deletedAt", task.DeletedAt is { } deleted ? CloudJson.From(Ms(deleted)) : CloudJson.Null.Value));
    // Done and archived carry the time they became so: the Cloud's when it gave this state, else the time this PC saw it.
    if (task.Status == "Done")
      fields.Add(("completedAt", CloudRecordJson.Text(CloudRecordJson.Get(carried, "crmStatus")) == "Done" && CloudRecordJson.Number(CloudRecordJson.Get(carried, "completedAt")) is not null
        ? CloudRecordJson.Get(carried, "completedAt")! : CloudJson.From(Time(task.Id, "completedAt", observe))));
    else fields.Add(("completedAt", CloudJson.Null.Value));
    if (task.Archived)
      fields.Add(("archivedAt", CloudRecordJson.Number(CloudRecordJson.Get(carried, "archivedAt")) is not null
        ? CloudRecordJson.Get(carried, "archivedAt")! : CloudJson.From(Time(task.Id, "archivedAt", observe))));
    else fields.Add(("archivedAt", CloudJson.Null.Value));
    // Comments: every note the Cloud gave (kept exactly) plus this PC's own comments; the newest 100 travel.
    var notes = new Dictionary<string, CloudJson>(StringComparer.Ordinal);
    foreach (var element in CloudRecordJson.Items(CloudRecordJson.Get(carried, "notes")) ?? []) notes[CloudRecordMerge.ElementId(OnlyNoteKeys(element))] = OnlyNoteKeys(element);
    foreach (var comment in task.Comments.IsDefault ? ImmutableArray<TaskComment>.Empty : task.Comments) notes.TryAdd(comment.Id, Note(comment));
    var ordered = notes.OrderBy(n => CloudRecordJson.Number(CloudRecordJson.Get(n.Value, "at")) ?? 0).ThenBy(n => n.Key, StringComparer.Ordinal).Select(n => n.Value).ToList();
    fields.Add(("notes", CloudJson.Arr(ordered.Skip(Math.Max(0, ordered.Count - 100)))));
    return CloudRecordJson.Object(fields);
  }

  /// The DeckTask after taking in `row`. Never assigns, never starts, never removes a comment or activity this PC has.
  private DeckTask Taken(CloudJson.Object row, DeckTask task)
  {
    foreach (var map in Fields()) if (CloudRecordJson.Has(row, map.Key)) task = map.In(CloudRecordJson.Get(row, map.Key), task);
    if (CloudRecordJson.Number(CloudRecordJson.Get(row, "createdAt")) is not null) task = task with { CreatedAt = At(CloudRecordJson.Get(row, "createdAt"), task.CreatedAt) };
    if (CloudRecordJson.Number(CloudRecordJson.Get(row, "updatedAt")) is not null) task = task with { UpdatedAt = At(CloudRecordJson.Get(row, "updatedAt"), task.UpdatedAt) };
    if (task.DeletedAt is not null && CloudRecordJson.Number(CloudRecordJson.Get(row, "deletedAt")) is not null) task = task with { DeletedAt = At(CloudRecordJson.Get(row, "deletedAt"), task.DeletedAt.Value) };
    if (CloudRecordJson.Has(row, "archivedAt")) task = task with { Archived = CloudRecordJson.Number(CloudRecordJson.Get(row, "archivedAt")) is not null };
    var comments = (task.Comments.IsDefault ? ImmutableArray<TaskComment>.Empty : task.Comments).ToList();
    var activity = (task.Activity.IsDefault ? ImmutableArray<TaskActivity>.Empty : task.Activity).ToList();
    foreach (var element in CloudRecordJson.Items(CloudRecordJson.Get(row, "notes")) ?? [])
    {
      var id = CloudRecordMerge.ElementId(OnlyNoteKeys(element));
      if (comments.Any(c => c.Id == id) || activity.Any(a => a.Id == id)) continue;
      var by = CloudRecordJson.Text(CloudRecordJson.Get(element, "by")) is { Length: > 0 and <= 200 } who && !who.Any(char.IsControl) ? who : "app";
      var actor = by == TaskActor.Owner.Id ? TaskActor.Owner : by == TaskActor.App.Id ? TaskActor.App : new TaskActor(by, by, "agent");
      var text = CloudRecordJson.Text(CloudRecordJson.Get(element, "text")) ?? "";
      var at = At(CloudRecordJson.Get(element, "at"), task.UpdatedAt);
      var kind = CloudRecordJson.Text(CloudRecordJson.Get(element, "kind")) ?? "";
      if (kind == CommentKind) comments.Add(new TaskComment(id, actor, text, at, []));
      else activity.Add(new TaskActivity(id, text, actor, at, kind));
    }
    return task with { Comments = [.. comments.OrderBy(c => c.At)], Activity = [.. activity.OrderBy(a => a.At)] };
  }
  private DeckTask Fresh(string id, string title) => new(id, title, "", ProjectIdentity.IndependentId, "", "To-Do", "none",
    DateTimeOffset.FromUnixTimeMilliseconds(now()), DateTimeOffset.FromUnixTimeMilliseconds(now()), Labels: [], Comments: [], Activity: []);

  /// The carried value after a write: the row's travelling fields over what was carried before.
  private static CloudJson.Object Merge(CloudJson.Object? carried, CloudJson.Object row)
  {
    var result = carried ?? CloudRecordJson.Object([]);
    // A tasks-everywhere value the row does not carry never removes the one carried here (an older copy does not know it).
    foreach (var member in CloudRecordAdapter.Travelling(CloudRecordsDeleteLedger.Clearing(row), Kind.Table).Members) result = CloudRecordJson.Set(result, member.Key, member.Value);
    foreach (var field in CarriedOnly) if (!CloudRecordJson.Has(row, field)) result = CloudRecordJson.Remove(result, field);
    return result;
  }
  private Dictionary<string, DeckTask> Local() => ReadAll().Tasks.Where(IsLocal).ToDictionary(t => Kind.Entity(t.Id), StringComparer.Ordinal);
  private CloudJson.Object Shared(DeckTask task, bool observe, bool? open = null) =>
    CloudRecordAdapter.Travelling(Row(task, Carried(task.Id), observe, Meta(task.Id), open ?? deletes.IsOpen()), Kind.Table);
  private CloudJson.Object? Meta(string id) => deletes.Saved("meta:" + Kind.Entity(id)) as CloudJson.Object;
  private void SetMeta(string id, CloudJson.Object? meta) { if (meta is null) deletes.ClearSaved("meta:" + Kind.Entity(id)); else deletes.Put("meta:" + Kind.Entity(id), meta); }
  private static CloudJson.Object DeleteFields(CloudJson.Object value) =>
    CloudRecordJson.Object(CloudMergeTablesV2.RecordDeleteFields.Where(f => CloudRecordJson.Has(value, f)).Select(f => (f, CloudRecordJson.Get(value, f)!)));
  /// Who moved a task to Trash on this PC: the person, or the AI the task's own history names.
  private CloudJson.Object TrashedHere(DeckTask task)
  {
    var by = (task.Activity.IsDefault ? [] : task.Activity).LastOrDefault(a => a.Text == "Moved to Trash.")?.By;
    var ai = by is not null && by.Kind != "human";
    var at = task.DeletedAt?.ToUnixTimeMilliseconds() ?? now();
    var actor = deletes.Actor(ai ? CloudDeleteBy.Ai : CloudDeleteBy.Person, ai ? by!.Name : null, at: at);
    return CloudRecordsDeleteLedger.Metadata(actor.Intent(Kind.Entity(task.Id), CloudDeleteScope.Everywhere), actor.MacName);
  }
  /// Two shared values that differ only in `updatedAt` (touched by every save) are the same for settling.
  private static bool SameSettled(CloudJson.Object a, CloudJson.Object b) =>
    CloudRecordAdapter.Equal(CloudRecordJson.Remove(a, "updatedAt"), CloudRecordJson.Remove(b, "updatedAt"));

  // ---- checks on a value from another device ----

  private static bool PlainText(CloudJson? value, int maximum) => CloudRecordJson.Text(value) is { } s && s.Length <= maximum && !s.Any(c => char.IsControl(c) && c is not ('\n' or '\r' or '\t'));
  private static bool Date(CloudJson? value) => CloudRecordJson.Nullish(value) || CloudRecordJson.Text(value) is { } s && DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);
  private static bool Clock(CloudJson? value) => CloudRecordJson.Nullish(value) || CloudRecordJson.Text(value) is { } s && TimeOnly.TryParseExact(s, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);

  // ---- ICloudRecordOwner ----

  public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords()
  {
    AgeTrash();
    var open = deletes.IsOpen();
    var current = new Dictionary<string, CloudJson.Object>(StringComparer.Ordinal);
    foreach (var (entity, task) in Local())
    {
      // A task moved to Trash on this PC gets its attribution once; one taken out of the Trash loses it.
      if (task.DeletedAt is not null && Meta(task.Id) is null) SetMeta(task.Id, TrashedHere(task));
      else if (task.DeletedAt is null && Meta(task.Id) is not null) SetMeta(task.Id, null);
      current[entity] = Shared(task, observe: true, open);
    }
    return settle.Pass(current, SameSettled);
  }

  public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud)
  {
    if (SystemKind.IdOf(entity) is not null || LinkKind.IdOf(entity) is not null || CrmKind.IdOf(entity) is not null) return new(null, Waiting: NotOnThisPcYet);
    var id = Kind.IdOf(entity) ?? throw new CloudRecordRefusal("This is not a task record.");
    DeckTask? existing;
    try { existing = ReadAll().Tasks.FirstOrDefault(t => t.Id == id); }
    catch (IOException) { throw new CloudRecordRefusal("The task list on this PC cannot be read right now."); }
    if (existing is not null && !IsLocal(existing)) return new(null, Waiting: ConnectedSystem);
    var carried = Carried(id);
    var mine = existing is null ? null : Shared(existing, observe: false);
    // Deleted for good on another device: applies over the Trash only. A live task edited here stays.
    if (cloud is null) return new(existing?.DeletedAt is not null ? null : mine);
    // A task this PC aged out of its own Trash is not placed back into that Trash.
    if (existing is null && CloudRecordJson.Text(CloudRecordJson.Get(cloud, "place")) == "trash" && deletes.Saved(CloudRecordsDeleteLedger.AgedKey(entity)) is not null) return new(null);
    var external = id.StartsWith(LocalPrefix, StringComparison.Ordinal) ? id[LocalPrefix.Length..] : "";
    if (external.Length == 0 || external.Length > 200 || external.Any(char.IsControl) || CloudRecordJson.Text(CloudRecordJson.Get(cloud, "keyId")) != "local"
      || CloudRecordJson.Text(CloudRecordJson.Get(cloud, "externalTaskId")) != external || CloudRecordJson.Text(CloudRecordJson.Get(cloud, "id")) != id)
      return new(mine, Waiting: ConnectedSystem);
    if (TextIn(CloudRecordJson.Get(CloudRecordJson.Get(cloud, "projectRef"), "projectId")) is { } projectId && !projects.List().Any(p => p.Id == projectId))
      return new(mine, Waiting: WaitsForProject);
    if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "place")) == "trash") CloudRecordsDeleteLedger.Validate(cloud);

    CloudJson.Object next = cloud;
    var held = new Dictionary<string, string>(StringComparer.Ordinal);
    void Hold(string name, string reason)
    {
      held[name] = reason;
      next = CloudRecordJson.Has(mine, name) ? CloudRecordJson.Set(next, name, CloudRecordJson.Get(mine, name)!) : CloudRecordJson.Remove(next, name);
    }
    if (!PlainText(CloudRecordJson.Get(cloud, "title"), 240) || string.IsNullOrWhiteSpace(CloudRecordJson.Text(CloudRecordJson.Get(cloud, "title"))) || CloudRecordJson.Text(CloudRecordJson.Get(cloud, "title"))!.Any(char.IsControl))
    {
      if (existing is null) return new(null, Waiting: "This task's title set on another device is not one this PC can use.");
      Hold("title", "The title set on another device is not one this PC can use.");
    }
    if (CloudRecordJson.Has(cloud, "instructions") && !CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "instructions")) && !PlainText(CloudRecordJson.Get(cloud, "instructions"), 40_000))
      Hold("instructions", "The details set on another device are too long for this PC.");
    if (CloudRecordJson.Has(cloud, "crmStatus") && !(CloudRecordJson.Text(CloudRecordJson.Get(cloud, "crmStatus")) is { } status && TaskStatuses.All.Contains(status)))
      Hold("crmStatus", "The status set on another device is not one this PC knows.");
    if (CloudRecordJson.Has(cloud, "priority") && !CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "priority"))
      && CloudRecordJson.Text(CloudRecordJson.Get(cloud, "priority")) is not ("" or "Low" or "Medium" or "High" or "Critical"))
      Hold("priority", "The priority set on another device is not one this PC knows.");
    if (CloudRecordJson.Has(cloud, "labels") && !CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "labels"))
      && (CloudRecordJson.Items(CloudRecordJson.Get(cloud, "labels")) is not { } labels || labels.Count > 50 || labels.Any(l => CloudRecordJson.Text(l) is not { Length: > 0 and <= 80 } t || t.Any(char.IsControl))))
      Hold("labels", "The tags set on another device are not ones this PC can hold.");
    foreach (var name in new[] { "startDate", "dueDate" }) if (!Date(CloudRecordJson.Get(cloud, name))) Hold(name, "The date set on another device is not one this PC can read.");
    foreach (var name in new[] { "startTime", "dueTime" }) if (!Clock(CloudRecordJson.Get(cloud, name))) Hold(name, "The time set on another device is not one this PC can read.");
    if (CloudRecordJson.Has(cloud, "taskType") && !CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "taskType"))
      && !CloudMergeTables.TaskTypes.Contains(CloudRecordJson.Text(CloudRecordJson.Get(cloud, "taskType")) ?? ""))
      Hold("taskType", "The kind of task set on another device is not one this PC knows.");
    if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "model")) is { Length: > 0 } model && !CloudMergeTables.IsValidModel(model))
      Hold("model", "The model set on another device is not one this PC can use.");
    if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "place")) is { } place ? place is not ("tasks" or "trash") : CloudRecordJson.Has(cloud, "place") && !CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "place")))
      Hold("place", "Where the task is kept is not one this PC knows.");
    // The safe direction travels: "needs your approval" arrives; "no approval needed" never removes approval here.
    if (CloudRecordJson.Bool(CloudRecordJson.Get(cloud, "decisionRequired")) != true && CloudRecordJson.Bool(CloudRecordJson.Get(mine, "decisionRequired")) == true)
      Hold("decisionRequired", ApprovalStays);
    if (!CloudRecordJson.Nullish(CloudRecordJson.Get(cloud, "tokenBudget")) && CloudRecordJson.Get(cloud, "tokenBudget")?.AsInteger is not (>= 0 and <= 1_000_000_000))
      Hold("tokenBudget", "The token budget set on another device is not a whole number this PC can use.");
    else if (!CloudRecordMerge.MayApply(CloudMergeClass.ShrinkField, CloudRecordJson.Get(mine, "tokenBudget"), CloudRecordJson.Get(cloud, "tokenBudget")))
      Hold("tokenBudget", BudgetStays);

    // Exactly what this PC will hold after the write, so the write is never sent back as a change of its own.
    var task = Taken(next, existing ?? Fresh(id, CloudRecordJson.Text(CloudRecordJson.Get(next, "title")) ?? ""));
    var planned = CloudRecordAdapter.Travelling(Row(task, Merge(carried, next), observe: false, MetaAfter(next, task), deletes.IsOpen()), Kind.Table);
    foreach (var field in new[] { "title", "instructions", "crmStatus", "priority", "labels", "dueDate", "dueTime", "startDate", "startTime", "taskType", "goalId", "projectRef", "place", "tokenBudget" })
      if (CloudRecordJson.Has(cloud, field) && !held.ContainsKey(field) && !CloudRecordAdapter.Equal(Value(planned, field), Value(cloud, field)))
        held[field] = NotHeldHere;
    return new(planned, held);
  }
  /// The attribution this PC keeps for a task after taking in `value`: the arriving one, or for an old-form Trash copy
  /// its device and day ("older version", never sent); none outside the Trash.
  private CloudJson.Object? MetaAfter(CloudJson.Object value, DeckTask task)
  {
    if (task.DeletedAt is null) return null;
    if (CloudDeleteText.IsUuid(CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedGroup")))) return DeleteFields(value);
    if (CloudRecordJson.Text(CloudRecordJson.Get(value, "place")) != "trash") return Meta(task.Id);
    var at = CloudRecordJson.Number(CloudRecordJson.Get(value, "deletedAt")) is { } d ? (long)d : receivingAt > 0 ? receivingAt : now();
    var actor = deletes.Arriving(value, receivingDevice, at);
    return CloudRecordJson.Object([("deletedBy", CloudJson.From(CloudDeleteText.Raw(actor.By))), ("deletedOn", CloudJson.From(actor.Mac)), ("deletedGroup", CloudJson.From(actor.Group)),
      ("deletedMacName", CloudJson.From(actor.MacName)), ("deletedTime", CloudJson.From(actor.At))]);
  }
  private static CloudJson Value(CloudJson.Object o, string field) => CloudRecordJson.Has(o, field) && !CloudRecordJson.Nullish(CloudRecordJson.Get(o, field)) ? CloudRecordJson.Get(o, field)! : CloudJson.Null.Value;

  public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting)
  {
    var id = Kind.IdOf(entity) ?? throw new CloudFailure("invalid_request");
    if (CloudRecordJson.Text(CloudRecordJson.Get(value, "keyId")) != "local" || !id.StartsWith(LocalPrefix, StringComparison.Ordinal)) throw new CloudFailure("invalid_request");
    var carried = Carried(id);
    CloudJson.Object? before = null, meta = null;
    try
    {
      tasks.Change(state =>
      {
        goals = state.Goals.IsDefault ? [] : state.Goals;
        var existing = state.Tasks.FirstOrDefault(t => t.Id == id);
        if (existing is not null && !IsLocal(existing)) throw new CloudRecordRefusal(ConnectedSystem);
        before = existing is null ? null : Shared(existing, observe: false);
        if (!CloudRecordAdapter.Equal(before, expecting))
          throw new CloudRecordRefusal("This task changed on this PC while a change from another device was being applied; it is applied on the next try.");
        var task = Taken(value, existing ?? Fresh(id, CloudRecordJson.Text(CloudRecordJson.Get(value, "title")) ?? ""));
        if (!GoalHere(task.GoalId, task.ProjectId)) task = task with { GoalId = null };
        meta = MetaAfter(value, task);
        task = task with { Revision = (existing?.Revision ?? 0) + 1 };
        var list = existing is null ? state.Tasks.Add(task) : state.Tasks.Replace(existing, task);
        return (state with { Tasks = list }, true);
      });
    }
    catch (IOException error) { throw new CloudRecordRefusal("Not applied on this PC: " + error.Message + " It is tried again later."); }
    ledger.Carried[id] = CloudRecordJson.Encode(Merge(carried, value));
    SaveLedger();
    SetMeta(id, meta);
    if (CloudRecordJson.Text(CloudRecordJson.Get(value, "place")) != "trash") deletes.ClearSaved(CloudRecordsDeleteLedger.AgedKey(entity));
    if (before is not null && !CloudRecordAdapter.Equal(before, value)) kept?.Keep(entity, before);
    settle.Wrote(entity, value);
  }

  // ---- the delete rule ----

  public void ConfigureDeleteRule(Func<bool>? gate = null, Func<string, string?>? deviceName = null, Func<long?>? serviceNow = null) => deletes.Configure(gate, deviceName, serviceNow);
  /// Each device ages its OWN Trash: a local task 30 days in the Trash goes, by the service clock only (nothing ages while
  /// it is not known), at most once an hour. Remembered here only and never sent.
  private void AgeTrash()
  {
    if (deletes.ServiceNow() is not { } service) return;
    if (trashAgedAt is { } last && service >= last && service - last < 3_600_000) return;
    trashAgedAt = service;
    var cutoff = service - TrashDays * 86_400_000;
    try
    {
      tasks.Change(state =>
      {
        var aged = state.Tasks.Where(t => IsLocal(t) && t.CurrentRunId is null && t.DeletedAt is { } at && at.ToUnixTimeMilliseconds() < cutoff).ToArray();
        foreach (var t in aged) deletes.Put(CloudRecordsDeleteLedger.AgedKey(Kind.Entity(t.Id)), CloudJson.From(true));
        return aged.Length == 0 ? (state, false) : (state with { Tasks = state.Tasks.RemoveRange(aged) }, true);
      });
    }
    catch (IOException) { }
  }
  private DeckTask? Find(string id) => ReadAll().Tasks.FirstOrDefault(t => t.Id == id);
  private void Purge(string id)
  {
    tasks.Change(state =>
    {
      var row = state.Tasks.FirstOrDefault(t => t.Id == id);
      return row is null || !IsLocal(row) || row.DeletedAt is null || row.CurrentRunId is not null ? (state, false) : (state with { Tasks = state.Tasks.Remove(row) }, true);
    });
    SetMeta(id, null);
  }
  private DeckTask? Restore(string id)
  {
    var entity = Kind.Entity(id);
    deletes.ClearSaved("purged:" + entity);
    deletes.Put(entity, CloudJson.From(true), restoring: true);
    DeckTask? back = null;
    tasks.Change(state =>
    {
      var row = state.Tasks.FirstOrDefault(t => t.Id == id);
      if (row is null || !IsLocal(row) || row.DeletedAt is null) return (state, false);
      back = row with { DeletedAt = null, UpdatedAt = DateTimeOffset.FromUnixTimeMilliseconds(now()), Revision = row.Revision + 1 };
      return (state with { Tasks = state.Tasks.Replace(row, back) }, true);
    });
    if (back is null) throw new CloudFailure("invalid_request");
    SetMeta(id, null);
    changed();
    return back;
  }

  public void CloudReceiving(string entity, string device, long at) { receivingDevice = device; receivingAt = at; }
  public bool CloudRestoring(string entity) => deletes.Restoring(entity);
  public void CloudCaptured(string entity, bool removed)
  {
    deletes.Captured(entity, removed);
    if (removed && Kind.IdOf(entity) is { } id) SetMeta(id, null);
  }
  /// Only "Delete for good" pressed here travels; a task merely gone (aged, or never this account's) does not.
  public CloudRecordMissing? CloudMissing(string entity, CloudJson.Object last) =>
    Kind.IdOf(entity) is not null && deletes.Saved("purged:" + entity) is not null ? new CloudRecordMissing(null) : null;
  public void CloudRemove(string entity, CloudJson.Object? expecting, CloudJson.Object removal, string device, long at)
  {
    if (Kind.IdOf(entity) is not { } id) return;
    DeckTask? existing;
    try { existing = Find(id); } catch (IOException) { throw new CloudRecordRefusal("The task list on this PC cannot be read right now."); }
    if (existing is null || !IsLocal(existing) || existing.DeletedAt is null) return;
    if (!CloudRecordAdapter.Equal(Shared(existing, observe: false), expecting)) throw new CloudRecordRefusal("This task changed while its purge arrived.");
    try { Purge(id); } catch (IOException error) { throw new CloudRecordRefusal("Not applied on this PC: " + error.Message + " It is tried again later."); }
  }

  /// Tasks are always "Everywhere": into the Trash on every device.
  public Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    var removed = new List<CloudDeleteItem>();
    foreach (var item in items)
    {
      var id = Kind.IdOf(item.Id) ?? item.Id;
      DeckTask? moved = null;
      var meta = CloudRecordsDeleteLedger.Metadata(by.Intent(Kind.Entity(id), CloudDeleteScope.Everywhere), by.MacName);
      tasks.Change(state =>
      {
        var row = state.Tasks.FirstOrDefault(t => t.Id == id);
        if (row is null || !IsLocal(row) || row.DeletedAt is not null || row.CurrentRunId is not null) return (state, false);
        moved = row with { DeletedAt = DateTimeOffset.FromUnixTimeMilliseconds(by.At), UpdatedAt = DateTimeOffset.FromUnixTimeMilliseconds(now()), Revision = row.Revision + 1 };
        return (state with { Tasks = state.Tasks.Replace(row, moved) }, true);
      });
      if (moved is null) continue;
      deletes.ClearRestoring(Kind.Entity(id));
      SetMeta(id, meta);
      removed.Add(new(Kind.Entity(id), "task", moved.Title));
    }
    if (removed.Count > 0) changed();
    return Task.FromResult(new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed));
  }
  public Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    foreach (var item in items) Restore(Kind.IdOf(item.Id) ?? item.Id);
    return Task.FromResult(items);
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>([]);
  /// The Trash as Bin groups: by its attribution; a row whose attribution does not read is left out, the rest shows.
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync()
  {
    var rows = new List<(CloudDeleteItem, CloudDeleteActor)>();
    var own = deletes.OwnDevice() ?? "this-pc";
    foreach (var task in ReadAll().Tasks.Where(t => IsLocal(t) && t.DeletedAt is not null))
    {
      var entity = Kind.Entity(task.Id);
      var at = task.DeletedAt!.Value.ToUnixTimeMilliseconds();
      var meta = Meta(task.Id);
      CloudDeleteActor actor;
      if (CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedGroup")) is not { } group)
        actor = new(CloudDeleteBy.Person, own, deletes.OwnName(), null, null, at, "before:" + own + ":" + (at / 86_400_000).ToString(CultureInfo.InvariantCulture));
      else if (CloudDeleteText.IsUuid(group))
      {
        try { actor = deletes.Arriving(meta!, CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedOn")) ?? "", at); }
        catch (CloudRecordRefusal) { continue; }
      }
      else actor = new(CloudDeleteBy.Person, CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedOn")) ?? "",
        CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedMacName")) ?? CloudDeleteWords.AnotherDevice, null, null, at, group);
      rows.Add((new CloudDeleteItem(entity, "task", task.Title), actor));
    }
    return Task.FromResult(CloudRecordsDeleteLedger.Groups(rows));
  }
  public Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group) => Task.FromResult(PutBackAll(group).Restored);
  public CloudRecordsPutBack PutBackAll(string group)
  {
    var found = BinGroupsAsync().GetAwaiter().GetResult().FirstOrDefault(g => g.Id == group);
    var restored = new List<CloudDeleteItem>(); var failed = new List<CloudDeleteItem>();
    foreach (var item in found?.Items ?? [])
    {
      try { Restore(Kind.IdOf(item.Id) ?? item.Id); restored.Add(item); }
      catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(item); }
    }
    return new(restored, failed);
  }
  /// "Delete for good" (the person's page only): only a stopped local task in the Trash; it travels.
  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    foreach (var item in items)
    {
      var id = Kind.IdOf(item.Id) ?? item.Id;
      if (Find(id) is not { DeletedAt: not null, CurrentRunId: null } row || !IsLocal(row)) continue;
      deletes.Put("purged:" + Kind.Entity(id), CloudJson.From(true));
      try { Purge(id); } catch { deletes.ClearSaved("purged:" + Kind.Entity(id)); throw; }
    }
    changed();
    return Task.CompletedTask;
  }

  public void CloudImported(IReadOnlyList<string> entities) { if (entities.Count > 0) changed(); }

  /// A task that waits for its project is looked at again when the project list changes.
  public string CloudContext() => "projects:" + string.Join(',', projects.List().Select(p => p.Id).OrderBy(p => p, StringComparer.Ordinal));
}
