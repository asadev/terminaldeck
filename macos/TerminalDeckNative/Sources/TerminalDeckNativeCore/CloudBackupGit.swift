import Foundation
import Darwin

public struct CloudBackupGitFacts: Codable, Equatable, Sendable {
  public struct Reference: Codable, Equatable, Sendable { public let name: String; public let object: String; public var symbolicTarget: String? = nil }
  public struct IndexEntry: Codable, Equatable, Sendable { public let path: String; public let mode: String; public let object: String; public let stage: Int }
  public struct Object: Codable, Equatable, Sendable { public let id: String; public let type: String; public let bytes: Int; public let sha256: String }
  public let v: Int
  public let head: String
  public let branch: String?
  public let objectFormat: String
  public let references: [Reference]
  public let index: [IndexEntry]
  public let objects: [Object]
  public let remoteURLs: [String]
  public let bundleHash: String
}

/// Plain raw objects are authoritative on restore. The archived bundle is never unpacked:
/// raw-object byte bounds avoid delegating decompression bombs to Git's pack reader.
/// A caller backs up this new package with CloudBackupEngine, alongside the working-file snapshot.
public enum CloudBackupGit {
  public typealias Classifier = CloudBackupEngine.Classifier
  private static let limit = 64 * 1024 * 1024

  public static func capture(source: URL, package: URL, classify: Classifier) async throws -> CloudBackupGitFacts {
    guard source.isFileURL, package.isFileURL, package.path != source.path, !package.path.hasPrefix(source.path + "/") else { throw CloudBackupError.unsafePath }
    let root = try CloudBackupDirectory(path: source.path)
    guard let info = try root.infoIfPresent(".git"), info.st_mode & S_IFMT == S_IFDIR else { throw CloudBackupError.incomplete }
    let git = try root.directory(".git")
    try refuseLinks(git)
    // External object stores and conditional config need an owning-authority adapter; do not read through them.
    for path in ["objects/info/alternates", "commondir", "shallow"] {
      if let (parent, name) = try? git.parent(of: path), try parent.infoIfPresent(name) != nil { throw CloudBackupError.incomplete }
    }
    if (try? git.info("worktrees")) != nil, !(try git.directory("worktrees").names()).isEmpty { throw CloudBackupError.incomplete }
    let configFD = try git.file("config")
    defer { close(configFD) }
    let config = try CloudBackupDirectory.readChunk(configFD, maximum: 1024 * 1024 + 1)
    guard config.count <= 1024 * 1024, let text = String(data: config, encoding: .utf8),
      text.range(of: #"(?im)^\s*\[\s*include|promisor\s*=\s*true|partialclone"#, options: .regularExpression) == nil else { throw CloudBackupError.incomplete }
    let packageParent = try CloudBackupDirectory(path: package.deletingLastPathComponent().path)
    guard try !packageParent.isWithin(root) else { throw CloudBackupError.unsafePath }
    let output = try packageParent.createDirectory(package.lastPathComponent)
    _ = try output.createDirectory("objects")
    let controlName = ".cloud-git-control-" + UUID().uuidString
    _ = try packageParent.createDirectory(controlName)
    let control = package.deletingLastPathComponent().appendingPathComponent(controlName)
    defer { unlinkat(packageParent.fd, controlName, AT_REMOVEDIR) }
    let head = try string(run(source, ["rev-parse", "--verify", "HEAD"], control: control))
    let format = try string(run(source, ["rev-parse", "--show-object-format"], control: control))
    guard ["sha1", "sha256"].contains(format), objectID(head) else { throw CloudBackupError.incomplete }
    let branch = try? string(run(source, ["symbolic-ref", "-q", "HEAD"], control: control))
    let refsData = try run(source, ["for-each-ref", "--format=%(objectname) %(refname) %(symref)"], control: control)
    let indexData = try run(source, ["ls-files", "--stage", "-z"], control: control)
    let refs = try references(refsData)
    let index = try indexEntries(indexData)
    guard index.allSatisfy({ $0.mode != "160000" }) else { throw CloudBackupError.incomplete }
    // Any known secret in committed/staged history blocks the Git package until split-object secret export exists.
    // Working files still have independent B/S snapshots; no history is falsely reported as protected or complete.
    let names = try run(source, ["log", "--all", "--reflog", "--format=", "--name-only", "-z"], control: control)
    for raw in names.split(separator: 0) {
      guard var path = String(data: Data(raw), encoding: .utf8) else { throw CloudBackupError.unsafePath }
      if path.hasPrefix("\n") { path.removeFirst() }
      if path.isEmpty { continue }
      _ = try CloudBackupPaths.components(path)
      let classification = try await classify(path, "git-history")
      guard classification.storageClass == .brain, classification.purpose != .aiSubscription else { throw CloudBackupError.incomplete }
    }
    for entry in index {
      let classification = try await classify(entry.path, "git-index")
      guard classification.storageClass == .brain, classification.purpose != .aiSubscription else { throw CloudBackupError.incomplete }
    }
    let attributes = try run(source, ["log", "--all", "--reflog", "-p", "--format=", "--", ".gitattributes"], control: control)
    if String(decoding: attributes, as: UTF8.self).range(of: #"filter\s*=\s*lfs"#, options: .regularExpression) != nil { throw CloudBackupError.incomplete }
    let reachable = try string(run(source, ["rev-list", "--objects", "--all", "--reflog", "--no-object-names"], control: control))
    let ids = Set(reachable.split(separator: "\n").map(String.init) + index.map(\.object) + [head]).sorted()
    guard ids.count <= 20_000, ids.allSatisfy(objectID) else { throw CloudBackupError.limitExceeded }
    let objectDirectory = try output.directory("objects")
    var objects: [CloudBackupGitFacts.Object] = []
    var total = 0
    for id in ids {
      try Task.checkCancellation()
      let type = try string(run(source, ["cat-file", "-t", id], control: control))
      guard ["blob", "tree", "commit", "tag"].contains(type) else { throw CloudBackupError.invalidManifest }
      guard let size = Int(try string(run(source, ["cat-file", "-s", id], control: control))), size >= 0, size <= limit,
        total <= 512 * 1024 * 1024 - size else { throw CloudBackupError.limitExceeded }
      let bytes = try run(source, ["cat-file", type, id], control: control)
      guard bytes.count == size else { throw CloudBackupError.changedDuringRead }
      try objectDirectory.writeNew(id, bytes: bytes)
      total += size
      objects.append(.init(id: id, type: type, bytes: size, sha256: CloudBackupDigest.sha256(bytes)))
    }
    _ = try run(source, ["bundle", "create", package.appendingPathComponent("history.bundle").path, "--all"], control: control)
    let bundle = try read(output, "history.bundle", maximum: 512 * 1024 * 1024)
    guard try run(source, ["for-each-ref", "--format=%(objectname) %(refname) %(symref)"], control: control) == refsData,
      try run(source, ["ls-files", "--stage", "-z"], control: control) == indexData,
      try string(run(source, ["rev-parse", "--verify", "HEAD"], control: control)) == head else { throw CloudBackupError.changedDuringRead }
    let remoteData = (try? run(source, ["config", "--local", "--get-regexp", #"^remote\..*\.url$"#], control: control)) ?? Data()
    let remotes = String(decoding: remoteData, as: UTF8.self).split(separator: "\n").compactMap { row -> String? in
      guard let space = row.firstIndex(of: " ") else { return nil }
      return sanitizedRemote(String(row[row.index(after: space)...]))
    }
    let facts = CloudBackupGitFacts(v: 1, head: head, branch: branch, objectFormat: format, references: refs, index: index, objects: objects,
      remoteURLs: remotes, bundleHash: CloudBackupDigest.sha256(bundle))
    try output.writeNew("facts.json", bytes: CloudWire.canonical(facts))
    guard fsync(output.fd) == 0 else { throw CloudBackupError.unavailable }
    return facts
  }

  public static func restore(package: URL, destination: URL) throws -> CloudBackupGitFacts {
    guard package.isFileURL, destination.isFileURL else { throw CloudBackupError.unsafePath }
    let input = try CloudBackupDirectory(path: package.path)
    let facts = try CloudWire.decode(CloudBackupGitFacts.self, from: read(input, "facts.json", maximum: limit), maximumBytes: limit)
    guard facts.v == 1, ["sha1", "sha256"].contains(facts.objectFormat), objectID(facts.head), facts.objects.count <= 20_000,
      Set(facts.objects.map(\.id)).count == facts.objects.count else { throw CloudBackupError.invalidManifest }
    let root = try CloudBackupDirectory(path: destination.path)
    guard try !root.isWithin(input), try !input.isWithin(root) else { throw CloudBackupError.unsafePath }
    guard try root.infoIfPresent(".git") == nil else { throw CloudBackupError.alreadyExists }
    let objects = try input.directory("objects")
    var total = 0
    // Validate every declared byte before making a repository. Never feed an archive to an extractor.
    for object in facts.objects {
      guard objectID(object.id), ["blob", "tree", "commit", "tag"].contains(object.type), object.bytes >= 0,
        object.bytes <= limit, total <= 512 * 1024 * 1024 - object.bytes else { throw CloudBackupError.limitExceeded }
      let data = try read(objects, object.id, maximum: object.bytes)
      guard data.count == object.bytes, CloudBackupDigest.sha256(data) == object.sha256 else { throw CloudBackupError.readbackFailed }
      total += data.count
    }
    for reference in facts.references { guard validRef(reference.name), objectID(reference.object), reference.symbolicTarget.map(validRef) ?? true else { throw CloudBackupError.invalidManifest } }
    if let branch = facts.branch { guard validRef(branch) else { throw CloudBackupError.invalidManifest } }
    for entry in facts.index { _ = try CloudBackupPaths.components(entry.path); guard validIndex(entry) else { throw CloudBackupError.invalidManifest } }
    _ = try root.createDirectory(".git")
    let controlParent = try CloudBackupDirectory(path: destination.deletingLastPathComponent().path)
    let controlName = ".cloud-git-control-" + UUID().uuidString
    let controlFD = try controlParent.createDirectory(controlName)
    let control = destination.deletingLastPathComponent().appendingPathComponent(controlName)
    let templateName = "template-" + UUID().uuidString
    _ = try controlFD.createDirectory(templateName)
    defer { unlinkat(controlFD.fd, templateName, AT_REMOVEDIR); unlinkat(controlParent.fd, controlName, AT_REMOVEDIR) }
    // Refuse to init over another repository, including a dangling .git link. Caller owns a fresh staging root.
    _ = try run(destination, ["init", "--template=" + control.appendingPathComponent(templateName).path, "--object-format=" + facts.objectFormat], control: control)
    _ = try run(destination, ["config", "--local", "core.hooksPath", "/dev/null"], control: control)
    for object in facts.objects {
      let data = try read(objects, object.id, maximum: object.bytes)
      guard try string(run(destination, ["hash-object", "-w", "-t", object.type, "--stdin"], input: data, control: control)) == object.id else { throw CloudBackupError.readbackFailed }
    }
    for reference in facts.references where reference.symbolicTarget == nil { _ = try run(destination, ["update-ref", reference.name, reference.object], control: control) }
    for reference in facts.references { if let target = reference.symbolicTarget { _ = try run(destination, ["symbolic-ref", reference.name, target], control: control) } }
    if let branch = facts.branch { _ = try run(destination, ["symbolic-ref", "HEAD", branch], control: control) }
    else { _ = try run(destination, ["update-ref", "--no-deref", "HEAD", facts.head], control: control) }
    let index = Data(facts.index.map { "\($0.mode) \($0.object) \($0.stage)\t\($0.path)\u{0}" }.joined().utf8)
    _ = try run(destination, ["update-index", "-z", "--index-info"], input: index, control: control)
    guard try indexEntries(run(destination, ["ls-files", "--stage", "-z"], control: control)) == facts.index,
      try references(run(destination, ["for-each-ref", "--format=%(objectname) %(refname) %(symref)"], control: control)) == facts.references,
      try string(run(destination, ["rev-parse", "HEAD"], control: control)) == facts.head else { throw CloudBackupError.readbackFailed }
    _ = try run(destination, ["fsck", "--strict", "--no-reflogs"], control: control)
    return facts
  }

  private static func refuseLinks(_ directory: CloudBackupDirectory, depth: Int = 0) throws {
    guard depth < 128 else { throw CloudBackupError.limitExceeded }
    for name in try directory.names() {
      let info = try directory.info(name)
      guard info.st_mode & S_IFMT != S_IFLNK else { throw CloudBackupError.incomplete }
      if info.st_mode & S_IFMT == S_IFDIR { try refuseLinks(directory.directory(name), depth: depth + 1) }
    }
  }
  private static func objectID(_ value: String) -> Bool {
    [40, 64].contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private static func validRef(_ value: String) -> Bool {
    value.hasPrefix("refs/") && !value.contains("..") && !value.contains("@{") && !value.hasSuffix("/") && !value.hasSuffix(".lock") &&
      !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) }
  }
  private static func validIndex(_ entry: CloudBackupGitFacts.IndexEntry) -> Bool {
    ["100644", "100755", "120000"].contains(entry.mode) && (0...3).contains(entry.stage) && objectID(entry.object)
  }
  private static func references(_ data: Data) throws -> [CloudBackupGitFacts.Reference] {
    try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
      let parts = $0.split(separator: " ", maxSplits: 2).map(String.init)
      guard (2...3).contains(parts.count), objectID(parts[0]), validRef(parts[1]), parts.count == 2 || validRef(parts[2]) else { throw CloudBackupError.invalidManifest }
      return .init(name: parts[1], object: parts[0], symbolicTarget: parts.count == 3 ? parts[2] : nil)
    }
  }
  private static func indexEntries(_ data: Data) throws -> [CloudBackupGitFacts.IndexEntry] {
    try data.split(separator: 0).map { raw in
      guard let text = String(data: Data(raw), encoding: .utf8), let tab = text.firstIndex(of: "\t") else { throw CloudBackupError.invalidManifest }
      let fields = text[..<tab].split(separator: " ").map(String.init)
      let path = String(text[text.index(after: tab)...])
      _ = try CloudBackupPaths.components(path)
      guard fields.count == 3, let stage = Int(fields[2]) else { throw CloudBackupError.invalidManifest }
      let entry = CloudBackupGitFacts.IndexEntry(path: path, mode: fields[0], object: fields[1], stage: stage)
      guard validIndex(entry) else { throw CloudBackupError.incomplete }
      return entry
    }
  }
  private static func sanitizedRemote(_ raw: String) -> String? {
    guard var url = URLComponents(string: raw), ["https", "http", "ssh"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
    url.user = nil; url.password = nil; url.query = nil; url.fragment = nil; url.path = ""
    return url.string
  }
  private static func read(_ directory: CloudBackupDirectory, _ name: String, maximum: Int) throws -> Data {
    let fd = try directory.file(name); defer { close(fd) }
    let bytes = try CloudBackupDirectory.readChunk(fd, maximum: maximum + 1)
    guard bytes.count <= maximum else { throw CloudBackupError.limitExceeded }
    return bytes
  }
  private static func string(_ bytes: Data) throws -> String {
    guard let value = String(data: bytes, encoding: .utf8) else { throw CloudBackupError.invalidManifest }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private final class Running: @unchecked Sendable { let process = Process() }
  static func run(_ root: URL, _ arguments: [String], input: Data = Data(), control: URL) throws -> Data {
    let folder = try CloudBackupDirectory(path: control.path)
    let name = UUID().uuidString
    let output = openat(folder.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw CloudBackupError.unavailable }
    defer { close(output); unlinkat(folder.fd, name, 0) }
    try folder.writeNew(name + ".in", bytes: input)
    let inputFD = try folder.file(name + ".in")
    defer { close(inputFD); unlinkat(folder.fd, name + ".in", 0) }
    let running = Running(), process = running.process
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "pack.threads=1", "-c", "protocol.allow=never"] + arguments
    process.currentDirectoryURL = root
    process.environment = ["HOME": control.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "", "GIT_TERMINAL_PROMPT": "0"]
    process.standardInput = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 30)
    timer.setEventHandler { if running.process.isRunning { running.process.terminate() } }
    timer.resume(); defer { timer.cancel() }
    process.waitUntilExit()
    guard process.terminationStatus == 0, lseek(output, 0, SEEK_SET) == 0 else { throw CloudBackupError.incomplete }
    return try CloudBackupDirectory.readChunk(output, maximum: limit + 1).checkedGitSize(limit)
  }
}
private extension Data {
  func checkedGitSize(_ maximum: Int) throws -> Data { guard count <= maximum else { throw CloudBackupError.limitExceeded }; return self }
}
