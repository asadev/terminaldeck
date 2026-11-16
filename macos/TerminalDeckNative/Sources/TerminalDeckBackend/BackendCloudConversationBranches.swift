import Foundation
import TerminalDeckNativeCore

/// Durable list of provider homes created by an explicit Continue on this Mac, under the account's Cloud folder.
/// Each is an approved conversation home, so every turn made after Continue is enumerated and uploaded,
/// carrying its branch link to the raw parent (§5.5 "distinct branch metadata").
public actor BackendCloudConversationBranches {
  public struct Entry: Codable, Sendable, Equatable {
    public let branchID: String
    public let provider: CloudConversationProvider
    /// Relative to `directory`, so the registry never stores another machine's absolute path.
    public let providerHome: String
    public let branch: CloudConversationBranch
  }
  public nonisolated let directory: URL
  private let log: BackendCloudConversationLog
  private var entries: [String: Entry]?
  public init(directory: URL, subjectHash: String) throws {
    try BackendCloudConversationAccount.check(directory, subjectHash: subjectHash)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    self.directory = directory.standardizedFileURL
    log = try .init(directory: directory, name: "branches.log")
  }
  private func load() throws -> [String: Entry] {
    if let entries { return entries }
    var value: [String: Entry] = [:]
    for line in try log.lines() { let entry = try JSONDecoder().decode(Entry.self, from: line); value[entry.branchID] = entry }
    entries = value; return value
  }
  /// Registered before the provider is started, so a crash after launch can never leave turns outside the uploaded homes.
  public func register(branchID: String, provider: CloudConversationProvider, providerHome: URL, branch: CloudConversationBranch) throws {
    var value = try load()
    let home = providerHome.standardizedFileURL.path, root = directory.path + "/"
    guard UUID(uuidString: branchID) != nil, home.hasPrefix(root) else { throw CloudFailure.unsafeConfiguration }
    let entry = Entry(branchID: branchID, provider: provider, providerHome: String(home.dropFirst(root.count)), branch: branch)
    if let old = value[branchID] { guard old == entry else { throw CloudFailure.idReused }; return }
    try log.append([try JSONEncoder().encode(entry)])
    value[branchID] = entry; entries = value
  }
  public func homes() throws -> [BackendCloudConversationHome] {
    try load().values.sorted { $0.branchID < $1.branchID }.map { entry in
      .init(homeID: "branch:" + entry.branchID, profileID: "branch:" + entry.branchID, provider: entry.provider,
        directory: directory.appendingPathComponent(entry.providerHome), branch: entry.branch)
    }
  }
}
