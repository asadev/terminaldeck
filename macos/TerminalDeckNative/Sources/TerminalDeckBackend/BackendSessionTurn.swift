import Foundation
import TerminalDeckNativeCore

/// 2 Nov (lane/working-turn): what an AI session that reports its turn through hooks (Claude Code, Codex, Gemini, also
/// one started by hand in a shell tab) is doing. It is "working" from the moment its turn starts (the person's or Hoot's
/// message, a tool, the model writing) until the turn ends (its Stop hook, a question for the person, or an interrupt);
/// otherwise it is whatever its last hook said. Its screen never decides while a turn is known.
///
/// Before, the app let the first output chunk after a working hook hand the status back to the screen reader, a write
/// of any byte (focus and mouse reports included) did the same, and in the shipped app (sessions behind the session
/// host) the hooks never reached the status at all. The screen reader sees a working sign only while Claude's footer
/// shows "esc to interrupt", and after each burst of output it reports "working" and its reading in the same moment:
/// every redraw without that sign (a once-a-second timer, a draft, a resize) became a Working pulse about 70 ms long
/// (the board's own write time), then Idle. His Decker session (3:00 backup): 20,151 such pulses, Idle ~0.9 s between
/// them, and never once "Finished its turn" (no Stop ever reached the status).
///
/// Facts measured on Claude Code 2.1.310 (2 Nov, a scratch PTY, classic and fullscreen renderer): while a turn runs
/// its screen prints every 0.1 s (never more than 0.35 s apart, also through a 20 s tool), at its idle prompt nothing at
/// all; Esc ends the turn with NO Stop hook and no PostToolUse, and the screen goes still within 0.2 s.
public struct BackendSessionTurn: Sendable, Equatable {
    public struct Timing: Sendable, Equatable {
        /// A working turn whose screen and hooks have both been still this long has ended without telling (40x the
        /// longest pause a working Claude screen makes).
        public var quiet: Double = 8_000
        /// After Esc / Ctrl+C: the turn has ended once the screen has been still this long...
        public var interruptQuiet: Double = 1_000
        /// ...and at least this long after the key.
        public var interruptWait: Double = 1_500
        /// Enter on a finished turn: a turn has started only if its turn-start hook comes within this long (or its
        /// screen is still busy, e.g. a slash command at work).
        public var confirm: Double = 3_000
        public init() {}
        public init(quiet: Double, interruptQuiet: Double, interruptWait: Double, confirm: Double) {
            self.quiet = quiet; self.interruptQuiet = interruptQuiet; self.interruptWait = interruptWait; self.confirm = confirm
        }
    }
    /// Input sent to the session, by what it can mean for a turn.
    public enum Input: Sendable, Equatable {
        case submit, interrupt, typing, other
        public init(_ data: String) {
            if Self.interrupts.contains(data) { self = .interrupt; return }
            guard BackendPTYManager.isTyping(Data(data.utf8)) else { self = .other; return }
            self = data.hasSuffix("\r") || data.hasSuffix("\n") ? .submit : .typing
        }
        /// Esc and Ctrl+C, plain or as the kitty keyboard protocol sends them.
        static let interrupts: Set<String> = ["\u{1b}", "\u{03}", "\u{1b}[27u", "\u{1b}[27;1u", "\u{1b}[99;5u"]
    }

    public private(set) var status: BackendSessionStatus
    /// Monotonic ms: the last hook, or the person's Enter or answer.
    private(set) var lastStep: Double
    private(set) var lastOutput: Double = 0
    private(set) var interruptAt: Double?
    /// Enter on a finished turn shows Working at once; without its turn-start hook it goes back to this.
    private(set) var unconfirmed: BackendSessionStatus?

    public init(status: BackendSessionStatus, at: Double) { self.status = status; lastStep = at }

