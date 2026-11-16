import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudRestoreTests: XCTestCase, @unchecked Sendable {
  private func reader(_ f: CloudBackupFixture) -> CloudRestoreReader {
    .init(fetch: { try await f.outbox.read($0) }, brain: f.brain, secrets: f.secrets)
  }
  private func changed(_ manifest: CloudBackupManifest, entries: [CloudBackupEntry]) throws -> CloudBackupManifest {
    .init(v: manifest.v, snapshotId: manifest.snapshotId, projectId: manifest.projectId, rootId: manifest.rootId,
      deviceId: manifest.deviceId, parentSnapshotId: manifest.parentSnapshotId, at: manifest.at,
      eventCursor: manifest.eventCursor, scanComplete: true, entries: entries, exclusions: [], markers: [], blocked: [],
      inventoryDigest: try CloudBackupDigest.of(entries))
  }
  private func entry(_ old: CloudBackupEntry, path: String, kind: CloudBackupEntry.Kind = .file, size: Int64? = nil,
                     chunks: [CloudBackupChunk]? = nil, link: String? = nil) -> CloudBackupEntry {
    .init(entryId: UUID().uuidString, relativePath: path, type: kind, mode: old.mode, mtimeNs: old.mtimeNs,
      size: size ?? (link.map { Int64($0.utf8.count) } ?? old.size), plainHash: link.map { CloudBackupDigest.sha256(Data($0.utf8)) } ?? old.plainHash,
      chunks: chunks ?? (kind == .file ? old.chunks : []), linkTarget: link, hardlinkGroup: nil, storageClass: old.storageClass)
  }

  func testS05CloudReadbackKeepsExistingBytesAndProvenance() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("note.txt", "cloud revision"); try f.write(".env", "FIXTURE_ONLY=cloud")
    try f.write("dir/nested.txt", "nested"); try f.write("dir-before.txt", "ordering")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "fixture-cut", at: 1)
    let reader = reader(f)
    let manifest = try await reader.manifest(snapshot.root)
    XCTAssertEqual(manifest.entries, snapshot.manifest.entries)
    let destination = f.base.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let note = destination.appendingPathComponent("note.txt"), env = destination.appendingPathComponent(".env")
    try Data("local revision".utf8).write(to: note); try Data("FIXTURE_ONLY=local".utf8).write(to: env)
    let planner = CloudRestorePlanner(reader: reader)
    let plan = try await planner.plan(manifest: manifest, sourceManifestHash: snapshot.root.sha256, destination: destination)
    XCTAssertNotEqual(plan.destination, destination.path)
    XCTAssertEqual(plan.conflicts.count, 2)
    let receipt = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "local revision")
    XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "FIXTURE_ONLY=local")
    XCTAssertEqual(try String(contentsOfFile: receipt.destination + "/note.txt", encoding: .utf8), "cloud revision")
    XCTAssertEqual(try String(contentsOfFile: receipt.destination + "/.env", encoding: .utf8), "FIXTURE_ONLY=cloud")
    XCTAssertTrue(receipt.ready)
    let proof = try JSONDecoder().decode(CloudRestorePlan.self, from: Data(contentsOf: URL(fileURLWithPath: receipt.provenanceFile)))
    XCTAssertEqual(proof.sourceManifestHash, snapshot.root.sha256)
    XCTAssertEqual(proof.sourceDeviceId, "fixture-machine-a")
    XCTAssertEqual(proof.sourceSnapshotAt, 1)
    XCTAssertEqual(proof.conflicts.first { $0.relativePath == "note.txt" }?.localHash, CloudBackupDigest.sha256(Data("local revision".utf8)))
    XCTAssertEqual(proof.conflicts.first { $0.relativePath == "note.txt" }?.cloudHash, CloudBackupDigest.sha256(Data("cloud revision".utf8)))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: receipt.destination + "/.env")[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testS11SourceProcessHooksAndPathsStayUnchanged() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    let hooks = f.base.appendingPathComponent("source-hooks.conf"), paths = f.base.appendingPathComponent("source-paths.json")
    try Data("fixture hook endpoint".utf8).write(to: hooks); try Data("fixture machine paths".utf8).write(to: paths)
    try f.write("work.txt", "unfinished work")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["60"]
    process.currentDirectoryURL = f.source; process.environment = ["HOME": f.base.path, "PATH": "/usr/bin:/bin"]
    try process.run()
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    let pid = process.processIdentifier
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let planner = CloudRestorePlanner(reader: reader(f))
    let plan = try await planner.plan(manifest: snapshot.manifest, sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("restored"))
    _ = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertTrue(process.isRunning)
    XCTAssertEqual(process.processIdentifier, pid)
    XCTAssertEqual(try String(contentsOf: hooks, encoding: .utf8), "fixture hook endpoint")
    XCTAssertEqual(try String(contentsOf: paths, encoding: .utf8), "fixture machine paths")
    XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("work.txt"), encoding: .utf8), "unfinished work")
  }

  func testUnsafePathsSymlinkEscapeAndOversizedArchiveAreRefused() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("file", "fixture")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let old = try XCTUnwrap(snapshot.manifest.entries.first)
    let planner = CloudRestorePlanner(reader: reader(f))
    for path in ["../escape", "/absolute", "C:/drive", "\\\\server\\file", "a/../../escape"] {
      do {
        _ = try await planner.plan(manifest: changed(snapshot.manifest, entries: [entry(old, path: path)]), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("unsafe"))
        XCTFail("An unsafe entry was accepted")
      } catch { XCTAssertEqual(error as? CloudBackupError, .unsafePath) }
    }
    do {
      _ = try await planner.plan(manifest: changed(snapshot.manifest, entries: [entry(old, path: "link", kind: .symlink, link: "../outside")]), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("unsafe"))
      XCTFail("An escaping link was accepted")
    } catch { XCTAssertEqual(error as? CloudBackupError, .unsafePath) }
    do {
      _ = try await planner.plan(manifest: changed(snapshot.manifest, entries: [entry(old, path: "link", kind: .symlink, link: "inside"), entry(old, path: "link/file")]), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("unsafe"))
      XCTFail("A link was accepted as a write parent")
    } catch { XCTAssertEqual(error as? CloudBackupError, .unsafePath) }
    let blob = try XCTUnwrap(old.chunks.first?.blob)
    let hugeChunks = Array(repeating: CloudBackupChunk(blob: blob, offset: 0, length: CloudWire.maximumPlainChunkBytes, plainHash: old.plainHash), count: 1152)
    do {
      _ = try await planner.plan(manifest: changed(snapshot.manifest, entries: [entry(old, path: "oversized.zip", size: 9 * 1024 * 1024 * 1024, chunks: hugeChunks)]), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("unsafe"))
      XCTFail("An oversized declared archive was accepted")
    } catch { XCTAssertEqual(error as? CloudBackupError, .limitExceeded) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("unsafe").path))
  }

  func testStalePlanWrongDigestAndTamperedBlobNeverPublish() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("file", "fixture")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let planner = CloudRestorePlanner(reader: reader(f))
    let target = f.base.appendingPathComponent("target")
    let first = try await planner.plan(manifest: snapshot.manifest, sourceManifestHash: snapshot.root.sha256, destination: target)
    do { _ = try await planner.restore(restoreId: first.restoreId, planDigest: "wrong"); XCTFail("Wrong digest accepted") }
    catch { XCTAssertEqual(error as? CloudBackupError, .destinationChanged) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: target.appendingPathComponent("local"))
    do { _ = try await planner.restore(restoreId: first.restoreId, planDigest: first.digest); XCTFail("Stale plan accepted") }
    catch { XCTAssertEqual(error as? CloudBackupError, .destinationChanged) }
    let second = try await planner.plan(manifest: snapshot.manifest, sourceManifestHash: snapshot.root.sha256, destination: target)
    await f.outbox.corrupt(try XCTUnwrap(snapshot.manifest.entries.first?.chunks.first?.blob))
    do { _ = try await planner.restore(restoreId: second.restoreId, planDigest: second.digest); XCTFail("Tampered blob published") }
    catch { XCTAssertEqual(error as? CloudBackupError, .readbackFailed) }
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("local"), encoding: .utf8), "keep")
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.destination))
  }

  func testCaseCollisionsKeepBothFiles() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("file", "fixture")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let old = try XCTUnwrap(snapshot.manifest.entries.first)
    let planner = CloudRestorePlanner(reader: reader(f))
    let plan = try await planner.plan(manifest: changed(snapshot.manifest, entries: [old, entry(old, path: "FILE")]), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("case-copy"))
    XCTAssertEqual(plan.conflicts.count, 1)
    XCTAssertEqual(Set(plan.members.map { $0.restoredPath.lowercased() }).count, 2)
    let receipt = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertEqual(receipt.restored, 2)
    for member in plan.members {
      XCTAssertEqual(try String(contentsOfFile: receipt.destination + "/" + member.restoredPath, encoding: .utf8), "fixture")
    }
  }
  func testAM2OrdinaryWorkRestoresWhileSecretsAreLocked() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("work.txt", "ordinary work"); try f.write(".env", "FIXTURE_ONLY=private")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    await f.secrets.lock()
    let reader = reader(f)
    let manifest = try await reader.manifest(snapshot.root, includeSecrets: false)
    XCTAssertEqual(manifest.entries.map(\.relativePath), ["work.txt"])
    XCTAssertEqual(manifest.blocked.count, 1)
    let planner = CloudRestorePlanner(reader: reader)
    let plan = try await planner.plan(manifest: manifest, sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("ordinary-copy"))
    let receipt = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertEqual(try String(contentsOfFile: receipt.destination + "/work.txt", encoding: .utf8), "ordinary work")
    XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.destination + "/.env"))
    XCTAssertEqual(receipt.blocked, 1)
    XCTAssertFalse(receipt.ready)
  }

  func testUnicodeCollisionsKeepBothOriginalNamesInProvenance() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("file", "fixture")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let old = try XCTUnwrap(snapshot.manifest.entries.first)
    let planner = CloudRestorePlanner(reader: reader(f))
    let names = ["caf\u{00e9}", "cafe\u{0301}"]
    let plan = try await planner.plan(manifest: changed(snapshot.manifest, entries: names.map { entry(old, path: $0) }), sourceManifestHash: snapshot.root.sha256, destination: f.base.appendingPathComponent("unicode-copy"))
    XCTAssertEqual(plan.conflicts.count, 1)
    XCTAssertEqual(Set(plan.members.map { Data($0.relativePath.utf8) }).count, 2)
    let receipt = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertEqual(receipt.restored, 2)
    for member in plan.members { XCTAssertEqual(try String(contentsOfFile: receipt.destination + "/" + member.restoredPath, encoding: .utf8), "fixture") }
  }

}
