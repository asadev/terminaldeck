import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct PROJSelectionCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}

private actor PROJSelectionEvents {
    private var sinks: [UUID: AsyncStream<Void>.Continuation] = [:]
    func stream() -> AsyncStream<Void> {
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(32))
        sinks[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return pair.stream
    }
    private func remove(_ id: UUID) { sinks[id] = nil }
    func changed() { for sink in sinks.values { sink.yield(()) } }
}

/// Red until AGOPT's actor selection persistence/watcher hooks land. Only owned fixtures.
final class PROJAgentSelectionTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let root: URL, folder: URL, directory: URL, persistence: BackendTaskPersistence
        var selected: [String] { ["alpha-agent", "beta-agent"].map { directory.appendingPathComponent($0 + ".md").path } }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-selection-" + UUID().uuidString + ".noindex").resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("source.noindex"), directory = folder.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ["alpha-agent", "beta-agent", "gamma-agent"] { try definition(id, role: "Fixture " + id).write(to: directory.appendingPathComponent(id + ".md"), atomically: true, encoding: .utf8) }
        return Fixture(root: root, folder: folder, directory: directory, persistence: try .init(directory: root.appendingPathComponent("records"), ownership: .exclusive))
    }
    private func definition(_ id: String, role: String) -> String {
        "---\nname: \(id)\ndescription: \(role)\ntools: Read, Grep\n---\nOnly read the owned fixture.\n"
    }
    private func options(_ files: [String], project: String = "independent") -> NativeRPCValue {
        .object([.init("projectId", .string(project)), .init("selectedFiles", .array(files.map(NativeRPCValue.string)))])
    }
    private func config(_ fixture: Fixture, events: PROJSelectionEvents? = nil) async throws -> BackendTaskConfiguration {
        let config = try BackendTaskConfiguration(persistence: fixture.persistence, changed: { await events?.changed() })
        try await config.start(); return config
    }
    private func savedPaths(_ fixture: Fixture) throws -> [String]? {
        try fixture.persistence.read("task-config.json")?["agentImportSelections"][fixture.directory.path].elements?.compactMap(\.string)
    }

    func testPartialChoiceSurvivesWatcherStartupRestartThenWholeFolderAddsThird() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await config(fixture)
        let preview = try await first.importPreview(folder: fixture.folder.path, options: options(fixture.selected))
        XCTAssertEqual(preview, ["alpha-agent", "beta-agent"])
        _ = try await first.importAgents(folder: fixture.folder.path, options: options(fixture.selected))
        try await first.startImportWatchers()
        let rows = try await first.allAgents()
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0["projectId"].string == "independent" && !$0.has("selectedFiles") })
        XCTAssertEqual(try savedPaths(fixture)?.sorted(), fixture.selected.sorted())
        try await first.stop()
        let restarted = try await config(fixture)
        try await restarted.startImportWatchers()
        let afterBoot = try await restarted.allAgents()
        XCTAssertEqual(afterBoot.count, 2); XCTAssertTrue(afterBoot.allSatisfy { $0["projectId"].string == "independent" })
        _ = try await restarted.importAgents(folder: fixture.folder.path, options: .object([.init("projectId", .string("independent"))]))
        let whole = try await restarted.allAgents()
        XCTAssertEqual(whole.count, 3); XCTAssertTrue(whole.allSatisfy { $0["projectId"].string == "independent" })
        XCTAssertNil(try savedPaths(fixture))
        try await restarted.stop()
    }

    func testSelectingOneNewFileKeepsGreyExistingIndependentAgentAndWatchScopeUnion() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let config = try await config(fixture)
        _ = try await config.importAgents(folder: fixture.folder.path, options: options([fixture.selected[0]]))
        _ = try await config.importAgents(folder: fixture.folder.path, options: options([fixture.selected[1]], project: "crm"))
        let alpha = try await config.agent("alpha-agent"), beta = try await config.agent("beta-agent")
        XCTAssertEqual(alpha?["projectId"].string, "independent"); XCTAssertEqual(beta?["projectId"].string, "crm")
        XCTAssertNotEqual(alpha?["syncStatus"].string, "missing")
        XCTAssertEqual(try savedPaths(fixture)?.sorted(), fixture.selected.sorted())
        try await config.startImportWatchers()
        let rows = try await config.allAgents()
        let unchecked = try await config.agent("gamma-agent")
        XCTAssertEqual(rows.count, 2); XCTAssertNil(unchecked)
        try await config.stop()
    }

    func testFilesystemChangeRefreshesCheckedFileWithoutImportingUncheckedThird() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = PROJSelectionEvents(), config = try await config(fixture, events: events)
        _ = try await config.importAgents(folder: fixture.folder.path, options: options(fixture.selected))
        try await config.startImportWatchers()
        let stream = await events.stream()
        try definition("gamma-agent", role: "Unchecked changed").write(to: fixture.directory.appendingPathComponent("gamma-agent.md"), atomically: true, encoding: .utf8)
        try definition("beta-agent", role: "Checked changed").write(to: fixture.directory.appendingPathComponent("beta-agent.md"), atomically: true, encoding: .utf8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream {
                    if try await config.agent("beta-agent")?["role"].string == "Checked changed" { return }
                    try Task.checkCancellation()
                }
                throw NativeRPCError(code: "fixture-ended", message: "The fixture change stream ended.")
            }
            group.addTask { try await Task.sleep(for: .seconds(8)); throw NativeRPCError(code: "fixture-timeout", message: "No checked-file update arrived.") }
            defer { group.cancelAll() }; _ = try await group.next()
        }
        let rows = try await config.allAgents(); XCTAssertEqual(rows.count, 2)
        let unchecked = try await config.agent("gamma-agent")
        XCTAssertNil(unchecked); XCTAssertTrue(rows.allSatisfy { $0["projectId"].string == "independent" })
        try await config.stop()
    }

    func testAGSAndGroupedProfileRecordWritersKeepSavedSelection() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let config = try await config(fixture)
        let ags = BackendAGSStore(persistence: fixture.persistence, cipher: PROJSelectionCipher())
        try await ags.start(); try await config.bindAGS(ags)
        _ = try await config.importAgents(folder: fixture.folder.path, options: options(fixture.selected))
        let currentSettings = try await ags.profile("alpha-agent")
        var settings = try XCTUnwrap(currentSettings); settings.keepOpen = false
        _ = try await config.saveSettingsForProfile("alpha-agent", settings: settings, expectedRevision: try await ags.currentRevision())
        XCTAssertEqual(try savedPaths(fixture)?.sorted(), fixture.selected.sorted())
        let request = NativeRPCValue.object([.init("do", .string("save-many")), .init("ids", .array([.string("alpha-agent"), .string("beta-agent")])),
            .init("agent", .object([.init("allowedTools", .array([.string("Read")]))]))])
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "fixture-key")
        if plan["needsApproval"].bool == true { _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].requireString("fixture plan"), callerKeyID: "fixture-key") }
        XCTAssertEqual(try savedPaths(fixture)?.sorted(), fixture.selected.sorted())
        try await config.stop()
    }
}
