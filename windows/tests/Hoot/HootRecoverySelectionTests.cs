using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Hoot.Tests;

public sealed class HootRecoverySelectionTests
{
  [Fact]
  public async Task GeneralRecoveryCannotReconnectCurrentOrHistoricalHootBackingChats()
  {
    await using var f = new Fixture();
    var rows = new List<TerminalDeck.Core.Chats.ChatRecord>();
    for (var i = 0; i < 3; i++)
      rows.Add(await f.Chats.CreateAsync(new(Guid.NewGuid().ToString(), "claude", f.Folder, "Scratch", f.AccountId, f.AccountId, new(), PermissionMode: AiPermissionMode.Bypass)));
    var state = HootState.Empty with { ChatId = rows[0].Definition.Id,
      Settings = new("claude", f.AccountId, f.Folder, new(), PermissionMode: AiPermissionMode.Plan),
      Turns = [new(Guid.NewGuid().ToString(), "Earlier", new("task"), HootTurnState.Finished, DateTimeOffset.UtcNow, rows[1].Definition.Id)] };
    Assert.Equal(rows[2], Assert.Single(HootChatRecovery.OrdinaryChats(rows, state)));
    Assert.Equal(3, HootChatRecovery.OrdinaryChats(rows, null).Count);
    Assert.Empty(HootChatRecovery.OrdinaryChats(rows.Take(2), state));
  }
}
