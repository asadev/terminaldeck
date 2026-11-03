import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Hoot's quick settings really change how Hoot's CLI is launched (stub CLI = the
/// captured `claude --help` in macos/hootchat), and a change makes the idle Hoot restart.
final class L5HootQuickSettingsTests: XCTestCase {
    private func help(_ provider: HootChatProvider) throws -> String {
        var macos = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { macos.deleteLastPathComponent() }
        return try String(contentsOf: macos.appendingPathComponent("testing/suite/fixtures/" + provider.rawValue + "-help.txt"), encoding: .utf8)
    }
    private func owner(_ root: URL) -> BackendHootReadyDefaults {
        let profiles = HootReadyDefaults.providerOrder.map { provider in
            BackendAccountProfile(id: "system:\(provider.rawValue)", name: provider.rawValue, provider: provider.rawValue,
                                  configDir: "/scratch/\(provider.rawValue)", system: true, color: "#000000", createdAt: 0)
        }
        return .init(settings: BackendAppSettingsStore(userData: root, writable: true), enabled: true,
                     profiles: { provider, _ in profiles.filter { $0.provider == provider.rawValue } },
                     available: { _ in true }, signedIn: { _, _ in true })
    }
    func testModelEffortContextAndPermissionReachTheLaunchArgumentsAndRestartHoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = owner(root)
        let before = try await defaults.read(projectPath: "/scratch/hoot")
        let beforePlan = try before.launchPlan(privateDirectory: root, installedHelp: help(.claude))
        XCTAssertFalse(beforePlan.arguments.contains("--model"), "Nothing chosen: the CLI keeps its own defaults")

        let first = HootReadyPreferences(provider: .claude, model: "opus", effort: "high", permissionMode: "acceptEdits", contextWindow: "1m")
        _ = try await defaults.save(first.wireValue, projectPath: "/scratch/hoot")
        let chosen = try await owner(root).read(projectPath: "/scratch/hoot") // survives a restart of the app
        let plan = try chosen.launchPlan(privateDirectory: root, installedHelp: help(.claude))
        XCTAssertTrue(plan.arguments.contains("opus[1m]"), "1M context becomes Claude Code's [1m] model: \(plan.arguments)")
        XCTAssertTrue(plan.arguments.contains("high"), "\(plan.arguments)")
        XCTAssertTrue(plan.arguments.contains("acceptEdits"), "\(plan.arguments)")
        XCTAssertTrue(BackendHootChatDriver.deliberateChange(chosen, provider: .claude, profileID: "system:claude", settings: before.launchSettings),
                      "A changed choice restarts the idle Hoot with the new arguments")

        let second = HootReadyPreferences(provider: .claude, model: "sonnet", effort: "low", permissionMode: "plan", contextWindow: nil)
        _ = try await defaults.save(second.wireValue, projectPath: "/scratch/hoot")
        let next = try await defaults.read(projectPath: "/scratch/hoot")
        let nextPlan = try next.launchPlan(privateDirectory: root, installedHelp: help(.claude))
        XCTAssertTrue(nextPlan.arguments.contains("sonnet[1m]"), "\(nextPlan.arguments)")
        XCTAssertTrue(nextPlan.arguments.contains("low") && nextPlan.arguments.contains("plan"), "\(nextPlan.arguments)")
        XCTAssertNotEqual(plan.arguments, nextPlan.arguments)
        XCTAssertTrue(BackendHootChatDriver.deliberateChange(next, provider: .claude, profileID: "system:claude", settings: chosen.launchSettings))
        XCTAssertFalse(BackendHootChatDriver.deliberateChange(next, provider: .claude, profileID: "system:claude", settings: next.launchSettings),
                       "No change, no restart")
    }
    func testOneMillionIsRefusedForModelsWithoutIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await owner(root).save(HootReadyPreferences(provider: .claude, model: "haiku", contextWindow: "1m").wireValue, projectPath: "/scratch/hoot")
            XCTFail("Haiku has no 1M window")
        } catch {}
        do {
            _ = try await owner(root).save(HootReadyPreferences(provider: .codex, model: "gpt-test", permissionMode: "acceptEdits").wireValue, projectPath: "/scratch/hoot")
            XCTFail("A Claude permission mode is not a Codex one")
        } catch {}
    }
    func testCodexPickerComesFromTheInstalledCLIAndLargestWindowReachesLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-" + UUID().uuidString)
        let home = root.appendingPathComponent("home/.codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A stub of Codex's own model list, as the installed CLI writes it.
        let cache = #"{"models":[{"slug":"gpt-stub-sol","display_name":"GPT Stub Sol","visibility":"list","context_window":272000,"max_context_window":872000,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"gpt-hidden","visibility":"hide","context_window":1000}]}"#
        try Data(cache.utf8).write(to: home.appendingPathComponent("models_cache.json"))
        let defaults = owner(root)
        await defaults.setModelHome(root.appendingPathComponent("home"))
        let read = try await defaults.read(projectPath: "/scratch/hoot")
        // The catalogue is one object per AI: its models, plus which are featured.
        let codex = read.catalog["codex"]["models"].elements ?? []
        XCTAssertEqual(codex.compactMap { $0["id"].string }, ["gpt-stub-sol"], "Only the CLI's listed models are offered")
        XCTAssertEqual(codex.first?["efforts"].elements?.compactMap(\.string), ["low", "high"])
        XCTAssertEqual(read.catalog["gemini"]["models"].elements?.isEmpty ?? true, true, "No written list: Gemini offers only what it reports itself")
        _ = try await defaults.save(HootReadyPreferences(provider: .codex, model: "gpt-stub-sol", effort: "high", contextWindow: "max").wireValue, projectPath: "/scratch/hoot")
        let chosen = try await defaults.read(projectPath: "/scratch/hoot")
        let plan = try chosen.launchPlan(privateDirectory: root, installedHelp: help(.codex))
        XCTAssertTrue(plan.arguments.contains("model_context_window=872000"), "\(plan.arguments)")
        XCTAssertTrue(plan.arguments.contains("gpt-stub-sol"), "\(plan.arguments)")
        do {
            _ = try await defaults.save(HootReadyPreferences(provider: .codex, model: "gpt-unknown", contextWindow: "max").wireValue, projectPath: "/scratch/hoot")
            XCTFail("No larger window is known for that model")
        } catch {}
    }
    func testEveryPermissionModeChangesLaunchAndHostAnswersWithoutACard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = owner(root)
        var seen: [String: [String]] = [:]
        for mode in ["default", "acceptEdits", "plan", "bypassPermissions"] {
            _ = try await defaults.save(HootReadyPreferences(provider: .claude, permissionMode: mode).wireValue, projectPath: "/scratch/hoot")
            let chosen = try await defaults.read(projectPath: "/scratch/hoot")
            XCTAssertEqual(chosen.permissionPolicy, mode)
            seen[mode] = try chosen.launchPlan(privateDirectory: root, installedHelp: help(.claude)).arguments
        }
        XCTAssertFalse(seen["default"]!.contains("--permission-mode"))
        XCTAssertEqual(seen["acceptEdits"], ["--effort", "xhigh", "--permission-mode", "acceptEdits"])
        XCTAssertEqual(seen["plan"], ["--effort", "xhigh", "--permission-mode", "plan"])
        XCTAssertEqual(seen["bypassPermissions"], ["--effort", "xhigh", "--permission-mode", "acceptEdits"], "Claude's host prompts refuse bypassPermissions; the host approves the rest")
        _ = try await defaults.save(HootReadyPreferences(provider: .codex, model: "gpt-test", permissionMode: "danger-full-access").wireValue, projectPath: "/scratch/hoot")
        let codex = try await defaults.read(projectPath: "/scratch/hoot")
        XCTAssertTrue(try codex.launchPlan(privateDirectory: root, installedHelp: help(.codex)).arguments.contains("danger-full-access"))

        // A write under Auto, and anything under Bypass, is answered by the host: no card.
        let write = NativeRPCValue.object([.init("subtype", .string("can_use_tool")), .init("name", .string("Write")), .init("input", .object([]))])
        let shell = NativeRPCValue.object([.init("subtype", .string("can_use_tool")), .init("name", .string("Bash")), .init("input", .object([]))])
        XCTAssertTrue(BackendHootChatStore.autoAllows(mode: "acceptEdits", provider: .claude, request: write))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "acceptEdits", provider: .claude, request: shell), "Auto still asks before commands")
        XCTAssertTrue(BackendHootChatStore.autoAllows(mode: "bypassPermissions", provider: .claude, request: shell))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "default", provider: .claude, request: write))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: nil, provider: .claude, request: write))
        let form = NativeRPCValue.object([.init("subtype", .string("mcpServer/elicitation/request")), .init("input", .object([]))])
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: form), "Questions always reach the person")
        XCTAssertTrue(BackendHootChatStore.autoAllows(mode: "workspace-write", provider: .codex,
            request: .object([.init("subtype", .string("item/fileChange/requestApproval")), .init("input", .object([]))])))
    }
    func testAChangedChoiceRestartsEvenWhenThisMomentsSignInCheckIsSlow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = BackendAccountProfile(id: "system:claude", name: "claude", provider: "claude", configDir: "/scratch/claude", system: true, color: "#000000", createdAt: 0)
        let slow = BackendHootReadyDefaults(settings: BackendAppSettingsStore(userData: root, writable: true), enabled: true,
            profiles: { provider, _ in provider == .claude ? [profile] : [] }, available: { _ in true }, signedIn: { _, _ in false })
        _ = try await slow.save(HootReadyPreferences(provider: .claude, profileID: "system:claude", permissionMode: "acceptEdits").wireValue, projectPath: "/scratch/hoot")
        let selected = try await slow.read(projectPath: "/scratch/hoot")
        XCTAssertFalse(selected.ready)
        XCTAssertTrue(BackendHootChatDriver.deliberateChange(selected, provider: .claude, profileID: "system:claude",
            settings: AGSAgentSettings(provider: "claude")), "Auto chosen in Settings restarts Hoot with it")
    }
    /// Real pipes with the fake Codex CLI: under Bypass its command approval is answered by the
    /// host (accept) and the turn finishes with nothing waiting for a card.
    func testBypassAnswersARealCLIApprovalWithoutACard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L5Hoot-pipes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = URL(fileURLWithPath: #filePath); for _ in 0..<4 { source.deleteLastPathComponent() }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .codex)
        await store.setPermissionPolicy("danger-full-access")
        try await store.attach(.init(command: "/usr/bin/python3", arguments: [source.appendingPathComponent("testing/suite/fixtures/HootFakeRPC.py").path, "codex"],
            cwd: root.path, environment: [:], setup: .init(cwd: root.path)))
        try await store.initialize(); _ = try await store.say("do the write")
        let deadline = Date().addingTimeInterval(10)
        while await store.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let busy = await store.isBusy
        XCTAssertFalse(busy, "The turn finished without waiting for a person")
        let pending = await store.snapshot()["pending"].elements?.count ?? 0
        XCTAssertEqual(pending, 0)
        await store.stop()
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let answers = requests.filter { $0["method"].isNullish && $0["id"].number == 7 }
        XCTAssertEqual(answers.first?["result"]["decision"].string, "accept")
    }
}
