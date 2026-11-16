import Foundation
import CryptoKit

/// The SEALED part of the shelf (owner, 15 Nov: "I want them to be in cloud as well ... every small thing to be synced
/// and in everywhere"). His saved passwords and project secret files go on the Cloud service's shelf so his signed-in
/// phones can show them with every Mac off, but sealed on the Mac with a key derived from the saved-passwords key,
/// which the service never holds. The service stores pieces it cannot open and cannot name; it sees only the outside:
/// account, kind, key generation, piece ids, sizes (padded) and counts.
///
/// Exact format (the phones implement the same; Security seat note 2026-11-15-secrets-everywhere.md, "FOR THE PHONES"):
/// - shelf root   = HKDF-SHA256(ikm: saved-passwords key (32 bytes), salt: empty, info: "TD-SHELF-SEALED-1\nroot\n<sub>\n<epoch>")
/// - piece key    = HKDF-SHA256(ikm: shelf root, salt: the piece id's 16 UUID bytes, info: "TD-SHELF-SEALED-1\n<kind>\n<role>\n<epoch>")
/// - AAD          = UTF-8 "TD-SHELF-SEALED-1\n<sub>\n<kind>\n<role>\n<epoch>\n<pieceId>"
/// - plaintext    = 4-byte big-endian length, the bytes, zeros up to the next size step (256 B, doubling, at most 256 KiB)
/// - AES-256-GCM, 12-byte random nonce, 16-byte tag; nonce, ciphertext and tag base64url without padding.
/// One piece opens by itself (the list in index pieces, each value in its own piece), so a phone opens only what he taps.
public enum CloudSecretsShelfSeal {
    public static let label = "TD-SHELF-SEALED-1"
    public static let suite = "A256GCM-HKDF-SHA256"
    /// The padded plaintext's largest size: one piece never passes the service's 256 KiB piece cap.
    public static let maximumPlainBytes = 262_144
    /// Index items per piece are cut so the JSON stays well under the cap.
    public static let indexPartBytes = 200_000

    /// The two sealed kinds. Saved MCP server sign-ins are saved passwords (domain `mcp`), so they are in `savedPasswords`.
    public enum Kind: String, Codable, Sendable, CaseIterable { case savedPasswords, projectSecretFiles }
    public enum Role: String, Codable, Sendable { case index, value }

    /// One sealed piece exactly as it is sent and stored. Every field here is all the service can see.
    public struct Piece: Codable, Equatable, Sendable {
        public let v: Int
        public let suite: String
        public let kind: Kind
        public let role: Role
        public let epoch: Int
        public let pieceId: String
        public let nonce: String
        public let ciphertext: String
        public let tag: String
    }

    // MARK: What is inside (never seen by the service)

    /// One saved password as the phone lists it: its name, what it is for, where (optional), when, and which labels its
    /// value piece holds. The values themselves are only in the value piece.
    public struct SavedPassword: Codable, Equatable, Sendable {
        public let ref: String
        public let name: String
        public let purpose: String
        public let place: String?
        public let changedAt: Int64?
        public let value: String
        public let valueBytes: Int
        public let labels: [String]
        enum CodingKeys: String, CodingKey { case ref, name, purpose = "for", place, changedAt, value, valueBytes, labels }
        public init(ref: String, name: String, purpose: String, place: String?, changedAt: Int64?, value: String, valueBytes: Int, labels: [String]) {
            self.ref = ref; self.name = name; self.purpose = purpose; self.place = place; self.changedAt = changedAt
            self.value = value; self.valueBytes = valueBytes; self.labels = labels
        }
    }
    /// One project secret file as the phone lists it. Its bytes are only in the value piece.
    public struct SecretFile: Codable, Equatable, Sendable {
        public let ref: String
        public let project: String
        public let file: String
        public let place: String
        public let changedAt: Int64?
        public let changedBy: String?
        public let sizeBytes: Int
        public let value: String
        public init(ref: String, project: String, file: String, place: String, changedAt: Int64?, changedBy: String?, sizeBytes: Int, value: String) {
            self.ref = ref; self.project = project; self.file = file; self.place = place; self.changedAt = changedAt
            self.changedBy = changedBy; self.sizeBytes = sizeBytes; self.value = value
        }
    }
    /// One field of a saved password's value (a password, a user name, a key). `secret` = hidden until he taps it.
    public struct Field: Codable, Equatable, Sendable {
        public let label: String
        public let value: String
        public let secret: Bool
        public init(label: String, value: String, secret: Bool) { self.label = label; self.value = value; self.secret = secret }
    }
    /// A saved password's value piece, inside the seal.
    public struct Value: Codable, Equatable, Sendable {
        public let v: Int
        public let fields: [Field]
        public init(fields: [Field]) { v = 1; self.fields = fields }
    }
    /// One index piece, inside the seal. All parts of one put share `putId`; `madeAt` lets a phone refuse an older list
    /// served back to it (a rolled-back shelf).
    public struct Index: Codable, Equatable, Sendable {
        public let v: Int
        public let kind: Kind
        public let putId: String
        public let part: Int
        public let parts: Int
        public let madeAt: Int64
        public let madeBy: String
        public let count: Int
        public let passwords: [SavedPassword]?
        public let files: [SecretFile]?
        public init(kind: Kind, putId: String, part: Int, parts: Int, madeAt: Int64, madeBy: String, count: Int,
                    passwords: [SavedPassword]? = nil, files: [SecretFile]? = nil) {
            v = 1; self.kind = kind; self.putId = putId; self.part = part; self.parts = parts; self.madeAt = madeAt
            self.madeBy = madeBy; self.count = count; self.passwords = passwords; self.files = files
        }
    }

