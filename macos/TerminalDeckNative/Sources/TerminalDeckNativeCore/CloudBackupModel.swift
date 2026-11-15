import Foundation
import CryptoKit

/// Local-only catalogue values. These never become tool results or unsealed cloud payloads.
public enum CloudBackupError: Error, Equatable, Sendable {
  case unsafePath, changedDuringRead, unsupportedFile, invalidManifest, limitExceeded
  case destinationChanged, alreadyExists, readbackFailed, unavailable, incomplete
}

public enum CloudBackupDigest {
  public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  static func md5(_ bytes: Data) -> String {
    Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  public static func of<T: Encodable>(_ value: T) throws -> String { sha256(try CloudWire.canonical(value)) }
}

public struct CloudBackupChunk: Codable, Equatable, Sendable {
  public let blob: CloudBlobRef
  public let offset: Int
  public let length: Int
  public let plainHash: String
}
public struct CloudBackupEntry: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case file, directory, symlink }
  public let entryId: String
  public let relativePath: String
  public let type: Kind
  public let mode: UInt16
  public let mtimeNs: String
  public let size: Int64
  public let plainHash: String
  public var chunks: [CloudBackupChunk]
  public let linkTarget: String?
  public let hardlinkGroup: String?
  public let storageClass: CloudStorageClass
  public var database: CloudBackupDatabaseProof? = nil
  public var artifact: CloudBackupArtifactProof? = nil
}
public struct CloudBackupExclusion: Codable, Equatable, Sendable {
  public let relativePath: String
  public let rule: String
  public let count: Int
  public let bytes: Int64
}
public struct CloudBackupMarker: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case archived, renamed, collision }
  public let kind: Kind
  public let path: String
  public let previousPath: String?
}
public struct CloudBackupManifest: Codable, Equatable, Sendable {
  public let v: Int
  public let snapshotId: String
  public let projectId: String
  public let rootId: String
  public let deviceId: String
  public let parentSnapshotId: String?
  public let at: Int64
  public let eventCursor: String
  public let scanComplete: Bool
  public let entries: [CloudBackupEntry]
  public let exclusions: [CloudBackupExclusion]
  public let markers: [CloudBackupMarker]
  public let blocked: [String]
  public let inventoryDigest: String
}
public struct CloudBackupSnapshot: Sendable {
  public let manifest: CloudBackupManifest
  public let root: CloudBlobRef
  public let localReceipt: CloudLocalReceipt
  public let queuedContentChunks: Int
  public let reusedContentChunks: Int
}

/// Local roots are supplied by the existing project authority, never inferred from a folder name.
public struct CloudBackupRoot: Sendable {
  public let projectId: String
  public let rootId: String
  public let deviceId: String
  public let directory: URL
  public let generatedDirectories: Set<String>
  public let finishedArtifacts: Set<String>
  public let verifiedDatabases: [String: CloudBackupDatabaseReceipt]
  public let verifiedArtifacts: [String: CloudBackupArtifactReceipt]
  public let includedPaths: [String]?
  public init(projectId: String, rootId: String, deviceId: String, directory: URL,
              generatedDirectories: Set<String> = [], finishedArtifacts: Set<String> = [], verifiedDatabases: [String: CloudBackupDatabaseReceipt] = [:],
              verifiedArtifacts: [String: CloudBackupArtifactReceipt] = [:], includedPaths: [String]? = nil) {
    self.projectId = projectId; self.rootId = rootId; self.deviceId = deviceId; self.directory = directory
    self.generatedDirectories = generatedDirectories; self.finishedArtifacts = finishedArtifacts; self.verifiedDatabases = verifiedDatabases
    self.verifiedArtifacts = verifiedArtifacts; self.includedPaths = includedPaths
  }
}

public enum CloudBackupPaths {
  // Swift String equality folds canonically equivalent Unicode. File identity must keep the original bytes.
  static func key(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
  static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    let a = lhs.split(separator: "/"), b = rhs.split(separator: "/")
    for index in 0..<min(a.count, b.count) {
      if !a[index].utf8.elementsEqual(b[index].utf8) { return a[index].utf8.lexicographicallyPrecedes(b[index].utf8) }
    }
    return a.count < b.count
  }

  public static func components(_ path: String) throws -> [String] {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains(":"),
      !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
      parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    else { throw CloudBackupError.unsafePath }
    return parts
  }
  public static func safeLink(_ target: String, at path: String) throws {
    // Conservative portability: even in-root '..' links are held rather than reinterpreted on another OS.
    _ = try components(target)
    _ = try components(path)
  }
  static func folded(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}
