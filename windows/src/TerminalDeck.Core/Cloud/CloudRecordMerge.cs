using System.Globalization;

namespace TerminalDeck.Core.Cloud;

// The record merge of the Mac's lean records (td-mac-next TerminalDeckNativeCore CloudBrainAgentsMerge.swift and
// CloudBrainAgentsFieldTables.swift), ported line by line. Projects (I11) and agents (I10) use it in 7C-2; tasks (I12)
// and settings (I21) use the same core in 7C-4. Per field the newest stamp wins; the other value is kept as an "other
// version" and listed; a joining device's first copy is a BASELINE and loses to any ordinary stamp (rule J). Payloads
// are byte-equal to the Mac's: the same members, the same values, the same canonical form (CloudCanonical).

/// How a follows-class field is merged: never a conflict.
public abstract record CloudMergeFollow
{
  private CloudMergeFollow() { }
  /// The largest number among the heads (`archivedAt`).
  public sealed record Newest : CloudMergeFollow;
  /// The largest number, but a change to this field alone never makes a revision (`updatedAt`).
  public sealed record Touched : CloudMergeFollow;
  /// The smallest number among the heads (`createdAt`).
  public sealed record Oldest : CloudMergeFollow;
  /// Travels with the partner field: among the heads holding the partner's shown stamp, the newest own stamp wins.
  public sealed record Partner(string Field) : CloudMergeFollow;
}

/// Field classes (design v2 Appendix A, revision 4).
public abstract record CloudMergeClass
{
  private CloudMergeClass() { }
  public sealed record Shared : CloudMergeClass;
  public sealed record Identity : CloudMergeClass;
  public sealed record Widening : CloudMergeClass;
  public sealed record Raise : CloudMergeClass;
  public sealed record Shrink : CloudMergeClass;
  public sealed record Follows(CloudMergeFollow Rule) : CloudMergeClass;
  public sealed record Collection(int? Cap) : CloudMergeClass;
  public sealed record ThisDevice : CloudMergeClass;

  public static readonly CloudMergeClass SharedField = new Shared(), IdentityField = new Identity(), WideningField = new Widening(),
    RaiseField = new Raise(), ShrinkField = new Shrink(), ThisDeviceField = new ThisDevice();
}

/// One versioned allow-list. Any key not listed is this device's only and never travels.
public sealed class CloudMergeTable(string domain, int version, IReadOnlyDictionary<string, CloudMergeClass> classes, IReadOnlyDictionary<string, int>? introduced = null)
{
  public string Domain { get; } = domain;
  public int Version { get; } = version;
  public IReadOnlyDictionary<string, CloudMergeClass> Classes { get; } = classes;
  public IReadOnlyDictionary<string, int> Introduced { get; } = introduced ?? new Dictionary<string, int>();
  /// null: this app version does not know the key.
  public CloudMergeClass? FieldClass(string key) => key == CloudRecordMerge.ExistsField ? CloudMergeClass.SharedField : Classes.GetValueOrDefault(key);
}

/// Appendix A, version 1, as signed by the Security seat (Ruling 3, 12 Nov 2026): the Mac's CloudBrainMergeTables.
public static class CloudMergeTables
{
  public const int Version = 1;
  private static Dictionary<string, CloudMergeClass> All(CloudMergeClass kind, params string[] keys) => keys.ToDictionary(k => k, _ => kind, StringComparer.Ordinal);
  private static CloudMergeTable Table(string domain, params Dictionary<string, CloudMergeClass>[] parts)
  {
    var classes = new Dictionary<string, CloudMergeClass>(StringComparer.Ordinal);
    foreach (var part in parts) foreach (var (key, kind) in part) classes.TryAdd(key, kind);
    return new(domain, Version, classes);
  }
  private static Dictionary<string, CloudMergeClass> One(params (string Key, CloudMergeClass Kind)[] rows) => rows.ToDictionary(r => r.Key, r => r.Kind, StringComparer.Ordinal);
  private static CloudMergeClass Follows(CloudMergeFollow rule) => new CloudMergeClass.Follows(rule);