    /// What a hook says about the turn, nil when it says nothing.
    /// `notificationType`: Claude's Notification hook names its kind (`notification_type`, Claude Code 2.1.310). Only a
    /// kind that waits for the person's answer is a question. 3 Nov: "idle_prompt" ("Claude is waiting for your input",
    /// sent once 60 s after every finished turn) made each idle Claude session "input" (Needs you) until someone typed,
    /// so the one session-host restart refused all afternoon with every prompt empty. A Notification without a kind
    /// (an older CLI) keeps the old meaning.
    public static func status(provider: String, event: String, sessionProvider: String, notificationType: String? = nil) -> BackendSessionStatus? {
        guard let status = BackendSessionHookCoordinator.statuses[provider]?[event] else { return nil }
        if provider == "claude", event == "Notification", let kind = notificationType, !claudeAskingNotifications.contains(kind) { return nil }
        return sessionProvider == "shell" && event == "SessionEnd" ? .waiting : status
    }
    /// Claude Code 2.1.310's notification kinds that wait for the person (the rest: idle_prompt, auth_success,
    /// agent_completed, push_notification, computer_use_*, quota_* ... say nothing about the turn).
    static let claudeAskingNotifications: Set<String> = ["permission_prompt", "worker_permission_prompt", "elicitation_dialog",
        "elicitation_url_dialog", "agent_needs_input"]

    public mutating func hook(_ next: BackendSessionStatus, at: Double) {
        status = next; lastStep = at; interruptAt = nil; unconfirmed = nil
    }
    public mutating func output(at: Double) { lastOutput = max(lastOutput, at) }
    /// Input from the person, Hoot, a task or a phone. Typing into a finished turn or a running one changes nothing.
    public mutating func input(_ kind: Input, at: Double) {
        switch kind {
        case .submit:
            switch status {
            case .working: return                                  // a message queued for the running turn
            case .input: unconfirmed = nil                        // an answer: the turn goes on
            default: unconfirmed = status                         // a new message: its hook confirms the turn
            }
            status = .working; lastStep = at; interruptAt = nil
        case .typing:
            guard status == .input else { return }                // an answer typed into the question
            status = .working; lastStep = at; interruptAt = nil
        case .interrupt:
            guard status == .working || status == .input else { return }
            interruptAt = at
        case .other: return                                       // focus, mouse, answers the terminal sends itself
        }
    }
    /// How long (ms from `now`) until the turn can end by itself; nil when only a hook or input can move it.
    public func due(now: Double, timing: Timing) -> Double? {
        var deadlines: [Double] = []
        if status == .working { deadlines.append(max(lastStep, lastOutput, interruptAt ?? 0) + timing.quiet) }
        if unconfirmed != nil { deadlines.append(max(lastStep + timing.confirm, lastOutput + timing.interruptQuiet)) }
        if let interruptAt, status == .working || status == .input {
            deadlines.append(max(interruptAt + timing.interruptWait, lastOutput + timing.interruptQuiet))
        }
        return deadlines.min().map { max(0, $0 - now) }
    }
    /// The turn ended without its hook: returns the new status, nil while it goes on. `screenAsks`: the screen reader
    /// sees a question (an agent that asks without a hook, e.g. a Codex approval).
    public mutating func settle(now: Double, timing: Timing, screenAsks: Bool) -> BackendSessionStatus? {
        let next: BackendSessionStatus
        if let back = unconfirmed, now >= lastStep + timing.confirm, now >= lastOutput + timing.interruptQuiet {
            next = back
        } else if let interruptAt, status == .working || status == .input,
                  now >= interruptAt + timing.interruptWait, now >= lastOutput + timing.interruptQuiet {
            next = .waiting
        } else if status == .working, now >= max(lastStep, lastOutput, interruptAt ?? 0) + timing.quiet {
            next = screenAsks ? .input : .waiting
        } else { return nil }
        status = next; lastStep = now; interruptAt = nil; unconfirmed = nil
        return next
    }
}

/// Hands accepted hook events to the lifecycle in their order without making the hook's sender wait for it: behind
/// the session host the hook's own reply (and so the AI's next step) waits while the app reads its accepted events.
public final class BackendSessionTurnFeed: Sendable {
    private let input: AsyncStream<BackendSessionHookEvent>.Continuation
    public init(_ lifecycle: BackendSessionLifecycleCoordinator) {
        let (events, input) = AsyncStream<BackendSessionHookEvent>.makeStream()
        self.input = input
        Task { for await event in events { await lifecycle.noteHook(event) } }
    }
    public func post(_ event: BackendSessionHookEvent) { input.yield(event) }
    deinit { input.finish() }
}
