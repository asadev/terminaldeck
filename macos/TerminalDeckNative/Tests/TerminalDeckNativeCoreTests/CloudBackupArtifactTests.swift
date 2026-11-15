import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudBackupArtifactTests: XCTestCase, @unchecked Sendable {
  func testFinishedAppTreeOverridesJunkWithoutIncludingOtherBuildOutput() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write(".build/Fixture.app/Contents/Info.plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Fixture</string></dict></plist>")
    try f.write(".build/Fixture.app/Contents/MacOS/Fixture", "fixture executable bytes")
    try f.write(".build/other-object.o", "rebuildable junk")
    let path = ".build/Fixture.app", file = f.source.appendingPathComponent(path)
    let artifact = try await CloudBackupArtifacts.inspect(file: file, artifactId: "fixture-build", completionId: "fixture-completed", completedAt: 1, settle: {})
    XCTAssertTrue(artifact.proof.bundle)
    XCTAssertEqual(artifact.proof.files, 2)
    let root = CloudBackupRoot(projectId: "project", rootId: "root", deviceId: "fixture", directory: f.source, verifiedArtifacts: [path: artifact])
    let snapshot = try await f.engine().snapshot(root, eventCursor: "1", at: 1)
    XCTAssertTrue(snapshot.manifest.scanComplete)
    XCTAssertEqual(snapshot.manifest.entries.first { $0.relativePath == path }?.artifact, artifact.proof)
    XCTAssertTrue(snapshot.manifest.entries.contains { $0.relativePath == path + "/Contents/MacOS/Fixture" })
    XCTAssertFalse(snapshot.manifest.entries.contains { $0.relativePath == ".build/other-object.o" })
  }
  func testArtifactChangingDuringStabilityCheckIsNotFinished() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("build.zip", "first")
    do {
      _ = try await CloudBackupArtifacts.inspect(file: f.source.appendingPathComponent("build.zip"), artifactId: "build", completionId: "fixture", completedAt: 1, settle: { try f.write("build.zip", "second and changing") })
      XCTFail("A changing artifact was called finished")
    } catch { XCTAssertEqual(error as? CloudBackupError, .changedDuringRead) }
  }
  func testExactArtifactSelectionDoesNotReadOrUploadItsNeighbours() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("build.zip", "selected build")
    try f.write("private.key", "FIXTURE_UNGRANTED_NEIGHBOUR")
    let artifact = try await CloudBackupArtifacts.inspect(file: f.source.appendingPathComponent("build.zip"), artifactId: "build", completionId: "fixture", completedAt: 1, settle: {})
    let root = CloudBackupRoot(projectId: "project", rootId: "outside-build", deviceId: "fixture", directory: f.source,
      verifiedArtifacts: ["build.zip": artifact], includedPaths: ["build.zip"])
    let snapshot = try await f.engine().snapshot(root, eventCursor: "1", at: 1)
    XCTAssertEqual(snapshot.manifest.entries.map(\.relativePath), ["build.zip"])
    XCTAssertEqual(snapshot.manifest.entries[0].artifact, artifact.proof)
    let brain = await f.brain.sealed, secrets = await f.secrets.sealed
    XCTAssertFalse((brain + secrets).contains { Data(base64Encoded: $0.ciphertext)?.range(of: Data("FIXTURE_UNGRANTED_NEIGHBOUR".utf8)) != nil })
    do {
      _ = try await f.engine().snapshot(.init(projectId: "project", rootId: "outside-build", deviceId: "fixture", directory: f.source), eventCursor: "2", at: 2)
      XCTFail("An exact-file root silently broadened to its directory")
    } catch { XCTAssertEqual(error as? CloudBackupError, .destinationChanged) }
  }
}
