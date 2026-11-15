using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// W3 memory: record shapes byte-compared with vectors made by the Mac's own CloudBrainMemory.swift structs encoded the
// way CloudWire.canonical encodes them (Fixtures/cloud-memory-vectors-swift.json; its generator sits beside it), and
// the merge cases mirrored from the Mac: a value changed on two devices, first sign-in (the Cloud's record wins and the
// joiner's value is listed), a removed setting (never sent from Windows, never applied as a removal here), and
// machine-local settings never travelling.
public sealed class CloudMemoryW3Tests
{
  private const string Store = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", StoreB = "9c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f";
  private const string DeviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", DeviceB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e";
  private static readonly JsonElement Swift = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloud-memory-vectors-swift.json"))).RootElement;
  private static string S(string name) => Swift.GetProperty(name).GetString()!;
  private static readonly DeckMemoryTable Settings = DeckMemoryCloudSchema.Table("settings");

  private static DeckMemoryRow Setting(string owner, string key, string? value, double updated) =>
    new("settings", [DeckMemoryCell.Text(owner), DeckMemoryCell.Text(key), value is null ? DeckMemoryCell.Null : DeckMemoryCell.Text(value), DeckMemoryCell.Real(updated)]);

  private static void SameRecord(string name, CloudOperation op)
  {
    Assert.Equal(S(name + ".payload"), Encoding.UTF8.GetString(CloudCanonical.Encode(op.Payload)));
    Assert.Equal(S(name + ".payloadHash"), op.PayloadHash);
    Assert.Equal(S(name + ".opId"), op.OpId);
    Assert.Equal(S(name + ".entity"), op.EntityId);
  }

  [Fact]
  public void Rows_parts_ids_and_numbers_are_byte_identical_to_the_Mac()
  {
    foreach (var (name, row, refs) in new (string, DeckMemoryRow, Dictionary<string, DeckMemoryReference>?)[]
    {
      ("setting", Setting("hoot", "tidy.on", "1", 1763000000.123), null),
      ("tombstone", Setting("hoot", "tidy.on", null, 1763000100.5), null),
      ("topic", new("topics", [DeckMemoryCell.Text("project:crm"), DeckMemoryCell.Text("t1"), DeckMemoryCell.Text("Release plan"), DeckMemoryCell.Text("projects/crm/topics/t1.md"),
        DeckMemoryCell.Integer(1), DeckMemoryCell.Text("crm"), DeckMemoryCell.Null, DeckMemoryCell.Null, DeckMemoryCell.Text("2026-11-13"), DeckMemoryCell.Null, DeckMemoryCell.Null]),
        new() { ["path"] = new(Store, "file", DeckMemoryCell.Text("projects/crm/topics/t1.md")) })
    })
    {
      var t = DeckMemoryCloudSchema.Table(row.Table);
      var body = CloudMemoryFormat.RowBody(t, row.Cells, refs);
      Assert.Equal(S(name + ".body"), Encoding.UTF8.GetString(body));
      var key = CloudMemoryFormat.RowKey(t, row.Cells);
      Assert.Equal(S(name + ".key"), key);
      var hash = CloudMemoryFormat.Hash(body);
      var version = CloudMemoryFormat.Uuid(Store + ":" + key + "\n" + hash);
      Assert.Equal(S(name + ".version"), version);
      var stamp = name switch { "setting" => 1763000000500L, "tombstone" => 1763000100500L, _ => 1763000000600L };
      var part = new CloudMemoryPart(Store, "I05", key, version, hash, body.Length, 0, 1, [], Convert.ToBase64String(body), stamp, false);
      var op = CloudMemoryFormat.Operation(part, DeviceA, [], 1);
      SameRecord(name, op);
      Assert.Equal(part, CloudMemoryFormat.ValidatePart(op, "I05"));
    }
    var file = Enumerable.Range(0, 40000).Select(i => (byte)(i % 251)).ToArray();
    var fileHash = CloudMemoryFormat.Hash(file);
    var fileVersion = CloudMemoryFormat.Uuid(Store + ":file/notes/big.md\n" + fileHash);
    Assert.Equal(S("file.version"), fileVersion);
    for (var i = 0; i < 2; i++)
    {
      var slice = file.AsSpan(i * CloudMemoryFormat.PartBytes, Math.Min(CloudMemoryFormat.PartBytes, file.Length - i * CloudMemoryFormat.PartBytes));
      var op = CloudMemoryFormat.Operation(new(Store, "I01", "file/notes/big.md", fileVersion, fileHash, file.Length, i, 2, [], Convert.ToBase64String(slice), 1763000000700, false), DeviceA, [], 1);
      Assert.Equal((S($"file{i}.payloadHash"), S($"file{i}.opId"), S($"file{i}.entity")), (op.PayloadHash, op.OpId, op.EntityId));
    }
    foreach (var member in Swift.EnumerateObject().Where(m => m.Name.StartsWith("double.", StringComparison.Ordinal)))
      Assert.Equal(member.Value.GetString(), CloudMemoryFormat.SwiftDouble(BitConverter.Int64BitsToDouble((long)ulong.Parse(member.Name[7..]))));
  }

