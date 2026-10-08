import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// A source's private values. Never leaves the store except to the owner's own screen.
public struct BackendRCVSecrets: Codable, Equatable, Sendable {
    public var secret: String
    /// The credential replies are sent with (e.g. a Whapi API token). Optional.
    public var reply: String?
    public init(secret: String, reply: String? = nil) { self.secret = secret; self.reply = reply }
}

/// Everything the Receiver keeps, encrypted as one record with the app's safe-storage cipher.
public struct BackendRCVState: Codable, Equatable, Sendable {
    public var version = 1
    /// Raw X25519 private key every relay delivery is sealed to.
    public var receiverKey: Data
    public var sources: [RCVSource] = []
    public var secrets: [String: BackendRCVSecrets] = [:]
    public var rules: [RCVRule] = []
    /// Oldest first.
    public var events: [RCVEvent] = []
    /// Sender ids already seen ("source|id" → when).
    public var seen: [String: Double] = [:]
    /// Relay delivery ids already stored (replay protection on the relay wire).
    public var deliveries: [String: Double] = [:]
    public var memory = RCVRouterMemory()
    /// "rule|conversation key" → the ongoing task.
    public var threads: [String: String] = [:]
    public var customPresets: [RCVPreset] = []
    /// Digests of replies we sent recently, so their echo is not routed back to an agent.
    public var sentReplies: [String: Double] = [:]
    public init(receiverKey: Data) { self.receiverKey = receiverKey }
}

