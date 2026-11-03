using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class W12ChatTests
{
  [Fact] public async Task ProviderThinkingTextStaysSeparateFromTheAssistantAnswerAndSignature()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    protocol.User(new(Guid.NewGuid().ToString(), "a prompt", [])); protocol.Receive("""{"type":"stream_event","event":{"type":"message_start","message":{"id":"message"}}}""");
    var update = protocol.Receive("""{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reported thought","signature":"not-visible"}}}""");
    var thought = Assert.Single(update.Signals); Assert.Equal("reasoningDelta", thought.Kind); Assert.Equal("reported thought", thought.Text); Assert.Null(thought.Data); Assert.Empty(update.Writes);
  }
  [Fact] public void CodexChangesWithoutAskingKeepsWorkspaceSandboxSeparateFromBypass()
  {
    Assert.Contains(AiPermissionMode.AcceptEdits, ChatPermissionModes.Supported("codex")); Assert.Equal("never", ChatPermissionModes.CodexApproval(AiPermissionMode.AcceptEdits)); Assert.Equal("workspace-write", ChatPermissionModes.CodexSandbox(AiPermissionMode.AcceptEdits)); Assert.Equal("danger-full-access", ChatPermissionModes.CodexSandbox(AiPermissionMode.Bypass));
  }
  [Fact] public async Task IdlePermissionChangeRetiresOnlyItsWorkerAndKeepsTheRecordedConversation()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "a prompt"); await ChatFixture.UntilAsync(() => !f.Chats.Get(id).Busy);
    var before = f.Chats.Get(id); await f.Chats.SetPermissionAsync(id, AiPermissionMode.Plan); var after = f.Chats.Get(id);
    Assert.Equal(before.ConversationId, after.ConversationId); Assert.NotEqual(before.CreationKey, after.CreationKey); Assert.Equal(before.Messages, after.Messages); Assert.Equal(1, f.Keeper.Starts);
  }
  [Fact] public async Task ContextUsesCurrentWorkerReadingsAndKeepsCumulativeTotalsOutOfTheWindow()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var data = JsonSerializer.SerializeToElement(new { creationKey = f.Chat.CreationKey, usage = new { modelContextWindow = 1000, last = new { totalTokens = 250 }, total = new { totalTokens = 50000 } } });
    var chat = f.Chat with { Events = [new(1, "usage", "turn", Data: data), new(2, "compaction", "one")] };
    var report = ChatContext.Read(chat); Assert.Equal(250, report.Tokens); Assert.Equal(750, report.Remaining); Assert.Equal(25, report.Percent); Assert.Equal(1, report.RecordedCompactions);
    Assert.Null(ChatContext.Read(chat with { CreationKey = "new worker" }).Tokens); Assert.Equal(250, ChatContext.Read(chat with { CreationKey = "new worker" }).PeakRecordedTokens);
  }
  [Fact] public async Task SideQuestionBriefKeepsMainDraftAndRefusesAChangedQuestionOrConversation()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var buffer = new ChatDraftBuffer(); buffer.Edit("UNSENT-MAIN-DRAFT"); var original = buffer.Read();
    var chat = f.Chat with { Events = [new(1, "user", "source-1", "recorded prompt"), new(2, "message", "source-2", "recorded reply")], Messages = [new("queue", "UNSENT-QUEUE", [])] };
    var side = buffer.SideQuestion; side.SetQuestion("What about this case?"); var prepared = side.Prepare(chat);
    Assert.Contains("recorded prompt", prepared.Text); Assert.DoesNotContain("UNSENT-MAIN-DRAFT", prepared.Text); Assert.DoesNotContain("UNSENT-QUEUE", prepared.Text); Assert.Equal(2, prepared.Sources.Length); Assert.Equal(original, buffer.Read());
    side.SetQuestion("Changed question"); Assert.Throws<InvalidOperationException>(() => side.ForCopy(chat)); Assert.Throws<InvalidOperationException>(() => side.EditBrief("stale", prepared.TextRevision));
    var next = side.Prepare(chat); side.EditBrief("my edited brief", next.TextRevision); Assert.Equal("my edited brief", side.ForCopy(chat));
    Assert.Throws<InvalidOperationException>(() => side.ForCopy(chat with { ConversationId = "another conversation" })); Assert.Equal(original, buffer.Read()); Assert.Equal(0, f.Keeper.Starts);
  }
  [Fact] public async Task ToolFailuresUseReportedStatusAndActualExitCode()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var chat = f.Chat with { Events = [new(1, "toolResult", "command", "command output", Data: JsonSerializer.SerializeToElement(new { type = "commandExecution", command = "check", exitCode = 2 })), new(2, "toolResult", "files", "refused", Data: JsonSerializer.SerializeToElement(new { type = "fileChange", status = "failed" }))] };
    var rows = ChatProjection.Rows(chat); Assert.All(rows, row => Assert.Equal("Failed", row.Status)); Assert.Equal("check", rows[0].Text); Assert.Equal("Update files", rows[1].Text);
  }
  [Fact] public async Task ProviderReadingsAreWhitelistedAndNeverClaimAnOldWorkerAsCurrent()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var source = JsonSerializer.SerializeToElement(new { model = "reported-model", permissionMode = "plan", api_key = "not-for-events", mcp_servers = new[] { new { name = "sample", status = "connected", token = "not-for-events" } } });
    var data = ChatProviderSnapshot.Capture("claude", f.Chat.CreationKey, source); Assert.DoesNotContain("not-for-events", data.GetRawText());
    var chat = f.Chat with { Events = [new(1, "providerInit", "provider", Data: data)] };
    Assert.Equal("reported-model", ChatProviderSnapshot.Read(chat).Model); Assert.Equal("plan", ChatProviderSnapshot.Describe(ChatProviderSnapshot.Read(chat), "permissionMode"));
    var updated = chat with { Events = [.. chat.Events, new(2, "requestUsage", "request", Data: JsonSerializer.SerializeToElement(new { creationKey = chat.CreationKey, model = "actual-request-model" }))] };
    Assert.Equal("actual-request-model", ChatProviderSnapshot.Read(updated).Model);
    var changed = updated with { CreationKey = "another-worker" }; Assert.False(ChatProviderSnapshot.Read(changed).Current); Assert.Null(ChatProviderSnapshot.Read(changed).Model); Assert.Equal("Not reported", ChatProviderSnapshot.Describe(ChatProviderSnapshot.Read(changed), "permissionMode"));
  }
  [Fact] public async Task CodexSessionReplyRetainsOnlyProviderConfirmedValues()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "codex" } };
    var protocol = new ChatLineProtocol(chat, f.History, codexAppServer: true);
    protocol.Receive("""{"id":"hello","result":{}}""");
    var reply = protocol.Receive("""{"id":"session","result":{"thread":{"id":"thread"},"model":"actual-model","approvalPolicy":"on-request"}}""");
    var snapshot = Assert.Single(reply.Signals, s => s.Kind == "providerInit");
    Assert.Equal("actual-model", ChatProviderSnapshot.Read(chat with { Events = [new(1, snapshot.Kind, snapshot.Id, Data: snapshot.Data)] }).Model);
  }
  [Fact] public async Task PrivateEditorCopyImportsOnlyIntoItsUnchangedSourceAndDeletesOnlyItsCopy()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var buffer = new ChatDraftBuffer(); buffer.Edit("original draft");
    var copies = new ChatDraftEditorCopies(f.Root); var copy = copies.Prepare(f.Chat, buffer); Assert.Equal("original draft", File.ReadAllText(copy.Path));
    File.WriteAllText(copy.Path, "saved editor text"); buffer.Edit("newer draft");
    Assert.Throws<InvalidOperationException>(() => copies.Import(f.Chat, buffer)); Assert.Equal("newer draft", buffer.Read().Text); Assert.True(File.Exists(copy.Path));
    copies.Discard(buffer); Assert.Equal("newer draft", buffer.Read().Text); Assert.False(File.Exists(copy.Path));
    copy = copies.Prepare(f.Chat, buffer, "unapplied full editor text", new(buffer.Read().Revision, f.Chat.ConversationId)); Assert.Equal("unapplied full editor text", File.ReadAllText(copy.Path)); File.WriteAllText(copy.Path, "saved editor text");
    Assert.Throws<InvalidOperationException>(() => copies.Import(f.Chat with { ConversationId = "another conversation" }, buffer));
    var imported = copies.Import(f.Chat, buffer); Assert.Equal("saved editor text", imported.Text); Assert.Empty(f.Chats.Get(f.Chat.Definition.Id).Messages);
    File.WriteAllText(copy.Path, new string('a', 262145)); Assert.Throws<ArgumentException>(() => copies.Import(f.Chat, buffer)); Assert.Equal("saved editor text", buffer.Read().Text);
    copies.Discard(buffer); Assert.True(File.Exists(Path.Combine(f.Root.DirectoryPath, "chats", Guid.Parse(f.Chat.Definition.Id).ToString("N"), "chat.json")));
  }
  [Fact] public async Task InspectorReplacesRepeatedCumulativeUsageInsteadOfCountingEachJsonLine()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var start = DateTimeOffset.UtcNow;
    var first = JsonSerializer.SerializeToElement(new { model = "reported-model", usage = new { input_tokens = 10, cache_creation_input_tokens = 2, cache_read_input_tokens = 20, output_tokens = 1 } });
    var last = JsonSerializer.SerializeToElement(new { usage = new { output_tokens = 5 } });
    var chat = f.Chat with { Events = [new(1, "requestStarted", "request", Data: first, At: start), new(2, "requestUsage", "request", Data: last, At: start.AddSeconds(2)), new(3, "requestUsage", "request", Data: last, At: start.AddSeconds(3)), new(4, "usage", "turn-total", Data: JsonSerializer.SerializeToElement(new { usage = new { output_tokens = 5 } }))] };
    var report = ChatInspector.Read(chat); Assert.Single(report.Requests); Assert.Equal(10, report.FreshInput); Assert.Equal(5, report.Output); Assert.Equal(2, report.CacheWrite); Assert.Equal(20, report.CacheRead); Assert.Equal(1, report.ProviderTurnReports);
    Assert.Equal("reported-model", report.Requests[0].Model); Assert.Equal(3, (report.Requests[0].LastAt - report.Requests[0].FirstAt).TotalSeconds);
    Assert.Null(ChatInspector.Read(f.Chat).Output);
  }
  [Fact] public async Task RetryWithMissingOriginalFilesDoesNotStartAWorkerOrQueueADuplicate()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false); var id = f.Chat.Definition.Id;
    var image = await f.Chats.AddImageAsync(id, "original.png", "image/png", new byte[] { 1, 2, 3 }, 1, 1);
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "look at the original", [image]);
    var before = f.Chats.Get(id); Assert.Single(before.Messages); Assert.Equal(ChatMessageState.Failed, before.Messages[0].State);
    File.Delete(Path.Combine(f.Root.DirectoryPath, "chats", Guid.Parse(id).ToString("N"), image.RelativePath));
    await f.Chats.RetryAsync(id); var after = f.Chats.Get(id);
    Assert.Single(after.Messages); Assert.Equal(before.Messages[0].ClientId, after.Messages[0].ClientId); Assert.Equal(ChatErrors.OriginalFilesNeeded, after.Problem); Assert.Equal(0, f.Keeper.Starts);
    await Assert.ThrowsAsync<ChatFilesNeededException>(async () => await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "new attempt", [image]));
    Assert.Single(f.Chats.Get(id).Messages);
  }
  [Fact] public async Task RecordedChangesKeepActualDiffCountsAndSourceWithoutReadingProjectFiles()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var chat = f.Chat with { Events = [new(1, "toolResult", "change", Data: JsonSerializer.SerializeToElement(new { type = "fileChange", changes = new[] { new { path = "file.cs", diff = "--- a/file.cs\n+++ b/file.cs\n-old\n+new\n+another" } } }))] };
    var change = Assert.Single(ChatRecordedChanges.Read(chat)); Assert.Equal("file.cs", change.Path); Assert.Equal(2, change.Added); Assert.Equal(1, change.Deleted); Assert.Equal(1, change.SourceSequence);
    var failed = chat with { Events = [new(1, "toolResult", "failed", Data: JsonSerializer.SerializeToElement(new { is_error = true, changes = new[] { new { path = "not-written" } } }))] };
    Assert.Empty(ChatRecordedChanges.Read(failed));
  }
  [Fact] public async Task RenameKeepsTheConversationWorkerAndCustomTitleOnTheFirstSend()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id; var lease = f.Chat.CreationKey;
    await f.Chats.RenameAsync(id, "My named session");
    Assert.Equal(lease, f.Chats.Get(id).CreationKey); Assert.Equal(0, f.Keeper.Starts);
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "hold"); await f.Chats.RenameAsync(id, "Renamed while working");
    Assert.Equal("Renamed while working", f.Chats.Get(id).Definition.Title); Assert.True(f.Chats.Get(id).Busy); Assert.Equal(lease, f.Chats.Get(id).CreationKey); Assert.Equal(1, f.Keeper.Starts);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Chats.RenameAsync(id, new string('a', 41)));
  }
  [Fact] public async Task AChatFollowsItsAccountWhenSigningInAgainMovedTheLogin()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id; var oldHome = f.Chat.Definition.AccountHome;
    // Sign in again in a new login folder with the same email: the account row now owns that folder.
    var again = await f.Accounts.CreateAsync("claude", "Again");
    f.Provider.Statuses[again.Id] = new(true, "synthetic@example.test"); await f.Accounts.RefreshAsync(again.Id);
    var moved = f.Accounts.Get(f.Account.Id); Assert.NotEqual(oldHome, moved.HomeId);
    await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "hello");
    Assert.Equal(moved.HomeId, f.Chats.Get(id).Definition.AccountHome); Assert.Equal(f.Account.Id, f.Chats.Get(id).Definition.AccountId);
  }
  [Fact] public async Task ANameGivenInNewSessionIsKeptOnTheFirstSend()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var named = await f.Chats.CreateAsync(f.Chat.Definition with { Id = Guid.NewGuid().ToString(), Title = "Umer round chat check" }, customTitle: true);
    await f.Chats.SendAsync(named.Definition.Id, Guid.NewGuid().ToString(), "Reply with PONG");
    Assert.Equal("Umer round chat check", f.Chats.Get(named.Definition.Id).Definition.Title);
  }
  [Fact] public void DraftCompareAndApplyRejectsStaleAndOversizeChangesWithoutLosingText()
  {
    var buffer = new ChatDraftBuffer(); buffer.Edit("unsent draft"); var before = buffer.Read();
    var updated = buffer.Apply(" changed", before.Revision, true); Assert.Equal("unsent draft changed", updated.Text);
    Assert.Throws<InvalidOperationException>(() => buffer.Apply("stale editor", before.Revision));
    Assert.Throws<ArgumentException>(() => buffer.Apply(new string('a', 262145), updated.Revision));
    Assert.Equal(updated, buffer.Read());
    string? control = null; buffer.ControlRequested += name => control = name; buffer.OpenControl("model"); Assert.Equal("model", control);
  }
  [Fact] public async Task CompletedToolKeepsItsInputOutputAndFailureAcrossDuplicateFinalCall()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var data = JsonSerializer.SerializeToElement(new { path = "sample.txt" });
    var chat = f.Chat with { Events = [new(1, "toolCall", "tool", "Write", Data: JsonSerializer.SerializeToElement(new { })), new(2, "toolInputDelta", "tool", data.GetRawText()), new(3, "toolResult", "tool", "Permission denied", Data: JsonSerializer.SerializeToElement(new { is_error = true })), new(4, "toolCall", "tool", "Write", Data: data)] };
    var row = Assert.Single(ChatProjection.Rows(chat)); Assert.False(row.Waiting); Assert.Equal("Failed", row.Status);
    Assert.Contains("sample.txt", row.Input); Assert.Equal("Permission denied", row.Output); Assert.Contains("Input", row.Details); Assert.Contains("Output", row.Details);
  }
  [Fact] public async Task UsageSignalRetainsProviderFiguresWithoutChangingAnAnswer()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    protocol.User(new(Guid.NewGuid().ToString(), "hello", []));
    var signals = protocol.Receive("""{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":12,"output_tokens":34},"total_cost_usd":0.002}""").Signals;
    var usage = Assert.Single(signals, s => s.Kind == "usage"); Assert.Equal(12, usage.Data!.Value.GetProperty("usage").GetProperty("input_tokens").GetInt32()); Assert.Contains(signals, s => s.Kind == "complete");
    Assert.DoesNotContain(signals, s => s.Kind == "message");
  }
  [Fact] public void ApprovalPreviewUsesOnlyReportedTextAndMarksMissingOrTruncatedBefore()
  {
    var replacement = ChatApprovalPreview.Read(JsonSerializer.Serialize(new { input = new { file_path = "sample.txt", old_string = "before", new_string = "after" } }));
    Assert.Equal("sample.txt", replacement.Path); Assert.Equal("before", replacement.Before); Assert.Equal("after", replacement.After);
    var write = ChatApprovalPreview.Read(JsonSerializer.Serialize(new { input = new { content = new string('a', 20001) } }));
    Assert.Null(write.Before); Assert.True(write.Truncated); Assert.Equal(20000, write.After?.Length);
    Assert.False(ChatApprovalPreview.Read("not json").HasPreview);
  }
  [Fact] public void PromptLimitCountsUtf8AndNeverTruncates()
  {
    ChatText.ValidatePrompt(new string('a', 262144));
    ChatText.ValidatePrompt(string.Concat(Enumerable.Repeat("😀", 65536)));
    Assert.Throws<ArgumentException>(() => ChatText.ValidatePrompt(new string('a', 262145)));
    Assert.Throws<ArgumentException>(() => ChatText.ValidatePrompt(string.Concat(Enumerable.Repeat("😀", 65537))));
    Assert.Throws<ArgumentException>(() => ChatText.ValidatePrompt("null\0character"));
  }
  [Fact] public void RecallKeepsCurrentDraftAndInvalidatesAnEditedRecall()
  {
    var recall = new ChatPromptRecall();
    Assert.Null(recall.Move(false, "unsent", ["first", "second"]));
    Assert.Equal("second", recall.Move(true, "unsent", ["first", "second"]));
    Assert.Equal("first", recall.Move(true, "second", ["first", "second", "arrived later"]));
    Assert.Null(recall.Move(true, "first", []));
    Assert.Equal("second", recall.Move(false, "first", []));
    Assert.Equal("unsent", recall.Move(false, "second", []));
    Assert.Equal("second", recall.Move(true, "new draft", ["first", "second"]));
    Assert.Null(recall.Move(false, "edited recall", ["first", "second"]));
    Assert.False(recall.IsRecalled("second"));
  }
  [Fact] public async Task SearchAndExportUseTheEntireRecordedHistoryAndOmitQueuedText()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var chat = f.Chat with { Events = [new(1, "user", "one", "Old MATCH match"), .. Enumerable.Range(2, 250).Select(i => new ChatEvent(i, "message", "answer" + i, "new answer"))], Messages = [new("queue", "unsent secret", [])] };
    var found = ChatText.Find(chat, "match"); Assert.Equal(2, found.Count); Assert.All(found, m => Assert.Equal("user:one", m.RowId));
    Assert.Single(ChatText.Prompts(chat));
    var exported = ChatText.Export(chat); Assert.Contains("Old MATCH match", exported); Assert.Contains("new answer", exported); Assert.DoesNotContain("unsent secret", exported);
  }
  [Fact] public void MarkdownRetainsCodeAndListsAndRefusesExecutableLinks()
  {
    var blocks = ChatMarkdown.Blocks("# Title\n\n- one\n2. two\n\n```csharp\nConsole.WriteLine(\"hello\");\n```\n\n[docs](https://example.test) and **bold** with `code`");
    Assert.Equal("heading", blocks[0].Kind); Assert.Equal(2, blocks.Count(b => b.Kind == "list"));
    var code = Assert.Single(blocks, b => b.Kind == "code"); Assert.Equal("csharp", code.Language); Assert.Equal("Console.WriteLine(\"hello\");", code.Text);
    var spans = ChatMarkdown.Spans(blocks.Last().Text); Assert.Contains(spans, s => s.Kind == "link" && s.Target == "https://example.test"); Assert.Contains(spans, s => s.Kind == "strong");
    Assert.False(ChatMarkdown.CanOpenLink("javascript:alert(1)")); Assert.False(ChatMarkdown.CanOpenLink("file:///C:/secret")); Assert.True(ChatMarkdown.CanOpenLink("https://example.test"));
    Assert.Equal("unfinished", Assert.Single(ChatMarkdown.Blocks("```\nunfinished")).Text);
  }
  [Fact] public async Task PermissionIsSavedAcrossRestartWithoutStartingAWorker()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    await f.Chats.SetPermissionAsync(f.Chat.Definition.Id, AiPermissionMode.Plan);
    Assert.Equal(0, f.Keeper.Starts); Assert.Equal(AiPermissionMode.Plan, f.Chats.Get(f.Chat.Definition.Id).Definition.PermissionMode);
    await f.RestartAsync(); Assert.Equal(AiPermissionMode.Plan, f.Chats.Get(f.Chat.Definition.Id).Definition.PermissionMode);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Chats.SetPermissionAsync(f.Chat.Definition.Id, (AiPermissionMode)999));
  }
  [Fact] public async Task PermissionCannotChangeWhileAnAnswerIsRunning()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    await f.Chats.SendAsync(f.Chat.Definition.Id, Guid.NewGuid().ToString(), "hold");
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Chats.SetPermissionAsync(f.Chat.Definition.Id, AiPermissionMode.Bypass));
    Assert.Equal(AiPermissionMode.Ask, f.Chats.Get(f.Chat.Definition.Id).Definition.PermissionMode);
  }
}
