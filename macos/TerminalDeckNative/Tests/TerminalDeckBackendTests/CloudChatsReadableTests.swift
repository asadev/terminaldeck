import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Sessions in the Cloud, step 1: the readable copy of a chat is the event lines the phones already draw, one JSON event
/// per line. Claude Code's and Codex's histories keep only what the person wrote and what the AI answered (no tool
/// traffic, no context the AI was given, no side chains); the app's own chats keep their own events, without the
/// streamed pieces.
@Suite("Cloud chats: the readable copy for Claude Code, Codex and the app's chats")
struct CloudChatsReadableTests {
    typealias Readable = BackendCloudChatsReadable

    static func events(_ lines: Data) throws -> [HootChatEvent] {
        try String(decoding: lines, as: UTF8.self).split(separator: "\n").map { try HootChatEvent(wire: try NativeRPCValue.parseJSON(Data($0.utf8))) }
    }

    @Test("Claude Code: the person's words and the answers; tool traffic, reminders and side chains left out")
    func claude() throws {
        let history = [
            #"{"type":"user","message":{"role":"user","content":"Fix the login page"},"uuid":"u1","timestamp":"2026-11-15T01:00:00.000Z","sessionId":"c1"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Looking at it now."},{"type":"tool_use","id":"t1","name":"Read","input":{}}]},"uuid":"a1","timestamp":"2026-11-15T01:00:01.000Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file text"}]},"uuid":"r1"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u2"}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"id":"m2","model":"claude-opus","content":[{"type":"text","text":"helper"}]},"uuid":"a2"}"#,
            #"{"type":"assistant","message":{"id":"m3","model":"claude-opus","content":[{"type":"text","text":"Done: the button works."}]},"uuid":"a3","timestamp":"2026-11-15T01:00:09.000Z"}"#,
        ].joined(separator: "\n") + "\n"
        let made = Readable.window(Data(history.utf8), format: .claude, conversation: "c1", provider: .claude, nextSequence: 1)
        #expect(made.consumed == history.utf8.count)
        let events = try Self.events(made.lines)
        #expect(events.map(\.record.kind) == [.user, .message, .message])
        #expect(events.map { $0.record.value["text"].string } == ["Fix the login page", "Looking at it now.", "Done: the button works."])
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(events.allSatisfy { $0.conversationID == "c1" && $0.provider == .claude })
        #expect(events[0].at == 1_794_704_400_000)
    }

    @Test("A line still being written waits; a huge line is passed over")
    func partialLines() throws {
        let whole = #"{"type":"user","message":{"role":"user","content":"one"},"uuid":"u1"}"# + "\n"
        let partial = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"tw"#
        let made = Readable.window(Data((whole + partial).utf8), format: .claude, conversation: "c", provider: .claude, nextSequence: 4)
        #expect(made.consumed == whole.utf8.count)
        #expect(try Self.events(made.lines).map(\.sequence) == [4])
    }

    @Test("Codex: response_item messages only; its context and tool calls left out")
    func codex() throws {
        let history = [
            #"{"timestamp":"2026-11-15T02:00:00.000Z","type":"session_meta","payload":{"id":"th1","cwd":"/tmp/p"}}"#,
            #"{"timestamp":"2026-11-15T02:00:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/tmp/p</cwd>\n</environment_context>"}]}}"#,
            #"{"timestamp":"2026-11-15T02:00:00.200Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
            #"{"timestamp":"2026-11-15T02:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a test"}]}}"#,
            #"{"timestamp":"2026-11-15T02:00:01.500Z","type":"event_msg","payload":{"type":"user_message","message":"Add a test"}}"#,
            #"{"timestamp":"2026-11-15T02:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#,
            #"{"timestamp":"2026-11-15T02:00:03.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            #"{"timestamp":"2026-11-15T02:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_1","content":[{"type":"output_text","text":"Added one test."}]}}"#,
        ].joined(separator: "\n") + "\n"
        let made = Readable.window(Data(history.utf8), format: .codex, conversation: "th1", provider: .codex, nextSequence: 1)
        let events = try Self.events(made.lines)
        #expect(events.map(\.record.kind) == [.user, .message])
        #expect(events.map { $0.record.value["text"].string } == ["Add a test", "Added one test."])
        #expect(events.allSatisfy { $0.provider == .codex })
        #expect(events[1].record.messageID == "msg_1")
    }

    @Test("The app's chats: their own events as the phones get them, streamed pieces left out")
    func appChat() throws {
        func event(_ sequence: Int, _ kind: String, _ text: String, conversation: String = "conv") -> String {
            #"{"version":1,"id":"\#(conversation):\#(sequence)","conversationId":"\#(conversation)","turnId":"t1","sequence":\#(sequence),"provider":"claude","kind":"\#(kind)","messageId":"m\#(sequence)","value":{"text":"\#(text)"},"at":1763168400000}"#
        }
        let file = #"{"version":1,"conversationId":"conv","busy":false,"events":["#
            + [event(1, "user", "Plan the release"), event(2, "textDelta", "Pla"), event(3, "message", "Here is the plan."),
               event(4, "user", "from another chat", conversation: "old")].joined(separator: ",") + "]}"
        let parsed = try #require(Readable.appChat(Data(file.utf8)))
        #expect(parsed.conversation == "conv")
        #expect(parsed.events.map(\.sequence) == [1, 3])
        let events = try Self.events(parsed.events.reduce(Data()) { $0 + $1.line })
        #expect(events.map(\.record.kind) == [.user, .message])
        #expect(events.map { $0.record.value["text"].string } == ["Plan the release", "Here is the plan."])
    }

    @Test("Gemini: the person's and Gemini's messages from its whole file")
    func gemini() throws {
        let file = #"{"sessionId":"g1","messages":[{"id":"1","timestamp":"2026-11-15T03:00:00.000Z","type":"user","content":"Hello"},{"id":"2","type":"info","content":"tool"},{"id":"3","timestamp":"2026-11-15T03:00:02.000Z","type":"gemini","content":"Hi there"}]}"#
        let parsed = try #require(Readable.gemini(Data(file.utf8)))
        #expect(parsed.conversation == "g1")
        #expect(parsed.messages.map(\.text) == ["Hello", "Hi there"])
        #expect(parsed.messages.map(\.role) == [.person, .ai])
    }
}
