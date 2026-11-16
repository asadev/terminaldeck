import AppKit
import TerminalDeckBackend

/// What came back from a guarded sheet: `chose` = the person's press was the accepting button; `taken` = and that
/// press may be taken as the person's own (R3).
struct NativeCloudSheetAnswer: Sendable, Equatable {
    let chose: Bool
    let taken: Bool
    /// Which button ended the sheet (the alert's own response number), for a sheet with a second refusing choice.
    var response: Int = 0
}

/// R3 in the window. Every trust or approval sheet (the device trust sheets, and saved passwords' "Allow this
/// device", "Codes match" and "Add this MCP server") registers here while it is open:
/// - a press that follows the app's own remote input (Mac reach from the phone) by less than two seconds is refused;
/// - every such sheet closes, as a refusal, when remote control of this Mac starts or ends.
/// Other remote-control software and anything else that can press buttons on this Mac cannot be told from the
/// person; that is accepted in the design's threat table.
///
/// Security review S4: this file is the ONE place lane A's Cloud code shows a sheet (`present`, `presentPanel`,
/// `notice`). A sheet that accepts something cannot be added without the guard, and
/// `CloudSheetGuardUITests.everyCloudSheetIsShownThroughTheGuard_S4` fails when a Cloud file shows one by itself.
@MainActor
final class NativeCloudSheetGuard {
    static let shared = NativeCloudSheetGuard()
    /// The record of the app's own remote input. Fixtures replace it.
    var remote: BackendRemoteInputGuard = .system
    /// How often an open sheet looks. Nothing looks while no such sheet is open.
    var interval: Duration = .milliseconds(500)
    private var closers: [UUID: @MainActor () -> Void] = [:]
    private var watching: Task<Void, Never>?
    private var wasActive = false
    /// Every Cloud sheet, panel and notice shown through this guard, counted (owner, 13 Nov: sign-in and joining in
    /// "Automatically, with my account" show none; the tests read this count).
    private(set) var shown = 0
    init() {}

