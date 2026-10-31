import Foundation

/// 28 Oct (bug B, Asad: "ok do 1", typed for Decker in Deck Dev, reached Commander in ClaudeiMatch first, and
/// Commander acted on it). On the Mac one key press goes to exactly one place: the view holding the keyboard. That
/// place was the phone screen open beside the Deck Dev session (Deck Dev's device panel, D13DBB65): a phone screen
/// keeps the keyboard until he clicks somewhere else (finding 3), and the phone app types what it gets into the session
/// IT has open, which was ClaudeiMatch. Nothing on the Deck Dev terminal said its keys were going elsewhere.
///
/// Two rules close it:
/// - `TerminalKeyboardNotice`: while a phone screen in the same window holds the keyboard, the terminal on screen
///   says so over its bottom edge ("Typing goes to the phone"), with one click to type here instead.
/// - `TerminalKeyboardChoice`: choosing a session (session list, tab strip, ⌘-number) moves the keyboard to its
///   terminal, from a phone screen too, for the moment it takes that terminal to land in the window.
public enum TerminalKeyboardNotice {
    /// Whether the terminal shows "Typing goes to the phone": it is on screen with a live session, and the key
    /// holder of its own window is a phone screen.
    public static func phoneHasTheKeyboard(terminalOnScreen: Bool, sessionLive: Bool, holderIsPhoneInSameWindow: Bool) -> Bool {
        terminalOnScreen && sessionLive && holderIsPhoneInSameWindow
    }
}

/// His own choice of a session, as a moment: a terminal asking for the keyboard within `lasts` seconds after it
/// counts as him moving the keyboard there (a phone screen holding it lets go). Anything later, or a selection made
/// outside his choosing places (Hoot, a restored tab, a tool), never takes the keyboard from a phone.
public struct TerminalKeyboardChoice: Sendable {
    public static let lasts: TimeInterval = 1.5
    public private(set) var at: TimeInterval?
    public init() {}
    public mutating func chose(at now: TimeInterval) { at = now }
    public func moves(now: TimeInterval) -> Bool {
        guard let at else { return false }
        return now >= at && now - at <= Self.lasts
    }
}
