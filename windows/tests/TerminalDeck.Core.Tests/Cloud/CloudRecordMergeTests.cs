using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-2: the record merge ported from the Mac (CloudBrainAgentsMerge.swift, CloudBrainAgentsFieldTables.swift). The
// scenarios are the Mac's own tests (CloudBrainAgentsMergeTests.swift) run against the port; the signed field tables are
// compared with the Mac's checked-in signed copy (CloudBrainAgentsFieldTableTests.swift). The Mac's tests hold no
// Swift-made payload bytes, so the golden payload below is written out by hand from CloudBrainMergeVersion.payload().
public sealed class CloudRecordMergeTests
{
  private static readonly CloudMergeTable Table = new("fixture", 1, new Dictionary<string, CloudMergeClass>(StringComparer.Ordinal)
  {
    ["id"] = CloudMergeClass.IdentityField, ["title"] = CloudMergeClass.SharedField, ["due"] = CloudMergeClass.SharedField, ["priority"] = CloudMergeClass.SharedField,
    ["status"] = CloudMergeClass.SharedField, ["place"] = CloudMergeClass.SharedField, ["statusAt"] = new CloudMergeClass.Follows(new CloudMergeFollow.Partner("status")),
    ["updatedAt"] = new CloudMergeClass.Follows(new CloudMergeFollow.Touched()), ["archivedAt"] = new CloudMergeClass.Follows(new CloudMergeFollow.Newest()),
    ["notes"] = new CloudMergeClass.Collection(100), ["permissionMode"] = CloudMergeClass.WideningField, ["sessionId"] = CloudMergeClass.ThisDeviceField,
    ["decisionRequired"] = CloudMergeClass.RaiseField, ["tokenBudget"] = CloudMergeClass.ShrinkField, ["hops"] = new CloudMergeClass.Follows(new CloudMergeFollow.Newest()),
  });

  /// One device of the Mac's merge tests: its graph, head payloads and stored image, all in memory.
  private sealed class Mac(string device)
  {
    public readonly CloudMergeGraph Graph = new();
    public readonly Dictionary<string, CloudMergeVersion> Payloads = new(StringComparer.Ordinal);
    public CloudJson.Object? Image;
    public CloudMergeView? View()
    {
      var heads = Graph.Heads;
      return heads.Count == 0 ? null : CloudRecordMerge.View(heads, Payloads.Where(p => heads.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value), Graph, Table);
    }
    private void Remember(CloudMergeRevision revision) { Graph.Add(revision.Node); Payloads[revision.OpId] = revision.Version; }
    public void Receive(params CloudMergeRevision[] revisions)
    {
      foreach (var revision in revisions) Remember(revision);
      var view = View();
      Image = view is { Exists: true } ? view.Shown() : null;
    }
    public CloudMergeRevision? Edit(string op, long at, Func<CloudJson.Object?, CloudJson.Object?> change, bool baseline = false)
    {
      var local = change(Image);
      var revision = CloudRecordMerge.Revision(View(), baseline ? null : Image, local, null, null, false, Table, op, device, at, baseline, Graph);
      if (revision is not null) Remember(revision);
      Image = local;
      return revision;
    }
  }
  private static CloudJson.Object Base => CloudRecordJson.Object([("id", CloudJson.From("t1")), ("title", CloudJson.From("T")), ("due", CloudJson.From("d0")),
    ("priority", CloudJson.From("p0")), ("status", CloudJson.From("open")), ("statusAt", CloudJson.From(1)), ("place", CloudJson.From("tasks")),
    ("notes", CloudJson.Arr([])), ("permissionMode", CloudJson.From("default")), ("decisionRequired", CloudJson.From(false)), ("tokenBudget", CloudJson.From(300)),
    ("hops", CloudJson.From(0))]);
  private static Func<CloudJson.Object?, CloudJson.Object?> Set(string key, string value) => image => image is null ? null : CloudRecordJson.Set(image, key, CloudJson.From(value));
  private static (Mac A, Mac[] Others, CloudMergeRevision R0) Start(int others)
  {
    var a = new Mac("mac-a");
    var r0 = a.Edit("r0", 1_000, _ => Base)!;
    var macs = Enumerable.Range(0, others).Select(i => { var mac = new Mac("mac-" + i); mac.Receive(r0); return mac; }).ToArray();
    return (a, macs, r0);
  }
  private static string? Title(CloudMergeView? view) => CloudRecordJson.Text(view?.Fields.GetValueOrDefault("title"));