  [Fact]
  public async Task The_adapters_own_capture_makes_the_Macs_exact_record()
  {
    var memory = new InMemoryDeckMemoryStore(Store);
    memory.PutRow(Setting("hoot", "tidy.on", "1", 1763000000.123), null);
    var adapter = new CloudMemoryAdapter(memory, new CloudMemorySlot(), DeviceA, localNow: () => 1);
    Assert.Empty((await adapter.CaptureAsync(() => 1763000000400, default)).Operations); // nothing before the feed was read once
    Assert.True(adapter.FeedRead());
    var capture = await adapter.CaptureAsync(() => 1763000000500, default);
    SameRecord("setting", Assert.Single(capture.Operations));
    capture.Commit();
    Assert.Empty((await adapter.CaptureAsync(() => 1763000000600, default)).Operations);
  }

  private sealed record Device(InMemoryDeckMemoryStore Memory, CloudMemoryAdapter Adapter, string Id);
  private static Device Make(string store, string device)
  {
    var m = new InMemoryDeckMemoryStore(store);
    var adapter = new CloudMemoryAdapter(m, new CloudMemorySlot(), device);
    adapter.FeedRead();
    return new(m, adapter, device);
  }
  private static async Task<IReadOnlyList<CloudOperation>> Capture(Device d, long stamp)
  {
    var capture = await d.Adapter.CaptureAsync(() => stamp, default);
    capture.Commit();
    return capture.Operations;
  }
  private static async Task Deliver(IEnumerable<CloudOperation> ops, Device to, string from, ulong seq = 1)
  {
    foreach (var op in ops) await to.Adapter.ApplyAsync(op, new CloudImportOrigin(from, seq, null, false), default);
  }
  private static string? Value(Device d, string key) => d.Memory.Rows("settings").FirstOrDefault(r => r.Cells[1].Value == key)?.Cells[2].Value;

  [Fact]
  public async Task A_value_changed_on_two_devices_shows_the_newer_on_both_and_lists_the_other()
  {
    var a = Make(Store, DeviceA); var b = Make(StoreB, DeviceB);
    a.Memory.PutRow(Setting("hoot", "tidy.hour", "3", 1), null);
    await Deliver(await Capture(a, 1000), b, DeviceA);
    Assert.Equal("3", Value(b, "tidy.hour"));
    Assert.Empty(await Capture(b, 1500)); // received, not edited: nothing to send back

    a.Memory.PutRow(Setting("hoot", "tidy.hour", "4", 2), null);
    b.Memory.PutRow(Setting("hoot", "tidy.hour", "5", 3), null);
    var fromA = await Capture(a, 2000);
    var fromB = await Capture(b, 3000);
    Assert.Equal(fromA.Single().EntityId, fromB.Single().EntityId); // the same record: B's edit descends from A's version
    await Deliver(fromA, b, DeviceA, 2);
    await Deliver(fromB, a, DeviceB, 3);
    Assert.Equal("5", Value(a, "tidy.hour"));
    Assert.Equal("5", Value(b, "tidy.hour"));
    Assert.Contains("\"4\"", Assert.Single(a.Adapter.OtherVersions).Value);
    Assert.Contains("\"4\"", Assert.Single(b.Adapter.OtherVersions).Value);
    // Applying the same records again changes nothing.
    await Deliver(fromB, a, DeviceB, 3);
    Assert.Single(a.Adapter.OtherVersions);
  }

  [Fact]
  public async Task First_sign_in_the_Clouds_record_wins_and_the_joiners_value_is_listed()
  {
    var a = Make(Store, DeviceA); var joiner = Make(StoreB, DeviceB);
    a.Memory.PutRow(Setting("hoot", "tidy.hour", "3", 1), null);
    var cloud = await Capture(a, 1000);
    joiner.Memory.PutRow(Setting("hoot", "tidy.hour", "7", 9), null); // the joiner's own value, never published, newer clock
    await Deliver(cloud, joiner, DeviceA);
    Assert.Equal("3", Value(joiner, "tidy.hour"));
    Assert.Contains("\"7\"", Assert.Single(joiner.Adapter.OtherVersions).Value);
    // The joiner's value travels as a baseline version, so every device keeps it as history and none shows it.
    var baseline = await Capture(joiner, 5000);
    var payload = (CloudJson.Object)Assert.Single(baseline).Payload;
    Assert.True(payload["baseline"] is CloudJson.Bool { Value: true });
    await Deliver(baseline, a, DeviceB, 2);
    Assert.Equal("3", Value(a, "tidy.hour"));
    Assert.Contains("\"7\"", Assert.Single(a.Adapter.OtherVersions).Value);
  }

