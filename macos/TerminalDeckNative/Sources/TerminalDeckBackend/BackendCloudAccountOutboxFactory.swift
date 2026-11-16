import Foundation
import TerminalDeckNativeCore

/// Account wiring only: defers constructing SYNC until registration/gate checks succeed.
/// Every queue, import, checkpoint and receipt is handled by the injected real SYNC port.
public actor BackendCloudAccountOutboxFactory: CloudOutboxPort {
    private let make: @Sendable () async throws -> any CloudOutboxPort
    private var value: (any CloudOutboxPort)?
    private var creating: Task<any CloudOutboxPort, Error>?
    /// nil until the account says whether the person paused sync (X3): the engine then only waits "starting up".
    private var paused: Bool?
    /// The resolved engine, readable without awaiting, for the synchronous service clock.
    private nonisolated let current = BackendCloudCurrentOutbox()
    public init(make: @escaping @Sendable () async throws -> any CloudOutboxPort) { self.make = make }
    /// The sync core's service-corrected time; nil until the engine exists and has learned an offset.
    public nonisolated func serviceTime() -> Int64? { current.get()?.serviceTime() }
    private func resolve() async throws -> any CloudOutboxPort {
        if let value { return value }
        if let creating { return try await creating.value }
        let task = Task {
            let candidate = try await make()
            return try await self.finish(candidate)
        }
        creating = task; defer { creating = nil }
        return try await task.value
    }
    private func finish(_ candidate: any CloudOutboxPort) async throws -> any CloudOutboxPort {
        value = candidate
        do {
            if let paused { try await candidate.setPaused(paused) } else { try await candidate.holdForStartup() }
            current.set(candidate); return candidate
        }
        catch { value = nil; current.set(nil); throw error }
    }
    public func setPaused(_ paused: Bool) async throws {
        self.paused = paused
        if let value { try await value.setPaused(paused) }
    }
    /// MAC-NEXT-7 (2): forwarded, never turned into a pause by the person (the default would store `paused`).
    public func holdForStartup() async throws {
        paused = nil
        if let value { try await value.holdForStartup() }
    }
    public func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt { try await resolve().enqueue(operations, files: files) }
    public func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation]) async throws -> CloudLocalReceipt {
        try await resolve().enqueue(operations, files: files, associations: associations)
    }
    public func coverage(sourceId: String) async throws -> CloudCoverage { try await resolve().coverage(sourceId: sourceId) }
    public func flush() async throws -> [CloudReceipt] { try await resolve().flush() }
    public func restoreProgress() async throws -> CloudRestoreProgress { try await resolve().restoreProgress() }
    public func contextReady(projectId: String) async throws -> CloudContextReady { try await resolve().contextReady(projectId: projectId) }
    public func register(adapter: any CloudDomainAdapter) async throws { try await resolve().register(adapter: adapter) }
    public func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { try await resolve().bootstrap(snapshots) }
    public func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { try await resolve().bootstrap(sources: sources, cut: cut) }
    public func pull() async throws -> [CloudImportReceipt] { try await resolve().pull() }
    public func syncNow() async throws { try await resolve().syncNow() }
    // Sync review round 5 S9: every port addition reaches the engine; the defaults would refuse, do nothing or say nil.
    public func abandonUnpublishedSetup() async throws { try await resolve().abandonUnpublishedSetup() }
    public func retryParked(domains: Set<String>) async throws { try await resolve().retryParked(domains: domains) }
    public func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt? { try await resolve().cloudReceipt(operationId: operationId) }
    public func outboxIdentity() async throws -> String { try await resolve().outboxIdentity() }
    public func contextReady(projectId: String, sources: Set<String>) async throws -> CloudContextReady {
        try await resolve().contextReady(projectId: projectId, sources: sources)
    }
    // Device trust (SYNC contract b8a72011) and retired saved-password records (eb06095e): all reach the engine.
    // The defaults would say "nothing waits" and refuse the three actions.
    public func heldDevices() async throws -> [CloudHeldDevice] { try await resolve().heldDevices() }
    /// The contents page reads; it never builds the sync core: before it exists nothing is known.
    public func contents(limit: Int) async throws -> CloudSyncContents { try await value?.contents(limit: limit) ?? .empty }
    public func refreshCoverage() async throws { try await value?.refreshCoverage() }
    public func trustDevice(deviceId: String, signKey: CloudPublicJWK) async throws -> [CloudImportReceipt] {
        try await resolve().trustDevice(deviceId: deviceId, signKey: signKey)
    }
    public func releaseHeld(deviceIds: [String]) async throws -> [CloudImportReceipt] { try await resolve().releaseHeld(deviceIds: deviceIds) }
    public func refusedPacks() async throws -> [CloudRefusedPack] { try await resolve().refusedPacks() }
    public func checkRefusedAgain(sequence: CloudSequence?) async throws -> [CloudImportReceipt] { try await resolve().checkRefusedAgain(sequence: sequence) }
    public func baselineProgress() async throws -> CloudBaselineProgress? { try await resolve().baselineProgress() }
    public func waitingBeyondList() async throws -> Int { try await resolve().waitingBeyondList() }
    public func refusedBeyondList() async throws -> Int { try await resolve().refusedBeyondList() }
    public func retiredRecords() async throws -> [CloudRetiredRecord] { try await resolve().retiredRecords() }
    public func confirmRetired(operationIds: [String]) async throws { try await resolve().confirmRetired(operationIds: operationIds) }
}

/// Ephemeral B-key cache. The provider is the existing authenticated transport; no key file or new vault exists.
public actor BackendCloudAccountBrainKeys {
    private let fetch: @Sendable (Int) async throws -> Data
    private var keys: [Int:Data] = [:]
    private var generation = 0
    private var fetching: [Int:Task<Data,Error>] = [:]
    public init(fetch: @escaping @Sendable (Int) async throws -> Data) { self.fetch = fetch }
    public func key(epoch: Int) async throws -> Data {
        guard epoch > 0 else { throw CloudFailure.invalidRequest }
        if let key = keys[epoch] { return key }
        let version = generation
        let task: Task<Data,Error>
        if let existing = fetching[epoch] { task = existing }
        else { task = Task { try await fetch(epoch) }; fetching[epoch] = task }
        do {
            let key = try await task.value
            guard key.count == 32, generation == version else { throw CloudFailure.gateClosed }
            keys[epoch] = key; fetching[epoch] = nil; return key
        } catch {
            if generation == version { fetching[epoch] = nil }
            throw error
        }
    }

    public func discard() { generation += 1; keys.removeAll(); fetching.values.forEach { $0.cancel() }; fetching.removeAll() }
}

/// Lock-protected handle so a nonisolated, synchronous read (the service clock) can reach the resolved engine.
final class BackendCloudCurrentOutbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any CloudOutboxPort)?
    func get() -> (any CloudOutboxPort)? { lock.withLock { value } }
    func set(_ next: (any CloudOutboxPort)?) { lock.withLock { value = next } }
}
