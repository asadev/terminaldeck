import Foundation
import TerminalDeckNativeCore

/// Lane A's per-device path map (§5.3), injected by composition: `map` reads this Mac's mapped folder for a
/// (projectId, rootId); `publish` records where an existing folder of this Mac lives. A2 never writes paths itself.
public struct BackendCloudBrainProjectPaths: Sendable {
  public let map: @Sendable (String, String) async throws -> String?
  public let publish: @Sendable (CloudBrainProjectRoot) async throws -> Void
  public init(map: @escaping @Sendable (String, String) async throws -> String?, publish: @escaping @Sendable (CloudBrainProjectRoot) async throws -> Void) {
    self.map = map; self.publish = publish
  }
}

public enum BackendCloudBrainProjects {
  public static func adapter(owner: BackendPROJRegistry, account: CloudBrainAgentsAccount, paths: BackendCloudBrainProjectPaths) -> CloudBrainAgentsAdapter {
    @Sendable func mapPaths(_ incoming: [CloudOperation]) async throws {
      var mapped: [String: String] = [:]
      for key in try await owner.cloudWantedRoots(incoming) {
        let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        if let path = try await paths.map(parts[0], parts[1]) { mapped[key] = path }
      }
      await owner.cloudSetMappedPaths(mapped)
    }
    @Sendable func publish() async throws {
      for root in try await owner.cloudUnpublishedRoots() { try await paths.publish(root); await owner.cloudMarkPublished(root) }
    }
    return .init(row: "I11", domains: ["projects"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudProjectInventory() },
      snapshot: { cut in
        try await owner.cloudAttach(account)
        let export = try await owner.cloudProjectSnapshot(cut: cut)
        try await publish()
        return export
      },
      apply: { incoming in
        try await owner.cloudAttach(account); try await mapPaths(incoming)
        return try await owner.cloudProjectImport(incoming)
      },
      retained: { try await owner.cloudProjectRetained($0) },
      ownChanges: { after, limit in
        // Folders added since the last drain are published to the path map before their records leave.
        try await publish()
        return try await owner.cloudProjectOwnChanges(after: after, limit: limit)
      },
      cursor: { try await owner.cloudProjectCursor() },
      saveCursor: { try await owner.cloudProjectSaveCursor($0) },
      notices: { await owner.cloudProjectNotices() },
      detach: { await owner.cloudDetach() }))
  }
  /// After lane A commits a new folder mapping: show Cloud projects (and their tasks) that were waiting for it.
  public static func refresh(owner: BackendPROJRegistry, tasks: BackendTaskStore?, account: CloudBrainAgentsAccount, paths: BackendCloudBrainProjectPaths) async throws {
    try await owner.cloudAttach(account)
    var mapped: [String: String] = [:]
    for key in try await owner.cloudWantedRoots([]) {
      let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
      if parts.count == 2, let path = try await paths.map(parts[0], parts[1]) { mapped[key] = path }
    }
    await owner.cloudSetMappedPaths(mapped)
    _ = try await owner.cloudProjectRefresh()
    if let tasks {
      try await tasks.cloudAttach(account)
      await tasks.cloudSetProjectRoots(try await owner.cloudProjectRoots())
      _ = try await tasks.cloudTaskRefresh()
    }
  }
}
