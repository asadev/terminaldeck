import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Private app/helper proof carrier. Tickets contain no authority: the attached
/// app retains the captured authoritative validator and consumes it once.
public enum BackendPCDecisionHostValidation {
    public enum Effect: String, Codable, Sendable { case spawn, input }
    public struct Envelope: Codable, Equatable, Sendable {
        public var sessionID: String
        public var reference: String
        public var digest: String
        public var host: UUID
        public var attachment: UUID
        public var spawn: UUID
        public var input: UUID?
    }
    struct Receipt: Codable, Equatable, Sendable {
        let envelope: Envelope
        let effect: Effect
        let ticket: UUID
    }
    @TaskLocal static var incoming: Envelope?
    private static let registry = Registry()
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var brokers: [UUID: WeakBroker] = [:]
    }
    final class WeakBroker: @unchecked Sendable {
        weak var value: Broker?
        init(_ value: Broker) { self.value = value }
    }
    final class Broker: @unchecked Sendable {
        final class Seal: @unchecked Sendable {
            let lock = NSLock()
            let expires: Date
            private var active = true
            init(expires: Date) { self.expires = expires }
            var valid: Bool { lock.withLock { active && expires > Date() } }
            func revoke() { lock.withLock { active = false } }
        }
        struct Pending: Sendable {
            let envelope: Envelope
            let effect: Effect
            let validate: @Sendable () async throws -> Void
            let expires: Date
            let seal: Seal
        }
        let host: UUID
        let attachment: UUID
        let current: @Sendable () -> UUID?
        let lock = NSLock()
        var pending: [UUID: Pending] = [:]
        var seals: [UUID: Seal] = [:]
        init(host: UUID, attachment: UUID, current: @escaping @Sendable () -> UUID?) {
            self.host = host; self.attachment = attachment; self.current = current
        }
        func issue(session: String, reference: String, digest: String, input: Bool,
                   validate: @escaping @Sendable () async throws -> Void) throws -> Envelope {
            guard current() == attachment, UUID(uuidString: session) != nil, !reference.isEmpty,
                  reference.utf8.count <= 16_384, !Task.isCancelled else { throw BackendPCDecisionHostValidation.held() }
            let value = Envelope(sessionID: session, reference: reference, digest: digest, host: host,
                                 attachment: attachment, spawn: UUID(), input: input ? UUID() : nil)
            try lock.withLock {
                pending = pending.filter { $0.value.expires > Date() }
                seals = seals.filter { $0.value.valid }
                guard pending.count < 256, seals.count < 128 else { throw BackendPCDecisionHostValidation.held() }
                let expiry = Date().addingTimeInterval(120)
                let seal = Seal(expires: expiry); seals[value.spawn] = seal
                pending[value.spawn] = Pending(envelope: value, effect: .spawn, validate: validate, expires: expiry, seal: seal)
                if let ticket = value.input { pending[ticket] = Pending(envelope: value, effect: .input, validate: validate, expires: expiry, seal: seal) }
            }
            return value
        }
        func revoke(_ envelope: Envelope) {
            lock.withLock {
                seals.removeValue(forKey: envelope.spawn)?.revoke()
                pending[envelope.spawn] = nil
                if let id = envelope.input { pending[id] = nil }
            }
        }
        @discardableResult
        func consume(_ value: Envelope, effect: Effect, cancellation: BackendMCPCancellation) async throws -> Receipt {
            let ticket = effect == .spawn ? value.spawn : value.input
            guard let ticket else { throw BackendPCDecisionHostValidation.held() }
            // Remove before the await: concurrent duplicate callbacks cannot both pass.
            let entry = lock.withLock { pending.removeValue(forKey: ticket) }
            guard let entry, entry.envelope == value, entry.effect == effect, entry.expires > Date(), entry.seal.valid,
                  current() == attachment, value.host == host, value.attachment == attachment,
                  !cancellation.isCancelled else { throw BackendPCDecisionHostValidation.held() }
            try Task.checkCancellation()
            try await entry.validate()
            try Task.checkCancellation()
            guard current() == attachment, !cancellation.isCancelled, entry.seal.valid else { throw BackendPCDecisionHostValidation.held() }
            return Receipt(envelope: value, effect: effect, ticket: ticket)
        }
    }
    static func register(client: BackendHOSTAppRelayClient) throws -> Broker {
        guard let attachment = client.attachmentID() else { throw BackendPCDecisionHostValidation.held() }
        let broker = Broker(host: client.hostIdentity.instance, attachment: attachment, current: { [weak client] in client?.attachmentID() })
        registry.lock.withLock {
            registry.brokers = registry.brokers.filter { $0.value.value != nil }
            registry.brokers[broker.host] = WeakBroker(broker)
        }
        return broker
    }
    static func issue(host: BackendHOSTProtocol.Hello, session: String, digest: String, input: Bool) throws -> Envelope? {
        guard BackendPCDecisionDelivery.required else { return nil }
        guard host.pcDecisionValidation == 1, let reference = BackendPCDecisionDelivery.hostedReference,
              let validate = BackendPCDecisionDelivery.validate,
              let broker = registry.lock.withLock({ registry.brokers[host.instance]?.value }) else { throw BackendPCDecisionHostValidation.held() }
        return try broker.issue(session: session, reference: reference, digest: digest, input: input, validate: validate)
    }
    static func revoke(_ envelope: Envelope?) {
        guard let envelope else { return }
        registry.lock.withLock { registry.brokers[envelope.host]?.value }?.revoke(envelope)
    }
    static func digest(method: String, payload: Data) -> String {
        var bytes = Data(method.utf8); bytes.append(0); bytes.append(payload)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func needsEffectValidation(_ method: String) -> Bool {
        guard method.hasPrefix("chats.") else { return false }
        return !["chats.inventory", "chats.read", "chats.job", "chats.turn", "chats.draft", "chats.queued",
                 "chats.handoff", "chats.stop", "chats.close", "chats.delete", "chats.remove", "chats.finish",
                 "chats.interrupt", "chats.child-stop", "chats.stopAll", "chats.open"].contains(method)
    }
    /// These owners call verifyFinal immediately before process start/input.
    /// Other provider controls need their own final hook before required work
    /// can use them; an app-local preparation check does not cover the effect.
    static func requireSupportedChatEffect(_ method: String, required: Bool) throws {
        guard !required || ["chats.launch", "chats.say", "chats.ensure"].contains(method) else {
            throw NativeRPCError(code: "decision-held", message: "This control has no final business-decision validation hook yet. Required task work is held.")
        }
    }
    private static var sortedEncoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    static func writeDigest(id: String, bytes: Data, expectedCreatedAt: Double?) throws -> String {
        struct Input: Encodable { let id: String; let bytes: Data; let expectedCreatedAt: Double? }
        return digest(method: "write", payload: try Self.sortedEncoder.encode(Input(id: id, bytes: bytes, expectedCreatedAt: expectedCreatedAt)))
    }
    static func launchDigest(_ launch: BackendHOSTProtocol.Launch) throws -> String {
        var clean = launch; clean.pcDecision = nil
        return digest(method: "create", payload: try Self.sortedEncoder.encode(clean))
    }
    static func arguments(_ value: Envelope, effect: Effect) throws -> NativeRPCValue {
        .object([.init("envelope", try NativeRPCValue.parseJSON(JSONEncoder().encode(value))), .init("effect", .string(effect.rawValue))])
    }
    static func decode(_ arguments: NativeRPCValue) throws -> (Envelope, Effect) {
        let envelope = try JSONDecoder().decode(Envelope.self, from: arguments["envelope"].encodedJSON())
        guard let effect = arguments["effect"].string.flatMap(Effect.init(rawValue:)) else { throw BackendPCDecisionHostValidation.held() }
        return (envelope, effect)
    }
    static func held() -> NativeRPCError { .init(code: "decision-held", message: "Fresh app decision validation is unavailable for this helper effect. Work is held.") }
}

