import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// "The sessions belong to the machine, not to the window" (TS resident.ts + index.ts
/// before-quit / goBackground / leaveBackground). Quitting with sessions running asks once —
/// Keep Them Running / Stop Everything / Cancel, with "Do this from now on" — and Keep puts
/// the windows away and leaves this process running: the PTYs, their pids and their in-memory
/// scrollback never move, so reopening shows every tab exactly where it was. While resident, a
/// menu-bar icon lists what is running and can stop one session or quit and stop them all.
/// Going to the background never activates anything; only the person's own reopen (Dock,
/// Spotlight, `open`, the menu-bar icon's Open) brings the windows back.
@MainActor
final class NativeSVResident {
    static let shared = NativeSVResident()

    /// The quit is already decided (TS `stopping`): Quit and Stop All, a signal, an update
    /// being installed, or the person's own answer. Never asked about again.
    var stopping = false
    private(set) var inBackground = false
    private var asking = false
    private var hidden: [NSWindow] = []
    private var activity: NSObjectProtocol?
    private var observer: UUID?
    private lazy var presence = BackendS3FillResidentPresence(
        sessions: { [weak self] in self?.menuSessions() ?? [] },
        open: { [weak self] in self?.openFromMenuBar() },
        stop: { [weak self] id in self?.stopOne(id) },
        quitAll: { [weak self] in self?.quitStoppingEverything() })
    private init() {}

    private var sessions: BackendCompositionSessions? { NativeCompositionRoot.shared.sessionsArea }
    private func live() -> [BackendSessionMeta] { sessions?.manager.list().filter { $0.exitCode == nil } ?? [] }

