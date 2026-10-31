import Foundation

/// When the app tries again by itself, before a person ever sees "Try again".
///
/// Asad, 11 Oct: "if the app is not used for long time it goes to retry page and works after
/// clicking on retry". A person never presses retry for something the app can retry itself:
///  - a read that failed because a line dropped (the session host, the engine) is asked again
///    after a short pause, twice, before any page hears about the failure;
///  - a retry control whose call site allows it (read-only reloads only) presses itself once
///    when the app's lines come back (wake, back after a long gap, engine or host up again);
///  - a web page whose process went away reloads, however long the app has been open.
/// Everything here is a pure decision so it can be checked with a fake clock.
public enum DeckRetryRules {
    /// Seconds to wait before automatic try 1 and 2. After these the failure is real.
    public static let pauses: [Double] = [0.35, 1.0]

    public static func pause(beforeAutomaticTry index: Int) -> Double? {
        index >= 0 && index < pauses.count ? pauses[index] : nil
    }

    /// The last word of a channel that only reads. A change is never repeated by itself:
    /// a write whose answer was lost may already have happened.
    public static let readVerbs: Set<String> = [
        "list", "state", "read", "status", "get", "overview", "context", "config", "options",
        "providers", "capabilities", "detect", "about", "paths", "info", "devices", "support",
        "account-providers", "history-state", "snapshot", "readiness",
    ]

    public static func isRead(channel: String) -> Bool {
        guard let verb = channel.split(separator: ":").last.map(String.init), channel.contains(":") else { return false }
        return readVerbs.contains(verb)
    }

    /// A failure that goes away by itself: the private line to the session host or the engine
    /// dropped, timed out or is still coming back. Matched on the words the owners already use
    /// (BackendHOSTFailure, EngineWireError, URLSession), so a wrapped copy is recognised too.
    public static func isTransient(_ description: String) -> Bool {
        let text = description.lowercased()
        let marks = [
            "the session host is unavailable",
            "the private session host connection failed",
            "the private session host could not be authenticated",
            "the session host still owns processes but cannot be reached yet",
            "isn't ready yet", "is not ready yet",
            "the request timed out", "the network connection was lost", "could not connect to the server",
            "connection refused", "connection reset", "broken pipe", "operation timed out",
        ]
        return marks.contains { text.contains($0) }
    }

    /// A read may be asked again by itself only when both hold.
    public static func retriesByItself(channel: String, failure description: String) -> Bool {
        isRead(channel: channel) && isTransient(description)
    }

    /// Words on a control that mean "ask again" (the shared empty state reads its own label).
    public static func isRetryLabel(_ label: String) -> Bool {
        // Not "Check again": that is on pages that are not errors ("not connected yet", "not installed").
        ["try again", "retry", "reload"].contains(label.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// When a retry control may press itself. SAFE BY DEFAULT (11 Oct, after the Context-handoff
/// defect: a self-pressing "Try again" asked Hoot again and undid the person's Stop): a control
/// never presses itself unless its call site allows it, and an allowed one presses only on the
/// shared "the lines are back" signal: once per signal, never on a timer, never twice.
///  - on screen when the signal fires: one press;
///  - appearing just after a signal (its failure happened in that same moment, e.g. the helper
///    was lost and the page's read failed a second later): one press;
///  - no signal, or already pressed for this signal: nothing. The button is the person's.
public struct DeckSelfPress: Sendable {
    /// A failure that appears this soon after the signal belongs to that signal's moment.
    public static let sameMomentSeconds: Double = 10
    private var pressedFor: [String: Int] = [:]
    public init() {}

    /// A control's id: where it is built, plus which item it belongs to when one line builds many
    /// (a card per failed project), so every item gets its own press per signal.
    public static func id(file: String, line: Int, instance: String? = nil) -> String {
        instance.map { "\(file):\(line)#\($0)" } ?? "\(file):\(line)"
    }

    /// - generation: the signal counter; 0 means no signal has ever fired.
    /// - signalAge: seconds since the signal fired.
    /// - onScreenBefore: the control was already showing when the signal fired.
    public func mayPress(id: String, generation: Int, signalAge: Double, onScreenBefore: Bool) -> Bool {
        guard generation > 0, pressedFor[id] != generation else { return false }
        return onScreenBefore || (signalAge >= 0 && signalAge <= Self.sameMomentSeconds)
    }
    public mutating func pressed(id: String, generation: Int) { pressedFor[id] = generation }
}

/// A web page's process may end any number of times over days of use and is simply reloaded.
/// Only several ends in a short time mean it "keeps crashing".
public struct DeckCrashWindow: Sendable {
    public static let seconds: Double = 60
    public static let limit = 3
    private var times: [Double] = []
    public init() {}

    /// Note one end; true while reloading is still the right answer.
    public mutating func reloadAfterEnd(at now: Double) -> Bool {
        times = times.filter { now - $0 < Self.seconds } + [now]
        return times.count < Self.limit
    }
    public var recentEnds: Int { times.count }
    public mutating func reset() { times = [] }
}

/// "Not used for a long time": away long enough that the first thing on screen must be fresh.
public enum DeckIdleRule {
    public static let longGapSeconds: Double = 300
    public static func isLongGap(awaySeconds: Double) -> Bool { awaySeconds >= longGapSeconds }
}

/// Closing the app while the session host keeps sessions running: the handshake that tells the
/// host "you carry on alone" is tried a few times; if it still fails the close goes on exactly
/// as a scripted quit already does (the host keeps its sessions through an app that is gone).
/// It never cancels the quit and never leaves a retry page behind (the cause of Asad's report).
public enum DeckQuitDetachRule {
    public enum Step: Equatable, Sendable { case tryAgain(afterSeconds: Double), closeWithoutHandshake }
    public static let pauses: [Double] = [0.3, 0.8]

    /// After failed attempt number `failures` (1, 2, 3…): wait and try again, or go on closing.
    public static func afterFailure(_ failures: Int) -> Step {
        failures >= 1 && failures <= pauses.count ? .tryAgain(afterSeconds: pauses[failures - 1]) : .closeWithoutHandshake
    }
}

/// The close-time handshake loop itself, with its handshake, its pauses and its log passed in,
/// so the same code that runs at quit is checked with a fake handshake and a fake clock.
public enum DeckQuitDetach {
    public enum Outcome: Equatable, Sendable {
        /// The host confirmed it carries on alone (after this many failed tries first).
        case detached(afterFailures: Int)
        /// It never confirmed: the close goes on as a scripted quit does. Never a cancelled quit.
        case closedWithoutHandshake(failures: Int)
    }

    /// `unattended` (a signal, logout or scripted quit) never waits: one try, then on.
    @MainActor
    public static func run(unattended: Bool,
                           handshake: @MainActor () async throws -> Void,
                           pause: @MainActor (Double) async -> Void,
                           trace: @MainActor (String) -> Void) async -> Outcome {
        var failures = 0
        while true {
            do { try await handshake(); return .detached(afterFailures: failures) }
            catch {
                failures += 1
                let step: DeckQuitDetachRule.Step = unattended ? .closeWithoutHandshake : DeckQuitDetachRule.afterFailure(failures)
                switch step {
                case .tryAgain(let seconds):
                    trace("hosted detach handshake failed (" + error.localizedDescription + "); trying again by itself (\(failures))")
                    await pause(seconds)
                case .closeWithoutHandshake:
                    trace("hosted detach handshake held (" + error.localizedDescription + "); detaching without it")
                    return .closedWithoutHandshake(failures: failures)
                }
            }
        }
    }
}