    // MARK: Padding

    /// The size steps: 256, 512, ... 262,144 bytes. A short password and a long one look the same from outside.
    public static func step(_ size: Int) -> Int? {
        var step = 256
        while step < size { step *= 2 }
        return step <= maximumPlainBytes ? step : nil
    }
    public static func pad(_ bytes: Data) throws -> Data {
        guard let total = step(bytes.count + 4) else { throw CloudFailure.invalidRequest }
        let count = UInt32(bytes.count)
        var made = Data([UInt8(count >> 24 & 0xff), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])
        made.append(bytes)
        made.append(Data(count: total - made.count))
        return made
    }
    public static func unpad(_ padded: Data) throws -> Data {
        let raw = [UInt8](padded)
        guard raw.count >= 4, step(raw.count) == raw.count else { throw CloudFailure.unsupportedFormat }
        let count = Int(raw[0]) << 24 | Int(raw[1]) << 16 | Int(raw[2]) << 8 | Int(raw[3])
        guard count <= raw.count - 4, raw[(4 + count)...].allSatisfy({ $0 == 0 }) else { throw CloudFailure.unsupportedFormat }
        return Data(raw[4..<(4 + count)])
    }

    static func aad(sub: String, kind: Kind, role: Role, epoch: Int, pieceId: String) -> Data {
        Data("\(label)\n\(sub)\n\(kind.rawValue)\n\(role.rawValue)\n\(epoch)\n\(pieceId)".utf8)
    }
}

/// The shelf's sealer for one account and one key generation. Made by `CloudSecretsContent.shelfSealer(epoch:)` from the
/// saved-passwords key; it holds only the derived shelf root, never the key itself, and is never written anywhere.
public struct CloudSecretsShelfSealer: Sendable {
    public let sub: String
    public let epoch: Int
    private let shelfRoot: Data
    init(root: Data, sub: String, epoch: Int) throws {
        guard root.count == 32, epoch > 0 else { throw CloudFailure.invalidRequest }
        try CloudSecretsCrypto.validateSubject(sub)
        self.sub = sub; self.epoch = epoch
        shelfRoot = CloudSecretsCrypto.derive(root, salt: Data(), info: "\(CloudSecretsShelfSeal.label)\nroot\n\(sub)\n\(epoch)")
    }
    /// Fixtures and the phones' contract: the same sealer from a known key.
    public static func make(root: Data, sub: String, epoch: Int) throws -> CloudSecretsShelfSealer { try .init(root: root, sub: sub, epoch: epoch) }

