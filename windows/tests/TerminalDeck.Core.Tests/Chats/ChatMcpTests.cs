using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Chats;

[Collection("Windows chat")]
public sealed class ChatMcpTests
{
  private static JsonElement Args(object args) => JsonSerializer.SerializeToElement(args);
  private static McpRegistration Caller(McpDoor door, string[] resources, params string[] tools) => door.RegisterCaller(
    new("chat-test", "caller", null, true, AiPermissionMode.Ask, tools, [McpTier.Read, McpTier.Act, McpTier.Alter], resources, DateTimeOffset.UtcNow.AddMinutes(5)),
    (_, _, _, _, _) => ValueTask.FromResult(true));
  [Fact] public async Task SideBriefToolsStaySeparateFromTheMainUnsentDraft()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var buffer = ChatDraftWorkspace.Open(id); buffer.Edit("main unsent draft"); var original = buffer.Read();
    var caller = Caller(door, ["sessions:" + id, "accounts:" + f.Account.Id, "folders:" + f.Root.DirectoryPath], "sessions.send", "chats.read");
    await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = id, text = "deck-chat:" + JsonSerializer.Serialize(new { action = "sideQuestion", expectedRevision = 0, text = "A side question" }) }));
    await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = id, text = "deck-chat:" + JsonSerializer.Serialize(new { action = "sideBriefPrepare" }) }));
    var state = await door.CallAsync(caller.Id, "chats.read", Args(new { cwd = f.Root.DirectoryPath, transcriptPath = "chat:" + id + ":sideQuestion" }));
    Assert.Equal("A side question", state.GetProperty("question").GetString()); Assert.Equal(original, buffer.Read()); Assert.Equal(0, f.Keeper.Starts); Assert.Equal(2, permission.Requests.Count);
  }
  [Fact] public async Task PrivateEditorActionsUseTheApprovedChatDraftAndNeverSendToTheProvider()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var buffer = ChatDraftWorkspace.Open(id); buffer.Edit("private draft");
    var caller = Caller(door, ["sessions:" + id, "accounts:" + f.Account.Id, "folders:" + f.Root.DirectoryPath], "sessions.send");
    async Task<JsonElement> Action(string action) => await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = id, text = "deck-chat:" + JsonSerializer.Serialize(new { action }) }));
    var prepared = await Action("draftEditorPrepare"); var path = prepared.GetProperty("editorCopy").GetProperty("path").GetString()!; Assert.StartsWith(f.Root.DirectoryPath, path);
    File.WriteAllText(path, "saved private edit"); await Action("draftEditorImport"); Assert.Equal("saved private edit", buffer.Read().Text);
    await Action("draftEditorDiscard"); Assert.False(File.Exists(path)); Assert.Equal(0, f.Keeper.Starts); Assert.Empty(f.Chats.Get(id).Messages); Assert.Equal(3, permission.Requests.Count);
  }
  [Fact] public async Task ToolDraftEditsAreUnsentAndUseTheSameRevisionAsTheVisibleEditor()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var buffer = ChatDraftWorkspace.Open(id); buffer.Edit("kept draft"); var revision = buffer.Read().Revision;
    var caller = Caller(door, ["sessions:" + id, "accounts:" + f.Account.Id, "folders:" + f.Root.DirectoryPath], "sessions.send", "sessions.get", "chats.read");
    var payload = "deck-chat:" + JsonSerializer.Serialize(new { action = "draftAppend", expectedRevision = revision, text = " with context" });
    await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = id, text = payload }));
    Assert.Equal("kept draft with context", buffer.Read().Text); Assert.Equal(0, f.Keeper.Starts); Assert.Empty(f.Chats.Get(id).Messages);
    var draft = await door.CallAsync(caller.Id, "chats.read", Args(new { cwd = f.Root.DirectoryPath, transcriptPath = "chat:" + id + ":draft:0" }));
    Assert.Equal(buffer.Read().Revision, draft.GetProperty("revision").GetInt64()); Assert.Equal(buffer.Read().Text, draft.GetProperty("text").GetString());
  }
  [Fact] public async Task PermissionControlUsesExistingAlterApprovalAndDenialKeepsThePolicy()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var caller = Caller(door, ["sessions:" + id, "accounts:" + f.Account.Id, "folders:" + f.Root.DirectoryPath], "agents.set_control");
    await door.CallAsync(caller.Id, "agents.set_control", Args(new { sessionId = id, control = "permission", value = "plan" }));
    Assert.Single(permission.Requests); Assert.Equal(AiPermissionMode.Plan, f.Chats.Get(id).Definition.PermissionMode);
    permission.Answer = r => new(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "agents.set_control", Args(new { sessionId = id, control = "permission", value = "bypass" })));
    Assert.Equal(AiPermissionMode.Plan, f.Chats.Get(id).Definition.PermissionMode);
  }
  [Fact] public async Task HistoryPagesReachTheOldestEventAndImagesUseTheSameReadPermission()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var image = await f.Chats.AddImageAsync(id, "synthetic.png", "image/png", new byte[] { 1, 2, 3, 4 }, 1, 1);
    foreach (var text in new[] { "first", "second", "third" })
    { await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), text, text == "first" ? [image] : []); await ChatFixture.UntilAsync(() => !f.Chats.Get(id).Busy); }
    var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var caller = Caller(door, ["folders:" + f.Root.DirectoryPath, "sessions:" + id, "accounts:" + f.Account.Id], "chats.list", "chats.read");
    var listed = await door.CallAsync(caller.Id, "chats.list", Args(new { cwd = f.Root.DirectoryPath }));
    string? path = listed[0].GetProperty("transcriptPath").GetString(); var sequences = new List<long>();
    do
    {
      var page = await door.CallAsync(caller.Id, "chats.read", Args(new { cwd = f.Root.DirectoryPath, transcriptPath = path, limit = 2 }));
      sequences.AddRange(page.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("sequence").GetInt64())); path = page.GetProperty("nextTranscriptPath").GetString();
    } while (path is not null);
    Assert.Equal(f.Chats.Get(id).Events.Length, sequences.Distinct().Count()); Assert.Contains(1L, sequences);
    var media = await door.CallAsync(caller.Id, "chats.read", Args(new { cwd = f.Root.DirectoryPath, transcriptPath = $"chat:{id}:media:{image.Id}" })); Assert.Equal("AQIDBA==", media.GetProperty("data").GetString());
    var denied = Caller(door, ["folders:" + f.Root.DirectoryPath], "chats.list", "chats.read");
    Assert.Equal(0, (await door.CallAsync(denied.Id, "chats.list", Args(new { cwd = f.Root.DirectoryPath }))).GetArrayLength()); Assert.Empty(permission.Requests);
  }
  [Fact] public async Task ReadNeedsSessionAccountAndFolderScopeAndDoesNotAskForApproval()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    string[] resources = ["sessions:" + f.Chat.Definition.Id, "accounts:" + f.Account.Id, "folders:" + f.Root.DirectoryPath];
    foreach (var missing in resources)
    {
      var denied = Caller(door, resources.Where(r => r != missing).ToArray(), "sessions.get");
      await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(denied.Id, "sessions.get", Args(new { sessionId = f.Chat.Definition.Id })));
    }
    var allowed = Caller(door, resources, "sessions.get");
    var result = await door.CallAsync(allowed.Id, "sessions_get", Args(new { sessionId = f.Chat.Definition.Id }));
    Assert.Equal("chat", result.GetProperty("mode").GetString()); Assert.False(result.TryGetProperty("accountHome", out _)); Assert.Empty(permission.Requests);
  }
  [Fact] public async Task SendEnvelopeReusesClientIdAndNeedsExactExistingPermission()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var permission = new FakePermission(); var door = new McpDoor(permission); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var caller = Caller(door, ["*"], "sessions.send"); var clientId = Guid.NewGuid().ToString();
    var args = Args(new { sessionId = f.Chat.Definition.Id, text = ChatMcpTools.CommandPrefix + JsonSerializer.Serialize(new { action = "send", clientId, text = "hold" }) });
    await door.CallAsync(caller.Id, "sessions.send", args); await door.CallAsync(caller.Id, "sessions_send", args);
    Assert.Equal(1, f.Keeper.Writes[clientId]); Assert.Equal(2, permission.Requests.Count);
    permission.Answer = r => new(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), false);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = f.Chat.Definition.Id, text = "deck-chat:{\"action\":\"sendNow\",\"clientId\":\"" + clientId + "\"}" })));
  }
  [Fact] public async Task AccountChangesCannotBypassTheirExistingAlterPermissionThroughSend()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var door = new McpDoor(new FakePermission()); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var caller = Caller(door, ["*"], "sessions.send");
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.send", Args(new { sessionId = f.Chat.Definition.Id, text = "deck-chat:{\"action\":\"account\",\"accountId\":\"other\"}" })));
    Assert.Equal(f.Account.Id, f.Chats.Get(f.Chat.Definition.Id).Definition.AccountId);
  }
  [Fact] public async Task ImageChunksReconcileOffsetsAndSavedHistoryContainsOnlyMediaPaths()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); using var images = new ChatImageUploads(f.Chats); var id = Guid.NewGuid().ToString(); var chat = f.Chat.Definition.Id;
    await images.ApplyAsync(chat, "caller", Args(new { action = "imageBegin", uploadId = id, name = "test.png", mimeType = "image/png", width = 1, height = 1 }), default);
    var chunk = Args(new { action = "imageChunk", uploadId = id, offset = 0, data = "AQIDBA==" });
    await images.ApplyAsync(chat, "caller", chunk, default); await images.ApplyAsync(chat, "caller", chunk, default);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await images.ApplyAsync(chat, "other", chunk, default));
    await images.ApplyAsync(chat, "caller", Args(new { action = "imageFinish", uploadId = id }), default);
    var media = await images.ResolveAsync(chat, "caller", Args(new { uploadIds = new[] { id } }), default); Assert.Equal(4, Assert.Single(media).Bytes);
    var finishAgain = await images.ApplyAsync(chat, "caller", Args(new { action = "imageFinish", uploadId = id }), default); Assert.NotNull(finishAgain);
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hold", media); Assert.Equal(4, f.History.ReadMedia(chat, media[0]).Length);
  }
}
