import SwiftUI
import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

@main
struct TerminalDeckNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model: AppModel

    init() {
        // A scratch copy's AIs keep their own logins (never this Mac's own), before anything reads the environment.
        BackendScratchAgentHomes.apply()
        model = AppModel.shared
    }

    var body: some Scene {
        TerminalDeckScenes(model: model)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [any DispatchSourceSignal] = []
    private var shutdownPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NativeScrollbars.install()
        // No window tabs: one window drives one engine.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        AppModel.shared.startEngine()
        if Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true {
            // Its state reaches the pages as `update:state` once the native
            // graph registers the update channels (NativeCompositionUpdateChannels).
            NativeAppUpdater.shared.start()
        }
        NativeFront.watchPresses()
        NativeFrontGuard.install()
        DeckReconnect.shared.start() // one "the lines are back" signal: wake, back after a long gap (DeckReconnect.swift)
        // ⌘Q / "quit" Apple events: clear sheets and dialogs before AppKit asks (NativeQuit).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        // A background launch (open -g, a login item) still shows the main window; it just
        // does not take the front (NativeLaunchWindow).
        NativeLaunchWindow.ensureShown(after: [0.3, 1.5, 4])
        IslandController.shared.start()
        DriveHost.shared.start() // Hoot driving the app (lane A, NativeDriveHost.swift); inert until "drive" is registered
        IntentsLaunch.start() // Siri / Shortcuts (lane R): keeps Siri's project names current — IntentsShortcuts.swift
    }

    /// Quitting closes the screen windows; they must stay remembered for next launch.
    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        NativeSVResident.shared.noteQuitEvent(event) // logout/restart/shutdown: stop without the Keep question (SV)
        NativeQuit.terminate()
    }

    /// A Dock click on the running app is the person's.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NativeSVResident.shared.reopen(); NativeFrontGuard.expect("the Dock, Spotlight or a launcher (reopen)")
        // Coming back must never open onto a retry page the app can clear itself (11 Oct).
        AppModel.shared.reopened(); DeckReconnect.shared.cameBack(to: "the window")
        NativeLaunchWindow.ensureShown(front: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NativeCompositionRoot.note("quit: asked to terminate")
        if let reply = NativeSVResident.shared.intercept() { return reply } // Keep Them Running / Stop Everything / Cancel (SV)
        if Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true,
           !NativeAppUpdater.shared.prepareForQuit() { NativeCompositionRoot.note("quit: the updater kept the app open"); return .terminateCancel }
        AppModel.shared.isTerminating = true
        if Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true {
            guard !shutdownPending else { return .terminateLater }
            shutdownPending = true
            Task {
                let stopped = await AppModel.shared.prepareShutdown()
                if !stopped { self.shutdownPending = false }
                NSApplication.shared.reply(toApplicationShouldTerminate: stopped)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Closing the windows quits the app, which stops the engine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DeckReconnect.shared.windowsWentAway() // the "long time away" clock starts when the window goes
        return NativeSVResident.shared.quitsWhenLastWindowCloses
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeAppUpdater.shared.stop()
        AppModel.shared.shutdown()
    }

    /// `kill -TERM <app pid>` / Ctrl-C close without a resident prompt. The
    /// shared shutdown path detaches hosted owners; signals never mean Stop Everything.
    private func installSignalHandlers() {
        // HOSTLOST (9 Oct): a write to a closed pipe or socket is an error to handle, never a reason
        // for the app to vanish. Terminal children reset SIGPIPE to the default before they exec.
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Not from inside this main-queue block: `terminate` answers `.terminateLater` and
                // spins the run loop until the shutdown Task replies, and that Task (main actor) runs
                // on the main queue — which this very block would be holding, so it never ran and the
                // quit hung forever (walk 1, 7 Oct). From the run loop, the main queue stays free.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        NativeCompositionRoot.note("quit: signal requested prompt-free detach")
                        NativeSVResident.shared.noteSignal()
                        NativeQuit.terminate()
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
        // Scratch quit proofs only (QUIT, 9 Oct): launched with TD_NATIVE_QUIT_PROOF=1, SIGUSR1 is the
        // person's ⌘Q and SIGUSR2 the menu's "Quit and Stop Everything" — so a proof never opens a
        // menu or takes the screen. Unset (every real launch), both signals keep their default.
        guard ProcessInfo.processInfo.environment[NativeLaunchSwitches.quitProof] == "1" else { return }
        for (sig, everything) in [(SIGUSR1, false), (SIGUSR2, true)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        NativeCompositionRoot.note("quit proof: " + (everything ? "Quit and Stop Everything" : "Quit (⌘Q)"))
                        if everything { NativeSVResident.shared.quitStoppingEverything() } else { NativeQuit.terminate() }
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
