using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Chats;

[Collection("Windows chat")]
public sealed class ChatSessionsTests
{
  [Fact] public async Task RealPipeStreamsUnicodeAndFullMessageReplacesItsDeltas()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(f.Chat.Definition.Id, id, "hello");
    await ChatFixture.UntilAsync(() => f.Chats.Get(f.Chat.Definition.Id).Events.Any(e => e.Kind == "complete"));
    var chat = f.Chats.Get(f.Chat.Definition.Id); var rows = ChatProjection.Rows(chat);
    Assert.Equal("hello", chat.Definition.Title); Assert.Single(rows, r => r.Kind == "assistant");
    Assert.Equal("Reply 🙂 hello", rows.Single(r => r.Kind == "assistant").Text); Assert.Equal(1, f.Keeper.Writes[id]); Assert.False(chat.Busy);
  }
  [Fact] public async Task SendNowMovesOnlyTheChosenIdAndIdenticalTextIsNeverDeduplicated()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    var active = Guid.NewGuid().ToString(); var first = Guid.NewGuid().ToString(); var second = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(chat, active, "hold"); await f.Chats.SendAsync(chat, first, "identical"); await f.Chats.SendAsync(chat, second, "identical");
    Assert.Equal(2, f.Chats.Get(chat).Messages.Count(m => m.State == ChatMessageState.Queued));
    await f.Chats.SendNowAsync(chat, second);
    await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Count(e => e.Kind == "complete") == 3);
    var users = f.Chats.Get(chat).Events.Where(e => e.Kind == "user").Select(e => e.ClientId).ToArray();
    Assert.Equal(new[] { active, second, first }, users); Assert.Equal(1, f.Keeper.Writes[first]); Assert.Equal(1, f.Keeper.Writes[second]);
    await f.Chats.SendAsync(chat, second, "identical"); Assert.Equal(1, f.Keeper.Writes[second]);
  }
  [Fact] public async Task QueuedEditsAndRemovalSurviveRestartWithoutSendingThem()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    var edited = Guid.NewGuid().ToString(); var removed = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hold"); await f.Chats.SendAsync(chat, edited, "before"); await f.Chats.SendAsync(chat, removed, "remove");
    await f.Chats.EditQueuedAsync(chat, edited, "after"); await f.Chats.RemoveQueuedAsync(chat, removed); await f.RestartAsync();
    Assert.Equal("after", f.Chats.Get(chat).Messages.Single(m => m.ClientId == edited).Text); Assert.Equal(ChatMessageState.Removed, f.Chats.Get(chat).Messages.Single(m => m.ClientId == removed).State);
    Assert.False(f.Keeper.Writes.ContainsKey(edited)); Assert.False(f.Keeper.Writes.ContainsKey(removed)); Assert.Equal(1, f.Keeper.Starts);
  }
  [Fact] public async Task RestartAttachesSameProcessAndReplaysOnlyEventsAfterSavedBoundary()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hello"); await ChatFixture.UntilAsync(() => !f.Chats.Get(chat).Busy);
    var before = f.Chats.Get(chat); await f.RestartAsync();
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "again"); await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Count(e => e.Kind == "complete") == 2);
    Assert.Equal(1, f.Keeper.Starts); Assert.Equal(before.ConversationId, f.Chats.Get(chat).ConversationId);
    Assert.Equal(2, ChatProjection.Rows(f.Chats.Get(chat)).Count(r => r.Kind == "assistant"));
    Assert.Equal(f.Chats.Get(chat).Events.Length, f.Chats.Get(chat).Events.Select(e => e.Sequence).Distinct().Count());
  }
  [Fact] public async Task LostSendReplyReconcilesByClientIdAfterRestartWithoutAnotherWrite()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id; var id = Guid.NewGuid().ToString();
    f.Keeper.LoseNextReply = true; await f.Chats.SendAsync(chat, id, "hold");
    Assert.Equal(ChatMessageState.Uncertain, f.Chats.Get(chat).Messages.Single().State);
    await f.RestartAsync(); await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Messages.Single().State == ChatMessageState.Sent);
    Assert.Equal(1, f.Keeper.Writes[id]); Assert.Single(f.Chats.Get(chat).Messages); Assert.Equal(1, f.Keeper.Starts);
  }
  [Theory] [InlineData(true)] [InlineData(false)]
  public async Task ApprovalRoundTripUsesExactRequestAndCannotAnswerTwice(bool allow)
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "approval");
    await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Any(e => e.Kind == "approval"));
    var request = f.Chats.Get(chat).Events.Single(e => e.Kind == "approval"); await f.Chats.AnswerAsync(chat, request.Id, allow);
    await ChatFixture.UntilAsync(() => !f.Chats.Get(chat).Busy);
    Assert.Equal("Reply 🙂 " + (allow ? "allowed" : "refused"), ChatProjection.Rows(f.Chats.Get(chat)).Single(r => r.Kind == "assistant").Text);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Chats.AnswerAsync(chat, request.Id, !allow));
  }
  [Fact] public async Task SignedOutAccountKeepsMessageAndShowsPlainSentenceWithoutLaunching()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false); var chat = f.Chat.Definition.Id;
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hello");
    Assert.Equal("Not signed in to Claude. Sign in to continue.", f.Chats.Get(chat).Problem); Assert.Equal(0, f.Keeper.Starts);
    Assert.Equal(ChatMessageState.Failed, f.Chats.Get(chat).Messages.Single().State);
  }
  [Fact] public async Task UnknownWorkerIsHeldAndNeverRecreated()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hold"); var key = f.Chats.Get(chat).CreationKey;
    f.Keeper.PresenceOverride = ProcessPresence.Unknown; await f.RestartAsync();
    Assert.Equal(key, f.Chats.Get(chat).CreationKey); Assert.Equal(1, f.Keeper.Starts); Assert.Contains("waiting to reconnect", f.Chats.Get(chat).Problem);
  }
  [Fact] public async Task ReusedClientIdWithDifferentTextIsRefusedBeforeAnotherWrite()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id; var id = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(chat, id, "hold"); await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Chats.SendAsync(chat, id, "changed")); Assert.Equal(1, f.Keeper.Writes[id]);
  }
  [Fact] public async Task StopKeepsQueueAndDoesNotAutomaticallySendIt()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id; var queued = Guid.NewGuid().ToString();
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hold"); await f.Chats.SendAsync(chat, queued, "queued"); await f.Chats.StopAsync(chat);
    await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Any(e => e.Kind == "complete"));
    Assert.False(f.Keeper.Writes.ContainsKey(queued)); Assert.Equal(ChatMessageState.Queued, f.Chats.Get(chat).Messages.Single(m => m.ClientId == queued).State);
  }
  [Fact] public async Task ModelChoiceUsesAccountOffersIncludingOneMillionAndResumesSameConversation()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    f.Provider.Models = [new("synthetic-1m", "Synthetic 1M", 1_000_000, true)];
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hello"); await ChatFixture.UntilAsync(() => !f.Chats.Get(chat).Busy); var conversation = f.Chats.Get(chat).ConversationId;
    await f.Chats.SetOptionsAsync(chat, new("synthetic-1m", "high")); await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "again");
    await ChatFixture.UntilAsync(() => f.Chats.Get(chat).Events.Count(e => e.Kind == "complete") == 2);
    Assert.Equal(conversation, f.Chats.Get(chat).ConversationId); Assert.Equal(2, f.Keeper.Starts); Assert.Equal("synthetic-1m", f.Chats.Get(chat).Definition.Options.Model);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Chats.SetOptionsAsync(chat, new("not-offered")));
  }
  [Fact] public async Task V3cAccountChoiceBeforeStartUsesHomeIdAndRefusesAMissingSavedTranscript()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat.Definition.Id;
    var other = await f.Accounts.CreateAsync("claude", "Other"); f.Provider.Statuses[other.Id] = new(true, "other@example.test"); await f.Accounts.RefreshAsync(other.Id);
    await f.Chats.SetAccountAsync(chat, other.Id); Assert.Equal(other.HomeId, f.Chats.Get(chat).Definition.AccountHome);
    await f.Chats.SendAsync(chat, Guid.NewGuid().ToString(), "hello"); await ChatFixture.UntilAsync(() => !f.Chats.Get(chat).Busy);
    await Assert.ThrowsAsync<IOException>(async () => await f.Chats.SetAccountAsync(chat, f.Account.Id)); Assert.Equal(other.Id, f.Chats.Get(chat).Definition.AccountId);
  }
  [Fact] public async Task V3cSwitchedChatContinuesThroughTheSyntheticCliWithoutRepeatingItsFirstMessage()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var first = Guid.NewGuid().ToString(); await f.Chats.SendAsync(id, first, "hello"); await ChatFixture.UntilAsync(() => !f.Chats.Get(id).Busy);
    var before = f.Chats.Get(id); var other = await f.Accounts.CreateAsync("claude", "Other"); f.Provider.Statuses[other.Id] = new(true, "other@example.test");
    var transcript = Path.Combine(f.Root.DirectoryPath, "accounts", f.Account.HomeId, "claude", "projects", "fixture", before.ConversationId + ".jsonl");
    Directory.CreateDirectory(Path.GetDirectoryName(transcript)!);
    File.WriteAllText(transcript, JsonSerializer.Serialize(new { sessionId = before.ConversationId, cwd = f.Root.DirectoryPath }) + "\n");
    await f.Chats.SetAccountAsync(id, other.Id);
    var second = Guid.NewGuid().ToString(); await f.Chats.SendAsync(id, second, "again");
    await ChatFixture.UntilAsync(() => f.Chats.Get(id).Events.Count(e => e.Kind == "complete") == 2);
    Assert.Equal(before.ConversationId, f.Chats.Get(id).ConversationId); Assert.Equal(other.HomeId, f.Chats.Get(id).Definition.AccountHome);
    Assert.Equal(2, f.Keeper.Starts); Assert.Equal(1, f.Keeper.Writes[first]); Assert.Equal(1, f.Keeper.Writes[second]);
    Assert.Equal(2, ChatProjection.Rows(f.Chats.Get(id)).Count(r => r.Kind == "assistant"));
  }
}
