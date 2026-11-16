import Foundation
import CryptoKit
import Darwin

/// Snapshot-only engine. It owns no timers, processes, network client, keys or project registration.
/// The integrator supplies authorized roots, V classification, the B/S content ports and SYNC's durable outbox.
public actor CloudBackupEngine {
  public typealias Classifier = @Sendable (String, String) async throws -> CloudSecretClassification
  private struct CachedFile: Codable { let stamp: String; let entry: CloudBackupEntry }
  private struct Catalogue: Codable {
    var rootPath: String
    var selectionDigest: String? = nil
    var latest: CloudBackupManifest?
    var files: [String: CachedFile] = [:]
    var chunks: [String: CloudBackupChunk] = [:]
  }
  private struct TreePage: Codable {
    let v: Int
    let entries: [CloudBackupEntry]
    let children: [CloudBlobRef]
  }
  private struct TreeRoot: Codable {
    let v: Int
    let snapshotId: String
    let projectId: String
    let rootId: String
    let deviceId: String
    let eventCursor: String
    let parentSnapshotId: String?
    let at: Int64
    let ordinary: CloudBlobRef?
    let protected: CloudBlobRef?
    let entryCount: Int
    let blockedCount: Int
    let inventoryDigest: String
    let exclusions: [CloudBackupExclusion]
    let markers: [CloudBackupMarker]
  }
  private let stateDirectory: URL
  private let brain: any CloudContentPort
  private let secrets: any CloudContentPort
  private let classify: Classifier
  private let outbox: any CloudOutboxPort
  private var busy = false

  public init(stateDirectory: URL, brain: any CloudContentPort, secrets: any CloudContentPort,
              classify: @escaping Classifier, outbox: any CloudOutboxPort) {
    self.stateDirectory = stateDirectory; self.brain = brain; self.secrets = secrets
    self.classify = classify; self.outbox = outbox
  }

  public func snapshot(_ root: CloudBackupRoot, eventCursor: String, at: Int64) async throws -> CloudBackupSnapshot {
    guard !busy else { throw CloudBackupError.unavailable }
    busy = true
    defer { busy = false }
    let run = Run(root: root, eventCursor: eventCursor, at: at, stateDirectory: stateDirectory,
                  brain: brain, secrets: secrets, classify: classify, outbox: outbox)
    return try await run.execute()
  }

  /// A single actor owns all snapshot buffers and descriptors across content-port suspension points.
  private actor Run {
    let root: CloudBackupRoot
    let eventCursor: String
    let at: Int64
    let stateDirectory: URL
    let brain: any CloudContentPort
    let secrets: any CloudContentPort
    let classify: Classifier
    let outbox: any CloudOutboxPort
    let snapshotId = UUID().uuidString.lowercased()
    var source: CloudBackupDirectory!
    var state: CloudBackupDirectory!
    var spool: CloudBackupDirectory!
    var spoolURL: URL!
    var identity = ""
    var previous = Catalogue(rootPath: "")
    var next = Catalogue(rootPath: "")
    var brainState = CloudContentState(available: false, epoch: 0)
    var secretState = CloudContentState(available: false, epoch: 0)
    var entries: [CloudBackupEntry] = []
    var exclusions: [CloudBackupExclusion] = []
    var blocked: [String] = []
    var blockedPaths = Set<String>()
    var files: [CloudLocalBlob] = []
    var uploaded = 0
    var reused = 0
    var totalBytes: Int64 = 0
    var pending: [(index: Int, bytes: Data, key: String)] = []
    var pendingBytes = 0
    var pendingClass: CloudStorageClass = .brain
    var hardlinks: [String: String] = [:]

    init(root: CloudBackupRoot, eventCursor: String, at: Int64, stateDirectory: URL,
         brain: any CloudContentPort, secrets: any CloudContentPort, classify: @escaping Classifier, outbox: any CloudOutboxPort) {
      self.root = root; self.eventCursor = eventCursor; self.at = at; self.stateDirectory = stateDirectory
      self.brain = brain; self.secrets = secrets; self.classify = classify; self.outbox = outbox
    }

    func execute() async throws -> CloudBackupSnapshot {
      guard root.directory.isFileURL, stateDirectory.isFileURL, !root.projectId.isEmpty, !root.rootId.isEmpty, !root.deviceId.isEmpty,
        stateDirectory.path != root.directory.path else { throw CloudBackupError.unsafePath }
      source = try CloudBackupDirectory(path: root.directory.path)
      // This directory belongs to the caller's isolated subject store, not to the project.
      let stateParent = try CloudBackupDirectory(path: stateDirectory.deletingLastPathComponent().path)
      if let selected = root.includedPaths {
        guard !selected.isEmpty else { throw CloudBackupError.invalidManifest }
        for path in selected {
          let (folder, name) = try source.parent(of: path)
          if try folder.info(name).st_mode & S_IFMT == S_IFDIR {
            guard try !stateParent.isWithin(folder.directory(name)) else { throw CloudBackupError.unsafePath }
          }
        }
      } else { guard try !stateParent.isWithin(source) else { throw CloudBackupError.unsafePath } }
      let stateName = stateDirectory.lastPathComponent
      _ = try CloudBackupPaths.components(stateName)
      if mkdirat(stateParent.fd, stateName, 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
      state = try stateParent.directory(stateName)
      if let selected = root.includedPaths {
        for path in selected {
          let (folder, name) = try source.parent(of: path)
          guard try !folder.isWithin(state) else { throw CloudBackupError.unsafePath }
          if try folder.info(name).st_mode & S_IFMT == S_IFDIR {
            let directory = try folder.directory(name)
            guard try !directory.isWithin(state), try !state.isWithin(directory) else { throw CloudBackupError.unsafePath }
          }
        }
      } else { guard try !state.isWithin(source) else { throw CloudBackupError.unsafePath } }
      var stateInfo = stat()
      guard fstat(state.fd, &stateInfo) == 0, stateInfo.st_uid == getuid(), stateInfo.st_mode & 0o077 == 0 else { throw CloudBackupError.unsafePath }
      identity = try CloudBackupDigest.of([root.projectId, root.rootId])
      let catalogueName = identity + ".json"
      let selectionDigest = try CloudBackupDigest.of((root.includedPaths ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
      previous = Catalogue(rootPath: root.directory.path)
      if try state.infoIfPresent(catalogueName) != nil {
        let fd = try state.file(catalogueName); defer { close(fd) }
        let data = try CloudBackupDirectory.readChunk(fd, maximum: 64 * 1024 * 1024 + 1)
        guard data.count <= 64 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
        previous = try JSONDecoder().decode(Catalogue.self, from: data)
        let oldSelection = try previous.selectionDigest ?? CloudBackupDigest.of([String]())
        guard oldSelection == selectionDigest, previous.rootPath == root.directory.path else { throw CloudBackupError.destinationChanged }
      }
      brainState = await brain.state(storageClass: .brain)
      secretState = await secrets.state(storageClass: .secrets)
      guard brainState.available else { throw CloudBackupError.unavailable }
      spool = try state.createDirectory(snapshotId)
      spoolURL = stateDirectory.appendingPathComponent(snapshotId)
      next = Catalogue(rootPath: root.directory.path)
      next.selectionDigest = selectionDigest
      next.chunks = previous.chunks
      try await walk(source, prefix: "", depth: 0)
      try await flushPack()
      for entry in entries {
        if let cached = next.files[CloudBackupPaths.key(entry.relativePath)] { next.files[CloudBackupPaths.key(entry.relativePath)] = .init(stamp: cached.stamp, entry: entry) }
      }
      var markers: [CloudBackupMarker] = []
      let paths = Set(entries.map { CloudBackupPaths.key($0.relativePath) })
      let oldPaths = Set(previous.latest?.entries.map { CloudBackupPaths.key($0.relativePath) } ?? [])
      for old in previous.latest?.entries ?? [] where !paths.contains(CloudBackupPaths.key(old.relativePath)) {
        // A blocked/protected source is not evidence that an earlier version was deleted.
        if blockedPaths.contains(where: { old.relativePath == $0 || old.relativePath.hasPrefix($0 + "/") }) { continue }
        if let renamed = entries.first(where: { $0.type == .file && $0.plainHash == old.plainHash && $0.size == old.size && !oldPaths.contains(CloudBackupPaths.key($0.relativePath)) }) {
          markers.append(.init(kind: .renamed, path: renamed.relativePath, previousPath: old.relativePath))
        } else { markers.append(.init(kind: .archived, path: old.relativePath, previousPath: nil)) }
      }
      var folded: [String: String] = [:]
      for entry in entries {
        let key = CloudBackupPaths.folded(entry.relativePath)
        if let other = folded[key] { markers.append(.init(kind: .collision, path: entry.relativePath, previousPath: other)) }
        else { folded[key] = entry.relativePath }
      }
      for (path, artifact) in root.verifiedArtifacts {
        guard artifact.file.path == root.directory.appendingPathComponent(path).path else { throw CloudBackupError.invalidManifest }
        if try CloudBackupArtifacts.digest(entries: entries, at: path, bundle: artifact.proof.bundle) != artifact.proof.contentDigest {
          blocked.append("artifact-not-finished-" + artifact.proof.artifactId)
          continue
        }
        guard let index = entries.firstIndex(where: { CloudBackupPaths.key($0.relativePath) == CloudBackupPaths.key(path) }) else { throw CloudBackupError.readbackFailed }
        entries[index].artifact = artifact.proof
      }
      let inventoryDigest = try CloudBackupDigest.of(entries)
      let manifest = CloudBackupManifest(v: 1, snapshotId: snapshotId, projectId: root.projectId, rootId: root.rootId,
        deviceId: root.deviceId, parentSnapshotId: previous.latest?.snapshotId, at: at, eventCursor: eventCursor,
        scanComplete: blocked.isEmpty, entries: entries, exclusions: exclusions, markers: markers, blocked: blocked, inventoryDigest: inventoryDigest)
      let ordinary = try await tree(entries.filter { $0.storageClass == .brain }, .brain)
      let protected = try await tree(entries.filter { $0.storageClass == .secrets }, .secrets)
      let rootRef = try await seal(CloudWire.canonical(TreeRoot(v: 1, snapshotId: snapshotId, projectId: root.projectId,
        rootId: root.rootId, deviceId: root.deviceId, eventCursor: eventCursor, parentSnapshotId: previous.latest?.snapshotId, at: at, ordinary: ordinary, protected: protected,
        entryCount: entries.count, blockedCount: blocked.count, inventoryDigest: inventoryDigest,
        exclusions: exclusions.map { .init(relativePath: CloudBackupDigest.sha256(Data($0.relativePath.utf8)), rule: $0.rule, count: $0.count, bytes: $0.bytes) },
        markers: markers.map { .init(kind: $0.kind, path: CloudBackupDigest.sha256(Data($0.path.utf8)), previousPath: $0.previousPath.map { CloudBackupDigest.sha256(Data($0.utf8)) }) })), .brain)
      let payload = CloudValue(try NativeRPCValue.parseJSON(CloudWire.canonical(rootRef)))
      let operation = CloudOperation(v: 1, opId: snapshotId, originDevice: root.deviceId, domain: "backup",
        entityId: identity, revision: snapshotId, parents: previous.latest.map { [$0.snapshotId] } ?? [], kind: .put,
        projectId: root.projectId, rootId: root.rootId, source: .init(sourceId: identity, recordId: snapshotId), createdAt: at,
        payload: payload, payloadHash: try CloudBackupDigest.of(payload))
      // SYNC must acknowledge the durable sealed bytes before this catalogue can reuse their references.
      try Task.checkCancellation()
      let receipt = try await outbox.enqueue([operation], files: files)
      guard receipt.operationIds.contains(operation.opId), receipt.queued >= 1, receipt.bytes >= files.reduce(0, { $0 + $1.bytes }) else { throw CloudBackupError.incomplete }
      next.latest = manifest
      let journal = try CloudWire.canonical(next)
      let temp = identity + "." + UUID().uuidString + ".tmp"
      try state.writeNew(temp, bytes: journal)
      guard renameat(state.fd, temp, state.fd, catalogueName) == 0, fsync(state.fd) == 0 else { throw CloudBackupError.unavailable }
      try spool.writeNew("manifest.local.json", bytes: CloudWire.canonical(manifest))
      return .init(manifest: manifest, root: rootRef, localReceipt: receipt, queuedContentChunks: uploaded, reusedContentChunks: reused)
    }

    func contentKey(_ hash: String, _ storageClass: CloudStorageClass) -> String {
      "\(storageClass.rawValue):\(storageClass == .brain ? brainState.epoch : secretState.epoch):\(hash)"
    }
    func seal(_ data: Data, _ storageClass: CloudStorageClass) async throws -> CloudBlobRef {
      try Task.checkCancellation()
      guard data.count <= CloudWire.maximumPlainChunkBytes else { throw CloudBackupError.limitExceeded }
      let id = UUID().uuidString.lowercased()
      let port = storageClass == .brain ? brain : secrets
      let epoch = storageClass == .brain ? brainState.epoch : secretState.epoch
      let envelope = try await port.seal(data, blobId: id, storageClass: storageClass, purpose: .backup, epoch: epoch, codec: .identity)
      guard envelope.blobId == id, envelope.storageClass == storageClass, envelope.purpose == .backup,
        envelope.epoch == epoch, envelope.plainBytes == data.count else { throw CloudBackupError.invalidManifest }
      let sealed = try CloudWire.canonical(envelope)
      guard sealed.count <= CloudWire.maximumBlobBytes else { throw CloudBackupError.limitExceeded }
      try spool.writeNew(id, bytes: sealed)
      let hash = CloudBackupDigest.sha256(sealed)
      let local = CloudLocalBlob(blobId: id, sourceId: identity, localURL: spoolURL.appendingPathComponent(id), bytes: Int64(sealed.count), sha256: hash, md5: CloudBackupDigest.md5(sealed), keyEpoch: epoch, storageClass: storageClass, purpose: .backup)
      files.append(local)
      return local.reference
    }
    func flushPack() async throws {
      guard !pending.isEmpty else { return }
      var pack = Data()
      for member in pending { pack.append(member.bytes) }
      let blob = try await seal(pack, pendingClass)
      uploaded += 1
      var offset = 0
      for member in pending {
        let chunk = CloudBackupChunk(blob: blob, offset: offset, length: member.bytes.count, plainHash: CloudBackupDigest.sha256(member.bytes))
        entries[member.index].chunks = [chunk]
        next.chunks[member.key] = chunk
        offset += member.bytes.count
      }
      pending.removeAll(); pendingBytes = 0
    }
    func excludedInventory(_ directory: CloudBackupDirectory, name: String, depth: Int = 0) throws -> (count: Int, bytes: Int64) {
      guard depth <= 128 else { throw CloudBackupError.limitExceeded }
      let info = try directory.info(name)
      if info.st_mode & S_IFMT != S_IFDIR { return (1, info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_size) : 0) }
      let child = try directory.directory(name)
      var count = 1
      var bytes: Int64 = 0
      for entry in try child.names() {
        let result = try excludedInventory(child, name: entry, depth: depth + 1)
        count += result.count
        let (sum, overflow) = bytes.addingReportingOverflow(result.bytes)
        guard count <= 1_000_000, !overflow else { throw CloudBackupError.limitExceeded }
        bytes = sum
      }
      return (count, bytes)
    }
    func exclusion(_ path: String, _ rule: String, directory: CloudBackupDirectory, name: String) throws {
      let measured = try excludedInventory(directory, name: name)
      exclusions.append(.init(relativePath: path, rule: rule, count: measured.count, bytes: measured.bytes))
    }
    func selectedNames(_ directory: CloudBackupDirectory, prefix: String) throws -> [String] {
      guard let paths = root.includedPaths else { return try directory.names() }
      if !prefix.isEmpty && paths.contains(where: { CloudBackupPaths.key($0) == CloudBackupPaths.key(prefix) || prefix.utf8.starts(with: ($0 + "/").utf8) }) { return try directory.names() }
      var names: [String: String] = [:]
      for path in paths {
        _ = try CloudBackupPaths.components(path)
        let leading = prefix.isEmpty ? "" : prefix + "/"
        guard path.utf8.starts(with: leading.utf8) else { continue }
        let suffix = String(decoding: path.utf8.dropFirst(leading.utf8.count), as: UTF8.self)
        if let name = suffix.split(separator: "/").first.map(String.init) { names[CloudBackupPaths.key(name)] = name }
      }
      return names.values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    func walk(_ directory: CloudBackupDirectory, prefix: String, depth: Int, protectedParent: Bool = false, rebuildableParent: Bool = false) async throws {
      guard depth <= 128 else { throw CloudBackupError.limitExceeded }
      for name in try selectedNames(directory, prefix: prefix) {
        try Task.checkCancellation()
        let path = prefix.isEmpty ? name : prefix + "/" + name
        _ = try CloudBackupPaths.components(path)
        let info = try directory.info(name)
        let kind = info.st_mode & S_IFMT
        let database = root.verifiedDatabases[path]
        let isArtifact = root.finishedArtifacts.union(root.verifiedArtifacts.keys).contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") })
        if name == ".git" { try exclusion(path, "git-owned-export-required", directory: directory, name: name); blocked.append("git-export-required"); continue }
        if ["SingletonLock", "SingletonSocket", "postmaster.pid", "mongod.lock", "hook-endpoint.conf"].contains(name) || name.hasSuffix(".sock") {
          try exclusion(path, "runtime-lock-or-endpoint", directory: directory, name: name); continue
        }
        let standardJunk: Set<String> = ["node_modules", ".build", "DerivedData", ".next", ".nuxt", ".turbo", ".cache", "__pycache__", ".venv", "venv"]
        let generated = kind == S_IFDIR && (standardJunk.contains(name) || root.generatedDirectories.contains(path) || (name == "target" && ((try? source.info("Cargo.toml")) != nil || (try? source.info("pom.xml")) != nil)))
        if (generated || rebuildableParent) && !isArtifact {
          try exclusion(path, "rebuildable-directory", directory: directory, name: name); continue
        }
        let classification = try await classify(path, identity)
        if classification.purpose == .aiSubscription { try exclusion(path, "provider-auth-disabled", directory: directory, name: name); continue }
        let storageClass: CloudStorageClass = (protectedParent || database?.proof.storageClass == .secrets) ? .secrets : classification.storageClass
        if storageClass == .secrets && !secretState.available { blockedPaths.insert(path); blocked.append("protected-item-\(entries.count + blocked.count)"); continue }
        guard entries.count < 1_000_000 else { throw CloudBackupError.limitExceeded }
        let id = CloudBackupDigest.sha256(Data((identity + "\u{0}" + path).utf8))
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        if kind == S_IFDIR {
          entries.append(.init(entryId: id, relativePath: path, type: .directory, mode: 0o700, mtimeNs: String(mtime), size: 0, plainHash: "", chunks: [], linkTarget: nil, hardlinkGroup: nil, storageClass: storageClass))
          try await walk(directory.directory(name), prefix: path, depth: depth + 1, protectedParent: storageClass == .secrets, rebuildableParent: rebuildableParent || generated)
        } else if kind == S_IFLNK {
          let target = try directory.link(name)
          guard CloudBackupDirectory.fingerprint(try directory.info(name)) == CloudBackupDirectory.fingerprint(info) else { throw CloudBackupError.changedDuringRead }
          // Unsafe links are recorded as blocked, never followed, even during export.
          do { try CloudBackupPaths.safeLink(target, at: path) }
          catch { blockedPaths.insert(path); blocked.append("unsafe-link-\(id)"); continue }
          entries.append(.init(entryId: id, relativePath: path, type: .symlink, mode: 0o700, mtimeNs: String(mtime), size: Int64(target.utf8.count), plainHash: CloudBackupDigest.sha256(Data(target.utf8)), chunks: [], linkTarget: target, hardlinkGroup: nil, storageClass: storageClass))
        } else if kind == S_IFREG {
          let ext = (name as NSString).pathExtension.lowercased()
          if database == nil && (["db", "sqlite", "sqlite3", "mdb", "ibd"].contains(ext) || name.hasSuffix("-wal") || name.hasSuffix("-shm")) {
            blockedPaths.insert(path); blocked.append("database-export-required-\(id)"); continue
          }
          if let database {
            guard database.file.path == root.directory.appendingPathComponent(path).path,
              database.proof.engine == "sqlite", database.proof.bytes == info.st_size else { throw CloudBackupError.invalidManifest }
          }
          let stamp = CloudBackupDirectory.fingerprint(info)
          if let cached = previous.files[CloudBackupPaths.key(path)], cached.stamp == stamp, cached.entry.storageClass == storageClass, cached.entry.database == database?.proof,
            cached.entry.chunks.allSatisfy({ $0.blob.keyEpoch == (storageClass == .brain ? brainState.epoch : secretState.epoch) }) {
            totalBytes += cached.entry.size
            guard totalBytes <= 64 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
            entries.append(cached.entry); next.files[CloudBackupPaths.key(path)] = cached; reused += cached.entry.chunks.count; continue
          }
          let fd = try directory.file(name)
          defer { close(fd) }
          var before = stat()
          guard fstat(fd, &before) == 0, CloudBackupDirectory.fingerprint(before) == stamp else { throw CloudBackupError.changedDuringRead }
          guard before.st_size >= 0, before.st_size <= 8 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
          totalBytes += Int64(before.st_size)
          guard totalBytes <= 64 * 1024 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
          let inode = "\(before.st_dev):\(before.st_ino)"
          let group: String?
          if before.st_nlink > 1 { group = hardlinks[inode] ?? UUID().uuidString; hardlinks[inode] = group } else { group = nil }
          var hasher = SHA256(), chunks: [CloudBackupChunk] = [], small: Data?
          var readBytes: Int64 = 0
          while true {
            try Task.checkCancellation()
            let data = try CloudBackupDirectory.readChunk(fd, maximum: CloudWire.maximumPlainChunkBytes)
            if data.isEmpty { break }
            if database == nil && readBytes == 0 && data.starts(with: Data("SQLite format 3\u{0}".utf8)) {
              blockedPaths.insert(path); blocked.append("database-export-required-\(id)"); break
            }
            hasher.update(data: data); readBytes += Int64(data.count)
            guard readBytes <= before.st_size else { throw CloudBackupError.changedDuringRead }
            let hash = CloudBackupDigest.sha256(data), key = contentKey(hash, storageClass)
            if let cached = next.chunks[key] { chunks.append(cached); reused += 1 }
            else if before.st_size <= 64 * 1024 { small = data }
            else {
              let blob = try await seal(data, storageClass)
              let chunk = CloudBackupChunk(blob: blob, offset: 0, length: data.count, plainHash: hash)
              chunks.append(chunk); next.chunks[key] = chunk; uploaded += 1
            }
          }
          if blocked.last == "database-export-required-\(id)" { continue }
          var after = stat()
          guard fstat(fd, &after) == 0, CloudBackupDirectory.fingerprint(after) == stamp,
            CloudBackupDirectory.fingerprint(try directory.info(name)) == stamp, readBytes == before.st_size else { throw CloudBackupError.changedDuringRead }
          let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
          if let database { guard database.proof.sha256 == hash else { throw CloudBackupError.readbackFailed } }
          let mode: UInt16 = storageClass == .secrets ? 0o600 : (before.st_mode & 0o111 != 0 ? 0o700 : 0o600)
          if let small, !pending.isEmpty && (pendingClass != storageClass || pendingBytes + small.count > CloudWire.maximumPlainChunkBytes) { try await flushPack() }
          entries.append(.init(entryId: id, relativePath: path, type: .file, mode: mode, mtimeNs: String(mtime), size: readBytes, plainHash: hash, chunks: chunks, linkTarget: nil, hardlinkGroup: group, storageClass: storageClass))
          if let proof = database?.proof {
            entries[entries.count - 1].database = .init(engine: proof.engine, exporter: proof.exporter, consistentThrough: proof.consistentThrough,
              tables: proof.tables, bytes: proof.bytes, sha256: proof.sha256, storageClass: storageClass)
          }
          if let small {
            pendingClass = storageClass; pending.append((entries.count - 1, small, contentKey(hash, storageClass))); pendingBytes += small.count
          }
          next.files[CloudBackupPaths.key(path)] = CachedFile(stamp: stamp, entry: entries.last!)
        } else { try exclusion(path, "not-a-regular-work-file", directory: directory, name: name) }
      }
    }
    func tree(_ selected: [CloudBackupEntry], _ storageClass: CloudStorageClass) async throws -> CloudBlobRef? {
      guard !selected.isEmpty else { return nil }
      var refs: [CloudBlobRef] = []
      var pageEntries: [CloudBackupEntry] = []
      var pageBytes = 0
      for entry in selected {
        let size = try CloudWire.canonical(entry).count
        guard size <= CloudWire.maximumPlainChunkBytes - 1024 else { throw CloudBackupError.limitExceeded }
        if !pageEntries.isEmpty && (pageEntries.count == 64 || pageBytes + size > 1024 * 1024) {
          refs.append(try await seal(CloudWire.canonical(TreePage(v: 1, entries: pageEntries, children: [])), storageClass))
          pageEntries = []; pageBytes = 0
        }
        pageEntries.append(entry); pageBytes += size
      }
      if !pageEntries.isEmpty { refs.append(try await seal(CloudWire.canonical(TreePage(v: 1, entries: pageEntries, children: [])), storageClass)) }
      while refs.count > 1 {
        var parents: [CloudBlobRef] = []
        for offset in stride(from: 0, to: refs.count, by: 64) {
          parents.append(try await seal(CloudWire.canonical(TreePage(v: 1, entries: [], children: Array(refs[offset..<min(offset + 64, refs.count)]))), storageClass))
        }
        refs = parents
      }
      return refs[0]
    }
  }
}
