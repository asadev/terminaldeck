import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendRoutinesIntegrationRunner: BackendRoutinesRunner {
    nonisolated let cancellable = false
    private var requests: [BackendRoutinesRunRequest] = []
    func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome { requests.append(request); return .init(ok: true) }
    func snapshot() -> [BackendRoutinesRunRequest] { requests }
}

final class BackendRoutinesIntegrationTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRoutinesAssembly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testAssemblySeedsBeforeFirstEngineLoad() async throws {
        let root = try scratch()
        let service = await BackendRoutinesService.create(options: .init(userData: root, runner: .disabled, seedFolder: { "/work/api" }))
        XCTAssertEqual(service.seedResult?.written, BackendRoutinesDefaults.routines.map(\.id))
        XCTAssertNil(service.seedingError)
        try await service.start()
        let rows = await service.engine.list()
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows.first { $0.id == "overnight" }?.state, "unarmed")
        XCTAssertTrue(rows.first { $0.id == "overnight" }?.reason?.contains("Hoot is not running") == true)
        await service.stop()
    }
    func testActualFileEventsReachRunnerAndSharedDiskLog() async throws {
        let root = try scratch(), project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let runner = BackendRoutinesIntegrationRunner()
        let service = await BackendRoutinesService.create(options: .init(userData: root, runner: .provided(runner),
            allowFolder: { $0 == project.path ? nil : "not a project" }))
        _ = try service.store.saveText("on-edit", text: "# On edit\n\nwhen: file-change src/**\nin: \(project.path)\nquiet-for: 1s\n\n---\n\nSomething under src changed. Have a look.\n")
        try await service.start()
        let armed = await service.engine.get("on-edit")
        XCTAssertEqual(armed?.state, "armed")
        // Like the source integration test, wait for native watch registration
        // before the edit. This entire test is queued for the combined gate.
        try await Task.sleep(for: .milliseconds(400))
        try "unmatched".write(to: project.appendingPathComponent("README.md"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        let unmatched = await runner.snapshot()
        XCTAssertTrue(unmatched.isEmpty)
        let source = project.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "export const x = 1".write(to: source.appendingPathComponent("app.ts"), atomically: false, encoding: .utf8)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if await service.engine.get("on-edit")?.lastOutcome == "ok" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let requests = await runner.snapshot()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(requests.first?.cause.kind, "file-change")
        XCTAssertEqual(requests.first?.routine.prompt, "Something under src changed. Have a look.")
        await service.stop()
        let path = root.appendingPathComponent("copilot-log/actions.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let actions = try lines.map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        XCTAssertTrue(actions.contains { $0["action"].string == "routine.run" && $0["outcome"].string == "started" })
        XCTAssertTrue(actions.contains { $0["action"].string == "routine.run" && $0["outcome"].string == "ok" })
        XCTAssertTrue(actions.allSatisfy { $0["routine"].string == "on-edit" })
        XCTAssertEqual(service.runtime.fileURL, root.appendingPathComponent("routine-state.json"))
    }
    func testMissingGitSourceStaysVisibleInsteadOfPretendingArmed() async throws {
        let root = try scratch(), runner = BackendRoutinesIntegrationRunner()
        let service = await BackendRoutinesService.create(options: .init(userData: root, runner: .provided(runner)))
        _ = try service.store.saveText("git-check", text: "# Git\nwhen: git-change\nin: /work/api\n---\nRead status.\n")
        try await service.start()
        let row = await service.engine.get("git-check")
        XCTAssertEqual(row?.state, "unarmed")
        XCTAssertTrue(row?.reason?.contains("No git watch") == true)
        await service.stop()
    }
    func testRegisteredCreateAndManualRunWorkWithoutRestart() async throws {
        let root = try scratch(), runner = BackendRoutinesIntegrationRunner()
        let service = await BackendRoutinesService.create(options: .init(userData: root, runner: .provided(runner)))
        let registry = NativeChannelRegistry(), context = NativeRPCContext(caller: .nativeApp, ownerID: "native-app")
        try await service.api.register(on: registry, ownerID: "routines")
        try await service.start()
        let draft: NativeRPCValue = .object([.init("name", .string("By hand")), .init("when", .string("manual")),
            .init("in", .string("/work/api")), .init("prompt", .string("Do it."))])
        let created = try await registry.invoke("routines:create", context: context, arguments: [draft])
        XCTAssertEqual(created["ok"].bool, true)
        XCTAssertEqual(created["id"].string, "by-hand")
        let listed = try await registry.invoke("routines:list", context: context, arguments: [])
        XCTAssertEqual(listed.elements?.count, 1)
        let result = try await registry.invoke("routines:run", context: context, arguments: [.string("by-hand")])
        XCTAssertEqual(result["started"].bool, true)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await service.engine.get("by-hand")?.lastOutcome == "ok" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let requests = await runner.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.attended, false)
        XCTAssertEqual(requests.first?.cause, .manual(by: "user"))
        await registry.shutdown()
        await service.stop()
    }
}
