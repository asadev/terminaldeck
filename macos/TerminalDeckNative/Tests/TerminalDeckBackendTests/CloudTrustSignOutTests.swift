import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Two-Mac proof (13 Nov): after signing out and in again, a Mac listed itself twice and its old entry stayed
/// "Trusted". Sign-out now removes this device at the service; removed devices leave every Mac's trusted list; a
/// stale earlier entry of the same Mac is never trusted automatically.
@Suite("Cloud trust — sign-out removes this device, removed and stale entries are not trusted")
struct CloudTrustSignOutTests {
    static let idA = "10000000-0000-4000-8000-00000000000a"
    static let idB = "10000000-0000-4000-8000-00000000000b"
    static let subject = CloudSubject(issuer: "https://issuer.example.invalid/auth/v1", sub: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    private func key() -> CloudPublicJWK {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    private func device(_ id: String, _ name: String, _ jwk: CloudPublicJWK, status: CloudDeviceStatus = .active,
                        seen: Int64 = 1_794_000_000_000, added: Int64? = 1_793_000_000_000) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: status, secretsApproved: false,
              lastSeenAt: seen, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: added)
    }
    private func ownRows(_ f: CloudAccountFixture) async -> [CloudDeviceTrustRow] {
        await f.account.state().trust.filter { $0.name == "Fixture Mac" }
    }