  [Fact]
  public void An_unrelated_later_edit_cannot_flip_a_disputed_field()
  {
    var (a, others, r0) = Start(2);
    var (b, c) = (others[0], others[1]);
    var rA = a.Edit("rA", 1_002, Set("title", "Ship notes"))!;
    var rB = b.Edit("rB", 1_005, Set("title", "Ship release notes"))!;
    c.Receive(rA);
    var rC = c.Edit("rC", 1_030, Set("due", "tomorrow"))!;
    var everyone = new Mac("mac-x"); everyone.Receive(r0, rA, rB, rC);
    var view = everyone.View()!;
    Assert.Equal("Ship release notes", Title(view));
    Assert.Equal("tomorrow", CloudRecordJson.Text(view.Fields["due"]));
    Assert.Equal(new[] { "rA" }, view.Conflicts.Select(x => x.Revision).ToArray());
  }

  [Fact]
  public void First_sign_in_the_Clouds_version_wins_and_the_joiner_is_listed()
  {
    var (a, _, r0) = Start(0);
    var b = new Mac("mac-b"); b.Receive(r0);
    var joined = b.Edit("rBase", 999_999, _ => CloudRecordJson.Set(Base, "title", CloudJson.From("B's own title")), baseline: true)!;
    Assert.Empty(joined.Parents);
    a.Receive(joined); b.Receive();
    foreach (var mac in new[] { a, b })
    {
      var view = mac.View()!;
      Assert.Equal("T", Title(view));
      var kept = Assert.Single(view.Conflicts);
      Assert.Equal(("title", "rBase", "B's own title"), (kept.Field, kept.Revision, CloudRecordJson.Text(kept.Value)));
    }
    Assert.False(r0.Version.Baseline);
  }

  [Fact]
  public void Between_two_baselines_the_older_wins()
  {
    var b = new Mac("mac-b"); var c = new Mac("mac-c");
    var rB = b.Edit("rB", 2_000, _ => CloudRecordJson.Object([("title", CloudJson.From("B"))]), baseline: true)!;
    var rC = c.Edit("rC", 3_000, _ => CloudRecordJson.Object([("title", CloudJson.From("C"))]), baseline: true)!;
    b.Receive(rC); c.Receive(rB);
    Assert.Equal("B", Title(b.View()));
    Assert.Equal("B", Title(c.View()));
  }

  [Fact]
  public void A_joiner_cannot_bring_back_a_record_the_Cloud_removed()
  {
    var (a, _, r0) = Start(0);
    var removal = a.Edit("rm", 2_000, _ => null)!;
    var joiner = new Mac("mac-j"); joiner.Receive(r0, removal);
    var baseline = joiner.Edit("join", 9_000, _ => CloudRecordJson.Set(Base, "title", CloudJson.From("Joiner's old copy")), baseline: true)!;
    a.Receive(baseline);
    foreach (var mac in new[] { a, joiner })
    {
      var view = mac.View()!;
      Assert.False(view.Exists);
      Assert.Contains(view.Conflicts, x => x.Field == CloudRecordMerge.ExistsField && x.Revision == "join");
    }
  }

  [Fact]
  public void Changed_here_is_judged_against_the_stored_image()
  {
    var (_, others, _) = Start(1);
    var b = others[0];
    b.Image = CloudRecordJson.Remove(b.Image!, "priority");
    Assert.Null(b.Edit("noop", 1_100, x => x));
    var edit = b.Edit("e1", 1_200, Set("due", "d1"))!;
    Assert.Equal("p0", CloudRecordJson.Text(edit.Version.Fields["priority"]));
    var cleared = b.Edit("e2", 1_300, x => CloudRecordJson.Remove(x!, "due"))!;
    Assert.True(CloudRecordJson.Nullish(cleared.Version.Fields["due"]));
  }

  [Fact]
  public void Identical_versions_and_double_removals_collapse()
  {
    var (a, others, _) = Start(1);
    var b = others[0];
    var rA = a.Edit("rA", 1_100, Set("title", "Same"))!;
    var rB = b.Edit("rB", 1_200, Set("title", "Same"))!;
    a.Receive(rB); b.Receive(rA);
    Assert.Empty(a.View()!.Conflicts);
    var removeA = a.Edit("xA", 1_300, _ => null)!;
    var removeB = b.Edit("xB", 1_310, _ => null)!;
    a.Receive(removeB); b.Receive(removeA);
    Assert.False(a.View()!.Exists);
    Assert.Empty(a.View()!.Conflicts);
  }