  /// `tasks.json` rows, entity `task:<id>`.
  public static readonly CloudMergeTable Task = Table("tasks",
    All(CloudMergeClass.IdentityField, "id", "keyId", "externalTaskId", "originExternalTaskId", "externalThreadId", "creator"),
    All(CloudMergeClass.SharedField, "title", "instructions", "crmStatus", "priority", "labels", "dueDate", "dueTime", "startDate", "startTime",
      "estimateMinutes", "taskType", "goalId", "result", "effort", "model", "projectRef", "place"),
    One(("decisionRequired", CloudMergeClass.RaiseField), ("tokenBudget", CloudMergeClass.ShrinkField)),
    One(("updatedAt", Follows(new CloudMergeFollow.Touched())), ("createdAt", Follows(new CloudMergeFollow.Oldest())),
      ("completedAt", Follows(new CloudMergeFollow.Partner("crmStatus"))), ("deletedAt", Follows(new CloudMergeFollow.Partner("place"))),
      ("archivedAt", Follows(new CloudMergeFollow.Newest())), ("hops", Follows(new CloudMergeFollow.Newest())), ("notes", new CloudMergeClass.Collection(100))),
    All(CloudMergeClass.ThisDeviceField, "local", "notificationKeyId", "reviewVerdict", "reusedFromTask", "decisionID", "decisionPolicyID", "decisionEpoch",
      "decisionEligible", "decisionCreateRequest", "assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId",
      "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "project", "cwd", "sessionId", "conversationId", "seatSession",
      "seatToldAt", "process", "stopped", "runStartedAt", "keepOpenUntil", "keepAliveUntilClose", "questionOpen", "hootTurnOpen",
      "lastTurn", "childrenTold", "seq", "stalled", "startFailed", "awaitingSetup", "useWorkspace", "briefFile", "landing",
      "landingAttempts", "reviewWaitingForFolder", "tokenUsageByAgent", "isAPIAccount", "detail"));
  public static readonly IReadOnlySet<string> TaskTypes = new HashSet<string>(StringComparer.Ordinal) { "task", "milestone" };
  /// A `model` (agent or task): letters, digits and `. _ : [ ] -`, starting with a letter or digit, at most 128.
  public static bool IsValidModel(string value) =>
    value.Length is > 0 and <= 128 && char.IsAsciiLetterOrDigit(value[0]) && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or ':' or '[' or ']' or '-');
  /// Elements of a task's `notes` collection: only these keys travel.
  public static readonly IReadOnlySet<string> NoteKeys = new HashSet<string>(StringComparer.Ordinal) { "id", "at", "by", "kind", "text" };

  /// Finished agent runs (history), entity `run:<id>`.
  public static readonly CloudMergeTable Run = Table("tasks",
    All(CloudMergeClass.SharedField, "id", "agent_id", "task_id", "provider", "project_id", "session_id", "conversation_id", "session_name", "started_at",
      "ended_at", "outcome", "summary", "needed_help", "verified", "tokens", "cost_usd", "cost_source", "billing_kind", "requested_model", "requested_effort"),
    All(CloudMergeClass.ThisDeviceField, "cwd", "account_id"));

  /// `task-config.json` `agents` rows, entity `agent:<id>`.
  public static readonly CloudMergeTable Agent = Table("agents",
    All(CloudMergeClass.IdentityField, "id"),
    All(CloudMergeClass.SharedField, "name", "role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo", "instructionHash"),
    All(CloudMergeClass.WideningField, "provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent", "skills",
      "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"),
    One(("statusAt", Follows(new CloudMergeFollow.Partner("status")))),
    All(CloudMergeClass.ThisDeviceField, "account", "creatorKeyId", "keyInitializedFields", "syncStatus", "syncedAt", "syncError", "instructions",
      "instructionsFile", "verifyCommand", "sourceDirectory", "sourceFile", "sourcePath", "defaultProject", "startIn", "reviewerAgent"));

  /// Agent options per profile and per provider default.
  public static readonly CloudMergeTable AgentOptions = Table("agent-options",
    All(CloudMergeClass.SharedField, "model", "effort"),
    All(CloudMergeClass.WideningField, "provider", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "keepOpen", "efficiency", "contextWindow", "fastMode"),
    All(CloudMergeClass.ThisDeviceField, "environment", "hooks", "workingFolder"));

  /// `settings.json` values, one record per key holding `key` and `value`.
  public static readonly IReadOnlySet<string> AppSettingKeys = new HashSet<string>(StringComparer.Ordinal) { "appearance.theme", "appearance.terminalFontSize",
    "notifications.onComplete", "notifications.onNeedsInput", "notifications.onFinishSound", "notifications.soundName" };
  /// `state.json` `preferences`, one record per key; `defaultProvider` is a widening (the owner holds it).
  public static readonly IReadOnlySet<string> NativePreferenceKeys = new HashSet<string>(StringComparer.Ordinal) { "theme", "notifyOnComplete", "defaultProvider" };
  public static readonly IReadOnlySet<string> NativeWideningKeys = new HashSet<string>(StringComparer.Ordinal) { "defaultProvider" };
  public static readonly CloudMergeTable Setting = Table("settings", All(CloudMergeClass.IdentityField, "key"), All(CloudMergeClass.SharedField, "value"));

  /// Project registry rows, entity `project:<id>`; folders stay on each device.
  public static readonly CloudMergeTable Project = Table("projects",
    All(CloudMergeClass.IdentityField, "id"),
    All(CloudMergeClass.SharedField, "name", "icon", "colour", "logo"),
    All(CloudMergeClass.WideningField, "lead"),
    One(("leadName", Follows(new CloudMergeFollow.Partner("lead"))), ("roots", new CloudMergeClass.Collection(null))),
    All(CloudMergeClass.ThisDeviceField, "folders"));

  /// Connected-task connection rows: history only.
  public static readonly CloudMergeTable Connection = Table("agents",
    All(CloudMergeClass.IdentityField, "keyId"),
    All(CloudMergeClass.SharedField, "name", "enabled", "hasEventsSecret", "eventsHost"),
    All(CloudMergeClass.ThisDeviceField, "eventsSecret", "eventsUrl", "statuses", "hootIdentity", "identities", "allowedSenders", "folders", "maxHops"));
}

/// Table VERSION 2 of the record tables (the Mac's CloudBrainAgentsFieldTables.swift extensions `recordsDeleteRule` and
/// `tasksEverywhere`, td-mac-next2 87941cff8 + bd3e3321b). Version 1 above stays the Security-reviewed list; version 2 only
/// ADDS fields, each introduced at 2, so a revision that writes one carries minTable 2 and a version-1 reader parks it
/// instead of half-applying it. Nothing of version 2 is written while the delete rule's gate is closed.
public static class CloudMergeTablesV2
{
  /// Who removed a record, on which device, in which group and with which scope (the delete rule's travel fields on records).
  public static readonly IReadOnlyList<string> RecordDeleteFields = ["deletedBy", "deletedOn", "deletedGroup", "deletedSession", "deletedAgent", "deletedMacName",
    "deletedTime", "deletedScope", "deletedWithAgent"];
  /// The delete fields travel with `partner` (`$exists`, or a task's `place`): among the heads holding the partner's shown
  /// stamp, the newest own stamp wins.
  public static CloudMergeTable RecordsDeleteRule(CloudMergeTable @base, string partner = CloudRecordMerge.ExistsField)
  {
    var classes = new Dictionary<string, CloudMergeClass>(@base.Classes, StringComparer.Ordinal);
    var introduced = new Dictionary<string, int>(@base.Introduced, StringComparer.Ordinal);
    foreach (var field in RecordDeleteFields) { classes[field] = new CloudMergeClass.Follows(new CloudMergeFollow.Partner(partner)); introduced[field] = 2; }
    return new(@base.Domain, Math.Max(2, @base.Version), classes, introduced);
  }
  /// Task fields that were "this device" (or not listed) and travel from version 2 ("tasks everywhere"). An arriving one
  /// never starts work; this PC carries them back unchanged.
  public static readonly IReadOnlyList<string> TaskEverywhereFields = ["assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId",
    "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "reviewVerdict", "reusedFromTask", "askedFromTask", "board",
    "position", "recurrence", "useWorkspace", "tokenUsage", "tokenUsageByAgent", "detail", "workingOn"];
  public static CloudMergeTable TasksEverywhere(CloudMergeTable @base)
  {
    var classes = new Dictionary<string, CloudMergeClass>(@base.Classes, StringComparer.Ordinal);
    var introduced = new Dictionary<string, int>(@base.Introduced, StringComparer.Ordinal);
    foreach (var field in TaskEverywhereFields) { classes[field] = CloudMergeClass.SharedField; introduced[field] = 2; }
    return new(@base.Domain, Math.Max(2, @base.Version), classes, introduced);
  }
  private static Dictionary<string, CloudMergeClass> All(CloudMergeClass kind, params string[] keys) => keys.ToDictionary(k => k, _ => kind, StringComparer.Ordinal);
  private static Dictionary<string, CloudMergeClass> Join(params Dictionary<string, CloudMergeClass>[] parts)
  {
    var classes = new Dictionary<string, CloudMergeClass>(StringComparer.Ordinal);
    foreach (var part in parts) foreach (var (key, kind) in part) classes.TryAdd(key, kind);
    return classes;
  }
  private static Dictionary<string, int> AtTwo(IEnumerable<string> keys) => keys.ToDictionary(k => k, _ => 2, StringComparer.Ordinal);

