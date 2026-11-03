import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Reuses the real watch source, composition authority, memory task stores and
/// existing thread-safe test box. Only process readers and change handlers are inert.
@MainActor
final class BackendATWORKMCPTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_ATWORK_FOCUSED"] == "1" else { throw XCTSkip("WIP ATWORK") }
    }
    private struct Rig: Sendable {
        let root: BackendCompositionRoot
        let authority: BackendCompositionAuthority
        let monitor: BackendATWORKMonitor
        let source: BackendATWORKSource
        let service: BackendATWORKService
        let rows: BackendDeckCoreSecurityTestBox<[AWWatchAgent]>
        let onRead: BackendDeckCoreSecurityTestBox<(@Sendable () -> Void)?>
        let changes: BackendDeckCoreSecurityTestBox<Int>
    }
    private func rig() async throws -> Rig {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ATWORK-MCP-" + UUID().uuidString + ".noindex")
        let data = scratch.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in scratch.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "ATWORK Fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: BackendDeckCoreToolContextAuthority(),
            gate: .init(authorize: { _, _, _, _, _, _ in throw NativeRPCError(code: "approval-required", message: "Fixture approval refused") },
                        record: { _, _, _, _ in }), hidden: .init())
        let persistence = try BackendTaskPersistence(directory: data.appendingPathComponent("tasks"), ownership: .memory)
        let tasks = BackendTaskStore(persistence: persistence), goals = BackendGoalStore(persistence: persistence)
        let config = try BackendTaskConfiguration(persistence: persistence)
        try await tasks.start(); try await goals.start(); try await config.start()
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil },
            post: { _, _ in throw NativeRPCError(code: "test-network", message: "No fixture network") }, onCommentID: { _, _ in }, problem: { _ in })
        let taskAuthority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true },
            project: { _, _ in }, authorize: { _, _, _, _ in }, actorName: { _ in "ATWORK fixture" })
        let rows = BackendDeckCoreSecurityTestBox<[AWWatchAgent]>([])
        let base = AWAgentsWatchNativeSource(authority: authority,
            tasks: .init(store: tasks, configuration: config, goals: goals, outbox: outbox, keyViews: { [] }),
            taskAuthority: taskAuthority, transcript: { _, _ in nil },
            remote: { _ in .init(agents: rows.get(), tasks: []) })
        let onRead = BackendDeckCoreSecurityTestBox<(@Sendable () -> Void)?>(nil)
        let monitor = BackendATWORKMonitor(readTargets: { [] }, readProcesses: { _ in onRead.get()?(); return [] },
            readSystem: { .init(cpuBusy: 0, cpuTotal: 0, freeMemoryBytes: 0, memoryPressure: 0, processes: 0, cores: 1) },
            now: { 100 }, uptime: { 100 }, watchProcessEvents: false, publish: { _ in })
        let source = BackendATWORKSource(base: base, monitor: monitor, inventory: .init(), authority: authority,
            manager: root.preparedSessions.manager)
        let service = BackendATWORKService(source: source, authority: authority, registry: root.registry)
        let changes = BackendDeckCoreSecurityTestBox<Int>(0)
        for channel in ["session:kill", "session:create", "hoot:stop"] {
            try await root.registry.register(channel, ownerID: "ATWORK-inert-actions", policy: { _ in }, handler: { _, _ in
                changes.edit { $0 += 1 }; return .bool(true)
            })
        }
        addTeardownBlock {
            await monitor.stop(); authority.close(); await state.stop(); try await root.shutdown()
            try? FileManager.default.removeItem(at: scratch)
        }
        return .init(root: root, authority: authority, monitor: monitor, source: source, service: service,
                     rows: rows, onRead: onRead, changes: changes)
    }
    private func agent(_ id: String, kind: String = "session") throws -> AWWatchAgent {
        try XCTUnwrap(AWWatchAgent.decode(.object([.init("id", .string(id)), .init("sourceID", .string(id)),
            .init("name", .string(id)), .init("kind", .string(kind)), .init("sessionID", .string(id)),
            .init("provider", .string("claude")), .init("state", .string("working"))])))
    }
    private func refused(_ expected: String, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, expected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAliasesKeepLegacyReadsAndUseAlterOnlyForChanges() async throws {
        let r = try await rig(), owner = "ATWORK-registration-fixture"
        try await AWAgentsWatchRegistration.install(registry: r.root.registry, server: r.root.mcp,
            service: .init(source: r.source), ownerID: owner)
        try await BackendATWORKRegistration.install(service: r.service, registry: r.root.registry, server: r.root.mcp, owner: owner)
        let specs = await r.root.mcp.registrations().map { $0.0 }
        let legacy = Set(AWAgentsWatchRegistration.operations.map { "agents.watch_" + $0 })
        XCTAssertEqual(Set(specs.map(\.id)), Set(BackendATWORKRegistration.toolIDs).union(legacy))
        for spec in specs {
            XCTAssertEqual(spec.tier, ["agents.stop", "agents.resume"].contains(spec.id) ? .alter : .read)
            if BackendATWORKRegistration.toolIDs.contains(spec.id) {
                XCTAssertEqual(spec.wireName, spec.id.replacingOccurrences(of: ".", with: "_"))
            }
        }
        await r.root.registry.removeOwner(owner); await r.root.mcp.removeTools(ownerID: owner)
        let remainingTools = await r.root.mcp.registrations()
        let channels = await r.root.registry.channels()
        XCTAssertTrue(remainingTools.isEmpty)
        XCTAssertTrue(Set(BackendATWORKRegistration.channels).isDisjoint(with: Set(channels)))
    }

    func testNativeStopAndResumeRequireConfirmationBeforeAnyChange() async throws {
        let r = try await rig(); r.rows.set([try agent("managed"), try agent("external", kind: "device")])
        for (operation, id) in [("stop", "managed"), ("resume", "external")] {
            await refused("approval-required") {
                _ = try await r.service.invoke(operation, arguments: .object([.init("id", .string(id))]),
                    caller: .app(r.authority.localContext()))
            }
        }
        XCTAssertEqual(r.changes.get(), 0)
    }

    func testExternalStopStaysUnavailableAfterOwnerConfirmation() async throws {
        let r = try await rig(); r.rows.set([try agent("external", kind: "device")])
        await refused("unavailable") {
            _ = try await r.service.invoke("stop", arguments: .object([.init("id", .string("external")), .init("confirmed", .bool(true))]),
                caller: .app(r.authority.localContext()))
        }
        XCTAssertEqual(r.changes.get(), 0)
    }

    func testConfirmedRemoteHootCannotStopLocalHoot() async throws {
        let r = try await rig()
        let remote = try XCTUnwrap(AWWatchAgent.decode(try agent("remote-hoot", kind: "hoot").wireValue
            .setting("machineID", .string("another-machine"))))
        r.rows.set([remote])
        await refused("unavailable") {
            _ = try await r.service.invoke("stop", arguments: .object([
                .init("id", .string(remote.id)), .init("confirmed", .bool(true))]),
                caller: .app(r.authority.localContext()))
        }
        XCTAssertEqual(r.changes.get(), 0, "A remote Hoot row must never route to this Mac's copilot:stop")
    }

    func testNativeRoutesRejectPageCallerBeforeAction() async throws {
        let r = try await rig()
        try await BackendATWORKRegistration.install(service: r.service, registry: r.root.registry, server: r.root.mcp, owner: "ATWORK-owner")
        let page = NativeRPCContext(caller: .page, ownerID: "page")
        for channel in ["agents-watch:stop", "agents-watch:resume", "agents-watch:devices"] {
            await refused("access-denied") {
                _ = try await r.root.registry.invoke(channel, context: page, arguments: [.object([.init("id", .string("private")), .init("confirmed", .bool(true))])])
            }
        }
        XCTAssertEqual(r.changes.get(), 0)
    }

    func testRemovedInventoryMembershipCannotLeakThroughMetricsReply() async throws {
        let r = try await rig(); r.rows.set([try agent("private")])
        r.onRead.set { r.rows.set([]) }
        let snapshot = try await r.source.snapshot(.app(r.authority.localContext()))
        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertEqual(r.changes.get(), 0)
    }

    func testOwnerRevocationDuringMetricsReadRejectsReply() async throws {
        let r = try await rig(); r.rows.set([try agent("private")])
        let context = try r.authority.localContext()
        r.onRead.set { r.authority.revokeLocalUI() }
        await refused("access-denied") { _ = try await r.source.snapshot(.app(context)) }
        XCTAssertEqual(r.changes.get(), 0)
    }
}
