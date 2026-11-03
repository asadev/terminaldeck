import Foundation

/// The account chip's switch, decided natively (12 Oct). It used to go through the hidden page
/// (`session-switch.ts`), and a page command can be dropped with no error: the person picked an account and
/// nothing happened. These are that file's rules and words, ported, so the native chip asks the engine itself and
/// every failure is said in plain words. The page's own copy stays for the places that still use it.
public struct AccountSwitchPlanView: Equatable, Sendable {
    public enum Mode: String, Sendable { case inPlace = "in-place", restart }
    public static let conversations: Set<String> = ["same", "carried", "follows", "stays", "theirs", "taken", "unreadable", "none", "separate", "handover"]
    public let sessionId: String
    /// Why it cannot happen, already written for a person. Nil when it can.
    public let refusal: String?
    public let fromName: String?
    public let toName: String?
    public let conversation: String
    public let resume: Bool
    public let mode: Mode
    /// Said first when a session that should switch in place has to start again on the account.
    public let notice: String?
    /// 13 Oct: the session is already on that account (or was just switched to it): nothing to do.
    public let already: Bool
    /// The AI of the account switched to ("claude", "codex", "gemini").
    public var toProvider: String? = nil
    /// Another AI takes over (the conversation is handed to it word for word).
    public var handsOver: Bool { conversation == "handover" }

    public init(sessionId: String, refusal: String?, fromName: String?, toName: String?, conversation: String,
                resume: Bool, mode: Mode, notice: String?, already: Bool = false) {
        self.sessionId = sessionId; self.refusal = refusal; self.fromName = fromName; self.toName = toName
        self.conversation = conversation; self.resume = resume; self.mode = mode; self.notice = notice; self.already = already
    }

