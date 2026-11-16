import Foundation

/// Logical values supplied by an existing store owner. No provider home or live process is opened here.
public struct CloudBrainAgentsRecord: Sendable, Equatable {
  public let domain: String
  public let id: String
  public let value: CloudValue
  public let projectID: String?
  public let rootID: String?
  public init(domain: String, id: String, value: NativeRPCValue, projectID: String? = nil, rootID: String? = nil) {
    self.domain = domain; self.id = id; self.value = CloudValue(value)
    self.projectID = projectID; self.rootID = rootID
  }
  public var key: String { domain + ":" + id }
  /// Match the authoritative writer's JSON representation: native byte values survive as $bytes and omitted fields stay omitted.
  public func persistedValue() throws -> CloudValue { CloudValue(try NativeRPCValue.parseJSON(value.raw.encodedJSON())) }
}

public struct CloudBrainAgentsExport: Sendable {
  public let operations: [CloudOperation]
  public let coverage: [CloudCoverage]
  public init(operations: [CloudOperation], coverage: [CloudCoverage]) { self.operations = operations; self.coverage = coverage }
}

/// All closures are provided by store owners, already bound to one Cloud account (design D3).
/// No default writer, network sender, scheduler or launcher exists.
public struct CloudBrainAgentsOwnerPort: Sendable {
  /// Read only: counts what the owner holds now; never captures or writes (finding 14).
  public let inventory: @Sendable () async throws -> [CloudCoverage]
  /// Captures from what the owner actually wrote (its files), then returns this device's own revisions only.
  public let snapshot: @Sendable (CloudSnapshotCut) async throws -> CloudBrainAgentsExport
  public let apply: @Sendable ([CloudOperation]) async throws -> [CloudItemResult]
  public let retained: @Sendable ([CloudOperation]) async throws -> Bool
  public let ownChanges: @Sendable (String?, Int) async throws -> [CloudOperation]
  public let cursor: @Sendable () async throws -> String?
  public let saveCursor: @Sendable (String) async throws -> Void
  public let notices: @Sendable () async -> AsyncStream<Void>
  public let detach: @Sendable () async -> Void
  public init(inventory: @escaping @Sendable () async throws -> [CloudCoverage],
              snapshot: @escaping @Sendable (CloudSnapshotCut) async throws -> CloudBrainAgentsExport,
              apply: @escaping @Sendable ([CloudOperation]) async throws -> [CloudItemResult],
              retained: @escaping @Sendable ([CloudOperation]) async throws -> Bool,
              ownChanges: @escaping @Sendable (String?, Int) async throws -> [CloudOperation],
              cursor: @escaping @Sendable () async throws -> String?,
              saveCursor: @escaping @Sendable (String) async throws -> Void,
              notices: @escaping @Sendable () async -> AsyncStream<Void>,
              detach: @escaping @Sendable () async -> Void) {
    self.inventory = inventory; self.snapshot = snapshot; self.apply = apply; self.retained = retained
    self.ownChanges = ownChanges; self.cursor = cursor; self.saveCursor = saveCursor; self.notices = notices; self.detach = detach
  }
}

