import Foundation
import XCTest
import Darwin
@testable import TerminalDeckBackend

final class BackendNodelessPackagingFilesTests: XCTestCase {
    private func scratch(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendNodelessPackaging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.resolvingSymlinksInPath())
    }
    func testScratchRootsAndCommandArgumentsFailClosed() {
        XCTAssertThrowsError(try BackendNodelessPackagingFiles.scratchRoot(URL(fileURLWithPath: "/Applications")))
        XCTAssertThrowsError(try BackendNodelessPackagingFiles.scratchRoot(URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try BackendNodelessPackagingFiles.scratchRoot(URL(fileURLWithPath: "/Users/sample/Library/Application Support/terminaldeck")))
        XCTAssertEqual(BackendNodelessPackagingCommand.run(arguments: []).code, 2)
        XCTAssertEqual(BackendNodelessPackagingCommand.run(arguments: [BackendNodelessPackagingCommand.argument, "relative", "Fixture.app", "receipt.json"]).code, 2)
    }
    func testDraftRecordsCopiedBytesWithoutInventingVerification() throws {
        try scratch { root in
            let app = root.appendingPathComponent("Fixture.app"), path = "Contents/Resources/licenses/fixture.txt"
            let file = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture notice\n".utf8).write(to: file)
            let hash = String(repeating: "a", count: 64)
            let draft = try BackendNodelessPackagingFiles.manifest(version: "fixture", architecture: "arm64", mode: .nativeOnly,
                inventorySHA256: hash, sourceSHA256: hash, graphSHA256: hash, artifacts: [.init(path: path, sha256: hash, kind: .notice)],
                appRelativePath: "Fixture.app", buildRoot: root)
            XCTAssertEqual(draft.artifacts[0].sha256, try BackendNodelessPackagingFiles.digest(file))
            XCTAssertNotEqual(draft.artifacts[0].sha256, hash)
            XCTAssertThrowsError(try BackendNodelessPackagingFiles.verify(buildRoot: root, appRelativePath: "Fixture.app", receiptRelativePath: "missing.json"))
        }
    }
    func testPlanTraversalSymlinkAndNonregularInputsCannotBeHashedAsArtifacts() throws {
        try scratch { root in
            let app = root.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside.txt")
            try Data("outside\n".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/Resources/link"), withDestinationURL: outside)
            let hash = String(repeating: "a", count: 64)
            for path in ["Contents/Resources/link", "Contents/../outside.txt", "Contents/Resources"] {
                XCTAssertThrowsError(try BackendNodelessPackagingFiles.manifest(version: "fixture", architecture: "arm64", mode: .nativeOnly,
                    inventorySHA256: hash, sourceSHA256: hash, graphSHA256: hash,
                    artifacts: [.init(path: path, sha256: hash, kind: .resource)], appRelativePath: "Fixture.app", buildRoot: root))
            }
        }
    }
    func testDescriptorRejectsReplacedParentBeforeReadingAndDoesNotBlockOnFIFO() throws {
        try scratch { root in
            let allowed = root.appendingPathComponent("allowed"), original = allowed.appendingPathComponent("nested")
            let foreign = root.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try Data("approved".utf8).write(to: original.appendingPathComponent("payload"))
            try Data("foreign".utf8).write(to: foreign.appendingPathComponent("payload"))
            try FileManager.default.moveItem(at: original, to: allowed.appendingPathComponent("old"))
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: foreign)
            XCTAssertThrowsError(try BackendNodelessPackagingFiles.openRegularSource(original.appendingPathComponent("payload"), within: allowed))
            let fifo = allowed.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try BackendNodelessPackagingFiles.openRegularSource(fifo, within: allowed))
            XCTAssertEqual(try String(contentsOf: foreign.appendingPathComponent("payload"), encoding: .utf8), "foreign")
        }
    }
}
