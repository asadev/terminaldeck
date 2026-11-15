import Foundation

public struct CloudBackupRecipe: Codable, Equatable, Sendable {
  public struct Runtime: Codable, Equatable, Sendable { public let name: String; public let version: String }
  public struct Manager: Codable, Equatable, Sendable { public let name: String; public let version: String; public let lockfile: String? }
  public struct WorkingDirectory: Codable, Equatable, Sendable { public let rootId: String; public let relativePath: String }
  public struct Command: Codable, Equatable, Sendable { public let argv: [String]; public let cwdRef: WorkingDirectory }
  public struct Database: Codable, Equatable, Sendable { public let id: String; public let engine: String; public let version: String; public let snapshotRef: String; public let connectionSecretRef: String? }
  public struct Port: Codable, Equatable, Sendable { public let name: String; public let preferred: Int; public let localOnly: Bool }
  public struct Service: Codable, Equatable, Sendable { public let name: String; public let ports: [Port] }
  public let v: Int
  public let projectId: String
  public let rootId: String
  public let source: String
  public let runtime: Runtime
  public let packageManager: Manager
  public let install: Command
  public let start: Command
  public let environmentRefs: [String]
  public let databases: [Database]
  public let services: [Service]
  public let packageHash: String
  public let lockfileHash: String?
  public var lastVerifiedAt: Int64?

  public static func detected(projectId: String, rootId: String, manager: String, script: String, runtimeVersion: String,
                              managerVersion: String, lockfile: String?, packageHash: String, lockfileHash: String?,
                              needsLibraries: Bool) throws -> CloudBackupRecipe {
    let installArguments: [String]
    if !needsLibraries { installArguments = [] }
    else {
      guard lockfile != nil else { throw CloudBackupError.incomplete }
      switch manager {
      case "npm": installArguments = [manager, "ci"]
      case "pnpm": installArguments = [manager, "install", "--frozen-lockfile"]
      case "yarn": installArguments = [manager, "install", managerVersion.hasPrefix("1.") ? "--frozen-lockfile" : "--immutable"]
      case "bun": installArguments = [manager, "install", "--frozen-lockfile"]
      default: throw CloudBackupError.unsupportedFile
      }
    }
    let cwd = WorkingDirectory(rootId: rootId, relativePath: "")
    let recipe = CloudBackupRecipe(v: 1, projectId: projectId, rootId: rootId, source: "detected",
      runtime: .init(name: manager == "bun" ? "bun" : "node", version: runtimeVersion),
      packageManager: .init(name: manager, version: managerVersion, lockfile: lockfile),
      install: .init(argv: installArguments, cwdRef: cwd), start: .init(argv: [manager, "run", script], cwdRef: cwd),
      environmentRefs: [], databases: [], services: [], packageHash: packageHash, lockfileHash: lockfileHash, lastVerifiedAt: nil)
    try recipe.validate()
    return recipe
  }
  public func validate() throws {
    let managers = ["npm", "pnpm", "yarn", "bun"]
    guard v == 1, !projectId.isEmpty, !rootId.isEmpty, ["detected", "saved"].contains(source),
      managers.contains(packageManager.name), runtime.name == (packageManager.name == "bun" ? "bun" : "node"),
      Self.version(runtime.version), Self.version(packageManager.version), packageHash.count == 64,
      start.argv.count == 3, start.argv[0] == packageManager.name, start.argv[1] == "run", ["dev", "start", "serve"].contains(start.argv[2]),
      start.cwdRef.rootId == rootId, install.cwdRef.rootId == rootId else { throw CloudBackupError.invalidManifest }
    for cwd in [start.cwdRef, install.cwdRef] where !cwd.relativePath.isEmpty { _ = try CloudBackupPaths.components(cwd.relativePath) }
    let validInstalls = [[], ["npm", "ci"], ["pnpm", "install", "--frozen-lockfile"], ["yarn", "install", "--frozen-lockfile"], ["yarn", "install", "--immutable"], ["bun", "install", "--frozen-lockfile"]]
    guard validInstalls.contains(install.argv), install.argv.isEmpty || install.argv.first == packageManager.name else { throw CloudBackupError.invalidManifest }
    if let lockfile = packageManager.lockfile {
      let allowed = ["npm": ["package-lock.json", "npm-shrinkwrap.json"], "pnpm": ["pnpm-lock.yaml"], "yarn": ["yarn.lock"], "bun": ["bun.lock", "bun.lockb"]]
      guard allowed[packageManager.name]?.contains(lockfile) == true, lockfileHash?.count == 64 else { throw CloudBackupError.invalidManifest }
    } else { guard install.argv.isEmpty, lockfileHash == nil else { throw CloudBackupError.incomplete } }
    guard environmentRefs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }),
      services.allSatisfy({ $0.ports.allSatisfy { $0.localOnly && (1...65535).contains($0.preferred) } }) else { throw CloudBackupError.invalidManifest }
  }
  public static func version(_ value: String) -> Bool {
    value.utf8.count <= 64 && value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z"#, options: .regularExpression) != nil
  }
}

/// Device-local observation only. It deliberately cannot be encoded into a portable recipe.
public struct CloudToolsStartProof: Sendable, Equatable {
  public let checkedAt: Int64
  public let port: Int
  public let sessionId: String
  public let listenerPID: Int32
  public let httpStatus: Int
  public let localURL: String
  public init(checkedAt: Int64, port: Int, sessionId: String, listenerPID: Int32, httpStatus: Int) {
    self.checkedAt = checkedAt; self.port = port; self.sessionId = sessionId; self.listenerPID = listenerPID; self.httpStatus = httpStatus
    localURL = "http://127.0.0.1:\(port)"
  }
}
