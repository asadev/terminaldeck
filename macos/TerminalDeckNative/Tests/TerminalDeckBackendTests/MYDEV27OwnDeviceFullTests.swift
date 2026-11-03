import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// #27 (Asad, 3 Nov): "for my device, when you choose my device, it should have everything ... all the accounts ...
/// same as you own it". Over the real trust store in a scratch folder: the person's own device reaches every login and
/// session whatever lists were kept for it, a list for it is refused in plain words, the devices paired before 0.21.0
/// are brought to Full once (a later choice stays), a computer signing in with this Mac's login gets Full, and only
/// the own device at Full starts without the sandbox or the stand-in git setup. Guests keep what sec-26 gave them.
@Suite("#27 my device gets everything", .serialized)
struct MYDEV27OwnDeviceFullTests {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var rows: [String] = []
        func add(_ line: String) { lock.lock(); rows.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return rows }
    }
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MYDEV27-" + UUID().uuidString + ".noindex")
    }
    private func pair(_ trust: BackendRemoteTrustStore, _ name: String) async throws -> String {
        let offer = try await trust.createPairingOffer()
        return try await trust.redeem(offer.token, name: name, address: "test", publicKey: nil).device.id
    }
    /// The login and session lists as the remote-serve owners save them, read back on open.
    private func saveLists(_ directory: URL, _ ids: [String]) throws {
        func save(_ name: String, _ key: String, _ value: String) throws {
            try NativeRPCValue.object([.init("version", .number(1)), .init("devices", .object(ids.map {
                .init($0, .object([.init("mode", .string("selected")), .init(key, .array([.string(value)]))]))
            }))]).encodedJSON().write(to: directory.appendingPathComponent(name))
        }
        try save("remote-accounts.json", "accounts", "allowed-account")
        try save("remote-sessions.json", "sessions", "allowed-session")
    }

    @Test func yourOwnDeviceReachesEveryLoginAndSessionWhateverListWasKept() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let mine = try await pair(trust, "Asad's iPhone"), guest = try await pair(trust, "Visitor"), plain = try await pair(trust, "Old guest")
        try await trust.approve(mine, kind: .mine); try await trust.approve(guest, kind: .guest); try await trust.approve(plain, kind: .guest)
        await trust.close()
        try saveLists(directory, [mine, guest])
        try await trust.open()
        try await trust.setPhoneAccess(mine, level: .full); try await trust.setPhoneAccess(guest, level: .work)
        // Own device: every login, every session, no account subset on its reach.
        #expect(await trust.accountAllowed(mine, account: "allowed-account"))
        #expect(await trust.accountAllowed(mine, account: "any-other-login"))
        #expect(await trust.hasAnyAccount(mine))
        #expect(await trust.sessionShared(mine, session: "any-session"))
        #expect(await trust.reach(mine, offered: [], home: directory.path).accounts == nil)
        #expect(await trust.reach(mine, offered: [], home: directory.path).unrestricted)
        // A guest keeps its lists exactly; a guest without one is as before.
        #expect(await trust.accountAllowed(guest, account: "allowed-account"))
        #expect(await !trust.accountAllowed(guest, account: "any-other-login"))
        #expect(await !trust.sessionShared(guest, session: "any-session"))
        #expect(await trust.reach(guest, offered: [], home: directory.path).accounts == ["allowed-account"])
        #expect(await trust.accountAllowed(plain, account: "any-other-login"))
        await trust.close()
    }

    @Test func aListForYourOwnDeviceIsRefusedInPlainWordsAndAGuestsIsKept() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let mine = try await pair(trust, "Asad's iPhone"), guest = try await pair(trust, "Visitor")
        try await trust.approve(mine, kind: .mine); try await trust.approve(guest, kind: .guest)
        let attempts: [@Sendable () async throws -> Void] = [
            { _ = try await trust.remoteServeSetAccountGrants(mine, mode: .string("selected"), accounts: [.string("work")]) },
            { _ = try await trust.remoteServeSetSessionGrants(mine, mode: .string("selected"), sessions: [.string("s-1")]) },
            { _ = try await trust.remoteServeSetFolderGrants(mine, folders: [.string("/Users/someone/Projects")]) }]
        for attempt in attempts {
            do { try await attempt(); Issue.record("A list for the own device was saved") }
            catch let error as NativeRPCError { #expect(error.code == "own-device"); #expect(error.message == BackendRemoteTrustStore.ownDeviceReachesAll) }
        }
        #expect(await trust.remoteServeAccountGrant(mine) == nil)
        #expect(await trust.remoteServeSessionGrant(mine) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote-accounts.json").path))
        let kept = try await trust.remoteServeSetAccountGrants(guest, mode: .string("selected"), accounts: [.string("work")])
        #expect(kept.accounts == ["work"] && !kept.all)
        await trust.close()
    }

    /// Review S-D3 (Decker): the upgrade removes limits and fills a missing level; a level the person chose stays.
    @Test func devicesPairedBeforeLoseTheirListsAndOnlyAMissingLevelBecomesFull() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let looking = try await pair(trust, "iPhone at Look"), unset = try await pair(trust, "Android, no level")
        let full = try await pair(trust, "Browser at Full"), guest = try await pair(trust, "Visitor"), gone = try await pair(trust, "Old iPhone")
        for id in [looking, unset, full, gone] { try await trust.approve(id, kind: .mine) }
        try await trust.approve(guest, kind: .guest)
        try await trust.setPhoneAccess(looking, level: .look); try await trust.setPhoneAccess(full, level: .full)
        try await trust.setPhoneAccess(guest, level: .work); try await trust.setPhoneAccess(gone, level: .look)
        try await trust.revoke(gone)
        await trust.close()
        try saveLists(directory, [looking, guest])
        try await trust.open()
        let lines = Lines()
        let outcome = try await trust.upgradeOwnDevicesToFull(report: { lines.add($0) })
        #expect(outcome == BackendRemoteTrustStore.OwnDevicesFullOutcome(own: 3, raised: 1, unlimited: 1))
        #expect(lines.all == [outcome?.line ?? ""])
        #expect(lines.all.first?.contains("3 of yours; 1 without a level set to Full control; 1 had a login, session or folder list removed") == true)
        // The one lowered to Look stays at Look (its lists are gone); the one with no level gets Full; Full stays Full.
        #expect(await trust.phoneAccess(looking) == .look)
        #expect(await trust.phoneAccess(unset) == .full)
        #expect(await trust.phoneAccess(full) == .full)
        #expect(await trust.remoteServeAccountGrant(looking) == nil)
        #expect(await trust.remoteServeSessionGrant(looking) == nil)
        // Guests and revoked devices are not touched.
        #expect(await trust.phoneAccess(guest) == .work)
        #expect(await trust.remoteServeAccountGrant(guest)?.accounts == ["allowed-account"])
        #expect(await trust.phoneAccess(gone) == nil)
        #expect(await !trust.isApproved(gone))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(BackendRemoteTrustStore.ownDevicesFullMarker).path))
        // Saved to disk, and once only: a level lowered afterwards stays as chosen.
        try await trust.setPhoneAccess(full, level: .work)
        await trust.close(); try await trust.open()
        #expect(await trust.phoneAccess(unset) == .full)
        #expect(try await trust.upgradeOwnDevicesToFull(report: { lines.add($0) }) == nil)
        #expect(await trust.phoneAccess(full) == .work)
        #expect(await trust.phoneAccess(looking) == .look)
        #expect(lines.all.count == 1)
        await trust.close()
    }

    @Test func aComputerSigningInWithThisMacsLoginGetsFullAndKeepsALaterChoice() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let first = try await trust.enrollVerifiedDevice(name: "Office Mac", address: "test", publicKey: key)
        #expect(first.device.approved && !first.device.revoked)
        #expect(await trust.kindOf(first.device.id) == .mine)
        #expect(await trust.phoneAccess(first.device.id) == .full)
        try await trust.setPhoneAccess(first.device.id, level: .work)
        let again = try await trust.enrollVerifiedDevice(name: "Office Mac", address: "test", publicKey: key)
        #expect(again.device.id == first.device.id)
        #expect(await trust.phoneAccess(first.device.id) == .work)
        await trust.close()
    }

    @Test func onlyYourOwnDeviceAtFullStartsWithoutTheSandboxOrTheStandInGit() throws {
        #expect(!BackendINT2PhoneAccessLevel.sandboxesStarts(.full, kind: .mine))
        for level in [BackendINT2PhoneAccessLevel.work, .hoot, .look, nil] { #expect(BackendINT2PhoneAccessLevel.sandboxesStarts(level, kind: .mine)) }
        // A guest raised to Full on the Devices page still works inside its folders and its own account folders.
        for level in [BackendINT2PhoneAccessLevel.full, .work, .hoot, .look, nil] { #expect(BackendINT2PhoneAccessLevel.sandboxesStarts(level, kind: .guest)) }
        let guest = BackendRemoteServeGitGuest.environment(.init(directory: URL(fileURLWithPath: "/tmp/device-key"),
            link: .init(url: "http://127.0.0.1:1/credential", key: "k", helper: "/tmp/askpass.sh")))
        #expect(guest.set["GIT_CONFIG_GLOBAL"] != nil && guest.remove.contains("SSH_AUTH_SOCK"))
        let own = BackendRemoteServeGitGuest.forStart(guest, sandboxed: false)
        #expect(own.set.isEmpty && own.remove.isEmpty)
        let sandboxed = BackendRemoteServeGitGuest.forStart(guest, sandboxed: true)
        #expect(sandboxed.set == guest.set && sandboxed.remove == guest.remove)
    }

    // MARK: The phone's Files (#27): the whole Mac for the own device, never a guest

    private func context(_ kind: BackendRemoteDeviceKind, level: BackendINT2PhoneAccessLevel = .full) -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "phone-1", kind: kind, address: "relay", peerPublicKey: nil, claimedCapabilities: ["files"],
              reach: .init(kind: kind, unrestricted: kind == .mine, folders: kind == .mine ? [] : ["/tmp/given"], accounts: nil, drivesWindows: false),
              phoneAccess: level)
    }
    private func frame(_ type: String, _ fields: [NativeRPCValue.Field]) -> BackendRemoteClientMessage {
        BackendRemoteClientMessage(.object([.init("t", .string(type))] + fields))
    }

    @Test func yourOwnPhoneListsAndReadsAnyFolderOnTheMacAndAGuestIsRefused() async throws {
        let base = URL(fileURLWithPath: BackendMacConfinement.kernelPath(scratch().path)); defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("zeta folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try Data("SECRET=1\n".utf8).write(to: base.appendingPathComponent(".env"))
        try Data("hello".utf8).write(to: base.appendingPathComponent("b.txt"))
        let feature = BackendPhoneFiles().feature()
        #expect(feature.capability == "files" && feature.policy == .ownerOnly && feature.messageTypes == ["files.list", "files.read"])
        // Own device: folders first, then names; dot-files kept; a file's size and time; the folder above.
        let rows = try await feature.handle(frame("files.list", [.init("path", .string(base.path))]), context(.mine))
        // Under the phones' own cap on a message, as sent (review-install-27 #7).
        #expect(BackendPhoneFiles.sentSize(try #require(rows.first)) <= BackendPhoneFiles.phoneMessageLimit)
        let listed = try #require(rows.first).value
        #expect(listed["t"] == .string("files.rows") && listed["path"] == .string(base.path))
        #expect(listed["parent"] == .string(base.deletingLastPathComponent().path))
        let entries = listed["entries"].elements ?? []
        #expect(entries.compactMap { $0["name"].string } == ["Alpha", "zeta folder", ".env", "b.txt"])
        #expect(entries.prefix(2).allSatisfy { $0["directory"] == .bool(true) })
        #expect(entries.last?["size"] == .number(5) && entries.last?["at"].number != nil)
        // Not only project folders: the top of the Mac itself, with no folder above it.
        let top = try await feature.handle(frame("files.list", [.init("path", .string("/"))]), context(.mine, level: .look))
        #expect(top.first?.value["parent"] == .null)
        #expect(top.first?.value["entries"].elements?.contains { $0["name"] == .string("Users") } == true)
        let read = try await feature.handle(frame("files.read", [.init("path", .string(base.appendingPathComponent(".env").path))]), context(.mine))
        #expect(read.first?.value["text"] == .string("SECRET=1\n") && read.first?.value["truncated"] == .bool(false))
        // A guest is never handed the Mac's files, even a folder it was given.
        do { _ = try await feature.handle(frame("files.list", [.init("path", .string(base.path))]), context(.guest)); Issue.record("A guest listed files") }
        catch let error as NativeRPCError { #expect(error.code == "unauthorized" && error.message == BackendPhoneFiles.guestRefusal) }
        let refusal = try #require(try BackendRemoteServeHostRefusals.guest("files.read")).value
        #expect(refusal["code"] == .string("unauthorized") && refusal["message"] == .string(BackendPhoneFiles.guestRefusal))
    }

    @Test func aFileIsReadInWholeCharacterWindowsAndBinaryIsSaidNotGarbled() throws {
        let base = URL(fileURLWithPath: BackendMacConfinement.kernelPath(scratch().path)); defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let text = base.appendingPathComponent("notes.md")
        try Data("abcé🙂z".utf8).write(to: text)   // a: 1 byte each, é: 2, 🙂: 4
        // A window that ends inside é or 🙂 stops before it; the next window starts exactly there.
        var at = 0, joined = "", windows = 0
        while true {
            let window = try BackendPhoneFiles.read(text.path, at: at, max: 4).value
            #expect(window["at"] == .number(Double(at)) && window["binary"] == .bool(false))
            let piece = window["text"].string ?? ""
            joined += piece; at += piece.utf8.count; windows += 1
            if window["truncated"] != .bool(true) || windows > 10 { break }
        }
        #expect(joined == "abcé🙂z" && windows >= 3)
        let binary = base.appendingPathComponent("core.log")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        let shown = try BackendPhoneFiles.read(binary.path, at: 0, max: 65536).value
        #expect(shown["binary"] == .bool(true) && shown["text"] == .string(""))
        let latin = base.appendingPathComponent("latin.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x6F, 0x6B]).write(to: latin)   // "café ok" in Latin-1, not UTF-8
        #expect(try BackendPhoneFiles.read(latin.path, at: 0, max: 65536).value["binary"] == .bool(true))
        #expect(throws: NativeRPCError.self) { try BackendPhoneFiles.read(base.path, at: 0, max: 10) }
        #expect(throws: NativeRPCError.self) { try BackendPhoneFiles.list("relative/path") }
    }

    /// Review S-D2 (Decker): an own device at Look only may read the Mac's files, never change them.
    @Test func lookOnlyReadsFilesAndNeverWritesThem() {
        let changes = ["files.write", "files.delete", "files.rename", "files.mkdir", "files.move", "files.upload"]
        for level in [BackendINT2PhoneAccessLevel.look, .hoot, .work] {
            for type in changes { #expect(!level.permits(type), "\(level.rawValue) may not \(type)") }
        }
        #expect(BackendINT2PhoneAccessLevel.look.permits("files.list") && BackendINT2PhoneAccessLevel.look.permits("files.read"))
        #expect(!BackendINT2PhoneAccessLevel.hoot.permits("files.list") && !BackendINT2PhoneAccessLevel.hoot.permits("files.read"))
        #expect(BackendINT2PhoneAccessLevel.fileReads == ["files.list", "files.read"])
        // The Mac serves Files as reads only today: nothing that writes is even routed.
        #expect(BackendPhoneFiles.messages == BackendINT2PhoneAccessLevel.fileReads)
    }
}
