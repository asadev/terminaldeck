import Foundation
import TerminalDeckNativeCore

public actor BackendCloudConversationAdapter: CloudDomainAdapter {
  public nonisolated let inventoryRows: [String]
  private let roots: [CloudConversationRoot]
  private let provider: CloudConversationProvider
  private let chunks: BackendCloudConversationChunks
  private let archive: BackendCloudConversationArchive
  private let reconciler: BackendCloudConversationReconciler
  private let deviceID: String
  private let blocked: [String]
  private var verification: (receipt: CloudImportReceipt, operations: [CloudOperation])?
  /// Every store must belong to the same signed-in account; a mixed construction is refused.
  public init(provider: CloudConversationProvider, roots: [CloudConversationRoot], chunks: BackendCloudConversationChunks,
              archive: BackendCloudConversationArchive, reconciler: BackendCloudConversationReconciler, deviceID: String,
              subjectHash: String, blockedSources: [String] = []) throws {
    guard !roots.isEmpty, roots.allSatisfy({ $0.provider == provider }) else { throw CloudFailure.invalidRequest }
    guard chunks.subjectHash == subjectHash, archive.subjectHash == subjectHash, reconciler.subjectHash == subjectHash else { throw CloudFailure.unsafeConfiguration }
    try CloudSyncBytes.transportID(deviceID)
    _ = try CloudConversationEnumerator(roots: roots)
    self.provider = provider; inventoryRows = [provider.inventoryRow]; self.roots = roots; self.chunks = chunks
    self.archive = archive; self.deviceID = deviceID; self.reconciler = reconciler; blocked = blockedSources
  }
  /// Reads directory metadata only; nothing is sealed, journaled or sent.
  public func sourceInventory() async throws -> [CloudSourceInventory] {
    let cursor = try CloudConversationEnumerator(roots: roots)
    while try await cursor.next() != nil { try Task.checkCancellation() }
    return await cursor.coverage().map { item in
      .init(sourceId: item.sourceId, inventoryRow: provider.inventoryRow, domain: provider.domain,
        items: item.items, bytes: item.bytes, complete: item.complete && blocked.isEmpty,
        blockedReasons: item.blockedReasons + blocked)
    }
  }
  public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unsupportedFormat }
  /// Pull-driven: each page is one new chunk or one file's new pages and manifest. Unchanged files produce nothing.
  /// Only operations authored by this device are offered; imported history is never re-sent.
  public func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
    do {
      let reader = try CloudConversationExport(roots: roots, chunks: chunks, journal: reconciler, deviceID: deviceID, cut: cut)
      let blocked = blocked, deviceID = deviceID
      return AsyncThrowingStream(unfolding: {
        guard let page = try await reader.next() else { return nil }
        let operations = page.operations.filter { $0.originDevice == deviceID }
        let used = Set(operations.compactMap { op -> String? in
          guard op.payload.raw["kind"].string == "chunk" else { return nil }
          return try? JSONDecoder().decode(CloudBlobRef.self, from: op.payload.raw["blob"].encodedJSON()).blobId
        })
        return CloudDomainSnapshot(cut: page.cut, operations: operations, files: page.files.filter { used.contains($0.blobId) },
          coverage: page.coverage.map { .init(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow,
            complete: $0.complete && blocked.isEmpty, items: $0.items, bytes: $0.bytes, blockedReasons: $0.blockedReasons + blocked) })
      })
    } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
  }
  /// Called by A's existing file-event/wake/overflow scheduler. Every file goes through SYNC's durable outbox;
  /// the journal moves forward only after each page's LocalReceipt.
  public func reconcile(cut: CloudSnapshotCut, outbox: any CloudOutboxPort) async throws -> [CloudLocalReceipt] {
    var receipts: [CloudLocalReceipt] = [], incomplete = false
    for try await page in await snapshotPages(cut: cut) {
      if !page.operations.isEmpty {
        let receipt = try await outbox.enqueue(page.operations, files: page.files)
        guard Set(receipt.operationIds) == Set(page.operations.map(\.opId)) else { throw CloudFailure.checksumMismatch }
        receipts.append(receipt)
      }
      if page.coverage.contains(where: { !$0.complete }) { incomplete = true }
    }
    if incomplete { throw CloudFailure.unavailable }
    return receipts
  }
  public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
    // A wires the shared file-event reconciler; a missing feed must not look like a completed watcher.
    BackendCloudBrainAgentsSupport.unavailableChanges()
  }
  private func preparationID(_ operations: [CloudOperation], files: [CloudLocalBlob]) throws -> String {
    let operationHash = CloudSyncBytes.hash(try CloudSyncCanonical.encode(operations))
    let referenceHash = CloudSyncBytes.hash(try CloudSyncCanonical.encode(files.map(\.reference).sorted { $0.blobId < $1.blobId }))
    return try CloudConversationIdentity.uuid(["A2-conversation-prepare", provider.rawValue, operationHash, referenceHash])
  }
  public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
    guard operations.allSatisfy({ $0.domain == provider.domain }), Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.invalidRequest }
    _ = try await archive.prepare(operations, files: files)
    return .init(preparationId: try preparationID(operations, files: files), operations: operations, files: files)
  }
  public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
    guard prepared.operations.allSatisfy({ $0.domain == provider.domain }), Set(prepared.operations.map(\.opId)).count == prepared.operations.count,
      try preparationID(prepared.operations, files: prepared.files) == prepared.preparationId else { throw CloudFailure.invalidRequest }
    // Recover from SYNC's durable preparation after restart; no plaintext preparation cache survives a page.
    let staged = try await archive.prepare(prepared.operations, files: prepared.files)
    let results = try await archive.apply(prepared.operations, staged: staged)
    let receipt = CloudImportReceipt(preparationId: prepared.preparationId, inventoryRow: provider.inventoryRow, results: results,
      counts: .init(domains: prepared.operations.isEmpty ? 0 : 1, records: prepared.operations.count,
        files: prepared.operations.filter { $0.payload.raw["kind"].string == "file" }.count,
        bytes: prepared.operations.reduce(0) { $0 + Int64($1.payload.raw["length"].number ?? 0) }, blocked: 0))
    verification = (receipt, prepared.operations); return receipt
  }
  public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
    guard let retained = verification, retained.receipt == receipt else { throw CloudFailure.invalidRequest }
    let good = try await archive.retained(retained.operations)
    if good, verification?.receipt.preparationId == receipt.preparationId { verification = nil }
    return .init(verified: good, counts: receipt.counts, reasons: good ? [] : ["Archive bytes did not match their import receipt."])
  }
}
