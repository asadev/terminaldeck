import Foundation

public struct CloudToolsObservation: Codable, Equatable, Sendable {
  public let deviceId: String
  public let toolId: String
  public let name: String
  public let version: String?
  public let platform: CloudPlatform
  public let architecture: String
  public let installed: Bool
  public let available: Bool
  public let pathRef: String?
  public let checkedAt: Int64
  public let capabilities: [String]
  public let reason: String?
  public init(deviceId: String, toolId: String, name: String, version: String?, platform: CloudPlatform, architecture: String,
              installed: Bool, available: Bool, pathRef: String? = nil, checkedAt: Int64, capabilities: [String] = [], reason: String? = nil) {
    self.deviceId = deviceId; self.toolId = toolId; self.name = name; self.version = version; self.platform = platform; self.architecture = architecture
    self.installed = installed; self.available = available; self.pathRef = pathRef; self.checkedAt = checkedAt; self.capabilities = capabilities; self.reason = reason
  }
}
public struct CloudToolsRequirement: Codable, Equatable, Sendable {
  public let toolId: String
  public let versionRange: String
  public let neededFor: [String]
  public let reason: String
  public init(toolId: String, versionRange: String, neededFor: [String], reason: String) {
    self.toolId = toolId; self.versionRange = versionRange; self.neededFor = neededFor; self.reason = reason
  }
}
public struct CloudToolsNeed: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case ready, missing, unavailable, wrongVersion, unobserved }
  public let requirement: CloudToolsRequirement
  public let observation: CloudToolsObservation?
  public let state: State
  public let canInstall: Bool
  public let reason: String
}
public enum CloudToolsInstallerDisposition: String, Sendable { case started, completed, blocked }
public struct CloudToolsInstaller: Sendable {
  public let id: String
  public let supportsVersion: @Sendable (String) -> Bool
  public let perform: @Sendable (NativeRPCContext) async throws -> CloudToolsInstallerDisposition
  public init(id: String, supportsVersion: @escaping @Sendable (String) -> Bool,
              perform: @escaping @Sendable (NativeRPCContext) async throws -> CloudToolsInstallerDisposition) {
    self.id = id; self.supportsVersion = supportsVersion; self.perform = perform
  }
}
public struct CloudToolsInstallResult: Sendable {
  public enum State: String, Sendable { case pending, verified, blocked }
  public let toolId: String
  public let state: State
  public let needs: [CloudToolsNeed]
}

