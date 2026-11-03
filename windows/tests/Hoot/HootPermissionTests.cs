using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Hoot.Tests;

public sealed class HootPermissionTests
{
  [Theory]
  [InlineData("person", AiPermissionMode.Plan)]
  [InlineData("task", AiPermissionMode.Plan)]
  [InlineData("background", AiPermissionMode.Plan)]
  [InlineData("person", AiPermissionMode.Bypass)]
  [InlineData("task", AiPermissionMode.Bypass)]
  [InlineData("background", AiPermissionMode.Bypass)]
  public async Task SavedOwnerModeReachesEveryRecoveredTurn(string source, AiPermissionMode mode)
  {
    await using var f = new Fixture();
    var settings = new HootSettings("claude", f.AccountId, f.Folder, new(), 0, 0, mode);
    var turn = new HootTurn(Guid.NewGuid().ToString(), "Synthetic queued context", new(source), HootTurnState.Queued, DateTimeOffset.UtcNow);
    f.Store.Save(HootState.Empty with { Settings = settings, Turns = [turn] });
    await using var recovered = new HootService(f.Store, f.Chats, f.Accounts, f.Handoff);
    await recovered.StartAsync();
    Assert.Equal(mode, f.Store.Load()!.Settings!.PermissionMode);
    Assert.Equal(mode, Assert.Single(f.Process.Sent).Chat.Definition.PermissionMode);
  }

  [Fact]
  public async Task RecoveredQueuedTurnRetiresAChatWithAnOlderPermissionMode()
  {
    await using var f = new Fixture(); await f.Ready(); var first = await f.Say(); f.Complete(first);
    await Fixture.Wait(f.Hoot, state => !state.Busy); await f.Hoot.DisposeAsync();
    var saved = f.Store.Load()!; var oldChat = saved.ChatId!;
    f.Store.Save(saved with { Settings = saved.Settings! with { PermissionMode = AiPermissionMode.Plan },
      Turns = saved.Turns.Add(new(Guid.NewGuid().ToString(), "Later task", new("task"), HootTurnState.Queued, DateTimeOffset.UtcNow)) });
    await using var recovered = new HootService(f.Store, f.Chats, f.Accounts, f.Handoff); await recovered.StartAsync();
    Assert.NotEqual(oldChat, recovered.Read().ChatId); Assert.True(f.Chats.Get(oldChat).Ended);
    Assert.Equal(AiPermissionMode.Plan, f.Process.Sent.Last().Chat.Definition.PermissionMode);
  }

  [Fact]
  public async Task RecoveryCannotDrainAnOldBypassChatQueueBeforeApplyingPlan()
  {
    await using var f = new Fixture();
    var old = await f.Chats.CreateAsync(new(Guid.NewGuid().ToString(), "claude", f.Folder, "Old Hoot", f.AccountId, f.AccountId, new(), PermissionMode: AiPermissionMode.Bypass));
    var history = new ChatHistory(TerminalDeck.Core.Storage.AppDataRoot.Explicit(f.Folder));
    history.Save(old with { Messages = [new(Guid.NewGuid().ToString(), "Old queued write", [])] });
    await f.Process.EnsureAsync(ChatSessions.Session(old), false, default);
    f.Store.Save(HootState.Empty with { ChatId = old.Definition.Id, Settings = new("claude", f.AccountId, f.Folder, new(), 0, 0, AiPermissionMode.Plan),
      Turns = [new(Guid.NewGuid().ToString(), "New Plan turn", new("task"), HootTurnState.Queued, DateTimeOffset.UtcNow)] });
    await using var recoveredChats = new ChatSessions(history, f.Process, f.Accounts);
    await using var recovered = new HootService(f.Store, recoveredChats, f.Accounts, f.Handoff); await recovered.StartAsync();
    var sent = Assert.Single(f.Process.Sent);
    Assert.NotEqual(old.Definition.Id, sent.Chat.Definition.Id); Assert.Equal(AiPermissionMode.Plan, sent.Chat.Definition.PermissionMode);
    Assert.True(recoveredChats.Get(old.Definition.Id).Ended);
  }

  [Fact]
  public async Task OrdinaryAiCannotSelectBypassThroughTheSettingsTool()
  {
    await using var f = new Fixture(); await f.Ready(); var authority = new McpCallerAuthority(); var door = new McpDoor(authority);
    new HootMcpTools(f.Hoot).Register(door);
    var caller = authority.Provision(door, new("other-ai", "other-session", null, AiPermissionMode.Ask,
      ["hoot.settings.set"], [McpTier.Alter], ["sessions:other-session", "hoot:main", "accounts:" + f.AccountId, "folders:" + f.Folder]), _ => true);
    var args = JsonSerializer.SerializeToElement(new { settings = new { provider = "claude", accountId = f.AccountId, folder = f.Folder,
      options = new { model = "", effort = "" }, permissionMode = "bypass", refreshMinutes = 0, refreshAfterTurns = 0 } });
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "hoot.settings.set", args));
    Assert.Equal(AiPermissionMode.Ask, f.Hoot.Read().Settings!.PermissionMode);
  }

  [Fact]
  public async Task PlanModeRefusesAppChangesAndChangedOwnerModeInvalidatesOldAuthority()
  {
    await using var f = new Fixture(); await f.Ready();
    await f.Hoot.ConfigureAsync(f.Hoot.Read().Settings! with { PermissionMode = AiPermissionMode.Plan });
    var configured = f.Hoot.Read().Settings; var authority = new McpCallerAuthority(); var door = new McpDoor(authority);
    new HootMcpTools(f.Hoot).Register(door);
    var registration = authority.Provision(door, new("hoot-proof", "backing", HootDesk.Seat, configured!.PermissionMode,
      ["hoot.settings.read", "memory.hoot.save"], [McpTier.Read, McpTier.Alter],
      ["sessions:backing", "hoot:main", "accounts:" + f.AccountId, "folders:" + f.Folder]), _ => f.Hoot.Read().Settings == configured);
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(registration.Id, "memory.hoot.save", JsonSerializer.SerializeToElement(new { card = "change", playbook = "" })));
    Assert.Equal("", f.Hoot.Read().Memory.Card);
    await f.Hoot.ConfigureAsync(configured with { PermissionMode = AiPermissionMode.Ask });
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(registration.Id, "hoot.settings.read", JsonSerializer.SerializeToElement(new { })));
  }
}
