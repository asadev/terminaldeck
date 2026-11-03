import Foundation
import Testing
import TerminalDeckNativeCore

/// Item 57 (Asad, 1 Nov: "the whole Terminal Deck app on the Mac quits; I need to go to the Mac and turn it on again"):
/// the watcher opens the installed app again only after a real crash of that copy, never after an orderly quit, a
/// Force Quit (no crash report) or a crash of another copy, and at most 3 times in 10 minutes. The real script runs here
/// with a fake home, a fake app path and a recording opener.
@Suite("Back after a crash", .serialized)
struct CrashRelaunchTests {
    @Test func onlyTheInstalledAppWatches() {
        #expect(CrashRelaunchPolicy.watches(bundlePath: "/Applications/Terminal Deck.app", standalone: true, testSwitches: false))
        #expect(!CrashRelaunchPolicy.watches(bundlePath: "/Users/x/Deck Dev/code/dev/Terminal Deck Dev.app", standalone: true, testSwitches: false))
        #expect(!CrashRelaunchPolicy.watches(bundlePath: "/Applications/Terminal Deck.app", standalone: false, testSwitches: false))
        #expect(!CrashRelaunchPolicy.watches(bundlePath: "/Applications/Terminal Deck.app", standalone: true, testSwitches: true))
    }

    @Test func theDecision() {
        let now = 10_000.0
        #expect(CrashRelaunchPolicy.reopen(cleanMark: false, crashReportForThisCopy: true, recentRelaunches: [], now: now, appRunning: false))
        #expect(!CrashRelaunchPolicy.reopen(cleanMark: true, crashReportForThisCopy: true, recentRelaunches: [], now: now, appRunning: false))
        #expect(!CrashRelaunchPolicy.reopen(cleanMark: false, crashReportForThisCopy: false, recentRelaunches: [], now: now, appRunning: false), "Force Quit")
        #expect(!CrashRelaunchPolicy.reopen(cleanMark: false, crashReportForThisCopy: true, recentRelaunches: [], now: now, appRunning: true))
        #expect(!CrashRelaunchPolicy.reopen(cleanMark: false, crashReportForThisCopy: true, recentRelaunches: [now - 10, now - 20, now - 30], now: now, appRunning: false))
        #expect(CrashRelaunchPolicy.reopen(cleanMark: false, crashReportForThisCopy: true, recentRelaunches: [now - 700, now - 800, now - 900], now: now, appRunning: false))
    }

    /// 2 Nov restarts audit: the launch line says how the run before ended and whether the watcher opened this one.
    @Test func theLaunchLineSaysHowThePreviousRunEnded() {
        let now = 50_000.0
        #expect(CrashRelaunchPolicy.previousEnd(markNames: ["started-41", "clean-41", "started-90"], currentPID: 90, relaunchTimes: [], now: now)
            == "the previous run (pid 41) ended the orderly way (Quit, an update or a scripted quit)")
        let unclean = CrashRelaunchPolicy.previousEnd(markNames: ["started-41"], currentPID: 90, relaunchTimes: [now - 5], now: now)
        #expect(unclean.hasPrefix("the previous run (pid 41) did NOT end the orderly way"))
        #expect(unclean.hasSuffix("; opened again by the crash watcher"))
        #expect(!CrashRelaunchPolicy.previousEnd(markNames: ["started-41"], currentPID: 90, relaunchTimes: [now - 600], now: now).contains("crash watcher"))
        #expect(CrashRelaunchPolicy.previousEnd(markNames: ["relaunches"], currentPID: 90, relaunchTimes: [], now: now) == "no record of the previous run")
        // The marks are named by the watcher script's arguments in NativeCrashRelaunch: started-<pid>, clean-<pid>.
        #expect(CrashRelaunchPolicy.previousEnd(markNames: ["started-90", "clean-90"], currentPID: 90, relaunchTimes: [], now: now) == "no record of the previous run")
    }

    /// Runs the real watcher script once; answers what the opener was asked to open ("" for nothing).
    private func run(clean: Bool, crashFor appPath: String?, history: [TimeInterval] = []) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CRW-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home"), reports = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let app = "/Applications/Fake Deck \(UUID().uuidString.prefix(6)).app"
        let start = dir.appendingPathComponent("started"), clean_ = dir.appendingPathComponent("clean"), hist = dir.appendingPathComponent("hist")
        let opened = dir.appendingPathComponent("opened"), opener = dir.appendingPathComponent("opener.sh")
        try Data().write(to: start)
        if clean { try Data().write(to: clean_) }
        try history.map { String(Int($0)) }.joined(separator: "\n").appending(history.isEmpty ? "" : "\n").write(to: hist, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"$@\" > '\(opened.path)'\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        Thread.sleep(forTimeInterval: 1.1) // the report must be newer than the start mark
        if let crashed = appPath {
            let escaped = (crashed + "/Contents/MacOS/TerminalDeckNative").replacingOccurrences(of: "/", with: "\\/")
            try "{\"app_name\":\"TerminalDeckNative\"}\n{\n  \"procPath\" : \"\(escaped)\"\n}\n"
                .write(to: reports.appendingPathComponent("TerminalDeckNative-2026-11-01-111810.ips"), atomically: true, encoding: .utf8)
        }
        // A pid that has already ended.
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", CrashRelaunchPolicy.script, "td-crash-watch", "\(gone.processIdentifier)", appPath == "OTHER" ? app : (appPath ?? app),
                             clean_.path, start.path, hist.path, opener.path, "1"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        watcher.environment = environment
        try watcher.run(); watcher.waitUntilExit()
        return (try? String(contentsOf: opened, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @Test func aCrashOfThisCopyOpensItAgainInTheBackground() throws {
        let app = "/Applications/Fake Deck \(UUID().uuidString.prefix(6)).app"
        #expect(try run(clean: false, crashFor: app) == "-g -a \(app)")
    }

    @Test func anOrderlyQuitAForceQuitOrAnotherCopysCrashDoNot() throws {
        let app = "/Applications/Fake Deck \(UUID().uuidString.prefix(6)).app"
        #expect(try run(clean: true, crashFor: app) == "", "orderly quit")
        #expect(try run(clean: false, crashFor: nil) == "", "Force Quit: no crash report")
        #expect(try run(clean: false, crashFor: "OTHER") == "", "a crash report of another copy")
    }

    @Test func neverMoreThanThreeTimesInTenMinutes() throws {
        let app = "/Applications/Fake Deck \(UUID().uuidString.prefix(6)).app"
        let now = Date().timeIntervalSince1970
        #expect(try run(clean: false, crashFor: app, history: [now - 30, now - 90, now - 200]) == "")
        #expect(try run(clean: false, crashFor: app, history: [now - 900, now - 1000]) == "-g -a \(app)")
    }
}
