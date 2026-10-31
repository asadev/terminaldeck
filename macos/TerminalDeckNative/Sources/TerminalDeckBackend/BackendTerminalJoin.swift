import Foundation

/// 27 Oct (Asad: opening iLoop on the phone took 11–22 s with today's session host). What a phone is sent when it
/// attaches to a session kept by a session host older than the remount (`BackendTerminalRemount`). Such a host
/// answers with its raw tail (up to 4,000 reads: megabytes for an agent whose full-screen view animates) and with
/// its own parse of the session as text (`screen`, `scrollbackText`). The phone needs the screen and its history,
/// not megabytes of frames; this builds them in the app, small, from what that host already sends:
///
/// - A full-screen program (Claude Code's full-screen view) whose last full repaint (a clear of the whole screen,
///   a reset, or the switch into the full screen; it repaints whole on every size change) is in the tail and not too
///   far back: the history as lines, the switch into the full screen, the modes as they were at that repaint, then
///   the raw bytes from the repaint on. Exact, colours included, and small.
/// - Anything else: the session's own text (its history and its screen as the host parsed them), plus its modes.
///   Exact words at the right places, without colours.
public enum BackendTerminalJoin {
    /// The history lines sent before the screen (the Mac's terminal keeps as many).
    public static let historyLines = 10_000
    /// The most raw bytes kept after the last full repaint (about five minutes of a working agent's animation);
    /// beyond that the text is sent instead, so the phone never parses more than this to open a terminal.
    public static let tailBudget = 256 * 1024

    public enum Shape: Equatable, Sendable { case repaint, text }

    public static func build(replay: String, screen: String?, scrollbackText: String?) -> (text: String, shape: Shape) {
        let bytes = Array(replay.utf8)
        var modes = BackendTerminalModes()
        modes.scan(bytes)
        let history = Self.history(scrollbackText)
        // An unwritten cell reads as NUL, which a terminal skips; it is a blank column here.
        let rows = (screen ?? "").replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        // A long-running program switched into its full screen before the tail began; the host's own screen says.
        let fullScreen = modes.alternate ?? Self.differs(screen: rows, from: history)
        if fullScreen, let anchor = modes.lastFullRepaint, bytes.count - anchor <= tailBudget {
            // The modes in force where the repaint begins; the repaint itself and what follows set the rest.
            var before = BackendTerminalModes()
            before.scan(Array(bytes[..<anchor]))
            // The viewer is a fresh terminal: it enters the full screen here, whatever the tail began inside.
            var out = history.joined(separator: "\r\n")
            out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J" + before.restore()
            out += String(decoding: bytes[anchor...], as: UTF8.self)
            return (out, .repaint)
        }
        var out = history.joined(separator: "\r\n")
        if fullScreen {
            // The full screen as the host sees it, row under row; wrapping off so a narrower viewer cuts, not spills.
            var painted = rows
            while let last = painted.last, last.trimmingCharacters(in: .whitespaces).isEmpty { painted.removeLast() }
            out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[?7l" + painted.joined(separator: "\r\n") + "\u{1b}[?7h"
        }
        out += modes.restore()
        return (out, .text)
    }

    /// The main screen's lines, the newest `historyLines`, without the blank rows under the last one written.
    static func history(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(historyLines))
    }

    /// No switch into the full screen was in the tail: the screen is the full screen when it is not the main
    /// screen's last rows.
    private static func differs(screen: [String], from history: [String]) -> Bool {
        let shown = screen.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return false }
        let tail = history.suffix(shown.count + 64).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(tail.suffix(shown.count)) != shown
    }
}
