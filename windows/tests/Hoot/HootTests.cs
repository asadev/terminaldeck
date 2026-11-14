using System.Text.Json;
using TerminalDeck.App.Views.Hoot;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Hoot.Tests;

public sealed class HootTests
{
  [Fact] public void TurnValueEqualitySurvivesMediaStorageAndDetectsChangedContent()
  {
    var file = ChatAttachmentData.Read("proof.pdf", "%PDF-1.7\nsynthetic"u8.ToArray());
    var turn = new HootTurn(Guid.NewGuid().ToString(), "", new("person"), HootTurnState.Queued, DateTimeOffset.UtcNow) { Attachments = [file], AttachmentKeys = ["receipt"] };
    var restored = JsonSerializer.Deserialize<HootTurn>(JsonSerializer.Serialize(turn))!;
    Assert.Equal(turn, restored); Assert.Equal(turn.GetHashCode(), restored.GetHashCode());
    Assert.NotEqual(turn, restored with { Attachments = [file with { Data = "%PDF-1.7\nchanged"u8.ToArray() }] });
    Assert.NotEqual(turn, restored with { AttachmentKeys = ["different-receipt"] });
  }

  [Fact] public async Task AttachmentOnlyTurnUsesActualChatMediaAndKeepsCallerAcrossQueue()
  {
    await using var f = new Fixture(); await f.Ready();
    var first = await f.Say(); var id = Guid.NewGuid().ToString();
    var data = ChatAttachmentData.Read("proof.pdf", "%PDF-1.7\nsynthetic"u8.ToArray());
    var source = new HootSource("person") { DeviceId = "phone", Restricted = true };
    await f.Hoot.SayWithAttachmentsAsync(id, "", [data], source);
    Assert.Single(f.Process.Sent); Assert.Equal(source, f.Hoot.Read().Turns.Single(t => t.Id == id).Source);
    f.Complete(first); await Fixture.Wait(f.Hoot, state => state.Active?.Id == id && state.Active.State == HootTurnState.Running);
    var sent = f.Process.Sent.Last(); var media = Assert.Single(sent.Message.Media);
    Assert.Equal("application/pdf", media.MimeType); Assert.Equal(data.Data, f.Chats.ReadImage(sent.Chat.Definition.Id, media));
    f.Complete(id); await Fixture.Wait(f.Hoot, state => !state.Busy);
    Assert.Empty(f.Hoot.Read().Turns.Single(t => t.Id == id).Attachments);
    Assert.Empty(f.Store.Load()!.Turns.Single(t => t.Id == id).Attachments);
    await f.Hoot.SayWithAttachmentsAsync(id, "", [data], source); Assert.Equal(2, f.Process.Sent.Count);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Hoot.SayWithAttachmentsAsync(id, "", [data with { Name = "other.pdf" }], source));
  }

  [Fact] public async Task UsesOwnSeatAccountAndHiddenDeskWithStableVisibleWords()
  {
    await using var f = new Fixture(); await f.Ready(); await f.Hoot.SaveMemoryAsync("Keep the project decisions.", "Use the right agent for each job.");
    var id = await f.Say("Please review this"); var sent = Assert.Single(f.Process.Sent);
    Assert.Equal(f.AccountId, sent.Chat.Definition.AccountId); Assert.Contains("seat is orchestrator", sent.Chat.Definition.Instructions);
    Assert.Contains("<deck-memory>", sent.Message.Text); Assert.Contains("Use the right agent", sent.Message.Text);
    Assert.Equal("Please review this", Assert.Single(f.Hoot.Read().Lines).Text);
    f.Complete(id, "I checked it."); await Fixture.Wait(f.Hoot, s => !s.Busy);
    Assert.Equal("Awake", f.Hoot.Read().Status); Assert.Contains(f.Hoot.Read().Lines, l => l.Kind == "assistant" && l.Text == "I checked it.");
  }
  [Fact] public async Task SameIdIsOneSendAndDifferentPayloadIsRejected()
  {
    await using var f = new Fixture(); await f.Ready(); var id = await f.Say();
    await f.Hoot.SayAsync(id, "Hello Hoot"); Assert.Single(f.Process.Sent);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Hoot.SayAsync(id, "Other text"));
  }
  [Fact] public async Task BackgroundAndTaskTurnsAreQuietAndTheirResultsStayReachable()
  {
    await using var f = new Fixture(); await f.Ready(); var id = Guid.NewGuid().ToString();
    var result = HootTaskTurns.RunAsync(f.Hoot, id, "task-1", "Review the queue", "Check the queue using the granted task tools.").AsTask();
    await Fixture.Wait(f.Hoot, s => s.Active?.Id == id);
    Assert.DoesNotContain(f.Hoot.Read().Lines, l => l.Kind == "user"); Assert.Single(f.Hoot.Read().Lines.Where(l => l.Kind == "background"));
    f.Complete(id, "The queue is checked."); var answer = await result.WaitAsync(TimeSpan.FromSeconds(8));
    Assert.True(answer.Finished); Assert.Equal("The queue is checked.", answer.Answer);
    Assert.DoesNotContain(f.Hoot.Read().Lines, l => l.Kind == "assistant");
    var quiet = Guid.NewGuid().ToString(); await f.Hoot.BackgroundTurnAsync(quiet, "dev-test", "proof-1", "Quiet proof", "A synthetic background request.");
    f.Complete(quiet); await Fixture.Wait(f.Hoot, s => !s.Busy); Assert.Single(f.Hoot.Read().Lines);
  }
  [Fact] public async Task QueuedPersonTurnWaitsForTaskAndCancellationDoesNotSendQueuedTask()
  {
    await using var f = new Fixture(); await f.Ready(); var task = Guid.NewGuid().ToString(); var cancelled = Guid.NewGuid().ToString();
    await f.Hoot.BackgroundTurnAsync(task, "task", "1", "First task", "Do the first task.");
    var person = await f.Say("Next question"); await f.Hoot.BackgroundTurnAsync(cancelled, "task", "2", "Second task", "Do the second task.");
    await f.Hoot.CancelBackgroundAsync(cancelled); Assert.Single(f.Process.Sent);
    f.Complete(task); await Fixture.Wait(f.Hoot, s => s.Active is { State: HootTurnState.Running } turn && turn.Id == person);
    Assert.Equal(2, f.Process.Sent.Count); f.Complete(person); await Fixture.Wait(f.Hoot, s => !s.Busy);
    Assert.Equal(HootTurnState.Stopped, f.Hoot.Read().Turns.Single(t => t.Id == cancelled).State);
  }
  [Fact] public async Task ExplicitNewChatArchivesFullConversationAndKeepsMemoryWithoutAnAiCall()
  {
    await using var f = new Fixture(); await f.Ready(); var first = await f.Say(); f.Complete(first); await Fixture.Wait(f.Hoot, s => !s.Busy);
    await f.Hoot.SaveBoardAsync(new("row", "Review", "working", "Queue proof", null, default));
    var before = f.Hoot.Read(); await f.Hoot.RefreshAsync(); var after = f.Hoot.Read();
    Assert.NotEqual(before.ConversationId, after.ConversationId); Assert.Empty(after.Lines); Assert.Empty(after.Turns); Assert.Null(after.ChatId); Assert.Single(f.Process.Sent);
    var archived = Assert.Single(after.History); Assert.Equal(before.ConversationId, archived.Id); Assert.Equal(before.Lines, archived.Lines); Assert.Equal(before.Turns, archived.Turns);
    Assert.Equal(archived.Lines.ToArray(), Assert.Single(f.Store.Load()!.History).Lines.ToArray());
    Assert.Equal(archived.Turns.ToArray(), Assert.Single(f.Store.Load()!.History).Turns.ToArray());
    Assert.Equal("working", after.Memory.Board[0].State); Assert.NotEmpty(after.Memory.Desks);
    var next = await f.Say("Continue"); Assert.NotEqual(before.ChatId, f.Hoot.Read().ChatId);
    Assert.Contains("Queue proof", f.Process.Sent.Last().Chat.Definition.Instructions); f.Complete(next); await Fixture.Wait(f.Hoot, s => !s.Busy);
  }
  [Fact] public async Task LegacyTurnRefreshCannotRetireTheConversation()
  {
    await using var f = new Fixture(); await f.Ready(after: 1); var id = await f.Say(); f.Complete(id);
    await Fixture.Wait(f.Hoot, s => !s.Busy); var chat = f.Hoot.Read().ChatId;
    Assert.NotNull(chat); Assert.Equal(0, f.Hoot.Read().Settings!.RefreshAfterTurns);
    var next = await f.Say("Keep going"); Assert.Equal(chat, f.Hoot.Read().ChatId);
    f.Complete(next); await Fixture.Wait(f.Hoot, s => !s.Busy); Assert.Empty(f.Hoot.Read().History);
  }
  [Fact] public async Task ModelChangesKeepTheBackingConversationAndFullMessages()
  {
    await using var f = new Fixture(); await f.Ready(); var first = await f.Say(); f.Complete(first); await Fixture.Wait(f.Hoot, s => !s.Busy);
    var before = f.Hoot.Read();
    await f.Hoot.ConfigureAsync(before.Settings! with { Options = new("fixture", "high") });
    var after = f.Hoot.Read(); Assert.Equal(before.ChatId, after.ChatId); Assert.Equal(before.ConversationId, after.ConversationId);
    Assert.Equal(before.Lines, after.Lines); Assert.False(f.Chats.Get(after.ChatId!).Ended); Assert.Single(f.Process.Sent);
    Assert.Equal(new("fixture", "high"), f.Chats.Get(after.ChatId!).Definition.Options);
  }
  [Fact] public async Task ArchivedBackingChatKeepsItsSelfControlFence()
  {
    await using var f = new Fixture(); await f.Ready(); var id = await f.Say(); f.Complete(id); await Fixture.Wait(f.Hoot, s => !s.Busy);
    var chat = f.Hoot.Read().ChatId!; await f.Hoot.RefreshAsync();
    var grant = new McpGrant("old-hoot", chat, null, true, AiPermissionMode.Ask, [], [], [], DateTimeOffset.UtcNow.AddHours(1));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "hoot.chat.new", JsonSerializer.SerializeToElement(new { }), f.Hoot.Read()));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "sessions.stop", JsonSerializer.SerializeToElement(new { sessionId = chat }), f.Hoot.Read()));
  }
  [Fact] public async Task InvalidArchivedHistoryFailsClosedWithoutReplacingSavedWords()
  {
    await using var f = new Fixture(); var saved = new State<HootState>(HootState.Empty with { History = default });
    Assert.Throws<IOException>(() => new HootService(saved, f.Chats, f.Accounts, f.Handoff));
    Assert.True(saved.Load()!.History.IsDefault);
  }
  [Fact] public async Task ExplicitNewChatRefusesToLoseQueuedOrUnconfirmedWork()
  {
    await using var f = new Fixture(); await f.Ready(); f.Process.LoseReceipt = true; await f.Say();
    var before = f.Hoot.Read();
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Hoot.RefreshAsync());
    Assert.Equal(before, f.Hoot.Read()); Assert.Single(f.Process.Sent);
  }
  [Fact] public async Task LegacyTimePlanDoesNotCreateATimerOnRecovery()
  {
    await using var f = new Fixture(); await f.Ready(); var id = await f.Say(); f.Complete(id); await Fixture.Wait(f.Hoot, s => !s.Busy);
    await f.Hoot.DisposeAsync(); var saved = f.Store.Load()!;
    f.Store.Save(saved with { Settings = saved.Settings! with { RefreshMinutes = 1, RefreshAfterTurns = 1 } });
    var clock = new NoTimersClock();
    await using var recovered = new HootService(f.Store, f.Chats, f.Accounts, f.Handoff, clock);
    await recovered.StartAsync(); Assert.Equal(saved.ChatId, recovered.Read().ChatId); Assert.Equal(0, clock.Created);
  }
  private sealed class NoTimersClock : TimeProvider
  {
    public int Created;
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    { Created++; throw new InvalidOperationException("Hoot must not schedule conversation resets."); }
  }
  [Fact] public async Task LostReceiptIsNeverAutomaticallySentAgain()
  {
    await using var f = new Fixture(); await f.Ready(); f.Process.LoseReceipt = true; var id = await f.Say();
    Assert.Equal(HootTurnState.Uncertain, f.Hoot.Read().Turns.Single(t => t.Id == id).State);
    await f.Hoot.SayAsync(id, "Hello Hoot"); await f.Say("Later question"); Assert.Single(f.Process.Sent);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Hoot.ContinueAsync());
    await f.Hoot.KeepUnconfirmedAsync(); Assert.Single(f.Process.Sent);
    f.Process.LoseReceipt = false; await f.Hoot.ContinueAsync(); Assert.Equal(2, f.Process.Sent.Count);
  }
  [Fact] public async Task RecoveryAttachesToTheSavedTurnWithoutResending()
  {
    await using var f = new Fixture(); await f.Ready(); var id = await f.Say(); await f.Hoot.DisposeAsync();
    await using var recovered = new HootService(f.Store, f.Chats, f.Accounts, f.Handoff); await recovered.StartAsync();
    Assert.Single(f.Process.Sent); var chatId = recovered.Read().ChatId!;
    f.Process.Emit(chatId, id, "message", "Recovered answer"); f.Process.Emit(chatId, id, "complete");
    await Fixture.Wait(recovered, s => !s.Busy); Assert.Equal("Recovered answer", recovered.Read().Turns.Single().Answer);
  }
  [Fact] public async Task AgentNotesCannotBecomeThePersonsWords()
  {
    await using var f = new Fixture(); await f.Ready(); var id = Guid.NewGuid().ToString();
    await f.Hoot.SayAsync(id, "App supplied context", new("session", "other", "A note from another session"));
    Assert.DoesNotContain(f.Hoot.Read().Lines, l => l.Kind == "user"); Assert.Single(f.Hoot.Read().Lines.Where(l => l.Kind == "context"));
    Assert.Contains("\"kind\":\"session\"", f.Process.Sent.Single().Message.Text);
  }
  [Fact] public async Task BackgroundApprovalIsVisibleAndResolvedThroughTheSameChat()
  {
    await using var f = new Fixture(); await f.Ready(); var id = Guid.NewGuid().ToString();
    await f.Hoot.BackgroundTurnAsync(id, "task", "1", "Write note", "Write the approved note.");
    f.Process.Emit(f.Hoot.Read().ChatId!, id, "approval", "Allow writing the note?", "permission");
    await Fixture.Wait(f.Hoot, s => s.Lines.Any(l => l.Kind == "approval" && l.Waiting));
    await f.Hoot.AnswerAsync("permission", false); await Fixture.Wait(f.Hoot, s => s.Lines.Any(l => l.Kind == "approval" && !l.Waiting));
    Assert.DoesNotContain(f.Hoot.Read().Lines, l => l.Kind == "user");
  }
  [Fact] public async Task HandoffReceiptsPreventDuplicatesAfterALostReply()
  {
    await using var f = new Fixture(); await f.Ready(); var id = Guid.NewGuid().ToString(); var session = Guid.NewGuid().ToString(); f.Handoff.LoseReply = true;
    await Assert.ThrowsAsync<IOException>(async () => await f.Hoot.HandoffAsync(id, session, "Goal, decisions and next step."));
    var saved = await f.Hoot.HandoffAsync(id, session, "Goal, decisions and next step."); Assert.False(saved.Sent); Assert.Equal(1, f.Handoff.Count);
    Assert.Single(f.Store.Load()!.Memory.Handoffs);
  }
  [Fact] public async Task PageModelShowsUncertainTurnWithoutResending()
  {
    await using var f = new Fixture(); await f.Ready(); using var model = new HootViewModel(f.Hoot); model.Draft = "A question";
    // The backend records uncertain dispatch as a durable result; the user can
    // inspect that turn rather than manufacturing another send identity.
    f.Process.LoseReceipt = true; await model.SendAsync(); Assert.Single(f.Process.Sent);
    Assert.Equal(HootTurnState.Uncertain, model.State.Turns.Single().State); Assert.NotNull(model.State.Problem);
  }
  [Fact] public void OwnSettingsFenceCoversSeatAndSavedChatIdentity()
  {
    var chat = Guid.NewGuid().ToString(); var account = Guid.NewGuid().ToString("N");
    var state = HootState.Empty with { Settings = new("claude", account, Path.GetTempPath(), new()), ChatId = chat };
    var grant = new McpGrant("hoot", chat, null, true, AiPermissionMode.Ask, [], [], [], DateTimeOffset.UtcNow.AddHours(1), SeatId: HootDesk.Seat);
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "hoot.settings.set", JsonSerializer.SerializeToElement(new { }), state));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "sessions.account", JsonSerializer.SerializeToElement(new { sessionId = chat }), state));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "hoot.send", JsonSerializer.SerializeToElement(new { }), state));
    HootPolicy.Check(grant, "sessions.send", JsonSerializer.SerializeToElement(new { sessionId = "other" }), state);
    HootPolicy.Check(grant, "hoot.settings.read", JsonSerializer.SerializeToElement(new { }), state);
    HootPolicy.Check(grant with { SeatId = null, SessionId = "other" }, "hoot.settings.set", JsonSerializer.SerializeToElement(new { }), state);
  }
  [Fact] public async Task LargeSavedDeskKeepsFullMemoryAndFitsTheChatWireWithTypedSource()
  {
    await using var f = new Fixture(); await f.Ready(); var card = new string('<', 16000); var playbook = new string('>', 16000);
    await f.Hoot.SaveMemoryAsync(card, playbook); await f.Say(new string('x', 64000));
    var sent = Assert.Single(f.Process.Sent); Assert.True(sent.Message.Text.Length < 128000); Assert.True(sent.Chat.Definition.Instructions.Length < 128000);
    Assert.Equal(card, f.Hoot.Read().Memory.Card); Assert.Equal(playbook, f.Hoot.Read().Memory.Playbook);
    var start = sent.Message.Text.IndexOf("<deck-memory>", StringComparison.Ordinal) + "<deck-memory>".Length;
    var end = sent.Message.Text.LastIndexOf("</deck-memory>", StringComparison.Ordinal);
    using var block = JsonDocument.Parse(sent.Message.Text[start..end]);
    Assert.Equal("person", block.RootElement.GetProperty("context").GetProperty("source").GetProperty("kind").GetString());
    Assert.Contains("memory.hoot.read", block.RootElement.GetProperty("memory").GetProperty("leftOut").GetString());
  }
  [Fact] public async Task TranscriptCursorIncludesEditsToAnAlreadySeenStreamingAnswer()
  {
    await using var f = new Fixture(); await f.Ready(); var id = await f.Say(); var chat = f.Hoot.Read().ChatId!;
    f.Process.Emit(chat, id, "textDelta", "First"); await Fixture.Wait(f.Hoot, s => s.Lines.Any(l => l.Text == "First"));
    var first = HootTranscript.Read(f.Hoot.Read()); var sequence = first.Lines.Single(l => l.Kind == "assistant").Sequence;
    f.Process.Emit(chat, id, "textDelta", " second"); await Fixture.Wait(f.Hoot, s => s.Lines.Any(l => l.Text == "First second"));
    var update = HootTranscript.Read(f.Hoot.Read(), first.NextCursor); var changed = Assert.Single(update.Lines);
    Assert.Equal("First second", changed.Text); Assert.Equal(sequence, changed.Sequence); Assert.True(update.NextCursor > first.NextCursor);
  }
  [Fact] public async Task LaterTurnCannotReplaceAnEarlierVisibleAnswerWithTheSameProviderRowId()
  {
    await using var f = new Fixture(); await f.Ready(); var first = await f.Say("First question"); f.Complete(first, "First answer");
    await Fixture.Wait(f.Hoot, s => !s.Busy); var second = await f.Say("Second question"); f.Complete(second, "Second answer");
    await Fixture.Wait(f.Hoot, s => !s.Busy);
    var answers = f.Hoot.Read().Lines.Where(l => l.Kind == "assistant").ToArray();
    Assert.Equal(new[] { "First answer", "Second answer" }, answers.Select(l => l.Text));
    Assert.Equal(2, answers.Select(l => l.Sequence).Distinct().Count());
  }
  [Fact] public void GenericChatToolsCannotBypassHootSelfApprovalFence()
  {
    var chat = Guid.NewGuid().ToString(); var state = HootState.Empty with { ChatId = chat };
    var grant = new McpGrant("hoot", chat, null, true, AiPermissionMode.Ask, [], [], [], DateTimeOffset.UtcNow.AddHours(1), SeatId: HootDesk.Seat);
    var answer = JsonSerializer.SerializeToElement(new { sessionId = chat, text = "deck-chat:{\"action\":\"answer\",\"allow\":true}" });
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "sessions.send", answer, state));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "sessions.stop", answer, state));
    Assert.Throws<McpRefusal>(() => HootPolicy.Check(grant, "sessions.keys", answer, state));
    HootPolicy.Check(grant, "sessions.account", JsonSerializer.SerializeToElement(new { sessionId = chat, action = "show" }), state);
    HootPolicy.Check(grant, "accounts.status", JsonSerializer.SerializeToElement(new { accountId = "own" }), state);
  }
  [Fact] public void ToolContractsHaveReadOrGuardedWriteTiersAndNoApprovalBypassDoor()
  {
    Assert.Equal(19, HootMcpTools.Specs.Count); Assert.Equal(19, HootMcpTools.Specs.Select(s => s.Wire).Distinct().Count());
    Assert.Equal(McpTier.Alter, HootMcpTools.Specs.Single(s => s.Id == "hoot.chat.branch").Tier);
    Assert.All(HootMcpTools.Specs.Where(s => s.Id.EndsWith(".read") || s.Id.EndsWith(".background")), s => Assert.Equal(McpTier.Read, s.Tier));
    Assert.DoesNotContain(HootMcpTools.Specs, s => s.Id.Contains("answer") || s.Id.Contains("bypass"));
    Assert.Equal(McpTier.Alter, HootMcpTools.Specs.Single(s => s.Id == "hoot.handoff").Tier);
  }
}