  /// `task:<id>`: the task table with the delete fields (partner `place`) and the tasks-everywhere fields.
  public static readonly CloudMergeTable Task = TasksEverywhere(RecordsDeleteRule(CloudMergeTables.Task, partner: "place"));
  /// `agent:<id>` and `instruction:<id>.md`.
  public static readonly CloudMergeTable Agent = RecordsDeleteRule(CloudMergeTables.Agent);
  public static readonly CloudMergeTable Instruction = RecordsDeleteRule(new CloudMergeTable("agents", 1, new Dictionary<string, CloudMergeClass>(StringComparer.Ordinal)
    { ["id"] = CloudMergeClass.IdentityField, ["text"] = CloudMergeClass.SharedField }));
  /// `project:<id>`.
  public static readonly CloudMergeTable Project = RecordsDeleteRule(CloudMergeTables.Project);
  /// A connected task system (`task-system:<id>`), never its token. Every field is new at 2.
  public static readonly CloudMergeTable TaskSystem = new("tasks", 2, Join(All(CloudMergeClass.IdentityField, "id", "createdAt"),
    All(CloudMergeClass.SharedField, "name", "url", "enabled", "changes", "markDone", "projectId", "profile", "server", "me", "docsUrl"),
    All(CloudMergeClass.ThisDeviceField, "tokenEnding", "problem", "projectIdInferred", "folder", "startIn")),
    AtTwo(["id", "createdAt", "name", "url", "enabled", "changes", "markDone", "projectId", "profile", "server", "me", "docsUrl"]));
  /// A CRM task one Mac receives, shown on the other devices as a read-only copy (`crm-task:<keyId>:<externalTaskId>`).
  public static readonly CloudMergeTable CrmTask = MakeCrmTask();
  private static CloudMergeTable MakeCrmTask()
  {
    var classes = new Dictionary<string, CloudMergeClass>(TasksEverywhere(CloudMergeTables.Task).Classes, StringComparer.Ordinal)
    { ["systemName"] = CloudMergeClass.SharedField, ["homeMac"] = CloudMergeClass.SharedField };
    return new("tasks", 2, classes, AtTwo(classes.Keys));
  }
  /// A CRM task link (`task-link:<keyId>`): name and on/off only.
  public static readonly CloudMergeTable TaskLink = new("tasks", 2, Join(All(CloudMergeClass.IdentityField, "keyId"), All(CloudMergeClass.SharedField, "name", "enabled")),
    AtTwo(["keyId", "name", "enabled"]));
}

/// When and by which revision a field (or a collection element) was last changed. Identical on every device.
public readonly record struct CloudMergeStamp(long Time, string Op)
{
  public static int Compare(CloudMergeStamp a, CloudMergeStamp b) => a.Time != b.Time ? a.Time.CompareTo(b.Time) : string.CompareOrdinal(a.Op, b.Op);
}
public sealed record CloudMergeElement(string Id, CloudJson Value, CloudMergeStamp Stamp);
/// An other version of one field: the value of a losing revision. Identity is (field, revision).
public sealed record CloudMergeConflict(string Field, string Revision, CloudJson Value, string Device, long Time)
{
  public (string, string) Identity => (Field, Revision);
}

public sealed class CloudMergeInvalid() : Exception("This record is not in a form this app reads.");
public sealed class CloudMergeHistoryIncomplete(IReadOnlyList<string> missing) : Exception("Earlier versions of this record are not on this device yet.")
{
  public IReadOnlyList<string> Missing { get; } = missing;
}

/// JSON helpers with the Mac's NativeRPCValue meaning: an absent member is "missing" (C# null), JSON null is null.
public static class CloudRecordJson
{
  public static CloudJson? Get(CloudJson? value, string key)
  {
    if (value is not CloudJson.Object o) return null;
    CloudJson? found = null;
    foreach (var m in o.Members) if (m.Key == key) found = m.Value;
    return found;
  }
  public static bool Has(CloudJson? value, string key) => value is CloudJson.Object o && o.Members.Any(m => m.Key == key);
  public static bool Nullish(CloudJson? value) => value is null or CloudJson.Null;
  public static bool Same(CloudJson? a, CloudJson? b)
  {
    if (a is null || b is null) return a is null && b is null;
    try { return CloudCanonical.Encode(a).AsSpan().SequenceEqual(CloudCanonical.Encode(b)); }
    catch (CloudFailure) { return false; }
  }
  public static CloudJson.Object Object(IEnumerable<(string Key, CloudJson Value)> members) => new(members.Select(m => KeyValuePair.Create(m.Key, m.Value)).ToArray());
  public static CloudJson.Object Sorted(IEnumerable<(string Key, CloudJson Value)> members) => Object(members.OrderBy(m => m.Key, StringComparer.Ordinal));
  /// Sets one member: replaces it where it is (dropping later duplicates), else appends it.
  public static CloudJson.Object Set(CloudJson.Object o, string key, CloudJson value)
  {
    var list = new List<KeyValuePair<string, CloudJson>>(); var done = false;
    foreach (var m in o.Members)
    {
      if (m.Key != key) { list.Add(m); continue; }
      if (!done) { list.Add(KeyValuePair.Create(key, value)); done = true; }
    }
    if (!done) list.Add(KeyValuePair.Create(key, value));
    return new(list);
  }
  public static CloudJson.Object Remove(CloudJson.Object o, string key) => new(o.Members.Where(m => m.Key != key).ToArray());
  public static string? Text(CloudJson? value) => value is CloudJson.String s ? s.Value : null;
  public static bool? Bool(CloudJson? value) => value is CloudJson.Bool b ? b.Value : null;
  public static double? Number(CloudJson? value) => value is CloudJson.Number n ? n.Value : null;
  public static IReadOnlyList<CloudJson>? Items(CloudJson? value) => value is CloudJson.Array a ? a.Items : null;
  public static string Encode(CloudJson value) => System.Text.Encoding.UTF8.GetString(CloudCanonical.Encode(value));
  public static CloudJson Decode(string text) => CloudJson.Parse(text);
  /// Int64(exactly:) of a double, or null.
  public static long? Exact(double value) => double.IsFinite(value) && value == Math.Floor(value) && value >= -9.2233720368547758E18 && value < 9.2233720368547758E18 ? (long)value : null;
}

