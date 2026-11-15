import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Two-Mac proof (13 Nov): a running Mac noticed a newly joined device only after a restart. The device list is now
/// asked on a quiet timer, and a changed list leads to the full status read, which trusts the device automatically.
@Suite("Cloud account — the device list refreshes by itself")
struct CloudAccountDeviceWatchTests {
    static let idA = "10000000-0000-4000-8000-00000000000a"
    private func key() -> CloudPublicJWK {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    private func device(_ id: String, _ name: String, _ jwk: CloudPublicJWK) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
              lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
    }
    @Test func aJoinedDeviceIsTrustedWithoutARestart() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setTrustMode(.account)
        _ = try await f.signin()
        let stateCalls = await f.transport.stateCalls
        // Nothing changed: one device-list request, no status read.
        #expect(try await f.account.refreshDevicesIfChanged() == false)
        #expect(await f.transport.stateCalls == stateCalls)
        // Another Mac joins while this one runs.
        await f.server.setOthers([device(Self.idA, "MacBook Pro", key())])
        #expect(try await f.account.refreshDevicesIfChanged())
        let row = try #require(await f.account.state().trust.first { $0.deviceId == Self.idA })
        #expect(row.standing == .trusted)
        #expect(row.byAccount)
        #expect(await f.transport.stateCalls == stateCalls + 1)
        // Asked again with nothing new: no second status read.
        #expect(try await f.account.refreshDevicesIfChanged() == false)
    }
    @Test func nothingIsAskedWhileSignedOut() async throws {
        let f = try CloudAccountFixture.make()
        #expect(try await f.account.refreshDevicesIfChanged() == false)
        #expect(await f.transport.deviceCalls == 0)
        _ = try await f.signin()
        try await f.account.signOut()
        let calls = await f.transport.deviceCalls
        #expect(try await f.account.refreshDevicesIfChanged() == false)
        #expect(await f.transport.deviceCalls == calls)
    }
    @Test func lastSeenAloneIsNoChange() {
        let jwk = key()
        let a = device(Self.idA, "MacBook Pro", jwk)
        let b = CloudDevice(deviceId: Self.idA, label: "MacBook Pro", platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                            lastSeenAt: 1_794_999_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
        #expect(BackendCloudAccount.deviceFingerprint([a]) == BackendCloudAccount.deviceFingerprint([b]))
        let gone = CloudDevice(deviceId: Self.idA, label: "MacBook Pro", platform: .macos, appVersion: "fixture", status: .revoked, secretsApproved: false,
                               lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
        #expect(BackendCloudAccount.deviceFingerprint([a]) != BackendCloudAccount.deviceFingerprint([gone]))
    }
}
