using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane D2: the record tables' VERSION 2, as the Macs read and write it (td-mac-next2 CloudBrainAgentsFieldTables.swift,
// `recordsDeleteRule` + `tasksEverywhere`, 87941cff8 + bd3e3321b). The Mac has no Swift-made byte vector for version 2:
// the class lists are transcribed from the Swift source field by field, and the payload bytes are written out from
// CloudBrainMergeVersion.payload() and CloudSyncCanonical exactly as the version-1 project vector beside them was.
public sealed class CloudRecordsV2ReferenceTests
{
  private static string Name(CloudMergeClass kind) => kind switch
  {
    CloudMergeClass.Shared => "shared", CloudMergeClass.Identity => "identity", CloudMergeClass.Widening => "widening", CloudMergeClass.Raise => "raise",
    CloudMergeClass.Shrink => "shrink", CloudMergeClass.ThisDevice => "thisMac",
    CloudMergeClass.Collection { Cap: var cap } => "collection:" + (cap?.ToString() ?? "none"),
    CloudMergeClass.Follows { Rule: CloudMergeFollow.Newest } => "follows.newest", CloudMergeClass.Follows { Rule: CloudMergeFollow.Touched } => "follows.touched",
    CloudMergeClass.Follows { Rule: CloudMergeFollow.Oldest } => "follows.oldest", CloudMergeClass.Follows { Rule: CloudMergeFollow.Partner { Field: var p } } => "follows.partner:" + p,
    _ => "?",
  };
  private static readonly string[] Delete = ["deletedBy", "deletedOn", "deletedGroup", "deletedSession", "deletedAgent", "deletedMacName", "deletedTime", "deletedScope", "deletedWithAgent"];
  private static readonly string[] Everywhere = ["assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId", "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId",
    "reviewVerdict", "reusedFromTask", "askedFromTask", "board", "position", "recurrence", "useWorkspace", "tokenUsage", "tokenUsageByAgent", "detail", "workingOn"];

  /// The version-2 table is exactly version 1 plus the added fields, each introduced at 2, with the Mac's classes.
  private static void SameAsV1Plus(CloudMergeTable v1, CloudMergeTable v2, IReadOnlyDictionary<string, string> added)
  {
    Assert.Equal(2, v2.Version);
    Assert.Equal(v1.Domain, v2.Domain);
    var expected = v1.Classes.ToDictionary(c => c.Key, c => Name(c.Value), StringComparer.Ordinal);
    foreach (var (k, v) in added) expected[k] = v;
    Assert.Equal(expected.OrderBy(e => e.Key, StringComparer.Ordinal), v2.Classes.ToDictionary(c => c.Key, c => Name(c.Value)).OrderBy(e => e.Key, StringComparer.Ordinal));
    Assert.Equal(added.Keys.Order(StringComparer.Ordinal), v2.Introduced.Where(i => i.Value == 2).Select(i => i.Key).Order(StringComparer.Ordinal));
    Assert.All(v2.Introduced.Values, v => Assert.Equal(2, v));
  }

  [Fact]
  public void Version_2_tables_equal_the_Macs_field_by_field()
  {
    var task = Delete.ToDictionary(f => f, _ => "follows.partner:place");
    foreach (var f in Everywhere) task[f] = "shared";
    SameAsV1Plus(CloudMergeTables.Task, CloudTasksOwner.Kind.Table, task);
    SameAsV1Plus(CloudMergeTables.Agent, CloudAgentsOwner.AgentKind.Table, Delete.ToDictionary(f => f, _ => "follows.partner:$exists"));
    SameAsV1Plus(CloudMergeTables.Project, CloudProjectsOwner.Kind.Table, Delete.ToDictionary(f => f, _ => "follows.partner:$exists"));
    var instruction = new CloudMergeTable("agents", 1, new Dictionary<string, CloudMergeClass> { ["id"] = CloudMergeClass.IdentityField, ["text"] = CloudMergeClass.SharedField });
    SameAsV1Plus(instruction, CloudAgentsOwner.InstructionKind.Table, Delete.ToDictionary(f => f, _ => "follows.partner:$exists"));
    // Version 1 is untouched (the Security-reviewed list; CloudRecordMergeTests compares it with the signed copy).
    Assert.Equal(1, CloudMergeTables.Task.Version);
    Assert.DoesNotContain("deletedGroup", CloudMergeTables.Task.Classes.Keys);
    Assert.Equal("thisMac", Name(CloudMergeTables.Task.Classes["assignee"]));
  }

