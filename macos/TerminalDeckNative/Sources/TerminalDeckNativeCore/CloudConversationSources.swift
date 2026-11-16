import Foundation
import Darwin

public enum CloudConversationProvider: String, Codable, Sendable, CaseIterable {
  case claude, codex, gemini
  public var inventoryRow: String { switch self { case .claude: "I17"; case .codex: "I18"; case .gemini: "I19" } }
  public var domain: String { "conversations-" + rawValue }
}

/// A conversation continued on this Mac is a distinct branch of its raw parent (§5.5), never an overwrite of it.
public struct CloudConversationBranch: Codable, Sendable, Equatable {
  public let parentManifest: String
  public let conversationId: String
  public let deviceId: String
  public init(parentManifest: String, conversationId: String, deviceId: String) {
    self.parentManifest = parentManifest; self.conversationId = conversationId; self.deviceId = deviceId
  }
  public var value: NativeRPCValue {
    .object([.init("parentManifest", .string(parentManifest)), .init("conversationId", .string(conversationId)), .init("deviceId", .string(deviceId))])
  }
  public static func parse(_ value: NativeRPCValue) throws -> CloudConversationBranch {
    guard Set((value.fields ?? []).map(\.key)) == ["parentManifest", "conversationId", "deviceId"],
      let parent = value["parentManifest"].string, UUID(uuidString: parent) != nil,
      let conversation = value["conversationId"].string, conversation.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
      let device = value["deviceId"].string, UUID(uuidString: device) != nil else { throw CloudFailure.invalidRequest }
    return .init(parentManifest: parent, conversationId: conversation, deviceId: device)
  }
}

/// Roots come from the authenticated profile/home owners. There is deliberately no ambient-home default.
/// `sourceID` is derived from the owner's stable home key, never from the home's absolute path.
public struct CloudConversationRoot: Sendable {
  public let sourceID: String
  public let profileID: String
  public let profileIDs: [String]
  public let provider: CloudConversationProvider
  public let directory: URL
  public let relativePrefix: String
  public let singleFile: String?
  public let branch: CloudConversationBranch?
  public init(sourceID: String, profileID: String, provider: CloudConversationProvider, directory: URL,
              relativePrefix: String = "", singleFile: String? = nil, aliasProfileIDs: [String] = [], branch: CloudConversationBranch? = nil) {
    self.sourceID = sourceID; self.profileID = profileID; self.profileIDs = Array(Set([profileID] + aliasProfileIDs)).sorted(); self.provider = provider
    self.directory = directory; self.relativePrefix = relativePrefix; self.singleFile = singleFile; self.branch = branch
  }
}

public struct CloudConversationFile: Sendable {
  public let root: CloudConversationRoot
  public let relativePath: String
  public let bytes: Int64
  public let modifiedAt: Int64
  /// Same format as `CloudConversationFileAccess.stamp`: an unchanged stamp means the file is not read again.
  public let stamp: String
}

/// A directory cursor is advanced only when the consumer asks. No tail, file-count or depth cap exists.
/// Every regular file under an approved root is exported as raw history; only chat files can later be continued.
public actor CloudConversationEnumerator {
  private let roots: [CloudConversationRoot]
  private var rootIndex = 0
  private var cursor: FileManager.DirectoryEnumerator?
  private var started = false
  private var visitedSingle = false
  private var scanErrors = CloudConversationScanErrors()
  private var counts: [String: (items: Int, bytes: Int64, reasons: Set<String>)] = [:]
  public init(roots: [CloudConversationRoot]) throws {
    guard !roots.isEmpty, Set(roots.map(\.sourceID)).count == roots.count,
      roots.allSatisfy({ !$0.sourceID.isEmpty && !$0.profileID.isEmpty && $0.directory.isFileURL && $0.directory.path.hasPrefix("/") }) else { throw CloudFailure.invalidRequest }
    self.roots = roots
  }
  public func next() throws -> CloudConversationFile? {
    while rootIndex < roots.count {
      try Task.checkCancellation()
      let root = roots[rootIndex]
      if !started {
        started = true; visitedSingle = false; scanErrors = CloudConversationScanErrors()
        counts[root.sourceID] = (0, 0, [])
        var info = stat()
        guard lstat(root.directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
          blocked(root.sourceID, "The approved source directory could not be read."); finishRoot(); continue
        }
        if root.singleFile == nil {
          let errors = scanErrors
          cursor = FileManager.default.enumerator(at: root.directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in errors.record(); return true })
          if cursor == nil { blocked(root.sourceID, "The source directory could not be enumerated."); finishRoot(); continue }
        }
      }
      let file: URL
      if let name = root.singleFile {
        if visitedSingle { finishRoot(); continue }
        visitedSingle = true
        guard Self.safeRelative(name), !name.contains("/") else { throw CloudFailure.invalidRequest }
        file = root.directory.appendingPathComponent(name)
        var info = stat()
        if lstat(file.path, &info) != 0 { finishRoot(); continue }
      } else {
        guard let next = cursor?.nextObject() as? URL else { finishRoot(); continue }
        file = next
      }
      let relative = String(file.path.dropFirst(root.directory.path.count + 1))
      guard Self.safeRelative(relative) else { blocked(root.sourceID, "An unsafe source path was refused."); continue }
      var info = stat()
      guard lstat(file.path, &info) == 0 else { blocked(root.sourceID, "A source entry could not be inspected."); continue }
      if info.st_mode & S_IFMT == S_IFLNK {
        cursor?.skipDescendants(); blocked(root.sourceID, "A source link needs an explicit approved root."); continue
      }
      let components = relative.split(separator: "/")
      // Provider memory belongs to lane A's I09 adapter; version-control internals are not conversation history.
      if components.contains("memory") || components.contains(".git") { cursor?.skipDescendants(); continue }
      if info.st_mode & S_IFMT == S_IFDIR { continue }
      guard info.st_mode & S_IFMT == S_IFREG else { blocked(root.sourceID, "A source entry is not a regular file."); continue }
      counts[root.sourceID]!.items += 1; counts[root.sourceID]!.bytes += info.st_size
      return .init(root: root, relativePath: relative, bytes: info.st_size,
        modifiedAt: Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000,
        stamp: CloudConversationFileAccess.stamp(info))
    }
    return nil
  }
  public func reportFailure(sourceID: String) { blocked(sourceID, "A source file was unreadable or changed during export.") }
  public func completedSources() -> Set<String> {
    Set(roots.prefix(rootIndex).filter { counts[$0.sourceID]?.reasons.isEmpty == true }.map(\.sourceID))
  }
  public func coverage() -> [CloudCoverage] {
    roots.map { root in
      let count = counts[root.sourceID] ?? (0, 0, Set<String>())
      var reasons = count.reasons
      if count.items == 0 { reasons.insert("No conversation files were exported; this source is not verified complete.") }
      if rootIndex < roots.count { reasons.insert("Source enumeration is still in progress.") }
      return .init(sourceId: root.sourceID, inventoryRow: root.provider.inventoryRow, complete: reasons.isEmpty,
        items: count.items, bytes: count.bytes, blockedReasons: reasons.sorted())
    }
  }
  private func blocked(_ sourceID: String, _ reason: String) { counts[sourceID, default: (0, 0, [])].reasons.insert(reason) }
  private func finishRoot() {
    if scanErrors.hasError { blocked(roots[rootIndex].sourceID, "One or more source directories were unreadable.") }
    cursor = nil; started = false; rootIndex += 1
  }
  public static func safeRelative(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

private final class CloudConversationScanErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false
  func record() { lock.withLock { failed = true } }
  var hasError: Bool { lock.withLock { failed } }
}

