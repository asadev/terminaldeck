import Foundation

/// A Claude session that started while account switching was not ready (the session host's saved-login
/// store would not open when it started) cannot change account in place: nothing serves its login.
/// Asad's rules: switching changes only the account; where the agent cannot pick up a new login in place it
/// is started again on the account, in the same tab, carrying on the same conversation, and that is said in
/// plain words first. And (12 Oct, permanent): to the person it is always a switch, never called a start-over — the
/// line, the button and every notice say Switch. These are those words, used by the switch plan (and so by
/// the MCP tool) and by the switch dialog.
public enum SwitchAccountRestartOffer {
    /// Why it cannot switch in place, with no word like "broker" or "seat" in it.
    public static let notReady = "This session started before account switching was ready, so it can't switch in place."
    public static let confirmLabel = "Switch"
    public static let busyLabel = "Switching…"

    /// The whole offer, short and plain, read before anything is stopped.
    public static func sentence(accountName: String, carriesOn: Bool) -> String {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "that account" : accountName
        return "Switch this session to \(name)? "
            + (carriesOn ? "It carries on with the same conversation." : "It starts a new conversation there; this one stays with the account it is on.")
    }

    /// 13 Oct: another AI takes over the session (Asad: "conversation can stay same, just other AI takes over").
    public static func handoverSentence(accountName: String, ai: String) -> String {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "that account" : accountName
        return "Switch this session to \(name) on \(ai)? \(ai) takes over in this tab and carries on with the same conversation."
    }

    /// What the app's own window was last told about a switch it asked for. The page draws the switch dialog
    /// from its own fields, which have no place for this offer, so the dialog reads it here. Every plan the
    /// window asks for replaces it (or clears it), so it always belongs to the dialog that plan opens.
    public struct Offer: Sendable, Equatable {
        public let sessionID: String
        public let accountID: String
        public let carriesOn: Bool
        public let at: Date
        public init(sessionID: String, accountID: String, carriesOn: Bool, at: Date = Date()) {
            self.sessionID = sessionID; self.accountID = accountID; self.carriesOn = carriesOn; self.at = at
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latest: Offer?
    public static func record(_ offer: Offer?) { lock.withLock { latest = offer } }
    /// The offer for the dialog being drawn now, if the last plan the window asked for was one.
    public static var current: Offer? { lock.withLock { latest } }
}
