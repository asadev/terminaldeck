import Foundation
import CryptoKit

public enum CloudSyncBytes {
  public static func md5(_ bytes: Data) -> String { Data(Insecure.MD5.hash(data: bytes)).base64EncodedString() }
  public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  public static func base64(_ bytes: Data) -> String { bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  public static func unbase64(_ string: String) throws -> Data {
    guard string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), string.count % 4 != 1,
      let bytes = Data(base64Encoded: string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - string.count % 4) % 4)), base64(bytes) == string else { throw CloudFailure.invalidRequest }
    return bytes
  }
  public static func uuid(_ value: String) throws -> Data {
    guard let id = UUID(uuidString: value), value.lowercased() == id.uuidString.lowercased() else { throw CloudFailure.invalidRequest }
    var raw = id.uuid
    return withUnsafeBytes(of: &raw) { Data($0) }
  }
  public static func transportID(_ value: String) throws {
    let bytes = try uuid(value)
    guard bytes[6] >> 4 == 4, bytes[8] >> 6 == 2 else { throw CloudFailure.invalidRequest }
  }
  public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
  public static func blob(_ bytes: Data, envelope: CloudContentEnvelope) -> CloudBlobRef {
    .init(blobId: envelope.blobId, sha256: hash(bytes), md5: Data(Insecure.MD5.hash(data: bytes)).base64EncodedString(), bytes: Int64(bytes.count), storageClass: envelope.storageClass, purpose: envelope.purpose, keyEpoch: envelope.epoch)
  }
  public static func verify(_ bytes: Data, ref: CloudBlobRef) throws {
    guard bytes.count <= CloudWire.maximumBlobBytes, Int64(bytes.count) == ref.bytes, hash(bytes) == ref.sha256,
      Data(Insecure.MD5.hash(data: bytes)).base64EncodedString() == ref.md5 else { throw CloudFailure.checksumMismatch }
  }
}

/// td-ops-1 is a canonical array. No timestamps take part in causal merging.
public enum CloudSyncPack {
  public static func encode(_ operations: [CloudOperation], maximumBytes: Int = CloudWire.maximumPlainChunkBytes) throws -> Data {
    try validate(operations)
    guard Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.invalidRequest }
    let bytes = try CloudSyncCanonical.encode(operations)
    guard bytes.count <= maximumBytes else { throw CloudFailure.invalidRequest }
    return bytes
  }
  public static func decode(_ bytes: Data) throws -> [CloudOperation] {
    let operations = try CloudWire.decode([CloudOperation].self, from: bytes, maximumBytes: CloudWire.maximumPlainChunkBytes)
    guard let raw = OrderedJSON.parse(bytes), let rows = raw.array, rows.count == operations.count else { throw CloudFailure.invalidRequest }
    for row in rows {
      guard let fields = row.fields, Set(fields.map(\.key)).isSubset(of: CloudFixtureSchema.requiredOperationKeys),
        let source = fields.first(where: { $0.key == "source" })?.value.fields,
        Set(source.map(\.key)).isSubset(of: ["sourceId", "recordId", "offset", "rawHash"]) else { throw CloudFailure.unsupportedFormat }
    }
    try validate(operations)
    guard Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.invalidRequest }
    return operations
  }
  /// Every check of `validate` except the payload's size and hash.
  public static func validateStructure(_ operations: [CloudOperation]) throws {
    var ids: [String: Data] = [:]
    for op in operations {
      guard op.v == 1 else { throw CloudFailure.unsupportedFormat }
      try CloudSyncBytes.transportID(op.opId)
      try CloudSyncBytes.transportID(op.originDevice)
      guard op.revision == op.opId, !op.parents.contains(op.revision), Set(op.parents).count == op.parents.count,
        !op.domain.isEmpty, op.domain.count <= 256, !op.entityId.isEmpty, op.entityId.count <= 256,
        !op.source.sourceId.isEmpty, !op.source.recordId.isEmpty,
        op.source.offset.map({ $0 >= 0 }) ?? true else { throw CloudFailure.invalidRequest }
      for parent in op.parents { try CloudSyncBytes.transportID(parent) }
      let bytes = try CloudSyncCanonical.encode(op)
      if let old = ids[op.opId], old != bytes { throw CloudFailure.idReused }
      ids[op.opId] = bytes
    }
  }
  public static func validate(_ operations: [CloudOperation]) throws {
    var ids: [String: Data] = [:]
    for op in operations {
      guard op.v == 1 else { throw CloudFailure.unsupportedFormat }
      try CloudSyncBytes.transportID(op.opId)
      try CloudSyncBytes.transportID(op.originDevice)
      guard op.revision == op.opId, !op.parents.contains(op.revision), Set(op.parents).count == op.parents.count,
        !op.domain.isEmpty, op.domain.count <= 256, !op.entityId.isEmpty, op.entityId.count <= 256,
        !op.source.sourceId.isEmpty, !op.source.recordId.isEmpty,
        op.source.offset.map({ $0 >= 0 }) ?? true else { throw CloudFailure.invalidRequest }
      for parent in op.parents { try CloudSyncBytes.transportID(parent) }
      guard try CloudSyncCanonical.encode(op.payload).count <= 65_536 else { throw CloudFailure.unsupportedFormat }
      guard CloudSyncBytes.hash(try CloudSyncCanonical.encode(op.payload)) == op.payloadHash else { throw CloudFailure.checksumMismatch }
      let bytes = try CloudSyncCanonical.encode(op)
      if let old = ids[op.opId], old != bytes { throw CloudFailure.idReused }
      ids[op.opId] = bytes
    }
  }
  /// Heads are a question about the causal graph only (ids, parents, same record), so they are computed from
  /// structure and never require payload content: the sync store keeps settled records as skeletons whose
  /// content is with the adapter (round 5 item B). Payload integrity is checked where content enters (packs).
  public static func heads(_ operations: [CloudOperation]) throws -> [CloudOperation] {
    try validateStructure(operations)
    let byID = Dictionary(operations.map { ($0.opId, $0) }, uniquingKeysWith: { a, _ in a })
    var waiting: [String: Int] = [:]
    var children: [String: [String]] = [:]
    for op in byID.values {
      waiting[op.opId] = 0
      for parent in op.parents {
        if let previous = byID[parent] {
          guard previous.domain == op.domain, previous.entityId == op.entityId else { throw CloudFailure.invalidRequest }
          waiting[op.opId, default: 0] += 1
          children[parent, default: []].append(op.opId)
        }
      }
    }
    // An iterative walk supports long retained revision histories without exhausting the call stack.
    var ready = waiting.keys.filter { waiting[$0] == 0 }, index = 0
    while index < ready.count {
      let id = ready[index]
      index += 1
      for child in children[id] ?? [] {
        waiting[child, default: 0] -= 1
        if waiting[child] == 0 { ready.append(child) }
      }
    }
    guard index == byID.count else { throw CloudFailure.invalidRequest }
    let parents = Set(operations.flatMap(\.parents))
    return byID.values.filter { !parents.contains($0.opId) }.sorted { $0.opId < $1.opId }
  }
}

