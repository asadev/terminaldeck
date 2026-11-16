import Foundation
import CryptoKit
import Darwin

/// Private plan/provenance; tools must expose a summary rather than protected file paths.
public struct CloudRestorePlan: Codable, Equatable, Sendable {
  public struct Member: Codable, Equatable, Sendable {
    public let entryId: String
    public let relativePath: String
    public let restoredPath: String
  }
  public struct Conflict: Codable, Equatable, Sendable {
    public let relativePath: String
    public let restoredPath: String
    public let localHash: String?
    public let cloudHash: String
  }
  public let restoreId: String
  public let projectId: String
  public let rootId: String
  public let snapshotId: String
  public let sourceManifestHash: String
  public let inventoryDigest: String
  public let sourceDeviceId: String
  public let sourceSnapshotAt: Int64
  public let requestedDestination: String
  public let destination: String
  public let parentIdentity: String
  public let existingFingerprint: String
  public let members: [Member]
  public let conflicts: [Conflict]
  public let bytes: Int64
  public let blocked: Int
  public let digest: String
}
public struct CloudRestoreReceipt: Codable, Equatable, Sendable {
  public let restoreId: String
  public let sourceManifestHash: String
  public let projectId: String
  public let rootId: String
  public let destination: String
  public let requested: Int
  public let restored: Int
  public let conflicts: Int
  public let blocked: Int
  public let provenanceFile: String
  public var ready: Bool { blocked == 0 && requested == restored }
}

