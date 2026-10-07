import Foundation
import CryptoKit
import Security

/// N18: in-memory private keys for the loopback login check (ssh2's
/// `privateKey` parsing), and server host-key signature checks. Nothing is
/// written to disk and no agent is used. Error text matches ssh2's shapes so
/// `BackendRemoteServeSSHVerifier.classify` answers `bad-key`.
enum BackendNodelessSSHKeyFailure {
    static func unreadable(_ why: String) -> BackendRemoteServeSSHSignal {
        .init(level: "client-key", message: "Cannot parse privateKey: " + why)
    }
    static let passphrase = BackendRemoteServeSSHSignal(level: "client-key", message: "Encrypted private key detected, but no passphrase given")
}

struct BackendNodelessSSHPEM {
    let label: String
    let headers: [String]
    let der: [UInt8]
    static func parse(_ text: String) throws -> BackendNodelessSSHPEM {
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") && $0.count > 16 }) else {
            throw BackendNodelessSSHKeyFailure.unreadable("Unsupported key format")
        }
        let label = String(lines[begin].dropFirst(11).dropLast(5))
        guard let end = lines[(begin + 1)...].firstIndex(of: "-----END \(label)-----") else {
            throw BackendNodelessSSHKeyFailure.unreadable("Missing end of key")
        }
        var headers: [String] = [], body = ""
        for line in lines[(begin + 1)..<end] { if line.contains(":") { headers.append(line) } else { body += line } }
        guard let data = Data(base64Encoded: body), !data.isEmpty else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid key encoding") }
        return .init(label: label, headers: headers, der: Array(data))
    }
}

/// Minimal DER reading/writing for PKCS#1/PKCS#8 key containers.
struct BackendNodelessSSHDER {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    mutating func element() throws -> (tag: UInt8, value: [UInt8]) {
        guard offset + 2 <= bytes.count else { throw BackendNodelessSSHKeyFailure.unreadable("Truncated key structure") }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1]); offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...4).contains(count), offset + count <= bytes.count else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid key length") }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
        }
        guard length >= 0, offset + length <= bytes.count else { throw BackendNodelessSSHKeyFailure.unreadable("Truncated key structure") }
        defer { offset += length }
        return (tag, Array(bytes[offset..<(offset + length)]))
    }
    mutating func expect(_ tag: UInt8) throws -> [UInt8] {
        let next = try element()
        guard next.tag == tag else { throw BackendNodelessSSHKeyFailure.unreadable("Unexpected key structure") }
        return next.value
    }
    mutating func integer() throws -> [UInt8] { Array(try expect(0x02).drop(while: { $0 == 0 })) }

    static func length(_ count: Int) -> [UInt8] {
        guard count >= 128 else { return [UInt8(count)] }
        var octets: [UInt8] = [], value = count
        while value > 0 { octets.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return [0x80 | UInt8(octets.count)] + octets
    }
    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] { [tag] + length(value.count) + value }
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var value = Array(magnitude.drop(while: { $0 == 0 }))
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tlv(0x02, value)
    }
    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
}

