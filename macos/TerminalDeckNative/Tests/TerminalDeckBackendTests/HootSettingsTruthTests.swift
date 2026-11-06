import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// SETTINGS-TRUTH.md (Tester, 12 Oct), Hoot rows: line 70 (Codex permission choices start; the saved mode is loaded at
/// start), lines 71-74 (Hoot's routines run on Hoot's own AI, model, effort and Who-uses-what account; the old per-Hoot
/// account key never wins). Scratch folders, stub CLIs and fake launches only: no account, no model, no network.
final class HootSettingsTruthTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-settings-truth-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func help(_ provider: HootChatProvider) throws -> String {
        var macos = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { macos.deleteLastPathComponent() }
        return try String(contentsOf: macos.appendingPathComponent("testing/suite/fixtures/" + provider.rawValue + "-help.txt"), encoding: .utf8)
    }
    private func profile(_ id: String, _ provider: String = "claude", system: Bool = false) -> BackendAccountProfile {
        BackendAccountProfile(id: id, name: id, provider: provider, configDir: "/scratch/" + id, system: system, color: "#000000", createdAt: 0)
    }
    /// `seat` first, as the real owner lists Hoot's row of Who uses what first.
    private func owner(_ root: URL, seat: [String: String] = [:], signedOut: Set<String> = []) -> BackendHootReadyDefaults {
        let all = ["claude": [profile("system:claude", system: true), profile("work")],
                   "codex": [profile("system:codex", "codex", system: true)], "gemini": [profile("system:gemini", "gemini", system: true)]]
        return .init(settings: BackendAppSettingsStore(userData: root, writable: true), enabled: true,
                     profiles: { provider, _ in
                         let list = all[provider.rawValue] ?? []
                         guard let first = seat[provider.rawValue], let pick = list.first(where: { $0.id == first }) else { return list }
                         return [pick] + list.filter { $0.id != first }
                     },
                     available: { _ in true }, signedIn: { profile, _ in !signedOut.contains(profile.id) })
    }

    // MARK: Line 70

    func testEveryCodexPermissionChoiceStartsHoot() async throws {
        let root = try scratch(), defaults = owner(root)
        for mode in ["default", "workspace-write", "read-only", "danger-full-access"] {
            _ = try await defaults.save(HootReadyPreferences(provider: .codex, model: "gpt-test", permissionMode: mode).wireValue, projectPath: "/scratch/hoot")
            let chosen = try await defaults.read(projectPath: "/scratch/hoot")
            let flags = try chosen.launchPlan(privateDirectory: root, installedHelp: help(.codex)).arguments
            let plan = try BackendHootChatLaunchPlan(provider: .codex, cwd: root.path, sessionID: nil, extra: flags)
            let session = try XCTUnwrap(plan.setup?.session)
            if mode == "default" {
                XCTAssertTrue(session["approvalPolicy"].isNullish, mode)
            } else {
                XCTAssertEqual(session["sandbox"].string, mode)
                XCTAssertEqual(session["approvalPolicy"].string, mode == "danger-full-access" ? "never" : "on-request", // R39/R73: full bypass never asks.
                    "\(mode): taken as the thread's approval policy, not refused")
            }
        }
        XCTAssertThrowsError(try BackendHootChatLaunchPlan(provider: .codex, cwd: root.path, sessionID: nil, extra: ["--ask-for-approval", "whenever"]))
    }

    func testTheSavedModeIsLoadedAtStartBeforeAnyChatViewAsks() async throws {
        let root = try scratch()
        _ = try await owner(root).save(HootReadyPreferences(provider: .claude, permissionMode: "bypassPermissions").wireValue, projectPath: "/scratch/hoot")
        let restarted = owner(root)
        var bypass = await restarted.bypassOn
        XCTAssertFalse(bypass, "Nothing read yet")
        await restarted.loadSavedMode(projectPath: "/scratch/hoot")
        bypass = await restarted.bypassOn
        XCTAssertTrue(bypass, "Phone and task turns follow Bypass from the start")
        _ = try await restarted.save(HootReadyPreferences(provider: .claude, permissionMode: "plan").wireValue, projectPath: "/scratch/hoot")
        _ = try await restarted.read(projectPath: "/scratch/hoot", forConversation: true)
        let plans = await restarted.plansOnly
        XCTAssertTrue(plans, "Hoot's own launch read follows the saved mode too")
    }

    // MARK: Line 74

    func testTheOldPerHootAccountNeverWinsOverWhoUsesWhat() async throws {
        let root = try scratch(), settings = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await settings.patch(.object([.init("hoot.account.claude", .string("work")), .init("hoot.account.codex", .string("x"))]))
        let defaults = owner(root)
        let read = try await defaults.read(projectPath: "/scratch/hoot")
        XCTAssertEqual(read.profile?.id, "system:claude", "Hoot's row (first) wins; the stale saved key is not read")
        await defaults.removeLegacyAccounts()
        // Read back through a fresh store: the file on disk, not this test's cached copy.
        let reopened = BackendAppSettingsStore(userData: root, writable: true)
        let claude = await reopened.value("hoot.account.claude"), codex = await reopened.value("hoot.account.codex")
        XCTAssertTrue(claude.isNullish && codex.isNullish, "Removed from the settings file")
        _ = try await defaults.save(HootReadyPreferences(provider: .claude, profileID: "work", permissionMode: "plan").wireValue, projectPath: "/scratch/hoot")
        let again = await BackendAppSettingsStore(userData: root, writable: true).value("hoot.account.claude")
        XCTAssertTrue(again.isNullish, "Never written again")
    }

    func testChangingHootsRowRestartsHootButASignedOutRowNeverLoops() async throws {
        let root = try scratch()
        let moved = try await owner(root, seat: ["claude": "work"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(moved.seatAccountID, "work"); XCTAssertEqual(moved.profile?.id, "work")
        XCTAssertTrue(BackendHootChatDriver.deliberateChange(moved, provider: .claude, profileID: "system:claude", settings: moved.launchSettings),
                      "The person moved Hoot's row to Work: Hoot switches on its next message")
        XCTAssertFalse(BackendHootChatDriver.deliberateChange(moved, provider: .claude, profileID: "work", settings: moved.launchSettings))
        let signedOut = try await owner(root, seat: ["claude": "work"], signedOut: ["work"]).read(projectPath: "/scratch/hoot")
        XCTAssertEqual(signedOut.seatAccountID, "work"); XCTAssertEqual(signedOut.profile?.id, "system:claude")
        XCTAssertFalse(BackendHootChatDriver.deliberateChange(signedOut, provider: .claude, profileID: "system:claude", settings: signedOut.launchSettings),
                       "The row's account is signed out: no restart loop")
    }

    // MARK: Lines 71-73: Hoot's routines

    private actor Launched {
        var inputs: [BackendRoutinesLaunchInput] = []
        var released = 0
        func add(_ input: BackendRoutinesLaunchInput) { inputs.append(input) }
        func release() { released += 1 }
    }
    private func request() -> BackendRoutinesRunRequest {
        .init(routine: .init(id: "hoot-check", name: "Morning check", triggers: [.manual], folder: "/work/api", prompt: "Say what is blocked."),
              runId: "run-1", cause: .manual(by: "user"), chain: [], cancellation: .init())
    }
    private func config(_ root: URL) throws -> String {
        let file = root.appendingPathComponent("unattended.json")
        try Data(#"{"mcpServers":{"deck-control":{"type":"http","url":"http://127.0.0.1:40404/mcp","headers":{"Authorization":"Bearer secret-token"}}}}"#.utf8).write(to: file)
        return file.path
    }
    private func runner(_ root: URL, provider: String, model: String?, effort: String?, launched: Launched, answer: String = String(repeating: "Session api is blocked on a question. ", count: 12)) throws -> BackendRoutinesCopilotRunner {
        let configPath = try config(root)
        return BackendRoutinesCopilotRunner(options: .init(mcpConfig: { configPath }, copilotRoot: root,
            environment: ["PATH": "/old", "CLAUDECODE": "1"],
            launch: { input in
                await launched.add(input)
                if let index = input.args.firstIndex(of: "-o"), index + 1 < input.args.count {
                    try Data(answer.utf8).write(to: URL(fileURLWithPath: input.args[index + 1]))
                    return .init(stdout: "", stderr: "", code: 0)
                }
                if provider == "gemini" { return .init(stdout: answer, stderr: "", code: 0) }
                return .init(stdout: NativeRPCValue.object([.init("result", .string(answer))]).compact, stderr: "", code: 0)
            }, actions: BackendRoutinesTestActions(),
            hoot: { inherited in
                .init(provider: provider, command: "/fake/" + provider, model: model, effort: effort,
                      environment: inherited.merging(["PATH": "/login/bin", "CODEX_HOME": "/scratch/seat"]) { _, new in new },
                      release: { await launched.release() })
            }))
    }

    func testARoutineRunsOnHootsClaudeModelEffortAndAccount() async throws {
        let root = try scratch(), launched = Launched()
        let outcome = try await runner(root, provider: "claude", model: "opus", effort: "high", launched: launched).run(request())
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        let inputs = await launched.inputs
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.command, "/fake/claude")
        XCTAssertTrue(input.args.contains("--strict-mcp-config"))
        XCTAssertEqual(input.args.suffix(4), ["--model", "opus", "--effort", "high"])
        XCTAssertEqual(input.env["PATH"], "/login/bin", "The account's own environment")
        let released = await launched.released
        XCTAssertEqual(released, 1, "The account is given back once")
    }

    func testARoutineRunsOnCodexWithTheSameReadOnlyLimits() async throws {
        let root = try scratch(), launched = Launched()
        let outcome = try await runner(root, provider: "codex", model: "gpt-test", effort: "high", launched: launched).run(request())
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        let inputs = await launched.inputs
        let input = try XCTUnwrap(inputs.first), args = input.args
        XCTAssertEqual(input.command, "/fake/codex")
        XCTAssertEqual(Array(args.prefix(5)), ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only"])
        XCTAssertTrue(args.contains("mcp_servers.deck-control.url=\"http://127.0.0.1:40404/mcp\""))
        // #351: the key is in the run's environment, never on its command line.
        XCTAssertTrue(args.contains("mcp_servers.deck-control.bearer_token_env_var=\"\(BackendSessionAppTools.tokenVariable)\""))
        XCTAssertFalse(args.contains { $0.contains("secret-token") }); XCTAssertEqual(input.env[BackendSessionAppTools.tokenVariable], "secret-token")
        XCTAssertTrue(args.contains { $0.hasPrefix("mcp_servers.deck-control.enabled_tools=[\"sessions_list\"") && !$0.contains("settings_write") })
        XCTAssertTrue(args.contains("gpt-test") && args.contains("model_reasoning_effort=\"high\""))
        XCTAssertEqual(args.last, "-", "The prompt goes on standard input")
        XCTAssertTrue(input.stdin.contains("Say what is blocked."))
        XCTAssertEqual(input.env["CODEX_HOME"], "/scratch/seat")
        let runs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path)
        XCTAssertTrue(runs.filter { $0.hasPrefix("answer-") }.isEmpty, "The answer file is removed after the run")
    }

    func testARoutineRunsOnGeminiWithAPrivateSettingsFile() async throws {
        let root = try scratch(), launched = Launched()
        let plan = try BackendRoutinesCopilotRunner.plan(provider: "gemini", mcpConfigPath: try config(root), model: "gemini-3-pro", effort: nil,
                                                          answerFile: "/unused", settingsFile: root.appendingPathComponent("s.json").path)
        XCTAssertEqual(plan.environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"], root.appendingPathComponent("s.json").path)
        let settings = try NativeRPCValue.parseJSON(try XCTUnwrap(plan.files.values.first))
        XCTAssertEqual(settings["mcpServers"]["deck-control"]["httpUrl"].string, "http://127.0.0.1:40404/mcp")
        XCTAssertFalse((settings["mcpServers"]["deck-control"]["includeTools"].elements ?? []).contains(.string("settings_write")))
        XCTAssertFalse((settings["tools"]["core"].elements ?? []).contains(.string("write_file")), "Nothing that writes")
        XCTAssertTrue(plan.args.contains("gemini-3-pro"))
        let outcome = try await runner(root, provider: "gemini", model: "gemini-3-pro", effort: nil, launched: launched).run(request())
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        XCTAssertThrowsError(try BackendRoutinesCopilotRunner.plan(provider: "other", mcpConfigPath: "/x", model: nil, effort: nil, answerFile: "/a", settingsFile: "/s"))
    }

    // MARK: Lines 75 and 76

    /// Fast mode reaches Hoot's routines on Claude Code (and only when Hoot has a choice of its own).
    func testFastModeReachesARoutine() throws {
        let root = try scratch()
        let on = try BackendRoutinesCopilotRunner.plan(provider: "claude", mcpConfigPath: try config(root), model: nil, effort: nil,
                                                        answerFile: "/a", settingsFile: "/s", fastMode: true)
        XCTAssertEqual(Array(on.args.suffix(2)), ["--settings", #"{"fastMode":true}"#])
        let unset = try BackendRoutinesCopilotRunner.plan(provider: "claude", mcpConfigPath: try config(root), model: nil, effort: nil,
                                                           answerFile: "/a", settingsFile: "/s")
        XCTAssertFalse(unset.args.contains("--settings"), "No choice of Hoot's own: the account's own Fast mode stands")
    }

    /// The folder's own instructions (CLAUDE.md) reach Hoot on Codex and Gemini, and nothing is written into the folder.
    func testTheFoldersInstructionsReachCodexAndGemini() throws {
        let root = try scratch()
        try Data("Always answer in Urdu when asked in Urdu.".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        let codex = try BackendHootChatLaunchPlan(provider: .codex, cwd: root.path, sessionID: nil, extra: ["--append-system-prompt", "Hoot's layer."])
        let developer = codex.setup?.session["developerInstructions"].string ?? ""
        XCTAssertTrue(developer.contains("Hoot's layer.") && developer.contains("Always answer in Urdu when asked in Urdu."), developer)
        let gemini = try BackendHootChatLaunchPlan(provider: .gemini, cwd: root.path, sessionID: nil, extra: ["--append-system-prompt", "Hoot's layer."])
        XCTAssertTrue(gemini.setup?.instructions.contains("Always answer in Urdu when asked in Urdu.") == true)
        let claude = try BackendHootChatLaunchPlan(provider: .claude, cwd: root.path, sessionID: nil, extra: [])
        XCTAssertFalse(claude.arguments.joined(separator: " ").contains("Urdu"), "Claude Code reads CLAUDE.md itself")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains("AGENTS.md") || files.contains("GEMINI.md"), "Nothing is written into the folder")
        let empty = try scratch()
        // No file, nothing of the folder's added. Since the rich chat (6 Nov) every chat carries the drawing instruction
        // on purpose: Codex in its developer instructions, Gemini as an optional extra it can start without.
        let none = try BackendHootChatLaunchPlan(provider: .codex, cwd: empty.path, sessionID: nil, extra: [])
        XCTAssertEqual(none.setup?.session["developerInstructions"].string, ChatMarkdown.instruction, "No file, nothing of the folder's added")
        let noneGemini = try BackendHootChatLaunchPlan(provider: .gemini, cwd: empty.path, sessionID: nil, extra: [])
        XCTAssertEqual(noneGemini.setup?.instructions, "")
        XCTAssertEqual(noneGemini.setup?.optionalInstructions, ChatMarkdown.instruction)
    }
}
