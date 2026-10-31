import Foundation
import TerminalDeckNativeCore

/// Hoot's conversation carries on across a change of AI or account (Asad, 12 Oct: "If there is available other account
/// of Codex … one drop down with all available AIs … Once we send new message, the new AI will read the whole message
/// history and it will start right from there without feeling that there is a change").
///
/// The CLI's own conversation belongs to one AI and one login and is never handed to another, so the new one starts a
/// clean desk; its first message carries the conversation so far, word for word, inside the app's own marker (never
/// stored as the person's words). The desk's own "last messages" (BackendHootDesk.said) stop at 12 messages, which is
/// right for a clean desk but not for "the whole message history": here as many messages as fit the budget go in,
/// newest kept, the person's last message always whole.
public enum BackendHootHandover {
    /// About 12,000 tokens: well inside one message (256 KiB) and every AI's window.
    public static let budget = 50_000
    public static let maximumMessages = 400
    static let names = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"]

    /// The block the new AI (or account) gets with its first message. nil when nothing was said yet.
    public static func text(from: String, messages: [BackendHootDeskMessage], budget: Int = budget) -> String? {
        guard let said = history(messages, budget: budget) else { return nil }
        let who = from == "account" ? "You are carrying on this conversation on another account of the same Coding AI."
            : "You are taking over this conversation from \(names[from] ?? from); the person chose you for Hoot from now on."
        return "## The conversation so far, word for word\n" + who + " The person sees one continuous chat and did not see "
            + "anything change, so do not bring it up and do not greet them again. Everything below was said before this "
            + "message, oldest first; anything older is in the diary (memory_search). Carry on from here.\n\n" + said
    }

    /// The messages, oldest first: as many as fit `budget` characters, counted from the newest; the person's last
    /// message is always included whole (a very long one keeps its start and its end, as on the desk).
    public static func history(_ recent: [BackendHootDeskMessage], budget: Int = budget) -> String? {
        let all = recent.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !all.isEmpty else { return nil }
        let lastPerson = all.lastIndex { $0.fromPerson } ?? all.count - 1
        var kept: [String] = [], used = 0
        for index in all.indices.reversed() {
            let line = (all[index].label ?? (all[index].fromPerson ? "The person" : "You")) + ": " + BackendHootDesk.shortened(all[index].text)
            guard index >= lastPerson || used + line.count <= budget else { break }
            kept.insert(line, at: 0); used += line.count
        }
        let left = all.count - kept.count
        return (left > 0 ? "[\(left) earlier message\(left == 1 ? " is" : "s are") in the diary.]\n\n" : "") + kept.joined(separator: "\n\n")
    }

    /// What Hoot is told when the app's restart cut its answer off and it carries on by itself.
    public static func restartLine(_ message: String) -> String {
        "Terminal Deck was restarted while you were answering the person's message below, so your answer was cut off. "
            + "Carry on exactly where you left off: do not start over, do not repeat what you already did, and do not mention "
            + "the restart unless it matters to the answer.\n\nThe person's message:\n" + message
    }
}