/// openat + O_NOFOLLOW protects every component, including a directory swapped after enumeration.
public enum CloudConversationFileAccess {
  public static func open(root: URL, relativePath: String) throws -> Int32 {
    guard CloudConversationEnumerator.safeRelative(relativePath) else { throw CloudFailure.unsafeConfiguration }
    guard root.path.hasPrefix("/") else { throw CloudFailure.unsafeConfiguration }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CloudFailure.unavailable }
    let rootParts = root.standardizedFileURL.path.split(separator: "/").map(String.init)
    for part in rootParts {
      let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      Darwin.close(descriptor)
      guard next >= 0 else { throw CloudFailure.unavailable }; descriptor = next
    }
    let parts = relativePath.split(separator: "/").map(String.init)
    for (index, part) in parts.enumerated() {
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index == parts.count - 1 ? 0 : O_DIRECTORY)
      let next = openat(descriptor, part, flags)
      Darwin.close(descriptor)
      guard next >= 0 else { throw CloudFailure.unavailable }; descriptor = next
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(descriptor); throw CloudFailure.unavailable }
    return descriptor
  }
  public static func stamp(_ descriptor: Int32) throws -> String {
    var info = stat(); guard fstat(descriptor, &info) == 0 else { throw CloudFailure.unavailable }
    return stamp(info)
  }
  public static func stamp(_ info: stat) -> String {
    "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
  }
  /// Device and inode decide whether earlier chunk boundaries can still describe this file.
  public static func identity(_ descriptor: Int32) throws -> (device: Int64, inode: UInt64, size: Int64) {
    var info = stat(); guard fstat(descriptor, &info) == 0 else { throw CloudFailure.unavailable }
    return (Int64(info.st_dev), UInt64(info.st_ino), Int64(info.st_size))
  }
  public static func read(_ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    let amount = try data.withUnsafeMutableBytes { buffer -> Int in
      var done = 0
      while done < buffer.count {
        try Task.checkCancellation()
        let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: done), buffer.count - done)
        if amount < 0 { if errno == EINTR { continue }; throw CloudFailure.unavailable }
        if amount == 0 { break }
        done += amount
      }
      return done
    }
    data.count = amount; return data
  }
  /// Positional read; the descriptor's own offset is left unchanged.
  public static func read(_ descriptor: Int32, at offset: Int64, count: Int) throws -> Data {
    guard offset >= 0, count >= 0 else { throw CloudFailure.invalidRequest }
    var data = Data(count: count)
    let amount = try data.withUnsafeMutableBytes { buffer -> Int in
      var done = 0
      while done < buffer.count {
        try Task.checkCancellation()
        let amount = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(offset) + off_t(done))
        if amount < 0 { if errno == EINTR { continue }; throw CloudFailure.unavailable }
        if amount == 0 { break }
        done += amount
      }
      return done
    }
    data.count = amount; return data
  }
  public static func seek(_ descriptor: Int32, to offset: Int64) throws {
    guard lseek(descriptor, off_t(offset), SEEK_SET) == off_t(offset) else { throw CloudFailure.unavailable }
  }
}