  [Fact]
  public async Task Machine_local_settings_and_meta_never_travel_and_a_removal_neither_travels_nor_deletes()
  {
    var a = Make(Store, DeviceA); var b = Make(StoreB, DeviceB);
    a.Memory.PutRow(Setting("hoot", "helper.last-run", "123", 1), null);
    a.Memory.PutRow(Setting("hoot", "backup.last", "x", 1), null);
    a.Memory.PutRow(Setting("hoot", "unknown.thing", "y", 1), null);
    a.Memory.PutRow(new DeckMemoryRow("meta", [DeckMemoryCell.Text("embedding.model"), DeckMemoryCell.Text("m")]), null);
    a.Memory.PutRow(Setting("hoot", "tidy.on", "1", 1), null);
    var ops = await Capture(a, 1000);
    var only = Assert.Single(ops);
    Assert.Contains("tidy.on", Encoding.UTF8.GetString(Convert.FromBase64String(((CloudJson.Object)only.Payload)["data"]!.AsString!)));
    await Deliver(ops, b, DeviceA);
    Assert.Equal("1", Value(b, "tidy.on"));

    // Removed here: nothing is sent (removals do not travel from Windows yet).
    a.Memory.RemoveRow("settings", [DeckMemoryCell.Text("hoot"), DeckMemoryCell.Text("tidy.on")]);
    Assert.Empty(await Capture(a, 2000));
    // A Mac's removal (the same row with value null, made on top of the version B holds) arriving: B keeps its value.
    var parent = ((CloudJson.Object)only.Payload)["version"]!.AsString!;
    var gone = CloudMemoryFormat.RowBody(Settings, Setting("hoot", "tidy.on", null, 2).Cells);
    var goneHash = CloudMemoryFormat.Hash(gone);
    var goneVersion = CloudMemoryFormat.Uuid(parent + "\n" + goneHash);
    await Deliver([CloudMemoryFormat.Operation(new(Store, "I05", only.Source.RecordId, goneVersion, goneHash, gone.Length, 0, 1, [parent], Convert.ToBase64String(gone), 2500, false),
      DeviceA, [only.OpId], 2)], b, DeviceA, 2);
    Assert.Equal("1", Value(b, "tidy.on"));
    Assert.Equal(CloudMemoryAdapter.KeptRemovalWhy, Assert.Single(b.Adapter.OtherVersions).Why);
    Assert.Empty(await Capture(b, 3000));

    // An incoming machine-local setting (an older device's bookkeeping) is kept as history only, never placed.
    var foreign = new InMemoryDeckMemoryStore(StoreB);
    foreign.PutRow(Setting("hoot", "helper.last-run", "999", 1), null);
    var t = Settings;
    var body = CloudMemoryFormat.RowBody(t, Setting("hoot", "helper.last-run", "999", 1).Cells);
    var hash = CloudMemoryFormat.Hash(body);
    var key = CloudMemoryFormat.RowKey(t, Setting("hoot", "helper.last-run", "999", 1).Cells);
    var version = CloudMemoryFormat.Uuid(StoreB + ":" + key + "\n" + hash);
    await Deliver([CloudMemoryFormat.Operation(new(StoreB, "I05", key, version, hash, body.Length, 0, 1, [], Convert.ToBase64String(body), 5, false), DeviceB, [], 5)], a, DeviceB, 3);
    Assert.Equal("123", Value(a, "helper.last-run"));
  }

  [Fact]
  public async Task A_two_part_file_and_its_label_arrive_in_any_order()
  {
    var a = Make(Store, DeviceA); var b = Make(StoreB, DeviceB);
    var text = Encoding.UTF8.GetBytes(new string('n', 40_000));
    a.Memory.WriteFile("projects/crm/topics/t1.md", text);
    a.Memory.PutRow(new("topics", [DeckMemoryCell.Text("hoot"), DeckMemoryCell.Text("t1"), DeckMemoryCell.Text("Plan"), DeckMemoryCell.Text("projects/crm/topics/t1.md"),
      DeckMemoryCell.Integer(1), DeckMemoryCell.Null, DeckMemoryCell.Null, DeckMemoryCell.Null, DeckMemoryCell.Text("2026-11-13"), DeckMemoryCell.Null, DeckMemoryCell.Null]), null);
    var ops = await Capture(a, 1000);
    Assert.Equal(3, ops.Count);
    // The project file waits until this PC matched project "crm"; the label waits for its file.
    await Deliver(ops.Reverse(), b, DeviceA);
    Assert.Empty(b.Memory.Files());
    Assert.Empty(b.Memory.Rows("topics"));
    Assert.Equal(2, b.Adapter.WaitingCount);
    var matched = new CloudMemoryAdapter(b.Memory, new CloudMemorySlot(), DeviceB, projects: (project, store) => project == "crm" ? "crm-local" : null);
    await Deliver(ops.Reverse(), new Device(b.Memory, matched, DeviceB), DeviceA);
    Assert.Equal(text, b.Memory.Files()["projects/crm-local/topics/t1.md"]);
    Assert.Equal("projects/crm-local/topics/t1.md", Assert.Single(b.Memory.Rows("topics")).Cells[3].Value);
  }
}
