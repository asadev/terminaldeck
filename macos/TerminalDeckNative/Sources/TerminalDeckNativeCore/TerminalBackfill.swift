import Foundation

/// A session's history first, then its live output — and nothing shown until the
/// history is in (`terminal-backfill.ts`).
///
/// The screen subscribes to `session:data` *before* it asks for `session:scrollback`,
/// so nothing printed in between is lost. Chunks that arrive while the read is in
/// flight are held and written after the history, which is the order they happened
/// in. Over the native bridge the events and the read travel on different
/// connections, so a held chunk may already be at the end of the history it
/// follows; those are dropped instead of printed twice (the engine's scrollback is
/// the very chunks it pushes, joined, so a chunk that was in time for the read is
/// exactly at its end).
///
/// Pure: the caller writes what this hands back and runs the clock
/// (`holdLimit`) that releases the screen if the read never answers.
public struct TerminalBackfill: Sendable {
    /// The longest a screen may be held, whatever is still arriving (`HOLD_LIMIT_MS`).
    public static let holdLimit: TimeInterval = 2

    public private(set) var isHolding = true
    private var held: [String] = []

    public init() {}

    /// One live chunk. Returns what to write now, or nil while it is held.
    public mutating func push(_ chunk: String) -> String? {
        guard isHolding else { return chunk }
        held.append(chunk)
        return nil
    }

    /// What to write once the hold ends: the history, then what arrived live
    /// while it was being read. Kept apart because only the second is the
    /// program speaking now — an old query in the history must not be answered.
    public struct Release: Equatable, Sendable {
        public let history: String
        public let live: String
        /// Both, in the order they are written.
        public var text: String { history + live }
    }

    /// The history is here (nil when the read failed or the hold ran out).
    /// Returns what to write, in order — or nil when already released, because
    /// every call after the first does nothing.
    public mutating func release(backlog: String?) -> Release? {
        guard isHolding else { return nil }
        isHolding = false
        let history = backlog ?? ""
        let fresh = Self.unseen(held, after: history)
        held.removeAll()
        return Release(history: history, live: fresh.joined())
    }

    /// The held chunks that the history does not already end with.
    static func unseen(_ held: [String], after history: String) -> [String] {
        guard !held.isEmpty, !history.isEmpty else { return held }
        let tail = history.utf8
        var joined: [UInt8] = []
        var covered = 0
        for (index, chunk) in held.enumerated() {
            joined.append(contentsOf: chunk.utf8)
            if joined.count > tail.count { break }
            if tail.suffix(joined.count).elementsEqual(joined) { covered = index + 1 }
        }
        return Array(held.dropFirst(covered))
    }
}

/// What is drawn over a session once it has ended (`endedNotice` for `exited`).
public struct TerminalEndNotice: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let actionLabel: String

    public static func exited(code: Int?) -> TerminalEndNotice {
        let said: String
        if let code, code != 0 {
            said = "The program running here exited with status \(code)."
        } else {
            said = "The program running here finished."
        }
        let detail = said + " What it printed is still above — nothing typed now goes anywhere."
        return TerminalEndNotice(title: "This session has ended", detail: detail, actionLabel: "Start another session here")
    }

    /// The line written into the terminal when the process exits (as the web pane does).
    public static let exitLine = "\r\n\u{1b}[2m[process exited]\u{1b}[0m\r\n"
}
