/**
 * The Swift sealed channel, checked against bytes the Node implementation
 * produced.
 *
 * A handshake that only talks to itself is worthless. Everything here is
 * asserted against `Tests/Fixtures/sealed-vectors.json`, which
 * `ios/Harness/run.sh vectors` generates by running `src/shared/sealed.ts`
 * itself — not a description of it, not a reimplementation of it.
 *
 * The four assertions that matter, in order of how quietly they fail:
 *
 *  1. Given the same static keys and the same ephemeral, `start` produces the
 *     identical handshake message — which pins the transcript hash, the HKDF
 *     argument order, and the AEAD's associated data all at once.
 *  2. `finish` accepts the Mac's real reply and derives the identical channel
 *     binding.
 *  3. Frames Node sealed open here, in order, to the right plaintext — which is
 *     the only test that pins the nonce layout and the k1/k2 direction.
 *  4. Frames sealed here are byte-identical to the ones Node sealed from the
 *     same plaintext under the same counter.
 *
 * Anything below those is a refusal: a tampered frame, a replayed frame, a
 * frame from the wrong direction.
 */

import CryptoKit
import XCTest
@testable import TerminalDeck

final class SealedChannelTests: XCTestCase {

    // MARK: - Fixtures

    private struct Vectors: Decodable {
        struct Pair: Decodable {
            let publicKey: String
            let privateKey: String
        }
        struct Frame: Decodable {
            let plaintext: String
            let frame: String
        }
        struct Session: Decodable {
            let label: String
            let mac: Pair
            let device: Pair
            let ephemeralPrivate: String
            let handshakeMessage: String
            let pendingChainingKey: String
            let pendingH: String
            let reply: String
            let channelBinding: String
            let devicePublicKey: String
            let initiatorToResponder: [Frame]
            let responderToInitiator: [Frame]
        }
        struct Fingerprint: Decodable {
            let publicKey: String
            let fingerprint: String
        }
        let noiseName: String
        let sealedVersion: Int
        let sessions: [Session]
        let fingerprints: [Fingerprint]
    }

    private static let vectors: Vectors = {
        guard let url = Bundle(for: SealedChannelTests.self)
            .url(forResource: "sealed-vectors", withExtension: "json") else {
            fatalError("sealed-vectors.json is not in the test bundle. "
                       + "Regenerate it with ios/Harness/run.sh vectors.")
        }
        // Force-tried on purpose: a malformed fixture is a broken checkout, not
        // a test failure to be reported per-case.
        return try! JSONDecoder().decode(Vectors.self, from: try! Data(contentsOf: url))
    }()

