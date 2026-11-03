import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The one "the app's lines are back" signal, and the one way a retry control presses itself.
///
/// Asad, 11 Oct: "if the app is not used for long time it goes to retry page and works after
/// clicking on retry". Nobody presses retry for something the app can retry itself:
///  - `generation` goes up when the Mac wakes, when the person comes back to the app after a long
///    gap, when the engine or the session host is up again, and when another copy that held the
///    data quits. These are events (notifications the system already sends); nothing polls.
///  - a retry control presses itself ONLY where its call site allows it (`autoRetry: true`, for
///    read-only reloads and reconnects; never for anything that costs an AI turn, starts, stops,
///    sends, signs in or changes data), and then once per `generation`: never on a timer.
///  - the whole-window failure page does the same through `AppModel.linesAreBack`.
/// The pauses and budgets are pure rules in `DeckRetryRules` (TerminalDeckNativeCore).
@MainActor
@Observable
final class DeckReconnect {
    static let shared = DeckReconnect()

    /// Counts "the lines are back". Retry controls watch it; pages may read it too.
    private(set) var generation = 0
    /// Why it last went up, for engine.log and for a page that wants to say so.
    private(set) var lastReason = ""

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var lastBack = Date.distantPast
    @ObservationIgnored private var selfPress = DeckSelfPress()

    private init() {}

    /// Once, at launch (TerminalDeckNativeApp). Only listens; draws and opens nothing.
    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeckReconnect.shared.back("the Mac woke") }
        })
        // Another copy holding the data quit: "Another copy is already using your data" heals itself.
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard bundle != nil, bundle == Bundle.main.bundleIdentifier else { return }
                DeckReconnect.shared.back("another copy of the app quit")
            }
        })
        let center = NotificationCenter.default
        // HELPER DOWN (11 Oct, test rows 10 and 11): the session helper went away. Pages that read
        // files (Artifacts, costs, history) now read without it (BackendTranscriptAccountFolders),
        // so anything that failed in that moment reads again at once instead of waiting for a person.
        observers.append(center.addObserver(forName: .tdSessionHostLost, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeckReconnect.shared.back("the session helper stopped; pages read again without it") }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeckReconnect.shared.awaySince = Date() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeckReconnect.shared.cameBack(to: "the app") }
        })
    }

    /// The person is looking at the app again (it became active, or its window was reopened).
    /// Only a long gap counts: switching apps all day must not reload pages.
    func cameBack(to what: String, now: Date = Date()) {
        defer { awaySince = nil }
        guard let since = awaySince else { return }
        let away = now.timeIntervalSince(since)
        guard DeckIdleRule.isLongGap(awaySeconds: away) else { return }
        back("back to \(what) after \(Int(away / 60)) min away")
    }

    /// A window was closed: the gap starts now even if the app stays active with no window.
    func windowsWentAway() { if awaySince == nil { awaySince = Date() } }

    /// The lines may be back: every retry control on screen, and the whole-window failure
    /// page, tries again by itself. Several reasons in the same second count once.
    func back(_ reason: String, now: Date = Date()) {
        guard now.timeIntervalSince(lastBack) >= 1 else { return }
        lastBack = now
        lastReason = reason
        generation += 1
        AppModel.shared.engine.log.note("reconnect: \(reason); pages with a retry try again by themselves (\(generation))")
        AppModel.shared.linesAreBack(reason)
    }

    #if DEBUG
    /// Checks only: the signal itself, without the app model (no engine, no log file).
    func linesBackForChecks(now: Date = Date()) { lastBack = now; generation += 1 }
    #endif

    // MARK: A retry control's own press (allowed call sites only)

    /// One press per signal: for a control already on screen when it fired, or one that appeared
    /// in the same moment (DeckSelfPress). Never without a signal.
    func mayPress(_ id: String, onScreenBefore: Bool) -> Bool {
        selfPress.mayPress(id: id, generation: generation, signalAge: Date().timeIntervalSince(lastBack), onScreenBefore: onScreenBefore)
    }
    func pressedByItself(_ id: String) { selfPress.pressed(id: id, generation: generation) }
}

/// The one automatic press an ALLOWED retry control gets per "lines are back" signal (see
/// `DeckSelfPress`). Without a signal it does nothing at all: no timer, no press on appearing.
private struct DeckSelfRetry: ViewModifier {
    let id: String
    let action: () -> Void
    @State private var signal = DeckReconnect.shared
    /// The signal count this control last saw, so "it fired while I was on screen" is known.
    @State private var seen: Int?
    /// A retry the page has switched off (busy, not connected) is never pressed for it.
    @Environment(\.isEnabled) private var isEnabled

    private struct Turn: Hashable { let generation: Int; let enabled: Bool }

    func body(content: Content) -> some View {
        content
            .task(id: Turn(generation: signal.generation, enabled: isEnabled)) {
                let onScreenBefore = seen != nil && seen != signal.generation
                seen = signal.generation
                guard isEnabled, signal.mayPress(id, onScreenBefore: onScreenBefore) else { return }
                // Let the page settle after the signal; this is one press for one event, not a timer.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, signal.mayPress(id, onScreenBefore: true) else { return }
                signal.pressedByItself(id)
                action()
            }
    }
}

extension View {
    /// EXPLICIT OPT-IN, for a read-only reload or a reconnect only: this control presses itself
    /// once when the app's lines come back. Never use it for anything that costs an AI turn,
    /// starts or stops something, sends, signs in or out, switches an account or changes data.
    func deckRetriesItself(instance: String? = nil, file: String = #fileID, line: Int = #line,
                           _ action: @escaping () -> Void) -> some View {
        modifier(DeckSelfRetry(id: DeckSelfPress.id(file: file, line: line, instance: instance), action: action))
    }
    func deckRetriesItself(id: String, _ action: @escaping () -> Void) -> some View {
        modifier(DeckSelfRetry(id: id, action: action))
    }
}

/// "Try again", for pages. SAFE BY DEFAULT: a plain button the person presses. Only with
/// `autoRetry: true` (a read-only reload of a page or list, or a reconnect) does it also press
/// itself once when the app's lines come back (`DeckReconnect`). Leave it false for anything
/// that costs an AI turn, starts or stops something, sends, signs in or changes data.
struct DeckRetryButton: View {
    let title: String
    let autoRetry: Bool
    let id: String
    let action: () -> Void

    /// - instance: which item this control belongs to, for one built inside a `ForEach` (e.g. the
    ///   project id): each item then gets its own press per signal instead of sharing the line's one.
    init(_ title: String = "Try Again", autoRetry: Bool = false, instance: String? = nil,
         file: String = #fileID, line: Int = #line, action: @escaping () -> Void) {
        self.title = title
        self.autoRetry = autoRetry
        self.id = DeckSelfPress.id(file: file, line: line, instance: instance)
        self.action = action
    }

    var body: some View {
        if autoRetry {
            Button(title, action: action).deckRetriesItself(id: id, action)
        } else {
            Button(title, action: action)
        }
    }
}
