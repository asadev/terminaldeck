import Foundation
import TerminalDeckNativeCore

public struct BackendCloudBackupArtifactInventory: Sendable {
  public struct Candidate: Sendable { public let artifactId: String; public let file: URL; public let relativePath: String? }
  public let candidates: [Candidate]
  public let indexComplete: Bool
  public let blocked: Int
}

/// This bounded Claude index is discovery input, not complete I27 source coverage.
/// Transcript mentions are discovery hints, never grants. Outside files need the owner's exact-file approval.
public struct BackendCloudBackupArtifacts: Sendable {
  private let index: BackendArtifactsIndex
  private let authority: BackendFilesystemAuthority
  private let outsideGrant: @Sendable (URL, String, NativeRPCContext) async throws -> Bool
  public init(index: BackendArtifactsIndex, authority: BackendFilesystemAuthority,
              outsideGrant: @escaping @Sendable (URL, String, NativeRPCContext) async throws -> Bool) {
    self.index = index; self.authority = authority; self.outsideGrant = outsideGrant
  }
  /// A build owner calls this after final writing/signing. No transcript text can supply this completion event.
  public func finished(projectId: String, folder: String, file: URL, completionId: String, completedAt: Int64,
                       context: NativeRPCContext) async throws -> CloudBackupArtifactReceipt {
    guard file.isFileURL else { throw CloudBackupError.unsafePath }
    let root = try await authority.authorize(folder, context: context)
    let admitted = try await authority.authorize(file.path, context: context)
    let inside = BackendFilesystemAuthority.within(admitted, root)
    if !inside { guard try await outsideGrant(admitted, projectId, context) else { throw CloudFailure.gateClosed } }
    let identity = inside ? String(admitted.path.dropFirst(root.path.count)) : admitted.path
    let id = try CloudBackupDigest.of([projectId, identity])
    return try await CloudBackupArtifacts.inspect(file: admitted, artifactId: id, completionId: completionId, completedAt: completedAt)
  }
  public func candidates(projectId: String, folder: String, context: NativeRPCContext) async throws -> BackendCloudBackupArtifactInventory {
    let root = try await authority.authorize(folder, context: context)
    var options = BackendArtifactScanOptions()
    options.maxAgeMilliseconds = 0; options.maxSessions = 400; options.maxArtifacts = 2000; options.onlyArtifacts = true
    let listing = try await index.list(project: folder, options: options, context: context)
    var result: [BackendCloudBackupArtifactInventory.Candidate] = []
    var blocked = Int(listing["sessionsSkipped"].number ?? 0)
    for row in listing["artifacts"].elements ?? [] {
      guard let path = row["relPath"].string, !path.isEmpty else { blocked += 1; continue }
      do {
        let outside = path.hasPrefix("/")
        if !outside { _ = try CloudBackupPaths.components(path) }
        let proposed = outside ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let admitted = try await authority.authorize(proposed.path, context: context)
        if outside { guard try await outsideGrant(admitted, projectId, context) else { blocked += 1; continue } }
        else { guard admitted.path.hasPrefix(root.path + "/") else { blocked += 1; continue } }
        let id = try CloudBackupDigest.of([projectId, path])
        result.append(.init(artifactId: id, file: admitted, relativePath: outside ? nil : path))
      } catch is CancellationError { throw CancellationError() }
      catch { blocked += 1 }
    }
    let complete = listing["truncated"].bool != true && listing["cancelled"].bool != true && blocked == 0
    return .init(candidates: result, indexComplete: complete, blocked: blocked + (listing["truncated"].bool == true ? 1 : 0))
  }
}