public enum CloudSyncKillPoint: String, Sendable {
  case afterLocalWrite, afterUpload, afterFinalize, afterCommit, duringApply, duringJournalWrite
}
public typealias CloudSyncFault = @Sendable (CloudSyncKillPoint) throws -> Void
public typealias CloudSyncSigner = @Sendable (Data) async throws -> String
/// Signs for the named device registration with that registration's own key, and throws if this Mac
/// no longer holds it. The engine passes its current device id on every signature, so it cannot go stale.
public typealias CloudSyncDeviceSigner = @Sendable (_ deviceId: String, _ payload: Data) async throws -> String
/// Test seam only (the engine's internal initialisers): stands in for the trusted list. The app's engine checks
/// every signature itself under a key from this Mac's stored trusted list (`CloudDeviceTrustPort`).
public typealias CloudSyncSignatureVerifier = @Sendable (CloudSegmentDescriptor, String) async throws -> Void

enum CloudSyncSignatureCheck: Sendable { case valid, badKey, badSignature }

public extension CloudSegmentDescriptor {
  func syncSigningBytes(subject: String) throws -> Data {
    let value = try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(self))
    guard case .object(let fields) = value else { throw CloudFailure.invalidRequest }
    return try CloudSyncCanonical.encode(CloudValue(.object(fields.filter { $0.key != "signature" }))) + Data("\n\(subject)".utf8)
  }
}
extension CloudSegmentDescriptor {
  /// Whether this descriptor's signature is a P-256 signature by `key` over its signing bytes for this account.
  /// `key` is one this Mac stored on its own trusted list. Total: every failure is an answer, never a throw.
  func syncSignatureCheck(key jwk: CloudPublicJWK, subject: String) -> CloudSyncSignatureCheck {
    guard jwk.kty == "EC", jwk.crv == "P-256", let encodedY = jwk.y,
      let x = try? CloudSyncBytes.unbase64(jwk.x), let y = try? CloudSyncBytes.unbase64(encodedY), x.count == 32, y.count == 32,
      let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y) else { return .badKey }
    guard let raw = try? CloudSyncBytes.unbase64(signature), raw.count == 64,
      let proof = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
      let message = try? syncSigningBytes(subject: subject), key.isValidSignature(proof, for: message) else { return .badSignature }
    return .valid
  }
}

/// Local transfer state, never a wire error or a server field.
public enum CloudSyncTransferFailure: Error, Sendable {
  case uploadExpired, readExpired
}