  [Fact]
  public void The_connected_systems_links_and_CRM_copies_tables_equal_the_Macs()
  {
    var system = CloudTasksOwner.SystemKind.Table;
    Assert.Equal(("tasks", 2), (system.Domain, system.Version));
    Assert.Equal(new[] { "createdAt", "id" }, system.Classes.Where(c => c.Value is CloudMergeClass.Identity).Select(c => c.Key).Order(StringComparer.Ordinal));
    Assert.Equal(new[] { "changes", "docsUrl", "enabled", "markDone", "me", "name", "profile", "projectId", "server", "url" },
      system.Classes.Where(c => c.Value is CloudMergeClass.Shared).Select(c => c.Key).Order(StringComparer.Ordinal));
    Assert.Equal(new[] { "folder", "problem", "projectIdInferred", "startIn", "tokenEnding" },
      system.Classes.Where(c => c.Value is CloudMergeClass.ThisDevice).Select(c => c.Key).Order(StringComparer.Ordinal));
    Assert.Equal(12, system.Introduced.Count);
    var link = CloudTasksOwner.LinkKind.Table;
    Assert.Equal(new[] { "enabled:shared", "keyId:identity", "name:shared" }, link.Classes.Select(c => c.Key + ":" + Name(c.Value)).Order(StringComparer.Ordinal));
    var crm = CloudTasksOwner.CrmKind.Table;
    Assert.Equal(2, crm.Version);
    Assert.Equal(("shared", "shared", "shared", "thisMac"), (Name(crm.Classes["systemName"]), Name(crm.Classes["homeMac"]), Name(crm.Classes["assignee"]), Name(crm.Classes["sessionId"])));
    Assert.DoesNotContain("deletedGroup", crm.Classes.Keys);
    Assert.Equal(crm.Classes.Count, crm.Introduced.Count);
  }

  private const string Op = "4b3f2a1c-9d8e-4f70-a1b2-c3d4e5f60718", Device = "7f306256-7209-4b63-962b-14a7b01b12ee", Group = "1f0e2d3c-4b5a-4968-8776-a5b4c3d2e1f0";
  private static string Stamp => "[1763000000000,\"" + Op + "\"]";

  /// A task moved to Trash by an AI while every device reads version 2: the delete fields and a tasks-everywhere field
  /// make the revision minTable 2; the table is 2.
  [Fact]
  public void Golden_version_2_task_payload_byte_for_byte()
  {
    var local = CloudRecordJson.Object([("id", CloudJson.From("local:one")), ("place", CloudJson.From("trash")), ("deletedBy", CloudJson.From("ai")),
      ("deletedGroup", CloudJson.From(Group)), ("assignee", CloudJson.Obj(("kind", CloudJson.From("agent")), ("id", CloudJson.From("reviewer"))))]);
    var revision = CloudRecordMerge.Revision(null, null, local, null, null, false, CloudTasksOwner.Kind.Table, Op, Device, 1_763_000_000_000, false, new CloudMergeGraph())!;
    var expected = "{\"baseline\":false,\"collections\":{},\"conflicts\":[],\"fields\":{\"$exists\":true,\"assignee\":{\"id\":\"reviewer\",\"kind\":\"agent\"},\"deletedBy\":\"ai\","
      + "\"deletedGroup\":\"" + Group + "\",\"id\":\"local:one\",\"place\":\"trash\"},\"minTable\":2,\"removed\":{},\"stamps\":{\"$exists\":" + Stamp + ",\"assignee\":" + Stamp
      + ",\"deletedBy\":" + Stamp + ",\"deletedGroup\":" + Stamp + ",\"id\":" + Stamp + ",\"place\":" + Stamp + "},\"table\":2}";
    Assert.Equal(expected, Encoding.UTF8.GetString(CloudCanonical.Encode(revision.Version.Payload())));
  }

