/**
 * Reading a pasted private key, and refusing the ones this phone cannot sign
 * with — by name, rather than by letting them fail later as "that sign-in was
 * refused".
 *
 * The round trip is built here rather than checked in: a private key committed
 * to a repository is a private key, however loudly a comment says it is a test
 * one. The writer below produces exactly the layout `ssh-keygen` writes, from a
 * key this test made a moment earlier, so the parser is exercised against the
 * real byte shape with nothing to leak.
 *
 * The format itself was proved against a real key on a real server:
 * `SSHSession` signed into a live Ubuntu box with Asad's own Ed25519 key and ran
 * both probe scripts. That is what caught the bound this parser originally put
 * on **every** four-byte read — the two check numbers inside an OpenSSH key are
 * random 32-bit values, so a bound meant for lengths rejected roughly every real
 * key. See `SSHWire.uint32`.
 */

import CryptoKit
import XCTest
@testable import TerminalDeck

final class SSHKeyReadingTests: XCTestCase {

    func testReadsAnEd25519KeyInOpenSSHFormat() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = Self.openSSHEd25519(key)
        let read = try SSHPrivateKeyReader.read(pem)
        // The public half is what the server checks, so it is the half worth
        // asserting: a parser that read the wrong 32 bytes would still produce a
        // key object, and would be refused by every server it was offered to.
        XCTAssertEqual(String(openSSHPublicKey: read.publicKey),
                       "ssh-ed25519 " + Self.base64(Self.publicBlob(key)))
    }

    func testSurvivesTheWrappingAPasteArrivesWith() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = "\n  " + Self.openSSHEd25519(key) + "\n\n"
        XCTAssertNoThrow(try SSHPrivateKeyReader.read(pem))
    }

    func testRefusesRSAByName() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA
        -----END RSA PRIVATE KEY-----
        """
        assertProblem(pem, .unsupported("RSA"))
    }

    /// The one a hosting company mails you, inside the newer wrapper. Same
    /// answer, and it has to come from the *inner* key type rather than from the
    /// PEM header, which says nothing about the algorithm.
    func testRefusesRSAInsideAnOpenSSHWrapper() {
        assertProblem(Self.openSSHOfType("ssh-rsa"), .unsupported("RSA"))
    }

    func testRefusesADSAKey() {
        assertProblem(Self.openSSHOfType("ssh-dss"), .unsupported("DSA"))
    }

    /// A key with a passphrase is a question, not a defect — and the sentence
    /// says so, because "refused" would send somebody to check a password that
    /// was never the problem.
    func testRefusesALockedKeyAsLockedRatherThanBroken() {
        assertProblem(Self.openSSHEncrypted(), .locked)
        XCTAssertTrue(PrivateKeyProblem.locked.advice.contains("ssh-keygen -p"))
    }

    /// The two files sit beside each other and only one of them can sign.
    func testNamesThePublicHalfWhenThatIsWhatWasPasted() {
        do {
            _ = try SSHPrivateKeyReader.read("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 someone@example")
            XCTFail("a public key was accepted as a private one")
        } catch let problem as PrivateKeyProblem {
            guard case let .malformed(why) = problem else {
                return XCTFail("wrong refusal: \(problem)")
            }
            XCTAssertTrue(why.contains(".pub"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRefusesSomethingThatIsNotAKeyAtAll() {
        assertProblem("hunter2", .notAKey)
        assertProblem("", .notAKey)
    }

    /// A key whose base64 is fine and whose contents are not.
    func testRefusesATruncatedKey() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(Self.base64(Array("openssh-key-v1\0".utf8)))
        -----END OPENSSH PRIVATE KEY-----
        """
        do {
            _ = try SSHPrivateKeyReader.read(pem)
            XCTFail("a truncated key was accepted")
        } catch let problem as PrivateKeyProblem {
            guard case .malformed = problem else { return XCTFail("wrong refusal: \(problem)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Every refusal has to be able to say what to do next; a headline on its
    /// own is a dead end, and this screen has none.
    func testEveryRefusalCarriesAdvice() {
        for problem: PrivateKeyProblem in [.notAKey, .locked, .unsupported("RSA"),
                                           .malformed("because")] {
            XCTAssertFalse(problem.headline.isEmpty)
            XCTAssertFalse(problem.advice.isEmpty)
        }
    }

    // MARK: - Asserting

    private func assertProblem(_ pem: String,
                               _ expected: PrivateKeyProblem,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        do {
            _ = try SSHPrivateKeyReader.read(pem)
            XCTFail("that key was accepted", file: file, line: line)
        } catch let problem as PrivateKeyProblem {
            XCTAssertEqual(problem, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Writing the format ssh-keygen writes

    private static func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    private static func string(_ bytes: [UInt8]) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + bytes
    }

    private static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    private static func publicBlob(_ key: Curve25519.Signing.PrivateKey) -> [UInt8] {
        string("ssh-ed25519") + string(Array(key.publicKey.rawRepresentation))
    }

    private static func wrap(_ body: [UInt8]) -> String {
        """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(base64(body))
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private static func openSSHEd25519(_ key: Curve25519.Signing.PrivateKey) -> String {
        let pub = Array(key.publicKey.rawRepresentation)
        let secret = Array(key.rawRepresentation) + pub
        // A check number with the top bit set on purpose: this is the value the
        // first version of the parser rejected as an over-long length.
        let check: [UInt8] = [0xF3, 0x1D, 0x40, 0x9C]
        var inner = check + check + string("ssh-ed25519") + string(pub) + string(secret)
            + string("someone@example")
        var pad: UInt8 = 1
        while inner.count % 8 != 0 {
            inner.append(pad)
            pad += 1
        }
        let body = Array("openssh-key-v1\0".utf8)
            + string("none") + string("none") + string([])
            + [0, 0, 0, 1]
            + string(publicBlob(key)) + string(inner)
        return wrap(body)
    }

    private static func openSSHOfType(_ type: String) -> String {
        let check: [UInt8] = [1, 2, 3, 4]
        var inner = check + check + string(type) + string([0, 0]) + string([0, 0])
            + string("someone@example")
        var pad: UInt8 = 1
        while inner.count % 8 != 0 {
            inner.append(pad)
            pad += 1
        }
        let body = Array("openssh-key-v1\0".utf8)
            + string("none") + string("none") + string([])
            + [0, 0, 0, 1]
            + string(string(type) + string([0, 0])) + string(inner)
        return wrap(body)
    }

    private static func openSSHEncrypted() -> String {
        let body = Array("openssh-key-v1\0".utf8)
            + string("aes256-ctr") + string("bcrypt") + string([0, 1, 2, 3])
            + [0, 0, 0, 1]
            + string(string("ssh-ed25519") + string([UInt8](repeating: 7, count: 32)))
            + string([UInt8](repeating: 9, count: 64))
        return wrap(body)
    }
}
