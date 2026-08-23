/**
 * Reading a private key somebody pasted, and saying honestly when it cannot be
 * used.
 *
 * ## Why this file exists at all
 *
 * `NIOSSH` signs with a `NIOSSHPrivateKey`, and the only ways to make one are
 * from a `Curve25519`, `P256`, `P384` or `P521` key object. It has no reader for
 * the file people actually hold — the `-----BEGIN OPENSSH PRIVATE KEY-----`
 * block `ssh-keygen` writes — so the gap between "what a person has" and "what
 * the library takes" is this file.
 *
 * ## The refusals are the point
 *
 * The desktop hands its keys to `ssh2`, which understands every key OpenSSH
 * does. This does not, and the difference has to arrive as a sentence rather
 * than as a failed handshake. Three cases:
 *
 *  - **RSA.** Not supported by NIOSSH at all — not as a user key and not as a
 *    host key. It is still the key a hosting company mails you, so it is
 *    detected by name and refused with the reason, never left to fail later as
 *    *"that sign-in was refused"*, which would send somebody to change a
 *    password that was never the problem.
 *  - **A key with a passphrase on it.** `ciphername` is anything but `none`.
 *    Nothing on the phone can ask the server for the passphrase, so this is a
 *    question rather than a defect — and it is a different sentence from a
 *    refusal.
 *  - **DSA, and anything else.** Named, and refused by name.
 *
 * ## What it never does
 *
 * It never logs, prints or returns the key material, and it never keeps it. The
 * only thing that leaves here is a key object or an error.
 *
 * ## CryptoKit, not `Crypto`
 *
 * NIOSSH's own signature is written against `Crypto`, the SwiftCrypto module —
 * and on this platform that module is one line: `@_exported import CryptoKit`,
 * behind SwiftPM's own `CRYPTO_IN_SWIFTPM` flag. So the types are the same
 * types, and importing the system framework directly saves linking a second
 * product to say so.
 */

import CryptoKit
import Foundation
import NIOSSH

/// Why a pasted key cannot be used. Every case carries its own sentence.
enum PrivateKeyProblem: Error, Equatable {
    /// Nothing that looks like a private key at all.
    case notAKey
    /// A real key, locked with a passphrase.
    case locked
    /// A real key of a kind this phone cannot sign with. Carries the kind.
    case unsupported(String)
    /// A key of a supported kind whose bytes did not parse.
    case malformed(String)

    /// The headline for the failure panel.
    var headline: String {
        switch self {
        case .notAKey: return "That is not a private key"
        case .locked: return "That key has a passphrase on it"
        case let .unsupported(kind): return "\(kind) keys cannot be used from this phone"
        case .malformed: return "That key could not be read"
        }
    }

    /// The next move, under the headline. Never an apology on its own.
    var advice: String {
        switch self {
        case .notAKey:
            return "Paste the whole file, including the BEGIN and END lines. It is the file with "
                + "no .pub on the end — the .pub one is the half that is meant to be public and "
                + "cannot sign anything."
        case .locked:
            return "Nothing here can ask you for the passphrase on the server's behalf. Either use "
                + "the password for that account instead, or make a copy of the key with no "
                + "passphrase: `ssh-keygen -p -f <the key file>` and leave the new passphrase empty."
        case let .unsupported(kind):
            return "This phone signs with Ed25519 and ECDSA keys. \(kind) is neither. An "
                + "`ssh-keygen -t ed25519` key added to that account with `ssh-copy-id` works, and "
                + "so does the account's password."
        case let .malformed(why):
            return why
        }
    }
}

/// The kinds of key this phone can sign with, spelled the way OpenSSH spells them.
enum SSHKeyKind: String {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
}

enum SSHPrivateKeyReader {

    /// The magic an `openssh-key-v1` block starts with, NUL included.
    private static let magic = Array("openssh-key-v1\0".utf8)

