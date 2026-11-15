import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudBackupTests: XCTestCase, @unchecked Sendable {
  func testChangedChunksOnlyAndRestartedCatalogue() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    let size = CloudWire.maximumPlainChunkBytes
    var data = Data(repeating: 65, count: size); data.append(Data(repeating: 66, count: size))
    try f.write("large.bin", data)
    try f.write("small-a.txt", "a"); try f.write("small-b.txt", "b")
    let first = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    XCTAssertEqual(first.queuedContentChunks, 3)
    let small = first.manifest.entries.filter { $0.relativePath.hasPrefix("small") }
    XCTAssertEqual(small[0].chunks[0].blob.blobId, small[1].chunks[0].blob.blobId)
    data[size + 1] = 67; try f.write("large.bin", data)
    let second = try await f.engine().snapshot(f.root(), eventCursor: "2", at: 2)
    XCTAssertEqual(second.queuedContentChunks, 1)
    XCTAssertEqual(second.reusedContentChunks, 3)
    XCTAssertEqual(second.manifest.parentSnapshotId, first.manifest.snapshotId)
    let a = try XCTUnwrap(first.manifest.entries.first { $0.relativePath == "large.bin" })
    let b = try XCTUnwrap(second.manifest.entries.first { $0.relativePath == "large.bin" })
    XCTAssertEqual(a.chunks[0], b.chunks[0])
    XCTAssertNotEqual(a.chunks[1].blob, b.chunks[1].blob)
  }

  func testAM2SecretSeparationAndAuthExclusion() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write(".env", "FIXTURE_ONLY_ENV=abc")
    try f.write("test.key", "FIXTURE_ONLY_KEY")
    try f.write("source.txt", "ordinary work")
    try f.write("auth.json", "FIXTURE_DISABLED_AUTH")
    let result = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    XCTAssertEqual(result.manifest.entries.filter { $0.storageClass == .secrets }.count, 2)
    XCTAssertEqual(result.manifest.entries.filter { $0.storageClass == .brain }.count, 1)
    XCTAssertEqual(result.manifest.exclusions.map(\.rule), ["provider-auth-disabled"])
    let brain = await f.brain.sealed
    let secrets = await f.secrets.sealed
    XCTAssertFalse(brain.contains { Data(base64Encoded: $0.ciphertext)?.range(of: Data("FIXTURE_ONLY".utf8)) != nil })
    XCTAssertTrue(secrets.contains { Data(base64Encoded: $0.ciphertext)?.range(of: Data("FIXTURE_ONLY_KEY".utf8)) != nil })
    XCTAssertFalse((brain + secrets).contains { Data(base64Encoded: $0.ciphertext)?.range(of: Data("FIXTURE_DISABLED_AUTH".utf8)) != nil })
  }

  func testHiddenIgnoredWorkJunkRenameDeleteAndHardlinks() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write(".gitignore", "ignored.txt\n")
    try f.write("yarn.lock", "fixture dependency lock"); try f.write("ignored.txt", "keep me"); try f.write("dist/authored.txt", "authored")
    try f.write("node_modules/generated.js", "junk")
    try f.write("old.txt", "rename me"); try f.write("delete.txt", "retain history")
    try FileManager.default.linkItem(at: f.source.appendingPathComponent("old.txt"), to: f.source.appendingPathComponent("hard.txt"))
    let engine = f.engine()
    let first = try await engine.snapshot(f.root(), eventCursor: "1", at: 1)
    XCTAssertTrue(first.manifest.entries.contains { $0.relativePath == "yarn.lock" })
    XCTAssertTrue(first.manifest.entries.contains { $0.relativePath == "ignored.txt" })
    XCTAssertTrue(first.manifest.entries.contains { $0.relativePath == "dist/authored.txt" })
    XCTAssertFalse(first.manifest.entries.contains { $0.relativePath == "node_modules/generated.js" })
    XCTAssertEqual(first.manifest.exclusions.first?.count, 2)
    XCTAssertEqual(first.manifest.exclusions.first?.bytes, 4)
    XCTAssertNotNil(first.manifest.entries.first { $0.relativePath == "old.txt" }?.hardlinkGroup)
    XCTAssertEqual(first.manifest.entries.first { $0.relativePath == "old.txt" }?.hardlinkGroup, first.manifest.entries.first { $0.relativePath == "hard.txt" }?.hardlinkGroup)
    try FileManager.default.moveItem(at: f.source.appendingPathComponent("old.txt"), to: f.source.appendingPathComponent("new.txt"))
    try FileManager.default.removeItem(at: f.source.appendingPathComponent("delete.txt"))
    let second = try await engine.snapshot(f.root(), eventCursor: "2", at: 2)
    XCTAssertTrue(second.manifest.markers.contains { $0.kind == .renamed && $0.previousPath == "old.txt" && $0.path == "new.txt" })
    XCTAssertTrue(second.manifest.markers.contains { $0.kind == .archived && $0.path == "delete.txt" })
    XCTAssertEqual(second.queuedContentChunks, 0)
  }

  func testS14StableIDsAndRootBinding() async throws {
    let a = try CloudBackupFixture(); defer { a.clean() }
    let b = try CloudBackupFixture(); defer { b.clean() }
    try a.write("file", "a"); try b.write("file", "b")
    let first = try await a.engine().snapshot(a.root(project: "A"), eventCursor: "1", at: 1)
    let second = try await b.engine().snapshot(b.root(project: "B"), eventCursor: "1", at: 1)
    XCTAssertNotEqual(first.manifest.projectId, second.manifest.projectId)
    XCTAssertNotEqual(first.manifest.entries[0].entryId, second.manifest.entries[0].entryId)
    do {
      _ = try await a.engine().snapshot(.init(projectId: "A", rootId: "root", deviceId: "fixture", directory: b.source), eventCursor: "2", at: 2)
      XCTFail("A root identifier must not be rebound to another path silently")
    } catch { XCTAssertEqual(error as? CloudBackupError, .destinationChanged) }
  }
}
