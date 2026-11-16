import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

/// A test device's signing identity: a real P-256 key, as every device makes for itself.
struct CloudSyncTestIdentity: Sendable {
  let deviceId: String
  let seed: UInt8
  func key() throws -> P256.Signing.PrivateKey { try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)) }
  func jwk() throws -> CloudPublicJWK {
    // x963: 04 || X (32) || Y (32)
    let raw = [UInt8](try key().publicKey.x963Representation)
    return CloudPublicJWK(kty: "EC", crv: "P-256", x: CloudSyncBytes.base64(Data(raw[1..<33])), y: CloudSyncBytes.base64(Data(raw[33..<65])))
  }
  func sign(_ payload: Data) throws -> String { CloudSyncBytes.base64(try key().signature(for: payload).rawRepresentation) }
}

/// This Mac's own stored trusted list in fixture form (lane A keeps the real one). Nothing here talks to the
/// fixture service: the list changes only when a test, standing in for the person's click, changes it.
actor CloudSyncFixtureTrust: CloudDeviceTrustPort {
  private var keys: [String: CloudPublicJWK]
  private var asked: [String] = []
  init(_ identities: [CloudSyncTestIdentity] = []) throws {
    var initial: [String: CloudPublicJWK] = [:]
    for identity in identities { initial[identity.deviceId] = try identity.jwk() }
    keys = initial
  }
  /// The person's trust click: the device's key is stored on this Mac.
  func trust(_ identity: CloudSyncTestIdentity) throws { keys[identity.deviceId] = try identity.jwk() }
  func store(_ deviceId: String, key: CloudPublicJWK) { keys[deviceId] = key }
  /// "Stop taking changes from this device".
  func stop(_ deviceId: String) { keys.removeValue(forKey: deviceId) }
  func askedFor() -> [String] { asked }
  /// The person's click lands in the middle of a pull: `identity` becomes trusted once the list has been asked
  /// about it `questions` more times.
  func trust(_ identity: CloudSyncTestIdentity, afterQuestions questions: Int) throws { pending[identity.deviceId] = (questions, try identity.jwk()) }
  private var pending: [String: (Int, CloudPublicJWK)] = [:]
  func trustedSigningKey(deviceId: String) async -> CloudPublicJWK? {
    asked.append(deviceId)
    if let (left, key) = pending[deviceId] {
      if left <= 0 { keys[deviceId] = key; pending[deviceId] = nil } else { pending[deviceId] = (left - 1, key) }
    }
    return keys[deviceId]
  }
}

extension CloudSyncTests {
  var thirdMac: String { "55555555-5555-4555-8555-555555555555" }
  /// An engine exactly as the app builds it: this Mac's trusted list, no verifier closure, no first upload.
  /// `adapter`: the same adapter again, for an engine started again on the same store (a restart).
  func trustEngine(root: URL, server: CloudSyncFixtureServer, identity: CloudSyncTestIdentity, trust: CloudSyncFixtureTrust,
                   adapter existing: CloudSyncFixtureAdapter? = nil,
                   fault: @escaping CloudSyncFault = { _ in }) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root)
    let adapter = try existing ?? CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    // The initialiser the app calls: a signer that follows the registration, and this Mac's trusted list.
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: identity.deviceId, epoch: 1, brainDomains: ["memory"],
      deviceSigner: { deviceId, payload in
        guard deviceId == identity.deviceId else { throw CloudFailure.unsafeConfiguration }
        return try identity.sign(payload)
      }, trust: trust, fault: fault)
    try await engine.register(adapter: adapter)
    return (engine, store, adapter)
  }
  /// The same for saved passwords: one adapter for the protected domain, `content` as the saved-password key port.
  /// `memory: false` builds it with NO memory domains (saved passwords alone).
  func trustProtectedEngine(root: URL, server: CloudSyncFixtureServer, identity: CloudSyncTestIdentity, trust: CloudSyncFixtureTrust,
                            content: CloudSyncProtectedFixtureContent, memory: Bool = true,
                            adapter existing: CloudSyncFixtureAdapter? = nil) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root)
    let adapter = try existing ?? CloudSyncFixtureAdapter(root: root.appendingPathComponent("protected"), domain: "api-key")
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: identity.deviceId, epoch: 1, brainDomains: memory ? ["memory"] : [], secretsDomains: ["api-key"], secretsContent: content,
      deviceSigner: { deviceId, payload in
        guard deviceId == identity.deviceId else { throw CloudFailure.unsafeConfiguration }
        return try identity.sign(payload)
      }, trust: trust)
    try await engine.register(adapter: adapter)
    return (engine, store, adapter)
  }
  /// A memory pack built by hand and signed with `identity`'s key (the signature covers the descriptor).
  func signedSegment(_ operations: [CloudOperation], by identity: CloudSyncTestIdentity) async throws -> CloudSegment {
    let base = try await reviewBrainSegment(operations)
    let d = base.descriptor
    let signature = try identity.sign(d.syncSigningBytes(subject: subject))
    return .init(descriptor: .init(segmentId: d.segmentId, requestId: d.requestId, storageClass: d.storageClass, purpose: d.purpose,
      domains: d.domains, keyEpoch: d.keyEpoch, sha256: d.sha256, bytes: d.bytes, opCount: d.opCount, format: d.format, signature: signature),
      ciphertext: base.ciphertext)
  }
  /// Commits `operations` to the fixture service as the device `identity`, signed with `signedBy`'s key
  /// (default: its own), then hands the fixture back to `then` (the device whose engine acts next).
  @discardableResult
  func commit(_ operations: [CloudOperation], as identity: CloudSyncTestIdentity, signedBy: CloudSyncTestIdentity? = nil,
              on server: CloudSyncFixtureServer, then: CloudSyncTestIdentity) async throws -> CloudSegment {
    let segment = try await signedSegment(operations, by: signedBy ?? identity)
    await server.switchDevice(identity.deviceId)
    _ = try await server.commit(segment)
    await server.switchDevice(then.deviceId)
    return segment
  }
}

/// Stops an engine at a chosen apply, like a crash at that point (the engine's `fault` hook).
final class CloudSyncTrustKillSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining = 0
  /// The `n`-th apply from now fails once, after the adapter applied and before the sync store recorded it.
  func failAtApply(_ n: Int) { lock.withLock { remaining = n } }
  func check(_ point: CloudSyncKillPoint) throws {
    try lock.withLock {
      guard point == .duringApply, remaining > 0 else { return }
      remaining -= 1
      if remaining == 0 { throw CloudFailure.unavailable }
    }
  }
}
