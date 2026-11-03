using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskPhoneTests
{
  private sealed class TrustStore : IDeviceTrustPersistence
  { private IReadOnlyList<StoredDevice> rows = []; public IReadOnlyList<StoredDevice> Load() => rows; public void Save(IReadOnlyList<StoredDevice> devices) => rows = devices; }
  private sealed class Sessions : IPhoneSessionView { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => []; }
  private static JsonElement Parse(byte[] value) { using var d = JsonDocument.Parse(value); return d.RootElement.Clone(); }
  [Fact] public async Task UnchangedPhoneCanReadListDetailMetadataAndCommentsWithItsOwnProjectGrant()
  {
    var f = new TaskFixture(); var task = f.Create(due: "2026-10-31"); await f.Tasks.CommentAsync(task.Id, "Ready for review", TaskActor.Owner);
    var trust = new DeviceTrust(new TrustStore()); var offer = trust.Pairing.Create(); var key = Enumerable.Repeat((byte)7, 32).ToArray();
    var paired = trust.Redeem(offer.Code, "Synthetic phone", "ios", key); trust.Approve(paired.DeviceId, PhoneAccess.Look);
    var allowed = true;
    var app = new TaskPhoneApplication(new PhoneLink(trust, "Windows fixture", "test", new Sessions()), trust,
      new(f.Tasks, f.Projects, id => f.People.GetValueOrDefault(id)), (_, _, folder) => allowed && folder.Equals("C:/Work/Sample", StringComparison.OrdinalIgnoreCase));
    async Task<JsonElement> Send(object message) => Parse(Assert.Single((await app.ReceiveAsync("channel", key, JsonSerializer.SerializeToUtf8Bytes(message), default)).Messages));
    var welcome = await Send(new { t = "hello", protocol = 1, token = paired.Credential, device = new { name = "Synthetic phone", platform = "ios" } });
    Assert.Contains(welcome.GetProperty("capabilities").EnumerateArray(), v => v.GetString() == "panels.tasks");
    Assert.Equal("C:/Work/Sample", Assert.Single(welcome.GetProperty("folders").EnumerateArray()).GetString());
    var list = await Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" });
    Assert.Equal("panel.rows", list.GetProperty("t").GetString()); var row = Assert.Single(list.GetProperty("rows").EnumerateArray());
    Assert.Equal(task.Id, row.GetProperty("id").GetString()); Assert.Equal("To-Do", row.GetProperty("meta").GetProperty("status").GetString());
    Assert.Equal("2026-10-31", row.GetProperty("meta").GetProperty("due").GetString()); Assert.Empty(row.GetProperty("actions").EnumerateArray());
    var detail = await Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample", scope = "task:" + task.Id });
    Assert.Equal("task:" + task.Id, detail.GetProperty("view").GetString());
    var comment = Assert.Single(detail.GetProperty("rows").EnumerateArray(), r => r.TryGetProperty("group", out var g) && g.GetString() == "Comments");
    Assert.Equal("Ready for review", comment.GetProperty("body").GetString()); Assert.Equal("human", comment.GetProperty("value").GetString());
    allowed = false;
    await Assert.ThrowsAsync<ProtocolException>(async () => await Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" }));
    await app.DisconnectedAsync("channel");
  }
  [Fact] public async Task ATaskReadRequiresHelloEvenWithAKnownPeerKeyAndRevocationTakesEffectImmediately()
  {
    var f = new TaskFixture(); f.Create(); var trust = new DeviceTrust(new TrustStore()); var key = new byte[32];
    var pair = trust.Redeem(trust.Pairing.Create().Code, "Fixture", "android", key); trust.Approve(pair.DeviceId, PhoneAccess.Look);
    var app = new TaskPhoneApplication(new PhoneLink(trust, "Fixture", "test", new Sessions()), trust, new(f.Tasks, f.Projects, _ => null), (_, _, _) => true);
    var read = JsonSerializer.SerializeToUtf8Bytes(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" });
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("x", key, read, default));
    await app.ReceiveAsync("x", key, JsonSerializer.SerializeToUtf8Bytes(new { t = "hello", protocol = 1, token = pair.Credential, device = new { name = "Fixture", platform = "android" } }), default);
    trust.Revoke(pair.DeviceId);
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("x", key, read, default));
  }
  [Fact] public async Task PageSizeIsBoundedAndAHiddenTaskCannotBeOpenedByGuessingItsId()
  {
    var f = new TaskFixture(); var task = f.Create();
    for (var i = 0; i < 44; i++) await f.Tasks.CommentAsync(task.Id, new string('界', 3500), TaskActor.Owner);
    var reads = new TaskPhoneReads(f.Tasks, f.Projects, _ => null);
    var page = reads.Read(task.Folder, "task:" + task.Id, null, _ => true);
    Assert.True(JsonSerializer.SerializeToUtf8Bytes(page).Length < PhoneWire.MaximumMessageBytes); Assert.NotEqual(JsonValueKind.Null, page.GetProperty("note").ValueKind);
    Assert.NotEqual(JsonValueKind.Null, page.GetProperty("nextCursor").ValueKind);
    Assert.Equal("task:" + task.Id, page.GetProperty("continuationScope").GetString());
    Assert.Throws<ProtocolException>(() => reads.Read(task.Folder, "task:" + task.Id, null, _ => false));
    Assert.Throws<ProtocolException>(() => reads.Read("C:/Work/Other", "task:" + task.Id, null, _ => true));
  }
  [Fact] public async Task NestedAndIndependentTasksDoNotInheritAnotherProjectsPhoneGrant()
  {
    var f = new TaskFixture(); var visible = f.Create();
    f.Projects.Save(new("private", "Private project", ["C:/Work/Sample/Private"]));
    var nested = f.Tasks.Create(new("Private task", "Private details", "private"), TaskActor.Owner);
    var independent = f.Tasks.Create(new("Independent task", "Independent details", "independent", "C:/Work/Sample"), TaskActor.Owner);
    await f.Tasks.CommentAsync(nested.Id, "Private comment", TaskActor.Owner);
    await f.Tasks.CommentAsync(independent.Id, "Independent comment", TaskActor.Owner);
    var grants = new TaskPhoneGrants(new MemoryStore<TaskPhoneGrantState>(), f.Projects);
    var trust = new DeviceTrust(new TrustStore()); var key = Enumerable.Repeat((byte)3, 32).ToArray();
    var pair = trust.Redeem(trust.Pairing.Create().Code, "Fixture", "android", key); trust.Approve(pair.DeviceId, PhoneAccess.Look);
    grants.Set(new(pair.DeviceId, ["sample"]));
    var device = trust.List().Single();
    Assert.True(grants.Allows(device, "sample", visible.Folder));
    Assert.False(grants.Allows(device, "private", nested.Folder));
    Assert.False(grants.Allows(device, "independent", independent.Folder));
    Assert.False(grants.Allows(device, "sample", "C:/Work/Other"));
    var app = new TaskPhoneApplication(new PhoneLink(trust, "Fixture", "test", new Sessions()), trust,
      new(f.Tasks, f.Projects, _ => null), grants.Allows);
    async Task<JsonElement> Send(object message) => Parse(Assert.Single((await app.ReceiveAsync("phone", key, JsonSerializer.SerializeToUtf8Bytes(message), default)).Messages));
    var welcome = await Send(new { t = "hello", protocol = 1, token = pair.Credential, device = new { name = "Fixture", platform = "android" } });
    Assert.Equal("C:/Work/Sample", Assert.Single(welcome.GetProperty("folders").EnumerateArray()).GetString());
    var page = await Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" });
    Assert.Equal(visible.Id, Assert.Single(page.GetProperty("rows").EnumerateArray()).GetProperty("id").GetString());
    foreach (var hidden in new[] { nested, independent })
      await Assert.ThrowsAsync<ProtocolException>(async () => await Send(new { t = "panel.read", panel = "tasks", path = hidden.Folder, scope = "task:" + hidden.Id }));
    grants.Set(new(pair.DeviceId, ["private"]));
    var detail = await Send(new { t = "panel.read", panel = "tasks", path = nested.Folder, scope = "task:" + nested.Id });
    Assert.Contains(detail.GetProperty("rows").EnumerateArray(), r => r.TryGetProperty("body", out var body) && body.GetString() == "Private comment");
    await Assert.ThrowsAsync<ProtocolException>(async () => await Send(new { t = "panel.read", panel = "tasks", path = visible.Folder, scope = "task:" + visible.Id }));
  }
  [Theory]
  [InlineData("{\"t\":\"panel.read\",\"t\":\"hello\"}")]
  [InlineData("{\"t\":\"panel.read\",\"panel\":\"tasks\",\"path\":\"C:/Work/Sample\\n\"}")]
  [InlineData("[]")]
  public async Task MalformedPhoneMessagesFailClosed(string message)
  {
    var f = new TaskFixture(); var trust = new DeviceTrust(new TrustStore());
    var app = new TaskPhoneApplication(new PhoneLink(trust, "Fixture", "test", new Sessions()), trust, new(f.Tasks, f.Projects, _ => null), (_, _, _) => true);
    await Assert.ThrowsAsync<ProtocolException>(async () => await app.ReceiveAsync("x", new byte[32], Encoding.UTF8.GetBytes(message), default));
  }
}