    /// applicationShouldTerminate's first word: nil lets the quit go on (nothing running, or
    /// already decided); otherwise the quit is cancelled while the app decides (TS
    /// `event.preventDefault()`), and re-issued only when the answer is Stop.
    func intercept() -> NSApplication.TerminateReply? {
        if NativeAppUpdater.shared.relaunchOnQuit { stopping = true } // TS beforeInstall: an update quit is never talked out of
        if stopping { leaveBackground(showWindows: false); return nil }
        let count = live().count
        guard count > 0, let state = NativeCompositionRoot.shared.backend?.state else { leaveBackground(showWindows: false); return nil }
        if asking { return .terminateCancel }
        asking = true
        Task { @MainActor in
            let plan = NativeSVQuitRule.plan(liveSessions: count, behavior: await state.getQuitBehavior(), stopping: false, inBackground: inBackground)
            // From the run loop, never from inside a main-queue job: a modal alert or `terminate`
            // run there would hold the main queue and stall every main-actor task (INT 14:10).
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.act(plan, state: state) } }
        }
        return .terminateCancel
    }

    private func act(_ plan: NativeSVQuitRule.Plan, state: NativeStateStore) {
        switch plan {
        case .stop: asking = false; quitStoppingEverything()
        case .keep: asking = false; goBackground()
        case .ask: ask(state: state)
        }
    }

    /// TS askWhatQuittingMeans. App-modal, answered by the person who just asked to quit.
    private func ask(state: NativeStateStore) {
        defer { asking = false }
        let question = NativeSVQuitRule.question(liveSessions: live().count)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = question.message
        alert.informativeText = question.detail
        for title in NativeSVQuitRule.buttons { alert.addButton(withTitle: title) }
        alert.buttons.last?.keyEquivalent = "\u{1b}" // Cancel is Escape (TS cancelId 2)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NativeSVQuitRule.rememberLabel
        alert.suppressionButton?.state = .off
        let response = alert.runModal() // front-ok: the person's own quit (⌘Q, the Quit menu, the last window closing)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = NativeSVQuitRule.answer(buttonIndex: index)
        if let remembered = NativeSVQuitRule.remembered(choice, checkbox: alert.suppressionButton?.state == .on) {
            Task {
                do { try await state.setQuitBehavior(remembered) }
                catch { NativeCompositionRoot.note("quit: the answer could not be remembered: " + error.localizedDescription) }
            }
        }
        NativeCompositionRoot.note("quit: the person answered " + choice.rawValue)
        switch choice {
        case .cancel:
            // Closing the last window is what asked: bring it back rather than leave no window.
            if !inBackground { NativeLaunchWindow.ensureShown() }
        case .keep: goBackground()
        case .stop: quitStoppingEverything()
        }
    }

    /// Signals, the menu-bar icon's "Quit and Stop All Sessions", and the Stop answer.
    func quitStoppingEverything() {
        stopping = true
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NativeQuit.terminate() } }
    }

    /// TS goBackground: the windows go (ordered out, never closed, so nothing on them is torn
    /// down), the sessions stay, the icon appears. Nothing is activated or brought forward.
    private func goBackground() {
        guard !inBackground else { presence.refresh(); return }
        guard let sessions else { quitStoppingEverything(); return }
        inBackground = true
        sessions.manager.setWatched(false)
        // TS keepAlive.hold(): no App Nap while agents work with no window.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Terminal Deck is keeping sessions running with no window")
        hidden = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && ($0.canBecomeMain || $0.styleMask.contains(.titled)) }
        for window in hidden { window.orderOut(nil) }
        presence.show()
        let lifecycle = sessions.lifecycle
        Task { @MainActor [weak self] in
            let id = await lifecycle.observe { event in
                switch event {
                case .exit, .removed, .status: await MainActor.run { self?.presence.refresh() }
                case .data: break
                }
            }
            guard let self, self.inBackground, self.observer == nil else { await lifecycle.removeObserver(id); return }
            self.observer = id
        }
        NativeCompositionRoot.note("quit: kept \(live().count) session(s) running in the background")
    }

    /// TS leaveBackground (+ createWindow): the person reopened the app.
    private func leaveBackground(showWindows: Bool) {
        guard inBackground else { return }
        inBackground = false
        presence.hide()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        if let observer, let lifecycle = sessions?.lifecycle { Task { await lifecycle.removeObserver(observer) } }
        observer = nil
        sessions?.manager.setWatched(true)
        let windows = hidden; hidden = []
        guard showWindows else { return }
        for window in windows { window.makeKeyAndOrderFront(nil) } // front-ok: the person reopened the app (Dock, Spotlight, menu-bar Open)
        // The main window, if the last-window close removed it, comes back as at launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { NativeLaunchWindow.ensureShown() } }
        NativeCompositionRoot.note("quit: back from the background; \(live().count) session(s) still running")
    }

    /// A quit sent by logout, restart or shutdown stops everything with no question: the
    /// processes end with the login session anyway, and an app-modal question would stall it.
    func noteQuitEvent(_ event: NSAppleEventDescriptor) {
        guard let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return }
        if [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map({ OSType($0) }).contains(why) {
            stopping = true
            NativeCompositionRoot.note("quit: logout, restart or shutdown; stopping every session without asking")
        }
    }

    /// The reopen Apple event (Dock click, Spotlight, a launcher, `open`).
    func reopen() { leaveBackground(showWindows: true) }

    /// TS window-all-closed.
    var quitsWhenLastWindowCloses: Bool { NativeSVQuitRule.quitsWhenLastWindowCloses(inBackground: inBackground, asking: asking) }

    private func openFromMenuBar() {
        NativeFrontGuard.expect("the menu-bar icon (Open)")
        leaveBackground(showWindows: true)
    }

    private func stopOne(_ id: String) {
        guard let lifecycle = sessions?.lifecycle else { return }
        Task { @MainActor [weak self] in
            try? await lifecycle.close(sessionID: id)
            self?.presence.refresh()
        }
    }

    private func menuSessions() -> [BackendS3FillResidentMenu.Session] {
        (sessions?.manager.list() ?? []).map { .init(id: $0.id, provider: $0.provider, cwd: $0.cwd, exitCode: $0.exitCode) }
    }
}
