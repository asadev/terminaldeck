import XCTest
import Foundation
import Darwin
@testable import TerminalDeckNativeCore

final class RNMHootDataMigrationTests: XCTestCase {
    private struct Interrupted: Error {}
    private func fixture(_ body: (URL, RNMHootDataMigration) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("RNM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, RNMHootDataMigration(dataRoot: root))
    }
    private func write(_ text: String, _ root: URL, _ relative: String) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func read(_ root: URL, _ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
    private func exists(_ root: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
    private func stages(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".hoot-migration-stage-") }
    }

    func testPathsAreInertAndUseOneNewSpelling() throws {
        try fixture { root, migration in
            let paths = migration.paths
            XCTAssertEqual(paths.dataRoot.path, root.path)
            XCTAssertTrue(paths.dataRoot.path.hasPrefix("/private/tmp/RNM-"))
            XCTAssertEqual(paths.home.lastPathComponent, "hoot")
            XCTAssertEqual(paths.layer.lastPathComponent, "hoot-layer")
            XCTAssertEqual(paths.log.lastPathComponent, "hoot-log")
            XCTAssertEqual(paths.composed.lastPathComponent, "hoot.md")
            XCTAssertEqual(paths.actions.path, paths.log.appendingPathComponent("actions.jsonl").path)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testOldOnlyFoldersAreAtomicallyMovedWithInodeAndBytesPreserved() throws {
        try fixture { root, migration in
            for folder in RNMHootPaths.Folder.allCases { try write("saved-\(folder.rawValue)", root, folder.legacyName + "/data") }
            var oldInfo = stat(), newInfo = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent("copilot").path, &oldInfo), 0)
            let launch = try migration.prepareForLaunch()
            XCTAssertEqual(lstat(root.appendingPathComponent("hoot").path, &newInfo), 0)
            XCTAssertEqual(oldInfo.st_ino, newInfo.st_ino)
            XCTAssertEqual(launch.archives.count, 0)
            for folder in RNMHootPaths.Folder.allCases {
                XCTAssertFalse(exists(root, folder.legacyName))
                XCTAssertEqual(try read(root, folder.rawValue + "/data"), "saved-\(folder.rawValue)")
            }
            let replay = try migration.prepareForLaunch()
            XCTAssertTrue(replay.archives.isEmpty)
            XCTAssertEqual(try read(root, "hoot/data"), "saved-hoot")
        }
    }

    func testMergePreservesUniqueIdenticalConflictingAndFileDirectoryCollisions() throws {
        try fixture { root, migration in
            try write("old", root, "copilot/unique/note.md")
            try write("same", root, "copilot/same.md")
            try write("same", root, "hoot/same.md")
            try write("old-conflict", root, "copilot/conflict.md")
            try write("new-conflict", root, "hoot/conflict.md")
            try write("old-dir-child", root, "copilot/directory/child")
            try write("new-file", root, "hoot/directory")
            try write("old-file", root, "copilot/file")
            try write("new-dir-child", root, "hoot/file/child")
            let launch = try migration.prepareForLaunch()
            let archive = try XCTUnwrap(launch.archives.first)
            XCTAssertTrue(archive.url.lastPathComponent.hasPrefix("copilot.migrated-"))
            XCTAssertEqual(archive.copied, 1)
            XCTAssertEqual(Set(archive.collisionPaths), ["same.md", "conflict.md", "directory", "file"])
            XCTAssertFalse(exists(root, "copilot"))
            XCTAssertEqual(try read(root, "hoot/unique/note.md"), "old")
            XCTAssertEqual(try read(root, "hoot/conflict.md"), "new-conflict")
            XCTAssertEqual(try read(root, "hoot/directory"), "new-file")
            XCTAssertEqual(try read(root, "hoot/file/child"), "new-dir-child")
            XCTAssertEqual(try read(archive.url, "conflict.md"), "old-conflict")
            XCTAssertEqual(try read(archive.url, "same.md"), "same")
            XCTAssertEqual(try read(archive.url, "directory/child"), "old-dir-child")
            XCTAssertEqual(try read(archive.url, "file"), "old-file")
        }
    }

    func testPartialMergeRetriesFromDurableJournalAcrossNewInstances() throws {
        try fixture { root, migration in
            try write("A", root, "copilot/a")
            try write("B", root, "copilot/b")
            try write("new", root, "hoot/existing")
            XCTAssertThrowsError(try migration.prepareForLaunch(checkpoint: { point in
                if point == .filePublished(.home, "a") { throw Interrupted() }
            }))
            XCTAssertEqual(try read(root, "copilot/a"), "A")
            XCTAssertEqual(try read(root, "copilot/b"), "B")
            XCTAssertEqual(try read(root, "hoot/a"), "A")
            XCTAssertFalse(exists(root, "hoot/b"))
            let recovered = try RNMHootDataMigration(dataRoot: root).prepareForLaunch()
            XCTAssertEqual(recovered.archives.count, 1)
            XCTAssertEqual(recovered.archives.first?.copied, 2)
            XCTAssertEqual(try read(root, "hoot/b"), "B")
            XCTAssertEqual(try read(root, "hoot/existing"), "new")
            let replay = try RNMHootDataMigration(dataRoot: root).prepareForLaunch()
            XCTAssertEqual(replay.archives.map(\.url), recovered.archives.map(\.url))
        }
    }

    func testInterruptedBeforeArchiveRetainsOldAndReplaysWithoutDuplicateArchives() throws {
        try fixture { root, migration in
            try write("old", root, "copilot/one")
            try write("new", root, "hoot/two")
            XCTAssertThrowsError(try migration.prepareForLaunch(checkpoint: { point in
                if point == .beforeArchive(.home) { throw Interrupted() }
            }))
            XCTAssertTrue(exists(root, "copilot/one"))
            let recovered = try RNMHootDataMigration(dataRoot: root).prepareForLaunch()
            XCTAssertEqual(recovered.archives.count, 1)
            XCTAssertEqual(try read(root, "hoot/one"), "old")
            XCTAssertEqual(try read(try XCTUnwrap(recovered.archives.first).url, "one"), "old")
        }
    }

    func testInterruptedAfterArchiveAndAfterAtomicRenameRecoverWithoutDataLoss() throws {
        for merge in [false, true] {
            try fixture { root, migration in
                try write("old", root, "copilot/one")
                if merge { try write("new", root, "hoot/two") }
                let interruption: RNMHootDataMigration.Checkpoint = merge ? .archiveMoved(.home) : .directoryRenamed(.home)
                XCTAssertThrowsError(try migration.prepareForLaunch(checkpoint: { point in
                    if point == interruption { throw Interrupted() }
                }))
                XCTAssertFalse(exists(root, "copilot"))
                XCTAssertEqual(try stages(root).count, merge ? 1 : 0)
                let recovered = try RNMHootDataMigration(dataRoot: root).prepareForLaunch()
                XCTAssertEqual(try read(root, "hoot/one"), "old")
                XCTAssertEqual(recovered.archives.count, merge ? 1 : 0)
                XCTAssertTrue(try stages(root).isEmpty)
                let receipt = try migration.confirmRead([.home], on: recovered)
                XCTAssertFalse(receipt.archives.first?.readOnSubsequentLaunch ?? false)
            }
        }
    }

    func testArchiveReadReceiptRequiresLaterLaunchAndNeverDeletesConflicts() throws {
        try fixture { root, migration in
            try write("old", root, "copilot/same")
            try write("new", root, "hoot/same")
            let first = try migration.prepareForLaunch()
            let premature = try migration.confirmRead([.home], on: first)
            XCTAssertFalse(try XCTUnwrap(premature.archives.first).readOnSubsequentLaunch)
            let second = try migration.prepareForLaunch()
            XCTAssertThrowsError(try migration.confirmRead([.home], on: first))
            let read = try migration.confirmRead([.home], on: second)
            let archive = try XCTUnwrap(read.archives.first)
            XCTAssertTrue(archive.readOnSubsequentLaunch)
            XCTAssertEqual(try self.read(archive.url, "same"), "old")
            let third = try migration.prepareForLaunch()
            XCTAssertEqual(third.archives.map(\.url), read.archives.map(\.url))
            XCTAssertEqual(try self.read(root, "hoot/same"), "new")
        }
    }

    func testSourceAndDestinationSymlinksAreRefusedWithoutFollowingThem() throws {
        for relative in ["copilot", "copilot/link", "hoot/link"] {
            try fixture { root, migration in
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try write("outside", root, "outside/secret")
                if relative != "copilot" { try write("old", root, "copilot/one"); try write("new", root, "hoot/two") }
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(relative), withDestinationURL: outside)
                XCTAssertThrowsError(try migration.prepareForLaunch())
                XCTAssertEqual(try read(root, "outside/secret"), "outside")
                XCTAssertTrue(exists(root, "copilot"))
                if relative != "copilot" { XCTAssertEqual(try read(root, "copilot/one"), "old") }
            }
        }
    }