/// Unsigned big-number remainder, only for RSA CRT exponents (d mod (p-1)).
enum BackendNodelessSSHBigMod {
    static func modMinusOne(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        var divisor = limbs(modulus)
        subtract(&divisor, [1])
        guard !divisor.isEmpty else { return [] }
        return bytes(remainder(limbs(value), divisor))
    }
    static func limbs(_ bigEndian: [UInt8]) -> [UInt32] {
        var out: [UInt32] = [], end = bigEndian.count
        while end > 0 {
            let start = max(0, end - 4)
            out.append(bigEndian[start..<end].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            end = start
        }
        while out.last == 0 { out.removeLast() }
        return out
    }
    static func bytes(_ value: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        for word in value.reversed() {
            out += [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
        return Array(out.drop(while: { $0 == 0 }))
    }
    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for index in stride(from: a.count - 1, through: 0, by: -1) where a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
        return 0
    }
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for index in 0..<a.count {
            var difference = Int64(a[index]) - Int64(index < b.count ? b[index] : 0) - borrow
            if difference < 0 { difference += 1 << 32; borrow = 1 } else { borrow = 0 }
            a[index] = UInt32(difference)
        }
        while a.last == 0 { a.removeLast() }
    }
    static func remainder(_ value: [UInt32], _ divisor: [UInt32]) -> [UInt32] {
        var rest: [UInt32] = []
        for index in stride(from: value.count - 1, through: 0, by: -1) {
            for bit in stride(from: 31, through: 0, by: -1) {
                var carry = (value[index] >> UInt32(bit)) & 1
                for limb in 0..<rest.count { let next = rest[limb] >> 31; rest[limb] = rest[limb] << 1 | carry; carry = next }
                if carry != 0 { rest.append(carry) }
                if compare(rest, divisor) >= 0 { subtract(&rest, divisor) }
            }
        }
        return rest
    }
}

/// The one credential handed in, parsed in memory.
enum BackendNodelessSSHPrivateKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
    case rsa(SecKey, modulus: [UInt8], exponent: [UInt8])

    private static let rsaOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    private static let ecOID: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    private static let ed25519OID: [UInt8] = [0x2b, 0x65, 0x70]

    static func parse(_ text: String) throws -> BackendNodelessSSHPrivateKey {
        do {
            let pem = try BackendNodelessSSHPEM.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let encrypted = pem.headers.contains { $0.uppercased().hasPrefix("PROC-TYPE:") && $0.uppercased().contains("ENCRYPTED") }
            switch pem.label {
            case "OPENSSH PRIVATE KEY": return try openSSH(pem.der)
            case "RSA PRIVATE KEY":
                if encrypted { throw BackendNodelessSSHKeyFailure.passphrase }
                return try rsa(pkcs1: pem.der)
            case "EC PRIVATE KEY":
                if encrypted { throw BackendNodelessSSHKeyFailure.passphrase }
                return try ec(pem.der)
            case "PRIVATE KEY": return try pkcs8(pem.der)
            case "ENCRYPTED PRIVATE KEY": throw BackendNodelessSSHKeyFailure.passphrase
            default: throw BackendNodelessSSHKeyFailure.unreadable("Unsupported key format")
            }
        } catch let signal as BackendRemoteServeSSHSignal { throw signal }
        catch { throw BackendNodelessSSHKeyFailure.unreadable("The key's numbers are not a valid key") }
    }

