import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor IslandCounts {
    var profiles = 0, signIns = 0, installed = 0
    func listed() { profiles += 1 }
    func signedIn() { signIns += 1 }
    func checkedInstall() { installed += 1 }
    var all: Int { profiles + signIns + installed }
}

/// #26 (3 Nov, Tester, install-25-final-check "For Decker" 2): Hoot's island re-read Claude's settings files, every
/// account and its sign-in on every app event (about two a second while agents work, ~10 % of a core in the debug
/// build). The files are now read once and watched; the live Hoot's check is answered from memory until something it
/// needs changes.
final class HootIslandQuietTests: XCTestCase {
    private func scratch(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-26-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }
    /// Waits for a watched change to arrive (the watcher folds a burst into one check after 250 ms).
    private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("never happened: " + what)
    }
    private func cpuMilliseconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }
    private func claudeHome(_ home: URL, model: String = "opus", stateBytes: Int = 0) throws {
        try write(#"{"model":"\#(model)","fastMode":true}"#, home.appendingPathComponent(".claude/settings.json"))
        // His ~/.claude.json is about 150 KB of project records; the measurement uses one that size.
        var projects: [String] = []
        var size = 0, index = 0
        while size < stateBytes {
            let row = #""/Users/someone/Projects/project-\#(index)":{"allowedTools":[],"history":[],"mcpServers":{},"enabledMcpjsonServers":[],"disabledMcpjsonServers":[],"hasTrustDialogAccepted":true,"projectOnboardingSeenCount":3,"hasClaudeMdExternalIncludesApproved":false,"lastCost":0.4213,"lastAPIDuration":81234,"lastDuration":912345,"lastLinesAdded":120,"lastLinesRemoved":33,"lastTotalInputTokens":123456,"lastTotalOutputTokens":23456,"lastSessionId":"0f6c6a1e-6f3e-4c1e-9f7a-\#(String(format: "%012d", index))"}"#
            projects.append(row); size += row.utf8.count; index += 1
        }
        try write(#"{"numStartups":412,"penguinModeOrgEnabled":true,"projects":{\#(projects.joined(separator: ","))}}"#, home.appendingPathComponent(".claude.json"))
    }

    func testTheCLIFilesAreReadOnceAndAgainOnlyWhenOneChanges() async throws {
        let home = try scratch("files"); defer { try? FileManager.default.removeItem(at: home) }
        try claudeHome(home)
        try write(#"{"models":[{"slug":"gpt-stub","display_name":"GPT Stub","visibility":"list","context_window":272000}]}"#,
                  home.appendingPathComponent(".codex/models_cache.json"))
        let files = BackendHootModelSource.LocalFiles.at(home)
        for _ in 0..<50 {
            _ = BackendHootModelSource.claudeSettings(home: home); _ = BackendHootModelSource.codex(home: home)
            _ = BackendHootModelSource.codexConfiguredModel(home: home)
        }
        XCTAssertEqual(files.diskReads, 4, "two Claude files, Codex's list and its (missing) config: once each for 150 asks")
        let settings = BackendHootModelSource.claudeSettings(home: home)
        XCTAssertEqual(settings.model, "opus"); XCTAssertTrue(settings.fastAvailable); XCTAssertTrue(settings.fastOn)
        XCTAssertEqual(BackendHootModelSource.codex(home: home).map(\.id), ["gpt-stub"])
        XCTAssertNil(BackendHootModelSource.codexConfiguredModel(home: home))

        // Claude's settings change: only they are read again, once.
        try write(#"{"model":"sonnet"}"#, home.appendingPathComponent(".claude/settings.json"))
        try await eventually("the new Claude model is seen") { BackendHootModelSource.claudeSettings(home: home).model == "sonnet" }
        _ = BackendHootModelSource.codex(home: home)
        XCTAssertEqual(files.diskReads, 6, "the change re-read the two Claude files only")
        XCTAssertFalse(BackendHootModelSource.claudeSettings(home: home).fastOn)

        // A file that did not exist is seen when it is created.
        try write("model = \"gpt-new\"\n", home.appendingPathComponent(".codex/config.toml"))
        try await eventually("Codex's new config is seen") { BackendHootModelSource.codexConfiguredModel(home: home) == "gpt-new" }
        // Unrelated files in the same folders cost no read.
        let settled = files.diskReads
        try write("{}", home.appendingPathComponent("unrelated.json"))
        try write("{}", home.appendingPathComponent(".claude/other.json"))
        try await Task.sleep(for: .milliseconds(600))
        for _ in 0..<20 { _ = BackendHootModelSource.claudeSettings(home: home); _ = BackendHootModelSource.codexConfiguredModel(home: home) }
        XCTAssertEqual(files.diskReads, settled, "files nobody reads changed: nothing is read again")
    }

    func testTheLiveCheckIsAnsweredFromMemoryUntilSomethingItNeedsChanges() async throws {
        let root = try scratch("live"); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"); try claudeHome(home)
        let settings = BackendAppSettingsStore(userData: root, writable: true), counts = IslandCounts()
        let accountFile = root.appendingPathComponent("profiles.json")
        let defaults = BackendHootReadyDefaults(settings: settings, enabled: true, accountFiles: [accountFile], profiles: { provider, _ in
            await counts.listed()
            return [.init(id: "system:" + provider.rawValue, name: provider.rawValue, provider: provider.rawValue,
                          configDir: home.path, system: true, color: "#000000", createdAt: 0)]
        }, available: { _ in await counts.checkedInstall(); return true }, signedIn: { _, _ in await counts.signedIn(); return true })
        await defaults.setModelHome(home)
        let folder = root.path

        let first = try await defaults.liveCheck(projectPath: folder)
        XCTAssertEqual(first.provider, .claude)
        let afterFirst = await counts.all
        XCTAssertEqual(afterFirst, 9, "one look at each AI's accounts, install and sign-in")
        for _ in 0..<120 { _ = try await defaults.liveCheck(projectPath: folder) }   // one minute of events at two a second
        let afterMinute = await counts.all
        XCTAssertEqual(afterMinute, afterFirst, "unrelated events read nothing")
        XCTAssertEqual(BackendHootModelSource.LocalFiles.at(home).diskReads, 0, "the check needs no model list, so no CLI file is read")

        // Hoot's saved choice changes: the very next check sees it (the settings store tells before the write returns).
        _ = try await settings.patch(.object([.init("hoot.model.claude", .string("claude-test-model"))]))
        let changed = try await defaults.liveCheck(projectPath: folder)
        XCTAssertEqual(changed.preferences.model, "claude-test-model")
        let afterSetting = await counts.all
        XCTAssertEqual(afterSetting, afterFirst + 9)

        // The app's account file (accounts, Who uses what) changes: seen once the watcher has folded the write.
        try write(#"{"profiles":[]}"#, accountFile)
        try await eventually("the account file change is seen") {
            _ = try await defaults.liveCheck(projectPath: folder)
            return await counts.all == afterSetting + 9
        }
        for _ in 0..<20 { _ = try await defaults.liveCheck(projectPath: folder) }
        let afterAccounts = await counts.all
        XCTAssertEqual(afterAccounts, afterSetting + 9, "and only once")

        // This chat's own options change.
        await defaults.resetChatOptions()
        _ = try await defaults.liveCheck(projectPath: folder)
        let afterReset = await counts.all
        XCTAssertEqual(afterReset, afterAccounts + 9)

        // Every other reader still reads fresh each time.
        _ = try await defaults.read(projectPath: folder, forConversation: true)
        let afterRead = await counts.all
        XCTAssertEqual(afterRead, afterReset + 9)
    }

    /// The before/after numbers for hoot-26-result.md: one minute of island events (two a second) against a home
    /// with a 150 KB ~/.claude.json. Before = what each event did at bc724b88 (installed #25): read and parse the four
    /// CLI files, Hoot's Home report, and every account through `read`. After = `liveCheck`.
    func testOneMinuteOfIslandEventsBeforeAndAfter() async throws {
        let root = try scratch("measure"); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"); try claudeHome(home, stateBytes: 150_000)
        let codexRow = #"{"slug":"gpt-stub-N","display_name":"GPT Stub N","visibility":"list","context_window":272000,"max_context_window":1000000,"supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}"#
        try write(#"{"models":[\#((0..<12).map { codexRow.replacingOccurrences(of: "-N", with: "-\($0)") }.joined(separator: ","))]}"#, home.appendingPathComponent(".codex/models_cache.json"))
        try write("model = \"gpt-stub-1\"\nmodel_reasoning_effort = \"high\"\n", home.appendingPathComponent(".codex/config.toml"))
        let settings = BackendAppSettingsStore(userData: root, writable: true), counts = IslandCounts()
        let defaults = BackendHootReadyDefaults(settings: settings, enabled: true, accountFiles: [root.appendingPathComponent("profiles.json")], profiles: { provider, _ in
            await counts.listed()
            return [.init(id: "system:" + provider.rawValue, name: provider.rawValue, provider: provider.rawValue,
                          configDir: home.path, system: true, color: "#000000", createdAt: 0)]
        }, available: { _ in await counts.checkedInstall(); return true }, signedIn: { _, _ in await counts.signedIn(); return true })
        await defaults.setModelHome(home)
        let paths = BackendCopilotPaths(userData: root.path)
        let events = 120
        let stateSize = (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude.json").path)[.size] as? Int) ?? 0

        _ = try await defaults.read(projectPath: root.path, forConversation: true)   // warm both paths once
        _ = try await defaults.liveCheck(projectPath: root.path)
        let beforeAccounts0 = await counts.all, beforeCPU0 = cpuMilliseconds()
        var beforeFiles = 0
        for _ in 0..<events {
            _ = BackendHootModelSource.readClaudeSettings(home: home); _ = BackendHootModelSource.readCodex(home: home)
            _ = BackendHootModelSource.readCodexConfiguredModel(home: home); beforeFiles += 4
            _ = BackendCopilotHome.report(paths)
            _ = try await defaults.read(projectPath: root.path, forConversation: true)
        }
        let beforeCPU = cpuMilliseconds() - beforeCPU0
        let beforeAccounts = await counts.all - beforeAccounts0

        let files = BackendHootModelSource.LocalFiles.at(home), afterFiles0 = files.diskReads
        let afterAccounts0 = await counts.all, afterCPU0 = cpuMilliseconds()
        for _ in 0..<events { _ = try await defaults.liveCheck(projectPath: root.path) }
        let afterCPU = cpuMilliseconds() - afterCPU0
        let afterAccounts = await counts.all - afterAccounts0, afterFiles = files.diskReads - afterFiles0

        func share(_ ms: Double) -> String { String(format: "%.2f%% of one core", ms / 60_000 * 100) }
        print("HOOT-26 MEASURE: \(events) island events in one minute (two a second), ~/.claude.json \(stateSize) bytes")
        print("HOOT-26 MEASURE: CLI settings/model files read and parsed: before \(beforeFiles)/min, after \(afterFiles)/min")
        print("HOOT-26 MEASURE: account, install and sign-in look-ups: before \(beforeAccounts)/min, after \(afterAccounts)/min")
        print("HOOT-26 MEASURE: CPU for that minute: before " + String(format: "%.0f", beforeCPU) + " ms (\(share(beforeCPU))), after "
              + String(format: "%.1f", afterCPU) + " ms (\(share(afterCPU)))")
        XCTAssertEqual(afterFiles, 0); XCTAssertEqual(afterAccounts, 0)
        XCTAssertEqual(beforeAccounts, events * 9)
        XCTAssertLessThan(afterCPU, beforeCPU)
    }
}