  [Fact]
  public void A_payload_round_trips_and_a_bad_number_is_refused()
  {
    var (a, _, _) = Start(0);
    var r = a.Edit("rN", 1_500, x => CloudRecordJson.Set(x!, "notes", CloudJson.Arr([CloudRecordJson.Object([("id", CloudJson.From("n1")), ("at", CloudJson.From(5)), ("text", CloudJson.From("hi"))])])))!;
    var bytes = CloudCanonical.Encode(r.Version.Payload());
    Assert.Equal(bytes, CloudCanonical.Encode(CloudMergeVersion.Parse(CloudJson.Parse(bytes)).Payload()));
    var bad = CloudRecordJson.Set(r.Version.Payload(), "table", CloudJson.From(1.5));
    Assert.Throws<CloudMergeInvalid>(() => CloudMergeVersion.Parse(bad));
  }

  /// A project as the Mac's projects owner first captures it (BackendCloudLeanProjects.record → CloudBrainMerge.revision
  /// with no view and no image, not a baseline): every travelling field and `$exists` stamped with the one revision.
  /// Written out from CloudBrainMergeVersion.payload() and CloudSyncCanonical (no Swift-made vector exists for it).
  [Fact]
  public void Golden_project_payload_matches_the_Macs_shape_byte_for_byte()
  {
    const string op = "4b3f2a1c-9d8e-4f70-a1b2-c3d4e5f60718";
    var local = CloudRecordJson.Object([("id", CloudJson.From("deck")), ("name", CloudJson.From("Deck")), ("icon", CloudJson.From("folder")),
      ("colour", CloudJson.From("blue")), ("lead", CloudJson.From("")), ("leadName", CloudJson.From(""))]);
    var revision = CloudRecordMerge.Revision(null, null, local, null, null, false, CloudMergeTables.Project, op, "7f306256-7209-4b63-962b-14a7b01b12ee", 1_763_000_000_000, false, new CloudMergeGraph())!;
    var stamp = "[1763000000000,\"" + op + "\"]";
    var expected = "{\"baseline\":false,\"collections\":{},\"conflicts\":[],\"fields\":{\"$exists\":true,\"colour\":\"blue\",\"icon\":\"folder\",\"id\":\"deck\",\"lead\":\"\",\"leadName\":\"\",\"name\":\"Deck\"},"
      + "\"minTable\":1,\"removed\":{},\"stamps\":{\"$exists\":" + stamp + ",\"colour\":" + stamp + ",\"icon\":" + stamp + ",\"id\":" + stamp + ",\"lead\":" + stamp
      + ",\"leadName\":" + stamp + ",\"name\":" + stamp + "},\"table\":1}";
    Assert.Equal(expected, Encoding.UTF8.GetString(CloudCanonical.Encode(revision.Version.Payload())));
    Assert.Equal(1_763_000_000_000, revision.Time);
    Assert.Empty(revision.Parents);
  }

  // ---- the signed field list (Ruling 3), the Mac's checked-in copy ----