    func testSymlinkAncestorIsRefusedBeforeCreatingAnythingUnderItsTarget() throws {
        try fixture { root, _ in
            let actual = root.appendingPathComponent("actual", isDirectory: true)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            let link = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
            let migration = RNMHootDataMigration(dataRoot: link.appendingPathComponent("data", isDirectory: true))
            XCTAssertThrowsError(try migration.prepareForLaunch())
            XCTAssertFalse(exists(actual, "data"))
        }
    }

    func testMalformedJournalAndMissingRecoveryDestinationRetainSource() throws {
        try fixture { root, migration in
            try write("old", root, "copilot/one")
            try write("invalid", root, ".hoot-migration.json")
            XCTAssertThrowsError(try migration.prepareForLaunch())
            XCTAssertEqual(try read(root, "copilot/one"), "old")
            try FileManager.default.removeItem(at: migration.paths.migrationJournal)
            try write("new", root, "hoot/two")
            XCTAssertThrowsError(try migration.prepareForLaunch(checkpoint: { point in
                if point == .beforeArchive(.home) { throw Interrupted() }
            }))
            try FileManager.default.removeItem(at: migration.paths.home)
            XCTAssertThrowsError(try RNMHootDataMigration(dataRoot: root).prepareForLaunch())
            XCTAssertEqual(try read(root, "copilot/one"), "old")
        }
    }