/// Only decision attribution survives restart. Sealed callbacks and one-use
/// tickets never leave app memory; recovery therefore needs a fresh ticket.
final class BackendPCDecisionRequiredSessions: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private var bindings: [String: String]
    init(directory: URL) throws {
        file = directory.appendingPathComponent("decision-required-sessions.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 8 * 1024 * 1024 else { throw BackendPCDecisionHostValidation.held() }
            bindings = try JSONDecoder().decode([String: String].self, from: data)
            guard bindings.count <= 4_096, bindings.allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.isEmpty && $0.value.utf8.count <= 16_384 }) else {
                throw BackendPCDecisionHostValidation.held()
            }
        } else { bindings = [:] }
    }
    func contains(_ session: String) -> Bool { lock.withLock { bindings[session] != nil } }
    /// Review sessions-security #3: when full, bindings of sessions the helper no longer runs (`live`, read outside
    /// this lock) are dropped first. Session ids are never reused, so an ended session's binding guards nothing.
    func bind(session: String, reference: String, live: (() -> Set<String>)? = nil) throws {
        let full = lock.withLock { bindings[session] == nil && bindings.count >= 4_096 }
        let keep = full ? live?().union([session]) : nil
        try lock.withLock {
            let current = keep.map { keep in bindings.filter { keep.contains($0.key) } } ?? bindings
            guard UUID(uuidString: session) != nil, !reference.isEmpty, reference.utf8.count <= 16_384,
                  current[session] != nil || current.count < 4_096 else { throw BackendPCDecisionHostValidation.held() }
            if current.count == bindings.count, bindings[session] == reference { return }
            var next = current; next[session] = reference
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try BackendHOSTFiles.atomicWrite(encoder.encode(next), to: file)
            bindings = next
        }
    }
}