public actor CloudRestorePlanner {
  private struct Prepared: Codable { let plan: CloudRestorePlan; let manifest: CloudBackupManifest }
  private var plans: [String: Prepared] = [:]
  private var running = Set<String>()
  private var stageStates: [String: Stages] = [:]
  private struct Stage: Codable { let name: String; let identity: String }
  private struct Stages: Codable { let current: Stage; let prior: [Stage] }
  private let reader: CloudRestoreReader
  private let journal: CloudRestoreJournal?
  public init(reader: CloudRestoreReader, journalDirectory: URL? = nil) {
    self.reader = reader; journal = journalDirectory.map { CloudRestoreJournal(directory: $0) }
  }

  public func plan(manifest: CloudBackupManifest, sourceManifestHash: String, destination: URL) throws -> CloudRestorePlan {
    guard destination.isFileURL, manifest.v == 1, !manifest.projectId.isEmpty, !manifest.rootId.isEmpty,
      manifest.entries.count <= 1_000_000, try CloudBackupDigest.of(manifest.entries) == manifest.inventoryDigest,
      sourceManifestHash.count == 64 else { throw CloudBackupError.invalidManifest }
    let parent = try CloudBackupDirectory(path: destination.deletingLastPathComponent().path)
    let name = destination.lastPathComponent
    _ = try CloudBackupPaths.components(name)
    let id = UUID().uuidString.lowercased()
    let existing = try parent.infoIfPresent(name)
    let device = String(manifest.deviceId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(24))
    let date = String(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(manifest.at) / 1000)).prefix(10))
    let finalName = existing == nil ? name : name + " (from " + (device.isEmpty ? "backup" : device) + " " + date + " " + String(id.prefix(8)) + ")"
    guard finalName.utf8.count <= 255, try parent.infoIfPresent(finalName) == nil else { throw CloudBackupError.alreadyExists }
    var originals: [String: CloudBackupEntry.Kind] = [:]
    var total: Int64 = 0
    for entry in manifest.entries {
      let parts = try CloudBackupPaths.components(entry.relativePath)
      guard !parts.contains(".git"), originals[CloudBackupPaths.key(entry.relativePath)] == nil, entry.size >= 0, Int64(entry.mtimeNs) != nil else { throw CloudBackupError.invalidManifest }
      guard entry.size <= 8 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
      if let proof = entry.database {
        guard entry.type == .file, proof.engine == "sqlite", proof.sha256 == entry.plainHash,
          proof.bytes == entry.size, proof.storageClass == entry.storageClass else { throw CloudBackupError.invalidManifest }
      }
      originals[CloudBackupPaths.key(entry.relativePath)] = entry.type
      let (sum, overflow) = total.addingReportingOverflow(entry.size)
      guard !overflow, sum <= 64 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
      total = sum
      if entry.type == .symlink {
        guard let target = entry.linkTarget, entry.size == target.utf8.count,
          entry.plainHash == CloudBackupDigest.sha256(Data(target.utf8)) else { throw CloudBackupError.invalidManifest }
        try CloudBackupPaths.safeLink(target, at: entry.relativePath)
      }
      if entry.type == .directory { guard entry.size == 0, entry.plainHash.isEmpty, entry.linkTarget == nil else { throw CloudBackupError.invalidManifest } }
      if entry.type == .file {
        var length: Int64 = 0
        for chunk in entry.chunks {
          guard chunk.offset >= 0, chunk.length > 0, chunk.length <= CloudWire.maximumPlainChunkBytes,
            chunk.offset <= CloudWire.maximumPlainChunkBytes - chunk.length, chunk.blob.storageClass == entry.storageClass,
            chunk.blob.purpose == .backup else { throw CloudBackupError.invalidManifest }
          length += Int64(chunk.length)
          guard length <= entry.size else { throw CloudBackupError.limitExceeded }
        }
        guard length == entry.size, entry.linkTarget == nil else { throw CloudBackupError.invalidManifest }
      } else { guard entry.chunks.isEmpty else { throw CloudBackupError.invalidManifest } }
    }
    for entry in manifest.entries {
      let parts = try CloudBackupPaths.components(entry.relativePath)
      for count in 1..<parts.count {
        let prefix = parts.prefix(count).joined(separator: "/")
        guard originals[CloudBackupPaths.key(prefix)] == .directory else { throw CloudBackupError.unsafePath }
      }
    }
    let ordered = manifest.entries.sorted {
      let a = $0.relativePath.split(separator: "/").count, b = $1.relativePath.split(separator: "/").count
      return a == b ? CloudBackupPaths.precedes($0.relativePath, $1.relativePath) : a < b
    }
    var mappings: [String: String] = [:], used = Set<String>()
    var members: [CloudRestorePlan.Member] = [], conflicts: [CloudRestorePlan.Conflict] = []
    var oldDirectory: CloudBackupDirectory?
    if let existing, existing.st_mode & S_IFMT == S_IFDIR { oldDirectory = try parent.directory(name) }
    for entry in ordered {
      let path = entry.relativePath as NSString
      let originalParent = path.deletingLastPathComponent
      let mappedParent = originalParent.isEmpty ? "" : (mappings[CloudBackupPaths.key(originalParent)] ?? originalParent) + "/"
      var chosen = mappedParent + path.lastPathComponent
      var collision = false
      if used.contains(CloudBackupPaths.folded(chosen)) {
        collision = true
        chosen += " (from " + String(id.prefix(8)) + "-" + String(members.count) + ")"
      }
      _ = try CloudBackupPaths.components(chosen)
      guard used.insert(CloudBackupPaths.folded(chosen)).inserted else { throw CloudBackupError.invalidManifest }
      mappings[CloudBackupPaths.key(entry.relativePath)] = chosen
      members.append(.init(entryId: entry.entryId, relativePath: entry.relativePath, restoredPath: chosen))
      var localHash: String?
      if let oldDirectory, let (oldParent, oldName) = try? oldDirectory.parent(of: entry.relativePath),
        let oldInfo = try oldParent.infoIfPresent(oldName) {
        if oldInfo.st_mode & S_IFMT == S_IFREG { localHash = try Self.hash(oldParent, name: oldName).hash }
        else { localHash = "type:\(oldInfo.st_mode & S_IFMT)" }
      }
      if collision || localHash != nil && localHash != entry.plainHash {
        conflicts.append(.init(relativePath: entry.relativePath, restoredPath: chosen, localHash: localHash, cloudHash: entry.plainHash))
      }
    }
    let fingerprint = try Self.fingerprint(parent, name: name)
    let identity = try Self.identity(parent.fd)
    let final = destination.deletingLastPathComponent().appendingPathComponent(finalName).path
    let unsigned = CloudRestorePlan(restoreId: id, projectId: manifest.projectId, rootId: manifest.rootId, snapshotId: manifest.snapshotId,
      sourceManifestHash: sourceManifestHash, inventoryDigest: manifest.inventoryDigest, sourceDeviceId: manifest.deviceId, sourceSnapshotAt: manifest.at, requestedDestination: destination.path, destination: final, parentIdentity: identity,
      existingFingerprint: fingerprint, members: members, conflicts: conflicts, bytes: total, blocked: manifest.blocked.count, digest: "")
    let digest = try CloudBackupDigest.of(unsigned)
    let plan = CloudRestorePlan(restoreId: id, projectId: unsigned.projectId, rootId: unsigned.rootId, snapshotId: unsigned.snapshotId,
      sourceManifestHash: sourceManifestHash, inventoryDigest: manifest.inventoryDigest, sourceDeviceId: manifest.deviceId, sourceSnapshotAt: manifest.at, requestedDestination: unsigned.requestedDestination, destination: final, parentIdentity: identity,
      existingFingerprint: fingerprint, members: members, conflicts: conflicts, bytes: total, blocked: unsigned.blocked, digest: digest)
    let prepared = Prepared(plan: plan, manifest: manifest)
    try journal?.write(prepared, id: id, kind: "plan")
    plans[id] = prepared
    return plan
  }

  public func restore(restoreId: String, planDigest: String) async throws -> CloudRestoreReceipt {
    let saved = try journal?.read(Prepared.self, id: restoreId, kind: "plan")
    guard let prepared = plans[restoreId] ?? saved, prepared.plan.restoreId == restoreId,
      prepared.plan.digest == planDigest, try Self.planDigest(prepared.plan) == planDigest,
      prepared.manifest.inventoryDigest == prepared.plan.inventoryDigest,
      try CloudBackupDigest.of(prepared.manifest.entries) == prepared.plan.inventoryDigest,
      running.insert(restoreId).inserted else { throw CloudBackupError.destinationChanged }
    defer { running.remove(restoreId) }
    let lock = try journal?.lock(restoreId)
    defer { if let lock { flock(lock, LOCK_UN); close(lock) } }
    let plan = prepared.plan
    let requested = URL(fileURLWithPath: plan.requestedDestination)
    let parent = try CloudBackupDirectory(path: requested.deletingLastPathComponent().path)
    guard try Self.identity(parent.fd) == plan.parentIdentity else { throw CloudBackupError.destinationChanged }
    let finalName = URL(fileURLWithPath: plan.destination).lastPathComponent
    let oldStages = try stageStates[restoreId] ?? journal?.read(Stages.self, id: restoreId, kind: "stage")
    if let info = try parent.infoIfPresent(finalName) {
      guard let oldStages, info.st_mode & S_IFMT == S_IFDIR,
        oldStages.current.identity == Self.identity(info) else {
        if finalName == requested.lastPathComponent, try Self.fingerprint(parent, name: finalName) != plan.existingFingerprint { throw CloudBackupError.destinationChanged }
        throw CloudBackupError.alreadyExists
      }
      let final = try parent.directory(finalName)
      try Self.verifyPublished(final, location: URL(fileURLWithPath: plan.destination), prepared: prepared)
      let receipt = Self.receipt(plan)
      try journal?.write(receipt, id: restoreId, kind: "receipt")
      return receipt
    }
    guard try Self.fingerprint(parent, name: requested.lastPathComponent) == plan.existingFingerprint else { throw CloudBackupError.destinationChanged }
    var disk = statfs()
    guard fstatfs(parent.fd, &disk) == 0, disk.f_bsize > 0,
      (UInt64(max(0, plan.bytes)) + UInt64(disk.f_bsize) - 1) / UInt64(disk.f_bsize) <= UInt64(disk.f_bavail) else { throw CloudBackupError.limitExceeded }
    let previous = oldStages.map { [$0.current] + $0.prior } ?? []
    guard previous.count < 128 else { throw CloudBackupError.limitExceeded }
    var reusable: [CloudBackupDirectory] = []
    for old in previous {
      _ = try CloudBackupPaths.components(old.name)
      guard !old.name.contains("/"), let info = try parent.infoIfPresent(old.name), info.st_mode & S_IFMT == S_IFDIR,
        old.identity == Self.identity(info) else { throw CloudBackupError.destinationChanged }
      reusable.append(try parent.directory(old.name))
    }
    let stageName = ".cloud-restore-" + restoreId + "-" + UUID().uuidString.lowercased()
    let stage = try parent.createDirectory(stageName)
    let stageRecord = try Stages(current: .init(name: stageName, identity: Self.identity(stage.fd)), prior: previous)
    try journal?.write(stageRecord, id: restoreId, kind: "stage")
    stageStates[restoreId] = stageRecord
    let indexed = Dictionary(uniqueKeysWithValues: prepared.manifest.entries.map { (CloudBackupPaths.key($0.relativePath), $0) })
    // Files/directories first; link creation is deliberately last, after every parent was pinned without following links.
    for member in plan.members {
      guard let entry = indexed[CloudBackupPaths.key(member.relativePath)] else { throw CloudBackupError.invalidManifest }
      let (folder, name) = try stage.parent(of: member.restoredPath)
      if entry.type == .directory { _ = try folder.createDirectory(name) }
      else if entry.type == .file {
        let fd = openat(folder.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(entry.storageClass == .secrets ? 0o600 : (entry.mode & 0o111 != 0 ? 0o700 : 0o600)))
        guard fd >= 0 else { throw CloudBackupError.alreadyExists }
        defer { close(fd) }
        var offset: Int64 = 0
        for chunk in entry.chunks {
          try Task.checkCancellation()
          let slice: Data
          if let cached = Self.reusableChunk(reusable, path: member.restoredPath, offset: offset, chunk: chunk) { slice = cached }
          else {
            let bytes = try await reader.bytes(chunk.blob)
            guard chunk.offset <= bytes.count, chunk.length <= bytes.count - chunk.offset else { throw CloudBackupError.limitExceeded }
            slice = bytes.subdata(in: chunk.offset..<(chunk.offset + chunk.length))
          }
          guard CloudBackupDigest.sha256(slice) == chunk.plainHash else { throw CloudBackupError.readbackFailed }
          try CloudBackupDirectory.writeAll(fd, slice)
          offset += Int64(chunk.length)
        }
        try Self.setTime(fd, nanoseconds: entry.mtimeNs)
        guard fsync(fd) == 0 else { throw CloudBackupError.unavailable }
      }
    }
    for member in plan.members {
      let entry = indexed[CloudBackupPaths.key(member.relativePath)]!
      if entry.type == .symlink {
        let (folder, name) = try stage.parent(of: member.restoredPath)
        guard let target = entry.linkTarget, symlinkat(target, folder.fd, name) == 0 else { throw CloudBackupError.unsafePath }
      }
    }
    for member in plan.members {
      let entry = indexed[CloudBackupPaths.key(member.relativePath)]!
      let (folder, name) = try stage.parent(of: member.restoredPath)
      switch entry.type {
      case .file:
        if let proof = entry.database {
          let path = requested.deletingLastPathComponent().appendingPathComponent(stageName).appendingPathComponent(member.restoredPath)
          let verified = try CloudBackupDatabase.inspect(path, storageClass: entry.storageClass, consistentThrough: proof.consistentThrough)
          guard verified.sha256 == proof.sha256, verified.bytes == proof.bytes, verified.tables == proof.tables else { throw CloudBackupError.readbackFailed }
        } else {
          let readback = try Self.hash(folder, name: name)
          guard readback.hash == entry.plainHash, readback.bytes == entry.size else { throw CloudBackupError.readbackFailed }
        }
      case .directory: _ = try folder.directory(name)
      case .symlink: guard try folder.link(name) == entry.linkTarget else { throw CloudBackupError.readbackFailed }
      }
    }
    let freshParent = try CloudBackupDirectory(path: requested.deletingLastPathComponent().path)
    guard try Self.identity(freshParent.fd) == plan.parentIdentity,
      try Self.fingerprint(parent, name: requested.lastPathComponent) == plan.existingFingerprint else { throw CloudBackupError.destinationChanged }
    let proofName = ".cloud-restore-proof-" + restoreId + ".json"
    let proof = try CloudWire.canonical(plan)
    if try parent.infoIfPresent(proofName) == nil { try parent.writeNew(proofName, bytes: proof) }
    else {
      let fd = try parent.file(proofName); defer { close(fd) }
      guard try CloudBackupDirectory.readChunk(fd, maximum: proof.count + 1) == proof else { throw CloudBackupError.destinationChanged }
    }
    let stagedInfo = try parent.info(stageName)
    guard try Self.identity(stage.fd) == Self.identity(stagedInfo), stagedInfo.st_mode & S_IFMT == S_IFDIR,
      fsync(stage.fd) == 0,
      renameatx_np(parent.fd, stageName, parent.fd, finalName, UInt32(RENAME_EXCL)) == 0,
      fsync(parent.fd) == 0 else { throw CloudBackupError.alreadyExists }
    let receipt = Self.receipt(plan)
    try journal?.write(receipt, id: restoreId, kind: "receipt")
    // Retain the plan for idempotent readback, including a retry after the publication receipt was lost.
    plans[restoreId] = prepared
    return receipt
  }

  private static func receipt(_ plan: CloudRestorePlan) -> CloudRestoreReceipt {
    .init(restoreId: plan.restoreId, sourceManifestHash: plan.sourceManifestHash, projectId: plan.projectId, rootId: plan.rootId,
      destination: plan.destination, requested: plan.members.count, restored: plan.members.count, conflicts: plan.conflicts.count,
      blocked: plan.blocked, provenanceFile: URL(fileURLWithPath: plan.requestedDestination).deletingLastPathComponent().appendingPathComponent(".cloud-restore-proof-" + plan.restoreId + ".json").path)
  }
  private static func planDigest(_ plan: CloudRestorePlan) throws -> String {
    let unsigned = CloudRestorePlan(restoreId: plan.restoreId, projectId: plan.projectId, rootId: plan.rootId, snapshotId: plan.snapshotId,
      sourceManifestHash: plan.sourceManifestHash, inventoryDigest: plan.inventoryDigest, sourceDeviceId: plan.sourceDeviceId,
      sourceSnapshotAt: plan.sourceSnapshotAt, requestedDestination: plan.requestedDestination, destination: plan.destination,
      parentIdentity: plan.parentIdentity, existingFingerprint: plan.existingFingerprint, members: plan.members, conflicts: plan.conflicts,
      bytes: plan.bytes, blocked: plan.blocked, digest: "")
    return try CloudBackupDigest.of(unsigned)
  }
  private static func reusableChunk(_ folders: [CloudBackupDirectory], path: String, offset: Int64, chunk: CloudBackupChunk) -> Data? {
    for directory in folders {
      do {
        let (parent, name) = try directory.parent(of: path)
        let fd = try parent.file(name); defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) == offset else { continue }
        let bytes = try CloudBackupDirectory.readChunk(fd, maximum: chunk.length)
        if bytes.count == chunk.length, CloudBackupDigest.sha256(bytes) == chunk.plainHash { return bytes }
      } catch { continue }
    }
    return nil
  }
  private static func verifyPublished(_ root: CloudBackupDirectory, location: URL, prepared: Prepared) throws {
    let entries = Dictionary(uniqueKeysWithValues: prepared.manifest.entries.map { (CloudBackupPaths.key($0.relativePath), $0) })
    for member in prepared.plan.members {
      guard let entry = entries[CloudBackupPaths.key(member.relativePath)] else { throw CloudBackupError.invalidManifest }
      let (folder, name) = try root.parent(of: member.restoredPath)
      switch entry.type {
      case .directory: _ = try folder.directory(name)
      case .symlink: guard try folder.link(name) == entry.linkTarget else { throw CloudBackupError.readbackFailed }
      case .file:
        let actual = try hash(folder, name: name)
        guard actual.hash == entry.plainHash, actual.bytes == entry.size else { throw CloudBackupError.readbackFailed }
        if let expected = entry.database {
          let actual = try CloudBackupDatabase.inspect(location.appendingPathComponent(member.restoredPath), storageClass: entry.storageClass, consistentThrough: expected.consistentThrough)
          guard actual.tables == expected.tables, actual.sha256 == expected.sha256 else { throw CloudBackupError.readbackFailed }
        }
      }
    }
  }

  private static func setTime(_ fd: Int32, nanoseconds: String) throws {
    guard let value = Int64(nanoseconds) else { throw CloudBackupError.invalidManifest }
    var seconds = value / 1_000_000_000, nanos = value % 1_000_000_000
    if nanos < 0 { seconds -= 1; nanos += 1_000_000_000 }
    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos))]
    guard futimens(fd, &times) == 0 else { throw CloudBackupError.unavailable }
  }
  private static func identity(_ fd: Int32) throws -> String {
    var info = stat(); guard fstat(fd, &info) == 0 else { throw CloudBackupError.unavailable }
    return identity(info)
  }
  private static func identity(_ info: stat) -> String {
    "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
  }
  private static func hash(_ folder: CloudBackupDirectory, name: String) throws -> (hash: String, bytes: Int64) {
    let fd = try folder.file(name); defer { close(fd) }
    var before = stat(); guard fstat(fd, &before) == 0 else { throw CloudBackupError.unavailable }
    guard before.st_size <= 8 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
    var hash = SHA256(), bytes: Int64 = 0
    while true {
      let chunk = try CloudBackupDirectory.readChunk(fd, maximum: CloudWire.maximumPlainChunkBytes)
      if chunk.isEmpty { break }; hash.update(data: chunk); bytes += Int64(chunk.count)
      guard bytes <= 8 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, CloudBackupDirectory.fingerprint(before) == CloudBackupDirectory.fingerprint(after) else { throw CloudBackupError.changedDuringRead }
    return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
  }
  private static func fingerprint(_ parent: CloudBackupDirectory, name: String, depth: Int = 0) throws -> String {
    guard depth < 128 else { throw CloudBackupError.limitExceeded }
    guard let info = try parent.infoIfPresent(name) else { return "absent" }
    var parts = [CloudBackupDirectory.fingerprint(info)]
    if info.st_mode & S_IFMT == S_IFDIR {
      let directory = try parent.directory(name)
      for child in try directory.names() { parts.append(child + ":" + (try fingerprint(directory, name: child, depth: depth + 1))) }
    }
    return CloudBackupDigest.sha256(Data(parts.joined(separator: "\n").utf8))
  }
}
