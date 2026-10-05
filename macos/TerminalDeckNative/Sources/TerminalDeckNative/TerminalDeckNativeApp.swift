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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No window tabs: one window drives one engine.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        AppModel.shared.startEngine()
        IslandController.shared.start()
        IntentsLaunch.start() // Siri / Shortcuts (lane R): keeps Siri's project names current — IntentsShortcuts.swift
    }

    /// Quitting closes the screen windows; they must stay remembered for next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.isTerminating = true
        return .terminateNow
    }

    /// Closing the windows quits the app, which stops the engine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// `kill <pid>` / Ctrl-C in a terminal: quit properly so the engine is stopped too.
    /// (If this app is killed outright, the engine sees its stdin close and stops.)
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
