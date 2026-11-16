import Foundation
import TerminalDeckNativeCore

public struct BackendCloudConversationHome: Sendable {
  /// The owner's stable identity for this home (for example `default`, `profile:<id>`, an account-login or agent-home id).
  /// It, not the directory, is what conversation identities are derived from.
  public let homeID: String
  public let profileID: String
  public let provider: CloudConversationProvider
  public let directory: URL
  public let branch: CloudConversationBranch?
  public init(homeID: String, profileID: String, provider: CloudConversationProvider, directory: URL, branch: CloudConversationBranch? = nil) {
    self.homeID = homeID; self.profileID = profileID; self.provider = provider; self.directory = directory; self.branch = branch
  }
  public init(profileID: String, provider: CloudConversationProvider, directory: URL) {
    self.init(homeID: profileID, profileID: profileID, provider: provider, directory: directory)
  }
}

/// First key given to a physical source wins and is kept when the home moves or another profile alias appears.
public struct BackendCloudConversationHomeKeyTable: Codable, Sendable, Equatable {
  public private(set) var keys: [String: String] = [:]
  public private(set) var order: [String: Int] = [:]
  public private(set) var next = 0
  public init() {}
  public mutating func key(provider: CloudConversationProvider, suffix: String, homeIDs: [String]) -> String {
    let names = homeIDs.sorted().map { provider.rawValue + "/" + suffix + "/" + $0 }
    let chosen = names.compactMap { keys[$0] }.min { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) } ?? names[0]
    if order[chosen] == nil { order[chosen] = next; next += 1 }
    for name in names where keys[name] == nil { keys[name] = chosen }
    return chosen
  }
}

public enum BackendCloudConversationHomes {
  private struct Candidate {
    let provider: CloudConversationProvider
    let suffix: String
    let directory: URL
    let prefix: String
    let file: String?
    let homeIDs: [String]
    let profileIDs: [String]
    let branch: CloudConversationBranch?
  }
  /// Pure planner with an in-memory key table; `BackendCloudConversationHomeKeys` persists the table per account.
  public static func roots(_ homes: [BackendCloudConversationHome]) throws -> [CloudConversationRoot] {
    var table = BackendCloudConversationHomeKeyTable()
    return try roots(homes, keys: &table)
  }
  /// The caller supplies ALL default, inactive profile, account-login, agent, approved remote and continued-branch homes.
  /// Uses the existing Gemini home resolver; no caller paths are inferred from transcript folder names.
  public static func roots(_ homes: [BackendCloudConversationHome], keys: inout BackendCloudConversationHomeKeyTable) throws -> [CloudConversationRoot] {
    var candidates: [Candidate] = []
    // A continued branch is always its own source, never merged with another home.
    let groups = Dictionary(grouping: homes) { $0.provider.rawValue + "\0" + $0.directory.standardizedFileURL.path + "\0" + ($0.branch == nil ? "" : $0.homeID) }
    for key in groups.keys.sorted() {
      let members = groups[key]!.sorted { $0.homeID < $1.homeID }
      let home = members[0]
      func add(_ suffix: String, directory: URL, prefix: String, file: String? = nil) {
        candidates.append(.init(provider: home.provider, suffix: suffix, directory: directory, prefix: prefix, file: file,
          homeIDs: members.map(\.homeID), profileIDs: members.map(\.profileID), branch: home.branch))
      }
      switch home.provider {
      case .claude:
        add("projects", directory: home.directory.appendingPathComponent("projects"), prefix: "projects")
        add("history", directory: home.directory, prefix: "", file: "history.jsonl")
      case .codex:
        for directory in ["sessions", "archived_sessions"] { add(directory, directory: home.directory.appendingPathComponent(directory), prefix: directory) }
        for name in ["history.jsonl", "session_index.jsonl"] { add(name, directory: home.directory, prefix: "", file: name) }
      case .gemini:
        for (index, path) in BackendTaskAgentTranscripts.geminiRoots(configDirectory: home.directory.path).enumerated() {
          add("tmp-\(index)", directory: URL(fileURLWithPath: path), prefix: index == 0 ? ".gemini/tmp" : ".cache/.gemini/tmp")
        }
      }
    }
    // Managed profiles may share an app-owned projects link. Resolve it only inside another explicitly approved home.
    // Keep every profile association while exporting one physical source once.
    let approved = Dictionary(grouping: homes, by: { $0.provider.rawValue }).mapValues { values in
      values.map { $0.directory.resolvingSymlinksInPath().standardizedFileURL.path }
    }
    var grouped: [String: [Candidate]] = [:]
    for candidate in candidates {
      let real = candidate.directory.resolvingSymlinksInPath().standardizedFileURL
      let allowed = (approved[candidate.provider.rawValue] ?? []).contains { real.path == $0 || NativeTranscriptPaths.isDescendant(real.path, of: $0) }
      let directory = allowed ? real : candidate.directory
      let key = candidate.provider.rawValue + "\0" + directory.path + "\0" + (candidate.file ?? "") + "\0" + (candidate.branch == nil ? "" : candidate.homeIDs.joined(separator: ","))
      grouped[key, default: []].append(.init(provider: candidate.provider, suffix: candidate.suffix, directory: directory, prefix: candidate.prefix,
        file: candidate.file, homeIDs: candidate.homeIDs, profileIDs: candidate.profileIDs, branch: candidate.branch))
    }
    var result: [CloudConversationRoot] = []
    for key in grouped.keys.sorted() {
      let values = grouped[key]!.sorted { ($0.suffix, $0.homeIDs.first ?? "") < ($1.suffix, $1.homeIDs.first ?? "") }, first = values[0]
      let stable = keys.key(provider: first.provider, suffix: first.suffix, homeIDs: Array(Set(values.flatMap(\.homeIDs))))
      let aliases = Array(Set(values.flatMap(\.profileIDs))).sorted()
      result.append(.init(sourceID: "conversation-" + (try CloudConversationIdentity.uuid(["conversation-source", stable])),
        profileID: aliases[0], provider: first.provider, directory: first.directory, relativePrefix: first.prefix,
        singleFile: first.file, aliasProfileIDs: aliases, branch: first.branch))
    }
    return result
  }
  public static func profileHomes(_ profiles: [BackendAccountProfile]) -> [BackendCloudConversationHome] {
    profiles.compactMap { profile in
      guard let provider = CloudConversationProvider(rawValue: profile.provider) else { return nil }
      return .init(homeID: "profile:" + profile.id, profileID: profile.id, provider: provider, directory: URL(fileURLWithPath: profile.configDir))
    }
  }
}

