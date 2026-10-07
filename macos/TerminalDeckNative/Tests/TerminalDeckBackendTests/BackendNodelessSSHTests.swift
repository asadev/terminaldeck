import Foundation
import CryptoKit
import Security
import Darwin
import XCTest
@testable import TerminalDeckBackend

/// N18: the native authenticate-only loopback SSH check (ssh-verify.ts parity).
final class BackendNodelessSSHTests: XCTestCase {
    private func openSSHKey(type: String, publicBlob: [UInt8], cipher: String = "none",
                            fields: (inout BackendNodelessSSHWriter) -> Void) -> String {
        var inner = BackendNodelessSSHWriter()
        inner.uint32(0x0102_0304); inner.uint32(0x0102_0304); inner.string(type); fields(&inner); inner.string("test key")
        var padded = inner.bytes, next: UInt8 = 1
        while padded.count % 8 != 0 { padded.append(next); next += 1 }
        let options: [UInt8] = cipher == "none" ? [] : [0, 0, 0, 16]
        var outer = BackendNodelessSSHWriter()
        outer.raw(Array("openssh-key-v1\u{0}".utf8)); outer.string(cipher); outer.string(cipher == "none" ? "none" : "bcrypt")
        outer.string(options); outer.uint32(1); outer.string(publicBlob); outer.string(padded)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + Data(outer.bytes).base64EncodedString(options: .lineLength64Characters)
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
    private func ed25519() -> (key: Curve25519.Signing.PrivateKey, blob: [UInt8], text: String) {
        let key = Curve25519.Signing.PrivateKey(), pub = Array(key.publicKey.rawRepresentation)
        var blob = BackendNodelessSSHWriter(); blob.string("ssh-ed25519"); blob.string(pub)
        let text = openSSHKey(type: "ssh-ed25519", publicBlob: blob.bytes) { writer in
            writer.string(pub); writer.string(Array(key.rawRepresentation) + pub)
        }
        return (key, blob.bytes, text)
    }
    private func bigEndian(_ value: UInt64) -> [UInt8] {
        Array(withUnsafeBytes(of: value.bigEndian) { Array($0) }.drop(while: { $0 == 0 }))
    }
    private func closedLoopbackPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    func testWireTypesRoundTripWithMinimalMpints() throws {
        var writer = BackendNodelessSSHWriter()
        writer.byte(7); writer.bool(true); writer.uint32(0xdead_beef); writer.string("ssh-userauth")
        writer.nameList(["a", "b"]); writer.mpint([0x00, 0x00, 0x80, 0x01]); writer.mpint([0x00]); writer.mpint([0x7f])
        XCTAssertEqual(BackendNodelessSSHWriter.mpintBody([0x00, 0x80]), [0x00, 0x80])
        XCTAssertEqual(BackendNodelessSSHWriter.mpintBody([0x00, 0x00, 0x01]), [0x01])
        var reader = BackendNodelessSSHReader(writer.bytes)
        XCTAssertEqual(try reader.byte(), 7); XCTAssertTrue(try reader.bool()); XCTAssertEqual(try reader.uint32(), 0xdead_beef)
        XCTAssertEqual(try reader.text(), "ssh-userauth"); XCTAssertEqual(try reader.nameList(), ["a", "b"])
        XCTAssertEqual(try reader.mpint(), [0x80, 0x01]); XCTAssertEqual(try reader.mpint(), []); XCTAssertEqual(try reader.mpint(), [0x7f])
        XCTAssertEqual(reader.remaining, 0)
        XCTAssertThrowsError(try reader.byte())
        var negative = BackendNodelessSSHReader([0, 0, 0, 1, 0x80])
        XCTAssertThrowsError(try negative.mpint())
        var oversized = BackendNodelessSSHReader([0xff, 0xff, 0xff, 0xff, 1])
        XCTAssertThrowsError(try oversized.string())
    }

    func testBigRemainderMatchesMachineArithmetic() {
        XCTAssertEqual(BackendNodelessSSHBigMod.modMinusOne([0x01, 0x00, 0x01], [0x0d]), [0x05])
        XCTAssertEqual(BackendNodelessSSHBigMod.modMinusOne([0x0c], [0x0d]), [])
        for _ in 0..<300 {
            let value = UInt64.random(in: 0...UInt64.max), modulus = UInt64.random(in: 2...UInt64.max)
            XCTAssertEqual(BackendNodelessSSHBigMod.modMinusOne(bigEndian(value), bigEndian(modulus)), bigEndian(value % (modulus - 1)))
        }
    }

    func testOpenSSHEd25519KeySignsAndHostKeyCheckBindsTheHash() throws {
        let (key, blob, text) = ed25519()
        let parsed = try BackendNodelessSSHPrivateKey.parse(text)
        XCTAssertEqual(parsed.publicBlob, blob); XCTAssertEqual(parsed.algorithms, ["ssh-ed25519"])
        let message = Array("exchange hash".utf8)
        let signature = try parsed.sign(message, algorithm: "ssh-ed25519")
        var reader = BackendNodelessSSHReader(signature)
        XCTAssertEqual(try reader.text(), "ssh-ed25519")
        XCTAssertTrue(key.publicKey.isValidSignature(try reader.string(), for: message))
        try BackendNodelessSSHHostKey.verify(blob: blob, signature: signature, hash: message, algorithm: "ssh-ed25519")
        XCTAssertThrowsError(try BackendNodelessSSHHostKey.verify(blob: blob, signature: signature, hash: Array("other hash".utf8), algorithm: "ssh-ed25519"))
        XCTAssertThrowsError(try BackendNodelessSSHHostKey.verify(blob: blob, signature: signature, hash: message, algorithm: "rsa-sha2-512"))
    }

    func testRSAKeysFromPKCS1AndOpenSSHSignWithBothSHA2Algorithms() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        let secret = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(secret))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(secret, &error) as Data?)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + pkcs1.base64EncodedString(options: .lineLength64Characters) + "\n-----END RSA PRIVATE KEY-----\n"
        var der = BackendNodelessSSHDER(Array(pkcs1)); var fields = BackendNodelessSSHDER(try der.expect(0x30))
        _ = try fields.integer()
        let n = try fields.integer(), e = try fields.integer(), d = try fields.integer(), p = try fields.integer(), q = try fields.integer()
        _ = try fields.integer(); _ = try fields.integer()
        let qinv = try fields.integer()
        var blob = BackendNodelessSSHWriter(); blob.string("ssh-rsa"); blob.mpint(e); blob.mpint(n)
        // OpenSSH stores no CRT exponents: the parser derives d mod (p-1), d mod (q-1).
        let openSSH = openSSHKey(type: "ssh-rsa", publicBlob: blob.bytes) { writer in
            writer.mpint(n); writer.mpint(e); writer.mpint(d); writer.mpint(qinv); writer.mpint(p); writer.mpint(q)
        }
        let message = Array("sign me".utf8)
        for text in [pem, openSSH] {
            let parsed = try BackendNodelessSSHPrivateKey.parse(text)
            XCTAssertEqual(parsed.publicBlob, blob.bytes); XCTAssertEqual(parsed.algorithms, ["rsa-sha2-512", "rsa-sha2-256"])
            for (algorithm, method) in [("rsa-sha2-512", SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA512), ("rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256)] {
                let signature = try parsed.sign(message, algorithm: algorithm)
                var reader = BackendNodelessSSHReader(signature)
                XCTAssertEqual(try reader.text(), algorithm)
                let raw = try reader.string()
                XCTAssertTrue(SecKeyVerifySignature(publicKey, method, Data(message) as CFData, Data(raw) as CFData, &error))
                try BackendNodelessSSHHostKey.verify(blob: blob.bytes, signature: signature, hash: message, algorithm: algorithm)
            }
        }
    }

    func testPKCS8ECDSAAndEd25519KeysParse() throws {
        let p256 = P256.Signing.PrivateKey()
        let parsed = try BackendNodelessSSHPrivateKey.parse(p256.pemRepresentation)
        XCTAssertEqual(parsed.algorithms, ["ecdsa-sha2-nistp256"])
        var blob = BackendNodelessSSHWriter(); blob.string("ecdsa-sha2-nistp256"); blob.string("nistp256"); blob.string(Array(p256.publicKey.x963Representation))
        XCTAssertEqual(parsed.publicBlob, blob.bytes)
        let message = Array("ecdsa".utf8)
        var reader = BackendNodelessSSHReader(try parsed.sign(message, algorithm: "ecdsa-sha2-nistp256"))
        XCTAssertEqual(try reader.text(), "ecdsa-sha2-nistp256")
        var pair = BackendNodelessSSHReader(try reader.string())
        let r = try pair.mpint(), s = try pair.mpint()
        let raw = [UInt8](repeating: 0, count: 32 - r.count) + r + [UInt8](repeating: 0, count: 32 - s.count) + s
        XCTAssertTrue(p256.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: message))

        let seed = Curve25519.Signing.PrivateKey()
        let pkcs8 = BackendNodelessSSHDER.sequence([BackendNodelessSSHDER.integer([0]),
            BackendNodelessSSHDER.sequence([BackendNodelessSSHDER.tlv(0x06, [0x2b, 0x65, 0x70])]),
            BackendNodelessSSHDER.tlv(0x04, BackendNodelessSSHDER.tlv(0x04, Array(seed.rawRepresentation)))])
        let edText = "-----BEGIN PRIVATE KEY-----\n" + Data(pkcs8).base64EncodedString() + "\n-----END PRIVATE KEY-----"
        let ed = try BackendNodelessSSHPrivateKey.parse(edText)
        var edBlob = BackendNodelessSSHWriter(); edBlob.string("ssh-ed25519"); edBlob.string(Array(seed.publicKey.rawRepresentation))
        XCTAssertEqual(ed.publicBlob, edBlob.bytes)
    }

    func testEncryptedUnsupportedAndGarbageKeysClassifyAsBadKey() {
        let (key, blob, _) = ed25519()
        let encrypted = openSSHKey(type: "ssh-ed25519", publicBlob: blob, cipher: "aes256-ctr") { writer in
            writer.string(Array(key.publicKey.rawRepresentation)); writer.string([UInt8](repeating: 1, count: 64))
        }
        let samples = [encrypted,
                       "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----",
                       "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----",
                       "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----",
                       "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----",
                       "correct horse battery staple"]
        for sample in samples {
            XCTAssertThrowsError(try BackendNodelessSSHPrivateKey.parse(sample)) { error in
                let signal = error as? BackendRemoteServeSSHSignal
                XCTAssertNotNil(signal)
                XCTAssertEqual(signal.map(BackendRemoteServeSSHVerifier.classify), .badKey)
            }
        }
    }

    func testGCMPacketsUseClearLengthAsAADAndCountTheNonce() throws {
        var packets = BackendNodelessSSHPackets()
        let plain = try packets.seal([20, 1, 2])
        XCTAssertEqual(plain.count % 8, 0, "pre-NEWKEYS packets align to 8 including the length")
        let key = [UInt8](repeating: 7, count: 16), iv = (0..<12).map { UInt8($0) }
        packets.outgoing = .init(key: key, iv: iv)
        let first = try packets.seal(Array("payload".utf8)), second = try packets.seal([1, 2, 3])
        for (packet, nonce, payload) in [(first, iv, Array("payload".utf8)), (second, Array(iv.prefix(11)) + [12], [UInt8]([1, 2, 3]))] {
            let length = Int(packet[0]) << 24 | Int(packet[1]) << 16 | Int(packet[2]) << 8 | Int(packet[3])
            XCTAssertEqual(length % 16, 0); XCTAssertEqual(packet.count, 4 + length + 16)
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: Array(nonce)), ciphertext: Data(packet[4..<(4 + length)]), tag: Data(packet.suffix(16)))
            let body = Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(packet.prefix(4))))
            let padding = Int(body[0])
            XCTAssertGreaterThanOrEqual(padding, 4)
            XCTAssertEqual(Array(body[1..<(body.count - padding)]), payload)
        }
    }

    func testNothingListeningIsNoSSHDAndAnUnreadableKeyIsBadKeyBeforeDialling() async throws {
        let verifier = BackendRemoteServeSSHVerifier(transport: BackendNodelessSSHAuthTransport())
        let port = closedLoopbackPort()
        let password = try await verifier.verify(username: "nobody", secret: "x", method: "password", port: port, timeoutMilliseconds: 3000)
        XCTAssertEqual(password, .noSSHD)
        let goodKey = try await verifier.verify(username: "nobody", secret: ed25519().text, method: "key", port: port, timeoutMilliseconds: 3000)
        XCTAssertEqual(goodKey, .noSSHD, "a socket failure with a readable key is not a key problem")
        let badKey = try await verifier.verify(username: "nobody", secret: "not a key", method: "key", port: port, timeoutMilliseconds: 3000)
        XCTAssertEqual(badKey, .badKey)
    }

    /// Opt-in against a real sshd on this Mac (System Settings > Remote Login).
    /// Skips without the variables; a skip is not passing evidence.
    func testRealLoopbackSSHDAcceptsTheRightPasswordAndRefusesAWrongOne() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let user = environment["TD_SSH_TEST_USER"], let secret = environment["TD_SSH_TEST_PASSWORD"] else {
            throw XCTSkip("Set TD_SSH_TEST_USER and TD_SSH_TEST_PASSWORD (and TD_SSH_TEST_PORT) to check a real loopback sshd.")
        }
        let port = Int(environment["TD_SSH_TEST_PORT"] ?? "22") ?? 22
        let verifier = BackendRemoteServeSSHVerifier(transport: BackendNodelessSSHAuthTransport())
        let accepted = try await verifier.verify(username: user, secret: secret, method: "password", port: port)
        XCTAssertNil(accepted)
        let refused = try await verifier.verify(username: user, secret: secret + "-wrong", method: "password", port: port)
        XCTAssertEqual(refused, .auth)
    }
}