    private static func fixed(_ magnitude: [UInt8], _ size: Int) throws -> [UInt8] {
        guard magnitude.count <= size else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid key size") }
        return [UInt8](repeating: 0, count: size - magnitude.count) + magnitude
    }
    private static func openSSH(_ bytes: [UInt8]) throws -> BackendNodelessSSHPrivateKey {
        var outer = BackendNodelessSSHReader(bytes)
        guard (try? outer.raw(15)) == Array("openssh-key-v1\u{0}".utf8) else { throw BackendNodelessSSHKeyFailure.unreadable("Not an OpenSSH key") }
        let cipher = try outer.text(), kdf = try outer.text()
        _ = try outer.string()
        guard try outer.uint32() == 1 else { throw BackendNodelessSSHKeyFailure.unreadable("Only one key per file is supported") }
        _ = try outer.string()
        guard cipher == "none", kdf == "none" else { throw BackendNodelessSSHKeyFailure.passphrase }
        var inner = BackendNodelessSSHReader(try outer.string())
        let check = try inner.uint32()
        guard try inner.uint32() == check else { throw BackendNodelessSSHKeyFailure.unreadable("Corrupt key") }
        let type = try inner.text()
        switch type {
        case "ssh-ed25519":
            _ = try inner.string()
            let secret = try inner.string()
            guard secret.count == 64 else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid Ed25519 key") }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: Array(secret.prefix(32))))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try inner.text(); _ = try inner.string()
            let scalar = try inner.mpint()
            if type.hasSuffix("256") { return .p256(try P256.Signing.PrivateKey(rawRepresentation: try fixed(scalar, 32))) }
            if type.hasSuffix("384") { return .p384(try P384.Signing.PrivateKey(rawRepresentation: try fixed(scalar, 48))) }
            return .p521(try P521.Signing.PrivateKey(rawRepresentation: try fixed(scalar, 66)))
        case "ssh-rsa":
            let n = try inner.mpint(), e = try inner.mpint(), d = try inner.mpint()
            let iqmp = try inner.mpint(), p = try inner.mpint(), q = try inner.mpint()
            guard !p.isEmpty, !q.isEmpty, !d.isEmpty else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid RSA key") }
            let der = BackendNodelessSSHDER.sequence([
                BackendNodelessSSHDER.integer([0]), BackendNodelessSSHDER.integer(n), BackendNodelessSSHDER.integer(e),
                BackendNodelessSSHDER.integer(d), BackendNodelessSSHDER.integer(p), BackendNodelessSSHDER.integer(q),
                BackendNodelessSSHDER.integer(BackendNodelessSSHBigMod.modMinusOne(d, p)),
                BackendNodelessSSHDER.integer(BackendNodelessSSHBigMod.modMinusOne(d, q)),
                BackendNodelessSSHDER.integer(iqmp)])
            return .rsa(try secKey(der), modulus: n, exponent: e)
        default:
            throw BackendNodelessSSHKeyFailure.unreadable("Unsupported key type \(type)")
        }
    }
    private static func rsa(pkcs1 der: [UInt8]) throws -> BackendNodelessSSHPrivateKey {
        var outer = BackendNodelessSSHDER(der)
        var fields = BackendNodelessSSHDER(try outer.expect(0x30))
        _ = try fields.integer()
        let n = try fields.integer(), e = try fields.integer()
        return .rsa(try secKey(der), modulus: n, exponent: e)
    }
    private static func secKey(_ der: [UInt8]) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            throw BackendNodelessSSHKeyFailure.unreadable("Invalid RSA key")
        }
        return key
    }
    private static func ec(_ der: [UInt8]) throws -> BackendNodelessSSHPrivateKey {
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return .p256(key) }
        if let key = try? P384.Signing.PrivateKey(derRepresentation: der) { return .p384(key) }
        if let key = try? P521.Signing.PrivateKey(derRepresentation: der) { return .p521(key) }
        throw BackendNodelessSSHKeyFailure.unreadable("Unsupported EC key")
    }
    private static func pkcs8(_ der: [UInt8]) throws -> BackendNodelessSSHPrivateKey {
        var outer = BackendNodelessSSHDER(der)
        var info = BackendNodelessSSHDER(try outer.expect(0x30))
        _ = try info.integer()
        var algorithm = BackendNodelessSSHDER(try info.expect(0x30))
        let oid = try algorithm.expect(0x06)
        let octets = try info.expect(0x04)
        switch oid {
        case rsaOID: return try rsa(pkcs1: octets)
        case ecOID: return try ec(der)
        case ed25519OID:
            var seed = BackendNodelessSSHDER(octets)
            let raw = try seed.expect(0x04)
            guard raw.count == 32 else { throw BackendNodelessSSHKeyFailure.unreadable("Invalid Ed25519 key") }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        default: throw BackendNodelessSSHKeyFailure.unreadable("Unsupported key type")
        }
    }

    /// Signature algorithms to offer, best first.
    var algorithms: [String] {
        switch self {
        case .ed25519: ["ssh-ed25519"]
        case .p256: ["ecdsa-sha2-nistp256"]
        case .p384: ["ecdsa-sha2-nistp384"]
        case .p521: ["ecdsa-sha2-nistp521"]
        case .rsa: ["rsa-sha2-512", "rsa-sha2-256"]
        }
    }
    var publicBlob: [UInt8] {
        var writer = BackendNodelessSSHWriter()
        switch self {
        case .ed25519(let key): writer.string("ssh-ed25519"); writer.string(Array(key.publicKey.rawRepresentation))
        case .p256(let key): writer.string("ecdsa-sha2-nistp256"); writer.string("nistp256"); writer.string(Array(key.publicKey.x963Representation))
        case .p384(let key): writer.string("ecdsa-sha2-nistp384"); writer.string("nistp384"); writer.string(Array(key.publicKey.x963Representation))
        case .p521(let key): writer.string("ecdsa-sha2-nistp521"); writer.string("nistp521"); writer.string(Array(key.publicKey.x963Representation))
        case .rsa(_, let modulus, let exponent): writer.string("ssh-rsa"); writer.mpint(exponent); writer.mpint(modulus)
        }
        return writer.bytes
    }
    /// The SSH signature blob: string algorithm, string signature.
    func sign(_ data: [UInt8], algorithm: String) throws -> [UInt8] {
        var writer = BackendNodelessSSHWriter()
        writer.string(algorithm)
        func ecdsa(_ raw: Data, half: Int) -> [UInt8] {
            var inner = BackendNodelessSSHWriter()
            inner.mpint(Array(raw.prefix(half))); inner.mpint(Array(raw.suffix(half)))
            return inner.bytes
        }
        switch self {
        case .ed25519(let key): writer.string(Array(try key.signature(for: Data(data))))
        case .p256(let key): writer.string(ecdsa(try key.signature(for: Data(data)).rawRepresentation, half: 32))
        case .p384(let key): writer.string(ecdsa(try key.signature(for: Data(data)).rawRepresentation, half: 48))
        case .p521(let key): writer.string(ecdsa(try key.signature(for: Data(data)).rawRepresentation, half: 66))
        case .rsa(let key, _, _):
            let method: SecKeyAlgorithm = algorithm == "rsa-sha2-256" ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA512
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, method, Data(data) as CFData, &error) as Data? else {
                throw BackendNodelessSSHKeyFailure.unreadable("The RSA key could not sign")
            }
            writer.string(Array(signature))
        }
        return writer.bytes
    }
}

