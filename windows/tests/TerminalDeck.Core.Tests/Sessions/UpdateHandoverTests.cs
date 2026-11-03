using System.Text;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tests.Chats;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class UpdateHandoverTests
{
  private static SessionDefinition Definition(string provider, string? conversation, string cwd = "C:\\work", string? purpose = null) =>
    new(Guid.NewGuid().ToString(), provider, cwd, "A session", ConversationId: conversation, Purpose: purpose);

  [Fact]
  public async Task HandoverRetiresEveryWorkerAndTheNextKeeperRestartsTheSessions()
  {
    var store = new MemoryState<SessionLedger>(); var processes = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, processes);
    var ai = await keeper.CreateAsync(Definition("claude", "conversation-1"));
    var shell = await keeper.CreateAsync(Definition("shell", null, "C:\\projects\\site"));
    var signIn = await keeper.CreateAsync(Definition("claude", null, purpose: "sign-in"));
    await keeper.AppendWorkerOutputAsync(shell.Definition.Id, shell.LeaseIdentity!, "PS C:\\projects\\site> ");
    var leases = new[] { ai, shell, signIn }.Select(r => r.LeaseIdentity!).ToArray();

    Assert.Equal(3, await keeper.PrepareUpdateAsync());
    foreach (var lease in leases) Assert.Contains("quit:" + lease, processes.Calls);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.CreateAsync(Definition("shell", null)));

    var savedAi = keeper.Get(ai.Definition.Id); var savedShell = keeper.Get(shell.Definition.Id);
    Assert.Equal(SessionState.Starting, savedAi.State); Assert.True(savedAi.Resume); Assert.False(savedAi.HasStarted); Assert.NotEqual(ai.CreationKey, savedAi.CreationKey);
    Assert.Equal(SessionState.Starting, savedShell.State); Assert.False(savedShell.Resume); Assert.Null(savedShell.LeaseIdentity);
    Assert.StartsWith("PS C:\\projects\\site> ", savedShell.Replay);
    Assert.Contains("This terminal restarted in C:\\projects\\site.", savedShell.ReplayPrefix);
    Assert.Equal(SessionState.Exited, keeper.Get(signIn.Definition.Id).State);

    // The new version's keeper uses its normal recovery: the conversation
    // resumes, the terminal restarts in its folder, the note stays above it.
    processes.Observations.Clear(); processes.Calls.Clear();
    var next = new SessionKeeper(store, processes);
    await next.RecoverAsync();
    Assert.Contains("resume:" + ai.Definition.Id, processes.Calls);
    Assert.Contains("start:" + shell.Definition.Id, processes.Calls);
    Assert.DoesNotContain("start:" + signIn.Definition.Id, processes.Calls);
    var restarted = next.Get(shell.Definition.Id);
    Assert.Equal(SessionState.Running, restarted.State);
    await next.RestoreWorkerReplayAsync(restarted.Definition.Id, restarted.LeaseIdentity!, "PS C:\\projects\\site> ", false, null);
    Assert.Contains("[Terminal Deck was updated. This terminal restarted in C:\\projects\\site.]", next.Get(shell.Definition.Id).Replay);
    Assert.Equal(1, next.List().Count(r => r.Definition.Id == shell.Definition.Id));
  }

  [Fact]
  public async Task AnUnreachableWorkerStopsTheUpdateWithoutStoppingAnything()
  {
    var processes = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes);
    var first = await keeper.CreateAsync(Definition("shell", null));
    var second = await keeper.CreateAsync(Definition("codex", "conversation-2"));
    processes.Observations[second.Definition.Id] = new(ProcessPresence.Unknown);
    await Assert.ThrowsAsync<IOException>(async () => await keeper.PrepareUpdateAsync());
    Assert.DoesNotContain(processes.Calls, c => c.StartsWith("quit:", StringComparison.Ordinal));
    Assert.Equal(first.CreationKey, keeper.Get(first.Definition.Id).CreationKey);
    Assert.False(keeper.Updating);
    await keeper.CreateAsync(Definition("shell", null));
  }

  [Fact]
  public async Task PrepareUpdateNeedsAuthenticationTheCurrentInstanceAndSupport()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper());
    var secret = new string('s', 64); var calls = 0;
    var endpoint = new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture", null, _ => { calls++; return ValueTask.FromResult(0); });
    await Assert.ThrowsAsync<UnauthorizedAccessException>(async () => await endpoint.HandleAsync(new() { Secret = new string('x', 64), Operation = "prepare-update", Instance = keeper.Instance }));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await endpoint.HandleAsync(new() { Secret = secret, Operation = "prepare-update", Instance = Guid.NewGuid() }));
    Assert.Equal(0, calls);
    Assert.True((await endpoint.HandleAsync(new() { Secret = secret, Operation = "prepare-update", Instance = keeper.Instance })).Success);
    Assert.Equal(1, calls);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture")
      .HandleAsync(new() { Secret = secret, Operation = "prepare-update", Instance = keeper.Instance }));
  }
}

[Collection("Windows chat")]
public sealed class ChatUpdateHandoverTests
{
  [Fact]
  public async Task ChatsKeepTheirConversationAcrossAnUpdate()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "hello");
    await ChatFixture.UntilAsync(() => !f.Chats.Get(id).Busy && f.Chats.Get(id).ConversationId is not null);
    var before = f.Chats.Get(id); var starts = f.Keeper.Starts;

    Assert.Equal(1, await f.Chats.PrepareUpdateAsync());
    var saved = f.Chats.Get(id);
    Assert.NotEqual(before.CreationKey, saved.CreationKey); Assert.Equal(before.ConversationId, saved.ConversationId);
    Assert.Equal(before.Messages.Length, saved.Messages.Length); Assert.False(saved.Ended); Assert.Null(saved.Problem);
    Assert.Equal(ProcessPresence.Dead, (await f.Keeper.ObserveAsync(ChatSessions.Session(before), default)).Presence);

    // The next version continues the same conversation on the next message.
    await f.RestartAsync();
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "hello again");
    await ChatFixture.UntilAsync(() => f.Chats.Get(id).Events.Count(e => e.Kind == "complete") == 2);
    Assert.Equal(starts + 1, f.Keeper.Starts); Assert.Equal(before.ConversationId, f.Chats.Get(id).ConversationId);
  }
}
