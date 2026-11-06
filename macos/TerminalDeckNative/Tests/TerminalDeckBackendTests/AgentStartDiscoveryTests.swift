import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Exercises the live read gate, including the two checks in agents_at_work.
@MainActor
final class AgentStartDiscoveryTests: XCTestCase {
    private struct WatchSource: AWAgentsWatchSource {
        let authority: BackendCompositionAuthority
        let rows: [AWWatchAgent]
        func authorize(_ caller: AWWatchCaller, tool: String, arguments: NativeRPCValue) async throws {
            guard case .mcp(let native) = caller else { throw NativeRPCError.invalidArguments("Expected the tool caller") }
            try await authority.authorize(native, tool: tool, arguments: arguments, tier: .read, sentence: "Read agents at work")
        }
        func snapshot(_ caller: AWWatchCaller) async throws -> AWWatchSnapshot { .init(agents: rows, tasks: []) }
        func conversation(_ agent: AWWatchAgent, caller: AWWatchCaller) async throws -> AWWatchConversation { .init(entries: []) }
    }
    private struct Rig {
        let control: BackendDeckCoreSecurityControl
        let log: BackendDeckCoreSecurityActionLog
        let allowed: BackendDeckCoreSecurityTestBox<Bool>
        let revokeOnRead: BackendDeckCoreSecurityTestBox<Bool>
    }
    private func rig() async throws -> Rig {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AgentStartDiscovery-" + UUID().uuidString + ".noindex")
        let data = scratch.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in scratch.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "Discovery Fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: [:])
        let log = BackendDeckCoreSecurityActionLog(directory: data.appendingPathComponent("log"))
        let control = try BackendDeckCoreSecurityControl(log: log, consent: .init(ask: { _ in false }))
        let allowed = BackendDeckCoreSecurityTestBox(true), revokeOnRead = BackendDeckCoreSecurityTestBox(false)
        await control.setToolUseInspector { _, _, _, _ in
            guard allowed.get() else { throw NativeRPCError(code: "access-denied", message: "Seat grant revoked") }
            return "verified-seat"
        }
        let contexts = BackendDeckCoreToolContextAuthority()
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: contexts, gate: control.compositionGate(), hidden: .init())
        let row = try XCTUnwrap(AWWatchAgent.decode(.object([
            .init("id", .string("fixture-agent")), .init("sourceID", .string("fixture-agent")),
            .init("kind", .string("session")), .init("name", .string("Fixture agent")),
            .init("provider", .string("codex")), .init("project", .string(scratch.path)), .init("state", .string("working"))
        ])))
        let monitor = BackendATWORKMonitor(readTargets: { [] }, readProcesses: { _ in
            if revokeOnRead.get() { allowed.set(false) }
            return []
        }, readSystem: { .init(cpuBusy: 0, cpuTotal: 0, freeMemoryBytes: 0, memoryPressure: 0, processes: 0, cores: 1) },
            readLaunchers: { [] }, watchProcessEvents: false, publish: { _ in })
        let source = BackendATWORKSource(base: WatchSource(authority: authority, rows: [row]), monitor: monitor,
            inventory: .init(), authority: authority, manager: root.preparedSessions.manager)
        let service = BackendATWORKService(source: source, authority: authority, registry: root.registry)
        let spec = try BackendMCPTool(id: "agents.at_work", wireName: "agents_at_work", description: "Read agents at work",
            inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        try await control.register([.init(tool: spec, summary: { _, _ in "Read agents at work" }, run: { args, context in
            try await contexts.withContext(context) { native in
                .init(value: try await service.invoke("list", arguments: args, caller: .mcp(native)))
            }
        })])
        addTeardownBlock {
            await monitor.stop(); authority.close(); await state.stop(); try await root.shutdown()
            try? FileManager.default.removeItem(at: scratch)
        }
        return .init(control: control, log: log, allowed: allowed, revokeOnRead: revokeOnRead)
    }