public actor CloudBrainAgentsAdapter: CloudDomainAdapter {
  public nonisolated let inventoryRows: [String]
  public nonisolated let domains: Set<String>
  public nonisolated let owner: CloudBrainAgentsOwnerPort
  private var verification: [String: (receipt: CloudImportReceipt, operations: [CloudOperation])] = [:]
  public init(row: String, domains: Set<String>, owner: CloudBrainAgentsOwnerPort) {
    inventoryRows = [row]; self.domains = domains; self.owner = owner
  }
  public func sourceInventory() async throws -> [CloudSourceInventory] {
    let coverage = try await owner.inventory()
    return coverage.map { .init(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow,
      domain: domains.sorted().joined(separator: ","), items: $0.items, bytes: $0.bytes, complete: $0.complete, blockedReasons: $0.blockedReasons) }
  }
  public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
    let value = try await owner.snapshot(cut)
    for op in value.operations { try CloudBrainAgentsLedger.check(op, domains: domains) }
    return .init(cut: cut, operations: value.operations, files: [], coverage: value.coverage)
  }
  /// Live feed of this device's own revisions after `after`. Imported revisions are never re-sent (D3).
  public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
    let owner = owner
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let notices = await owner.notices()
          var iterator = notices.makeAsyncIterator()
          var cursor = after
          while !Task.isCancelled {
            while true {
              let page = try await owner.ownChanges(cursor, 64)
              for op in page { continuation.yield(op) }
              guard let last = page.last else { break }
              cursor = last.opId
            }
            if await iterator.next() == nil { break }
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  /// Syntactic check only. Domain validation is per record at apply time and never fails the batch (finding 15).
  public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
    guard files.isEmpty else { throw CloudFailure.unsupportedFormat }
    var seen: [String: CloudOperation] = [:]
    for op in operations {
      try CloudBrainAgentsLedger.check(op, domains: domains)
      if let old = seen[op.opId], old != op { throw CloudFailure.idReused }
      seen[op.opId] = op
    }
    let id = try CloudConversationIdentity.uuid(["A2-logical-prepare", inventoryRows[0], domains.sorted().joined(separator: ","),
      CloudSyncBytes.hash(CloudSyncCanonical.encode(operations))])
    return .init(preparationId: id, operations: operations, files: [])
  }
  public func applyPrepared(_ input: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
    let checked = try await validateIncoming(input.operations, files: input.files)
    guard checked.preparationId == input.preparationId else { throw CloudFailure.invalidRequest }
    let results = try await owner.apply(input.operations)
    guard results.count == input.operations.count, zip(results, input.operations).allSatisfy({ $0.entityId == $1.entityId }),
      !results.contains(where: { $0.status == .blocked }), try await owner.retained(input.operations) else { throw CloudFailure.unavailable }
    let receipt = CloudImportReceipt(preparationId: input.preparationId, inventoryRow: inventoryRows[0], results: results,
      counts: .init(domains: Set(input.operations.map(\.domain)).count, records: Set(input.operations.map(\.opId)).count,
        files: 0, bytes: try input.operations.reduce(Int64(0)) { $0 + Int64(try CloudSyncCanonical.encode($1.payload).count) }, blocked: 0))
    verification[input.preparationId] = (receipt, input.operations)
    return receipt
  }
  public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
    guard let retained = verification[receipt.preparationId], retained.receipt == receipt else { throw CloudFailure.invalidRequest }
    let verified = try await owner.retained(retained.operations)
    if verified { verification[receipt.preparationId] = nil }
    return .init(verified: verified, counts: receipt.counts, reasons: verified ? [] : ["Imported revisions could not be read back."])
  }
}

/// Moves one owner's own revisions into SYNC's durable outbox. The saved cursor advances only after a LocalReceipt.
/// No network, timer or second data writer; the next owner change (or an explicit retry) drains again.
public actor CloudBrainAgentsPump {
  private let owner: CloudBrainAgentsOwnerPort
  private let outbox: any CloudOutboxPort
  private var task: Task<Void, Never>?
  private var draining = false
  public private(set) var problem = false
  public init(adapter: CloudBrainAgentsAdapter, outbox: any CloudOutboxPort) { owner = adapter.owner; self.outbox = outbox }
  @discardableResult public func drainOnce(limit: Int = 64) async throws -> Int {
    guard !draining else { throw CloudFailure.unavailable }
    draining = true; defer { draining = false }
    let cursor = try await owner.cursor()
    let operations = try await owner.ownChanges(cursor, limit)
    guard let last = operations.last else { return 0 }
    let receipt = try await outbox.enqueue(operations, files: [])
    guard Set(receipt.operationIds) == Set(operations.map(\.opId)) else { throw CloudFailure.checksumMismatch }
    try await owner.saveCursor(last.opId)
    problem = false
    return operations.count
  }
  public func start() async {
    guard task == nil else { return }
    let notices = await owner.notices() // subscribe before the first read
    task = Task {
      var iterator = notices.makeAsyncIterator()
      while !Task.isCancelled {
        do { while try await drainOnce() > 0 { try Task.checkCancellation() } }
        catch { problem = true }
        if await iterator.next(isolation: self) == nil { break }
      }
    }
  }
  /// Sign-out: stop draining and stop the owner capturing into this account (D3).
  public func stop() async {
    task?.cancel(); task = nil
    await owner.detach()
  }
}
