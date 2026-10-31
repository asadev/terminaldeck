import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSharedProjectsTests: XCTestCase {
    func testMergeConflictsSharingAndUnshareKeepOriginalHistory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppShared-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let own = base.appendingPathComponent(".claude"), managed = base.appendingPathComponent("profiles"), config = managed.appendingPathComponent("work")
        let local = config.appendingPathComponent("projects/both"), shared = own.appendingPathComponent("projects/both")
        for directory in [local, shared] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("mine".utf8).write(to: local.appendingPathComponent("clash.jsonl"))
        try Data("theirs".utf8).write(to: shared.appendingPathComponent("clash.jsonl"))
        try Data("same".utf8).write(to: local.appendingPathComponent("same.jsonl"))
        try Data("same".utf8).write(to: shared.appendingPathComponent("same.jsonl"))
        try Data("new".utf8).write(to: local.appendingPathComponent("new.jsonl"))
        let profile = BackendAccountProfile(id: "work", name: "Work", provider: "claude", configDir: config.path, system: false, color: "--accent", createdAt: 0)
        let service = BackendAppSharedProjects(systemConfig: own, managedRoot: managed, writable: true, now: { 1791280000000 }, changed: {})
        let result = try await service.share(profile)
        XCTAssertEqual(result["kept"], .number(1)); XCTAssertEqual(result["moved"], .number(1)); XCTAssertEqual(result["state"]["link"], .string("shared"))
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("clash.jsonl"), encoding: .utf8), "theirs")
        let aside = URL(fileURLWithPath: try XCTUnwrap(result["keptAt"].string))
        XCTAssertEqual(try String(contentsOf: aside.appendingPathComponent("both/clash.jsonl"), encoding: .utf8), "mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathComponent("projects/both/new.jsonl").path))
        let state = try await service.unshare(profile)
        XCTAssertEqual(state.link, "separate")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.appendingPathComponent("projects").path), [])
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("clash.jsonl"), encoding: .utf8), "theirs")
    }
    func testSystemAndForeignLinksAreNeverRelinked() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppShared-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("profiles"), config = managed.appendingPathComponent("work"), own = base.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent("projects"), withDestinationURL: base.appendingPathComponent("foreign"))
        let service = BackendAppSharedProjects(systemConfig: own, managedRoot: managed, writable: true, changed: {})
        let profile = BackendAccountProfile(id: "work", name: "Work", provider: "claude", configDir: config.path, system: false, color: "--accent", createdAt: 0)
        do { _ = try await service.share(profile); XCTFail("Foreign link must refuse") } catch { XCTAssertTrue(error.localizedDescription.contains("Nothing here will replace")) }
        let system = BackendAccountProfile(id: "system", name: "System", provider: "claude", configDir: own.path, system: true, color: "--accent", createdAt: 0)
        let reads = await service.readsShared(system); XCTAssertTrue(reads)
        let state = await service.state(system); XCTAssertEqual(state.link, "unmanaged")
        let alias = base.appendingPathComponent("user-owned-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
        let outsideAlias = BackendAccountProfile(id: "alias", name: "Alias", provider: "claude", configDir: alias.path, system: false, color: "--accent", createdAt: 0)
        let outsideCanShare = await service.canShare(outsideAlias); XCTAssertFalse(outsideCanShare)
        let insideAlias = managed.appendingPathComponent("inside-alias")
        try FileManager.default.createSymbolicLink(at: insideAlias, withDestinationURL: own)
        let inside = BackendAccountProfile(id: "inside", name: "Inside", provider: "claude", configDir: insideAlias.path, system: false, color: "--accent", createdAt: 0)
        let insideCanShare = await service.canShare(inside); XCTAssertTrue(insideCanShare)
    }
}