/// The per-account home key table. Written only when a new home or alias first appears.
public actor BackendCloudConversationHomeKeys {
  private let persistence: BackendTaskPersistence
  private var table: BackendCloudConversationHomeKeyTable?
  public init(directory: URL, subjectHash: String) throws {
    try BackendCloudConversationAccount.check(directory, subjectHash: subjectHash)
    persistence = try .init(directory: directory, ownership: .exclusive)
  }
  public func roots(_ homes: [BackendCloudConversationHome]) throws -> [CloudConversationRoot] {
    var current: BackendCloudConversationHomeKeyTable
    if let table { current = table }
    else if let bytes = try persistence.readOwnedBytes("home-keys.json", maximumBytes: 16 * 1024 * 1024) {
      current = try JSONDecoder().decode(BackendCloudConversationHomeKeyTable.self, from: bytes)
    } else { current = .init() }
    let before = current
    let roots = try BackendCloudConversationHomes.roots(homes, keys: &current)
    if current != before {
      try persistence.writeBytes("home-keys.json", data: try JSONEncoder().encode(current))
    }
    table = current
    return roots
  }
}

public struct BackendCloudConversationHomeInventory: Sendable {
  public let homes: [BackendCloudConversationHome]
  public let roots: [CloudConversationRoot]
  public let blockedSources: [String]
}

public extension BackendCloudConversationHomes {
  /// The home owner classifies each managed directory; filenames never guess an account's provider.
  /// Every child is visited, including inactive accounts. Unresolved/unreadable children block coverage.
  /// Continued-conversation branch homes from this account's registry are always included.
  static func discover(defaultHomes: [BackendCloudConversationHome], profiles: [BackendAccountProfile],
                       accountLoginsRoot: URL, agentHomesRoot: URL, approvedRemoteHomes: [BackendCloudConversationHome],
                       branches: BackendCloudConversationBranches? = nil, keys: BackendCloudConversationHomeKeys? = nil,
                       resolveOwnedHome: @Sendable (URL) async throws -> [BackendCloudConversationHome]) async throws -> BackendCloudConversationHomeInventory {
    var homes = defaultHomes + profileHomes(profiles) + approvedRemoteHomes
    var blocked: [String] = []
    for container in [accountLoginsRoot, agentHomesRoot] {
      let errors = BackendCloudConversationInventoryErrors()
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: container.path, isDirectory: &directory), directory.boolValue,
            (try? container.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            let cursor = FileManager.default.enumerator(at: container,
              includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in errors.record(); return true }) else {
        blocked.append("A managed-home container is absent or unreadable."); continue
      }
      while let entry = cursor.nextObject() as? URL {
        try Task.checkCancellation()
        do {
          let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          if values.isSymbolicLink == true { blocked.append("A managed-home link requires explicit owner approval."); continue }
          guard values.isDirectory == true else { continue }
          let resolved = try await resolveOwnedHome(entry)
          guard !resolved.isEmpty, resolved.allSatisfy({ $0.directory.standardizedFileURL == entry.standardizedFileURL ||
            NativeTranscriptPaths.isDescendant($0.directory.standardizedFileURL.path, of: entry.standardizedFileURL.path) }) else {
            blocked.append("A managed home has no resolved provider owner."); continue
          }
          homes += resolved
        } catch { blocked.append("A managed home could not be resolved completely.") }
      }
      if errors.failed { blocked.append("A managed-home directory could not be fully enumerated.") }
    }
    if let branches { homes += try await branches.homes() }
    // A repeated owner entry is the same source; distinct profiles retain their association even on a shared home.
    var seen = Set<String>()
    homes = homes.filter { seen.insert($0.provider.rawValue + "\0" + $0.homeID + "\0" + $0.profileID + "\0" + $0.directory.standardizedFileURL.path).inserted }
    if homes.isEmpty { blocked.append("No approved provider homes were exported.") }
    for home in homes where home.provider == .codex && home.branch == nil {
      do {
        let names = try FileManager.default.contentsOfDirectory(atPath: home.directory.path)
        if names.contains(where: { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }) {
          blocked.append("Codex database metadata needs a logical database adapter; the database was not copied.")
        }
      } catch { blocked.append("A Codex home could not be inventoried.") }
    }
    let planned: [CloudConversationRoot]
    if let keys { planned = try await keys.roots(homes) } else { planned = try Self.roots(homes) }
    return .init(homes: homes, roots: planned, blockedSources: Array(Set(blocked)).sorted())
  }
}

private final class BackendCloudConversationInventoryErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func record() { lock.withLock { value = true } }
  var failed: Bool { lock.withLock { value } }
}
