import Foundation
import Darwin

/// Only sealed envelope bytes cross this boundary. Domain owners retain classification and decryption.
struct CloudSyncSealedFile: Sendable {
  let file: CloudLocalBlob
  let bytes: Data

  init(_ file: CloudLocalBlob) throws {
    guard file.localURL.isFileURL, file.bytes > 0, file.bytes <= CloudWire.maximumBlobBytes else { throw CloudFailure.invalidRequest }
    let fd = Darwin.open(file.localURL.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw CloudFailure.unavailable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == file.bytes,
      let bytes = try handle.read(upToCount: CloudWire.maximumBlobBytes + 1) else { throw CloudFailure.checksumMismatch }
    try Self.validate(bytes, reference: file.reference)
    self.file = file; self.bytes = bytes
  }
  static func validate(_ bytes: Data, reference ref: CloudBlobRef) throws {
    try CloudSyncBytes.transportID(ref.blobId)
    try CloudSyncBytes.verify(bytes, ref: ref)
    let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: bytes,
      allowedKeys: ["v", "suite", "class", "purpose", "epoch", "blobId", "codec", "plainBytes", "nonce", "ciphertext", "tag"], maximumBytes: CloudWire.maximumBlobBytes)
    guard envelope.v == 1, envelope.suite == "A256GCM-HKDF-SHA256", ref.keyEpoch > 0,
      ref.purpose.permits(ref.storageClass), envelope.blobId == ref.blobId, envelope.epoch == ref.keyEpoch,
      envelope.storageClass == ref.storageClass, envelope.purpose == ref.purpose,
      envelope.plainBytes >= 0, envelope.plainBytes <= CloudWire.maximumPlainChunkBytes,
      try CloudSyncBytes.unbase64(envelope.nonce).count == 12,
      try CloudSyncBytes.unbase64(envelope.tag).count == 16,
      try CloudSyncBytes.unbase64(envelope.ciphertext).count <= CloudWire.maximumPlainChunkBytes,
      try CloudSyncCanonical.encode(envelope) == bytes else { throw CloudFailure.checksumMismatch }
  }
  static func references(in operations: [CloudOperation]) throws -> [CloudBlobRef] {
    var refs: [String: CloudBlobRef] = [:]
    func visit(_ value: OrderedJSON, depth: Int) throws {
      guard depth < 64 else { throw CloudFailure.invalidRequest }
      if let fields = value.fields {
        let keys = Set(fields.map(\.key))
        if keys == Set(["blobId", "sha256", "md5", "bytes", "class", "purpose", "keyEpoch"]) {
          let ref = try CloudWire.decode(CloudBlobRef.self, from: Data(value.compact.utf8))
          try CloudSyncBytes.transportID(ref.blobId)
          guard ref.bytes > 0, ref.bytes <= CloudWire.maximumBlobBytes, ref.keyEpoch > 0,
            ref.purpose.permits(ref.storageClass) else { throw CloudFailure.invalidRequest }
          if let old = refs[ref.blobId], old != ref { throw CloudFailure.idReused }
          refs[ref.blobId] = ref
        } else { for field in fields { try visit(field.value, depth: depth + 1) } }
      } else if let children = value.array { for child in children { try visit(child, depth: depth + 1) } }
    }
    for op in operations {
      guard let value = OrderedJSON.parse(try CloudSyncCanonical.encode(op.payload)) else { throw CloudFailure.invalidRequest }
      try visit(value, depth: 0)
    }
    return refs.values.sorted { $0.blobId < $1.blobId }
  }
}

extension CloudSyncStore {
  func retainFile(_ file: CloudSyncSealedFile) throws {
    let ref = file.file.reference
    try execute("INSERT OR IGNORE INTO retained_files(blobId,sourceId) VALUES (?,?)", [Data(ref.blobId.utf8), Data(file.file.sourceId.utf8)])
    if let old = try rows("SELECT bytes,descriptor FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first {
      guard old[0] == file.bytes, old[1] == (try CloudSyncCanonical.encode(ref)) else { throw CloudFailure.idReused }
    } else {
      try execute("INSERT INTO objects(blobId,bytes,descriptor) VALUES (?,?,?)", [Data(ref.blobId.utf8), file.bytes, try CloudSyncCanonical.encode(ref)])
    }
  }
  func fileReferences(for operationIds: [String]) throws -> [CloudBlobRef] {
    var refs: [String: CloudBlobRef] = [:]
    for id in operationIds {
      for row in try rows("SELECT objects.descriptor FROM objects JOIN outbox_files ON objects.blobId=outbox_files.blobId WHERE outbox_files.opId=?", [Data(id.utf8)]) {
        let ref = try JSONDecoder().decode(CloudBlobRef.self, from: row[0]); refs[ref.blobId] = ref
      }
    }
    return refs.values.sorted { $0.blobId < $1.blobId }
  }
  func materialize(_ bytes: Data, reference ref: CloudBlobRef, sourceId: String) throws -> CloudLocalBlob {
    try CloudSyncSealedFile.validate(bytes, reference: ref)
    let directory = root.appendingPathComponent("sealed", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(ref.blobId)
    // Always restore from the checked durable object, never trust a previous handoff file.
    try bytes.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw CloudFailure.unavailable }
    defer { Darwin.close(fd) }
    guard Darwin.fcntl(fd, F_FULLFSYNC) == 0 else { throw CloudFailure.unavailable }
    let dir = Darwin.open(directory.path, O_RDONLY)
    guard dir >= 0 else { throw CloudFailure.unavailable }
    defer { Darwin.close(dir) }
    guard Darwin.fsync(dir) == 0 else { throw CloudFailure.unavailable }
    let parent = Darwin.open(root.path, O_RDONLY)
    guard parent >= 0 else { throw CloudFailure.unavailable }
    defer { Darwin.close(parent) }
    guard Darwin.fsync(parent) == 0 else { throw CloudFailure.unavailable }
    return .init(blobId: ref.blobId, sourceId: sourceId, localURL: url, bytes: ref.bytes, sha256: ref.sha256,
      md5: ref.md5, keyEpoch: ref.keyEpoch, storageClass: ref.storageClass, purpose: ref.purpose)
  }
}
