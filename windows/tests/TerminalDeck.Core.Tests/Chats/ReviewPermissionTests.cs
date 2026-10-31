using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class ReviewPermissionTests
{
  [Theory]
  [InlineData(AiPermissionMode.Ask, "on-request", "workspace-write")]
  [InlineData(AiPermissionMode.Plan, "never", "read-only")]
  [InlineData(AiPermissionMode.Bypass, "never", "danger-full-access")]
  public async Task CodexStartsAndResumesWithTheSavedOwnerMode(AiPermissionMode mode, string approval, string sandbox)
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    foreach (var conversation in new string?[] { null, "saved-thread" })
    {
      var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "codex", PermissionMode = mode }, ConversationId = conversation };
      var protocol = new ChatLineProtocol(chat, f.History, true);
      var update = protocol.Receive("""{"id":"hello","result":{}}""");
      using var wire = JsonDocument.Parse(update.Writes.Last()); var args = wire.RootElement.GetProperty("params");
      Assert.Equal(approval, args.GetProperty("approvalPolicy").GetString()); Assert.Equal(sandbox, args.GetProperty("sandbox").GetString());
      Assert.Equal(conversation is null ? "thread/start" : "thread/resume", wire.RootElement.GetProperty("method").GetString());
    }
  }

  [Theory]
  [InlineData(AiPermissionMode.Ask, "default")]
  [InlineData(AiPermissionMode.Plan, "plan")]
  [InlineData(AiPermissionMode.AcceptEdits, "auto_edit")]
  [InlineData(AiPermissionMode.Bypass, "yolo")]
  public async Task GeminiWaitsForItsAdvertisedModeBeforeModelAndMessages(AiPermissionMode mode, string nativeMode)
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "gemini", PermissionMode = mode, Options = new("fixture") } };
    var protocol = new ChatLineProtocol(chat, f.History);
    protocol.Receive("""{"id":"hello","result":{"protocolVersion":1,"agentCapabilities":{}}}""");
    var offered = protocol.Receive(JsonSerializer.Serialize(new { id = "session", result = new { sessionId = "gemini-session", modes = new { availableModes = new[] { new { id = nativeMode } } } } }));
    Assert.False(offered.Ready); using var request = JsonDocument.Parse(Assert.Single(offered.Writes));
    Assert.Equal("session/set_mode", request.RootElement.GetProperty("method").GetString()); Assert.Equal(nativeMode, request.RootElement.GetProperty("params").GetProperty("modeId").GetString());
    var modeAck = protocol.Receive("""{"id":"permission-mode","result":{}}"""); Assert.False(modeAck.Ready);
    Assert.Contains("session/set_model", Assert.Single(modeAck.Writes));
    Assert.True(protocol.Receive("""{"id":"model","result":{}}""").Ready);
  }

  [Theory]
  [InlineData(AiPermissionMode.Plan)]
  [InlineData(AiPermissionMode.Bypass)]
  public async Task MissingGeminiModeNeverFallsBackToDefault(AiPermissionMode mode)
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var chat = f.Chat with { Definition = f.Chat.Definition with { Provider = "gemini", PermissionMode = mode } };
    var protocol = new ChatLineProtocol(chat, f.History);
    Assert.Throws<IOException>(() => protocol.Receive("""{"id":"session","result":{"sessionId":"new","modes":{"availableModes":[{"id":"default"}]}}}"""));
  }

  [Fact]
  public async Task PlanCannotApproveAProviderWriteRequest()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var protocol = new ChatLineProtocol(f.Chat with { Definition = f.Chat.Definition with { PermissionMode = AiPermissionMode.Plan } }, f.History);
    var approval = Assert.Single(protocol.Receive("""{"type":"control_request","request_id":"write","request":{"subtype":"can_use_tool","tool_name":"Write","input":{}}}""").Signals);
    Assert.Throws<InvalidOperationException>(() => protocol.Answer(approval.Id, true, approval.Data!.Value));
    Assert.Contains("deny", protocol.Answer(approval.Id, false, approval.Data!.Value));
  }
}
