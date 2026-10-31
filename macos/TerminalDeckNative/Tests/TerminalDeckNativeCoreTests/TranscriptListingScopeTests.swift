import XCTest
@testable import TerminalDeckNativeCore

final class TranscriptListingScopeTests: XCTestCase {
    func testListingAndNewestRetainProjectAndSymlinkBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/part53-test-scratch/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), project = root.appendingPathComponent("project").path
        let directory = config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let allowed = directory.appendingPathComponent("allowed.jsonl")
        try Data("{}\n".utf8).write(to: allowed)
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.jsonl"), withDestinationURL: outside)
        let scope = NativeTranscriptScope(configDirectory: config.path, projectFolders: [project])
        XCTAssertEqual(try NativeTranscriptPaths.listTranscripts(directory.path, scope: scope).map(\.sessionID), ["allowed"])
        XCTAssertEqual(try NativeTranscriptPaths.newest(project, scope: scope)?.path, NativeTranscriptPaths.canonical(allowed.path))
        let denied = NativeTranscriptScope(configDirectory: config.path, projectFolders: [])
        XCTAssertTrue(try NativeTranscriptPaths.listTranscripts(directory.path, scope: denied).isEmpty)
        XCTAssertThrowsError(try NativeTranscriptPaths.assertTranscript(outside.path, scope: scope))
    }
}
