import Foundation

// Siri / Shortcuts (lane R): asking Hoot, the pure parts.
//
// The app asks Hoot exactly as the island's Ask box does (src/renderer/island/
// IslandPage.tsx): `copilot:state` / `copilot:ensure` for Hoot's session and
// folder, the question typed into that session in two writes (`session:write`,
// the text, a short gap, then Enter — `terminalWrites` in
// src/renderer/chat/attach/mentions.ts), and the answer read back from Hoot's own
// transcript (`chat:load` with Hoot's folder). This file is the reading and the
// wording; the app target does the calls.

/// One line of Hoot's conversation, as `chat:load` reports it.
public struct IntentChatLine: Equatable, Sendable {
    public enum Role: String, Sendable { case you, agent }
    public let id: String
    public let role: Role
    public let text: String

    public init(id: String, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Hoot itself, from `copilot:state` / `copilot:ensure`.
public struct IntentCopilot: Equatable, Sendable {
    public let status: String
    public let sessionId: String?
    /// The folder Hoot's CLI runs in — where its conversation is read from: the
    /// one it started in (`folder.runningIn`), else its own (`paths.root`).
    public let folder: String?
    public let problem: String?

    public var isRunning: Bool { status == "running" && sessionId != nil }
    public var isStarting: Bool { status == "starting" }
}

/// What came back after the question.
public struct IntentHootReply: Equatable, Sendable {
    /// The question has reached Hoot's conversation.
    public var asked: Bool
    /// Hoot's messages after it, oldest first.
    public var answer: [String]

    public init(asked: Bool, answer: [String]) {
        self.asked = asked
        self.answer = answer
    }
}

public enum IntentHoot {
    /// The island keeps a message to 4,000 characters (`hoot-menubar.ts`); so does this.
    public static let maxQuestion = 4000
    /// Between the text and the Enter, so the agent reads them as typing then submit.
    /// The page uses 50 ms back to back; this side's writes travel over HTTP, so more room.
    public static let submitGap: Duration = .milliseconds(150)
    /// How long the whole ask may run on after Siri has been answered.
    public static let backgroundLimit: Duration = .seconds(300)

    // MARK: Reading the engine

    public static func copilot(_ value: Any) -> IntentCopilot? {
        guard let dict = value as? [String: Any], let status = dict["status"] as? String else { return nil }
        let paths = dict["paths"] as? [String: Any]
        let running = (dict["folder"] as? [String: Any])?["runningIn"] as? String
        return IntentCopilot(
            status: status,
            sessionId: nonEmpty(dict["sessionId"] as? String),
            folder: nonEmpty(running) ?? nonEmpty(paths?["root"] as? String),
            problem: nonEmpty(dict["problem"] as? String))
    }

    /// `chat:load`'s answer: whether a conversation exists, and its lines.
    public static func lines(_ value: Any) -> (found: Bool, lines: [IntentChatLine]) {
        guard let dict = value as? [String: Any] else { return (false, []) }
        let found = dict["found"] as? Bool ?? true
        var out: [IntentChatLine] = []
        for case let entry as [String: Any] in (dict["messages"] as? [Any]) ?? [] {
            guard let id = entry["id"] as? String, let text = entry["text"] as? String,
                  let roleName = entry["role"] as? String, let role = IntentChatLine.Role(rawValue: roleName),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out.append(IntentChatLine(id: id, role: role, text: text))
        }
        return (found, out)
    }

    /// A `session:status` push: `[sessionId, status, …]`.
    public static func statusEvent(_ args: [Any]) -> (id: String, status: String)? {
        guard args.count >= 2, let id = args[0] as? String, let status = args[1] as? String else { return nil }
        return (id, status)
    }

    // MARK: The question

    /// What Siri heard, made safe to type into a terminal: one line, no control
    /// characters (a newline would submit half of it, an escape would be a key),
    /// at most `maxQuestion` characters. Nil when nothing is left.
    public static func question(_ raw: String) -> String? {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar -> Unicode.Scalar in
            let value = scalar.value
            let isControl = value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || value == 0x2028 || value == 0x2029
            return isControl ? " " : scalar
        }))
        let line = IntentSpeech.collapse(printable)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxQuestion)).trimmingCharacters(in: .whitespaces)
    }

    /// The two writes, in order: the text, then Enter. A message carrying `@`
    /// gets a trailing space so the agent's mention picker closes before Enter
    /// (`terminalPayload` in mentions.ts).
    public static func writes(for question: String) -> [String] {
        [question.contains("@") ? question + " " : question, "\r"]
    }

    // MARK: The answer

    /// Find the question among the lines that were not there before it was
    /// asked, and Hoot's messages after it.
    public static func reply(to question: String, in lines: [IntentChatLine], known: Set<String>) -> IntentHootReply {
        let wanted = normal(question)
        let fresh = lines.enumerated().filter { !known.contains($0.element.id) }
        let asked = fresh.last(where: { $0.element.role == .you && matches(normal($0.element.text), wanted) })
            ?? fresh.first(where: { $0.element.role == .you })
        guard let asked else { return IntentHootReply(asked: false, answer: []) }
        let answer = lines[(asked.offset + 1)...]
            .filter { $0.role == .agent }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return IntentHootReply(asked: true, answer: answer)
    }

    /// The session's status says Hoot's turn has ended (or it is stopped on a question).
    public static func isTurnOver(_ status: String) -> Bool {
        ["waiting", "idle", "completed", "exited", "input"].contains(status)
    }

    /// Hoot is asking the person something (a permission, a choice).
    public static func isAskingYou(_ status: String) -> Bool { status == "input" }

    /// Hoot's answer for Siri: the last thing it said, short and plain; all of it as detail.
    public static func answer(_ reply: IntentHootReply, assistant: String, askingYou: Bool = false) -> IntentAnswer {
        let detail = reply.answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let last = reply.answer.last.map(IntentSpeech.plain) ?? ""
        var spoken = last.isEmpty
            ? "\(assistant) answered with something I can't read aloud. It's in \(assistant)'s conversation in Terminal Deck."
            : IntentSpeech.shorten(last)
        if askingYou {
            spoken = IntentSpeech.shorten(spoken, limit: IntentSpeech.spokenLimit - 60)
                + " \(assistant) is waiting for your answer in Terminal Deck."
        }
        return IntentAnswer(spoken: spoken, detail: detail)
    }

    /// Said when the answer takes longer than Siri can wait.
    public static func deferred(assistant: String, asked: Bool) -> IntentAnswer {
        let spoken = asked
            ? "I asked \(assistant). It's still working on it — I'll send you a notification with the answer."
            : "\(assistant) is starting up. I'll ask as soon as it's ready and send you a notification with the answer."
        return IntentAnswer(spoken: spoken, detail: [spoken])
    }

    /// The notification's title and body once a late answer has landed.
    public static func notification(_ answer: IntentAnswer, assistant: String) -> (title: String, body: String) {
        ("\(assistant) answered", IntentSpeech.shorten(answer.detail.isEmpty ? answer.spoken : IntentSpeech.plain(answer.detailText), limit: 600))
    }

    // MARK: Inside

    private static func normal(_ text: String) -> String {
        IntentSpeech.collapse(text).lowercased()
    }

    /// The transcript may hold the text with the trailing space, or cut, or with
    /// an attachment note after it — a prefix either way is the same question.
    private static func matches(_ line: String, _ wanted: String) -> Bool {
        guard !wanted.isEmpty, !line.isEmpty else { return false }
        return line == wanted || line.hasPrefix(wanted) || wanted.hasPrefix(line) && line.count >= min(40, wanted.count)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
