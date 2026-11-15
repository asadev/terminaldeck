import Foundation
import CryptoKit
import Darwin

public struct CloudBackupArtifactProof: Codable, Equatable, Sendable {
  public let artifactId: String
  public let completionId: String
  public let completedAt: Int64
  public let contentDigest: String
  public let files: Int
  public let bytes: Int64
  public let bundle: Bool
}
public struct CloudBackupArtifactReceipt: Sendable {
  public let file: URL
  public let proof: CloudBackupArtifactProof
}

public enum CloudBackupArtifacts {
  private struct Stamp: Equatable { let path: String; let fingerprint: String; let kind: mode_t; let size: Int64; let link: String? }
  private struct Content: Codable { let path: String; let kind: String; let bytes: Int64; let hash: String; let link: String? }
  private struct BundleInfo: Decodable { let CFBundleExecutable: String }
  public static func inspect(file: URL, artifactId: String, completionId: String, completedAt: Int64,
                             settle: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) async throws -> CloudBackupArtifactReceipt {
    guard file.isFileURL, !artifactId.isEmpty, !completionId.isEmpty else { throw CloudBackupError.invalidManifest }
    let parent = try CloudBackupDirectory(path: file.deletingLastPathComponent().path)
    let name = file.lastPathComponent
    _ = try CloudBackupPaths.components(name)
    let rootInfo = try parent.info(name)
    let bundle = rootInfo.st_mode & S_IFMT == S_IFDIR
    if bundle {
      guard file.pathExtension.lowercased() == "app" else { throw CloudBackupError.unsupportedFile }
      let directory = try parent.directory(name)
      let (infoFolder, infoName) = try directory.parent(of: "Contents/Info.plist")
      let fd = try infoFolder.file(infoName); defer { close(fd) }
      let bytes = try CloudBackupDirectory.readChunk(fd, maximum: 1024 * 1024 + 1)
      guard bytes.count <= 1024 * 1024 else { throw CloudBackupError.limitExceeded }
      let info = try PropertyListDecoder().decode(BundleInfo.self, from: bytes)
      guard try CloudBackupPaths.components(info.CFBundleExecutable).count == 1 else { throw CloudBackupError.unsafePath }
      let (executableFolder, executableName) = try directory.parent(of: "Contents/MacOS/" + info.CFBundleExecutable)
      let executable = try executableFolder.file(executableName); close(executable)
    } else { guard rootInfo.st_mode & S_IFMT == S_IFREG else { throw CloudBackupError.unsupportedFile } }
    let first = try stamps(parent: parent, name: name)
    try await settle()
    let second = try stamps(parent: parent, name: name)
    guard first == second else { throw CloudBackupError.changedDuringRead }
    let content = try content(parent: parent, name: name, stamps: second, bundle: bundle)
    guard try stamps(parent: parent, name: name) == second else { throw CloudBackupError.changedDuringRead }
    let proof = CloudBackupArtifactProof(artifactId: artifactId, completionId: completionId, completedAt: completedAt,
      contentDigest: try CloudBackupDigest.of(content), files: content.filter { $0.kind == "file" }.count,
      bytes: content.reduce(0) { $0 + $1.bytes }, bundle: bundle)
    return .init(file: file, proof: proof)
  }
  static func digest(entries: [CloudBackupEntry], at path: String, bundle: Bool) throws -> String {
    let prefix = path + "/"
    let selected = entries.filter { CloudBackupPaths.key($0.relativePath) == CloudBackupPaths.key(path) || $0.relativePath.utf8.starts(with: prefix.utf8) }
    let content = selected.map { entry -> Content in
      let relative = bundle ? (entry.relativePath == path ? "" : String(entry.relativePath.dropFirst(prefix.count))) : ""
      return .init(path: relative, kind: entry.type.rawValue, bytes: entry.type == .file ? entry.size : 0, hash: entry.plainHash, link: entry.linkTarget)
    }.sorted { CloudBackupPaths.precedes($0.path, $1.path) }
    return try CloudBackupDigest.of(content)
  }
  private static func stamps(parent: CloudBackupDirectory, name: String) throws -> [Stamp] {
    var result: [Stamp] = []
    func visit(_ directory: CloudBackupDirectory, _ name: String, _ path: String, _ depth: Int) throws {
      guard depth <= 128, result.count < 100_000 else { throw CloudBackupError.limitExceeded }
      let info = try directory.info(name), kind = info.st_mode & S_IFMT
      guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind) else { throw CloudBackupError.unsupportedFile }
      let link = kind == S_IFLNK ? try directory.link(name) : nil
      if let link { try CloudBackupPaths.safeLink(link, at: path) }
      result.append(.init(path: path, fingerprint: CloudBackupDirectory.fingerprint(info), kind: kind, size: Int64(info.st_size), link: link))
      if kind == S_IFDIR {
        let child = try directory.directory(name)
        for item in try child.names() { try visit(child, item, path.isEmpty ? item : path + "/" + item, depth + 1) }
      }
    }
    try visit(parent, name, "", 0)
    return result
  }
  private static func content(parent: CloudBackupDirectory, name: String, stamps: [Stamp], bundle: Bool) throws -> [Content] {
    let root = bundle ? try parent.directory(name) : parent
    var result: [Content] = [], total: Int64 = 0
    for stamp in stamps {
      if stamp.kind == S_IFDIR { result.append(.init(path: stamp.path, kind: "directory", bytes: 0, hash: "", link: nil)); continue }
      if let link = stamp.link { result.append(.init(path: stamp.path, kind: "symlink", bytes: 0, hash: CloudBackupDigest.sha256(Data(link.utf8)), link: link)); continue }
      guard stamp.size >= 0, stamp.size <= 8 * 1024 * 1024 * 1024, total <= 64 * 1024 * 1024 * 1024 - stamp.size else { throw CloudBackupError.limitExceeded }
      total += stamp.size
      let (folder, leaf) = bundle ? try root.parent(of: stamp.path) : (root, name)
      let fd = try folder.file(leaf); defer { close(fd) }
      var checksum = SHA256(), count: Int64 = 0
      while true {
        let data = try CloudBackupDirectory.readChunk(fd, maximum: CloudWire.maximumPlainChunkBytes)
        if data.isEmpty { break }
        count += Int64(data.count)
        guard count <= stamp.size else { throw CloudBackupError.changedDuringRead }
        checksum.update(data: data)
      }
      guard count == stamp.size, CloudBackupDirectory.fingerprint(try folder.info(leaf)) == stamp.fingerprint else { throw CloudBackupError.changedDuringRead }
      result.append(.init(path: stamp.path, kind: "file", bytes: count, hash: checksum.finalize().map { String(format: "%02x", $0) }.joined(), link: nil))
    }
    return result
  }
}
