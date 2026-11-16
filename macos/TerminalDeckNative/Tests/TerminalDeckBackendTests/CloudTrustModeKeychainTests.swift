import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 13 Nov, security gap 1: "How this Mac trusts your other devices" lives in the Keychain beside the trusted-device
/// list; the old Cloud-folder file is a one-time migration source and changes nothing afterwards. Gap 2: the
/// website's start request names the device. Item 4: one Remove means one thing (trust and reach).
/// Every test uses an in-memory slot: no test opens the Keychain.
@Suite("Cloud trust setting in the Keychain, the start request's device name, and one Remove")
struct CloudTrustModeKeychainTests {
    static let idA = "20000000-0000-4000-8000-00000000000a"
    static let idB = "20000000-0000-4000-8000-00000000000b"

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-trust-mode-" + UUID().uuidString + ".noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func key() -> CloudPublicJWK {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    private func device(_ id: String, _ name: String, _ jwk: CloudPublicJWK) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
              lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
    }
    private func signIn(_ f: CloudAccountFixture, mode: BackendCloudTrustMode) async throws {
        await f.account.setTrustMode(mode)
        let url = try await f.account.beginAppSignIn()
        try await f.server.authorize(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(try await f.account.finishAppReturn(token: items.first { $0.name == "callback" }!.value!, code: "fixture-code",
                                                    state: items.first { $0.name == "state" }!.value!))
    }
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var fail = false
        var ids: [String] { lock.withLock { _ids } }
        func add(_ id: String) throws { lock.withLock { _ids.append(id) }; if fail { throw CloudFailure.unavailable } }
    }

    // MARK: gap 1

    @Test func noStoredChoiceIsAutomaticAndALaterFileChangesNothing() throws {
        let dir = try folder(), file = dir.appendingPathComponent("trust-mode"), slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustModeStore(slot: slot.port(), legacyFile: file)
        #expect(store.load() == .account)
        #expect(slot.bytes() == Data("account".utf8), "the default is stored once, so the file is never read again")
        try Data("ask".utf8).write(to: file)
        #expect(store.load() == .account)
        #expect(!FileManager.default.fileExists(atPath: file.path), "a stale file is deleted, never read")
        #expect(store.load() == .account)
    }
    @Test func theOldFileIsReadOnceThenDeletedAndWritingOrDeletingItChangesNothing() throws {
        let dir = try folder(), file = dir.appendingPathComponent("trust-mode"), slot = CloudTrustFixtureSlot()
        try Data("ask".utf8).write(to: file)
        let store = BackendCloudTrustModeStore(slot: slot.port(), legacyFile: file)
        #expect(store.load() == .ask)
        #expect(slot.bytes() == Data("ask".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path), "migrated, then deleted")
        // Something that can write the Cloud folder tries to flip this Mac back to automatic.
        try Data("account".utf8).write(to: file)
        #expect(store.load() == .ask)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("account".utf8).write(to: file)
        try FileManager.default.removeItem(at: file)
        #expect(store.load() == .ask)
        // Only the page's own press changes it.
        try store.save(.account)
        #expect(store.load() == .account)
        try store.save(.ask)
        #expect(store.load() == .ask)
    }
    @Test func anUnreadableItemIsTheStricterAskAndTheFileIsLeftAlone() throws {
        let dir = try folder(), file = dir.appendingPathComponent("trust-mode"), slot = CloudTrustFixtureSlot()
        try Data("account".utf8).write(to: file)
        slot.breakReads(true)
        let store = BackendCloudTrustModeStore(slot: slot.port(), legacyFile: file)
        #expect(store.load() == .ask)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(slot.writes() == 0)
    }
    @Test func theItemIsASiblingOfTheTrustedListUnderTheSameService() {
        let mode = BackendCloudTrustModeStore.names(appName: "TD Test Throwaway", instanceId: "instance-1")
        let list = BackendCloudTrustSlot.names(appName: "TD Test Throwaway", instanceId: "instance-1", subjectHash: "subject-1")
        #expect(mode.service == list.service)
        #expect(mode.account != list.account && mode.account.hasPrefix("trust-mode:"))
        #expect(BackendCloudTrustModeStore.names(appName: "TD Test Throwaway", instanceId: "instance-2").account != mode.account)
    }

    // MARK: gap 2

    @Test func theStartRequestsDeviceNameIsTheRegistrationLabelCutTo64() {
        #expect(BackendCloudAccount.startDeviceLabel("Asad's Mac mini") == "Asad's Mac mini")
        let long = String(repeating: "m", count: 80)
        #expect(BackendCloudAccount.startDeviceLabel(long) == String(repeating: "m", count: 64))
        #expect(BackendCloudAccount.startDeviceLabel(String(repeating: "é", count: 70)).utf16.count <= 64)
    }

    // MARK: item 4, the Cloud side

    @Test func removingTrustAlsoAsksReachToRemoveTheDevice() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .account)
        let reach = Recorder()
        await f.account.setReachLink { id in try reach.add(id) }
        try await f.account.stopTrusting(deviceId: Self.idA)
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
        #expect(reach.ids == [Self.idA])
    }
    @Test func aReachFailureIsSaidButTheTrustChangeStays() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .account)
        let reach = Recorder(); reach.fail = true
        await f.account.setReachLink { id in try reach.add(id) }
        await #expect(throws: BackendReachLinkFailure()) { try await f.account.stopTrusting(deviceId: Self.idA) }
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
    }
    @Test func reachRemovalStopsATrustedDeviceAndKeepsAnUnlistedOneOut() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .account)
        let reach = Recorder()
        await f.account.setReachLink { id in try reach.add(id) }
        try await f.account.stopTrustingForReachRemoval(deviceId: Self.idA)
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
        #expect(reach.ids.isEmpty, "the reach side's own Remove is never called back")
        // A device this Mac has not listed yet (it signed in after the last read) is kept out of automatic trust.
        await f.server.setOthers([device(Self.idA, "MacBook Air", key()), device(Self.idB, "iPad", key())])
        await f.account.setTrustMode(.ask)
        try await f.account.refresh()
        try await f.account.stopTrustingForReachRemoval(deviceId: Self.idB)
        await f.account.setTrustMode(.account)
        try await f.account.refresh()
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idB) == nil)
        #expect(await f.trust.entry(deviceId: Self.idB)?.trust == "stopped")
        // A remote-input press is refused, as every trust press is.
        f.remoteInput.set(true)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.trust.stopForReachRemoval(deviceId: Self.idA, row: nil) }
    }
}