  private static Dictionary<string, string> Classes(params (string Kind, string[] Keys)[] rows)
  {
    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var (kind, keys) in rows) foreach (var key in keys) result[key] = kind;
    return result;
  }
  private static readonly Dictionary<string, Dictionary<string, string>> Signed = new()
  {
    ["task"] = Classes(
      ("identity", ["id", "keyId", "externalTaskId", "originExternalTaskId", "externalThreadId", "creator"]),
      ("shared", ["title", "instructions", "crmStatus", "priority", "labels", "dueDate", "dueTime", "startDate", "startTime", "estimateMinutes", "taskType", "goalId", "result", "effort", "model", "projectRef", "place"]),
      ("raise", ["decisionRequired"]), ("shrink", ["tokenBudget"]),
      ("follows.touched", ["updatedAt"]), ("follows.oldest", ["createdAt"]), ("follows.newest", ["archivedAt", "hops"]),
      ("follows.partner:crmStatus", ["completedAt"]), ("follows.partner:place", ["deletedAt"]), ("collection:100", ["notes"]),
      ("thisMac", ["local", "notificationKeyId", "reviewVerdict", "reusedFromTask", "decisionID", "decisionPolicyID", "decisionEpoch", "decisionEligible", "decisionCreateRequest",
        "assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId", "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "project", "cwd", "sessionId",
        "conversationId", "seatSession", "seatToldAt", "process", "stopped", "runStartedAt", "keepOpenUntil", "keepAliveUntilClose", "questionOpen", "hootTurnOpen", "lastTurn",
        "childrenTold", "seq", "stalled", "startFailed", "awaitingSetup", "useWorkspace", "briefFile", "landing", "landingAttempts", "reviewWaitingForFolder", "tokenUsageByAgent",
        "isAPIAccount", "detail"])),
    ["run"] = Classes(
      ("shared", ["id", "agent_id", "task_id", "provider", "project_id", "session_id", "conversation_id", "session_name", "started_at", "ended_at", "outcome", "summary",
        "needed_help", "verified", "tokens", "cost_usd", "cost_source", "billing_kind", "requested_model", "requested_effort"]),
      ("thisMac", ["cwd", "account_id"])),
    ["agent"] = Classes(
      ("identity", ["id"]), ("shared", ["name", "role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo", "instructionHash"]),
      ("widening", ["provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent", "skills", "maxConcurrent", "maxRunMinutes",
        "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"]),
      ("follows.partner:status", ["statusAt"]),
      ("thisMac", ["account", "creatorKeyId", "keyInitializedFields", "syncStatus", "syncedAt", "syncError", "instructions", "instructionsFile", "verifyCommand",
        "sourceDirectory", "sourceFile", "sourcePath", "defaultProject", "startIn", "reviewerAgent"])),
    ["agentOptions"] = Classes(
      ("shared", ["model", "effort"]),
      ("widening", ["provider", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "keepOpen", "efficiency", "contextWindow", "fastMode"]),
      ("thisMac", ["environment", "hooks", "workingFolder"])),
    ["setting"] = Classes(("identity", ["key"]), ("shared", ["value"])),
    ["project"] = Classes(("identity", ["id"]), ("shared", ["name", "icon", "colour", "logo"]), ("widening", ["lead"]), ("follows.partner:lead", ["leadName"]),
      ("collection:none", ["roots"]), ("thisMac", ["folders"])),
    ["connection"] = Classes(("identity", ["keyId"]), ("shared", ["name", "enabled", "hasEventsSecret", "eventsHost"]),
      ("thisMac", ["eventsSecret", "eventsUrl", "statuses", "hootIdentity", "identities", "allowedSenders", "folders", "maxHops"])),
  };
  private static string Name(CloudMergeClass kind) => kind switch
  {
    CloudMergeClass.Shared => "shared", CloudMergeClass.Identity => "identity", CloudMergeClass.Widening => "widening", CloudMergeClass.Raise => "raise",
    CloudMergeClass.Shrink => "shrink", CloudMergeClass.ThisDevice => "thisMac",
    CloudMergeClass.Collection { Cap: var cap } => "collection:" + (cap?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "none"),
    CloudMergeClass.Follows { Rule: CloudMergeFollow.Newest } => "follows.newest", CloudMergeClass.Follows { Rule: CloudMergeFollow.Touched } => "follows.touched",
    CloudMergeClass.Follows { Rule: CloudMergeFollow.Oldest } => "follows.oldest", CloudMergeClass.Follows { Rule: CloudMergeFollow.Partner { Field: var p } } => "follows.partner:" + p,
    _ => "?"
  };

  [Fact]
  public void The_tables_equal_the_signed_field_list_class_by_class()
  {
    var tables = new Dictionary<string, CloudMergeTable>
    {
      ["task"] = CloudMergeTables.Task, ["run"] = CloudMergeTables.Run, ["agent"] = CloudMergeTables.Agent, ["agentOptions"] = CloudMergeTables.AgentOptions,
      ["setting"] = CloudMergeTables.Setting, ["project"] = CloudMergeTables.Project, ["connection"] = CloudMergeTables.Connection,
    };
    Assert.Equal(Signed.Keys.OrderBy(k => k, StringComparer.Ordinal), tables.Keys.OrderBy(k => k, StringComparer.Ordinal));
    foreach (var (name, table) in tables)
    {
      var mine = table.Classes.ToDictionary(c => c.Key, c => Name(c.Value), StringComparer.Ordinal);
      Assert.Equal(Signed[name].OrderBy(k => k.Key, StringComparer.Ordinal), mine.OrderBy(k => k.Key, StringComparer.Ordinal));
      Assert.Equal(1, table.Version);
    }
    Assert.Equal(("projects", "agents", "tasks", "settings"), (CloudMergeTables.Project.Domain, CloudMergeTables.Agent.Domain, CloudMergeTables.Task.Domain, CloudMergeTables.Setting.Domain));
  }
}
