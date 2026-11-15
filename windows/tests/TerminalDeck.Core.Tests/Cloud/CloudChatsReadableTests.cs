using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// Sessions in the Cloud (the Mac's CloudChatsReadableTests, case for case): the readable copy of a chat is the event
/// lines the phones already draw, one JSON event per line. Claude Code's and Codex's histories keep only what the person
/// wrote and what the AI answered; the app's own chats keep their own events, without the streamed pieces.
public sealed class CloudChatsReadableTests
{
  internal static JsonElement[] Events(byte[] lines) => Encoding.UTF8.GetString(lines).Split('\n', StringSplitOptions.RemoveEmptyEntries)
    .Select(l => JsonDocument.Parse(l).RootElement.Clone()).ToArray();
  private static string S(JsonElement e, string name) => e.GetProperty(name).GetString()!;
  private static string Text(JsonElement e) => e.GetProperty("value").GetProperty("text").GetString()!;

  [Fact] public void ClaudeThePersonsWordsAndTheAnswersToolTrafficRemindersAndSideChainsLeftOut()
  {
    var history = string.Join("\n",
      """{"type":"user","message":{"role":"user","content":"Fix the login page"},"uuid":"u1","timestamp":"2026-11-15T01:00:00.000Z","sessionId":"c1"}""",
      """{"type":"assistant","message":{"id":"m1","model":"claude-opus","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Looking at it now."},{"type":"tool_use","id":"t1","name":"Read","input":{}}]},"uuid":"a1","timestamp":"2026-11-15T01:00:01.000Z"}""",
      """{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file text"}]},"uuid":"r1"}""",
      """{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u2"}""",
      """{"type":"assistant","isSidechain":true,"message":{"id":"m2","model":"claude-opus","content":[{"type":"text","text":"helper"}]},"uuid":"a2"}""",
      """{"type":"assistant","message":{"id":"m3","model":"claude-opus","content":[{"type":"text","text":"Done: the button works."}]},"uuid":"a3","timestamp":"2026-11-15T01:00:09.000Z"}""") + "\n";
    var made = CloudChatsReadable.Read(Encoding.UTF8.GetBytes(history), CloudChatsReadable.Format.Claude, "c1", "claude", 1);
    Assert.Equal(Encoding.UTF8.GetByteCount(history), made.Consumed);
    var events = Events(made.Lines);
    Assert.Equal(["user", "message", "message"], events.Select(e => S(e, "kind")));
    Assert.Equal(["Fix the login page", "Looking at it now.", "Done: the button works."], events.Select(Text));
    Assert.Equal([1L, 2L, 3L], events.Select(e => e.GetProperty("sequence").GetInt64()));
    Assert.All(events, e => { Assert.Equal("c1", S(e, "conversationId")); Assert.Equal("claude", S(e, "provider")); });
    Assert.Equal(1_794_704_400_000, events[0].GetProperty("at").GetInt64());
  }

  [Fact] public void ALineStillBeingWrittenWaitsAHugeLineIsPassedOver()
  {
    var whole = """{"type":"user","message":{"role":"user","content":"one"},"uuid":"u1"}""" + "\n";
    var partial = """{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"tw""";
    var made = CloudChatsReadable.Read(Encoding.UTF8.GetBytes(whole + partial), CloudChatsReadable.Format.Claude, "c", "claude", 4);
    Assert.Equal(Encoding.UTF8.GetByteCount(whole), made.Consumed);
    Assert.Equal([4L], Events(made.Lines).Select(e => e.GetProperty("sequence").GetInt64()));
  }

  [Fact] public void CodexResponseItemMessagesOnlyItsContextAndToolCallsLeftOut()
  {
    var history = string.Join("\n",
      """{"timestamp":"2026-11-15T02:00:00.000Z","type":"session_meta","payload":{"id":"th1","cwd":"/tmp/p"}}""",
      """{"timestamp":"2026-11-15T02:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/tmp/p</cwd>\n</environment_context>"}]}}""",
      """{"timestamp":"2026-11-15T02:00:00.200Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}""",
      """{"timestamp":"2026-11-15T02:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a test"}]}}""",
      """{"timestamp":"2026-11-15T02:00:01.500Z","type":"event_msg","payload":{"type":"user_message","message":"Add a test"}}""",
      """{"timestamp":"2026-11-15T02:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}""",
      """{"timestamp":"2026-11-15T02:00:03.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}""",
      """{"timestamp":"2026-11-15T02:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_1","content":[{"type":"output_text","text":"Added one test."}]}}""") + "\n";
    var events = Events(CloudChatsReadable.Read(Encoding.UTF8.GetBytes(history), CloudChatsReadable.Format.Codex, "th1", "codex", 1).Lines);
    Assert.Equal(["user", "message"], events.Select(e => S(e, "kind")));
    Assert.Equal(["Add a test", "Added one test."], events.Select(Text));
    Assert.All(events, e => Assert.Equal("codex", S(e, "provider")));
    Assert.Equal("msg_1", S(events[1], "messageId"));
  }

  internal static ChatRecord Chat(string id, params ChatEvent[] events) => new(1,
    new ChatDefinition(id, "claude", @"C:\work\crm", "Plan", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new ChatOptions()),
    "key", events, [], Busy: true, ActiveClientId: "client-1");

  [Fact] public void TheAppsChatsTheirOwnEventsAsThePhonesGetThemStreamedPiecesLeftOut()
  {
    var at = DateTimeOffset.FromUnixTimeMilliseconds(1_763_168_400_000);
    var id = Guid.NewGuid().ToString();
    var file = JsonSerializer.SerializeToUtf8Bytes(Chat(id,
      new ChatEvent(1, "user", "u1", "Plan the release", At: at), new ChatEvent(2, "textDelta", "m1", "Pla", At: at),
      new ChatEvent(3, "message", "m1", "Here is the plan.", At: at), new ChatEvent(4, "reasoningDelta", "r1", "private", At: at)));
    var parsed = CloudChatsReadable.AppChat(file);
    Assert.NotNull(parsed);
    Assert.Equal(id, parsed.Value.Conversation);
    Assert.Equal([1L, 3L], parsed.Value.Events.Select(e => e.Sequence));
    var events = Events([.. parsed.Value.Events.SelectMany(e => e.Line)]);
    Assert.Equal(["user", "message"], events.Select(e => S(e, "kind")));
    Assert.Equal(["Plan the release", "Here is the plan."], events.Select(Text));
  }

  [Fact] public void GeminiThePersonsAndGeminisMessagesFromItsWholeFile()
  {
    var file = """{"sessionId":"g1","messages":[{"id":"1","timestamp":"2026-11-15T03:00:00.000Z","type":"user","content":"Hello"},{"id":"2","type":"info","content":"tool"},{"id":"3","timestamp":"2026-11-15T03:00:02.000Z","type":"gemini","content":"Hi there"}]}""";
    var parsed = CloudChatsReadable.Gemini(Encoding.UTF8.GetBytes(file));
    Assert.NotNull(parsed);
    Assert.Equal("g1", parsed.Value.Conversation);
    Assert.Equal(["Hello", "Hi there"], parsed.Value.Messages.Select(m => m.Text));
    Assert.Equal([CloudChatsReadable.Role.Person, CloudChatsReadable.Role.Ai], parsed.Value.Messages.Select(m => m.Role));
  }
}
