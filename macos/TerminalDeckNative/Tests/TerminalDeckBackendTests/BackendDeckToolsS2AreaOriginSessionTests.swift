import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The MCP provider stand-in for agents-area-control.test.ts: `add` answers like
/// the source fake (`{ ok: true, message: 'Added.' }`); the resolver hands the
/// request back unchanged; everything else is the real "unavailable" provider.
struct BackendDeckToolsS2AreaOriginMCPProvider: BackendDeckCoreEventsMCPProvider {
    private let off = BackendDeckCoreEventsUnavailableMCPProvider()
    func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String { path }
    func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue { request }
    func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue { try off.resolveEdit(request) }
    func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue { try off.resolveRemove(request) }
    func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue { try off.resolveInstall(request) }
    func list(projectPath: String?) async throws -> [NativeRPCValue] { try await off.list(projectPath: projectPath) }
    func add(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        .object([.init("ok", .bool(true)), .init("message", .string("Added."))])
    }
    func edit(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await off.edit(request) }
    func remove(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await off.remove(request) }
    func inventory(id: String, projectPath: String?) async throws -> NativeRPCValue { try await off.inventory(id: id, projectPath: projectPath) }
    func disconnect(id: String) async throws -> NativeRPCValue? { try await off.disconnect(id: id) }
    func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async throws -> NativeRPCValue {
        try await off.call(id: id, tool: tool, arguments: arguments, projectPath: projectPath)
    }
    func store(projectPath: String?) async throws -> NativeRPCValue { try await off.store(projectPath: projectPath) }
    func install(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await off.install(request) }
    func toolFile(name: String, scope: String, projectPath: String?) async throws -> NativeRPCValue? {
        try await off.toolFile(name: name, scope: scope, projectPath: projectPath)
    }
}

/// agents-area-control.test.ts:77, session-app-origin.test.ts and
/// session-provenance.test.ts, through the real central gate
/// (BackendDeckCoreSecurityControl + built-in catalogue + real action log),
/// with the shared fake surface and real access keys. No sleeps, no network.
final class BackendDeckToolsS2AreaOriginSessionTests: BackendDeckCoreTestPortSecurityCase {
    // MARK: agents-area-control.test.ts

