import AppKit
import Foundation
import TerminalDeckNativeCore

/// Starts the crash watcher for the installed app (CrashRelaunchPolicy) and leaves the clean mark on an orderly quit.
/// The watcher is a tiny shell process: it sleeps 2 s between looks while the app runs and ends with it.
@MainActor enum NativeCrashRelaunch {
    private static var folder: URL?
    private static var cleanMark: URL?

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        let testSwitches = [NativeLaunchSwitches.uiTest, NativeLaunchSwitches.quitProof, NativeLaunchSwitches.dataFolder]
            .contains { environment[$0]?.isEmpty == false }
        let standalone = Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true
        let app = Bundle.main.bundlePath
        guard CrashRelaunchPolicy.watches(bundlePath: app, standalone: standalone, testSwitches: testSwitches) else { return }
        let run = InstalledTerminalDeck.configuration().dataRoot.appendingPathComponent("run", isDirectory: true)
        let pid = getpid()
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            // How the run before this one ended, and who opened this one, before the marks go (2 Nov restarts audit).
            let marks = (try? FileManager.default.contentsOfDirectory(atPath: run.path)) ?? []
            let relaunches = ((try? String(contentsOf: run.appendingPathComponent("relaunches"), encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            let version = [Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                           Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String].compactMap { $0 }.joined(separator: " build ")
            NativeCompositionRoot.note("launch: pid \(pid), \(version); " + CrashRelaunchPolicy.previousEnd(
                markNames: marks, currentPID: pid, relaunchTimes: relaunches, now: Date().timeIntervalSince1970))
            // Marks of earlier runs go; this run's start mark is the "newer than" for crash reports.
            for old in (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("clean-") || old.lastPathComponent.hasPrefix("started-") {
                try? FileManager.default.removeItem(at: old)
            }
            let started = run.appendingPathComponent("started-\(pid)")
            try Data().write(to: started)
            let clean = run.appendingPathComponent("clean-\(pid)")
            let watcher = Process()
            watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            watcher.arguments = ["-c", CrashRelaunchPolicy.script, "td-crash-watch", "\(pid)", app, clean.path, started.path,
                                 run.appendingPathComponent("relaunches").path]
            watcher.standardInput = FileHandle.nullDevice
            watcher.standardOutput = FileHandle.nullDevice
            watcher.standardError = FileHandle.nullDevice
            try watcher.run()
            folder = run; cleanMark = clean
        } catch {
            NativeCompositionRoot.note("crash watcher: not started (\(error.localizedDescription))")
        }
    }

    /// The orderly end (Quit, logout, update, scripted quit): the watcher then ends without opening the app again.
    static func markClean() {
        guard let cleanMark else { return }
        try? Data().write(to: cleanMark)
    }
}
