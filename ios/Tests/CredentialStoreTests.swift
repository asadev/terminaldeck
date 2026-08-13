/**
 * The Keychain store, against the real Keychain.
 *
 * Not a mock: `SecItemAdd` has behaviour worth testing, and the one that bit
 * this file is that adding an item that already exists returns
 * `errSecDuplicateItem` and writes *nothing* — so a credential would be saved
 * once at pairing and never updated again, and the durable token that arrives
 * in the `welcome` would be silently dropped. Every test here uses its own
 * service name so it cannot touch the one a paired app is using.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class CredentialStoreTests: XCTestCase {

    private var store: KeychainCredentialStore!

    override func setUp() {
        super.setUp()
        store = KeychainCredentialStore(service: "dev.terminaldeck.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        store.eraseEverything()
        super.tearDown()
    }

    private func credential(_ token: String, kind: StoredCredential.Kind = .pairing) -> StoredCredential {
        StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: "M9G95TNJT64Q928VW3HVRYDR8J",
                             hostKey: Data(repeating: 7, count: 32)),
            token: token,
            kind: kind,
            deviceId: "device-1",
            deviceName: "iPhone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testNothingIsStoredUntilSomethingIs() {
        XCTAssertNil(store.load())
    }

    func testACredentialSurvivesAFreshInstanceOfTheStore() {
        let service = "dev.terminaldeck.tests.\(UUID().uuidString)"
        let first = KeychainCredentialStore(service: service)
        first.save(credential("abc"))

        // A second instance reads the Keychain rather than the first one's cache,
        // which is what a relaunch does.
        let second = KeychainCredentialStore(service: service)
        XCTAssertEqual(second.load()?.token, "abc")
        second.eraseEverything()
    }

    func testTheDurableTokenReplacesThePairingOne() {
        store.save(credential("pairing-token"))
        let redeemed = store.load()!.redeemed(token: "device.credential",
                                              deviceId: "d-9", deviceName: "Asad's iPhone")
        store.save(redeemed)

        // The update path, which `SecItemAdd` alone would have silently skipped.
        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(reloaded.load()?.token, "device.credential")
        XCTAssertEqual(reloaded.load()?.kind, .device)
        XCTAssertEqual(reloaded.load()?.deviceId, "d-9")
    }

    func testClearingForgetsTheCredential() {
        store.save(credential("abc"))
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertNil(KeychainCredentialStore(service: store.serviceForTesting).load())
    }

    func testClearingKeepsTheDeviceIdentity() {
        // Unpairing must not change who this phone is. Regenerating the static
        // key would make the Mac see a stranger the next time, and put a second
        // row in its device list for one physical phone.
        let before = store.deviceKeys()
        store.clear()
        XCTAssertEqual(store.deviceKeys().publicKey, before.publicKey)
        XCTAssertEqual(KeychainCredentialStore(service: store.serviceForTesting).deviceKeys().publicKey,
                       before.publicKey)
    }

    func testTheDeviceKeyIsAUsableX25519Identity() {
        let keys = store.deviceKeys()
        XCTAssertEqual(keys.privateKey.count, 32)
        XCTAssertEqual(keys.publicKey.count, 32)
        // Derived, not stored: rebuilding from the private half must agree.
        XCTAssertEqual(StaticKeyPair(privateKey: keys.privateKey)?.publicKey, keys.publicKey)
    }

    func testTwoStoresAreTwoIdentities() {
        // Different service names must not share a device key — this is what
        // keeps a test from stamping on the running app's identity.
        let other = KeychainCredentialStore(service: "dev.terminaldeck.tests.\(UUID().uuidString)")
        XCTAssertNotEqual(other.deviceKeys().publicKey, store.deviceKeys().publicKey)
        other.eraseEverything()
    }

    func testTheEndpointComesBackIntact() {
        store.save(credential("abc"))
        guard case let .relay(url, hostId, hostKey) = store.load()?.endpoint else {
            return XCTFail("expected a relay endpoint")
        }
        XCTAssertEqual(url.absoluteString, "wss://relay.example")
        XCTAssertEqual(hostId, "M9G95TNJT64Q928VW3HVRYDR8J")
        XCTAssertEqual(hostKey.count, 32)
    }
}