  /// An updated device with the gate closed writes version-1 fields only: table 2, minTable 1 (an older reader takes it).
  [Fact]
  public void Golden_closed_gate_project_payload_is_table_2_minTable_1()
  {
    var local = CloudRecordJson.Object([("id", CloudJson.From("deck")), ("name", CloudJson.From("Deck"))]);
    var revision = CloudRecordMerge.Revision(null, null, local, null, null, false, CloudProjectsOwner.Kind.Table, Op, Device, 1_763_000_000_000, false, new CloudMergeGraph())!;
    var expected = "{\"baseline\":false,\"collections\":{},\"conflicts\":[],\"fields\":{\"$exists\":true,\"id\":\"deck\",\"name\":\"Deck\"},\"minTable\":1,\"removed\":{},"
      + "\"stamps\":{\"$exists\":" + Stamp + ",\"id\":" + Stamp + ",\"name\":" + Stamp + "},\"table\":2}";
    Assert.Equal(expected, Encoding.UTF8.GetString(CloudCanonical.Encode(revision.Version.Payload())));
  }

  private sealed class Owner : ICloudRecordOwner
  {
    public List<string> Written { get; } = [];
    public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords() => new Dictionary<string, CloudJson.Object>();
    public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud) => new(cloud);
    public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting) => Written.Add(entity);
    public void CloudImported(IReadOnlyList<string> entities) { }
  }

  /// A version-2 record (minTable 2) is taken by this build and set aside, never half-applied, by a version-1 reader.
  [Fact]
  public async Task A_version_2_record_is_applied_here_and_parked_by_a_version_1_reader()
  {
    var dir = Path.Combine(Path.GetTempPath(), "td-d2-ref-" + Guid.NewGuid().ToString("N"));
    try
    {
      var local = CloudRecordJson.Object([("id", CloudJson.From("deck")), ("name", CloudJson.From("Deck")), ("deletedBy", CloudJson.From("person")),
        ("deletedGroup", CloudJson.From(Group))]);
      var revision = CloudRecordMerge.Revision(null, null, local, null, null, false, CloudProjectsOwner.Kind.Table, Op, Device, 1_763_000_000_000, false, new CloudMergeGraph())!;
      Assert.Equal(2, revision.Version.MinTable);
      var payload = revision.Version.Payload();
      var op = new CloudOperation(1, Op, Device, "projects", "project:deck", Op, [], "put", null, null, new CloudSourceReference("project-registry", "project:deck"),
        revision.Time, payload, CloudOperation.PayloadHashOf(payload));
      foreach (var (kind, applies) in new[] { (new CloudRecordKind("project:", CloudMergeTables.Project), false), (CloudProjectsOwner.Kind, true) })
      {
        var folder = Path.Combine(dir, applies ? "v2" : "v1");
        var owner = new Owner();
        var adapter = new CloudRecordAdapter("projects", "I11", "project-registry", [kind], new CloudRecordStore(folder, () => 1_763_000_000_000), "acct",
          "5d41402a-bc4b-4a76-b971-9d911017c592", owner, new CloudRecordOrigins(Path.Combine(folder, "accounts"), "acct"));
        await adapter.ApplyAsync(op, new CloudImportOrigin(Device, 1, revision.Time, false), default);
        await adapter.SettleAsync(default);
        Assert.Equal(applies, owner.Written.Contains("project:deck"));
        Assert.Equal(!applies, adapter.Listing().WaitingHere.Any(w => w.Record == "project:deck" && w.Reason.Contains("newer version", StringComparison.Ordinal)));
      }
    }
    finally { try { Directory.Delete(dir, recursive: true); } catch (IOException) { } }
  }
}
