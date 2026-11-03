using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Chats;

[Collection("Windows chat")]
public sealed class W13SessionPageTests
{
  [Fact]
  public async Task CommandOutputControlUsesTheExistingDoorWithoutSendingTheDraft()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync();
    var id = fixture.Chat.Definition.Id;
    var permission = new FakePermission(); var door = new McpDoor(permission);
    using var tools = new ChatMcpTools(fixture.Chats); tools.Register(door);
    var draft = ChatDraftWorkspace.Open(id); draft.Edit("keep this unsent"); var before = draft.Read();
    string? opened = null; draft.ControlRequested += control => opened = control;
    var caller = door.RegisterCaller(new("w13", "caller", null, true, AiPermissionMode.Ask,
      ["sessions.send"], [McpTier.Read, McpTier.Act, McpTier.Alter], ["sessions:" + id, "accounts:" + fixture.Account.Id, "folders:" + fixture.Root.DirectoryPath],
      DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "sessions.send", JsonSerializer.SerializeToElement(new {
      sessionId = id, text = "deck-chat:" + JsonSerializer.Serialize(new { action = "openControl", control = "commandOutput" })
    }));
    Assert.Equal("commandOutput", opened); Assert.Equal(before, draft.Read());
    Assert.Empty(fixture.Chats.Get(id).Messages); Assert.Equal(0, fixture.Keeper.Starts);
    Assert.Single(permission.Requests);
  }
}
