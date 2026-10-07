import XCTest
import Foundation
@testable import TerminalDeckBackend

/// src/shared/sealed.test.ts. Fixed raw private keys replace incidental entropy
/// in attack cases; the real CryptoKit/Noise implementation remains under test.
@MainActor
final class BackendFoundationTestsBSealed: XCTestCase {
    private func key(_ byte: UInt8) throws -> StaticKeyPair { try XCTUnwrap(StaticKeyPair(privateKey: Data(repeating: byte, count: 32))) }
    private struct Pair { let mac: StaticKeyPair, device: StaticKeyPair; let client: SealedTransport; let server: BackendSealedTransport; let message: Data, reply: Data, peer: Data }
    private func connect(deviceByte: UInt8 = 0x22, ephemeralByte: UInt8 = 0x33, serverEphemeralByte: UInt8 = 0x44) throws -> Pair {
        let mac = try key(0x11), device = try key(deviceByte)
        let start = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: mac.publicKey, ephemeral: key(ephemeralByte))
        let response = try BackendSealedHost.respond(identity: BackendSealedIdentity(privateKey: mac.privateKey), message: start.message, approvedKeys: [device.publicKey], fixtureEphemeral: Data(repeating: serverEphemeralByte, count: 32))
        return Pair(mac: mac, device: device, client: try SealedHandshake.finish(pending: start.pending, reply: response.reply), server: response.transport, message: start.message, reply: response.reply, peer: response.devicePublicKey)
    }
    private func authentication(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected authentication refusal") } catch { XCTAssertEqual(String(describing: error), "authentication") }
    }
    func testRaw32ByteKeysAndGenerationDoesNotRepeat() {
        let keys = (0..<50).map { _ in StaticKeyPair.generate() }
        XCTAssertTrue(keys.allSatisfy { $0.privateKey.count == 32 && $0.publicKey.count == 32 })
        XCTAssertEqual(Set(keys.map(\.publicKey)).count, 50)
    }
    func testBothDirectionsAuthenticatedPeerAnd32ByteBinding() async throws {
        let pair = try connect(), command = Data("ls -la".utf8), output = Data("total 0\r\n".utf8)
        let opened = try await pair.server.receive(pair.client.send(command)); XCTAssertEqual(opened, command)
        let response = try await pair.server.send(output); XCTAssertEqual(try pair.client.receive(response), output)
        XCTAssertEqual(pair.peer, pair.device.publicKey); XCTAssertEqual(pair.client.channelBinding, pair.server.channelBinding); XCTAssertEqual(pair.client.channelBinding.count, 32)
    }
    func testIdentityHiddenAndNewConnectionGetsDifferentKeys() throws {
        let one = try connect(), two = try connect(ephemeralByte: 0x55, serverEphemeralByte: 0x66)
        XCTAssertNil(one.message.range(of: one.device.publicKey))
        XCTAssertNotEqual(one.client.channelBinding, two.client.channelBinding)
    }
    func testUnknownPeerWrongHostAndAuthenticatedStaticCannotBeSubstituted() throws {
        let mac = try key(0x11), device = try key(0x22), stranger = try key(0x55), host = try BackendSealedIdentity(privateKey: mac.privateKey)
        let foreign = try SealedHandshake.start(deviceStatic: stranger, responderStaticPublic: mac.publicKey, ephemeral: key(0x33))
        XCTAssertThrowsError(try BackendSealedHost.respond(identity: host, message: foreign.message, approvedKeys: [device.publicKey])) { XCTAssertEqual(String(describing: $0), "authentication") }
        let admitted = try BackendSealedHost.respond(identity: host, message: foreign.message, approvedKeys: [], permitUnknownPeer: true, fixtureEphemeral: Data(repeating: 0x44, count: 32))
        XCTAssertEqual(admitted.devicePublicKey, stranger.publicKey); XCTAssertNotEqual(admitted.devicePublicKey, device.publicKey)
        let intended = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: mac.publicKey, ephemeral: key(0x33))
        XCTAssertThrowsError(try BackendSealedHost.respond(identity: BackendSealedIdentity(privateKey: stranger.privateKey), message: intended.message, approvedKeys: [device.publicKey])) { XCTAssertEqual(String(describing: $0), "authentication") }
    }
    func testEverySpecifiedHandshakeTamperPositionRefusedAndLengthsExact() throws {
        let pair = try connect(), identity = try BackendSealedIdentity(privateKey: pair.mac.privateKey)
        for index in [0, 31, 32, pair.message.count - 1] {
            var bent = pair.message; bent[index] ^= 1
            XCTAssertThrowsError(try BackendSealedHost.respond(identity: identity, message: bent, approvedKeys: [pair.device.publicKey]))
        }
        for bad in [Data(pair.message.prefix(60)), pair.message + Data([0])] {
            XCTAssertThrowsError(try BackendSealedHost.respond(identity: identity, message: bad, approvedKeys: [pair.device.publicKey])) { XCTAssertEqual(String(describing: $0), "length") }
        }
        var zeroed = pair.message; zeroed.replaceSubrange(0..<32, with: Data(count: 32))
        XCTAssertThrowsError(try BackendSealedHost.respond(identity: identity, message: zeroed, approvedKeys: [pair.device.publicKey])) { XCTAssertEqual(String(describing: $0), "authentication") }
    }
    func testForgedReplyAndReplyWrongLengthRefused() throws {
        let mac = try key(0x11), device = try key(0x22)
        let start = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: mac.publicKey, ephemeral: key(0x33))
        let answered = try BackendSealedHost.respond(identity: BackendSealedIdentity(privateKey: mac.privateKey), message: start.message, approvedKeys: [device.publicKey], fixtureEphemeral: Data(repeating: 0x44, count: 32))
        var bent = answered.reply; bent[bent.count - 1] ^= 1
        XCTAssertThrowsError(try SealedHandshake.finish(pending: start.pending, reply: bent)) { XCTAssertEqual($0 as? SealedError, .authentication) }
        let impostor = try key(0x55), forgedStart = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: impostor.publicKey, ephemeral: key(0x66))
        let forgedReply = try BackendSealedHost.respond(identity: BackendSealedIdentity(privateKey: impostor.privateKey), message: forgedStart.message, approvedKeys: [device.publicKey], fixtureEphemeral: Data(repeating: 0x77, count: 32))
        XCTAssertThrowsError(try SealedHandshake.finish(pending: start.pending, reply: forgedReply.reply)) { XCTAssertEqual($0 as? SealedError, .authentication) }
        for bad in [Data(answered.reply.prefix(40)), answered.reply + Data([0])] { XCTAssertThrowsError(try SealedHandshake.finish(pending: start.pending, reply: bad)) { XCTAssertEqual($0 as? SealedError, .length) } }
    }
    func testKeeps200MessageOrderAndSamePlaintextChangesCiphertext() async throws {
        let pair = try connect()
        for index in 0..<200 { let text = Data("line \(index)".utf8); let received = try await pair.server.receive(pair.client.send(text)); XCTAssertEqual(received, text) }
        XCTAssertNotEqual(try pair.client.send(Data("same".utf8)), try pair.client.send(Data("same".utf8)))
    }
    func testReplayAndReorderRefusedWithoutAdvancingReceiveCounter() async throws {
        let pair = try connect(), first = try pair.client.send(Data("one".utf8)), second = try pair.client.send(Data("two".utf8))
        await authentication { _ = try await pair.server.receive(second) }
        let one = try await pair.server.receive(first), two = try await pair.server.receive(second)
        XCTAssertEqual(one, Data("one".utf8)); XCTAssertEqual(two, Data("two".utf8))
        await authentication { _ = try await pair.server.receive(first) }
    }
    func testEveryFrameByteTamperTruncationAndWrongDirectionRefused() async throws {
        let pair = try connect(), frame = try pair.client.send(Data("rm -rf /".utf8))
        for index in frame.indices { var bent = frame; bent[index] ^= 0x80; await authentication { _ = try await pair.server.receive(bent) } }
        await authentication { _ = try await pair.server.receive(Data(frame.dropLast())) }
        await authentication { _ = try await pair.server.receive(Data()) }
        XCTAssertThrowsError(try pair.client.receive(frame)) { XCTAssertEqual($0 as? SealedError, .authentication) }
        let correct = try await pair.server.receive(frame); XCTAssertEqual(correct, Data("rm -rf /".utf8))
    }
    func testBinary64KiBEmptyPayloadAndOnly16ByteTagOverhead() async throws {
        let pair = try connect(), big = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let received = try await pair.server.receive(pair.client.send(big)); XCTAssertEqual(received, big)
        let empty = try await pair.server.receive(pair.client.send(Data())); XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try pair.client.send(Data(count: 100)).count, 116)
    }
    func testFingerprintStableDifferentAcrossKeysAndExactSuite() throws {
        let a = try key(0x11), b = try key(0x22), fingerprint = sealedFingerprint(a.publicKey)
        XCTAssertEqual(fingerprint, sealedFingerprint(a.publicKey)); XCTAssertNotEqual(fingerprint, sealedFingerprint(b.publicKey))
        XCTAssertNotNil(fingerprint.range(of: "^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4})*$", options: .regularExpression))
        XCTAssertNil(fingerprint.range(of: "[01OI]", options: .regularExpression))
        XCTAssertEqual(Sealed.noiseName, "Noise_IK_25519_ChaChaPoly_SHA256"); XCTAssertEqual(Sealed.version, 1)
    }
}