/// The payload of one revision: every travelling field with its last-changed stamp, collections by element id, carried
/// other versions. Names this app does not know are merged by where they sit and carried through untouched.
public sealed class CloudMergeVersion
{
  public int Table { get; set; }
  public int MinTable { get; set; }
  public bool Baseline { get; set; }
  public Dictionary<string, CloudJson> Fields { get; init; } = new(StringComparer.Ordinal);
  public Dictionary<string, CloudMergeStamp> Stamps { get; init; } = new(StringComparer.Ordinal);
  public Dictionary<string, Dictionary<string, CloudMergeElement>> Collections { get; init; } = new(StringComparer.Ordinal);
  public Dictionary<string, Dictionary<string, CloudMergeStamp>> Removed { get; init; } = new(StringComparer.Ordinal);
  public List<CloudMergeConflict> Conflicts { get; init; } = [];

  private static CloudJson StampValue(CloudMergeStamp stamp) => CloudJson.Arr([CloudJson.From(stamp.Time), CloudJson.From(stamp.Op)]);
  private static long Exact(CloudJson? value) => CloudRecordJson.Number(value) is { } n && CloudRecordJson.Exact(n) is { } whole ? whole : throw new CloudMergeInvalid();
  private static CloudMergeStamp Stamp(CloudJson? value)
  {
    if (CloudRecordJson.Items(value) is not { Count: 2 } pair || CloudRecordJson.Text(pair[1]) is not { Length: > 0 } op) throw new CloudMergeInvalid();
    return new(Exact(pair[0]), op);
  }

  /// The Mac's `payload()`: table, minTable, baseline, fields, stamps, collections (elements by id), removed, conflicts.
  public CloudJson.Object Payload()
  {
    var collections = CloudRecordJson.Sorted(Collections.Select(c => (c.Key, (CloudJson)CloudJson.Arr(c.Value.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(id =>
      (CloudJson)CloudRecordJson.Sorted([("id", CloudJson.From(id)), ("value", c.Value[id].Value), ("stamp", StampValue(c.Value[id].Stamp))]))))));
    var removed = CloudRecordJson.Sorted(Removed.Select(r => (r.Key, (CloudJson)CloudJson.Arr(r.Value.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(id =>
      (CloudJson)CloudRecordJson.Sorted([("id", CloudJson.From(id)), ("stamp", StampValue(r.Value[id]))]))))));
    var conflicts = CloudJson.Arr(Conflicts.OrderBy(c => c.Field, StringComparer.Ordinal).ThenBy(c => c.Revision, StringComparer.Ordinal).Select(c =>
      (CloudJson)CloudRecordJson.Sorted([("field", CloudJson.From(c.Field)), ("revision", CloudJson.From(c.Revision)), ("value", c.Value),
        ("device", CloudJson.From(c.Device)), ("time", CloudJson.From(c.Time))])));
    return CloudRecordJson.Sorted([("table", CloudJson.From(Table)), ("minTable", CloudJson.From(MinTable)), ("baseline", CloudJson.From(Baseline)),
      ("fields", CloudRecordJson.Sorted(Fields.Select(f => (f.Key, f.Value)))), ("stamps", CloudRecordJson.Sorted(Stamps.Select(s => (s.Key, StampValue(s.Value))))),
      ("collections", collections), ("removed", removed), ("conflicts", conflicts)]);
  }

  public static CloudMergeVersion Parse(CloudJson p)
  {
    if (CloudRecordJson.Bool(CloudRecordJson.Get(p, "baseline")) is not { } baseline || CloudRecordJson.Get(p, "fields") is not CloudJson.Object fields
      || CloudRecordJson.Get(p, "stamps") is not CloudJson.Object stamps || CloudRecordJson.Get(p, "collections") is not CloudJson.Object collections
      || CloudRecordJson.Get(p, "removed") is not CloudJson.Object removed || CloudRecordJson.Items(CloudRecordJson.Get(p, "conflicts")) is not { } conflicts)
      throw new CloudMergeInvalid();
    var table = Exact(CloudRecordJson.Get(p, "table")); var minTable = Exact(CloudRecordJson.Get(p, "minTable"));
    if (table is < 1 or > 1_000_000 || minTable is < 1 or > 1_000_000) throw new CloudMergeInvalid();
    var version = new CloudMergeVersion { Table = (int)table, MinTable = (int)minTable, Baseline = baseline };
    foreach (var m in fields.Members) version.Fields[m.Key] = m.Value;
    foreach (var m in stamps.Members) version.Stamps[m.Key] = Stamp(m.Value);
    if (!version.Fields.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(version.Stamps.Keys)) throw new CloudMergeInvalid();
    foreach (var field in collections.Members)
    {
      var elements = new Dictionary<string, CloudMergeElement>(StringComparer.Ordinal);
      foreach (var row in CloudRecordJson.Items(field.Value) ?? [])
      {
        if (CloudRecordJson.Text(CloudRecordJson.Get(row, "id")) is not { Length: > 0 } id || !CloudRecordJson.Has(row, "value")) throw new CloudMergeInvalid();
        elements[id] = new(id, CloudRecordJson.Get(row, "value")!, Stamp(CloudRecordJson.Get(row, "stamp")));
      }
      version.Collections[field.Key] = elements;
    }
    foreach (var field in removed.Members)
    {
      var ids = new Dictionary<string, CloudMergeStamp>(StringComparer.Ordinal);
      foreach (var row in CloudRecordJson.Items(field.Value) ?? [])
      {
        if (CloudRecordJson.Text(CloudRecordJson.Get(row, "id")) is not { Length: > 0 } id) throw new CloudMergeInvalid();
        ids[id] = Stamp(CloudRecordJson.Get(row, "stamp"));
      }
      version.Removed[field.Key] = ids;
    }
    var seen = new HashSet<(string, string)>();
    foreach (var row in conflicts)
    {
      if (CloudRecordJson.Text(CloudRecordJson.Get(row, "field")) is not { } field || CloudRecordJson.Text(CloudRecordJson.Get(row, "revision")) is not { } revision
        || CloudRecordJson.Text(CloudRecordJson.Get(row, "device")) is not { } device || !CloudRecordJson.Has(row, "value")) throw new CloudMergeInvalid();
      var conflict = new CloudMergeConflict(field, revision, CloudRecordJson.Get(row, "value")!, device, Exact(CloudRecordJson.Get(row, "time")));
      if (seen.Add(conflict.Identity)) version.Conflicts.Add(conflict);
    }
    return version;
  }

