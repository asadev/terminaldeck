import Foundation
import SQLite3
import XCTest
@testable import TerminalDeckNativeCore

final class CloudBackupDatabaseTests: XCTestCase, @unchecked Sendable {
  func testS12CommittedWALSurvivesSealedBackupAndFreshRestore() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("live.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
    let live = try XCTUnwrap(db)
    defer { sqlite3_close(live) }
    XCTAssertEqual(sqlite3_exec(live, "CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO items(value) VALUES('fixture-a'),('fixture-b'),('fixture-c');", nil, nil, nil), SQLITE_OK)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))
    let package = f.base.appendingPathComponent("database-package")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    let outcome = try CloudBackupDatabase.snapshot(engine: "sqlite", source: source, destination: package.appendingPathComponent("data.sqlite"), storageClass: .brain)
    guard case .snapshot(let database) = outcome else { return XCTFail("SQLite snapshot was not created") }
    XCTAssertEqual(database.proof.tables.first { $0.name == "items" }?.rows, 3)
    XCTAssertTrue(database.proof.exporter.hasPrefix("sqlite3_backup/"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.file.path + "-wal"))
    let root = CloudBackupRoot(projectId: "project", rootId: "database", deviceId: "fixture-a", directory: package, verifiedDatabases: ["data.sqlite": database])
    let snapshot = try await f.engine().snapshot(root, eventCursor: "1", at: 1)
    // 16 Nov release check: say WHAT was held back and what the package held, so one run names the cause
    // (suspected: the exporter's ".cloud-sqlite-<id>" stage folder left behind with a SQLite sidecar in it).
    let packageListing = (FileManager.default.enumerator(atPath: package.path)?.allObjects as? [String] ?? []).sorted()
    XCTAssertTrue(snapshot.manifest.scanComplete, "blocked: \(snapshot.manifest.blocked); package holds: \(packageListing)")
    XCTAssertEqual(snapshot.manifest.entries.first { $0.relativePath == "data.sqlite" }?.database?.tables, database.proof.tables,
                   "entries: \(snapshot.manifest.entries.map(\.relativePath))")
    let reader = CloudRestoreReader(fetch: { try await f.outbox.read($0) }, brain: f.brain, secrets: f.secrets)
    let manifest = try await reader.manifest(snapshot.root)
    let planner = CloudRestorePlanner(reader: reader)
    let destination = f.base.appendingPathComponent("restored-db")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("existing database must stay".utf8).write(to: destination.appendingPathComponent("data.sqlite"))
    let plan = try await planner.plan(manifest: manifest, sourceManifestHash: snapshot.root.sha256, destination: destination)
    let receipt = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    let restored = try CloudBackupDatabase.inspect(URL(fileURLWithPath: receipt.destination).appendingPathComponent("data.sqlite"), storageClass: .brain, consistentThrough: database.proof.consistentThrough)
    XCTAssertEqual(restored.tables.first { $0.name == "items" }?.rows, 3)
    XCTAssertEqual(restored.sha256, database.proof.sha256)
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("data.sqlite"), encoding: .utf8), "existing database must stay")
    XCTAssertTrue(receipt.ready)
    XCTAssertEqual(sqlite3_exec(live, "INSERT INTO items(value) VALUES('still-running');", nil, nil, nil), SQLITE_OK)
  }

  func testS12EveryOtherDatabaseEngineIsExplicitlyBlocked() throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    for engine in ["postgres", "mysql", "redis", "mongodb", "docker-volume"] {
      let result = try CloudBackupDatabase.snapshot(engine: engine, source: f.source.appendingPathComponent("not-read"), destination: f.base.appendingPathComponent("not-created"), storageClass: .brain)
      guard case .blocked(let actual, let reason) = result else { return XCTFail("Unsupported database reported success") }
      XCTAssertEqual(actual, engine)
      XCTAssertFalse(reason.isEmpty)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("not-created").path))
  }

  func testUnverifiedLiveDatabaseIsNeverCopiedAsAWorkFile() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    try f.write("database.sqlite", "not a consistent export")
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    XCTAssertFalse(snapshot.manifest.scanComplete)
    XCTAssertTrue(snapshot.manifest.entries.isEmpty)
    XCTAssertEqual(snapshot.manifest.blocked.count, 1)
  }
}
