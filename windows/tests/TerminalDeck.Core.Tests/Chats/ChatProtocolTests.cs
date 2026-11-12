using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Tests.Chats;

[CollectionDefinition("Windows chat", DisableParallelization = true)]
public sealed class ChatTestCollection;

[Collection("Windows chat")]
public sealed class ChatProtocolTests
{
  private static ChatRecord Record(ChatFixture fixture, string provider) => fixture.Chat with { Definition = fixture.Chat.Definition with { Provider = provider } };
  [Fact] public async Task LargeImageEchoIsAcceptedWithoutInliningItIntoEvents()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    var encoded = Convert.ToBase64String(new byte[7 * 1024 * 1024]); var client = Guid.NewGuid().ToString();
    var line = JsonSerializer.Serialize(new { type = "user", uuid = client, message = new { content = new[] { new { type = "image", source = new { type = "base64", media_type = "image/png", data = encoded } } } } });
    var lines = new List<string>(); await foreach (var received in ChatCliConnection.Lines(new StringReader(line + "\n"), default)) lines.Add(received);
    var accepted = Assert.Single(protocol.Receive(Assert.Single(lines)).Signals); Assert.Equal("accepted", accepted.Kind); Assert.Equal(client, accepted.ClientId); Assert.Null(accepted.Data);
  }
  [Fact] public async Task MessageImageBudgetIsCheckedBeforeStartingTheCli()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var id = f.Chat.Definition.Id;
    var first = await f.Chats.AddImageAsync(id, "first.png", "image/png", new byte[5 * 1024 * 1024], 1, 1);
    var second = await f.Chats.AddImageAsync(id, "second.png", "image/png", new byte[5 * 1024 * 1024], 1, 1);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Chats.SendAsync(id, Guid.NewGuid().ToString(), "look", [first, second])); Assert.Equal(0, f.Keeper.Starts); Assert.Empty(f.Chats.Get(id).Messages);
  }
  [Fact] public async Task ANewCliCannotAnswerAnOldApprovalEvenWhenTheProviderReusesItsId()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var file = Path.Combine(f.Root.DirectoryPath, "approval-fixture.py");
    File.WriteAllText(file, """
      import sys,json
      json.loads(sys.stdin.readline())
      print(json.dumps({'type':'control_request','request_id':'same','request':{'subtype':'can_use_tool','tool_name':'Synthetic','input':{}}}),flush=True)
      reply=json.loads(sys.stdin.readline())
      text='correct' if reply['response']['request_id']=='same' else 'wrong'
      print(json.dumps({'type':'assistant','message':{'id':'assistant','content':[{'type':'text','text':text}]}}),flush=True)
      print(json.dumps({'type':'result','subtype':'success','is_error':False}),flush=True)
      """);
    var ids = new List<string>();
    for (var turn = 0; turn < 2; turn++)
    {
      var question = new TaskCompletionSource<ChatSignal>(TaskCreationOptions.RunContinuationsAsynchronously); var signals = new System.Collections.Concurrent.ConcurrentQueue<ChatSignal>();
      var launch = new TerminalDeck.Core.Platform.ProcessLaunch("/usr/bin/python3", ["-u", file], new Dictionary<string, string> { ["PATH"] = "/usr/bin:/bin" }, f.Root.DirectoryPath);
      await using var cli = new ChatCliConnection(f.Chat, f.History, launch, signal => { signals.Enqueue(signal); if (signal.Kind == "approval") question.TrySetResult(signal); return ValueTask.CompletedTask; });
      await cli.StartAsync(); await cli.SendAsync(new(Guid.NewGuid().ToString(), "approval", [])); var approval = await question.Task.WaitAsync(TimeSpan.FromSeconds(5));
      if (ids.Count > 0) await Assert.ThrowsAsync<InvalidOperationException>(async () => await cli.AnswerAsync(ids[0], true, approval.Data!.Value));
      ids.Add(approval.Id); await cli.AnswerAsync(approval.Id, true, approval.Data!.Value); await cli.Completion.WaitAsync(TimeSpan.FromSeconds(5));
      Assert.Equal("correct", signals.Single(signal => signal.Kind == "message").Text);
    }
    Assert.Equal(2, ids.Distinct().Count());
  }
  [Fact] public async Task ReusedExecItemIdsRemainSeparateAcrossTurns()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var file = Path.Combine(f.Root.DirectoryPath, "exec-fixture.py");
    // The fake answers with the person's words only: the prompt's last part (8 Nov, S3: the first turn
    // also carries the app's one-time drawing instruction before them).
    File.WriteAllText(file, "import sys,json\ntext=sys.stdin.read().split('\\n\\n')[-1]\nprint(json.dumps({'type':'item.completed','item':{'type':'agent_message','id':'item_0','text':text}}),flush=True)\nprint(json.dumps({'type':'turn.completed'}),flush=True)\n");
    var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "codex" } }; var events = new List<ChatEvent>();
    foreach (var text in new[] { "first", "second" })
    {
      var signals = new System.Collections.Concurrent.ConcurrentQueue<ChatSignal>();
      var launch = new TerminalDeck.Core.Platform.ProcessLaunch("/usr/bin/python3", ["-u", file], new Dictionary<string, string> { ["PATH"] = "/usr/bin:/bin" }, f.Root.DirectoryPath);
      await using var cli = new ChatCliConnection(chat, f.History, launch, signal => { signals.Enqueue(signal); return ValueTask.CompletedTask; });
      await cli.StartAsync(); await cli.SendExecAsync(new(Guid.NewGuid().ToString(), text, [])); await cli.Completion.WaitAsync(TimeSpan.FromSeconds(5));
      foreach (var signal in signals) events.Add(new(events.Count + 1, signal.Kind, signal.Id, signal.Text, signal.ClientId));
    }
    var rows = ChatProjection.Rows(chat with { Events = events.ToArray() }); Assert.Equal(new[] { "first", "second" }, rows.Where(r => r.Kind == "assistant").Select(r => r.Text));
  }
  // 9 Nov (Mac: "Working · 1 running" for two days in an idle chat). Windows records no background tasks at all, so a
  // task the AI never reports finished cannot keep a chat working: the turn's own result ends Busy.
  [Fact] public async Task ABackgroundTaskWithoutAFinishNeverKeepsTheChatWorking()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    Assert.DoesNotContain(protocol.Receive("""{"type":"system","subtype":"task_started","task_id":"bg-1","tool_use_id":"tool-bg","description":"sleep","task_type":"local_bash"}""").Signals,
      s => s.Kind is not "conversation");
    Assert.DoesNotContain(protocol.Receive("""{"type":"system","subtype":"task_progress","task_id":"bg-1","description":"sleep"}""").Signals, s => s.Kind is not "conversation");
    Assert.Contains(protocol.Receive("""{"type":"result","subtype":"success","is_error":false}""").Signals, s => s.Kind == "complete");
  }
  [Fact] public async Task GeminiResumeDoesNotReplayOldTextOrApproveBeforeItIsReady()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(Record(f, "gemini") with { ConversationId = "exact" }, f.History);
    protocol.Receive("""{"id":"hello","result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}""");
    Assert.Empty(protocol.Receive("""{"method":"session/update","params":{"sessionId":"exact","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"old history"}}}}""").Signals);
    var early = protocol.Receive("""{"id":1,"method":"session/request_permission","params":{"sessionId":"exact","options":[]}}"""); Assert.Empty(early.Signals); Assert.Single(early.Writes);
    Assert.True(protocol.Receive("""{"id":"session","result":{}}""").Ready);
  }
  [Fact] public async Task ApprovalKeepsExactLargeInputWhileItsEventUsesMediaFiles()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History); var encoded = Convert.ToBase64String(new byte[10_000]);
    var line = JsonSerializer.Serialize(new { type = "control_request", request_id = "large", request = new { subtype = "can_use_tool", tool_name = "SyntheticImage", input = new { type = "image", mimeType = "image/png", data = encoded } } });
    var approval = Assert.Single(protocol.Receive(line).Signals); Assert.DoesNotContain(encoded, approval.Data!.Value.GetRawText());
    using var answer = JsonDocument.Parse(protocol.Answer("large", true, approval.Data.Value));
    Assert.Equal(encoded, answer.RootElement.GetProperty("response").GetProperty("response").GetProperty("updatedInput").GetProperty("data").GetString());
  }
  [Fact] public async Task ClaudeApprovalsRetainExactInputAndTransientImagesStayOutOfHistory()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    var update = protocol.Receive("{\"type\":\"control_request\",\"request_id\":\"r\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Write\",\"input\":{\"content\":\"synthetic\"}}}");
    var approval = Assert.Single(update.Signals);
    using var response = JsonDocument.Parse(protocol.Answer("r", true, approval.Data!.Value));
    Assert.Equal("synthetic", response.RootElement.GetProperty("response").GetProperty("response").GetProperty("updatedInput").GetProperty("content").GetString());
    var image = await f.History.AddImageAsync(f.Chat.Definition.Id, "image.png", "image/png", new byte[] { 1, 2, 3, 4 }, 1, 1, default);
    var message = new ChatMessage(Guid.NewGuid().ToString(), "look", [image]);
    f.History.Save(f.Chat with { Messages = [message] });
    Assert.Contains("AQIDBA==", protocol.User(message));
    var json = File.ReadAllText(Path.Combine(f.Root.DirectoryPath, "chats", Guid.Parse(f.Chat.Definition.Id).ToString("N"), "chat.json"));
    Assert.DoesNotContain("AQIDBA==", json); Assert.Contains("media/", json); Assert.Equal(new byte[] { 1, 2, 3, 4 }, f.History.ReadMedia(f.Chat.Definition.Id, image));
    Assert.Throws<ArgumentException>(() => { _ = f.History.ReadMedia(f.Chat.Definition.Id, image with { RelativePath = "../../outside" }); });
  }
  [Fact] public async Task CodexAppServerHandshakeResumeStreamingAndScopedApprovals()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var record = Record(f, "codex") with { ConversationId = "thread-exact" };
    var protocol = new ChatLineProtocol(record, f.History, true); Assert.Contains("initialize", protocol.Begin());
    var initialize = protocol.Receive("{\"id\":\"hello\",\"result\":{}}"); Assert.Contains("thread/resume", initialize.Writes.Last()); Assert.Contains("thread-exact", initialize.Writes.Last());
    Assert.True(protocol.Receive("{\"id\":\"session\",\"result\":{\"thread\":{\"id\":\"thread-exact\"}}}").Ready);
    var client = Guid.NewGuid().ToString(); Assert.Contains("turn/start", protocol.User(new(client, "hello", [])));
    protocol.Receive("{\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-exact\",\"turn\":{\"id\":\"turn-1\"}}}");
    Assert.Contains("turn-1", protocol.Interrupt());
    var delta = protocol.Receive("{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-exact\",\"itemId\":\"m\",\"delta\":\"hello\"}}"); Assert.Equal("hello", Assert.Single(delta.Signals).Text);
    Assert.Empty(protocol.Receive("{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"other\",\"delta\":\"private\"}}").Signals);
    var request = protocol.Receive("{\"id\":7,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-exact\",\"command\":\"synthetic\"}}");
    var approval = Assert.Single(request.Signals); Assert.Equal("7", approval.Id);
    using var answer = JsonDocument.Parse(protocol.Answer(approval.Id, false, approval.Data!.Value)); Assert.Equal(7, answer.RootElement.GetProperty("id").GetInt32()); Assert.Equal("decline", answer.RootElement.GetProperty("result").GetProperty("decision").GetString());
    Assert.Throws<IOException>(() => new ChatLineProtocol(record, f.History, true).Receive("{\"id\":\"session\",\"result\":{\"thread\":{\"id\":\"wrong\"}}}"));
  }
  [Fact] public async Task CodexExecNormalizesToolsResultsAndAuthenticationFailures()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(Record(f, "codex"), f.History);
    Assert.Null(protocol.Begin()); Assert.Equal("conversation", Assert.Single(protocol.Receive("{\"type\":\"thread.started\",\"thread_id\":\"thread\"}").Signals).Kind);
    Assert.Equal("toolCall", Assert.Single(protocol.Receive("{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\",\"id\":\"t\",\"command\":\"synthetic\"}}").Signals).Kind);
    Assert.Equal("toolResult", Assert.Single(protocol.Receive("{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"id\":\"t\",\"aggregated_output\":\"done\"}}").Signals).Kind);
    Assert.Equal(ChatErrors.NotSignedIn("codex"), Assert.Single(protocol.Receive("{\"type\":\"error\",\"message\":\"Not logged in; synthetic-private-token\"}").Signals).Text);
  }
  [Fact] public async Task GeminiNegotiatesCapabilitiesResumesExactlyAndChoosesOnlyOneUseApproval()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(Record(f, "gemini") with { ConversationId = "exact" }, f.History);
    var hello = protocol.Receive("{\"id\":\"hello\",\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true,\"promptCapabilities\":{\"image\":true}}}}");
    Assert.Contains("session/load", Assert.Single(hello.Writes)); Assert.True(protocol.Receive("{\"id\":\"session\",\"result\":{}}").Ready);
    var messageId = Guid.NewGuid().ToString(); Assert.Contains("session/prompt", protocol.User(new(messageId, "hello", [])));
    var request = protocol.Receive("{\"id\":\"1\",\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"exact\",\"toolCall\":{\"title\":\"Write\"},\"options\":[{\"kind\":\"allow_always\",\"optionId\":\"always\"},{\"kind\":\"allow_once\",\"optionId\":\"once\"}]}}");
    var approval = Assert.Single(request.Signals); Assert.Equal("\"1\"", approval.Id);
    using var answer = JsonDocument.Parse(protocol.Answer(approval.Id, true, approval.Data!.Value));
    Assert.Equal("once", answer.RootElement.GetProperty("result").GetProperty("outcome").GetProperty("optionId").GetString());
    Assert.Contains("cancelled", protocol.Answer(approval.Id, false, approval.Data.Value));
    Assert.Throws<IOException>(() => new ChatLineProtocol(Record(f, "gemini") with { ConversationId = "exact" }, f.History).Receive("{\"id\":\"hello\",\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{}}}"));
  }
  [Fact] public async Task NonJsonDiagnosticsAreIgnoredAndRawErrorDetailsAreNeverDisplayed()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    Assert.Empty(protocol.Receive("synthetic-private-diagnostic").Signals);
    var signals = protocol.Receive("{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"errors\":[\"synthetic-private-value\"]}").Signals;
    Assert.Equal("The coding AI could not answer. Retry when you’re ready.", Assert.Single(signals).Text);
  }
  [Fact] public async Task UsageLimitSaysSoPlainlyWithItsResetTime()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    var row = "{\"type\":\"assistant\",\"is_api_error_message\":true,\"message\":{\"id\":\"m1\",\"model\":\"<synthetic>\",\"content\":[{\"type\":\"text\",\"text\":\"You've hit your weekly limit · resets 2pm (Asia/Dubai)\"}]}}";
    var error = Assert.Single(protocol.Receive(row).Signals, s => s.Kind == "error");
    Assert.Equal("This account has reached its weekly limit — resets 2pm (Asia/Dubai). Switch account?", error.Text); Assert.True(ChatErrors.IsUsageLimit(error.Text));
    Assert.Equal("This account has reached its session limit (5 hours) — resets 10:10am (Asia/Dubai). Switch account?", ChatErrors.FromProvider("claude", "You've hit your session limit · resets 10:10am (Asia/Dubai)"));
    Assert.Equal("This account has reached its usage limit — resets 3:05 PM. Switch account?", ChatErrors.FromProvider("codex", "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM."));
    Assert.Equal("This account has reached its usage limit. Switch account?", ChatErrors.FromProvider("gemini", "RESOURCE_EXHAUSTED: Quota exceeded"));
    Assert.Equal(ChatErrors.NotSignedIn("claude"), ChatErrors.FromProvider("claude", "Not logged in · Please run /login"));
  }
}
