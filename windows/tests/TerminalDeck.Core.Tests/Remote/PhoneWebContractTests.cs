using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneWebContractTests : IDisposable
{
  private readonly string folder = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "phone-web-contract-" + Guid.NewGuid().ToString("N"));
  private static JsonElement Request(object value) => JsonSerializer.SerializeToElement(value);
  [Fact]
  public void PanelPagesPreserveEveryBoundedRowAndDecoderMetadataWithin48KiB()
  {
    var seen = new List<string>(); var cursor = 0; var pages = 0;
    do
    {
      var rows = new JsonArray(Enumerable.Range(0, 40).Select(i => (JsonNode)new JsonObject { ["id"] = i.ToString(), ["title"] = new string('界', 1000) }).ToArray());
      var request = Request(new { cursor, rid = "correlate", scope = "task:one" });
      var result = PhonePanelPagination.Apply(request, new JsonObject { ["t"] = "panel.rows", ["rows"] = rows, ["view"] = "task:one" });
      Assert.Equal("correlate", result["rid"]!.GetValue<string>()); Assert.Equal(cursor, result["cursor"]!.GetValue<int>()); Assert.Equal(40, result["totalRows"]!.GetValue<int>());
      Assert.Equal("task:one", result["continuationScope"]!.GetValue<string>()); Assert.True(Encoding.UTF8.GetByteCount(result.ToJsonString()) <= 48 * 1024);
      seen.AddRange(result["rows"]!.AsArray().Select(r => r!["id"]!.GetValue<string>())); pages++;
      cursor = result["nextCursor"]?.GetValue<int>() ?? -1;
    } while (cursor >= 0);
    Assert.True(pages > 1); Assert.Equal(Enumerable.Range(0, 40).Select(i => i.ToString()), seen);
    Assert.Throws<PhoneRefusal>(() => PhonePanelPagination.Cursor(Request(new { cursor = 201 })));
    Assert.Throws<PhoneRefusal>(() => PhonePanelPagination.Cursor(Request(new { cursor = "wrong" })));
  }
  [Fact]
  public async Task ActionRedrawNamesListScopeAndItsContinuationNeverRepeatsMutation()
  {
    var mutations = 0; var reads = new List<string?>();
    var owner = new PhonePanelOwner("example", true, (_, request, _) =>
    {
      reads.Add(request.TryGetProperty("scope", out var scope) ? scope.GetString() : null);
      return ValueTask.FromResult(new JsonObject { ["rows"] = new JsonArray(new JsonObject { ["id"] = "row", ["title"] = "Row", ["actions"] = new JsonArray(new JsonObject { ["id"] = "delete" }) }) });
    }, (_, _, _) => { mutations++; return ValueTask.CompletedTask; });
    var registry = new PhonePanelRegistry((_, _) => true, owner); var device = new ApprovedDevice("web", "Browser", "web", PhoneAccess.Full);
    var result = Assert.Single(await registry.HandleAsync("c", device, "panel.act", Request(new { t = "panel.act", panel = "example", scope = "item:row", action = "delete", id = "row", rid = "delete-rid" }), "delete-rid", default));
    Assert.Equal(1, mutations); Assert.Equal(new string?[] { "item:row", null }, reads); Assert.Null(result["continuationScope"]); Assert.Equal("delete-rid", result["rid"]!.GetValue<string>());
    await registry.HandleAsync("c", device, "panel.read", Request(new { t = "panel.read", panel = "example", cursor = 0 }), null, default); Assert.Equal(1, mutations);
  }
  [Fact]
  public void TextAndUploadedPathLimitsMatchCompanionDecoder()
  {
    Assert.Equal("line\nnext\r\ttab", PhoneChatText.Read(Request(new { text = "line\nnext\r\ttab" })));
    Assert.Equal(16384, Encoding.UTF8.GetByteCount(PhoneChatText.Read(Request(new { text = new string('é', 8192) }))));
    Assert.Throws<PhoneRefusal>(() => PhoneChatText.Read(Request(new { text = new string('é', 8193) })));
    foreach (var control in new[] { '\0', '\u001b', '\u007f', '\u0085' }) Assert.Throws<PhoneRefusal>(() => PhoneChatText.Read(Request(new { text = "a" + control })));
    Assert.Equal(4, PhoneUploadedFiles.Paths(Request(new { files = new[] { "/a", "/b", "/c", "/d" } })).Length);
    Assert.Throws<PhoneRefusal>(() => PhoneUploadedFiles.Paths(Request(new { files = new[] { "/a", "/b", "/c", "/d", "/e" } })));
  }
  [Fact]
  public async Task ProjectPathsAndIndexedInlineArtifactChunksMatchWebAndRejectChangesAndRevocation()
  {
    Directory.CreateDirectory(folder); var root = AppDataRoot.Explicit(Path.Combine(folder, "data")); var projectFolder = Directory.CreateDirectory(Path.Combine(folder, "project")).FullName;
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root)); var project = projects.Create("Example", projectFolder);
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    var artifacts = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts"), _ => project.Id, (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    var bytes = Enumerable.Range(0, 70000).Select(i => (byte)(i % 251)).ToArray(); var file = Path.Combine(projectFolder, "proof.png"); await File.WriteAllBytesAsync(file, bytes); artifacts.Record(projectFolder, "proof.png", "session", DateTimeOffset.UtcNow);
    var allowed = true; var host = new PhoneConnectedFeatures(projects, agents, artifacts, (_, id) => allowed && id == project.Id, (_, _) => false);
    var device = new ApprovedDevice("web", "Browser", "web", PhoneAccess.Full); host.Bind((_, _, _) => ValueTask.CompletedTask, _ => device);
    async Task<JsonObject> Read(object value) => Assert.Single(await host.HandleAsync("c", device, "panel.read", Request(value), "request-rid", default));
    var list = await Read(new { t = "panel.read", panel = "projects" }); var row = Assert.Single(list["rows"]!.AsArray()); Assert.Equal(projectFolder, row!["id"]!.GetValue<string>());
    var detail = await Read(new { t = "panel.read", panel = "projects", path = projectFolder, scope = "project" }); Assert.Equal(projectFolder, Assert.Single(detail["rows"]!.AsArray())!["id"]!.GetValue<string>());
    var catalog = await Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, scope = "made project session:*" }); var token = Assert.Single(catalog["rows"]!.AsArray())!["id"]!.GetValue<string>().Split(' ')[0];
    var collected = new List<byte>(); long offset = 0;
    do
    {
      var reply = await Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, scope = "made project session:*", preview = token, at = offset, max = 32768 });
      Assert.Empty(reply["rows"]!.AsArray()); Assert.Equal("request-rid", reply["rid"]!.GetValue<string>()); Assert.True(Encoding.UTF8.GetByteCount(reply.ToJsonString()) <= 48 * 1024);
      var preview = reply["preview"]!; Assert.Equal(token, preview["token"]!.GetValue<string>()); Assert.Equal(offset, preview["offset"]!.GetValue<long>()); Assert.Equal(70000, preview["total"]!.GetValue<long>());
      collected.AddRange(Convert.FromBase64String(preview["data"]!.GetValue<string>())); offset = preview["next"]!.GetValue<long>(); if (preview["done"]!.GetValue<bool>()) break;
    } while (true);
    Assert.Equal(bytes, collected);
    await Assert.ThrowsAsync<PhoneRefusal>(() => Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, preview = "#unlisted", at = 0 }));
    await Assert.ThrowsAsync<PhoneRefusal>(() => Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, preview = token, at = 0, max = 32769 }));
    allowed = false; await Assert.ThrowsAsync<PhoneRefusal>(() => Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, preview = token, at = 0 })); allowed = true;
    await File.WriteAllBytesAsync(file, [1, 2, 3]); await Assert.ThrowsAsync<PhoneRefusal>(() => Read(new { t = "panel.read", panel = "artifacts", path = projectFolder, preview = token, at = 0 }));
  }
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
}