    /// A press counts only when it is the accepting button AND the app's own remote input did not just post.
    /// Security review S1: the press is judged by the press event's own time when the window has it, so an app that
    /// was slow to handle a remote click cannot let that click age past the two seconds.
    nonisolated static func accepted(_ response: NSApplication.ModalResponse, accept: NSApplication.ModalResponse,
                                     remote: BackendRemoteInputGuard) -> Bool {
        guard response == accept else { return false }
        let pressedAt: UInt64? = Thread.isMainThread ? MainActor.assumeIsolated { NativeCloudSheetGuard.pressTime() } : nil
        return !remote.refusesPress(at: pressedAt)
    }
    /// The time of the click or key press being handled right now, on the uptime clock (the clock the remote-input
    /// record uses; an event's time is seconds since this Mac started, not counting sleep). nil when no such event
    /// is being handled.
    static func pressTime() -> UInt64? {
        guard let event = NSApp?.currentEvent else { return nil }
        return pressTime(type: event.type, seconds: event.timestamp)
    }
    nonisolated static func pressTime(type: NSEvent.EventType, seconds: TimeInterval) -> UInt64? {
        switch type {
        case .leftMouseUp, .leftMouseDown, .keyDown, .keyUp: break
        default: return nil
        }
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000_000 else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
    /// Security review S6: the accepting button of a guarded sheet takes a click and nothing else. It answers no
    /// key, and it cannot hold the keyboard focus, so with macOS keyboard navigation switched on Space can never
    /// press it.
    static func harden(_ alert: NSAlert, accept: NSApplication.ModalResponse) {
        let index = accept.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return }
        let button = alert.buttons[index]
        button.keyEquivalent = ""
        button.refusesFirstResponder = true
    }
    /// Review S-B4: a press on the Cloud page itself (no sheet) that turns Cloud on, lets Cloud write somewhere or
    /// changes a file ("Use Cloud here", the Cloud switch, "Choose folder…", "Show earlier version", "Put the
    /// earlier version back"). Refused, with one plain line, when the app's own remote input posted in the two
    /// seconds before the press, the same rule as a sheet's accepting button.
    static let pressRefused = "This Mac was just being controlled from another device, so that was not done. Wait a moment and press it yourself."
    nonisolated static func pagePressAllowed(remote: BackendRemoteInputGuard, at pressedAt: UInt64?) -> Bool {
        !remote.refusesPress(at: pressedAt)
    }
    /// Runs `work` only when the press may be taken as the person's own; otherwise says why nothing happened.
    func pagePress(model: NativeCloudAccount = .shared, _ work: () -> Void) {
        guard Self.pagePressAllowed(remote: remote, at: Self.pressTime()) else { model.say(Self.pressRefused); return }
        work()
    }
    /// Shows a sheet whose `accept` button gives something away (trust, a sign-in, a sign-out of the last Mac, a
    /// file that can run a command). While it is open it closes, as a refusal, when remote control of this Mac
    /// starts or ends; at the press the answer is taken only if the app's own remote input did not just post.
    func present(_ alert: NSAlert, on window: NSWindow, accept: NSApplication.ModalResponse) async -> NativeCloudSheetAnswer {
        shown += 1
        Self.harden(alert, accept: accept)
        let remote = self.remote
        let watch = opened { [weak alert] in
            if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort) }
        }
        let answer: NativeCloudSheetAnswer = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) {
                continuation.resume(returning: NativeCloudSheetAnswer(chose: $0 == accept, taken: NativeCloudSheetGuard.accepted($0, accept: accept, remote: remote),
                                                                      response: $0.rawValue))
            }
        }
        closed(watch)
        return answer
    }
    /// The same question when this app has no window to attach a sheet to: an app-modal alert, judged by the same
    /// press rule.
    /// Front gate: an app-modal alert takes the keyboard, so it is shown only for the person's own action; anything
    /// else (an arrival, a sync change, a trust notice) is a refusal and shows nothing.
    func presentWithoutWindow(_ alert: NSAlert, accept: NSApplication.ModalResponse) -> NativeCloudSheetAnswer {
        guard NativeFront.personActing else { return NativeCloudSheetAnswer(chose: false, taken: false, response: NSApplication.ModalResponse.abort.rawValue) }
        shown += 1
        Self.harden(alert, accept: accept)
        let response = alert.runModal() // front-ok: guarded by NativeFront.personActing above (the person's own action)
        return NativeCloudSheetAnswer(chose: response == accept, taken: Self.accepted(response, accept: accept, remote: remote), response: response.rawValue)
    }
    /// A panel of the app's own (the new-Mac sheet) as a sheet on `window`. `close` must end it as a refusal; the
    /// result is handed to `closed` when the panel goes away. The panel's own accepting button asks `remote` itself.
    func presentPanel(_ panel: NSPanel, on window: NSWindow, close: @escaping @MainActor () -> Void) -> UUID {
        shown += 1
        let id = opened(close)
        window.beginSheet(panel)
        return id
    }
    /// A notice with one "OK" and nothing to accept.
    func notice(_ alert: NSAlert) {
        shown += 1
        if let window = NSApp?.keyWindow { alert.beginSheetModal(for: window); return }
        // Without a window the alert is app-modal and takes the keyboard: only for the person's own action.
        NativeFront.onlyForPerson("Cloud notice: " + alert.messageText) { _ = alert.runModal() }
    }
    /// Remote control started or ended since the sheet opened.
    nonisolated static func sessionChanged(was: Bool, now: Bool) -> Bool { was != now }

    /// A trust or approval sheet is opening. `close` must end it as a refusal.
    func opened(_ close: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        if closers.isEmpty { wasActive = remote.remoteControlActive() }
        closers[id] = close
        watch()
        return id
    }
    func closed(_ id: UUID) {
        closers[id] = nil
        if closers.isEmpty { watching?.cancel(); watching = nil }
    }
    /// One look: if remote control started or ended, every registered sheet is closed. Returns whether it did.
    @discardableResult func check() -> Bool {
        guard !closers.isEmpty else { return false }
        let active = remote.remoteControlActive()
        guard Self.sessionChanged(was: wasActive, now: active) else { return false }
        wasActive = active
        let open = closers
        closers = [:]
        watching?.cancel(); watching = nil
        for close in open.values { close() }
        return true
    }
    private func watch() {
        guard watching == nil else { return }
        let pause = interval
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled, let self else { return }
                if self.check() { return }
            }
        }
    }
}
