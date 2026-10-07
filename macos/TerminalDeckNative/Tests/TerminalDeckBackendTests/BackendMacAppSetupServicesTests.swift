import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppSetupServicesTests: XCTestCase {
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    private func prereq(_ tools: [NativeRPCValue]? = nil) -> NativeRPCValue { o([("canRunSessions", .bool(true)), ("needsLogin", .bool(false)), ("tools", .array(tools ?? [tool("claude", "ready"), tool("codex", "missing"), tool("gemini", "ready"), tool("git", "ready")]))]) }
    private func tool(_ id: String, _ state: String) -> NativeRPCValue { o([("id", .string(id)), ("label", .string(id)), ("state", .string(state)), ("purpose", .string("")), ("required", .bool(false))]) }
    private func hook(_ id: String) -> NativeRPCValue { o([("id", .string(id)), ("label", .string(id)), ("state", .string("none")), ("file", .string("/home/\(id)/settings.json")), ("fileExists", .bool(true)), ("installedEvents", .array([])), ("staleEvents", .array([])), ("missingEvents", .array((BackendSessionHookInstallation.events[id] ?? []).map(NativeRPCValue.string))), ("foreignHooks", .number(0)), ("foreignOwners", .array([])), ("message", .string("No hooks from this app in this file yet."))]) }
    private func build(prerequisites: NativeRPCValue? = nil, copilot: NativeRPCValue? = nil, hooks: [NativeRPCValue]? = nil, endpoint: NativeRPCValue? = .object([.init("socketPath", .string("/tmp/test/hook.sock")), .init("token", .string("never-returned"))])) -> NativeRPCValue {
        let probe = o([("command", .string("which codex")), ("line", .string("codex not found"))])
        return BackendMacAppSetupSnapshot.compose(prerequisites: prerequisites ?? prereq(), copilot: copilot ?? o([("state", .string("missing")), ("probe", o([("command", .string("which copilot")), ("line", .string("copilot not found"))]))]), probes: o([("codex", probe)]), hooks: hooks ?? [hook("claude"), hook("codex"), hook("gemini")], endpoint: endpoint, now: 1)
    }
    func testSupportedToolsHaveOneOrder() { XCTAssertEqual(build()["tools"].elements!.compactMap { $0["id"].string }, BackendMacAppSetupSnapshot.toolIDs) }
    func testLiteralProbeAppearsOnlyForMissingTool() { let tools = build()["tools"].elements!; XCTAssertEqual(tools.first { $0["id"].string == "codex" }?["probe"]["line"], .string("codex not found")); XCTAssertEqual(tools.first { $0["id"].string == "claude" }?["probe"], .null) }
    func testFailedLaunchEvidenceWinsOverLookup() { let bad = tool("codex", "missing").setting("evidence", .string("Error: spawn /opt/homebrew/.../codex ENOENT")); let row = build(prerequisites: prereq([bad]))["tools"].elements!.first { $0["id"].string == "codex" }!; XCTAssertTrue(row["probe"]["line"].string!.contains("ENOENT")); XCTAssertEqual(row["probe"]["command"], .string("codex --version")) }
    func testWorkingToolRetainsAlternatePathCaveat() { let row = build(prerequisites: prereq([tool("claude", "ready").setting("note", .string("Runs from /elsewhere/claude."))]))["tools"].elements!.first { $0["id"].string == "claude" }!; XCTAssertEqual(row["note"], .string("Runs from /elsewhere/claude.")) }
    func testCopilotGhRouteDoesNotDisplayContradictoryLookup() { let row = build(copilot: o([("state", .string("ready")), ("route", .string("gh-extension")), ("probe", o([("line", .string("copilot not found"))]))]))["tools"].elements!.first { $0["id"].string == "copilot" }!; XCTAssertEqual(row["state"], .string("ready")); XCTAssertEqual(row["probe"], .null) }
    func testCopilotIsDetectedOnly() { XCTAssertTrue(build()["tools"].elements!.first { $0["id"].string == "copilot" }!["note"].string!.contains("Detected only")) }
    func testUnmentionedToolsStayPresentAndUnknown() { let tools = build(prerequisites: prereq([]))["tools"].elements!; XCTAssertEqual(tools.compactMap { $0["id"].string }, BackendMacAppSetupSnapshot.toolIDs); XCTAssertEqual(tools[0]["state"], .string("unknown")) }
    func testHookEventsStayInLifecycleOrder() { let hooks = build()["hooks"].elements!; for hook in hooks { XCTAssertEqual(hook["events"].elements!.compactMap(\.string), BackendSessionHookInstallation.events[hook["id"].string!]!) }; XCTAssertTrue(hooks.first { $0["id"].string == "gemini" }!["events"].elements!.contains(.string("AfterTool"))); XCTAssertEqual(hooks.first { $0["id"].string == "codex" }!["events"].elements!.count, 5) }
    func testCodexRequirementUsesCurrentFlagAndTrust() { let text = build()["hooks"].elements!.first { $0["id"].string == "codex" }!["requirement"].string!; XCTAssertTrue(text.contains("`hooks = true`")); XCTAssertFalse(text.contains("codex_hooks")); XCTAssertTrue(text.contains("Trust")) }
    func testCopilotHasRowAndNoRedundantHookBlock() { let result = build(); XCTAssertFalse(result["hooks"].elements!.contains { $0["id"].string == "copilot" }); XCTAssertTrue(result["tools"].elements!.first { $0["id"].string == "copilot" }!["note"].string!.contains("no session-hook configuration")) }
    func testHookReportedCountsAreNotRecounted() { let raw = hook("claude").setting("state", .string("stale")).setting("installedEvents", .array([.string("SessionStart")])).setting("staleEvents", .array([.string("Stop")])).setting("missingEvents", .array([])); let row = build(hooks: [raw])["hooks"].elements![0]; XCTAssertEqual(row["state"], .string("stale")); XCTAssertEqual(row["installedEvents"], raw["installedEvents"]); XCTAssertEqual(row["staleEvents"], raw["staleEvents"]) }
    func testEndpointExposesAddressAndNeverToken() { let endpoint = build()["endpoint"]; XCTAssertEqual(endpoint.fields!.map(\.key).sorted(), ["address", "running"]); XCTAssertEqual(endpoint["address"], .string("/tmp/test/hook.sock")); XCTAssertFalse(endpoint.compact.contains("never-returned")) }
    func testAbsentEndpointIsExplicitlyNotRunning() { XCTAssertEqual(build(endpoint: nil)["endpoint"], o([("running", .bool(false)), ("address", .null)])) }
    actor Detection: BackendMacAppSetupDetection {
        let authSize: Int?, keychain: Bool, agents: [String: BackendNativeProviders.Binary]
        var commands: [(String, [String], Int)] = []
        init(authSize: Int? = nil, keychain: Bool = false, agents: [String: BackendNativeProviders.Binary] = [:]) { self.authSize = authSize; self.keychain = keychain; self.agents = agents }
        func loginPath() async throws -> String { "/fake/bin:/usr/bin" }
        func binary(_ id: String, path: String) async throws -> BackendNativeProviders.Binary? { agents[id] }
        func credentialFileSize() async throws -> Int? { authSize }
        func keychainCredentialExists() async throws -> Bool { keychain }
        func command(_ name: String, arguments: [String], path: String, timeoutMs: Int) async throws -> NativeRPCValue { commands.append((name, arguments, timeoutMs)); return .object([.init("ok", .bool(false)), .init("stdout", .string(""))]) }
        func hookStatuses() async throws -> [NativeRPCValue] { [] }
        func calls() -> [(String, [String], Int)] { commands }
    }
    func testClaudeCredentialFileAndKeychainStates() async throws { let file = try await BackendMacAppSetupPrerequisites.authState("claude", detection: Detection(authSize: 1)), keychain = try await BackendMacAppSetupPrerequisites.authState("claude", detection: Detection(keychain: true)), absent = try await BackendMacAppSetupPrerequisites.authState("claude", detection: Detection()), codex = try await BackendMacAppSetupPrerequisites.authState("codex", detection: Detection()); XCTAssertEqual(file, "ready"); XCTAssertEqual(keychain, "ready"); XCTAssertEqual(absent, "installed-not-authed"); XCTAssertEqual(codex, "ready") }
    func testMissingCLIsHaveExactInstallRemediesAndNoSessionVote() async throws { let detection = Detection(), result = try await BackendMacAppSetupPrerequisites.check(detection); XCTAssertEqual(result["canRunSessions"], .bool(false)); XCTAssertEqual(result["needsLogin"], .bool(false)); XCTAssertEqual(result["tools"].elements![0]["remedy"], .string("Claude Code is not installed. Install it with `npm install -g @anthropic-ai/claude-code`, then check again.")); let calls = await detection.calls(); XCTAssertTrue(calls.allSatisfy { $0.2 == 4000 }) }
}