    func testFileLockContentionRefusesAndAbandonedLockFileIsReusable() throws {
        try fixture { root, migration in
            try write("old", root, "copilot/one")
            let fd = Darwin.open(migration.paths.migrationLock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try migration.prepareForLaunch()) { error in
                XCTAssertEqual((error as? NativeRPCError)?.code, "hoot-migration-busy")
            }
            XCTAssertTrue(exists(root, "copilot/one"))
            XCTAssertFalse(exists(root, "hoot"))
            _ = flock(fd, LOCK_UN); Darwin.close(fd)
            // The stale lock FILE remains, but the kernel releases its owner.
            _ = try RNMHootDataMigration(dataRoot: root).prepareForLaunch()
            XCTAssertEqual(try read(root, "hoot/one"), "old")
        }
    }

    func testNewLegacyWriterGetsSeparateArchiveAndLogsDoNotContainContents() throws {
        try fixture { root, migration in
            try write("secret-original-content", root, "copilot/one")
            try write("new", root, "hoot/two")
            let first = try migration.prepareForLaunch()
            try write("later", root, "copilot/three")
            let second = try migration.prepareForLaunch()
            XCTAssertEqual(second.archives.count, 2)
            XCTAssertNotEqual(first.archives.first?.url, second.archives.last?.url)
            XCTAssertEqual(try read(root, "hoot/three"), "later")
            let lines = try read(root, "hoot-migration.jsonl").split(separator: "\n")
            XCTAssertGreaterThanOrEqual(lines.count, 4)
            for line in lines { _ = try JSONDecoder().decode(RNMHootDataMigration.Event.self, from: Data(line.utf8)) }
            XCTAssertFalse(lines.contains { $0.contains("secret-original-content") })
        }
    }

    func testSeparateProcessesReplayAnInterruptedJournalAndLeaveOneArchive() throws {
        try fixture { root, migration in
            try write("A", root, "copilot/a")
            try write("B", root, "copilot/b")
            try write("new", root, "hoot/existing")
            try runSubprocess(root: root, action: "interrupt")
            XCTAssertTrue(exists(root, "copilot/a"))
            XCTAssertTrue(exists(root, "hoot/a"))
            XCTAssertFalse(exists(root, "hoot/b"))
            XCTAssertEqual(try stages(root).count, 1)
            try runSubprocess(root: root, action: "recover")
            XCTAssertTrue(try stages(root).isEmpty)
            let replay = try migration.prepareForLaunch()
            XCTAssertEqual(replay.archives.count, 1)
            XCTAssertEqual(try read(root, "hoot/b"), "B")
            XCTAssertEqual(try read(try XCTUnwrap(replay.archives.first).url, "a"), "A")
        }
    }

    // Relaunch the current runner, including its loaded bundle for Apple's
    // xctest host. The standalone focused runner needs only the test selector.
    func testMigrationSubprocessHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["RNM_MIGRATION_TEST_ROOT"], raw.hasPrefix("/private/tmp/RNM-"),
              let action = environment["RNM_MIGRATION_TEST_ACTION"], ["interrupt", "recover"].contains(action) else {
            throw XCTSkip("Only the private RNM subprocess fixture invokes this helper.")
        }
        let migration = RNMHootDataMigration(dataRoot: URL(fileURLWithPath: raw, isDirectory: true))
        if action == "interrupt" {
            XCTAssertThrowsError(try migration.prepareForLaunch(checkpoint: { point in
                if point == .filePublished(.home, "a") { throw Interrupted() }
            }))
        } else {
            XCTAssertEqual(try migration.prepareForLaunch().archives.count, 1)
        }
    }

    private func runSubprocess(root: URL, action: String) throws {
        let process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let selection = NSStringFromClass(type(of: self)) + "/testMigrationSubprocessHelper"
        process.executableURL = executable
        if executable.lastPathComponent == "xctest" {
            let bundle = Bundle(for: RNMHootDataMigrationTests.self).bundleURL
            guard bundle.pathExtension == "xctest" else {
                throw NativeRPCError(code: "test-runner", message: "The migration subprocess needs its loaded XCTest bundle.")
            }
            process.arguments = ["-XCTest", selection, bundle.path]
        } else {
            process.arguments = [selection]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["RNM_MIGRATION_TEST_ROOT"] = root.path
        environment["RNM_MIGRATION_TEST_ACTION"] = action
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "The private migration subprocess failed: \(text)")
    }
}
