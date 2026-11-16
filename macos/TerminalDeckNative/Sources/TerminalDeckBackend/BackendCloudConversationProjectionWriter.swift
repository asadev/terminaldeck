import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendCloudConversationProjectedFile: Sendable {
  /// Stable for one (manifest, destination folder): a second Continue reuses it and continues the same branch.
  public let branchID: String
  public let providerHome: URL
  public let file: URL
  public let conversationID: String
  public let rawHash: String
  public let projectedHash: String
  public let transformManifest: URL
  public let supportFiles: [URL]
}

/// Called only inside the explicitly leased Continue. Output goes to one private folder per (manifest, new path).
/// JSONL is streamed line by line; a long conversation has no whole-file size limit. Raw intermediates are removed
/// once the transform manifest is written; the immutable raw archive is never changed.
public enum BackendCloudConversationProjectionWriter {
  public static func branchID(manifestID: String, provider: CloudConversationProvider, newPath: String) throws -> String {
    try CloudConversationIdentity.uuid(["conversation-branch", provider.rawValue, manifestID, newPath])
  }
  public static func project(archive: BackendCloudConversationArchive, manifestID: String, provider: CloudConversationProvider,
                             conversationID: String, projectID: String, rootID: String, oldPath: String, newPath: String,
                             stagingDirectory: URL) async throws -> BackendCloudConversationProjectedFile {
    guard conversationID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
      oldPath.hasPrefix("/"), newPath.hasPrefix("/"), !projectID.isEmpty, !rootID.isEmpty else { throw CloudFailure.invalidRequest }
    let manifest = try await archive.metadata(manifestID: manifestID)
    guard manifest.payload.raw["provider"].string == provider.rawValue,
      let relative = manifest.payload.raw["relativePath"].string else { throw CloudFailure.invalidRequest }
    let prefix = manifest.payload.raw["relativePrefix"].string ?? ""
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard stagingDirectory.standardizedFileURL == stagingDirectory.resolvingSymlinksInPath().standardizedFileURL else { throw CloudFailure.unsafeConfiguration }
    let branch = try branchID(manifestID: manifestID, provider: provider, newPath: newPath)
    let root = stagingDirectory.appendingPathComponent(branch)
    if let existing = try reuse(root: root, branchID: branch, conversationID: conversationID, newPath: newPath, provider: provider) { return existing }
    // A folder without a transform manifest was never launched; it holds only this writer's partial output.
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    guard mkdir(root.path, 0o700) == 0 else { throw CloudFailure.unavailable }
    var finished = false
    defer { if !finished { try? FileManager.default.removeItem(at: root) } }
    var intermediates: [URL] = []
    let source = root.appendingPathComponent("source.raw"); intermediates.append(source)
    let raw = try NativeTranscriptPaths.createCloudProjectionFile(relative: "source.raw", in: root)
    defer { try? raw.close() }
    var index = 0
    while let bytes = try await archive.chunkAt(manifestID: manifestID, index: index) {
      try Task.checkCancellation(); try raw.write(contentsOf: bytes); index += 1
    }
    try raw.synchronize(); try raw.close()
    let rawHash = try BackendNodelessPackagingFiles.digest(source, within: root)
    let home = root.appendingPathComponent("provider-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let destination: String
    switch provider {
    case .claude:
      guard URL(fileURLWithPath: relative).lastPathComponent == conversationID + ".jsonl" else { throw CloudFailure.unsupportedFormat }
      destination = "projects/" + NativeTranscriptPaths.encodeProjectPath(newPath) + "/" + conversationID + ".jsonl"
    case .codex:
      destination = "sessions/" + (try codexSessionRelative(relative, prefix: prefix, conversationID: conversationID))
    case .gemini:
      let name = URL(fileURLWithPath: relative).lastPathComponent
      guard name.hasPrefix("session-"), ["json", "jsonl"].contains(URL(fileURLWithPath: name).pathExtension) else { throw CloudFailure.unsupportedFormat }
      destination = ".gemini/tmp/" + CloudSyncBytes.hash(Data(newPath.utf8)) + "/chats/" + name
    }
    let writeRoot = provider == .codex ? root : home
    let writeRelative = provider == .codex ? "codex-projection.jsonl" : destination
    if provider == .codex { intermediates.append(root.appendingPathComponent(writeRelative)) }
    let output = try NativeTranscriptPaths.createCloudProjectionFile(relative: writeRelative, in: writeRoot)
    defer { try? output.close() }
    if provider == .gemini && URL(fileURLWithPath: relative).pathExtension == "json" {
      let bytes = try await archive.read(manifestID: manifestID, offset: 0, limit: CloudWire.maximumPlainChunkBytes)
      guard Int64(bytes.count) == Int64(manifest.payload.raw["bytes"].string!) else { throw CloudFailure.unsupportedFormat }
      let mapped = try CloudConversationProjection.project(bytes, provider: provider, conversationID: conversationID, oldPath: oldPath, newPath: newPath, jsonLines: false)
      try output.write(contentsOf: mapped.bytes)
    } else {
      try streamLines(source: source, root: root, output: output, provider: provider, conversationID: conversationID, oldPath: oldPath, newPath: newPath)
    }
    try output.synchronize(); try output.close()
    let projectedFile: URL
    if provider == .codex {
      let sessionRelative = String(destination.dropFirst("sessions/".count))
      let thread = BackendSessionSwitchCodexCarry.Thread(id: conversationID, file: root.appendingPathComponent(writeRelative), relative: sessionRelative)
      guard let carried = BackendSessionSwitchCodexCarry.carry(thread, targetHome: home.path) else { throw CloudFailure.unsupportedFormat }
      projectedFile = carried
    } else { projectedFile = home.appendingPathComponent(destination) }
    let projectedHash = try BackendNodelessPackagingFiles.digest(projectedFile, within: root)
    var supportFiles: [URL] = [], supportRecords: [NativeRPCValue] = []
    if provider == .claude {
      let support = try await archive.claudeSupport(mainManifestID: manifestID, conversationID: conversationID)
      let oldFolder = relative.split(separator: "/").dropLast().joined(separator: "/")
      let oldPrefix = oldFolder.isEmpty ? "" : oldFolder + "/"
      let newPrefix = "projects/" + NativeTranscriptPaths.encodeProjectPath(newPath) + "/"
      for item in support {
        let sourceRelative = item.payload.raw["relativePath"].string!
        let targetRelative = newPrefix + String(sourceRelative.dropFirst(oldPrefix.count))
        let sourceName = "support-" + item.opId + ".raw"
        intermediates.append(root.appendingPathComponent(sourceName))
        let rawHandle = try NativeTranscriptPaths.createCloudProjectionFile(relative: sourceName, in: root)
        do {
          var part = 0
          while let bytes = try await archive.chunkAt(manifestID: item.opId, index: part) { try rawHandle.write(contentsOf: bytes); part += 1 }
          try rawHandle.synchronize(); try rawHandle.close()
        } catch { try? rawHandle.close(); throw error }
        let target = try NativeTranscriptPaths.createCloudProjectionFile(relative: targetRelative, in: home)
        do {
          if sourceRelative.hasSuffix("/sessions-index.json") || sourceRelative == "sessions-index.json" {
            let bytes = try await archive.read(manifestID: item.opId, offset: 0, limit: CloudWire.maximumPlainChunkBytes)
            guard Int64(bytes.count) == Int64(item.payload.raw["bytes"].string!) else { throw CloudFailure.unsupportedFormat }
            var index = try NativeRPCValue.parseJSON(bytes)
            guard index["version"].number == 1, let entries = index["entries"].elements else { throw CloudFailure.unsupportedFormat }
            let matches = entries.filter { $0["sessionId"].string == conversationID }
            guard matches.count == 1 else { throw CloudFailure.unsupportedFormat }
            let entry = matches[0].setting("fullPath", .string(projectedFile.path)).setting("projectPath", .string(newPath))
            index = index.setting("entries", .array([entry]))
            if index["originalPath"].string == oldPath { index = index.setting("originalPath", .string(newPath)) }
            try target.write(contentsOf: index.encodedJSON())
          } else if sourceRelative.hasSuffix(".jsonl") {
            try streamLines(source: root.appendingPathComponent(sourceName), root: root, output: target,
              provider: .claude, conversationID: conversationID, oldPath: oldPath, newPath: newPath)
          } else {
            // Other support records (for example tool results) are carried byte-for-byte.
            var part = 0
            while let bytes = try await archive.chunkAt(manifestID: item.opId, index: part) { try target.write(contentsOf: bytes); part += 1 }
          }
          try target.synchronize(); try target.close()
        } catch { try? target.close(); throw error }
        let outputURL = home.appendingPathComponent(targetRelative)
        supportRecords.append(.object([.init("v", .number(1)), .init("provider", .string("claude")), .init("version", .number(1)),
          .init("rawHash", .string(try BackendNodelessPackagingFiles.digest(root.appendingPathComponent(sourceName), within: root))),
          .init("projectedHash", .string(try BackendNodelessPackagingFiles.digest(outputURL, within: root))),
          .init("projectId", .string(projectID)), .init("rootId", .string(rootID)), .init("oldPath", .string(oldPath)),
          .init("newPath", .string(newPath)), .init("conversationId", .string(conversationID)), .init("file", .string(targetRelative))]))
        supportFiles.append(outputURL)
      }
    }
    let record = NativeRPCValue.object([.init("v", .number(1)), .init("provider", .string(provider.rawValue)), .init("version", .number(1)),
      .init("rawHash", .string(rawHash)), .init("projectedHash", .string(projectedHash)), .init("projectId", .string(projectID)),
      .init("rootId", .string(rootID)), .init("oldPath", .string(oldPath)), .init("newPath", .string(newPath)), .init("conversationId", .string(conversationID)),
      .init("file", .string(String(projectedFile.standardizedFileURL.path.dropFirst(home.standardizedFileURL.path.count + 1)))),
      .init("support", .array(supportRecords))])
    let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
    try persistence.write("transform.json", value: record)
    // The transform manifest records both hashes; the plaintext intermediates are not kept as extra copies.
    for file in intermediates { if unlink(file.path) != 0, errno != ENOENT { throw CloudFailure.unavailable } }
    finished = true
    return .init(branchID: branch, providerHome: home, file: projectedFile, conversationID: conversationID, rawHash: rawHash,
      projectedHash: projectedHash, transformManifest: root.appendingPathComponent("transform.json"), supportFiles: supportFiles)
  }
  /// A completed earlier projection for the same (manifest, destination) is reused, including turns made since.
  private static func reuse(root: URL, branchID: String, conversationID: String, newPath: String,
                            provider: CloudConversationProvider) throws -> BackendCloudConversationProjectedFile? {
    let persistence = try BackendTaskPersistence(directory: root, ownership: .readOnly)
    guard FileManager.default.fileExists(atPath: root.path), let record = try persistence.read("transform.json") else { return nil }
    let home = root.appendingPathComponent("provider-home")
    guard record["conversationId"].string == conversationID, record["newPath"].string == newPath, record["provider"].string == provider.rawValue,
      let file = record["file"].string, CloudConversationEnumerator.safeRelative(file), let rawHash = record["rawHash"].string,
      let projectedHash = record["projectedHash"].string else { throw CloudFailure.unsupportedFormat }
    let support = try (record["support"].elements ?? []).map { item -> URL in
      guard let name = item["file"].string, CloudConversationEnumerator.safeRelative(name) else { throw CloudFailure.unsupportedFormat }
      return home.appendingPathComponent(name)
    }
    return .init(branchID: branchID, providerHome: home, file: home.appendingPathComponent(file), conversationID: conversationID, rawHash: rawHash,
      projectedHash: projectedHash, transformManifest: root.appendingPathComponent("transform.json"), supportFiles: support)
  }
  /// Codex keeps live rollouts under `sessions/YYYY/MM/DD/`; an archived rollout is flat, so its date comes from its own name.
  static func codexSessionRelative(_ relative: String, prefix: String, conversationID: String) throws -> String {
    let parts = relative.split(separator: "/").map(String.init)
    guard let name = parts.last, name.hasSuffix(".jsonl"), name.contains(conversationID) else { throw CloudFailure.unsupportedFormat }
    if prefix != "archived_sessions", parts.count == 4 { return relative }
    guard prefix == "archived_sessions", parts.count == 1,
      let match = name.range(of: #"^rollout-(\d{4})-(\d{2})-(\d{2})T"#, options: .regularExpression) else { throw CloudFailure.unsupportedFormat }
    let date = name[match].dropFirst("rollout-".count).dropLast()
    let fields = date.split(separator: "-").map(String.init)
    guard fields.count == 3 else { throw CloudFailure.unsupportedFormat }
    return fields.joined(separator: "/") + "/" + name
  }
  /// Step 2 ("Switch to this Mac"): the same per-record projection from any byte source (here: a chat read back from
  /// the Cloud's raw copy into a file), streamed line by line, and lenient: a line it cannot map (another conversation's
  /// record, a line that is not JSON) is written exactly as it was. Only provider-owned metadata changes (the folder,
  /// Gemini's project hash); message and tool text is never searched. The source is never changed.
  public static func rewrite(source: URL, into output: FileHandle, provider: CloudConversationProvider, conversationID: String,
                             oldPath: String, newPath: String) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    if provider == .gemini, source.pathExtension != "jsonl" {
      // Gemini keeps one JSON document: mapped whole when it fits, else carried as it is.
      let bytes = try input.readToEnd() ?? Data()
      if oldPath != newPath, let mapped = try? CloudConversationProjection.project(bytes, provider: provider, conversationID: conversationID,
                                                                                   oldPath: oldPath, newPath: newPath, jsonLines: false) {
        try output.write(contentsOf: mapped.bytes)
      } else { try output.write(contentsOf: bytes) }
      return
    }
    func write(_ line: Data, newline: Bool) throws {
      if !line.isEmpty {
        if oldPath != newPath, let value = try? NativeRPCValue.parseJSON(line, maximumBytes: CloudWire.maximumPlainChunkBytes),
           let mapped = try? CloudConversationProjection.mapRecord(value, provider: provider, conversationID: conversationID, oldPath: oldPath, newPath: newPath),
           mapped.value != value, let encoded = try? mapped.value.encodedJSON() {
          try output.write(contentsOf: encoded)
        } else { try output.write(contentsOf: line) }
      }
      if newline { try output.write(contentsOf: Data([10])) }
    }
    var buffer = Data()
    while true {
      let bytes = try input.read(upToCount: 1_048_576) ?? Data()
      if bytes.isEmpty { break }
      buffer.append(bytes)
      var start = buffer.startIndex
      while let end = buffer[start...].firstIndex(of: 10) {
        try write(Data(buffer[start..<end]), newline: true)
        start = end + 1
      }
      if start > buffer.startIndex { buffer.removeSubrange(..<start) }
      if buffer.count > CloudWire.maximumPlainChunkBytes { try output.write(contentsOf: buffer); buffer.removeAll() }
    }
    if !buffer.isEmpty { try write(buffer, newline: false) }
  }
  private static func streamLines(source: URL, root: URL, output: FileHandle, provider: CloudConversationProvider,
                                  conversationID: String, oldPath: String, newPath: String) throws {
    let descriptor = try CloudConversationFileAccess.open(root: root, relativePath: source.lastPathComponent)
    defer { Darwin.close(descriptor) }
    var buffer = Data(), identity = false, path = false
    func write(_ line: Data, newline: Bool) throws {
      if !line.isEmpty {
        let value = try NativeRPCValue.parseJSON(line, maximumBytes: CloudWire.maximumPlainChunkBytes)
        let mapped = try CloudConversationProjection.mapRecord(value, provider: provider, conversationID: conversationID, oldPath: oldPath, newPath: newPath)
        identity = identity || mapped.identity; path = path || mapped.path
        try output.write(contentsOf: mapped.value == value ? line : mapped.value.encodedJSON())
      }
      if newline { try output.write(contentsOf: Data([10])) }
    }
    while true {
      let bytes = try CloudConversationFileAccess.read(descriptor, count: 64 * 1024)
      if bytes.isEmpty { break }
      buffer.append(bytes)
      var start = buffer.startIndex
      while let end = buffer[start...].firstIndex(of: 10) {
        try write(Data(buffer[start..<end]), newline: true)
        start = end + 1
      }
      if start > buffer.startIndex { buffer.removeSubrange(..<start) }
      guard buffer.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.unsupportedFormat }
    }
    if !buffer.isEmpty { try write(buffer, newline: false) }
    guard identity, path else { throw CloudFailure.unsupportedFormat }
  }
}
