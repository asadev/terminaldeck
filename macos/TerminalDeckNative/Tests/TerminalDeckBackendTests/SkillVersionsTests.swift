import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor SkillVersionFinalEffect {
    var calls = 0
    let mutate: @Sendable () throws -> Void
    init(mutate: @escaping @Sendable () throws -> Void) { self.mutate = mutate }
    func verify() throws { calls += 1; if calls == 2 { try mutate() } }
}

private actor SkillVersionRevokingGrant {
    let root: String, source: String
    var lookups = 0, revoked = false
    init(root: String, source: String) { self.root = root; self.source = source }
    func ownership() -> NativeRPCValue? { lookups += 1; if lookups >= 4 { revoked = true }; return nil }
    func scope() -> BackendROUTINESSkillsScope { .init(roots: revoked ? [source] : [root]) }
}

@MainActor final class SkillVersionsTests: XCTestCase {
    struct Rig {
        let root: URL, source: URL, store: BackendSkillVersions
        let effect = BackendROUTINESSkillsEffectGuard(verify: {})
        func digest() throws -> String { try BackendSkillVersionFiles.inspect(source).digest }
        func save(_ label: String) async throws -> String { try await store.snapshot(source: source, label: label, expected: digest(), guard: effect)["version"]["id"].requireString("id") }
        func service(builtin: Bool = false, owned: Bool = false, writable: Bool = true) -> BackendROUTINESSkills {
            BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { [] }, catalogue: { .null }, install: { _, _ in .null }, remove: { _ in .null }, ownedSkill: { _ in owned ? .object([.init("id", .string("store-owned"))]) : nil }), sharedRoots: [.init(folder: source.deletingLastPathComponent(), source: "Fixture", builtIn: builtin)], home: root, writable: writable, versions: store)
        }
    }
    func rig(claude: Bool = false) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-versions-" + UUID().uuidString).resolvingSymlinksInPath()
        let source = root.appendingPathComponent(claude ? "project/.claude/skills/topic-skill" : "project/.agents/skills/topic-skill")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: topic-skill\ndescription: Fixture\n---\nRead the project.".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(root: root, source: source, store: .init(root: root.appendingPathComponent("private-history"), writable: true))
    }
    func testFullTreeSnapshotIsImmutableAndReadDoesNotCreateHistory() async throws {
        let r = try rig()
        let initial = try await r.store.info(source: r.source)
        XCTAssertEqual(initial["versions"], .array([])); XCTAssertFalse(FileManager.default.fileExists(atPath: r.root.appendingPathComponent("private-history").path))
        try FileManager.default.createDirectory(at: r.source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0".utf8).write(to: r.source.appendingPathComponent("scripts/run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.source.appendingPathComponent("scripts/run.sh").path)
        try Data([0, 255, 8]).write(to: r.source.appendingPathComponent(".hidden-asset"))
        let digest = try r.digest(), id = try await r.save("First")
        XCTAssertEqual(try r.digest(), digest)
        try Data([9]).write(to: r.source.appendingPathComponent(".hidden-asset"))
        let check = try await r.store.check(source: r.source, version: id, guard: r.effect)
        XCTAssertEqual(check["check"]["passed"], .bool(true)); XCTAssertEqual(check["check"]["digest"], .string(digest))
        let reopened = BackendSkillVersions(root: r.root.appendingPathComponent("private-history"), writable: true)
        let state = try await reopened.info(source: r.source, selected: id)
        XCTAssertEqual(state["selected"]["digest"], .string(digest)); XCTAssertNotEqual(state["currentDigest"], .string(digest))
        let files = state["selected"]["files"].elements ?? []
        XCTAssertEqual(files.first { $0["path"].string == "scripts/run.sh" }?["executable"], .bool(true))
        XCTAssertTrue(files.contains { $0["path"].string == ".hidden-asset" })
    }
    func testAdoptionPreservesDirtyAddedDeletedFilesAndRollback() async throws {
        let r = try rig(); try Data([1, 2]).write(to: r.source.appendingPathComponent("asset"))
        let a = try await r.save("A"), digestA = try r.digest()
        try FileManager.default.removeItem(at: r.source.appendingPathComponent("asset")); try Data("edits".utf8).write(to: r.source.appendingPathComponent("new-file"))
        let b = try await r.save("B"), digestB = try r.digest()
        let receipt = try await r.store.adopt(source: r.source, version: a, expected: digestB, guard: r.effect)
        XCTAssertNotNil(receipt["checkpointVersion"].string); XCTAssertEqual(try r.digest(), digestA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.source.appendingPathComponent("new-file").path))
        _ = try await r.store.adopt(source: r.source, version: b, expected: digestA, guard: r.effect)
        XCTAssertEqual(try r.digest(), digestB); XCTAssertEqual(try Data(contentsOf: r.source.appendingPathComponent("new-file")), Data("edits".utf8))
        let state = try await r.store.info(source: r.source); XCTAssertEqual(state["dirty"], .bool(false))
    }
    func testLongUnicodeLabelStillAllowsSafeCheckpointAndAdoption() async throws {
        let r = try rig(), id = try await r.save(String(repeating: "語", count: 33))
        try Data("working edits".utf8).write(to: r.source.appendingPathComponent("edit"))
        let result = try await r.store.adopt(source: r.source, version: id, expected: r.digest(), guard: r.effect)
        XCTAssertNotNil(result["checkpointVersion"].string)
    }
    func testStaleDigestAndRevokedEffectLeaveEditsUntouched() async throws {
        let r = try rig(), id = try await r.save("A"), before = try r.digest()
        try Data("keep".utf8).write(to: r.source.appendingPathComponent("edited"))
        do { _ = try await r.store.adopt(source: r.source, version: id, expected: before, guard: r.effect); XCTFail("stale") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let current = try r.digest()
        let revoked = BackendROUTINESSkillsEffectGuard { throw NativeRPCError(code: "not-granted", message: "Revoked") }
        do { _ = try await r.store.adopt(source: r.source, version: id, expected: current, guard: revoked); XCTFail("revoked") } catch {}
        XCTAssertEqual(try r.digest(), current)
    }
    func testSelectedVersionChecksSurviveWorkingChangesAndDetectCorruption() async throws {
        let r = try rig(), a = try await r.save("A")
        try Data("new".utf8).write(to: r.source.appendingPathComponent("extra")); let b = try await r.save("B")
        _ = try await r.store.check(source: r.source, version: a, guard: r.effect)
        let registry = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: r.root.appendingPathComponent("private-history/registry.json")))
        let identity = try XCTUnwrap(registry.values.first)
        try Data("corrupt".utf8).write(to: r.root.appendingPathComponent("private-history/\(identity)/versions/\(b)/tree/SKILL.md"))
        let checked = try await r.store.check(source: r.source, version: b, guard: r.effect)
        XCTAssertEqual(checked["check"]["passed"], .bool(false))
        let historyA = try await r.store.info(source: r.source, selected: a), historyB = try await r.store.info(source: r.source, selected: b)
        XCTAssertEqual(historyA["checks"].elements?.count, 1); XCTAssertEqual(historyA["checks"].elements?.first?["passed"], .bool(true))
        XCTAssertEqual(historyB["checks"].elements?.first?["passed"], .bool(false))
        let digest = try r.digest()
        do { _ = try await r.store.adopt(source: r.source, version: b, expected: digest, guard: r.effect); XCTFail("corrupt") } catch {}
        XCTAssertEqual(try r.digest(), digest)
    }
    func testLinksAmbiguousPathsAndOversizeRefuseWholeSnapshot() async throws {
        let r = try rig()
        try FileManager.default.createSymbolicLink(atPath: r.source.appendingPathComponent("linked").path, withDestinationPath: "/etc/hosts")
        do { _ = try await r.save("Link"); XCTFail("symlink") } catch {}
        try FileManager.default.removeItem(at: r.source.appendingPathComponent("linked"))
        try Data(count: BackendSkillVersionFiles.maxFileBytes + 1).write(to: r.source.appendingPathComponent("large"))
        do { _ = try await r.save("Large"); XCTFail("size") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.root.appendingPathComponent("private-history").path))
        XCTAssertFalse(BackendSkillVersionFiles.safe("../outside")); XCTAssertFalse(BackendSkillVersionFiles.safe("/outside"))
    }
    func testMarkedMirrorMovesTogetherAndDivergentOrUnownedMirrorIsRefused() async throws {
        let r = try rig(claude: true), a = try await r.save("A")
        try Data("new".utf8).write(to: r.source.appendingPathComponent("added")); let b = try await r.save("B")
        let mirror = try XCTUnwrap(BackendSkillsMirror.mirror(r.source))
        _ = try await r.store.adopt(source: r.source, version: a, expected: r.digest(), guard: r.effect)
        XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, try r.digest())
        try Data("mirror edits".utf8).write(to: mirror.appendingPathComponent("added"))
        let original = try r.digest(), divergent = try BackendSkillVersionFiles.inspect(mirror).digest
        do { _ = try await r.store.adopt(source: r.source, version: b, expected: original, guard: r.effect); XCTFail("diverged") } catch {}
        XCTAssertEqual(try r.digest(), original); XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, divergent)
        try FileManager.default.removeItem(at: mirror.appendingPathComponent(BackendSkillsMirror.marker))
        do { _ = try await r.store.adopt(source: r.source, version: b, expected: original, guard: r.effect); XCTFail("unowned") } catch {}
        XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, divergent)
    }
    func testProtectedAndStoreOwnedAdoptionRefuseAndReadOnlyCannotSave() async throws {
        let r = try rig(), id = try await r.save("A")
        for service in [r.service(builtin: true), r.service(owned: true)] {
            do { _ = try await service.call("skills:version_adopt", .object([.init("skill", .string(r.source.path)), .init("version", .string(id)), .init("expectedDigest", .string(r.digest()))])); XCTFail("protected") }
            catch { XCTAssertTrue(error.localizedDescription.contains("protected")) }
        }
        do { _ = try await r.service(writable: false).call("skills:version_save", .object([.init("skill", .string(r.source.path)), .init("label", .string("No")), .init("expectedDigest", .string(r.digest()))])); XCTFail("read-only") } catch {}
    }
    func testScopeAndRenameHistoryUseSelectedFolder() async throws {
        let r = try rig(), id = try await r.save("A"), service = r.service()
        do { _ = try await service.call("skills:versions", .object([.init("skill", .string(r.source.path))]), scope: .init(roots: [])); XCTFail("scope") } catch {}
        let result = try await service.rename(r.source.path, name: "new-topic")
        let target = URL(fileURLWithPath: try result["folder"].requireString("folder"))
        let state = try await r.store.info(source: target)
        XCTAssertTrue((state["versions"].elements ?? []).contains { $0["id"].string == id })
        do { _ = try await r.store.adopt(source: target, version: id, expected: BackendSkillVersionFiles.inspect(target).digest, guard: r.effect); XCTFail("cross-name") } catch { XCTAssertTrue(error.localizedDescription.contains("different skill name")) }
    }
    func testOwnershipMarkerRemovedAtFinalGuardDoesNotOverwriteMirror() async throws {
        let r = try rig(claude: true), version = try await r.save("A")
        try Data("working".utf8).write(to: r.source.appendingPathComponent("edit"))
        let mirror = try XCTUnwrap(BackendSkillsMirror.mirror(r.source)), digest = try r.digest()
        let gate = SkillVersionFinalEffect { try FileManager.default.removeItem(at: mirror.appendingPathComponent(BackendSkillsMirror.marker)) }
        do { _ = try await r.store.adopt(source: r.source, version: version, expected: digest, guard: .init { try await gate.verify() }); XCTFail("marker removed") } catch {}
        XCTAssertEqual(try r.digest(), digest); XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(BackendSkillsMirror.marker).path))
    }
    func testIndependentMirrorAppearingAtFinalGuardIsPreservedEvenWithMatchingBytes() async throws {
        let r = try rig(claude: true), version = try await r.save("A"), digest = try r.digest()
        let mirror = try XCTUnwrap(BackendSkillsMirror.counterpart(of: r.source))
        let source = r.source
        let gate = SkillVersionFinalEffect {
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: mirror)
        }
        do { _ = try await r.store.adopt(source: source, version: version, expected: digest, guard: .init { try await gate.verify() }); XCTFail("independent mirror appeared") } catch {}
        XCTAssertEqual(try r.digest(), digest); XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent(BackendSkillsMirror.marker).path))
    }
    func testMirrorGrantRevokedDuringFinalOwnershipLookupRefusesBeforeSwap() async throws {
        let r = try rig(claude: true), version = try await r.save("A")
        try Data("current edits".utf8).write(to: r.source.appendingPathComponent("edit"))
        let mirror = try XCTUnwrap(BackendSkillsMirror.mirror(r.source)), digest = try r.digest()
        let grant = SkillVersionRevokingGrant(root: r.root.path, source: r.source.path)
        let service = BackendROUTINESSkills(dependencies: .init(projects: { [] }, profiles: { [] }, catalogue: { .null }, install: { _, _ in .null }, remove: { _ in .null }, ownedSkill: { _ in await grant.ownership() }), sharedRoots: [.init(folder: r.source.deletingLastPathComponent(), source: "Fixture")], home: r.root, writable: true, versions: r.store)
        do {
            _ = try await service.call("skills:version_adopt", .object([.init("skill", .string(r.source.path)), .init("version", .string(version)), .init("expectedDigest", .string(digest))]), scope: .init(roots: [r.root.path]), currentScope: { await grant.scope() })
            XCTFail("mirror access was revoked during the ownership await")
        } catch { XCTAssertTrue(error.localizedDescription.contains("access changed")) }
        let lookups = await grant.lookups; XCTAssertEqual(lookups, 4)
        XCTAssertEqual(try r.digest(), digest); XCTAssertEqual(try BackendSkillVersionFiles.inspect(mirror).digest, digest)
    }
    func testExclusiveStagingNeverTouchesAnExistingFolder() throws {
        let r = try rig(), tree = try BackendSkillVersionFiles.inspect(r.source)
        do { try BackendSkillVersionFiles.write(tree, to: r.source); XCTFail("existing directory") } catch {}
        XCTAssertEqual(try r.digest(), tree.digest)
    }
    func testInterruptedExchangeRestoresPreviousFilesBeforeRetry() async throws {
        let r = try rig(), a = try await r.save("A"), digestA = try r.digest()
        let stage = r.source.deletingLastPathComponent().appendingPathComponent(".td-skill-version-" + UUID().uuidString)
        try FileManager.default.copyItem(at: r.source, to: stage)
        try Data("new".utf8).write(to: stage.appendingPathComponent("changed"))
        let digestB = try BackendSkillVersionFiles.inspect(stage).digest
        try BackendSkillVersionFiles.exchange(r.source, stage)
        let registry = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: r.root.appendingPathComponent("private-history/registry.json")))
        let identity = try XCTUnwrap(registry.values.first)
        let journal = NativeRPCValue.object([.init("source", .string(r.source.path)), .init("previous", .null), .init("committed", .bool(false)), .init("swaps", .array([.object([.init("target", .string(r.source.path)), .init("stage", .string(stage.path)), .init("existed", .bool(true)), .init("before", .string(digestA)), .init("after", .string(digestB))])]))])
        try journal.encodedJSON().write(to: r.root.appendingPathComponent("private-history/\(identity)/operation.json"))
        do { _ = try await r.store.adopt(source: r.source, version: a, expected: digestB, guard: r.effect); XCTFail("refresh after recovery") } catch {}
        XCTAssertEqual(try r.digest(), digestA)
        let state = try await r.store.info(source: r.source); XCTAssertEqual(state["recoveryPending"], .bool(false))
    }
}