public actor BackendRCVStore {
    public static let fileName = "receiver.json"
    public static let maxEvents = 1_000, maxRawEvents = 200, maxRawBytes = 6 * 1024 * 1024, maxPlainBytes = 16 * 1024 * 1024

    private let persistence: BackendTaskPersistence?
    private let cipher: (any BackendAccountVaultCipher)?
    private var state: BackendRCVState
    /// The last state known to be on disk. A failed save puts this back, so nothing unsaved is ever acknowledged.
    private var persisted: BackendRCVState
    private var started = false
    private var saving: Task<Void, Error>?
    private var dirty = false
    private let delayMilliseconds: Int

    /// Set when the store could not even be placed (its folder); `start` reports it.
    private let failure: String?

    /// `persistence`/`cipher` nil keeps everything in memory (tests and previews).
    public init(persistence: BackendTaskPersistence?, cipher: (any BackendAccountVaultCipher)?, saveDelayMilliseconds: Int = 250, failure: String? = nil) {
        self.persistence = persistence; self.cipher = cipher; delayMilliseconds = saveDelayMilliseconds; self.failure = failure
        state = BackendRCVState(receiverKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        persisted = state
    }

    public func start() throws {
        guard !started else { return }
        if let failure { throw NativeRPCError(code: "receiver-unavailable", message: failure) }
        if let persistence, let record = try persistence.read(Self.fileName, maximumBytes: Self.maxPlainBytes * 2) {
            guard record["version"].number == 1, let blob = record["encrypted"].string.flatMap({ Data(base64Encoded: $0) }) else {
                throw NativeRPCError.malformed("The Receiver's saved data cannot be read.")
            }
            guard let cipher, cipher.available() else { throw Self.unavailable() }
            let plain: String
            do { plain = try cipher.decrypt(blob) } catch { throw Self.unavailable(error) }
            guard plain.utf8.count <= Self.maxPlainBytes else { throw NativeRPCError.malformed("The Receiver's saved data is too large.") }
            let next = try JSONDecoder().decode(BackendRCVState.self, from: Data(plain.utf8))
            guard next.version == 1, next.receiverKey.count == 32 else { throw NativeRPCError.malformed("The Receiver's saved data has an unknown version.") }
            state = next
        }
        persisted = state
        started = true
    }

    public func read() throws -> BackendRCVState { try requireStarted(); return state }

    /// Add what is rebuilt on every start (Terminal Deck's own sources) without saving:
    /// a brand-new Receiver touches the Keychain only on its first real save.
    public func seed(_ change: @Sendable (inout BackendRCVState) -> Void) throws {
        try requireStarted(); change(&state); change(&persisted)
    }

    /// Change the state; the change is saved before `update` returns (coalesced with others close in time).
    @discardableResult
    public func update<T: Sendable>(_ change: @Sendable (inout BackendRCVState) throws -> T) async throws -> T {
        try requireStarted()
        var next = state
        let result = try change(&next)
        Self.bound(&next, now: Date().timeIntervalSince1970 * 1000)
        state = next
        try await save()
        return result
    }

    /// Keep the record small: newest events, raw payloads only on the newest, old memories forgotten.
    static func bound(_ state: inout BackendRCVState, now: Double) {
        if state.events.count > maxEvents { state.events.removeFirst(state.events.count - maxEvents) }
        var rawBytes = 0
        for index in state.events.indices.reversed() {
            let fromNewest = state.events.count - 1 - index
            rawBytes += state.events[index].raw.count
            if fromNewest >= maxRawEvents || rawBytes > maxRawBytes, state.events[index].raw.count > 2 {
                state.events[index].raw = Data("{}".utf8)
            }
        }
        state.seen = state.seen.filter { $0.value > now - 7 * 86_400_000 }
        if state.seen.count > 5_000 { state.seen = Dictionary(uniqueKeysWithValues: state.seen.sorted { $0.value > $1.value }.prefix(5_000).map { ($0.key, $0.value) }) }
        state.deliveries = state.deliveries.filter { $0.value > now - 4 * 86_400_000 }
        if state.deliveries.count > 4_000 { state.deliveries = Dictionary(uniqueKeysWithValues: state.deliveries.sorted { $0.value > $1.value }.prefix(4_000).map { ($0.key, $0.value) }) }
        state.sentReplies = state.sentReplies.filter { $0.value > now - 600_000 }
        if state.threads.count > 2_000 { state.threads = Dictionary(uniqueKeysWithValues: state.threads.sorted { $0.key < $1.key }.suffix(2_000).map { ($0.key, $0.value) }) }
    }

    private func save() async throws {
        guard persistence != nil else { return }
        dirty = true
        if let saving { try await saving.value; if !dirty { return } }
        let task = Task { [delayMilliseconds] in
            if delayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(delayMilliseconds)) }
            try self.commit()
        }
        saving = task
        defer { if saving == task { saving = nil } }
        try await task.value
    }

    private func commit() throws {
        guard persistence != nil else { return }
        dirty = false
        let snapshot = state
        do { try write(snapshot); persisted = snapshot } catch { state = persisted; throw error }
    }

    private func write(_ state: BackendRCVState) throws {
        guard let persistence else { return }
        try persistence.writable()
        guard let cipher, cipher.available() else { throw Self.unavailable() }
        let plain = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        guard plain.utf8.count <= Self.maxPlainBytes else { throw NativeRPCError(code: "receiver-full", message: "The Receiver's saved data is too large.") }
        let exists = try persistence.read(Self.fileName, maximumBytes: Self.maxPlainBytes * 2) != nil
        let blob: Data
        do { blob = try cipher.encrypt(plain, existingVault: exists) } catch { throw Self.unavailable(error) }
        try persistence.write(Self.fileName, value: .object([.init("version", .number(1)), .init("encrypted", .string(blob.base64EncodedString()))]))
    }

    private func requireStarted() throws { guard started else { throw NativeRPCError(code: "unavailable", message: "The Receiver has not started.") } }
    static func unavailable(_ cause: Error? = nil) -> NativeRPCError {
        let reason = (cause as? LocalizedError)?.errorDescription ?? (cause as? NativeRPCError)?.message
        return .init(code: "secure-store-unavailable", message: "The Receiver's secure storage is unavailable" + (reason.map { ": " + $0 } ?? ".") + " Nothing was changed.")
    }
}
