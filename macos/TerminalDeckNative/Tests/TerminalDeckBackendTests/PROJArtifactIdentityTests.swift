import Foundation
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct PROJArtifactIdentitySource: BackendArtifactsTranscriptSource {
    let files: [NativeTranscriptFile]
    let denied: Bool
    /// Conversations this source refuses while approving the rest.
    var deniedSessions: Set<String> = []
    func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] { files }
    func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String {
        if denied || deniedSessions.contains(file.sessionID) { throw NativeRPCError(code: "fixture-denied", message: "The fixture source denied this transcript.") }
        return file.path
    }
}
private extension NativeTranscriptFile {
    /// The file's own name, which no answer may carry for a skipped history.
    var lastPathComponentForTest: String { URL(fileURLWithPath: path).lastPathComponent }
}
private actor PROJArtifactIdentityCalls {
    private var count = 0
    func add() { count += 1 }
    func total() -> Int { count }
}

final class PROJArtifactIdentityTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let root: URL, folder: URL, nested: URL, projects: BackendPROJRegistry
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "proj-artifact-fixture")
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-artifact-identity-" + UUID().uuidString + ".noindex").resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("workspace.noindex"), nested = folder.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let projects = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try await projects.save(.init(id: "imatch", name: "iMatch", folders: [folder.path]))
        _ = try await projects.save(.init(id: "research", name: "Research", folders: [nested.path]))
        return .init(root: root, folder: folder, nested: nested, projects: projects)
    }
    private func transcript(_ fixture: Fixture, id: String, paths: [String], age: Double = 0) throws -> NativeTranscriptFile {
        let file = fixture.root.appendingPathComponent(id + ".jsonl"), at = Date().addingTimeInterval(-age)
        let blocks = paths.map { path in NativeRPCValue.object([.init("type", .string("tool_use")), .init("name", .string("Write")),
            .init("input", .object([.init("file_path", .string(path)), .init("content", .string("Owned fixture."))]))]) }
        let line = NativeRPCValue.object([.init("timestamp", .string(ISO8601DateFormatter().string(from: at))),
            .init("message", .object([.init("content", .array(blocks))]))])
        var bytes = try line.encodedJSON(); bytes.append(10); try bytes.write(to: file)
        let stamp = at.timeIntervalSince1970 * 1_000
        return .init(path: file.path, sessionID: id, createdAt: stamp, modifiedAt: stamp, bytes: Int64(bytes.count))
    }
    private func index(_ fixture: Fixture, files: [NativeTranscriptFile], denied: Bool = false, deniedSessions: Set<String> = []) async -> BackendArtifactsIndex {
        let index = BackendArtifactsIndex(source: PROJArtifactIdentitySource(files: files, denied: denied, deniedSessions: deniedSessions), authority: .init(scope: { _ in .local }))
        await index.bindProjectResolver { try await fixture.projects.resolve(projectID: nil, folder: $0) }
        return index
    }

    func testParentScanClassifiesNestedFilesHistoryAndMixedSessionGroupsByActualFolder() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try transcript(fixture, id: "legacy", paths: [fixture.folder.appendingPathComponent("root.md").path, fixture.nested.appendingPathComponent("report.md").path])
        let index = await index(fixture, files: [file])
        let result = try await index.list(project: fixture.folder.path, context: fixture.context)
        let artifacts = try XCTUnwrap(result["artifacts"].elements)
        XCTAssertEqual(artifacts.first { $0["relPath"].string == "root.md" }?["projectId"].string, "imatch")
        XCTAssertEqual(artifacts.first { $0["relPath"].string == "research/report.md" }?["projectId"].string, "research")
        let grouped = try XCTUnwrap(result["sessions"].elements)
        XCTAssertEqual(Set(grouped.compactMap { $0["projectId"].string }), ["imatch", "research"])
        XCTAssertTrue(grouped.allSatisfy { $0["sessionId"].string == "legacy" && $0["files"].number == 1 })
        let filtered = try await fixture.projects.filter(artifacts, projectID: "research")
        XCTAssertEqual(filtered.count, 1)
        let history = try await index.history(project: fixture.folder.path, relative: "research/report.md", context: fixture.context)
        XCTAssertEqual(history["projectId"].string, "research")
        XCTAssertEqual(history["changes"].elements?.first?["projectId"].string, "research")
        await index.stop()
    }

    func testTrustedExplicitIndependentWriterWinsOverRegisteredFolderEverywhere() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try transcript(fixture, id: "independent-conversation", paths: [fixture.nested.appendingPathComponent("report.md").path])
        let index = await index(fixture, files: [file])
        await index.bindSessionProjectResolver { provider, id in provider == "claude" && id == "independent-conversation" ? "independent" : nil }
        let result = try await index.list(project: fixture.folder.path, context: fixture.context)
        let artifacts = try XCTUnwrap(result["artifacts"].elements)
        for key in ["artifacts", "sessions"] {
            XCTAssertEqual(result[key].elements?.first?["projectId"].string, "independent")
            XCTAssertEqual(result[key].elements?.first?["projectIdInferred"].bool, false)
        }
        let filtered = try await fixture.projects.filter(artifacts, projectID: "independent")
        XCTAssertEqual(filtered.count, 1)
        let history = try await index.history(project: fixture.folder.path, relative: "research/report.md", context: fixture.context)
        XCTAssertEqual(history["projectId"].string, "independent")
        XCTAssertEqual(history["changes"].elements?.first?["projectId"].string, "independent")
        await index.stop()
    }

    func testNewestUnmappedWriterUsesFileFolderRatherThanOlderExplicitWriterOrInvalidID() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = fixture.nested.appendingPathComponent("report.md").path
        let older = try transcript(fixture, id: "older", paths: [path], age: 30)
        let newest = try transcript(fixture, id: "newest", paths: [path])
        let index = await index(fixture, files: [newest, older])
        await index.bindSessionProjectResolver { _, id in id == "older" ? "independent" : "INVALID ID" }
        let result = try await index.list(project: fixture.folder.path, context: fixture.context)
        XCTAssertEqual(result["artifacts"].elements?.first?["projectId"].string, "research")
        XCTAssertEqual(result["artifacts"].elements?.first?["projectIdInferred"].bool, true)
        let sessions = try XCTUnwrap(result["sessions"].elements)
        XCTAssertEqual(sessions.first { $0["sessionId"].string == "older" }?["projectId"].string, "independent")
        XCTAssertEqual(sessions.first { $0["sessionId"].string == "newest" }?["projectId"].string, "research")
        await index.stop()
    }

    func testDeniedTranscriptNeverCallsTrustedIdentityResolver() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try transcript(fixture, id: "denied", paths: [fixture.nested.appendingPathComponent("report.md").path])
        let index = await index(fixture, files: [file], denied: true), calls = PROJArtifactIdentityCalls()
        await index.bindSessionProjectResolver { _, _ in await calls.add(); return "independent" }
        // A history the source refuses is SKIPPED, never read and never a reason for the list to fail
        // (one refused or unreadable history used to fail every project's list).
        let result = try await index.list(project: fixture.folder.path, context: fixture.context)
        // Not scanned: nothing it wrote is a row, no session of it is reported, and the trusted resolver is never asked.
        XCTAssertEqual(result["artifacts"].elements?.count, 0); XCTAssertEqual(result["sessions"].elements?.count, 0)
        XCTAssertEqual(result["sessionsScanned"].number, 0)
        let total = await calls.total(); XCTAssertEqual(total, 0)
        // It is counted as skipped by a mark; its path stays out of the answer (it goes to the log).
        XCTAssertEqual(result["sessionsSkipped"].number, 1); XCTAssertEqual(result["skippedKeys"].elements?.count, 1)
        XCTAssertFalse(String(decoding: try result.encodedJSON(), as: UTF8.self).contains(file.lastPathComponentForTest))
        await index.stop()

        // Beside an approved history: the approved one is listed in full, the refused one still contributes
        // nothing, and the trusted resolver is asked about the approved conversation only.
        let allowed = try transcript(fixture, id: "allowed", paths: [fixture.folder.appendingPathComponent("root.md").path])
        let mixed = await self.index(fixture, files: [file, allowed], deniedSessions: ["denied"]), asked = PROJArtifactIdentityCalls()
        await mixed.bindSessionProjectResolver { _, conversation in if conversation == "denied" { await asked.add() }; return nil }
        let both = try await mixed.list(project: fixture.folder.path, context: fixture.context)
        XCTAssertEqual(both["artifacts"].elements?.compactMap { $0["relPath"].string }, ["root.md"])
        XCTAssertEqual(both["sessions"].elements?.compactMap { $0["sessionId"].string }, ["allowed"])
        XCTAssertEqual(both["sessionsScanned"].number, 1); XCTAssertEqual(both["sessionsSkipped"].number, 1)
        let deniedAsked = await asked.total(); XCTAssertEqual(deniedAsked, 0)
        await mixed.stop()
    }
}