    @Test func signOutRemovesThisDeviceAndSigningInAgainListsItOnce() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        let first = try await f.identity.deviceRegistration().deviceId
        try await f.account.signOut()
        #expect(await f.server.removals == 1)
        #expect(try await f.identity.existing() == nil)
        f.clock.advance(60_000)
        _ = try await f.signin()
        let second = try await f.identity.deviceRegistration().deviceId
        // One fresh entry: a new device id and key.
        #expect(second != first)
        let rows = await ownRows(f)
        #expect(rows.filter { $0.standing == .thisMac }.map(\.deviceId) == [second])
        // The old entry is reported removed: off this Mac's trusted list and not shown.
        let old = try #require(rows.first { $0.deviceId == first })
        #expect(old.removed)
        #expect(old.standing == .new)
        #expect(!old.canBeTrusted)
        let entry = try #require(try await f.trust.list().devices.first { $0.deviceId == first })
        #expect(!entry.trusted)
        #expect(entry.stopReason == "removed from account")
    }
    @Test func aFailedRemovalStillSignsOutAndTheOldEntryIsStale() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        let first = try await f.identity.deviceRegistration().deviceId
        await f.server.setRefuseRemoval(true)
        await f.server.setLeaveOffline(true)
        try await f.account.signOut()
        #expect(await f.account.state().phase == .signedOut)
        #expect(try await f.identity.existing() == nil)
        f.clock.advance(60_000)
        _ = try await f.signin()
        let old = try #require(await ownRows(f).first { $0.deviceId == first })
        #expect(!old.removed)
        #expect(old.stale)
        #expect(!old.canBeTrusted)
    }
    /// 13 Nov leftover: a Mac that signs in again listed its own OLD entry as "cannot be trusted right now". In every
    /// trust mode the old entry is now stopped on this Mac's list and named nowhere on the Cloud page.
    @Test func aMacSigningInAgainNeitherTrustsNorShowsItsOldEntryInEitherMode() async throws {
        for mode in [BackendCloudTrustMode.ask, .account] {
            let f = try CloudAccountFixture.make()
            await f.account.setTrustMode(mode)
            _ = try await f.signin()
            let first = try await f.identity.deviceRegistration().deviceId
            await f.server.setRefuseRemoval(true)
            await f.server.setLeaveOffline(true)
            try await f.account.signOut()
            f.clock.advance(60_000)
            _ = try await f.signin()
            let snapshot = await f.account.state()
            let old = try #require(snapshot.trust.first { $0.deviceId == first })
            #expect(old.stale)
            #expect(old.standing != .trusted)
            #expect(await f.trust.trustedSigningKey(deviceId: first) == nil)
            #expect(try await f.trust.list().devices.first { $0.deviceId == first }?.stopReason == BackendCloudTrustStore.staleReason)
            var input = BackendCloudOverviewInput(snapshot: snapshot, memory: .init(included: true))
            input.automaticTrust = mode == .account
            let page = try #require(BackendCloudOverviewBuilder.build(input))
            #expect(!page.waiting.contains { $0.id == "device:" + first || $0.text.contains("cannot be trusted right now") })
            #expect(!page.notices.contains { $0.id == "joined:" + first })
        }
    }
    @Test func anotherMacStopsTrustingADeviceReportedRemoved() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        let jwk = key()
        await f.server.setOthers([device(Self.idA, "MacBook Pro", jwk)])
        _ = try await f.signin()
        #expect(try await f.trust.list().devices.first { $0.deviceId == Self.idA }?.trusted == true)
        await f.server.setOthers([device(Self.idA, "MacBook Pro", jwk, status: .revoked)])
        #expect(try await f.account.refreshDevicesIfChanged())
        let entry = try #require(try await f.trust.list().devices.first { $0.deviceId == Self.idA })
        #expect(!entry.trusted)
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
        // Never added back by itself, and this Mac's own identity is untouched.
        try await f.account.refresh()
        #expect(try await f.trust.list().devices.first { $0.deviceId == Self.idA }?.trusted == false)
        let mine = try await f.identity.deviceRegistration().deviceId
        #expect(try await f.trust.list().devices.first { $0.deviceId == mine }?.trusted == true)
    }
    @Test func aStaleEntryOfTheSameMacIsNotTrustedAutomatically() async throws {
        let oldKey = key(), newKey = key(), other = key()
        // The old entry was last seen before the same Mac (same name, another key) was added again.
        let devices = [device(Self.idA, "Studio b", oldKey, seen: 1_000, added: 500),
                       device(Self.idB, "Studio b", newKey, seen: 3_000, added: 2_000),
                       device("10000000-0000-4000-8000-00000000000c", "Air", other, seen: 1_000, added: 500)]
        #expect(BackendCloudTrustRows.stale(devices: devices, thisDeviceId: nil) == [Self.idA])
        // Seen again after the newer entry was added: two real Macs of one name, neither is stale.
        let both = [device(Self.idA, "Studio b", oldKey, seen: 2_500, added: 500), devices[1]]
        #expect(BackendCloudTrustRows.stale(devices: both, thisDeviceId: nil).isEmpty)
        // This Mac's current identity is never stale.
        #expect(BackendCloudTrustRows.stale(devices: devices, thisDeviceId: Self.idA).isEmpty)
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let rows = BackendCloudTrustRows.build(devices: devices, list: nil, thisDeviceId: nil)
        #expect(rows.first { $0.deviceId == Self.idA }?.stale == true)
        let added = try await store.trustByAccount(rows)
        #expect(Set(added) == [Self.idB, "10000000-0000-4000-8000-00000000000c"])
    }

    // Proof 2 (13 Nov): B's saved passwords were protected and locked; sign-out logged "device removal failed:
    // secretsLocked" and A kept trusting B. The removal no longer depends on reading the vault version.
    @Test func aMacWhoseStatusCannotBeReadStillRemovesItselfWithoutTheVersion() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        await f.transport.failState(["secrets_locked", "secrets_locked", "secrets_locked"])
        try await f.account.signOut()
        #expect(await f.server.removals == 1)
        #expect(await f.server.lastRemovalVersion == .some(nil))
        #expect(try await f.identity.leaveNotes().isEmpty)
        #expect(f.store.value() == nil || f.store.value() == #"{"signedOut":true}"#)
    }
    @Test func anOfflineSignOutKeepsASignedLeaveNoteAndSendsItWhenCloudAnswers() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        let first = try await f.identity.deviceRegistration().deviceId
        await f.server.setRemovalOffline(true)
        await f.server.setLeaveOffline(true)
        try await f.account.signOut()
        #expect(await f.account.state().phase == .signedOut)
        #expect(await f.server.removals == 0)
        // The note survives a restart: a fresh identity over the same store still holds it, and no key or token.
        let stored = try #require(f.store.value())
        #expect(stored.contains(first) && stored.contains("\"signedOut\":true"))
        #expect(!stored.contains("fixture-refresh") && !stored.contains("signing"))
        let again = BackendCloudAccountIdentity(configuration: f.identity.configuration, store: f.store.port(), http: f.server, clock: { f.clock.now() })
        #expect(try await again.leaveNotes().map(\.deviceId) == [first])
        #expect(try await again.existing() == nil)
        // Still offline: kept. Cloud answers: taken, the old entry is removed, the note forgotten.
        await f.account.sendLeaveNotes()
        #expect(try await f.identity.leaveNotes().count == 1)
        await f.server.setLeaveOffline(false)
        await f.account.sendLeaveNotes()
        #expect(await f.server.leaveTaken == [first])
        #expect(await f.server.devices().devices.first { $0.deviceId == first }?.status == .revoked)
        #expect(try await f.identity.leaveNotes().isEmpty)
        #expect(f.store.value() == nil)
        // Sent twice changes nothing.
        await f.account.sendLeaveNotes()
        #expect(await f.server.leaveTaken == [first])
    }
    @Test func aLeaveNoteOutlivesTheNextSignInAndIsSentThen() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        let first = try await f.identity.deviceRegistration().deviceId
        await f.server.setRemovalOffline(true)
        await f.server.setLeaveUnknown(true)
        try await f.account.signOut()
        // An older service without the leave route: the note is kept, not dropped.
        #expect(try await f.identity.leaveNotes().map(\.deviceId) == [first])
        await f.server.setRemovalOffline(false)
        f.clock.advance(60_000)
        _ = try await f.signin()
        #expect(try await f.identity.leaveNotes().map(\.deviceId) == [first])
        await f.server.setLeaveUnknown(false)
        await f.account.sendLeaveNotes()
        #expect(await f.server.leaveTaken == [first])
        #expect(try await f.identity.leaveNotes().isEmpty)
        // This Mac's new identity is untouched.
        #expect(try await f.identity.existing() != nil)
        #expect(try await f.identity.deviceRegistration().deviceId != first)
    }
    // Mac-next 2 (13 Nov): a service that answers "not found" for the leave route: the sign-out ends exactly as it
    // did before leave notes (signed out, nothing kept, no key or token left), and the note is never sent again.
    @Test func aServiceThatAnswersNotFoundForTheLeaveRouteSignsOutAsBefore() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        await f.server.setRemovalOffline(true)
        await f.server.setLeaveNotFound(true)
        try await f.account.signOut()
        #expect(await f.account.state().phase == .signedOut)
        #expect(await f.account.state().problem == nil)
        #expect(await f.server.leaveCalls == 1)
        #expect(try await f.identity.leaveNotes().isEmpty)
        #expect(try await f.identity.existing() == nil)
        #expect(f.store.value() == nil || f.store.value() == #"{"signedOut":true}"#)
        await f.account.sendLeaveNotes()
        await f.account.networkReturned()
        #expect(await f.server.leaveCalls == 1)
    }
}