  /// Every revision id this payload names: its stamps, element and removal stamps, carried other versions.
  public HashSet<string> Referenced()
  {
    var ids = new HashSet<string>(Stamps.Values.Select(s => s.Op), StringComparer.Ordinal);
    foreach (var elements in Collections.Values) ids.UnionWith(elements.Values.Select(e => e.Stamp.Op));
    foreach (var marks in Removed.Values) ids.UnionWith(marks.Values.Select(m => m.Op));
    ids.UnionWith(Conflicts.Select(c => c.Revision));
    return ids;
  }
}

/// The small part of a revision, kept for every revision of a record.
public sealed record CloudMergeNode
{
  public CloudMergeNode(string opId, IEnumerable<string> parents, string device, long time, bool baseline)
  {
    OpId = opId; Parents = parents.OrderBy(p => p, StringComparer.Ordinal).ToArray(); Device = device; Time = time; Baseline = baseline;
  }
  public string OpId { get; }
  public IReadOnlyList<string> Parents { get; }
  public string Device { get; }
  public long Time { get; }
  public bool Baseline { get; }
}

/// A whole revision as written or received: the node plus its payload.
public sealed record CloudMergeRevision(CloudMergeNode Node, CloudMergeVersion Version)
{
  public string OpId => Node.OpId;
  public IReadOnlyList<string> Parents => Node.Parents;
  public long Time => Node.Time;
}

/// The nodes of one record known on this device. Every function is independent of insertion order.
public sealed class CloudMergeGraph
{
  public Dictionary<string, CloudMergeNode> Nodes { get; } = new(StringComparer.Ordinal);
  public CloudMergeGraph(IEnumerable<CloudMergeNode>? nodes = null) { foreach (var node in nodes ?? []) Add(node); }
  public void Add(CloudMergeNode node) => Nodes.TryAdd(node.OpId, node);
  public IReadOnlyList<string> Heads
  {
    get
    {
      var parents = Nodes.Values.SelectMany(n => n.Parents).ToHashSet(StringComparer.Ordinal);
      return Nodes.Keys.Where(k => !parents.Contains(k)).OrderBy(k => k, StringComparer.Ordinal).ToArray();
    }
  }
  public IReadOnlyList<string> Missing(IEnumerable<string> heads)
  {
    var queue = heads.ToList(); var seen = new HashSet<string>(StringComparer.Ordinal); var missing = new SortedSet<string>(StringComparer.Ordinal);
    for (var i = 0; i < queue.Count; i++)
    {
      var id = queue[i];
      if (!seen.Add(id)) continue;
      if (!Nodes.TryGetValue(id, out var node)) { missing.Add(id); continue; }
      queue.AddRange(node.Parents);
    }
    return missing.ToArray();
  }
  /// True when `ancestor` is a strict ancestor of `descendant`.
  public bool IsAncestor(string ancestor, string descendant)
  {
    if (ancestor == descendant) return false;
    var queue = Nodes.TryGetValue(descendant, out var start) ? start.Parents.ToList() : [];
    var seen = new HashSet<string>(StringComparer.Ordinal);
    for (var i = 0; i < queue.Count; i++)
    {
      var id = queue[i];
      if (id == ancestor) return true;
      if (!seen.Add(id)) continue;
      if (Nodes.TryGetValue(id, out var node)) queue.AddRange(node.Parents);
    }
    return false;
  }
  public bool Seen(string ancestor, string descendant) => ancestor == descendant || IsAncestor(ancestor, descendant);
  public bool IsBaseline(string op) => Nodes.TryGetValue(op, out var node) && node.Baseline;
}

/// The shown record: a pure function of the head payloads and the graph.
public sealed class CloudMergeView
{
  public required IReadOnlyList<string> Heads { get; init; }
  public required Dictionary<string, CloudJson> Fields { get; init; }
  public required Dictionary<string, CloudMergeStamp> Stamps { get; init; }
  public required Dictionary<string, List<CloudMergeElement>> Collections { get; init; }
  public required Dictionary<string, Dictionary<string, CloudMergeStamp>> Removed { get; init; }
  public required IReadOnlyList<CloudMergeConflict> Conflicts { get; init; }
  public required int MinTable { get; init; }
  public bool Exists => CloudRecordJson.Bool(Fields.GetValueOrDefault(CloudRecordMerge.ExistsField)) ?? true;
  /// The record as an object: travelling fields (not `$exists`) and each collection as an ordered array of values.
  public CloudJson.Object Shown()
  {
    var pairs = Fields.Where(f => f.Key != CloudRecordMerge.ExistsField).Select(f => (f.Key, f.Value)).ToList();
    foreach (var (name, elements) in Collections) pairs.Add((name, CloudJson.Arr(elements.Select(e => e.Value))));
    return CloudRecordJson.Sorted(pairs);
  }
}

public static class CloudRecordMerge
{
  public const string ExistsField = "$exists";

  public static bool Same(CloudJson a, CloudJson b) => CloudRecordJson.Same(a, b);
  /// Element identity: its own `id`, otherwise `h:` + sha256 of its canonical bytes.
  public static string ElementId(CloudJson element)
  {
    if (CloudRecordJson.Text(CloudRecordJson.Get(element, "id")) is { Length: > 0 } id) return id;
    return "h:" + CloudBytes.Sha256Hex(CloudCanonical.Encode(element));
  }
  /// Element order: its own `at` time when it is an exact integer (rounded down), else its stamp time, then id.
  public static (long, string) OrderKey(CloudJson value, string id, CloudMergeStamp stamp) =>
    (CloudRecordJson.Number(CloudRecordJson.Get(value, "at")) is { } at && CloudRecordJson.Exact(Math.Floor(at)) is { } whole ? whole : stamp.Time, id);
  private static int CompareKey((long, string) a, (long, string) b) => a.Item1 != b.Item1 ? a.Item1.CompareTo(b.Item1) : string.CompareOrdinal(a.Item2, b.Item2);
  public static int ElementOrder(CloudMergeElement a, CloudMergeElement b) => CompareKey(OrderKey(a.Value, a.Id, a.Stamp), OrderKey(b.Value, b.Id, b.Stamp));

  private sealed record Candidate(CloudJson Value, CloudMergeStamp Stamp, string Head);
  private enum Preference { None, Truth, SmallestPositive }
  private static Preference PreferenceOf(string name, CloudMergeTable table)
  {
    if (name == ExistsField) return Preference.Truth;
    return table.FieldClass(name) switch { CloudMergeClass.Raise => Preference.Truth, CloudMergeClass.Shrink => Preference.SmallestPositive, _ => Preference.None };
  }

