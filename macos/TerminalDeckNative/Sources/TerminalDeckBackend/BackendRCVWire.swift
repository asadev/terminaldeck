import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The Receiver's half of the relay wire (mirrors `relay/src/receiver.ts`) and
/// the end-to-end checks the Mac makes on every delivery. The relay holds no
/// source secret, so everything here is checked again on this Mac.
public enum BackendRCVWire {
    public static let sync: UInt8 = 0x20, deliver: UInt8 = 0x21, ack: UInt8 = 0x22, synced: UInt8 = 0x23
    public static let ackKept: UInt8 = 1, ackRefused: UInt8 = 2, ackUnknown: UInt8 = 3
    public static let sealInfo = "td-receiver-seal-v1"
    public static let maxBodyBytes = 80 * 1024
    public static let noChannel = Data(count: 16)
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func isFrame(_ type: UInt8) -> Bool { (sync...synced).contains(type) }

    /// 26 characters of the relay's base32 alphabet: 130 random bits, never derived from the host id.
    public static func mintSourceID() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<26).map { _ in alphabet[Int(generator.next(upperBound: UInt8(32)))] })
    }
    public static func isSourceID(_ value: String) -> Bool { value.range(of: #"^[A-HJ-NP-Z2-9]{26}$"#, options: .regularExpression) != nil }

    /// 32 random bytes as 43 base64url characters.
    public static func mintSecret() -> String { base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func sha256Hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Equal-time comparison of two texts (by digest, so lengths leak nothing either).
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(SHA256.hash(data: Data(a.utf8))), y = Array(SHA256.hash(data: Data(b.utf8)))
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    // MARK: Frames

    public static func frame(_ type: UInt8, channel: Data, payload: Data) -> Data {
        var out = Data([type]); out.append(channel.prefix(16)); if channel.count < 16 { out.append(Data(count: 16 - channel.count)) }
        out.append(payload); return out
    }

    static func withHead(_ head: Any, rest: Data) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
        guard json.count <= 0xffff else { throw NativeRPCError.malformed("The Receiver head is too large.") }
        var out = Data([UInt8(json.count >> 8), UInt8(json.count & 0xff)]); out.append(json); out.append(rest); return out
    }

    static func readHead(_ payload: Data) -> (head: [String: Any], rest: Data)? {
        let bytes = Data(payload)
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[bytes.startIndex]) << 8 | Int(bytes[bytes.startIndex + 1])
        guard bytes.count >= 2 + length,
              let head = try? JSONSerialization.jsonObject(with: bytes.subdata(in: (bytes.startIndex + 2)..<(bytes.startIndex + 2 + length))) as? [String: Any]
        else { return nil }
        return (head, bytes.subdata(in: (bytes.startIndex + 2 + length)..<bytes.endIndex))
    }

    /// What the relay is told about one source. Never a secret: only hashes and header names.
    public struct Declaration: Equatable, Sendable {
        public let id: String, auth: RCVAuthScheme, secretHash: String?, tokenHeader: String?, signatureHeader: String?, ipAllow: [String], enabled: Bool
        var json: [String: Any] {
            var out: [String: Any] = ["id": id, "auth": auth.rawValue, "enabled": enabled, "ipAllow": ipAllow]
            if let secretHash { out["secretHash"] = secretHash }
            if let tokenHeader { out["tokenHeader"] = tokenHeader }
            if let signatureHeader { out["signatureHeader"] = signatureHeader }
            return out
        }
    }

    public static func declaration(_ source: RCVSource, secret: String) -> Declaration {
        let auth = source.auth
        let hash: String?
        switch auth.scheme {
        case .token: hash = sha256Hex(secret)
        case .basic: hash = sha256Hex((auth.basicUser ?? "") + ":" + secret)
        case .hmac, .none: hash = nil
        }
        return .init(id: source.id, auth: auth.scheme, secretHash: hash, tokenHeader: auth.tokenHeader?.lowercased(),
                     signatureHeader: auth.scheme == .hmac ? auth.hmac?.header.lowercased() : nil, ipAllow: auth.ipAllow, enabled: source.enabled)
    }

    public static func syncPayload(sealKey: Curve25519.KeyAgreement.PublicKey, sources: [Declaration]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "sealKey": base64url(sealKey.rawRepresentation), "sources": sources.map(\.json)], options: [.sortedKeys])
    }

    public struct Synced: Equatable, Sendable { public let accepted: [String], refused: [String: String], queued: Int }
    public static func decodeSynced(_ payload: Data) -> Synced? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], object["v"] as? Int == 1 else { return nil }
        let refused = (object["refused"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { out, item in
            if let id = item["id"] as? String, let reason = item["reason"] as? String { out[id] = reason }
        }
        return .init(accepted: object["accepted"] as? [String] ?? [], refused: refused, queued: object["queued"] as? Int ?? 0)
    }

    public struct Delivery: Equatable, Sendable {
        public let id: Data, sourceID: String, receivedAt: Int64, sealed: Data
        public var key: String { id.map { String(format: "%02x", $0) }.joined() }
    }
    public static func decodeDeliver(channel: Data, payload: Data) -> Delivery? {
        guard channel.count == 16, let parsed = readHead(payload), parsed.head["v"] as? Int == 1,
              let source = parsed.head["sourceId"] as? String, isSourceID(source),
              let received = (parsed.head["receivedAt"] as? NSNumber)?.int64Value, received > 0, parsed.rest.count >= 60 else { return nil }
        return .init(id: Data(channel), sourceID: source, receivedAt: received, sealed: parsed.rest)
    }

    // MARK: Sealing

    public static func aad(sourceID: String, deliveryID: Data, receivedAt: Int64) -> Data {
        Data("\(sourceID).\(deliveryID.map { String(format: "%02x", $0) }.joined()).\(receivedAt)".utf8)
    }

    static func symmetric(_ shared: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient, sharedInfo: Data(sealInfo.utf8), outputByteCount: 32)
    }

    /// The relay's construction, for tests and for posting sample deliveries locally.
    public static func seal(_ plain: Data, to recipient: Curve25519.KeyAgreement.PublicKey, aad: Data) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = symmetric(shared, ephemeral: ephemeral.publicKey.rawRepresentation, recipient: recipient.rawRepresentation)
        let box = try AES.GCM.seal(plain, using: key, authenticating: aad)
        return ephemeral.publicKey.rawRepresentation + Data(box.nonce) + box.ciphertext + box.tag
    }

    public static func open(_ sealed: Data, key: Curve25519.KeyAgreement.PrivateKey, aad: Data) throws -> Data {
        let bytes = Data(sealed)
        guard bytes.count >= 60 else { throw NativeRPCError.malformed("The delivery is too short to open.") }
        let ephemeral = bytes.prefix(32), nonce = bytes.subdata(in: 32..<44)
        let body = bytes.subdata(in: 44..<(bytes.count - 16)), tag = bytes.suffix(16)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        let symmetricKey = symmetric(shared, ephemeral: Data(ephemeral), recipient: key.publicKey.rawRepresentation)
        return try AES.GCM.open(try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag), using: symmetricKey, authenticating: aad)
    }

    /// One opened delivery, as the sender sent it (headers lowercased).
    public struct Opened: Sendable {
        public let method: String, headers: [String: String], pathToken: String?, clientIP: String?, body: Data
        public init(method: String = "POST", headers: [String: String], pathToken: String? = nil, clientIP: String? = nil, body: Data) {
            self.method = method; self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            self.pathToken = pathToken; self.clientIP = clientIP; self.body = body
        }
    }

    public static func openDelivery(_ delivery: Delivery, key: Curve25519.KeyAgreement.PrivateKey) throws -> Opened {
        let plain = try open(delivery.sealed, key: key, aad: aad(sourceID: delivery.sourceID, deliveryID: delivery.id, receivedAt: delivery.receivedAt))
        guard let parsed = readHead(plain), parsed.head["v"] as? Int == 1, parsed.rest.count <= maxBodyBytes else { throw NativeRPCError.malformed("The delivery's contents are not readable.") }
        let headers = (parsed.head["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return .init(method: parsed.head["method"] as? String ?? "POST", headers: headers, pathToken: parsed.head["pathToken"] as? String,
                     clientIP: parsed.head["clientIp"] as? String, body: parsed.rest)
    }

    /// The plain form a delivery is sealed in (tests, and local "send a sample").
    public static func plain(_ opened: Opened) throws -> Data {
        var head: [String: Any] = ["v": 1, "method": opened.method, "headers": opened.headers]
        if let token = opened.pathToken { head["pathToken"] = token }
        if let ip = opened.clientIP { head["clientIp"] = ip }
        return try withHead(head, rest: opened.body)
    }
}