    func testAgentsAtWorkRepeatsItsReadChecksAndReturnsRows() async throws {
        let r = try await rig()
        for _ in 0..<3 {
            let result = await r.control.call(name: "agents_at_work", arguments: .object([]))
            XCTAssertTrue(result.ok, result.error ?? "")
            XCTAssertEqual(result.value["total"], .number(1))
            XCTAssertEqual(result.value["agents"].elements?.first?["name"], .string("Fixture agent"))
        }
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0["tier"] == .string("read") && $0["outcome"] == .string("ok") })
    }

    func testAgentsAtWorkRefusesWhenSeatAccessChangesDuringRead() async throws {
        let r = try await rig()
        r.revokeOnRead.set(true)
        let result = await r.control.call(name: "agents_at_work", arguments: .object([]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.refusal, .notGranted)
        XCTAssertEqual(result.value, .null)
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["outcome"], .string("refused"))
    }

    func testReadChecksKeepCallBindingAndDoNotSpendMutationEntry() async throws {
        let r = try await rig(), control = r.control
        let spec = try BackendMCPTool(id: "fixture.change", wireName: "fixture_change", description: "Fixture",
            inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        try await control.register([.init(tool: spec, summary: { _, _ in "Fixture" }, run: { args, context in
            let gate = control.compositionGate()
            try await gate.authorize(context, spec.id, args, .read, "Read first", false)
            do {
                try await gate.authorize(context, spec.id, args.setting("outside", .bool(true)), .read, "Forged arguments", false)
                XCTFail("Read checks must bind the arguments")
            } catch {}
            let impostor = BackendDeckCoreSecurityCallContext(native: context.native,
                caller: .init(kind: .key, tiers: [.read, .act, .alter], keyID: "different-caller"), callID: context.callID,
                attended: context.attended, granted: context.granted, sessionLimits: context.sessionLimits,
                now: context.now, startedByCopilot: context.startedByCopilot, noteStarted: context.noteStarted)
            do {
                try await gate.authorize(impostor, spec.id, args, .read, "Forged caller", false)
                XCTFail("Read checks must bind the caller")
            } catch {}
            try await gate.authorize(context, spec.id, args, .read, "Read again", false)
            try await gate.authorize(context, spec.id, args, .act, "Change once", false)
            do {
                try await gate.authorize(context, spec.id, args, .act, "Change twice", false)
                XCTFail("Changes must still enter exactly once")
            } catch {}
            try await gate.record(context, spec.id, args, .object([.init("changed", .bool(true))]))
            return .init(value: .bool(true))
        })])
        let result = await control.call(name: spec.id, arguments: .object([]))
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.row["tier"], .string("act"))
        XCTAssertEqual(result.row["result"]["changed"], .bool(true))
    }

    private func spec(_ id: String, held: String? = nil) throws -> BackendDeckCoreCatalogueMetadata {
        .init(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id,
            inputSchema: .object([.init("type", .string("object"))]), tier: .read), title: id, index: held)
    }
    func testDescribeWithoutArgumentsListsAllAreasAndOnlyGrantedCounts() throws {
        let catalogue = try [spec("sessions.chat", held: "Chat in an allowed project"), spec("sessions.list"), spec("browser.read")]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "seat")
        let result = try BackendDeckCoreCatalogueDescribe.answer(.object([]), catalogue: catalogue,
            granted: ["sessions.chat"], caller: caller).value
        let areas = try XCTUnwrap(result["areas"].elements)
        XCTAssertEqual(areas.compactMap { $0["area"].string }, BackendDeckCoreCatalogueDescribe.areas.map(\.id))
        XCTAssertTrue(areas.allSatisfy { $0["covers"].string?.isEmpty == false && $0["covers"].string?.contains("\n") == false })
        XCTAssertEqual(areas.first { $0["area"] == .string("sessions") }?["tools"], .number(1))
        XCTAssertEqual(areas.first { $0["area"] == .string("browser") }?["tools"], .number(0))
    }

    func testDescribeSessionsIncludesGrantedHeldAndListedToolsOnly() throws {
        let catalogue = try [spec("sessions.chat", held: "Chat"), spec("sessions.list"), spec("sessions.stop", held: "Stop")]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "seat")
        let result = try BackendDeckCoreCatalogueDescribe.answer(.object([.init("area", .string("sessions"))]),
            catalogue: catalogue, granted: ["sessions_chat", "sessions_list"], caller: caller).value
        XCTAssertEqual(result["held"].elements?.map { $0["name"] }, [.string("sessions_chat")])
        XCTAssertEqual(result["alreadyListed"], .array([.string("sessions_list")]))
        XCTAssertFalse(result.compact.contains("sessions_stop"))
    }

    func testDescribeSessionsWithoutGrantExplainsActualAgentSettings() throws {
        let catalogue = try [spec("sessions.chat", held: "Chat"), spec("sessions.list")]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "seat")
        let result = try BackendDeckCoreCatalogueDescribe.answer(.object([.init("area", .string("sessions"))]),
            catalogue: catalogue, granted: ["tools.describe"], caller: caller).value
        XCTAssertEqual(result["held"], .array([]))
        XCTAssertEqual(result["alreadyListed"], .array([]))
        XCTAssertEqual(result["unknown"], .missing)
        // d58fd61f (5 Nov): one refusal for every session tool the seat is not allowed, naming where the owner allows it.
        let note = try XCTUnwrap(result["note"].string)
        XCTAssertEqual(note, BackendSessionDirectory.toolRefusal)
        for label in ["Agents", "Settings", "Allowed tools", "Blocked tools"] {
            XCTAssertTrue(note.contains(label), label)
        }
    }
}