  /// The n-way rule for one field: drop candidates whose stamping revision another candidate's had seen; then rule J (a
  /// baseline loses to any ordinary stamp) before "an edit beats a removal"; among ordinary stamps the newest wins,
  /// among baselines the oldest.
  private static (Candidate Winner, List<Candidate> Losers)? Pick(IEnumerable<Candidate> candidates, CloudMergeGraph graph, Preference prefer = Preference.None)
  {
    var byOp = new Dictionary<string, Candidate>(StringComparer.Ordinal);
    foreach (var c in candidates.OrderBy(c => c.Head, StringComparer.Ordinal)) byOp.TryAdd(c.Stamp.Op, c);
    var all = byOp.Values.OrderBy(c => c.Stamp.Op, StringComparer.Ordinal).ToList();
    var undominated = all.Where(c => !all.Any(d => d.Stamp.Op != c.Stamp.Op && graph.IsAncestor(c.Stamp.Op, d.Stamp.Op))).ToList();
    var ordinary = undominated.Where(c => !graph.IsBaseline(c.Stamp.Op)).ToList();
    var pool = ordinary.Count == 0 ? undominated : ordinary;
    Candidate? preferred = null;
    switch (prefer)
    {
      case Preference.Truth:
        var trues = pool.Where(c => CloudRecordJson.Bool(c.Value) == true).ToList(); if (trues.Count > 0) pool = trues;
        break;
      case Preference.SmallestPositive:
        preferred = pool.Where(c => (CloudRecordJson.Number(c.Value) ?? 0) > 0)
          .OrderBy(c => CloudRecordJson.Number(c.Value)!.Value).ThenBy(c => c.Stamp.Op, StringComparer.Ordinal).FirstOrDefault();
        break;
    }
    Candidate? winner = preferred;
    if (winner is null && pool.Count > 0)
    {
      winner = pool[0];
      foreach (var c in pool.Skip(1))
      {
        var order = CloudMergeStamp.Compare(c.Stamp, winner.Stamp);
        if (ordinary.Count == 0 ? order < 0 : order > 0) winner = c;
      }
    }
    if (winner is null) return null;
    var losers = undominated.Where(c => c.Stamp.Op != winner.Stamp.Op && !Same(c.Value, winner.Value)).ToList();
    return (winner, losers);
  }

  /// The view over a head set. `payloads` needs only the heads. Throws when a head, a parent on the history or a revision
  /// a stamp names is not held, so the record waits instead of differing.
  public static CloudMergeView View(IEnumerable<string> heads, IReadOnlyDictionary<string, CloudMergeVersion> payloads, CloudMergeGraph graph, CloudMergeTable table)
  {
    var ids = heads.Distinct(StringComparer.Ordinal).OrderBy(h => h, StringComparer.Ordinal).ToArray();
    var missing = new HashSet<string>(graph.Missing(ids), StringComparer.Ordinal);
    var versions = new List<(string Head, CloudMergeVersion Version)>();
    foreach (var id in ids) { if (payloads.TryGetValue(id, out var v)) versions.Add((id, v)); else missing.Add(id); }
    foreach (var (_, version) in versions) missing.UnionWith(version.Referenced().Where(r => !graph.Nodes.ContainsKey(r)));
    if (missing.Count > 0) throw new CloudMergeHistoryIncomplete(missing.OrderBy(m => m, StringComparer.Ordinal).ToArray());

    var fields = new Dictionary<string, CloudJson>(StringComparer.Ordinal);
    var stamps = new Dictionary<string, CloudMergeStamp>(StringComparer.Ordinal);
    var found = new List<CloudMergeConflict>();
    var names = versions.SelectMany(v => v.Version.Fields.Keys).Distinct(StringComparer.Ordinal).OrderBy(n => n, StringComparer.Ordinal).ToArray();
    var follows = new List<(string Name, CloudMergeFollow Rule)>();
    foreach (var name in names)
    {
      if (table.FieldClass(name) is CloudMergeClass.Follows { Rule: var rule }) { follows.Add((name, rule)); continue; }
      var candidates = versions.Where(v => v.Version.Stamps.ContainsKey(name))
        .Select(v => new Candidate(v.Version.Fields.GetValueOrDefault(name) ?? CloudJson.Null.Value, v.Version.Stamps[name], v.Head)).ToList();
      if (Pick(candidates, graph, PreferenceOf(name, table)) is not { } result) continue;
      fields[name] = result.Winner.Value; stamps[name] = result.Winner.Stamp;
      foreach (var loser in result.Losers)
        found.Add(new(name, loser.Stamp.Op, loser.Value, graph.Nodes.TryGetValue(loser.Stamp.Op, out var n) ? n.Device : "", loser.Stamp.Time));
    }
    foreach (var (name, rule) in follows)
    {
      var holders = versions.Where(v => v.Version.Stamps.ContainsKey(name)).ToList();
      (string Head, CloudMergeVersion Version)? chosen = null;
      static int Numbered((string Head, CloudMergeVersion Version) a, (string Head, CloudMergeVersion Version) b, string name)
      {
        var x = CloudRecordJson.Number(a.Version.Fields[name])!.Value; var y = CloudRecordJson.Number(b.Version.Fields[name])!.Value;
        return x != y ? x.CompareTo(y) : string.CompareOrdinal(a.Head, b.Head);
      }
      var numbered = holders.Where(h => CloudRecordJson.Number(h.Version.Fields.GetValueOrDefault(name)) is not null).ToList();
      switch (rule)
      {
        case CloudMergeFollow.Newest or CloudMergeFollow.Touched:
          foreach (var h in numbered) if (chosen is null || Numbered(h, chosen.Value, name) > 0) chosen = h;
          break;
        case CloudMergeFollow.Oldest:
          foreach (var h in numbered) if (chosen is null || Numbered(h, chosen.Value, name) < 0) chosen = h;
          break;
        case CloudMergeFollow.Partner { Field: var partner }:
          var agreeing = stamps.TryGetValue(partner, out var winner) ? holders.Where(h => h.Version.Stamps.TryGetValue(partner, out var s) && s == winner).ToList() : holders;
          foreach (var h in agreeing.Count == 0 ? holders : agreeing)
            if (chosen is null || CloudMergeStamp.Compare(h.Version.Stamps[name], chosen.Value.Version.Stamps[name]) > 0) chosen = h;
          break;
      }
      chosen ??= holders.OrderBy(h => h.Head, StringComparer.Ordinal).Select(h => ((string, CloudMergeVersion)?)h).FirstOrDefault();
      if (chosen is { } pick) { fields[name] = pick.Version.Fields.GetValueOrDefault(name) ?? CloudJson.Null.Value; stamps[name] = pick.Version.Stamps[name]; }
    }
    // Collections: union by element id minus removals that had seen the element's last change; the cap keeps the newest N.
    var collections = new Dictionary<string, List<CloudMergeElement>>(StringComparer.Ordinal);
    var removed = new Dictionary<string, Dictionary<string, CloudMergeStamp>>(StringComparer.Ordinal);
    var collectionNames = versions.SelectMany(v => v.Version.Collections.Keys.Concat(v.Version.Removed.Keys)).Distinct(StringComparer.Ordinal).OrderBy(n => n, StringComparer.Ordinal);
    foreach (var name in collectionNames)
    {
      var elementIds = versions.SelectMany(v => (v.Version.Collections.GetValueOrDefault(name)?.Keys ?? Enumerable.Empty<string>())
        .Concat(v.Version.Removed.GetValueOrDefault(name)?.Keys ?? Enumerable.Empty<string>())).Distinct(StringComparer.Ordinal).OrderBy(n => n, StringComparer.Ordinal);
      var kept = new List<CloudMergeElement>(); var gone = new Dictionary<string, CloudMergeStamp>(StringComparer.Ordinal);
      foreach (var id in elementIds)
      {
        var candidates = versions.Where(v => v.Version.Collections.GetValueOrDefault(name)?.ContainsKey(id) == true)
          .Select(v => { var e = v.Version.Collections[name][id]; return new Candidate(e.Value, e.Stamp, v.Head); }).ToList();
        var removals = versions.Select(v => v.Version.Removed.GetValueOrDefault(name)).Where(r => r?.ContainsKey(id) == true).Select(r => r![id])
          .Distinct().OrderBy(s => s.Time).ThenBy(s => s.Op, StringComparer.Ordinal).ToList();
        var live = candidates.Where(c => !removals.Any(r => graph.Seen(c.Stamp.Op, r.Op))).ToList();
        if (Pick(live, graph) is { } result) kept.Add(new(id, result.Winner.Value, result.Winner.Stamp));
        else if (removals.Count > 0) gone[id] = removals[^1];
      }
      kept.Sort(ElementOrder);
      if (table.FieldClass(name) is CloudMergeClass.Collection { Cap: { } cap } && kept.Count > cap) kept = kept.Skip(kept.Count - cap).ToList();
      collections[name] = kept;
      if (gone.Count > 0) removed[name] = gone;
    }
    // Other versions. An entry clears when the shown value equals it, or when the revision that set the shown value had
    // seen it AND no head holding that winning stamp still carries it (a re-mark is not an edit).
    var conflicts = new Dictionary<(string, string), CloudMergeConflict>();
    foreach (var entry in versions.SelectMany(v => v.Version.Conflicts).Concat(found))
    {
      if (!stamps.TryGetValue(entry.Field, out var winner)) continue;
      if (fields.TryGetValue(entry.Field, out var shown) && Same(shown, entry.Value)) continue;
      if (graph.Seen(entry.Revision, winner.Op))
      {
        var stillCarried = versions.Any(v => v.Version.Stamps.TryGetValue(entry.Field, out var s) && s == winner && v.Version.Conflicts.Any(c => c.Identity == entry.Identity));
        if (!stillCarried) continue;
      }
      conflicts.TryAdd(entry.Identity, entry);
    }
    return new CloudMergeView
    {
      Heads = ids, Fields = fields, Stamps = stamps, Collections = collections, Removed = removed,
      Conflicts = conflicts.Values.OrderBy(c => c.Field, StringComparer.Ordinal).ThenBy(c => c.Revision, StringComparer.Ordinal).ToArray(),
      MinTable = versions.Count == 0 ? 1 : versions.Max(v => v.Version.MinTable)
    };
  }