/// Facts come from the existing discovery owner, actions from real existing installers.
/// No binary bytes, transferred PATH, permissions, or another machine's installed flags are accepted here.
public actor CloudToolsCatalog {
  public typealias Observe = @Sendable (String, Bool) async throws -> CloudToolsObservation?
  public typealias Install = @Sendable (NativeRPCContext) async throws -> CloudToolsInstallerDisposition
  private let deviceId: String
  private let observe: Observe
  private let installers: [String: CloudToolsInstaller]
  private let authorize: @Sendable (NativeRPCContext, String) async throws -> Void
  private let now: @Sendable () -> Int64
  private var installing = Set<String>()
  public init(deviceId: String, observe: @escaping Observe, installers: [String: CloudToolsInstaller],
              authorizeInstall: @escaping @Sendable (NativeRPCContext, String) async throws -> Void,
              now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
    self.deviceId = deviceId; self.observe = observe; self.installers = installers; authorize = authorizeInstall; self.now = now
  }
  public func needs(_ requirements: [CloudToolsRequirement], refresh: Bool = false) async throws -> [CloudToolsNeed] {
    let requestedAt = now()
    var values: [String: CloudToolsObservation] = [:]
    var checked = Set<String>()
    for requirement in requirements {
      guard !requirement.toolId.isEmpty, !requirement.versionRange.isEmpty else { throw CloudFailure.invalidRequest }
      if checked.insert(requirement.toolId).inserted, let value = try await observe(requirement.toolId, refresh) { values[requirement.toolId] = value }
    }
    return requirements.map { requirement in
      let value = values[requirement.toolId]
      guard let value, value.deviceId == deviceId, value.toolId == requirement.toolId,
        value.checkedAt <= now() + 5000, value.checkedAt >= now() - 300_000,
        !refresh || value.checkedAt >= requestedAt - 1000, value.installed || !value.available,
        !(value.pathRef?.hasPrefix("/") ?? false), !(value.pathRef?.hasPrefix("\\") ?? false) else {
        return .init(requirement: requirement, observation: nil, state: .unobserved, canInstall: false, reason: "Not checked on this Mac.")
      }
      if !value.installed {
        return .init(requirement: requirement, observation: value, state: .missing, canInstall: installers[requirement.toolId]?.supportsVersion(requirement.versionRange) == true, reason: "Needed on this Mac.")
      }
      if !value.available {
        return .init(requirement: requirement, observation: value, state: .unavailable, canInstall: false, reason: value.reason ?? "Installed, but not available to this app.")
      }
      if requirement.versionRange != "*", value.version == nil {
        return .init(requirement: requirement, observation: value, state: .unobserved, canInstall: false, reason: "The required version has not been checked.")
      }
      guard requirement.versionRange == "*" || Self.matches(value.version ?? "", requirement.versionRange) else {
        return .init(requirement: requirement, observation: value, state: .wrongVersion, canInstall: installers[requirement.toolId]?.supportsVersion(requirement.versionRange) == true, reason: "This project needs a different version.")
      }
      return .init(requirement: requirement, observation: value, state: .ready, canInstall: false, reason: "Available on this Mac.")
    }
  }
  public func install(toolId: String, requirements: [CloudToolsRequirement], context: NativeRPCContext) async throws -> CloudToolsInstallResult {
    let selected = requirements.filter { $0.toolId == toolId }
    guard !selected.isEmpty, let installer = installers[toolId] else { throw CloudFailure.unsupportedFormat }
    guard installing.insert(toolId).inserted else { return .init(toolId: toolId, state: .pending, needs: try await needs(selected)) }
    defer { installing.remove(toolId) }
    let before = try await needs(selected, refresh: true)
    if before.allSatisfy({ $0.state == .ready }) { return .init(toolId: toolId, state: .verified, needs: before) }
    guard before.filter({ $0.state != .ready }).allSatisfy(\.canInstall), selected.allSatisfy({ installer.supportsVersion($0.versionRange) }) else { return .init(toolId: toolId, state: .blocked, needs: before) }
    try await authorize(context, toolId)
    try Task.checkCancellation()
    let disposition = try await installer.perform(context)
    if disposition == .started { return .init(toolId: toolId, state: .pending, needs: before) }
    let after = try await needs(selected, refresh: true)
    return .init(toolId: toolId, state: disposition == .completed && after.allSatisfy({ $0.state == .ready }) ? .verified : .blocked, needs: after)
  }
  public static func requirements(for recipe: CloudBackupRecipe) throws -> [CloudToolsRequirement] {
    try recipe.validate()
    var result = [CloudToolsRequirement(toolId: recipe.runtime.name, versionRange: recipe.runtime.version, neededFor: [recipe.rootId], reason: "Run this project's saved start command.")]
    if recipe.packageManager.name != recipe.runtime.name {
      result.append(.init(toolId: recipe.packageManager.name, versionRange: recipe.packageManager.version, neededFor: [recipe.rootId], reason: "Restore this project's libraries from its lockfile."))
    }
    return result
  }
  static func matches(_ actual: String, _ range: String) -> Bool {
    func version(_ raw: String) -> [Int]? {
      let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
      guard CloudBackupRecipe.version(value) else { return nil }
      let fields = value.split(whereSeparator: { $0 == "-" || $0 == "+" })[0].split(separator: ".").compactMap { Int($0) }
      return fields.count == 3 ? fields : nil
    }
    let mode: String, expected: String
    if range.hasPrefix(">=") { mode = ">="; expected = String(range.dropFirst(2)) }
    else if range.hasPrefix("^") || range.hasPrefix("~") { mode = String(range.prefix(1)); expected = String(range.dropFirst()) }
    else { mode = "="; expected = range }
    guard let a = version(actual), let b = version(expected) else { return false }
    let actualText = actual.hasPrefix("v") ? String(actual.dropFirst()) : actual
    let expectedText = expected.hasPrefix("v") ? String(expected.dropFirst()) : expected
    if actualText.contains("-") || expectedText.contains("-") { return mode == "=" && actualText == expectedText }
    let atLeast = !a.lexicographicallyPrecedes(b)
    switch mode {
    case ">=": return atLeast
    case "~": return atLeast && a[0] == b[0] && a[1] == b[1]
    case "^": return atLeast && a[0] == b[0] && (b[0] > 0 || a[1] == b[1] && (b[1] > 0 || a[2] == b[2]))
    default: return a == b && actualText == expectedText
    }
  }
}