    private func pieceKey(_ kind: CloudSecretsShelfSeal.Kind, _ role: CloudSecretsShelfSeal.Role, pieceId: String) throws -> Data {
        CloudSecretsCrypto.derive(shelfRoot, salt: try CloudSecretsCrypto.uuidBytes(pieceId),
                                  info: "\(CloudSecretsShelfSeal.label)\n\(kind.rawValue)\n\(role.rawValue)\n\(epoch)")
    }
    public func seal(_ bytes: Data, kind: CloudSecretsShelfSeal.Kind, role: CloudSecretsShelfSeal.Role, pieceId: String) throws -> CloudSecretsShelfSeal.Piece {
        try seal(bytes, kind: kind, role: role, pieceId: pieceId, nonce: CloudSecretsCrypto.random(12))
    }
    func seal(_ bytes: Data, kind: CloudSecretsShelfSeal.Kind, role: CloudSecretsShelfSeal.Role, pieceId: String, nonce: Data) throws -> CloudSecretsShelfSeal.Piece {
        guard UUID(uuidString: pieceId) != nil, pieceId == pieceId.lowercased() else { throw CloudFailure.invalidRequest }
        var plain = try CloudSecretsShelfSeal.pad(bytes)
        defer { plain.resetBytes(in: 0..<plain.count) }
        var key = try pieceKey(kind, role, pieceId: pieceId)
        defer { key.resetBytes(in: 0..<key.count) }
        let box = try CloudSecretsCrypto.seal(plain, key: key, aad: CloudSecretsShelfSeal.aad(sub: sub, kind: kind, role: role, epoch: epoch, pieceId: pieceId), nonce: nonce)
        return .init(v: 1, suite: CloudSecretsShelfSeal.suite, kind: kind, role: role, epoch: epoch, pieceId: pieceId,
                     nonce: box.nonce, ciphertext: box.ciphertext, tag: box.tag)
    }
    /// Opens one piece of THIS account and generation, of the expected kind and role. Anything else throws.
    public func open(_ piece: CloudSecretsShelfSeal.Piece, kind: CloudSecretsShelfSeal.Kind, role: CloudSecretsShelfSeal.Role) throws -> Data {
        guard piece.v == 1, piece.suite == CloudSecretsShelfSeal.suite, piece.kind == kind, piece.role == role, piece.epoch == epoch,
              UUID(uuidString: piece.pieceId) != nil else { throw CloudFailure.unsupportedFormat }
        var key = try pieceKey(kind, role, pieceId: piece.pieceId)
        defer { key.resetBytes(in: 0..<key.count) }
        let plain = try CloudSecretsCrypto.open(nonce: piece.nonce, ciphertext: piece.ciphertext, tag: piece.tag, key: key,
            aad: CloudSecretsShelfSeal.aad(sub: sub, kind: kind, role: role, epoch: epoch, pieceId: piece.pieceId))
        return try CloudSecretsShelfSeal.unpad(plain)
    }

    private var refKey: SymmetricKey { SymmetricKey(data: CloudSecretsCrypto.derive(shelfRoot, salt: Data(), info: "\(CloudSecretsShelfSeal.label)\nref")) }
    private func mac(_ text: String) -> [UInt8] { Array(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: refKey)) }
    /// The item's opaque reference inside the list: the same on every Mac of the account for the same item, says nothing.
    public func ref(kind: CloudSecretsShelfSeal.Kind, itemKey: String) -> String {
        mac("item\n\(kind.rawValue)\n\(itemKey)").prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    /// A value piece's id: the same for the same item and bytes (an unchanged value is never sent again), a new one when
    /// the value changes. Keyed, so the id tells the service nothing about the value.
    public func valueId(kind: CloudSecretsShelfSeal.Kind, itemKey: String, bytes: Data) -> String {
        var raw = Array(mac("value\n\(kind.rawValue)\n\(itemKey)\n" + CloudSecretsCrypto.hash(bytes)).prefix(16))
        raw[6] = raw[6] & 0x0f | 0x40
        raw[8] = raw[8] & 0x3f | 0x80
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
            .uuidString.lowercased()
    }
    /// A keyed fingerprint of one kind's whole sealed view (put again only when it changed). Holds no name or value.
    public func fingerprint(_ bytes: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("fingerprint\n".utf8) + bytes, using: refKey).map { String(format: "%02x", $0) }.joined()
    }
}

public extension CloudSecretsContent {
    /// The shelf's sealer, only while this Mac holds the saved-passwords key of `epoch` (locked = throws).
    func shelfSealer(epoch: Int) async throws -> CloudSecretsShelfSealer {
        let key = try await shelfKey(epoch: epoch)
        return try CloudSecretsShelfSealer(root: key.root, sub: key.subject.sub, epoch: epoch)
    }
}
