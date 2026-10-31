import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatDiffActionsTests: XCTestCase, @unchecked Sendable {
    private actor Grant {
        let root: URL
        var writing = true
        init(_ root: URL) { self.root = root }
        func scope() -> BackendFilesystemScope { .init(readRoots: [root], writeRoots: writing ? [root] : []) }
        func revoke() { writing = false }
    }
    private struct Rig {
        let root: URL
        let service: BackendChatDiffActions
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "sess-diff-fixture")
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sess-diff-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = root
            service = BackendChatDiffActions(authority: .init { _ in .init(readRoots: [folder], writeRoots: [folder]) })
        }
        func write(_ text: String, path: String = "note.txt") throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        func read(_ path: String = "note.txt") throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private let patch = "--- a/note.txt\n+++ b/note.txt\n@@ -1,3 +1,3 @@\n head\n-old\n+new\n tail\n"
    private let before = "head\nold\ntail\n", after = "head\nnew\ntail\n"
    private func change(_ diff: String, path: String = "note.txt", kind: String = "update") -> NativeRPCValue {
        .object([.init("path", .string(path)), .init("kind", .object([.init("type", .string(kind))])), .init("diff", .string(diff))])
    }
    private func register(_ rig: Rig, _ change: NativeRPCValue) async throws -> NativeRPCValue {
        try await rig.service.register(change: change, projectRoot: rig.root.path, context: rig.context)
    }
    private func identifier(_ receipt: NativeRPCValue) throws -> String { try XCTUnwrap(receipt["id"].string) }
    private func errorCode(_ body: () async throws -> NativeRPCValue) async -> String? {
        do { _ = try await body(); return nil } catch let error as NativeRPCError { return error.code } catch { return "other" }
    }

    func testPendingApplyUsesExactVersionsPreservesModeAndTerminalReceiptOnRefresh() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.write(before)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: rig.root.appendingPathComponent("note.txt").path)
        let registered = try await register(rig, change(patch)), id = try identifier(registered)
        XCTAssertEqual(registered["state"].string, "pending")
        XCTAssertNotEqual(registered["beforeHash"], registered["afterHash"])
        let duplicate = try await register(rig, change(patch))
        XCTAssertEqual(duplicate["id"].string, id)
        let preview = try await rig.service.preview(id: id, context: rig.context)
        XCTAssertEqual(preview["patch"].string, patch)
        XCTAssertEqual(try rig.read(), before, "Preview cannot write the file")
        let applied = try await rig.service.apply(id: id, context: rig.context)
        XCTAssertEqual(applied["state"].string, "accepted")
        XCTAssertEqual(applied["verified"].bool, true)
        XCTAssertEqual(applied["wroteFile"].bool, true)
        XCTAssertEqual(try rig.read(), after)
        let permissions = try FileManager.default.attributesOfItem(atPath: rig.root.appendingPathComponent("note.txt").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o750)
        let refreshed = try await register(rig, change(patch))
        XCTAssertEqual(refreshed["id"].string, id)
        XCTAssertEqual(refreshed["state"].string, "accepted")
        try rig.write("person's later edit\n")
        _ = try await rig.service.apply(id: id, context: rig.context)
        XCTAssertEqual(try rig.read(), "person's later edit\n", "A repeated action must never replay a write")
        let refusal = await errorCode { try await rig.service.reject(id: id, context: rig.context) }
        XCTAssertEqual(refusal, "diff-decided")
    }

    func testAlreadyAppliedChangeRejectsOnlyByItsVerifiedExactBeforeVersion() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(after)
        let registered = try await register(rig, change(patch)), id = try identifier(registered)
        XCTAssertEqual(registered["state"].string, "alreadyApplied")
        XCTAssertEqual(registered["canApply"].bool, false)
        let rejected = try await rig.service.reject(id: id, context: rig.context)
        XCTAssertEqual(rejected["wroteFile"].bool, true)
        XCTAssertEqual(try rig.read(), before)
        let refreshed = try await register(rig, change(patch))
        XCTAssertEqual(refreshed["id"].string, id)
        XCTAssertEqual(refreshed["state"].string, "rejected")
        _ = try await rig.service.reject(id: id, context: rig.context)
        XCTAssertEqual(try rig.read(), before)
    }

    func testPendingRejectLeavesBytesAndInodeAlone() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let file = rig.root.appendingPathComponent("note.txt").path
        var initial = stat(); XCTAssertEqual(lstat(file, &initial), 0)
        let id = try identifier(await register(rig, change(patch)))
        let receipt = try await rig.service.reject(id: id, context: rig.context)
        XCTAssertEqual(receipt["wroteFile"].bool, false)
        XCTAssertEqual(try rig.read(), before)
        var final = stat(); XCTAssertEqual(lstat(file, &final), 0); XCTAssertEqual(initial.st_ino, final.st_ino)
    }

    func testConcurrentByteChangesRefuseApplyRejectAndPreviewWithoutOverwriting() async throws {
        for applied in [false, true] {
            let rig = try Rig(); defer { rig.cleanup() }; try rig.write(applied ? after : before)
            let id = try identifier(await register(rig, change(patch)))
            let newer = "head\nOWN\ntail\n"; try rig.write(newer)
            let preview = await errorCode { try await rig.service.preview(id: id, context: rig.context) }
            let apply = await errorCode { try await rig.service.apply(id: id, context: rig.context) }
            let reject = await errorCode { try await rig.service.reject(id: id, context: rig.context) }
            XCTAssertEqual(preview, "diff-conflict"); XCTAssertEqual(apply, "diff-conflict"); XCTAssertEqual(reject, "diff-conflict")
            XCTAssertEqual(try rig.read(), newer)
        }
    }

    func testReplacementWithIdenticalBytesAndModeChangeAreStillVersionConflicts() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let id = try identifier(await register(rig, change(patch)))
        try Data(before.utf8).write(to: rig.root.appendingPathComponent("replacement"))
        XCTAssertEqual(rename(rig.root.appendingPathComponent("replacement").path, rig.root.appendingPathComponent("note.txt").path), 0)
        let replaced = await errorCode { try await rig.service.apply(id: id, context: rig.context) }
        XCTAssertEqual(replaced, "diff-conflict")
        let fresh = try identifier(await register(rig, change(patch)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.root.appendingPathComponent("note.txt").path)
        let mode = await errorCode { try await rig.service.apply(id: fresh, context: rig.context) }
        XCTAssertEqual(mode, "diff-conflict")
        XCTAssertEqual(try rig.read(), before)
    }

    func testSymlinkParentsAndHardlinksCannotBecomeConditionalWriteTargets() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before, path: "real.txt")
        try FileManager.default.createSymbolicLink(atPath: rig.root.appendingPathComponent("note.txt").path, withDestinationPath: "real.txt")
        let linked = await errorCode { try await register(rig, change(patch)) }
        XCTAssertEqual(linked, "diff-path")
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("note.txt"))
        XCTAssertEqual(link(rig.root.appendingPathComponent("real.txt").path, rig.root.appendingPathComponent("note.txt").path), 0)
        let hardlinked = await errorCode { try await register(rig, change(patch)) }
        XCTAssertEqual(hardlinked, "diff-file")
        try FileManager.default.createDirectory(at: rig.root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        try rig.write(before, path: "directory/note.txt")
        try FileManager.default.createSymbolicLink(atPath: rig.root.appendingPathComponent("alias").path, withDestinationPath: "directory")
        let parent = await errorCode { try await register(rig, change("@@ -1,3 +1,3 @@\n head\n-old\n+new\n tail\n", path: "alias/note.txt")) }
        XCTAssertEqual(parent, "diff-path")
        XCTAssertEqual(try rig.read("real.txt"), before)
    }

    func testSymlinkIntroducedAfterPreviewCannotWriteItsDestination() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let id = try identifier(await register(rig, change(patch)))
        try rig.write("outside review\n", path: "other.txt")
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(atPath: rig.root.appendingPathComponent("note.txt").path, withDestinationPath: "other.txt")
        let refusal = await errorCode { try await rig.service.apply(id: id, context: rig.context) }
        XCTAssertEqual(refusal, "diff-path")
        XCTAssertEqual(try rig.read("other.txt"), "outside review\n")
    }

    func testEscapesAndMismatchedDiffHeadersAreNotAdmitted() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        for path in ["../note.txt", "/etc/note.txt", "nested/../note.txt", ".git/config"] {
            let error = await errorCode { try await register(rig, change(patch, path: path)) }
            XCTAssertEqual(error, "diff-path")
        }
        let mismatch = try await register(rig, change(patch.replacingOccurrences(of: "note.txt", with: "other.txt")))
        XCTAssertEqual(mismatch["available"].bool, false)
        XCTAssertEqual(try rig.read(), before)
    }

    func testAmbiguousInsertionTruncatedBinaryAndRenameChangesRemainUnavailable() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write("head\ninsert\n")
        let ambiguous = try await register(rig, change("@@ -1 +1,2 @@\n head\n+insert\n"))
        XCTAssertEqual(ambiguous["available"].bool, false)
        try rig.write(before)
        for diff in ["@@ -1,3 +1,3 @@\n-old\n+new\n", "Binary files a/note.txt and b/note.txt differ", "rename from old\nrename to new\n"] {
            let receipt = try await register(rig, change(diff)); XCTAssertEqual(receipt["available"].bool, false)
        }
        let renamed = change(patch).setting("kind", .object([.init("type", .string("update")), .init("move_path", .string("renamed.txt"))]))
        let receipt = try await register(rig, renamed); XCTAssertEqual(receipt["available"].bool, false)
        XCTAssertEqual(try rig.read(), before)
    }

    func testMissingFinalNewlineAndUnicodeBytesArePreservedExactly() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write("old🙂")
        let diff = "@@ -1 +1 @@\n-old🙂\n\\ No newline at end of file\n+new🙂\n\\ No newline at end of file\n"
        let id = try identifier(await register(rig, change(diff)))
        _ = try await rig.service.apply(id: id, context: rig.context)
        XCTAssertEqual(try rig.read(), "new🙂")
        try rig.write("cafe\u{301}\n")
        let unequal = try await register(rig, change("@@ -1 +1 @@\n-café\n+tea\n"))
        XCTAssertEqual(unequal["available"].bool, false, "Unicode-equivalent text is not byte-equivalent text")
    }

    func testSingleClaudeEditUsesExactUniqueByteMatchAndRefusesOverlaps() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write("start\nalpha\nfinish\n")
        let edit = NativeRPCValue.object([.init("file_path", .string(rig.root.appendingPathComponent("note.txt").path)), .init("old_string", .string("alpha")), .init("new_string", .string("beta"))])
        let id = try identifier(await register(rig, edit))
        _ = try await rig.service.apply(id: id, context: rig.context)
        XCTAssertEqual(try rig.read(), "start\nbeta\nfinish\n")
        try rig.write("aaa")
        let overlap = try await register(rig, edit.setting("old_string", .string("aa")).setting("new_string", .string("zz")))
        XCTAssertEqual(overlap["available"].bool, false)
    }

    func testRetentionEvictsOldReceiptsExplicitly() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        var first: String?
        for n in 0..<65 {
            let path = "file-\(n).txt"; try rig.write(before, path: path)
            let receipt = try await register(rig, change("@@ -1,3 +1,3 @@\n head\n-old\n+new\n tail\n", path: path))
            if first == nil { first = try identifier(receipt) }
        }
        let old = try XCTUnwrap(first)
        let refusal = await errorCode { try await rig.service.apply(id: old, context: rig.context) }
        XCTAssertEqual(refusal, "diff-stale")
        XCTAssertEqual(try rig.read("file-0.txt"), before)
    }

    func testCurrentWriteGrantIsRequiredEvenAfterAValidReadPreview() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let grant = Grant(rig.root)
        let service = BackendChatDiffActions(authority: .init { _ in await grant.scope() })
        let receipt = try await service.register(change: change(patch), projectRoot: rig.root.path, context: rig.context)
        let id = try identifier(receipt)
        _ = try await service.preview(id: id, context: rig.context)
        await grant.revoke()
        let refusal = await errorCode { try await service.apply(id: id, context: rig.context) }
        XCTAssertEqual(refusal, "access-denied")
        XCTAssertEqual(try rig.read(), before)
    }

    func testAtomicPublicationPreservesExtendedAttributesOwnerAndGroup() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let path = rig.root.appendingPathComponent("note.txt").path
        let source = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(source, 0); defer { close(source) }
        let name = "dev.terminaldeck.sess-diff-fixture", value = Data([0, 1, 2, 255, 10])
        let set = value.withUnsafeBytes { fsetxattr(source, name, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        var initial = stat(); XCTAssertEqual(fstat(source, &initial), 0)
        let id = try identifier(await register(rig, change(patch)))
        let receipt = try await rig.service.apply(id: id, context: rig.context)
        XCTAssertEqual(receipt["verified"].bool, true)
        let destination = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(destination, 0); defer { close(destination) }
        var restored = Data(count: value.count)
        let count = restored.withUnsafeMutableBytes { fgetxattr(destination, name, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(count, value.count); XCTAssertEqual(restored, value)
        var final = stat(); XCTAssertEqual(fstat(destination, &final), 0)
        XCTAssertEqual(final.st_uid, initial.st_uid); XCTAssertEqual(final.st_gid, initial.st_gid)
        XCTAssertEqual(try rig.read(), after)
    }

    func testExtendedAttributeChangeAfterRegistrationRefusesPublication() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let id = try identifier(await register(rig, change(patch)))
        let file = open(rig.root.appendingPathComponent("note.txt").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(file, 0); defer { close(file) }
        let value = Data("new metadata".utf8)
        XCTAssertEqual(value.withUnsafeBytes { fsetxattr(file, "dev.terminaldeck.sess-diff-fixture", $0.baseAddress, $0.count, 0, 0) }, 0)
        let refusal = await errorCode { try await rig.service.apply(id: id, context: rig.context) }
        XCTAssertEqual(refusal, "diff-conflict")
        XCTAssertEqual(try rig.read(), before)
    }

    func testPublishedContentReceivesANewModificationTimeAfterMetadataCopy() async throws {
        let rig = try Rig(); defer { rig.cleanup() }; try rig.write(before)
        let path = rig.root.appendingPathComponent("note.txt").path
        let oldDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        let id = try identifier(await register(rig, change(patch)))
        let started = Date().timeIntervalSince1970
        _ = try await rig.service.apply(id: id, context: rig.context)
        var final = stat(); XCTAssertEqual(lstat(path, &final), 0)
        XCTAssertGreaterThanOrEqual(Double(final.st_mtimespec.tv_sec), floor(started))
        XCTAssertEqual(try rig.read(), after)
    }

    func testRenamedAndReplacedParentRefusesPreviouslyRegisteredVersion() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let parent = rig.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try rig.write(before, path: "folder/note.txt")
        let receipt = try await register(rig, change("@@ -1,3 +1,3 @@\n head\n-old\n+new\n tail\n", path: "folder/note.txt"))
        let id = try identifier(receipt)
        try FileManager.default.moveItem(at: parent, to: rig.root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try rig.write(before, path: "folder/note.txt")
        let refusal = await errorCode { try await rig.service.apply(id: id, context: rig.context) }
        XCTAssertEqual(refusal, "diff-conflict")
        XCTAssertEqual(try rig.read("folder/note.txt"), before)
        XCTAssertEqual(try rig.read("moved/note.txt"), before)
    }
}
