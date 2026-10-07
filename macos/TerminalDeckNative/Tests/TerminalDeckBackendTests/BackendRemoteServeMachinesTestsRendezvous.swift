import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsRendezvous: XCTestCase {
    func testSaltMatchesOtherClientsExactly() {
        XCTAssertEqual(Rendezvous.salt, "terminaldeck-machine-pairing-v1")
        XCTAssertEqual(Rendezvous.scryptN, 16384); XCTAssertEqual(Rendezvous.scryptR, 8); XCTAssertEqual(Rendezvous.scryptP, 1)
        XCTAssertEqual(Rendezvous.seedBytes, 64)
    }
    func testAllCrossClientSlotAndResponderKeyVectors() async throws {
        let vectors = [
            ("482913", "PNN7FEFPVPEPG8J6JD5LTK22CW", "PluJUUCYOIi9dWOnMK0Sq8NrO635DqyD0yTLIyeLlAU="),
            ("000000", "ESVP7D6GDHN28MLNU5AEGRGGC7", "AFF3srTJviOR9zEbStt+iPZuTjl1Gp595oLklTIfLgc="),
            ("999999", "UAFTGU2WS5MN5GYUKF48KJG5SK", "bleS0Mpc5kqiW5FJ7wNs6uardUbhJgcrjUN583t7Zx4=")]
        for (code, slot, key) in vectors {
            let identity = try await BackendRendezvous.derive(code)
            XCTAssertEqual(identity.hostID, slot); XCTAssertEqual(identity.keys.publicKey.base64EncodedString(), key)
        }
    }
    func testSameCodeHasSameSlotAndBothKeyHalves() async throws {
        let first = try await BackendRendezvous.derive("482913"), second = try await BackendRendezvous.derive("482913")
        XCTAssertEqual(first.hostID, second.hostID); XCTAssertEqual(first.keys.privateKey, second.keys.privateKey); XCTAssertEqual(first.keys.publicKey, second.keys.publicKey)
    }
    func testTypedCodeSeparatorsDoNotChangeDerivation() async throws {
        let canonical = try await BackendRendezvous.derive("482913")
        for spelling in ["482-913", "  482 913  "] {
            let identity = try await BackendRendezvous.derive(spelling)
            XCTAssertEqual(identity.hostID, canonical.hostID); XCTAssertEqual(identity.keys.publicKey, canonical.keys.publicKey)
        }
    }
    func testDifferentCodesHaveDifferentSlots() async throws {
        let first = try await BackendRendezvous.derive("482913"), second = try await BackendRendezvous.derive("482914")
        XCTAssertNotEqual(first.hostID, second.hostID)
    }
    func testDerivedSlotAndIdentityHaveRelayShapes() async throws {
        let identity = try await BackendRendezvous.derive("999999")
        XCTAssertTrue(BackendRelayPacketCodec.isHostID(identity.hostID))
        XCTAssertEqual(identity.keys.privateKey.count, 32); XCTAssertEqual(identity.keys.publicKey.count, 32)
        XCTAssertNotNil(identity.keys.fingerprint.range(of: #"^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$"#, options: .regularExpression))
        let seed = try BackendPairingDerivation.scrypt(password: Data("999999".utf8), salt: Data(Rendezvous.salt.utf8),
            n: Rendezvous.scryptN, r: Rendezvous.scryptR, p: Rendezvous.scryptP, length: Rendezvous.seedBytes)
        let hostSecret = Data(seed.prefix(32))
        XCTAssertEqual(hostSecret.count, 32); XCTAssertEqual(BackendRelayPacketCodec.hostID(for: hostSecret), identity.hostID)
        // Native's public result exposes slot/key, not a hostSecret field; the
        // real shared derivation above pins the same 32-byte split directly.
    }
    func testNonCodesRefusedBeforeExpensiveDerivation() async {
        for spelling in ["nope", "", "48291", "4829131", "H4K9-2FQT"] {
            XCTAssertNil(BackendRendezvous.normalize(spelling))
            let identity = await Rendezvous.identity(for: spelling); XCTAssertNil(identity)
        }
    }
    func testWrongCodeCannotAuthenticateResponder() async throws {
        let right = try await BackendRendezvous.derive("482913"), wrong = try await BackendRendezvous.derive("482914")
        let guest = StaticKeyPair.generate()
        let opening = try SealedHandshake.start(deviceStatic: guest, responderStaticPublic: right.keys.publicKey)
        XCTAssertNoThrow(try BackendSealedHost.respond(identity: right.keys, message: opening.message, approvedKeys: [], permitUnknownPeer: true))
        XCTAssertThrowsError(try BackendSealedHost.respond(identity: wrong.keys, message: opening.message, approvedKeys: [], permitUnknownPeer: true))
    }
    private func offer(_ patch: NativeRPCValue = .object([])) -> String {
        NativeRPCValue.object([.init("t", .string("machine")), .init("relayUrl", .string("wss://relay.example.invalid")),
            .init("hostId", .string(BackendRelayPacketCodec.hostID(for: Data(repeating: 5, count: 32)))),
            .init("publicKey", .string(Data(repeating: 251, count: 32).base64EncodedString())), .init("name", .string("Studio PC")),
            .init("platform", .string("darwin"))]).merging(patch).compact
    }
    func testOfferRejectsUndialableRelayHostAndKey() {
        for patch in [NativeRPCValue.object([.init("hostId", .string("too-short"))]),
                      .object([.init("relayUrl", .string("https://relay.example.invalid"))]),
                      .object([.init("publicKey", .string("not-a-key"))])] {
            XCTAssertNil(Rendezvous.parseOffer(offer(patch)))
        }
    }
    func testOfferRejectsNonJSONWrongTagNonObjectAndOversizedBody() {
        for raw in ["not json", "{\"t\":\"welcome\"}", "[1,2,3]", "42", String(repeating: "x", count: 5000)] { XCTAssertNil(Rendezvous.parseOffer(raw)) }
    }
    func testSupplementalOfferParserAcceptsStandardBase64Key() throws {
        let parsed = try XCTUnwrap(Rendezvous.parseOffer(offer()))
        XCTAssertEqual(parsed.hostKey, Data(repeating: 251, count: 32)); XCTAssertEqual(parsed.relayURL.absoluteString, "wss://relay.example.invalid")
        // This is supplemental coverage, not the TS full offer round-trip:
        // the generated native MachineOffer omits the source name/platform.
    }
}