    // agents-area-control.test.ts:77
    func testAgentsAreaControlL77MCPServerEnvironmentStaysOutOfTheLogOneLevelDown() async throws {
        let mcp = try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckToolsS2AreaOriginMCPProvider())
        let f = try rig(approval: .allow, extras: mcp)
        let result = await f.call("mcp_add", o([
            ("name", .string("github")), ("scope", .string("user")), ("transport", .string("stdio")), ("command", .string("npx -y srv")),
            ("env", o([("GITHUB_PERSONAL_ACCESS_TOKEN", .string("ghp_do_not_log_me"))])),
        ]))
        XCTAssertTrue(result.ok, result.error ?? "")
        let logFile = await f.log.file
        let text = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertFalse(text.contains("ghp_do_not_log_me"))
        XCTAssertTrue(text.contains("GITHUB_PERSONAL_ACCESS_TOKEN"))
    }

    // MARK: session-app-origin.test.ts

    private func keyCaller(_ id: String, _ name: String) -> BackendDeckCoreSecurityCaller {
        BackendDeckCoreSecurityCaller(kind: .key, tiers: BackendDeckCoreSecurityAccessKeys.tiersFor("work"), keyID: id, keyName: name, askFirst: true)
    }
    /// keyRig's folders: the fake app has /work/api and /work/site open. Approval
    /// stays `.absent`, which is `approver: false` — no window to ask.
    private func appRig() throws -> BackendDeckCoreTestPortSecurityRig {
        let f = try rig(); f.surface.projects = ["/work/api", "/work/site"]; return f
    }
    /// `rig.key('work', { name })`: a real Work key, its id handed back.
    private func workKey(_ keys: BackendDeckCoreSecurityAccessKeys, _ name: String) async throws -> String {
        let created = try await made(keys, name: name, level: "work")
        return try XCTUnwrap(created["view"]["id"].string)
    }
    private func list(_ f: BackendDeckCoreTestPortSecurityRig, _ caller: BackendDeckCoreSecurityCaller) async -> [NativeRPCValue] {
        await f.call("sessions.list", .object([]), .init(caller: caller)).value["sessions"].elements ?? []
    }
    private func site(_ sessions: [NativeRPCValue]) -> NativeRPCValue? { sessions.first { $0["cwd"] == .string("/work/site") } }

    // session-app-origin.test.ts:43
    func testSessionAppOriginL43IsWrittenDownAsThatAppsByItsKeysName() async throws {
        let f = try appRig(), keys = BackendDeckCoreSecurityAccessKeys(directory: try scratch())
        let id = try await workKey(keys, "E2E test (Claude)")
        let result = await f.call("sessions.start", o([("cwd", .string("/work/site"))]), .init(caller: keyCaller(id, "E2E test (Claude)")))
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(f.surface.starts.first?["origin"], .string("app"))
        XCTAssertEqual(f.surface.starts.first?["originApp"], .string("E2E test (Claude)"))
    }

    // session-app-origin.test.ts:50
    func testSessionAppOriginL50IsListedAsStartedByThatAppToTheAppAndToTheCopilot() async throws {
        let f = try appRig(), keys = BackendDeckCoreSecurityAccessKeys(directory: try scratch())
        let id = try await workKey(keys, "E2E test (Claude)"), app = keyCaller(id, "E2E test (Claude)")
        _ = await f.call("sessions.start", o([("cwd", .string("/work/site"))]), .init(caller: app))
        for caller in [app, BackendDeckCoreSecurityCaller.local] {
            let started = site(await list(f, caller))
            XCTAssertEqual(started?["startedByCopilot"], .bool(false), caller.kind.rawValue)
            XCTAssertEqual(started?["startedByApp"], .string("E2E test (Claude)"), caller.kind.rawValue)
        }
    }

    // session-app-origin.test.ts:60
    func testSessionAppOriginL60LeavesTheCopilotsOwnSessionsAsTheCopilots() async throws {
        let f = try appRig()
        _ = await f.call("sessions.start", o([("cwd", .string("/work/site"))]))
        XCTAssertEqual(f.surface.starts.first?["origin"], .string("copilot"))
        XCTAssertEqual(f.surface.starts.first?.has("originApp"), false)
        let started = site(await list(f, .local))
        XCTAssertEqual(started?["startedByCopilot"], .bool(true))
        XCTAssertEqual(started?["startedByApp"], .null)
    }

    // session-app-origin.test.ts:68
    func testSessionAppOriginL68TypedIntoByTheStartingAppAndOnlyByAskingForAnyoneElse() async throws {
        let f = try appRig(), keys = BackendDeckCoreSecurityAccessKeys(directory: try scratch())
        let one = try await workKey(keys, "One"), two = try await workKey(keys, "Two")
        _ = await f.call("sessions.start", o([("cwd", .string("/work/site"))]), .init(caller: keyCaller(one, "One")))
        let sessionId = site(await list(f, .local))?["id"].string ?? ""

        let own = await f.call("sessions.send", o([("sessionId", .string(sessionId)), ("text", .string("hello"))]), .init(caller: keyCaller(one, "One")))
        XCTAssertEqual(own.row["tier"], .string("act"))
        let other = await f.call("sessions.send", o([("sessionId", .string(sessionId)), ("text", .string("hi"))]), .init(caller: keyCaller(two, "Two")))
        XCTAssertEqual(other.row["tier"], .string("alter"))
        XCTAssertEqual(other.refusal, .notGranted)
        let copilot = await f.call("sessions.send", o([("sessionId", .string(sessionId)), ("text", .string("hi"))]))
        XCTAssertEqual(copilot.row["tier"], .string("alter"))
        XCTAssertEqual(copilot.refusal, .noApprover)
    }

    // session-app-origin.test.ts:91
    func testSessionAppOriginL91IsNotCountedAmongTheCopilotsSessions() async throws {
        let f = try appRig(), keys = BackendDeckCoreSecurityAccessKeys(directory: try scratch())
        let id = try await workKey(keys, "E2E")
        _ = await f.call("sessions.start", o([("cwd", .string("/work/site"))]), .init(caller: keyCaller(id, "E2E")))
        let copilotSessions = await f.control.copilotSessions()
        XCTAssertEqual(copilotSessions, [])
    }

    // MARK: session-provenance.test.ts

    // session-provenance.test.ts:126
    func testSessionProvenanceL126PointsTheSessionAtTheVeryRowThisCallWrote() async throws {
        let f = try rig()
        let result = await f.call("sessions.start", o([("cwd", .string("/work/api"))]))
        XCTAssertEqual(f.surface.starts.first?["originRunId"], result.row["id"])
        XCTAssertEqual(result.row["tool"], .string("sessions.start"))
    }

    // session-provenance.test.ts:136
    func testSessionProvenanceL136GivesTwoStartsTwoDifferentTurns() async throws {
        let f = try rig()
        let first = await f.call("sessions.start", o([("cwd", .string("/work/api"))]))
        // A second folder: two copilot-started sessions in one working tree are refused.
        let second = await f.call("sessions.start", o([("cwd", .string("/work/web"))]))
        XCTAssertNotEqual(first.row["id"], second.row["id"])
        let starts = f.surface.starts
        guard starts.count == 2 else { return XCTFail("expected two starts, got \(starts.count)") }
        XCTAssertEqual(starts[0]["originRunId"], first.row["id"])
        XCTAssertEqual(starts[1]["originRunId"], second.row["id"])
    }
}
