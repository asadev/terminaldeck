import Foundation
import TerminalDeckNativeCore

/// Uses the existing dev runner and bounded process runner. There is no new network client or launch path.
/// Start remains dev.servers_start. The owner calls verify on the existing dev-server change event.
public struct BackendCloudToolsRecipe: Sendable {
  private let servers: BackendDevServers
  private let files: BackendFilesystemService
  private let runner: BackendCommandRunner
  private let environment: [String: String]
  private let classify: CloudBackupEngine.Classifier
  private let observedVersion: @Sendable (String, String, NativeRPCContext) async throws -> String
  public init(servers: BackendDevServers, files: BackendFilesystemService, runner: BackendCommandRunner,
              environment: [String: String], classify: @escaping CloudBackupEngine.Classifier,
              observedVersion: @escaping @Sendable (String, String, NativeRPCContext) async throws -> String) {
    self.servers = servers; self.files = files; self.runner = runner; self.environment = environment; self.classify = classify; self.observedVersion = observedVersion
  }
  public func detect(projectId: String, rootId: String, folder: String, context: NativeRPCContext) async throws -> CloudBackupRecipe {
    let arguments = try await servers.launchArguments(folder: folder, context: context)
    let manager = arguments[0]
    let package = try await text(folder, "package.json", context)
    let payload = try NativeRPCValue.parseJSON(Data(package.utf8), maximumBytes: 1024 * 1024)
    guard try await classify("package.json", projectId).storageClass == .brain else { throw CloudFailure.secretsLocked }
    let needsLibraries = !(payload["dependencies"].fields ?? []).isEmpty || !(payload["devDependencies"].fields ?? []).isEmpty
    var lockfile: String?, lockHash: String?
    for file in ["pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json", "npm-shrinkwrap.json"] {
      if (try? await files.authority.resolve(root: folder, relative: file, context: context)) != nil {
        guard try await classify(file, projectId).storageClass == .brain else { throw CloudFailure.secretsLocked }
        let data = try await text(folder, file, context)
        lockfile = file; lockHash = CloudBackupDigest.sha256(Data(data.utf8)); break
      }
    }
    let runtime = manager == "bun" ? "bun" : "node"
    let runtimeVersion = try await observedVersion(runtime, folder, context)
    let managerVersion = runtime == manager ? runtimeVersion : try await observedVersion(manager, folder, context)
    return try CloudBackupRecipe.detected(projectId: projectId, rootId: rootId, manager: manager, script: arguments[2],
      runtimeVersion: runtimeVersion, managerVersion: managerVersion, lockfile: lockfile,
      packageHash: CloudBackupDigest.sha256(Data(package.utf8)), lockfileHash: lockHash, needsLibraries: needsLibraries)
  }
  /// Called only by an explicit Start action, under that action's existing policy and a write grant.
  /// Importing/restoring a recipe never invokes this method.
  public func prepareLibraries(_ recipe: CloudBackupRecipe, folder: String, context: NativeRPCContext) async throws {
    try context.require("dev.start")
    guard context.caller == .nativeApp || context.caller == .internalEngine else {
      throw NativeRPCError(code: "unavailable", message: "This caller has no scoped dependency installer on this Mac.")
    }
    _ = try await files.authority.authorize(folder, context: context, intent: .write)
    try recipe.validate()
    guard recipe.install.cwdRef.relativePath.isEmpty else { throw CloudBackupError.unsupportedFile }
    let package = try await text(folder, "package.json", context)
    guard CloudBackupDigest.sha256(Data(package.utf8)) == recipe.packageHash else { throw CloudBackupError.destinationChanged }
    if let name = recipe.packageManager.lockfile {
      let lock = try await text(folder, name, context)
      guard CloudBackupDigest.sha256(Data(lock.utf8)) == recipe.lockfileHash else { throw CloudBackupError.destinationChanged }
    }
    guard !recipe.install.argv.isEmpty else { return }
    let result = try await BackendDevProcessExecutor().run(command: "/usr/bin/env", arguments: recipe.install.argv,
      environment: environment, cwd: folder, timeoutMilliseconds: 60_000, maximumBytes: 1024 * 1024)
    guard result.ok, !result.timedOut else {
      throw NativeRPCError(code: "cloud-libraries", message: "The project libraries could not be restored from the lockfile. Nothing was started.")
    }
  }
  public func verify(_ recipe: CloudBackupRecipe, folder: String, route: String = "/", context: NativeRPCContext) async throws -> CloudToolsStartProof {
    try recipe.validate()
    guard route.hasPrefix("/"), route.utf8.count <= 512, !route.contains("?"), !route.contains("#"), !route.contains("\\"),
      !route.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { throw CloudBackupError.unsafePath }
    let arguments = try await servers.launchArguments(folder: folder, context: context)
    let package = try await text(folder, "package.json", context)
    guard arguments == recipe.start.argv, CloudBackupDigest.sha256(Data(package.utf8)) == recipe.packageHash else { throw CloudBackupError.destinationChanged }
    if let lockfile = recipe.packageManager.lockfile {
      let lock = try await text(folder, lockfile, context)
      guard CloudBackupDigest.sha256(Data(lock.utf8)) == recipe.lockfileHash else { throw CloudBackupError.destinationChanged }
    }
    let state = try await servers.status(folder: folder, context: context)
    guard state["status"].string == "ready", let session = state["sessionId"].string,
      let number = state["port"].number, number.rounded() == number, (1...65535).contains(number),
      let rootPID = try await servers.processID(folder: folder, context: context), rootPID > 1 else { throw CloudBackupError.incomplete }
    let port = Int(number)
    let listener = try await listeningPID(port: port, rootPID: rootPID, folder: folder)
    let response = try await runner.run(command: "/usr/bin/curl", arguments: ["--disable", "--silent", "--noproxy", "*", "--proto", "=http", "--max-redirs", "0", "--max-time", "2", "--output", "/dev/null", "--write-out", "%{http_code}", "http://127.0.0.1:\(port)" + route], environment: environment, cwd: folder, timeoutMilliseconds: 4000, outputLimit: 1024)
    guard response.succeeded, let status = Int(response.output.trimmingCharacters(in: .whitespacesAndNewlines)), (200...299).contains(status) else { throw CloudBackupError.incomplete }
    let currentRoot = try await servers.processID(folder: folder, context: context)
    let currentListener = try await listeningPID(port: port, rootPID: rootPID, folder: folder)
    guard currentRoot == rootPID, currentListener == listener else { throw CloudBackupError.incomplete }
    return .init(checkedAt: Int64(Date().timeIntervalSince1970 * 1000), port: port, sessionId: session, listenerPID: listener, httpStatus: status)
  }
  private func listeningPID(port: Int, rootPID: Int32, folder: String) async throws -> Int32 {
    let result = try await runner.run(command: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"], environment: environment, cwd: folder, timeoutMilliseconds: 3000, outputLimit: 16384)
    guard result.succeeded else { throw CloudBackupError.unavailable }
    var current: Int32?, addresses: [Int32: [String]] = [:]
    for line in result.output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      if line.first == "p" { current = Int32(line.dropFirst()) }
      if line.first == "n", let current { addresses[current, default: []].append(String(line.dropFirst())) }
    }
    for (pid, values) in addresses where values.contains("127.0.0.1:\(port)") && values.allSatisfy({ ["127.0.0.1:\(port)", "[::1]:\(port)", "::1:\(port)"].contains($0) }) {
      var candidate = pid
      for _ in 0..<32 {
        if candidate == rootPID { return pid }
        guard candidate > 1 else { break }
        let parent = try await runner.run(command: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(candidate)], environment: environment, cwd: folder, timeoutMilliseconds: 2000, outputLimit: 128)
        guard parent.succeeded, let next = Int32(parent.output.trimmingCharacters(in: .whitespacesAndNewlines)), next != candidate else { break }
        candidate = next
      }
    }
    throw CloudBackupError.incomplete
  }
  private func text(_ folder: String, _ path: String, _ context: NativeRPCContext) async throws -> String {
    let value = try await files.read(root: folder, relative: path, context: context)
    guard value["kind"].string == "text", let text = value["text"].string, let count = value["bytes"].number,
      Double(text.utf8.count) == count, count <= 4 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
    return text
  }
}