/// Exchange-hash signature check for the negotiated host-key algorithm. The
/// loopback host key itself is accepted without comparison (ssh-verify.ts).
enum BackendNodelessSSHHostKey {
    static let algorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]
    static func verify(blob: [UInt8], signature: [UInt8], hash: [UInt8], algorithm: String) throws {
        let failure = BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server's host signature did not verify.")
        var key = BackendNodelessSSHReader(blob), proof = BackendNodelessSSHReader(signature)
        let type = try key.text()
        guard try proof.text() == algorithm else { throw failure }
        let signed = try proof.string()
        switch algorithm {
        case "ssh-ed25519":
            guard type == algorithm else { throw failure }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try key.string())
            guard publicKey.isValidSignature(signed, for: hash) else { throw failure }
        case "ecdsa-sha2-nistp256":
            guard type == algorithm, try key.text() == "nistp256" else { throw failure }
            let publicKey = try P256.Signing.PublicKey(x963Representation: try key.string())
            var pair = BackendNodelessSSHReader(signed)
            let r = try pair.mpint(), s = try pair.mpint()
            guard r.count <= 32, s.count <= 32 else { throw failure }
            let raw = [UInt8](repeating: 0, count: 32 - r.count) + r + [UInt8](repeating: 0, count: 32 - s.count) + s
            guard publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: hash) else { throw failure }
        case "rsa-sha2-512", "rsa-sha2-256":
            guard type == "ssh-rsa" else { throw failure }
            let exponent = try key.mpint(), modulus = try key.mpint()
            guard modulus.count >= 128, signed.count <= modulus.count else { throw failure }
            let der = BackendNodelessSSHDER.sequence([BackendNodelessSSHDER.integer(modulus), BackendNodelessSSHDER.integer(exponent)])
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            var error: Unmanaged<CFError>?
            guard let publicKey = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else { throw failure }
            let full = [UInt8](repeating: 0, count: modulus.count - signed.count) + signed
            let method: SecKeyAlgorithm = algorithm == "rsa-sha2-256" ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA512
            guard SecKeyVerifySignature(publicKey, method, Data(hash) as CFData, Data(full) as CFData, &error) else { throw failure }
        default:
            throw failure
        }
    }
}
