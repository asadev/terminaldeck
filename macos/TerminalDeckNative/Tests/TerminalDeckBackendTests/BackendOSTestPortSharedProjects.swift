import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTestPortSharedProjects: BackendOSTestPortFixture {
    struct Rig { let base: URL, own: URL, managed: URL, service: BackendAppSharedProjects; var shared: URL { own.appendingPathComponent("projects") } }
    func rig() throws -> Rig {
        let base = try scratch("history"), own = base.appendingPathComponent("home/.claude"), managed = base.appendingPathComponent("userdata/profiles")
        try FileManager.default.createDirectory(at: own.appendingPathComponent("projects"), withIntermediateDirectories: true); try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        return Rig(base: base, own: own, managed: managed, service: BackendAppSharedProjects(systemConfig: own, managedRoot: managed, writable: true, now: { 1790000000000 }, changed: {}))
    }
    func account(_ id: String, _ rig: Rig, provider: String = "claude", directory: URL? = nil, system: Bool = false) -> BackendAccountProfile {
        .init(id: id, name: id, provider: provider, configDir: (directory ?? rig.managed.appendingPathComponent(id)).path, system: system, color: "--accent", createdAt: 0)
    }
    func createConfig(_ profile: BackendAccountProfile) throws { try FileManager.default.createDirectory(atPath: profile.configDir, withIntermediateDirectories: true) }
    func config(_ profile: BackendAccountProfile, _ path: String = "projects") -> URL { URL(fileURLWithPath: profile.configDir).appendingPathComponent(path) }
    func symlink(_ url: URL) -> Bool { var info = stat(); return Darwin.lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK }
    func testSharedProjects79LinkPointsIntoOwnHistory() async throws {
        let r = try rig(), profile = account("work", r); try createConfig(profile); _ = try await r.service.share(profile)
        XCTAssertTrue(symlink(config(profile))); XCTAssertFalse(symlink(r.shared)); let state = await r.service.state(profile); XCTAssertEqual(state.link, "shared")
    }
    func testSharedProjects94TwoAccountsSeeSameConversation() async throws {
        let r = try rig(), one = account("one", r), two = account("two", r)
        for profile in [one, two] { try createConfig(profile); _ = try await r.service.share(profile) }
        try put(config(one, "projects/-tmp-work/abc.jsonl"), "{}\n"); XCTAssertEqual(try names(config(two, "projects/-tmp-work")), ["abc.jsonl"])
    }
    func testSharedProjects120MergeByFileWithoutHidingHistory() async throws {
        let r = try rig(), profile = account("work", r)
        try FileManager.default.createDirectory(at: config(profile, "projects/-tmp-only-mine"), withIntermediateDirectories: true)
        try put(config(profile, "projects/-tmp-both/on-screen.jsonl"), "the conversation on screen\n"); try put(r.shared.appendingPathComponent("-tmp-both/older.jsonl"), "an older one\n")
        let result = try await r.service.share(profile); XCTAssertEqual(result["kept"].number, 0); XCTAssertEqual(result["keptAt"], .null)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent("-tmp-only-mine").path)); XCTAssertEqual(try names(r.shared.appendingPathComponent("-tmp-both")), ["older.jsonl", "on-screen.jsonl"])
        XCTAssertEqual(try text(r.shared.appendingPathComponent("-tmp-both/older.jsonl")), "an older one\n"); XCTAssertEqual(try names(config(profile, "projects/-tmp-both")), ["older.jsonl", "on-screen.jsonl"])
        XCTAssertFalse(try names(URL(fileURLWithPath: profile.configDir)).contains { $0.hasPrefix("projects.not-merged-") })
    }
    func testSharedProjects146OnlyDifferentCollisionSetAside() async throws {
        let r = try rig(), profile = account("work", r)
        for (name, body) in [("same.jsonl", "identical\n"), ("clash.jsonl", "mine\n"), ("fine.jsonl", "fine\n")] { try put(config(profile, "projects/-tmp-both/" + name), body) }
        try put(r.shared.appendingPathComponent("-tmp-both/same.jsonl"), "identical\n"); try put(r.shared.appendingPathComponent("-tmp-both/clash.jsonl"), "theirs\n")
        let result = try await r.service.share(profile); XCTAssertEqual(result["kept"].number, 1); XCTAssertEqual(try text(r.shared.appendingPathComponent("-tmp-both/clash.jsonl")), "theirs\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent("-tmp-both/fine.jsonl").path))
        let aside = URL(fileURLWithPath: try XCTUnwrap(result["keptAt"].string)); XCTAssertEqual(try text(aside.appendingPathComponent("-tmp-both/clash.jsonl")), "mine\n"); XCTAssertEqual(try names(aside.appendingPathComponent("-tmp-both")), ["clash.jsonl"])
    }
    func testSharedProjects169OldAsideRestoredAtAdoption() async throws {
        let r = try rig(), profile = account("work", r); try createConfig(profile); _ = try await r.service.share(profile)
        try put(config(profile, "projects.not-merged-1790000000000/-tmp-hidden/lost.jsonl"), "a conversation nobody could find\n")
        _ = await r.service.adopt([profile]); XCTAssertEqual(try text(r.shared.appendingPathComponent("-tmp-hidden/lost.jsonl")), "a conversation nobody could find\n")
        XCTAssertFalse(try names(URL(fileURLWithPath: profile.configDir)).contains { $0.hasPrefix("projects.not-merged-") })
    }
    func testSharedProjects187UserManagedDirectoryRefuses() async throws {
        let r = try rig(), profile = account("adopted", r, directory: r.base.appendingPathComponent("my-own-claude")); try createConfig(profile)
        do { _ = try await r.service.share(profile); XCTFail("Restructured user-owned account") } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("only an account this app created its own folder for")) }
    }
    func testSharedProjects196RecursiveAccountDeleteStopsAtLink() async throws {
        let r = try rig(), profile = account("work", r); try createConfig(profile); _ = try await r.service.share(profile); try put(r.shared.appendingPathComponent("-tmp-real/abc.jsonl"), "{}\n")
        let state = await r.service.state(profile); XCTAssertTrue(BackendAppSharedProjects.describeDelete(state).lowercased().contains("no conversations are lost"))
        try FileManager.default.removeItem(atPath: profile.configDir); XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent("-tmp-real/abc.jsonl").path))
    }
    func testSharedProjects214DeleteCountsUnsharedFolders() async throws {
        let r = try rig(), profile = account("solo", r)
        for folder in ["-tmp-a", "-tmp-b"] { try FileManager.default.createDirectory(at: config(profile, "projects/" + folder), withIntermediateDirectories: true) }
        let state = await r.service.state(profile), said = BackendAppSharedProjects.describeDelete(state); XCTAssertTrue(said.contains("2 folders")); XCTAssertTrue(said.contains("will be deleted"))
    }
    func testSharedProjects226UnshareCreatesEmptyOwnHistory() async throws {
        let r = try rig(), profile = account("work", r); try createConfig(profile); _ = try await r.service.share(profile); try FileManager.default.createDirectory(at: r.shared.appendingPathComponent("-tmp-keep"), withIntermediateDirectories: true)
        let after = try await r.service.unshare(profile); XCTAssertEqual(after.link, "separate"); XCTAssertFalse(symlink(config(profile))); XCTAssertEqual(try names(config(profile)), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent("-tmp-keep").path)); let state = await r.service.state(profile); XCTAssertEqual(state.link, "separate")
    }
    func testSharedProjects261AdoptOrdinaryDirectory() async throws {
        let r = try rig(), profile = account("examplemail-gmail-com", r); try FileManager.default.createDirectory(at: config(profile, "projects/-Users-apple-bin"), withIntermediateDirectories: true)
        let before = await r.service.state(profile), beforeRead = await r.service.readsShared(profile); XCTAssertEqual(before.link, "separate"); XCTAssertFalse(beforeRead)
        let result = await r.service.adopt([profile]), afterRead = await r.service.readsShared(profile); XCTAssertEqual(result["joined"], .array([.string(profile.id)])); XCTAssertTrue(afterRead)
    }
    func testSharedProjects280OnscreenConversationVisibleAfterSwitch() async throws {
        let r = try rig(), profile = account("examplemail-gmail-com", r); try createConfig(profile); try put(r.shared.appendingPathComponent("-Users-apple-Projects-terminaldeck/dbebd1aa.jsonl"), #"{"type":"user"}"# + "\n")
        _ = await r.service.adopt([profile]); XCTAssertEqual(try names(config(profile, "projects/-Users-apple-Projects-terminaldeck")), ["dbebd1aa.jsonl"])
    }
    func testSharedProjects299NoOwnOrAccountHistoryHidden() async throws {
        let r = try rig(), profile = account("work", r); try put(r.shared.appendingPathComponent("-tmp-both/ours.jsonl"), "mine\n"); try put(config(profile, "projects/-tmp-both/theirs.jsonl"), "theirs\n")
        try FileManager.default.createDirectory(at: config(profile, "projects/-tmp-only-theirs"), withIntermediateDirectories: true); _ = await r.service.adopt([profile])
        XCTAssertEqual(try text(r.shared.appendingPathComponent("-tmp-both/ours.jsonl")), "mine\n"); XCTAssertEqual(try text(r.shared.appendingPathComponent("-tmp-both/theirs.jsonl")), "theirs\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent("-tmp-only-theirs").path)); XCTAssertFalse(try names(URL(fileURLWithPath: profile.configDir)).contains { $0.hasPrefix("projects.not-merged-") })
    }
    func testSharedProjects319IneligibleAccountsRemainUntouched() async throws {
        let r = try rig(), adopted = account("adopted", r, directory: r.base.appendingPathComponent("my-own-claude")), codex = account("codex", r, provider: "codex"), elsewhere = account("elsewhere", r)
        try FileManager.default.createDirectory(at: config(adopted), withIntermediateDirectories: true); try createConfig(codex); try createConfig(elsewhere)
        let foreign = r.base.appendingPathComponent("somewhere-else"); try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: config(elsewhere), withDestinationURL: foreign)
        for profile in [adopted, codex, elsewhere] { let canJoin = await r.service.canJoin(profile); XCTAssertFalse(canJoin) }
        let result = await r.service.adopt([adopted, codex, elsewhere]); XCTAssertEqual(result["joined"], .array([])); XCTAssertEqual(result["left"].elements?.compactMap(\.string).sorted(), ["adopted", "codex", "elsewhere"]); XCTAssertEqual(result["failed"], .array([]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(elsewhere).path), foreign.path)
    }
    func testSharedProjects351SystemInstallAlreadyShared() async throws {
        let r = try rig(), own = account("system-claude", r, directory: r.own, system: true), reads = await r.service.readsShared(own), canJoin = await r.service.canJoin(own)
        XCTAssertTrue(reads); XCTAssertTrue(canJoin); let result = await r.service.adopt([own]); XCTAssertEqual(result["already"], .array([.string("system-claude")]))
    }
    func testSharedProjects363AdoptionIdempotent() async throws {
        let r = try rig(), profile = account("work", r); try FileManager.default.createDirectory(at: config(profile), withIntermediateDirectories: true)
        let first = await r.service.adopt([profile]), second = await r.service.adopt([profile]), third = await r.service.adopt([profile]), reads = await r.service.readsShared(profile)
        XCTAssertEqual(first["joined"], .array([.string("work")])); XCTAssertEqual(second["joined"], .array([])); XCTAssertEqual(third["already"], .array([.string("work")])); XCTAssertTrue(reads)
    }
    func testSharedProjects374BrokenDirectoryDoesNotThrow() async throws {
        let r = try rig(), profile = account("broken", r); try put(URL(fileURLWithPath: profile.configDir), "not a directory\n")
        let result = await r.service.adopt([profile]); XCTAssertEqual(result["joined"], .array([]))
        let left = result["left"].elements?.compactMap(\.string) ?? [], failed = result["failed"].elements?.compactMap { $0["id"].string } ?? []; XCTAssertEqual(left + failed, ["broken"])
    }
    private let accountFolders = ["-private-tmp-deck-switch-demo", "-private-tmp-td-acct-model-work", "-private-tmp-td-switch-evidence", "-private-var-folders-7j-copilot-probe-copilot", "-Users-apple--claude-jobs-5ccc1804-tmp-deck-demo", "-Users-apple--claude-jobs-5ccc1804-tmp-deck-solo", "-Users-apple-bin"]
    private let ownFolders = ["-private-tmp-deck-switch-demo", "-private-tmp-td-acct-model-work", "-private-tmp-td-switch-evidence", "-Users-apple--claude-jobs-5ccc1804-tmp-deck-demo", "-Users-apple--claude-jobs-5ccc1804-tmp-deck-solo", "-Users-apple-Projects-terminaldeck"]
    func testSharedProjects430MeasuredThreeAccountMigration() async throws {
        let r = try rig(), kiwi = account("examplemail-gmail-com", r), codex = account("asadiqbalonline-gmail-com-2", r, provider: "codex"), own = account("system-claude", r, directory: r.own, system: true)
        for folder in ownFolders { try put(r.shared.appendingPathComponent(folder + "/own.jsonl"), #"{"type":"user"}"# + "\n") }
        for folder in accountFolders { try put(config(kiwi, "projects/" + folder + "/theirs.jsonl"), #"{"type":"user"}"# + "\n") }; try createConfig(codex)
        let result = await r.service.adopt([kiwi, codex, own]); XCTAssertEqual(result["joined"], .array([.string(kiwi.id)])); XCTAssertEqual(result["left"], .array([.string(codex.id)])); XCTAssertEqual(result["already"], .array([.string(own.id)])); XCTAssertEqual(result["failed"], .array([]))
        let kiwiReads = await r.service.readsShared(kiwi), ownReads = await r.service.readsShared(own); XCTAssertTrue(kiwiReads); XCTAssertTrue(ownReads)
        for folder in ownFolders { XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent(folder + "/own.jsonl").path)) }
        for folder in ["-Users-apple-bin", "-private-var-folders-7j-copilot-probe-copilot"] { XCTAssertTrue(FileManager.default.fileExists(atPath: r.shared.appendingPathComponent(folder + "/theirs.jsonl").path)) }
        for folder in accountFolders where ownFolders.contains(folder) { XCTAssertEqual(try names(r.shared.appendingPathComponent(folder)), ["own.jsonl", "theirs.jsonl"]) }
        XCTAssertFalse(try names(URL(fileURLWithPath: kiwi.configDir)).contains { $0.hasPrefix("projects.not-merged-") }); XCTAssertTrue(symlink(config(kiwi)))
    }
    func testSharedProjects481CurrentFolderReadableFromOtherAccount() async throws {
        let r = try rig(), kiwi = account("examplemail-gmail-com", r)
        for folder in ownFolders { try put(r.shared.appendingPathComponent(folder + "/own.jsonl"), #"{"type":"user"}"# + "\n") }; try createConfig(kiwi)
        _ = await r.service.adopt([kiwi]); XCTAssertEqual(try names(config(kiwi, "projects/-Users-apple-Projects-terminaldeck")), ["own.jsonl"])
    }
}