    /**
     * A pasted key, as something that can sign — or a stated reason it cannot.
     *
     * PEM headers decide the route, because they are the one part of every one
     * of these formats that is plain text and reliable.
     */
    static func read(_ text: String) throws -> NIOSSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PrivateKeyProblem.notAKey }

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try readOpenSSH(trimmed)
        }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            throw PrivateKeyProblem.unsupported("RSA")
        }
        if trimmed.contains("BEGIN DSA PRIVATE KEY") {
            throw PrivateKeyProblem.unsupported("DSA")
        }
        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            return try readPEMCurve(trimmed)
        }
        if trimmed.contains("ENCRYPTED PRIVATE KEY") {
            throw PrivateKeyProblem.locked
        }
        // A public key is the mistake worth naming, because the two files sit
        // beside each other and only one of them can sign.
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") {
            throw PrivateKeyProblem.malformed(
                "That is the public half of a key — the one ending .pub. The private half is the "
                    + "file with the same name and no extension, and it begins with a BEGIN line.")
        }
        throw PrivateKeyProblem.notAKey
    }

    /* ------------------------------------------------------------- PKCS#8 -- */

    /**
     * `BEGIN EC PRIVATE KEY` (SEC1) and `BEGIN PRIVATE KEY` (PKCS#8).
     *
     * CryptoKit reads both shapes through `init(pemRepresentation:)`, so the
     * three curves are simply tried in turn. An Ed25519 key in PKCS#8 — which
     * `openssl genpkey` writes and `ssh-keygen` never does — is not readable by
     * CryptoKit and comes out of here named, rather than as a parse failure.
     */
    private static func readPEMCurve(_ pem: String) throws -> NIOSSHPrivateKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p521Key: key)
        }
        throw PrivateKeyProblem.unsupported("That kind of PEM key")
    }

    /* ------------------------------------------------------ openssh-key-v1 -- */

    /**
     * The format `ssh-keygen` has written since 2014.
     *
     *     "openssh-key-v1\0"
     *     string  ciphername          -- "none" unless there is a passphrase
     *     string  kdfname
     *     string  kdfoptions
     *     uint32  number of keys      -- always 1 in practice
     *     string  public key
     *     string  the private section, encrypted when ciphername is not "none"
     *
     * and inside that section, once it is in the clear:
     *
     *     uint32  check
     *     uint32  check                -- the same number twice, or the
     *                                     passphrase was wrong
     *     string  key type
     *     ...     the key, shaped by its type
     *     string  comment
     *     bytes   padding
     */
    private static func readOpenSSH(_ pem: String) throws -> NIOSSHPrivateKey {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let raw = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw PrivateKeyProblem.malformed(
                "The text between the BEGIN and END lines is not valid base64, which usually means "
                    + "it arrived with something else wrapped around it.")
        }

        var wire = SSHWire(Array(raw))
        guard wire.take(magic.count) == magic else {
            throw PrivateKeyProblem.malformed("This key does not start the way an OpenSSH key does.")
        }
        guard let cipher = wire.string(), wire.string() != nil, wire.blob() != nil,
              let count = wire.length(), count >= 1, wire.blob() != nil,
              let secret = wire.blob()
        else {
            throw PrivateKeyProblem.malformed("This key ends before it should.")
        }
        guard cipher == "none" else { throw PrivateKeyProblem.locked }

        var inner = SSHWire(secret)
        guard let check1 = inner.uint32(), let check2 = inner.uint32(), check1 == check2 else {
            // With no cipher there is nothing to get wrong but the file itself.
            throw PrivateKeyProblem.malformed("The inside of this key does not check out.")
        }
        guard let type = inner.string() else {
            throw PrivateKeyProblem.malformed("This key does not say what kind it is.")
        }

        switch SSHKeyKind(rawValue: type) {
        case .ed25519:
            // string public (32), string private (64 = seed ‖ public).
            guard inner.blob() != nil, let secretBytes = inner.blob(), secretBytes.count == 64
            else {
                throw PrivateKeyProblem.malformed("This Ed25519 key is not the right size.")
            }
            guard let key = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(secretBytes.prefix(32)))
            else {
                throw PrivateKeyProblem.malformed("This Ed25519 key could not be loaded.")
            }
            return NIOSSHPrivateKey(ed25519Key: key)

        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            // string curve name, string Q, mpint d.
            guard inner.string() != nil, inner.blob() != nil, let d = inner.blob() else {
                throw PrivateKeyProblem.malformed("This ECDSA key ends before it should.")
            }
            // An mpint carries a leading zero byte whenever the top bit of the
            // first real byte is set, and is short when the number happens to
            // start with zeroes. CryptoKit wants exactly the curve's width.
            let width = type == SSHKeyKind.ecdsaP256.rawValue
                ? 32 : (type == SSHKeyKind.ecdsaP384.rawValue ? 48 : 66)
            let scalar = pad(trimLeadingZeros(d), to: width)
            guard scalar.count == width else {
                throw PrivateKeyProblem.malformed("This ECDSA key is not the right size.")
            }
            if type == SSHKeyKind.ecdsaP256.rawValue {
                guard let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(scalar)) else {
                    throw PrivateKeyProblem.malformed("This ECDSA key could not be loaded.")
                }
                return NIOSSHPrivateKey(p256Key: key)
            }
            if type == SSHKeyKind.ecdsaP384.rawValue {
                guard let key = try? P384.Signing.PrivateKey(rawRepresentation: Data(scalar)) else {
                    throw PrivateKeyProblem.malformed("This ECDSA key could not be loaded.")
                }
                return NIOSSHPrivateKey(p384Key: key)
            }
            guard let key = try? P521.Signing.PrivateKey(rawRepresentation: Data(scalar)) else {
                throw PrivateKeyProblem.malformed("This ECDSA key could not be loaded.")
            }
            return NIOSSHPrivateKey(p521Key: key)

        case nil:
            if type == "ssh-rsa" { throw PrivateKeyProblem.unsupported("RSA") }
            if type == "ssh-dss" { throw PrivateKeyProblem.unsupported("DSA") }
            if type.hasPrefix("sk-") {
                throw PrivateKeyProblem.unsupported("Hardware security key")
            }
            throw PrivateKeyProblem.unsupported(type)
        }
    }

    private static func trimLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        while out.first == 0 && out.count > 1 { out.removeFirst() }
        return out
    }

    private static func pad(_ bytes: [UInt8], to width: Int) -> [UInt8] {
        guard bytes.count < width else { return bytes }
        return [UInt8](repeating: 0, count: width - bytes.count) + bytes
    }
}