    /// `readSwitchPlan`: narrowed, never cast. A plan with no `refusal` field at all is not an answer.
    public static func read(_ raw: Any?) -> AccountSwitchPlanView? {
        guard let row = raw as? [String: Any], let id = row["sessionId"] as? String, !id.isEmpty, row.keys.contains("refusal") else { return nil }
        let refusal: String?
        if let text = row["refusal"] as? String, !text.isEmpty { refusal = text }
        else if row["refusal"] is NSNull { refusal = nil }
        else { return nil }
        guard let conversation = row["conversation"] as? String, conversations.contains(conversation) else { return nil }
        func name(_ key: String) -> String? { ((row[key] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let notice = (row["notice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var plan = AccountSwitchPlanView(sessionId: id, refusal: refusal, fromName: name("from"), toName: name("to"), conversation: conversation,
                                         resume: row["resume"] as? Bool == true, mode: row["mode"] as? String == "in-place" ? .inPlace : .restart,
                                         notice: notice, already: row["already"] as? Bool == true)
        plan.toProvider = (row["to"] as? [String: Any])?["provider"] as? String
        return plan
    }

    /// Made the moment the account is picked, with no dialog: only in place, and only when nothing refused it.
    public var switchesWithoutAsking: Bool { mode == .inPlace && refusal == nil }
}

public enum AccountSwitchWords {
    /// `SWITCH_KEEPS`: what does not change.
    public static let keeps = "Same tab, same folder, same place on the bar. The agent running in it is stopped and started again as the other account, so anything it has not written to disk goes with it."
    public static let unreadablePlan = "This build could not work out what switching would do. Nothing was changed."
    public static func alreadyOn(_ name: String) -> String { "Already on \(name)" }
    /// The AI's name as the switch says it (the same names Hoot's hand-over uses).
    public static func aiName(_ provider: String?) -> String {
        switch provider { case "claude": "Claude Code"; case "codex": "Codex"; case "gemini": "Gemini"; default: provider ?? "the other AI" }
    }
    /// Asad, 12 Oct: one line in the Switch offer, only while the session's agent is busy (working, or mid-turn
    /// waiting on a question). An idle agent loses nothing, and an in-place switch stops nothing.
    public static let busyWarning = "Its agent is working right now. Switching will stop what it's doing."
    public static func warning(offer: Bool, status: String?) -> String? {
        guard offer else { return nil }
        let meaning = StatusMeaning(status)
        return meaning == .working || meaning == .needsInput ? busyWarning : nil
    }

    /// `switchConversationTag`: the conversation's fate in two words, beside the arrow.
    public static func tag(_ conversation: String) -> String? {
        switch conversation {
        case "same", "carried", "follows", "handover": nil
        case "theirs": "their conversation"
        case "unreadable": "conversation unknown"
        default: "new conversation"
        }
    }

    /// `switchConversationNote`: the ⓘ sentence, read before anything is stopped. Never says "restart" (Asad, 12 Oct).
    public static func note(_ conversation: String, from: String, to: String) -> String {
        let stays = "This conversation stays with \(from)."
        switch conversation {
        case "same": return "Nothing starts again. This conversation carries on in the same terminal — only the account changes to \(to)."
        case "carried": return "This agent reads its login only when it starts, so it starts again as \(to) — and this conversation comes with it: it is copied into \(to)'s history and continued there."
        case "follows": return "This conversation comes with you. \(to) shares the same conversation history, so the session picks up exactly where it is now — same conversation, new account."
        case "theirs": return "\(stays) \(to) has its own conversation in this folder and that is the one that will be continued here — not the one on screen now."
        case "taken": return "\(stays) \(to) has a conversation in this folder, but another tab is already showing it, so this starts a new one instead."
        case "unreadable": return "\(stays) This app cannot read where \(to) keeps its history, so the agent is asked to continue and will say for itself in the terminal whether it found anything."
        case "none": return "\(stays) This agent has no way to continue an earlier conversation, so \(to) starts fresh."
        case "separate": return "\(stays) This agent keeps each account's conversations separate, so \(to) cannot see this one and starts a new conversation."
        case "handover": return "Another AI takes over in this tab, in the same folder and project. It is given this conversation word for word, and the whole record in a file it can read, so it carries on from here."
        default: return "\(stays) \(to) has no conversation in this folder, so it starts a new one."
        }
    }

    /// The dialog for a plan, in the fields the native confirm draws (the same ones the page used to send).
    public static func request(_ plan: AccountSwitchPlanView?, title: String, from: String, to: String,
                               busy: Bool, problem: String?, canDefer: Bool) -> SwitchAccountRequest {
        guard let plan else {
            return SwitchAccountRequest(title: title, fromName: from, toName: to, planned: false, refusal: nil, tag: nil, note: "",
                                        busy: busy, problem: problem, canDefer: false)
        }
        let tag = tag(plan.conversation)
        // In place nothing stops: only the account changes (never the "stopped and started again" line).
        let note = plan.mode == .inPlace ? note("same", from: from, to: to)
            : plan.handsOver ? note("handover", from: from, to: to) + " The AI running now is stopped, so anything it has not written to disk goes with it."
            : tag == nil && plan.conversation != "carried" ? keeps : note(plan.conversation, from: from, to: to) + " " + keeps
        return SwitchAccountRequest(title: title, fromName: from, toName: to, planned: true, refusal: plan.refusal, tag: tag, note: note,
                                    busy: busy, problem: problem, canDefer: canDefer && plan.notice == nil)
    }

    /// The sentence inside a failure, without a transport's prefix; never empty.
    public static func problem(_ text: String) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Error invoking remote method", "The persistent host service could not complete "] {
            if message.hasPrefix(prefix), let colon = message.range(of: ": ") { message = String(message[colon.upperBound...]) }
        }
        if let at = message.range(of: "Error: ", options: .backwards) { message = String(message[at.upperBound...]) }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || message.hasPrefix("The operation couldn’t be completed") { return "The account could not be switched just now. Nothing was changed." }
        return message
    }
}