    private func hex(_ value: String) -> Data {
        var out = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            out.append(UInt8(value[index ..< next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The suite identity

    func testNamesTheSameSuiteAsTheDesktop() {
        // A mismatch here is a client that cannot negotiate down, it just fails
        // at the first decrypt — so it is worth failing at compile-test time.
        XCTAssertEqual(Sealed.noiseName, Self.vectors.noiseName)
        XCTAssertEqual(Sealed.version, Self.vectors.sealedVersion)
    }

    // MARK: - 1. The handshake message, byte for byte

    func testProducesTheSameHandshakeMessageAsNode() throws {
        for vector in Self.vectors.sessions {
            let device = try XCTUnwrap(StaticKeyPair(privateKey: hex(vector.device.privateKey)), vector.label)
            // The public halves are derived, never read from the fixture: a port
            // that derived them differently would otherwise be handed the right
            // answer.
            XCTAssertEqual(hex(device.publicKey), vector.device.publicKey, vector.label)

            let started = try startFrom(vector)
            XCTAssertEqual(hex(started.message), vector.handshakeMessage, vector.label)
            XCTAssertEqual(hex(started.pending.transcript.chainingKey), vector.pendingChainingKey, vector.label)
            XCTAssertEqual(hex(started.pending.transcript.h), vector.pendingH, vector.label)
        }
    }

    func testHidesTheDeviceIdentityOnTheWire() throws {
        let vector = Self.vectors.sessions[0]
        let message = hex(vector.handshakeMessage)
        let devicePublic = hex(vector.device.publicKey)
        // IK's whole point: the static key is encrypted, so the relay cannot
        // tell which device is connecting.
        XCTAssertFalse(message.range(of: devicePublic) != nil)
    }

    // MARK: - 2. The reply, and the keys that come out of it

    func testDerivesTheSameChannelBindingAsNode() throws {
        for vector in Self.vectors.sessions {
            let transport = try openSession(vector)
            XCTAssertEqual(hex(transport.channelBinding), vector.channelBinding, vector.label)
        }
    }

    func testRefusesAReplyOfTheWrongLength() throws {
        let vector = Self.vectors.sessions[0]
        let pending = try startFrom(vector).pending
        let reply = hex(vector.reply)
        XCTAssertThrowsError(try SealedHandshake.finish(pending: pending, reply: reply.prefix(40))) {
            XCTAssertEqual($0 as? SealedError, .length)
        }
    }

    func testRefusesAForgedReply() throws {
        let vector = Self.vectors.sessions[0]
        var reply = hex(vector.reply)
        reply[reply.count - 1] ^= 0x01
        let pending = try startFrom(vector).pending
        XCTAssertThrowsError(try SealedHandshake.finish(pending: pending, reply: reply)) {
            XCTAssertEqual($0 as? SealedError, .authentication)
        }
    }

    func testRefusesAReplyWithASwappedEphemeral() throws {
        // The relay's one available attack: substitute its own ephemeral and try
        // to sit in the middle. It fails on the confirmation tag.
        let vector = Self.vectors.sessions[0]
        let other = StaticKeyPair.generate()
        let reply = other.publicKey + hex(vector.reply).suffix(Sealed.tagBytes)
        let pending = try startFrom(vector).pending
        XCTAssertThrowsError(try SealedHandshake.finish(pending: pending, reply: reply))
    }

    // MARK: - 3. Opening what Node sealed

    func testOpensEveryFrameNodeSealed() throws {
        for vector in Self.vectors.sessions {
            let transport = try openSession(vector)
            // Node interleaved the two directions; the receive counter must not
            // be affected by what this side sent, so they are replayed apart.
            for (index, frame) in vector.responderToInitiator.enumerated() {
                let plaintext = try transport.receive(hex(frame.frame))
                XCTAssertEqual(hex(plaintext), frame.plaintext, "\(vector.label) frame \(index)")
            }
        }
    }

    func testSealsFramesByteIdenticalToNode() throws {
        for vector in Self.vectors.sessions {
            let transport = try openSession(vector)
            for (index, frame) in vector.initiatorToResponder.enumerated() {
                let sealed = try transport.send(hex(frame.plaintext))
                XCTAssertEqual(hex(sealed), frame.frame, "\(vector.label) frame \(index)")
            }
        }
    }

    func testCarriesAnEmptyPayloadAndALargeOne() throws {
        // Both are in the fixture; this asserts the shapes rather than trusting
        // the loop above to have covered them.
        let vector = Self.vectors.sessions[0]
        let sizes = vector.initiatorToResponder.map { $0.plaintext.count / 2 }
        XCTAssertTrue(sizes.contains(0))
        XCTAssertTrue(sizes.contains { $0 > 64 * 1024 })
    }

    func testAddsOnlyTheTagToThePayloadSize() throws {
        let transport = try openSession(Self.vectors.sessions[0])
        XCTAssertEqual(try transport.send(Data(repeating: 0, count: 100)).count, 116)
    }

    // MARK: - 4. Refusals on the live channel

    func testRefusesAReplayedFrame() throws {
        let vector = Self.vectors.sessions[0]
        let transport = try openSession(vector)
        let frame = hex(vector.responderToInitiator[0].frame)
        XCTAssertNoThrow(try transport.receive(frame))
        XCTAssertThrowsError(try transport.receive(frame)) {
            XCTAssertEqual($0 as? SealedError, .authentication)
        }
    }

    func testRefusesAReorderedFrameWithoutLosingItsPlace() throws {
        let vector = Self.vectors.sessions[0]
        let transport = try openSession(vector)
        let frames = vector.responderToInitiator.map { hex($0.frame) }
        XCTAssertThrowsError(try transport.receive(frames[1]))
        // The counter did not advance on the failure, so the honest next frame
        // still opens. A forged frame must not desynchronise a real connection.
        XCTAssertNoThrow(try transport.receive(frames[0]))
        XCTAssertNoThrow(try transport.receive(frames[1]))
    }

    func testRefusesEveryFlippedBit() throws {
        let vector = Self.vectors.sessions[1]
        let frame = hex(vector.responderToInitiator[0].frame)
        for index in 0 ..< frame.count {
            let transport = try openSession(vector)
            var bent = frame
            bent[index] ^= 0x80
            XCTAssertThrowsError(try transport.receive(bent), "byte \(index)")
        }
    }

    func testRefusesTheOtherDirectionsTraffic() throws {
        let vector = Self.vectors.sessions[0]
        let transport = try openSession(vector)
        // Keys are directional. Our own frame must be opaque to us.
        let ours = try transport.send(Data("secret".utf8))
        XCTAssertThrowsError(try transport.receive(ours))
    }

    func testRefusesATruncatedFrame() throws {
        let vector = Self.vectors.sessions[0]
        let transport = try openSession(vector)
        let frame = hex(vector.responderToInitiator[0].frame)
        XCTAssertThrowsError(try transport.receive(frame.prefix(frame.count - 1)))
        XCTAssertThrowsError(try transport.receive(Data()))
    }

    // MARK: - Keys and fingerprints

    func testDerivesPublicKeysTheSameWayNodeDoes() {
        for vector in Self.vectors.sessions {
            let mac = StaticKeyPair(privateKey: hex(vector.mac.privateKey))
            XCTAssertEqual(hex(mac!.publicKey), vector.mac.publicKey, vector.label)
        }
    }

    func testRefusesAPrivateKeyOfTheWrongLength() {
        XCTAssertNil(StaticKeyPair(privateKey: Data(repeating: 7, count: 31)))
        XCTAssertNil(StaticKeyPair(privateKey: Data()))
    }

    func testGeneratesFreshKeysEveryTime() {
        let keys = Set((0 ..< 25).map { _ in StaticKeyPair.generate().publicKey })
        XCTAssertEqual(keys.count, 25)
    }

    func testFingerprintsMatchTheDesktopExactly() {
        // The point of the fingerprint is that a person reads the same six
        // groups off two screens. One character of drift makes it worse than
        // useless, because it teaches people to ignore a mismatch.
        for vector in Self.vectors.fingerprints {
            XCTAssertEqual(sealedFingerprint(hex(vector.publicKey)), vector.fingerprint)
        }
    }

    func testFingerprintsCarryNoAmbiguousCharacters() {
        for _ in 0 ..< 20 {
            let value = sealedFingerprint(StaticKeyPair.generate().publicKey)
            XCTAssertNil(value.rangeOfCharacter(from: CharacterSet(charactersIn: "01OI")))
            XCTAssertEqual(value.filter { $0 != "-" }.count, 24)
        }
    }

    // MARK: - A handshake against a fresh key, end to end

    func testAFreshEphemeralStillProducesAWorkingHandshake() throws {
        // Everything above replays a recorded ephemeral. This one uses a real
        // random one and proves only that the message is well-formed — the
        // reply cannot be checked without a responder, which this app is not.
        let device = StaticKeyPair.generate()
        let mac = StaticKeyPair.generate()
        let started = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: mac.publicKey)
        XCTAssertEqual(started.message.count, Sealed.noiseMessageBytes)

        let again = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: mac.publicKey)
        // Forward secrecy in observable form: same identities, different session.
        XCTAssertNotEqual(started.message, again.message)
    }

    func testRefusesAResponderKeyOfTheWrongLength() {
        let device = StaticKeyPair.generate()
        XCTAssertThrowsError(try SealedHandshake.start(deviceStatic: device,
                                                       responderStaticPublic: Data(repeating: 1, count: 31))) {
            XCTAssertEqual($0 as? SealedError, .length)
        }
    }

    func testRefusesAnAllZeroResponderKey() {
        // A low-order point: the shared secret comes out zero, which would be a
        // key the attacker also knows.
        let device = StaticKeyPair.generate()
        XCTAssertThrowsError(try SealedHandshake.start(deviceStatic: device,
                                                       responderStaticPublic: Data(repeating: 0, count: 32)))
    }

    // MARK: - Helpers

    private func startFrom(_ vector: Vectors.Session) throws -> (message: Data, pending: PendingHandshake) {
        let device = try XCTUnwrap(StaticKeyPair(privateKey: hex(vector.device.privateKey)))
        let ephemeral = try XCTUnwrap(StaticKeyPair(privateKey: hex(vector.ephemeralPrivate)))
        return try SealedHandshake.start(deviceStatic: device,
                                         responderStaticPublic: hex(vector.mac.publicKey),
                                         ephemeral: ephemeral)
    }

    private func openSession(_ vector: Vectors.Session) throws -> SealedTransport {
        try SealedHandshake.finish(pending: try startFrom(vector).pending, reply: hex(vector.reply))
    }
}
