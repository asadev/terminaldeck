import SwiftUI
import AppKit
import TerminalDeckNativeCore

@main
struct TerminalDeckNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        TerminalDeckScenes(model: model)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [any DispatchSourceSignal] = []
    private var shutdownPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        NativeSVResident.shared.reopen(); NativeFrontGuard.expect("the Dock, Spotlight or a launcher (reopen)"); return true
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
        NativeSVResident.shared.quitsWhenLastWindowCloses
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeAppUpdater.shared.stop()
        AppModel.shared.shutdown()
    }

    /// `kill <pid>` / Ctrl-C in a terminal: quit properly so the engine is stopped too.
    /// (If this app is killed outright, the engine sees its stdin close and stops.)
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Not from inside this main-queue block: `terminate` answers `.terminateLater` and
                // spins the run loop until the shutdown Task replies, and that Task (main actor) runs
                // on the main queue — which this very block would be holding, so it never ran and the
                // quit hung forever (walk 1, 7 Oct). From the run loop, the main queue stays free.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { NativeSVResident.shared.stopping = true; NativeQuit.terminate() }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