/**
 * The one wire format SSH uses everywhere: big-endian lengths in front of
 * everything.
 *
 * Deliberately total — every read is optional and every read is bounds-checked,
 * because the bytes being walked came out of a text box.
 */
struct SSHWire {
    private let bytes: [UInt8]
    private var at: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, at + count <= bytes.count else { return nil }
        defer { at += count }
        return Array(bytes[at..<(at + count)])
    }

    /// Four bytes, big-endian, as they are. **Not** bounded: the two check
    /// numbers inside an OpenSSH key are random 32-bit values, and a bound here
    /// rejected every real key with a check value above 16 megabytes — which is
    /// 99.6% of them. Measured against his own Hetzner key, which is why this
    /// comment exists and why {@link length} is a separate reader.
    mutating func uint32() -> Int? {
        guard let four = take(4) else { return nil }
        let value = (UInt32(four[0]) << 24) | (UInt32(four[1]) << 16)
            | (UInt32(four[2]) << 8) | UInt32(four[3])
        return Int(value)
    }

    /// A length, which is a number this file is willing to allocate. Anything
    /// larger is a corrupt file rather than a real key, and refusing here is
    /// what keeps a bad paste from asking for a gigabyte.
    mutating func length() -> Int? {
        guard let value = uint32(), value <= 1 << 24 else { return nil }
        return value
    }

    mutating func blob() -> [UInt8]? {
        guard let count = length() else { return nil }
        return take(count)
    }

    mutating func string() -> String? {
        guard let raw = blob() else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}

/**
 * **What was actually pasted**, read back and described.
 *
 * ## The bug this exists to make impossible
 *
 * The key field was a paste-only pill whose entire feedback was
 * *"Private key ready · 412 characters"*. A character count cannot tell a whole
 * key from a key whose seven lines were flattened into one — the count is
 * identical either way, because a newline is one character and so is the space
 * that replaced it. So a key that arrived mangled read as ready, the login was
 * refused, and the sentence on screen sent somebody to check a password that was
 * never the problem.
 *
 * A private key is **seven lines** for Ed25519, and the first and last of them
 * are `-----BEGIN OPENSSH PRIVATE KEY-----` and its END. This says how many
 * lines came through and whether both of those are present, and it runs the real
 * reader over the bytes — the same one the SSH handshake will use — so *"this
 * key is readable"* means the thing that is about to sign has already read it.
 *
 * Nothing here renders the key. What it returns is a sentence about it.
 */
enum PrivateKeyReadback: Equatable {
    /// Readable by the reader that will sign with it. Carries the sentence.
    case good(String)
    /// Something arrived and it is not usable. Carries the reader's own words.
    case bad(headline: String, advice: String)
    /// Empty.
    case nothing

    var sentence: String? {
        switch self {
        case let .good(text): return text
        case let .bad(headline, _): return headline
        case .nothing: return nil
        }
    }

    var isGood: Bool {
        if case .good = self { return true }
        return false
    }

    /**
     * Look at a pasted key.
     *
     * The line count is of the **trimmed** text, because a copied file almost
     * always arrives with a trailing newline and counting it would report eight
     * lines for a seven-line key — a number that does not match what somebody
     * sees in their editor, on a screen whose whole job is to convince them the
     * paste was whole.
     */
    static func of(_ raw: String) -> PrivateKeyReadback {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .nothing }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
        do {
            _ = try SSHPrivateKeyReader.read(trimmed)
        } catch let problem as PrivateKeyProblem {
            /*
             * A readable *kind* of key that this phone cannot sign with is still
             * a key that survived the paste, and saying "one line" about an RSA
             * key would be two complaints in one sentence. The reader's own
             * headline goes out; the line count goes with it only when the
             * failure could plausibly *be* the paste.
             */
            if case .notAKey = problem, lines <= 1 {
                return .bad(headline: "That arrived as one line.",
                            advice: "A private key is several lines and this field kept only one, "
                                + "which usually means it was copied out of somewhere that "
                                + "flattened it. Paste it again, or open the key file and copy all "
                                + "of it including the BEGIN and END lines.")
            }
            return .bad(headline: problem.headline, advice: problem.advice)
        } catch {
            return .bad(headline: "That key could not be read.",
                        advice: String(describing: error))
        }

        let kind = trimmed.contains("BEGIN OPENSSH PRIVATE KEY") ? "OpenSSH" : "PEM"
        let ends = trimmed.hasPrefix("-----BEGIN") && trimmed.hasSuffix("KEY-----")
        return .good("\(kind) private key · \(lines) line\(lines == 1 ? "" : "s")"
            + (ends ? " · BEGIN and END are both here" : ""))
    }
}
