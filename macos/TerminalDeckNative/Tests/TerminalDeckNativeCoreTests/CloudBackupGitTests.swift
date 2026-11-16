import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudBackupGitTests: XCTestCase, @unchecked Sendable {
  func testS13OfflineRestoreRetainsUnpushedAndPartiallyStagedWork() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    let control = f.base.appendingPathComponent("git-control")
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
    func git(_ args: [String], at root: URL? = nil) throws -> Data { try CloudBackupGit.run(root ?? f.source, args, control: control) }
    _ = try git(["init"])
    _ = try git(["config", "user.name", "Fixture Person"])
    _ = try git(["config", "user.email", "fixture@example.invalid"])
    try f.write("work.txt", "base\n"); try f.write(".gitignore", "ignored.data\n.env\n")
    _ = try git(["add", "work.txt", ".gitignore"])
    _ = try git(["commit", "-m", "fixture base"])
    try f.write("local-only.txt", "unpublished commit\n")
    _ = try git(["add", "local-only.txt"]); _ = try git(["commit", "-m", "unpushed fixture"])
    _ = try git(["remote", "add", "origin", "https://fixture-user:fixture-password@unavailable.invalid/project.git?fixture=private"])
    try f.write("work.txt", "staged bytes\n"); _ = try git(["add", "work.txt"])
    try f.write("work.txt", "unstaged bytes\n"); try f.write("untracked.txt", "untracked bytes")
    try f.write("ignored.data", "ignored bytes"); try f.write(".env", "FIXTURE_ONLY=private")
    let branch = String(decoding: try git(["symbolic-ref", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try git(["symbolic-ref", "refs/heads/fixture-alias", branch])
    let indexBefore = try git(["ls-files", "--stage", "-z"])
    let configBefore = try Data(contentsOf: f.source.appendingPathComponent(".git/config"))
    let package = f.base.appendingPathComponent("git-package")
    let facts = try await CloudBackupGit.capture(source: f.source, package: package, classify: CloudBackupFixture.classify)
    XCTAssertTrue(facts.remoteURLs.allSatisfy { !$0.contains("fixture-password") && !$0.contains("fixture-user") && !$0.contains("private") })
    XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(".git/config")), configBefore)
    XCTAssertEqual(try git(["ls-files", "--stage", "-z"]), indexBefore)
    XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("history.bundle").path))
    let work = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let bundle = try await f.engine().snapshot(.init(projectId: "project", rootId: "git-state", deviceId: "fixture-machine-a", directory: package), eventCursor: "1", at: 1)
    let reader = CloudRestoreReader(fetch: { try await f.outbox.read($0) }, brain: f.brain, secrets: f.secrets)
    let planner = CloudRestorePlanner(reader: reader)
    let restoredPackagePlan = try await planner.plan(manifest: reader.manifest(bundle.root), sourceManifestHash: bundle.root.sha256, destination: f.base.appendingPathComponent("package-on-b"))
    let restoredPackage = try await planner.restore(restoreId: restoredPackagePlan.restoreId, planDigest: restoredPackagePlan.digest)
    let workPlan = try await planner.plan(manifest: reader.manifest(work.root), sourceManifestHash: work.root.sha256, destination: f.base.appendingPathComponent("project-on-b"))
    let restoredWork = try await planner.restore(restoreId: workPlan.restoreId, planDigest: workPlan.digest)
    let destination = URL(fileURLWithPath: restoredWork.destination)
    let verified = try CloudBackupGit.restore(package: URL(fileURLWithPath: restoredPackage.destination), destination: destination)
    XCTAssertEqual(verified.head, facts.head)
    XCTAssertEqual(String(decoding: try git(["symbolic-ref", "refs/heads/fixture-alias"], at: destination), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), branch)
    XCTAssertEqual(try git(["ls-files", "--stage", "-z"], at: destination), indexBefore)
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("work.txt"), encoding: .utf8), "unstaged bytes\n")
    XCTAssertEqual(String(decoding: try git(["show", ":work.txt"], at: destination), as: UTF8.self), "staged bytes\n")
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("untracked.txt"), encoding: .utf8), "untracked bytes")
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("ignored.data"), encoding: .utf8), "ignored bytes")
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(".env"), encoding: .utf8), "FIXTURE_ONLY=private")
    XCTAssertEqual(String(decoding: try git(["show", "HEAD:local-only.txt"], at: destination), as: UTF8.self), "unpublished commit\n")
    XCTAssertEqual(try git(["remote"], at: destination), Data())
    do { _ = try CloudBackupGit.restore(package: package, destination: destination); XCTFail("Existing Git state was overwritten") }
    catch { XCTAssertEqual(error as? CloudBackupError, .alreadyExists) }
  }

  func testGitHistoryWithProtectedFilesIsBlockedRatherThanDowngraded() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    let control = f.base.appendingPathComponent("control")
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
    _ = try CloudBackupGit.run(f.source, ["init"], control: control)
    try f.write(".env", "FIXTURE_ONLY=private")
    _ = try CloudBackupGit.run(f.source, ["add", ".env"], control: control)
    _ = try CloudBackupGit.run(f.source, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "protected fixture"], control: control)
    do {
      _ = try await CloudBackupGit.capture(source: f.source, package: f.base.appendingPathComponent("blocked"), classify: CloudBackupFixture.classify)
      XCTFail("Protected Git history was exported as ordinary bytes")
    } catch { XCTAssertEqual(error as? CloudBackupError, .incomplete) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("blocked/history.bundle").path))
  }
}
