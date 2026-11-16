import Foundation

// File associations use the contract's `CloudFileAssociation` (CloudContract.swift): local-only metadata,
// never encoded into a Cloud request or an encrypted operation.

extension CloudSyncStore {
  /// Returns, per source id, how many protected files could not be attributed. Strict callers (the outbox) refuse them;
  /// snapshot pages keep them retained, because bootstrap uploads every snapshot file before any segment.
  @discardableResult
  func linkDependencies(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation], strict: Bool = true) throws -> [String: Int] {
    var unattributed: [String: Int] = [:]
    let byId = Dictionary(operations.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
    let bySource = Dictionary(grouping: byId.values, by: { $0.source.sourceId })
    var linked = Set<String>()
    for operation in byId.values {
      for ref in try CloudSyncSealedFile.references(in: [operation]) {
        try execute("INSERT OR IGNORE INTO outbox_files(opId,blobId) VALUES (?,?)", [Data(operation.opId.utf8), Data(ref.blobId.utf8)])
        linked.insert(ref.blobId)
      }
    }
    for association in associations {
      guard byId[association.operationId] != nil else { throw CloudFailure.invalidRequest }
      for id in Set(association.blobIds) {
        guard try !rows("SELECT blobId FROM objects WHERE blobId=?", [Data(id.utf8)]).isEmpty else { throw CloudFailure.invalidRequest }
        try execute("INSERT OR IGNORE INTO outbox_files(opId,blobId) VALUES (?,?)", [Data(association.operationId.utf8), Data(id.utf8)])
        linked.insert(id)
      }
    }
    for file in files where !linked.contains(file.blobId) {
      // sourceId may explicitly name an operation, or identify a single operation's producer batch.
      let owner = byId[file.sourceId] ?? (bySource[file.sourceId]?.count == 1 ? bySource[file.sourceId]?.first : nil)
      if let owner {
        try execute("INSERT OR IGNORE INTO outbox_files(opId,blobId) VALUES (?,?)", [Data(owner.opId.utf8), Data(file.blobId.utf8)])
      } else if file.storageClass == .secrets && !operations.isEmpty {
        // Opaque multi-record producers must provide associations; never inspect their plaintext.
        guard !strict else { throw CloudFailure.invalidRequest }
        unattributed[file.sourceId, default: 0] += 1
      }
      // File-only snapshot pages stay retained until their referring operations arrive.
    }
    return unattributed
  }
}
