import Foundation
import CryptoKit
import TerminalDeckNativeCore

public struct BackendDeckCoreSecurityGrant: Sendable {
    public let identity: String
    public let attended: Bool
    public let tools: Set<String>?
    public let cancellation: BackendMCPCancellation
    public let caller: @Sendable () async -> BackendDeckCoreSecurityCaller
    public let events: (any BackendDeckCoreSecurityEvents)?
    public let keyID: String?
    public let via: String?
    public let noteClient: @Sendable (String?) async -> Void
    public let done: @Sendable () async -> Void
    public init(identity: String = UUID().uuidString, attended: Bool, tools: Set<String>? = nil, cancellation: BackendMCPCancellation = .init(),
                caller: @escaping @Sendable () async -> BackendDeckCoreSecurityCaller,
                events: (any BackendDeckCoreSecurityEvents)? = nil, keyID: String? = nil, via: String? = nil,
                noteClient: @escaping @Sendable (String?) async -> Void = { _ in }, done: @escaping @Sendable () async -> Void = {}) {
        self.identity = identity; self.attended = attended; self.tools = tools; self.cancellation = cancellation; self.caller = caller
        self.events = events; self.keyID = keyID; self.via = via; self.noteClient = noteClient; self.done = done
    }
}

/// Per-run table. Digest comparison always visits every entry, keeping the first match.
public actor BackendDeckCoreSecurityCallerTable {
    private struct Entry: Sendable { let id: UUID; let digest: Data; let grant: BackendDeckCoreSecurityGrant }
    private var entries: [Entry] = []
    public init() {}
    @discardableResult public func set(token: String, grant: BackendDeckCoreSecurityGrant) throws -> UUID {
        guard !token.isEmpty else { throw NativeRPCError.invalidArguments("deck-control: refusing to register an empty token") }
        let digest = Self.digest(token)
        if let index = entries.firstIndex(where: { BackendRemoteTrustStorage.equal($0.digest, digest) }) {
            let id = entries[index].id; entries[index] = Entry(id: id, digest: digest, grant: grant); return id
        }
        let id = UUID(); entries.append(Entry(id: id, digest: digest, grant: grant)); return id
    }
    @discardableResult public func delete(token: String) -> Bool {
        let digest = Self.digest(token); guard let index = entries.firstIndex(where: { BackendRemoteTrustStorage.equal($0.digest, digest) }) else { return false }
        entries.remove(at: index).grant.cancellation.cancel(); return true
    }
    @discardableResult public func revoke(_ registration: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == registration }) else { return false }
        entries.remove(at: index).grant.cancellation.cancel(); return true
    }
    public func size() -> Int { entries.count }
    public func clear() { for entry in entries { entry.grant.cancellation.cancel() }; entries.removeAll() }
    public func match(authorization: String?) -> BackendDeckCoreSecurityGrant? {
        guard let authorization else { return nil }
        let offered = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : authorization
        guard !offered.isEmpty else { return nil }
        let digest = Self.digest(offered); var found: BackendDeckCoreSecurityGrant?
        for entry in entries {
            let matches = BackendRemoteTrustStorage.equal(digest, entry.digest)
            if matches && found == nil { found = entry.grant }
        }
        return found
    }
    private nonisolated static func digest(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    public nonisolated static func bearerOf(_ header: String?) -> String? {
        guard var value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let range = value.range(of: #"^bearer\s+"#, options: [.regularExpression, .caseInsensitive]) { value.removeSubrange(range) }
        return value.isEmpty ? nil : value
    }
}

/// Both loopback and the relay use this exact persistent-key door.
public final class BackendDeckCoreSecurityAccessKeyDoor: @unchecked Sendable {
    private struct Flight { let id: UUID; let keyID: String; let via: String; let cancellation: BackendMCPCancellation }
    public let keys: BackendDeckCoreSecurityAccessKeys
    private let consent: BackendDeckCoreSecurityConsentBroker?
    private let events: (@Sendable () async -> (any BackendDeckCoreSecurityEvents)?)?
    private let lock = NSLock()
    private var flights: [UUID: Flight] = [:]
    private var stopped = false
    private var watcher: UUID?
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    public init(keys: BackendDeckCoreSecurityAccessKeys, consent: BackendDeckCoreSecurityConsentBroker? = nil,
                events: (@Sendable () async -> (any BackendDeckCoreSecurityEvents)?)? = nil) {
        self.keys = keys; self.consent = consent; self.events = events
    }
    /// Install once during composition; no network request opens the door implicitly.
    public func activate() async {
        let install = lock.withLock { watcher == nil && !stopped }
        guard install else { return }
        let id = await keys.onAuthorityChange { [weak self] ids, internet in self?.reconcile(ids: ids, internet: internet) }
        let keep = lock.withLock { if stopped || watcher != nil { return false }; watcher = id; return true }
        if !keep { await keys.removeObserver(id) }
    }
    public func grant(credential: String?, via: String, userAgent: String? = nil,
                      external: BackendMCPCancellation? = nil) async -> BackendDeckCoreSecurityGrant? {
        guard ["this-mac", "internet"].contains(via), lock.withLock({ !stopped && watcher != nil }) else { return nil }
        let internetAtArrival = await keys.internet()
        if via == "internet" && !internetAtArrival { return nil }
        guard let key = await keys.match(credential), key["crmOnly"].bool != true,
              let keyID = key["id"].string, let name = key["name"].string else { return nil }
        let cancellation = BackendMCPCancellation(); let id = UUID()
        let flight = Flight(id: id, keyID: keyID, via: via, cancellation: cancellation)
        let accepted = lock.withLock { if stopped { return false }; flights[id] = flight; return true }
        guard accepted else { return nil }
        var externalWatch: UUID?
        if let external { externalWatch = external.observe { cancellation.cancel() } }
        let label: String? = key["lastApp"].isNullish ? userAgent.flatMap { BackendDeckCoreSecurityAccessKeys.cleanAppLabel($0.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespacesAndNewlines).first) } : nil
        await keys.noteUsed(id: keyID, via: via, app: label)
        let service = await events?()
        // Actor lookups suspend; close the grant if a revoke raced its registration.
        let current = await keys.get(id: keyID)
        let internetNow = await keys.internet()
        let roadOpen = via != "internet" || internetNow
        guard current != nil, roadOpen, !cancellation.isCancelled else {
            finish(id); if let externalWatch { external?.removeObserver(externalWatch) }; return nil
        }
        let observer = externalWatch
        return BackendDeckCoreSecurityGrant(identity: "key:" + keyID, attended: true, cancellation: cancellation,
            caller: { [keys] in await keys.caller(id: keyID, nameAtArrival: name) }, events: service, keyID: keyID, via: via,
            noteClient: { [keys] client in if let client { await keys.noteUsed(id: keyID, via: via, app: client) } },
            done: { [weak self] in self?.finish(id); if let observer { external?.removeObserver(observer) } })
    }
    public func onChange(_ listener: @escaping @Sendable () -> Void) -> UUID { lock.withLock { let id = UUID(); listeners[id] = listener; return id } }
    public func removeObserver(_ id: UUID) { lock.withLock { listeners[id] = nil } }
    public func serving() async -> Bool { let internet = await keys.internet(); return lock.withLock({ !stopped && watcher != nil }) && internet }
    public func inFlightCount(keyID: String? = nil) -> Int { lock.withLock { flights.values.filter { keyID == nil || $0.keyID == keyID }.count } }
    public func stop() async {
        let values = lock.withLock { () -> (UUID?, [Flight], [@Sendable () -> Void]) in
            stopped = true; let id = watcher; watcher = nil; let values = Array(flights.values); flights.removeAll(); return (id, values, Array(listeners.values))
        }
        if let id = values.0 { await keys.removeObserver(id) }
        for flight in values.1 { flight.cancellation.cancel() }
        for listener in values.2 { listener() }
    }
    private func finish(_ id: UUID) { lock.withLock { flights[id] = nil } }
    private func reconcile(ids: Set<String>, internet: Bool) {
        let values = lock.withLock { (Array(flights.values), Array(listeners.values)) }
        var gone: Set<String> = []
        for flight in values.0 {
            if !ids.contains(flight.keyID) { flight.cancellation.cancel(); gone.insert(flight.keyID) }
            else if !internet && flight.via == "internet" { flight.cancellation.cancel() }
        }
        if let consent { for keyID in gone { Task { try? await consent.callerGone("key:" + keyID) } } }
        for listener in values.1 { listener() }
    }
}
