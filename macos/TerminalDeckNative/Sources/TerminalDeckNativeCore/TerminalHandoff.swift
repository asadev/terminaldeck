import Foundation

// 28 Oct (Asad: "as soon as we move to another window, it immediately aligns itself first and then sits there, so we
// don't even feel that something is changing"; "As soon as I click on the session in my phone's side panel, it
// automatically comes to my phone. That click is the trigger.").
//
// A session's terminal follows the device where it was chosen last: the Mac (clicked in its session list or tab strip)
// or a phone (opened from its side panel or Overview). Typing is not choosing. The program can only draw at one size,
// so a device that is showing the session when the other one takes it shows "Open on <device>" with "Move back here"
// instead of a terminal squeezed into another shape. When the size moves, the device taking it keeps a cover on (that
// panel, or its own last frame) until the program has redrawn for it; nothing in between is ever shown.

/// How long a program gets to redraw after its size changed: until its output has been quiet for `quiet`
/// milliseconds, never longer than `cap` (an agent that animates all the time is shown at the cap).
public struct TerminalSettle: Sendable, Equatable {
    public static let quiet: Double = 120
    public static let cap: Double = 600
    /// When the new size was given (ms, any clock, the same one as `now` and `lastOutput`).
    public let start: Double
    public init(start: Double) { self.start = start }
    /// When to look again, or nil once it has settled. `lastOutput`: when the session last printed (output before
    /// `start` does not count: the quiet gap is measured from the resize at the earliest).
    public func next(now: Double, lastOutput: Double?) -> Double? {
        let quietAt = max(start, lastOutput ?? start) + Self.quiet
        let wake = min(quietAt, start + Self.cap)
        return now >= wake ? nil : wake
    }
}

/// Who has a session's size, as this Mac's own terminal hears it (`session:owner`).
public struct TerminalOwner: Sendable, Equatable {
    /// This Mac has it.
    public let here: Bool
    /// The device that has it otherwise, as it named itself ("Asad's iPhone").
    public let name: String?
    /// The kind of device, for the panel's picture: "phone" or "computer".
    public let kind: String
    /// Later answers win over earlier ones (an answer and an event can cross).
    public let turn: UInt64
    public init(here: Bool, name: String?, kind: String, turn: UInt64) {
        self.here = here; self.name = name; self.kind = kind; self.turn = turn
    }
    public static let mac = TerminalOwner(here: true, name: nil, kind: "computer", turn: 0)

    /// From `session:owner`'s answer or event: `{here, name, kind, turn}`.
    public static func parse(_ raw: Any?) -> TerminalOwner? {
        guard let object = raw as? [String: Any], let here = object["here"] as? Bool else { return nil }
        let turn = (object["turn"] as? NSNumber)?.uint64Value ?? 0
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TerminalOwner(here: here, name: name, kind: object["kind"] as? String ?? "phone", turn: turn)
    }

    /// The device's name as the panel says it.
    public var displayName: String { name ?? (kind == "phone" ? "your phone" : "another computer") }

    /// A phone's platform as it said in its hello ("ios", "android", "iPadOS"): a phone or tablet; anything else
    /// (another Mac) is a computer.
    public static func kind(platform: String) -> String {
        let lowered = platform.lowercased()
        return ["ios", "ipados", "android", "iphone", "ipad"].contains { lowered.hasPrefix($0) } ? "phone" : "computer"
    }
}

/// Where a session can be chosen on this Mac (28 Oct). Only a selection made in one of these places moves the session
/// here; a selection made anywhere else (Hoot moving through the app, a restored tab, a tool, a notification) never
/// does, however soon after one of his clicks it comes (Reviewer, 28 Oct: a one-second click window let a Hoot tab
/// switch count as his).
public enum TerminalChoosePlace: String, Sendable {
    /// The session list in the side panel (a row, its "Open", moving through it with the keys).
    case sessionList
    /// The tab strip above the session.
    case tabStrip
    /// ⌘1–⌘9.
    case commandNumber
}

/// The place a selection is being made in, for exactly as long as that place's own action runs.
public final class TerminalChooser {
    public private(set) var place: TerminalChoosePlace?
    public init() {}
    /// Runs `select` (that place's action) as his choice made in `place`; a session selected while it runs is chosen
    /// there. Anything `select` leaves for later runs outside it and is not his choice.
    public func choosing(in place: TerminalChoosePlace, _ select: () -> Void) {
        let outer = self.place
        self.place = place
        defer { self.place = outer }
        select()
    }
}
