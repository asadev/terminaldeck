/**
 * The Keychain store, against the real Keychain.
 *
 * Not a mock: `SecItemAdd` has behaviour worth testing, and the one that bit
 * this file is that adding an item that already exists returns
 * `errSecDuplicateItem` and writes *nothing* — so a credential would be saved
 * once at pairing and never updated again, and the durable token that arrives
 * in the `welcome` would be silently dropped. Every test here uses its own
 * service name so it cannot touch the one a paired app is using.
 *
 * ## What multi-host added, and what it must never do
 *
 * The store holds a collection now, and the whole risk of that change is in one
 * sentence: **pairing must add a machine, never replace one.** A phone that
 * pairs with a Windows PC and quietly drops the Mac does not look like a bug in
 * a collection, it looks like the app forgetting your Mac — so that is the case
 * with the most tests on it, from both directions (adding, and re-pairing with
 * something already in the list).
 *
 * The second half is what happens when a record cannot be read. A single blob
 * holding every pairing would lose all of them to one bad decode, which is why
 * there is one Keychain item per host; the tests below prove that a corrupt
 * record costs exactly one machine and is *reported* rather than swallowed.
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

    /// Two host ids in the relay's own alphabet — no `0`/`O`, no `1`/`I`.
    private static let macId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private static let pcId = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"

    private func credential(_ token: String,
                            hostId: String = macId,
                            kind: StoredCredential.Kind = .pairing,
                            nickname: String? = nil,
                            pairedAt: TimeInterval = 1_700_000_000) -> StoredCredential {
        StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: hostId,
                             hostKey: Data(repeating: 7, count: 32)),
            token: token,
            kind: kind,
            deviceId: "device-1",
            deviceName: "iPhone",
            pairedAt: Date(timeIntervalSince1970: pairedAt),
            nickname: nickname)
    }

    // MARK: - One machine

    func testNothingIsStoredUntilSomethingIs() {
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.load(Self.macId))
    }

    func testACredentialSurvivesAFreshInstanceOfTheStore() {
        let service = "dev.terminaldeck.tests.\(UUID().uuidString)"
        let first = KeychainCredentialStore(service: service)
        first.save(credential("abc"))

        // A second instance reads the Keychain rather than the first one's cache,
        // which is what a relaunch does.
        let second = KeychainCredentialStore(service: service)
        XCTAssertEqual(second.load(Self.macId)?.token, "abc")
        second.eraseEverything()
    }

    func testTheDurableTokenReplacesThePairingOne() {
        store.save(credential("pairing-token"))
        let redeemed = store.load(Self.macId)!.redeemed(token: "device.credential",
                                                        deviceId: "d-9", deviceName: "Asad's iPhone")
        store.save(redeemed)

        // The update path, which `SecItemAdd` alone would have silently skipped.
        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(reloaded.load(Self.macId)?.token, "device.credential")
        XCTAssertEqual(reloaded.load(Self.macId)?.kind, .device)
        XCTAssertEqual(reloaded.load(Self.macId)?.deviceId, "d-9")
        // One machine, still. A rotation is not a pairing.
        XCTAssertEqual(reloaded.all().count, 1)
    }

    func testForgettingOneMachineForgetsIt() {
        store.save(credential("abc"))
        store.remove(Self.macId)
        XCTAssertNil(store.load(Self.macId))
        XCTAssertNil(KeychainCredentialStore(service: store.serviceForTesting).load(Self.macId))
    }

    func testForgettingKeepsTheDeviceIdentity() {
        // Unpairing must not change who this phone is. Regenerating the static
        // key would make every machine see a stranger the next time, and put a
        // second row in each of their device lists for one physical phone.
        let before = store.deviceKeys()
        store.save(credential("abc"))
        store.clearAll()
        XCTAssertEqual(store.deviceKeys().publicKey, before.publicKey)
        XCTAssertEqual(KeychainCredentialStore(service: store.serviceForTesting).deviceKeys().publicKey,
                       before.publicKey)
    }

    // MARK: - Several machines

    /// The requirement, stated as plainly as it can be stated.
    func testPairingASecondMachineKeepsTheFirst() {
        store.save(credential("mac-token", hostId: Self.macId, pairedAt: 1_700_000_000))
        store.save(credential("pc-token", hostId: Self.pcId, pairedAt: 1_700_000_100))

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.load(Self.macId)?.token, "mac-token")
        XCTAssertEqual(store.load(Self.pcId)?.token, "pc-token")

        // And after a relaunch, which is when "my phone forgot my Mac" is
        // actually noticed.
        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(Set(reloaded.all().map(\.hostId)), [Self.macId, Self.pcId])
    }

    /// Oldest first, and stable. A switcher that reshuffles itself is one people
    /// tap the wrong row in.
    func testTheListIsInPairingOrder() {
        store.save(credential("b", hostId: Self.pcId, pairedAt: 1_700_000_500))
        store.save(credential("a", hostId: Self.macId, pairedAt: 1_700_000_000))
        XCTAssertEqual(store.all().map(\.hostId), [Self.macId, Self.pcId])
    }

    /// Re-pairing after a revoke is a normal thing to do, and it must not cost
    /// the user their other machines.
    func testRePairingOneMachineLeavesTheOthersAlone() {
        store.save(credential("mac-token", hostId: Self.macId))
        store.save(credential("pc-token", hostId: Self.pcId, pairedAt: 1_700_000_100))

        store.save(credential("mac-token-2", hostId: Self.macId))

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.load(Self.macId)?.token, "mac-token-2")
        XCTAssertEqual(store.load(Self.pcId)?.token, "pc-token")
    }

    func testForgettingOneMachineLeavesTheOthers() {
        store.save(credential("mac-token", hostId: Self.macId))
        store.save(credential("pc-token", hostId: Self.pcId, pairedAt: 1_700_000_100))

        store.remove(Self.macId)

        XCTAssertEqual(store.all().map(\.hostId), [Self.pcId])
        XCTAssertEqual(KeychainCredentialStore(service: store.serviceForTesting).all().count, 1)
    }

    /// Each machine keeps its own key. Two machines that could read each other's
    /// sessions would be the one thing multi-host is not allowed to cost.
    func testEachMachineKeepsItsOwnHostKey() {
        let mac = StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: Self.macId, hostKey: Data(repeating: 1, count: 32)),
            token: "a", kind: .device, deviceId: "d", deviceName: "iPhone", pairedAt: Date())
        let pc = StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: Self.pcId, hostKey: Data(repeating: 2, count: 32)),
            token: "b", kind: .device, deviceId: "d", deviceName: "iPhone", pairedAt: Date())
        store.save(mac)
        store.save(pc)

        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        guard case let .relay(_, _, macKey) = reloaded.load(Self.macId)?.endpoint,
              case let .relay(_, _, pcKey) = reloaded.load(Self.pcId)?.endpoint else {
            return XCTFail("both endpoints should have come back")
        }
        XCTAssertEqual(macKey, Data(repeating: 1, count: 32))
        XCTAssertEqual(pcKey, Data(repeating: 2, count: 32))
        XCTAssertNotEqual(macKey, pcKey)
    }

    func testANicknameSurvivesTheTrip() {
        store.save(credential("a", nickname: "Studio"))
        XCTAssertEqual(store.load(Self.macId)?.label, "Studio")
        // Without one, the label is the front of the host id — the half a person
        // is comparing against the code on screen.
        store.save(credential("b", hostId: Self.pcId))
        XCTAssertEqual(store.load(Self.pcId)?.label, "K3ZQW7")
    }

    /**
     * **The copilot credential is a second secret in the same item.**
     *
     * `COPILOT-REMOTE.md` §8 asks for it *beside* the pairing credential, with
     * the same protection class, and the same Keychain item is the strongest
     * reading of beside: one item cannot go missing while the other survives.
     * It is sent exactly once — the desktop keeps a scrypt hash — so a phone
     * that fails to store it has to show the Connect screen and ask for a **new**
     * code, which is the one outcome worth a test rather than an assumption.
     *
     * Read back through a second store over the same drawer, so this is a
     * Keychain round trip rather than a cache hit.
     */
    func testTheCopilotCredentialSurvivesBesideThePairingOne() {
        store.save(credential("token").withCopilotCredential("c2VjcmV0LWJ5dGVz"))

        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(reloaded.load(Self.macId)?.copilotCredential, "c2VjcmV0LWJ5dGVz")
        XCTAssertEqual(reloaded.load(Self.macId)?.token, "token", "and the pairing one is untouched")
    }

    /**
     * Disconnecting the copilot drops that secret and leaves the pairing alone.
     *
     * The two are revoked separately by design — disconnecting the copilot at
     * the desk leaves every terminal the device was paired for — so the record
     * has to survive losing one of them. A store that dropped the row, or that
     * kept a credential whose record on the far machine has gone, would be wrong
     * in the two opposite directions this separation exists to keep apart.
     */
    func testDroppingTheCopilotCredentialKeepsTheMachine() {
        store.save(credential("token").withCopilotCredential("c2VjcmV0"))
        store.save(credential("token").withCopilotCredential(nil))

        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertNil(reloaded.load(Self.macId)?.copilotCredential)
        XCTAssertEqual(reloaded.load(Self.macId)?.token, "token")
        XCTAssertEqual(reloaded.all().count, 1, "the machine is still paired")
    }

    /**
     * Re-pairing does **not** carry the copilot credential across.
     *
     * Redeeming produces a new device id, and the desktop's copilot record is
     * keyed by device id — so a secret kept through a re-pair is one this phone
     * believes in and nothing on that machine has ever heard of. That is the
     * worse of the two ways to be wrong: the Connect screen would not be drawn,
     * and every copilot frame would be refused with no explanation on either end.
     */
    func testRedeemingAPairingDoesNotCarryTheCopilotCredential() {
        let paired = credential("pairing-token").withCopilotCredential("c2VjcmV0")

        let durable = paired.redeemed(token: "device-token", deviceId: "device-2",
                                      deviceName: "iPhone")

        XCTAssertNil(durable.copilotCredential,
                     "a new device id is a new device, and its copilot record does not exist yet")
        XCTAssertEqual(durable.token, "device-token")
    }

    /**
     * A record written before this field existed still decodes.
     *
     * A `StoredCredential` that fails to decode is a machine that has vanished
     * from the phone, which is the failure this whole store is designed against
     * — so the field has to be optional *and* absent from the bytes when there
     * is nothing to write, which is what makes yesterday's record readable by
     * today's build.
     *
     * Built by encoding rather than hand-written, because a hand-written blob
     * would be pinning this test's idea of the format instead of the format.
     */
    func testARecordWithNoCopilotFieldStillDecodes() throws {
        let encoded = try JSONEncoder().encode(credential("t"))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("copilotCredential"),
                       "an absent second secret writes no key at all")

        let decoded = try JSONDecoder().decode(StoredCredential.self, from: encoded)
        XCTAssertNil(decoded.copilotCredential)
        XCTAssertEqual(decoded.token, "t")
    }

    // MARK: - Damage

    /**
     * One unreadable record costs one machine, and says so.
     *
     * The reason this store is one Keychain item per host rather than one item
     * holding a JSON array: a single blob has a single decode, so a record
     * written by a shape of the struct this build does not understand would read
     * as *no pairings at all*.
     */
    func testACorruptRecordCostsOneMachineAndIsCounted() {
        store.save(credential("mac-token", hostId: Self.macId))
        store.save(credential("pc-token", hostId: Self.pcId, pairedAt: 1_700_000_100))

        // Overwrite one item with something that is not a `StoredCredential`.
        let vandal = KeychainCredentialStore(service: store.serviceForTesting)
        vandal.corruptForTesting(hostId: Self.macId)

        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(reloaded.all().map(\.hostId), [Self.pcId])
        XCTAssertEqual(reloaded.unreadable, 1, "the app has to be able to say one pairing could not be read")
    }

    // MARK: - Migration

    /**
     * A phone paired before this build keeps its machine.
     *
     * The single-host record lived at its own account. Nothing about the
     * multi-host change is worth a user re-pairing, so it is folded into the
     * collection on first read and the old item is removed only after the new one
     * is written.
     */
    func testASingleHostRecordIsFoldedIn() {
        store.writeLegacyRecordForTesting(credential("legacy-token"))

        XCTAssertEqual(store.all().map(\.hostId), [Self.macId])
        XCTAssertEqual(store.load(Self.macId)?.token, "legacy-token")

        // And it stays folded in: a second store reads the new account.
        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(reloaded.load(Self.macId)?.token, "legacy-token")
        XCTAssertEqual(reloaded.all().count, 1, "the migration must not leave two copies")
    }

    /// The migration runs beside machines paired after it, without disturbing them.
    func testTheMigrationDoesNotDisturbNewerPairings() {
        store.save(credential("pc-token", hostId: Self.pcId, pairedAt: 1_700_000_100))
        store.writeLegacyRecordForTesting(credential("legacy-token", hostId: Self.macId))

        let reloaded = KeychainCredentialStore(service: store.serviceForTesting)
        XCTAssertEqual(Set(reloaded.all().map(\.hostId)), [Self.macId, Self.pcId])
    }

    // MARK: - The device identity

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
        guard case let .relay(url, hostId, hostKey) = store.load(Self.macId)?.endpoint else {
            return XCTFail("expected a relay endpoint")
        }
        XCTAssertEqual(url.absoluteString, "wss://relay.example")
        XCTAssertEqual(hostId, Self.macId)
        XCTAssertEqual(hostKey.count, 32)
    }

    /// A tailnet machine has no host id in its code, so its address stands in —
    /// and the scheme is deliberately not part of it, or one machine paired over
    /// `http` and `https` would be two rows in the switcher.
    func testADirectEndpointStillNamesOneMachine() {
        XCTAssertEqual(DeckEndpoint.direct(url: URL(string: "wss://mac.tailnet.ts.net/ws")!).hostId,
                       "direct:mac.tailnet.ts.net")
        XCTAssertEqual(DeckEndpoint.direct(url: URL(string: "ws://mac.tailnet.ts.net/ws")!).hostId,
                       "direct:mac.tailnet.ts.net")
        XCTAssertEqual(DeckEndpoint.direct(url: URL(string: "wss://mac.tailnet.ts.net:8443/ws")!).hostId,
                       "direct:mac.tailnet.ts.net:8443")
        // And it cannot collide with a relay host id, which has no colon in it.
        XCTAssertFalse(DeckEndpoint.relay(url: URL(string: "wss://r.example")!,
                                          hostId: Self.macId,
                                          hostKey: Data(count: 32)).hostId.contains(":"))
    }
}