  /// Owner-side rule for a value arriving from another device: `Raise` never turns off; `Shrink` takes only a positive
  /// value no larger than the current limit. Everything else is decided elsewhere (true). null = missing.
  public static bool MayApply(CloudMergeClass? kind, CloudJson? before, CloudJson? after)
  {
    if (CloudRecordJson.Same(before, after)) return true;
    switch (kind)
    {
      case CloudMergeClass.Raise: return CloudRecordJson.Bool(after) == true;
      case CloudMergeClass.Shrink:
        if (CloudRecordJson.Number(after) is not { } value || value <= 0) return false;
        return CloudRecordJson.Number(before) is not { } limit || limit <= 0 || value <= limit;
      default: return true;
    }
  }

  /// A new revision over `view`, deciding "changed here" against `image`, what this device last STORED for those heads.
  /// `local` null = removed here. `held` fields are sent with the view's value and stamp. `chosen` fields are a deliberate
  /// pick, stamped now even when equal to the image. `restore` is an explicit undo of a removal. Null when nothing
  /// deliberate changed (a change to touched follows fields alone is no revision).
  public static CloudMergeRevision? Revision(CloudMergeView? view, CloudJson.Object? image, CloudJson.Object? local, IReadOnlySet<string>? held, IReadOnlySet<string>? chosen,
    bool restore, CloudMergeTable table, string opId, string device, long now, bool baseline, CloudMergeGraph graph)
  {
    IReadOnlySet<string> holding = held ?? new HashSet<string>(), picked = chosen ?? new HashSet<string>();
    IReadOnlyList<string> parents = baseline || view is null ? Array.Empty<string>() : view.Heads;
    var parentTimes = parents.Where(graph.Nodes.ContainsKey).Select(p => graph.Nodes[p].Time).ToList();
    var newestParent = parentTimes.Count == 0 ? long.MinValue : parentTimes.Max();
    var time = Math.Max(now, newestParent == long.MaxValue ? long.MaxValue : Math.Max(newestParent, long.MinValue + 1) + 1);
    var stamp = new CloudMergeStamp(time, opId);
    var fields = view is null ? new Dictionary<string, CloudJson>(StringComparer.Ordinal) : new Dictionary<string, CloudJson>(view.Fields, StringComparer.Ordinal);
    var stamps = view is null ? new Dictionary<string, CloudMergeStamp>(StringComparer.Ordinal) : new Dictionary<string, CloudMergeStamp>(view.Stamps, StringComparer.Ordinal);
    var collections = new Dictionary<string, Dictionary<string, CloudMergeElement>>(StringComparer.Ordinal);
    foreach (var (name, elements) in view?.Collections ?? new Dictionary<string, List<CloudMergeElement>>()) collections[name] = elements.ToDictionary(e => e.Id, e => e, StringComparer.Ordinal);
    var removed = new Dictionary<string, Dictionary<string, CloudMergeStamp>>(StringComparer.Ordinal);
    foreach (var (name, marks) in view?.Removed ?? new Dictionary<string, Dictionary<string, CloudMergeStamp>>()) removed[name] = new(marks, StringComparer.Ordinal);
    var edited = new HashSet<string>(StringComparer.Ordinal);
    void Set(string name, CloudJson value, bool force = false)
    {
      if (!force && fields.TryGetValue(name, out var old) && Same(old, value)) return;
      fields[name] = value; stamps[name] = stamp; edited.Add(name);
    }
    CloudMergeRevision? Finish()
    {
      var touched = table.Classes.Where(c => c.Value is CloudMergeClass.Follows { Rule: CloudMergeFollow.Touched }).Select(c => c.Key).ToHashSet(StringComparer.Ordinal);
      if (!edited.Except(touched).Any()) return null;
      // Every edit re-marks that the record exists; the re-mark is not an edit of `$exists`.
      if (!edited.Contains(ExistsField)) { fields[ExistsField] = CloudJson.From(true); stamps[ExistsField] = stamp; }
      var conflicts = (view?.Conflicts ?? Array.Empty<CloudMergeConflict>()).Where(c => !edited.Contains(c.Field) && !picked.Contains(c.Field)).ToList();
      var introduced = edited.Count == 0 ? 1 : edited.Max(e => table.Introduced.GetValueOrDefault(e, 1));
      var version = new CloudMergeVersion
      {
        Table = table.Version, MinTable = Math.Max(view?.MinTable ?? 1, introduced), Baseline = baseline, Fields = fields, Stamps = stamps,
        Collections = collections, Removed = removed, Conflicts = conflicts
      };
      return new(new CloudMergeNode(opId, parents, device, time, baseline), version);
    }
    if (local is null)
    {
      // Removed here: only a record this device held and the view still shows.
      if (image is null || view is null || !view.Exists) return null;
      Set(ExistsField, CloudJson.From(false));
      return Finish();
    }
    if (view is not null && !view.Exists)
    {
      if (!restore && !baseline) return null;
      Set(ExistsField, CloudJson.From(true));
    }
    else if (view is null) Set(ExistsField, CloudJson.From(true));
    foreach (var name in picked.Where(n => !holding.Contains(n)))
    {
      if (name == ExistsField) Set(ExistsField, CloudJson.From(true), force: true);
      else Set(name, CloudRecordJson.Has(local, name) ? CloudRecordJson.Get(local, name)! : CloudJson.Null.Value, force: true);
    }
    foreach (var (name, kind) in table.Classes.OrderBy(c => c.Key, StringComparer.Ordinal))
    {
      if (holding.Contains(name) || picked.Contains(name)) continue;
      switch (kind)
      {
        case CloudMergeClass.ThisDevice: continue;
        case CloudMergeClass.Identity:
          if (!fields.ContainsKey(name) && CloudRecordJson.Has(local, name)) Set(name, CloudRecordJson.Get(local, name)!);
          break;
        case CloudMergeClass.Collection { Cap: var cap }:
          {
            if (!CloudRecordJson.Has(local, name)) continue;
            var current = collections.TryGetValue(name, out var c) ? c : new Dictionary<string, CloudMergeElement>(StringComparer.Ordinal);
            var mine = new Dictionary<string, CloudJson>(StringComparer.Ordinal);
            foreach (var element in CloudRecordJson.Items(CloudRecordJson.Get(local, name)) ?? []) mine[ElementId(element)] = element;
            Dictionary<string, CloudJson>? stored = null;
            if (image is not null && CloudRecordJson.Has(image, name))
            {
              stored = new(StringComparer.Ordinal);
              foreach (var element in CloudRecordJson.Items(CloudRecordJson.Get(image, name)) ?? []) stored[ElementId(element)] = element;
            }
            var touchedCollection = false;
            foreach (var (id, element) in mine)
            {
              if (stored is not null && stored.TryGetValue(id, out var before) && Same(before, element)) continue;
              if (current.TryGetValue(id, out var existing) && Same(existing.Value, element)) continue;
              current[id] = new(id, element, stamp);
              if (removed.TryGetValue(name, out var marks)) marks.Remove(id);
              touchedCollection = true;
            }
            if (stored is not null)
            {
              var union = new Dictionary<string, CloudJson>(stored, StringComparer.Ordinal);
              foreach (var (id, value) in mine) union[id] = value;
              HashSet<string>? newest = cap is { } limit
                ? union.Select(u => (Key: OrderKey(u.Value, u.Key, current.TryGetValue(u.Key, out var e) ? e.Stamp : stamp), Id: u.Key))
                    .OrderBy(u => u.Key, Comparer<(long, string)>.Create(CompareKey)).TakeLast(limit).Select(u => u.Id).ToHashSet(StringComparer.Ordinal)
                : null;
              foreach (var id in stored.Keys.OrderBy(k => k, StringComparer.Ordinal))
              {
                if (mine.ContainsKey(id) || !current.ContainsKey(id)) continue;
                if (newest is not null && !newest.Contains(id)) continue;
                current.Remove(id);
                if (!removed.TryGetValue(name, out var marks)) removed[name] = marks = new(StringComparer.Ordinal);
                marks[id] = stamp; touchedCollection = true;
              }
            }
            if (!touchedCollection) continue;
            if (cap is { } most)
            {
              var ordered = current.Values.ToList(); ordered.Sort(ElementOrder);
              if (ordered.Count > most) foreach (var element in ordered.Take(ordered.Count - most)) current.Remove(element.Id);
              if (removed.TryGetValue(name, out var marks) && marks.Count > most)
                removed[name] = marks.OrderBy(m => m.Value.Time).ThenBy(m => m.Value.Op, StringComparer.Ordinal).TakeLast(most).ToDictionary(m => m.Key, m => m.Value, StringComparer.Ordinal);
            }
            collections[name] = current; edited.Add(name);
            break;
          }
        default:
          if (CloudRecordJson.Has(local, name))
          {
            // Unchanged here when it equals what this device stored, whatever the view says now.
            if (image is not null && CloudRecordJson.Has(image, name) && Same(CloudRecordJson.Get(image, name)!, CloudRecordJson.Get(local, name)!)) continue;
            Set(name, CloudRecordJson.Get(local, name)!);
          }
          else if (image is not null && CloudRecordJson.Has(image, name) && !CloudRecordJson.Nullish(CloudRecordJson.Get(image, name)))
            // Cleared here only when this device had stored a value; a store that never had the field says nothing.
            Set(name, CloudJson.Null.Value);
          break;
      }
    }
    return Finish();
  }

  internal static string Number(long value) => value.ToString(CultureInfo.InvariantCulture);
}
