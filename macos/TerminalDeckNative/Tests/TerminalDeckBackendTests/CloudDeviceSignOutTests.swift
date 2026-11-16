import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner, 14 Nov: Remove has one meaning, it signs that device out. `signOutDevice` asks the Cloud
/// (`POST /devices/remove`) for the chosen device only; this Mac's own id and a device holding the saved-passwords key
/// are refused with nothing changed.
@Suite("Cloud account — signing another device out")
struct CloudDeviceSignOutTests {
    static let phone = "20000000-0000-4000-8000-0000000000b1"
    static let mini = "20000000-0000-4000-8000-0000000000b2"
    private func device(_ id: String, _ name: String, _ platform: CloudPlatform) -> CloudDevice {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let jwk = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                 y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        return .init(deviceId: id, label: name, platform: platform, appVersion: "fixture", status: .active, secretsApproved: false,
                     lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
    }
    private func signedIn() async throws -> CloudAccountFixture {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        await f.server.setOthers([device(Self.phone, "iPhone", .ios), device(Self.mini, "Mac mini", .macos)])
        // DEVICE-SIGNOUT-3: this Mac's list is read once more, so every check starts from a state that SHOWS both
        // devices (a refused sign-out reads nothing, so a stale state would prove nothing).
        try await f.account.refresh()
        let shown = DevicesPage.accountDevices(await f.account.state()).compactMap(\.deviceId)
        #expect(shown.contains(Self.phone) && shown.contains(Self.mini))
        return f
    }

    @Test func signsOutTheChosenDeviceOnly() async throws {
        let f = try await signedIn()
        try await f.account.signOutDevice(Self.phone)
        let sent = await f.server.signedOut
        #expect(sent.map(\.id) == [Self.phone])
        #expect(sent.first?.version == .zero, "the vault version read now is sent")
        // The list read afterwards no longer shows it as active: it leaves the page.
        let shown = DevicesPage.accountDevices(await f.account.state()).compactMap(\.deviceId)
        #expect(!shown.contains(Self.phone))
        #expect(shown.contains(Self.mini))
    }

    @Test func thisMacIsNeverSignedOutHere() async throws {
        let f = try await signedIn()
        let mine = try await f.identity.deviceRegistration().deviceId
        await #expect(throws: BackendDeviceSignOutRefusal.thisMac) { try await f.account.signOutDevice(mine) }
        #expect(await f.server.signedOut.isEmpty)
    }

    @Test func aDeviceHoldingTheSavedPasswordsKeyKeepsEverything() async throws {
        let f = try await signedIn()
        await f.server.refuseSignOut(["rotation_required"])
        await #expect(throws: BackendDeviceSignOutRefusal.holdsSavedPasswordsKey) { try await f.account.signOutDevice(Self.mini) }
        #expect(await f.server.signedOut.isEmpty)
        #expect(DevicesPage.accountDevices(await f.account.state()).compactMap(\.deviceId).contains(Self.mini))
        // And after the next read of the account, too: the service kept it, so this Mac keeps showing it.
        try await f.account.refresh()
        #expect(DevicesPage.accountDevices(await f.account.state()).compactMap(\.deviceId).contains(Self.mini))
    }

    @Test func aMovedVersionIsReadAgainOnce() async throws {
        let f = try await signedIn()
        await f.server.refuseSignOut(["version_changed"])
        #expect(try await f.account.signOutDevice(Self.phone) == .signedOut)
        #expect(await f.server.signedOut.map(\.id) == [Self.phone])
        await f.server.refuseSignOut(["version_changed", "version_changed"])
        await #expect(throws: CloudFailure.self) { try await f.account.signOutDevice(Self.mini) }
    }

    /// DEVICE-SIGNOUT-2 (security): "not found" is judged by the account's list read now.
    @Test func notFoundIsJudgedByTheListReadNow() async throws {
        let f = try await signedIn()
        // Still listed as active: a failure, never "done".
        await f.server.refuseSignOut(["not_found"])
        await #expect(throws: CloudFailure.self) { try await f.account.signOutDevice(Self.mini) }
        // Listed as revoked: already signed out.
        try await f.account.signOutDevice(Self.phone)
        await f.server.refuseSignOut(["not_found"])
        #expect(try await f.account.signOutDevice(Self.phone) == .alreadyGone)
        // Not listed at all (a browser's reach key): only reach's removal can sign it out; the caller judges.
        await f.server.refuseSignOut(["not_found"])
        #expect(try await f.account.signOutDevice("30000000-0000-4000-8000-0000000000c1") == .notAnAccountDevice)
    }

    @Test func signedOutHereSignsNobodyOut() async throws {
        let f = try CloudAccountFixture.make()
        await #expect(throws: BackendDeviceSignOutRefusal.notSignedIn) { try await f.account.signOutDevice(Self.phone) }
        #expect(await f.server.signedOut.isEmpty)
    }
}