/// End-to-end checks on this Mac. Each failure is one plain sentence and never quotes the secret.
public enum BackendRCVAuth {
    public enum Failure: Error, Equatable, Sendable {
        case address, credential, signature, stale
        public var words: String {
            switch self {
            case .address: "It came from an address that is not on this source’s allowed list."
            case .credential: "Its secret was missing or wrong."
            case .signature: "Its signature did not match this source’s secret."
            case .stale: "Its signed time was too old or in the future, so it may be a replay."
            }
        }
    }

    public static func verify(_ opened: BackendRCVWire.Opened, source: RCVSource, secret: String, now: Double) -> Failure? {
        let auth = source.auth
        if !auth.ipAllow.isEmpty {
            guard let ip = opened.clientIP, auth.ipAllow.contains(where: { allows($0, ip) }) else { return .address }
        }
        switch auth.scheme {
        case .none: return nil
        case .token:
            let bearer = opened.headers["authorization"].flatMap { value -> String? in
                value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : nil
            }
            let presented = opened.pathToken ?? bearer ?? opened.headers[auth.tokenHeader?.lowercased() ?? "x-receiver-secret"]
            guard let presented, !secret.isEmpty, BackendRCVWire.same(presented, secret) else { return .credential }
            return nil
        case .basic:
            guard let value = opened.headers["authorization"], value.hasPrefix("Basic "),
                  let decoded = Data(base64Encoded: String(value.dropFirst(6))).flatMap({ String(data: $0, encoding: .utf8) }),
                  let user = auth.basicUser, !secret.isEmpty, BackendRCVWire.same(decoded, user + ":" + secret) else { return .credential }
            return nil
        case .hmac:
            guard let hmac = auth.hmac, let header = opened.headers[hmac.header.lowercased()], !secret.isEmpty else { return .signature }
            var signed = Data()
            let parts = hmac.signedPayload.components(separatedBy: "{body}")
            guard parts.count == 2 else { return .signature }
            var before = parts[0], after = parts[1]
            if hmac.signedPayload.contains("{timestamp}") {
                guard let name = hmac.timestampHeader, let stamp = opened.headers[name.lowercased()], let number = Double(stamp) else { return .stale }
                let millis = number > 1e12 ? number : number * 1000
                guard abs(now - millis) <= Double(hmac.toleranceSeconds) * 1000 else { return .stale }
                before = before.replacingOccurrences(of: "{timestamp}", with: stamp); after = after.replacingOccurrences(of: "{timestamp}", with: stamp)
            }
            signed.append(Data(before.utf8)); signed.append(opened.body); signed.append(Data(after.utf8))
            let expected = mac(signed, secret: Data(secret.utf8), algorithm: hmac.algorithm)
            // Some senders list several signatures (key rotation); any one may match.
            for candidate in header.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard candidate.hasPrefix(hmac.prefix) else { continue }
                let encoded = String(candidate.dropFirst(hmac.prefix.count))
                let presented: Data?
                switch hmac.encoding {
                case .hex: presented = hexData(encoded)
                case .base64: presented = Data(base64Encoded: encoded)
                }
                if let presented, presented.count == expected.count, constantEqual(presented, expected) { return nil }
            }
            return .signature
        }
    }

    public static func mac(_ data: Data, secret: Data, algorithm: RCVHMAC.Algorithm) -> Data {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
    }

    static func constantEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    static func hexData(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.count <= 256 else { return nil }
        var out = Data(); var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte); index = next
        }
        return out
    }

    /// `203.0.113.7` or a range like `203.0.113.0/24` / `2001:db8::/32`.
    public static func allows(_ rule: String, _ address: String) -> Bool {
        let parts = rule.split(separator: "/", omittingEmptySubsequences: false)
        guard let network = bytes(String(parts[0])), let candidate = bytes(address.replacingOccurrences(of: "::ffff:", with: "")), network.count == candidate.count else { return false }
        let bits = parts.count == 2 ? Int(parts[1]) ?? -1 : network.count * 8
        guard bits >= 0, bits <= network.count * 8 else { return false }
        for i in 0..<network.count {
            let take = max(0, min(8, bits - i * 8))
            let mask: UInt8 = take == 0 ? 0 : UInt8(0xff) << (8 - take)
            if network[i] & mask != candidate[i] & mask { return false }
        }
        return true
    }

    static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
