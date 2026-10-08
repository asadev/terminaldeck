import Foundation
import TerminalDeckNativeCore

/// All authoritative records and env files live on the selected server.
public actor BackendAppsStore {
    public static let root = "/var/lib/terminaldeck/apps"
    public nonisolated let stateRoot: String
    private let runtime: BackendAppsRuntime
    private var busy: Set<String> = []
    private var locks: [String: (path: String, token: String)] = [:]
    private var lockRecovery: [String: BackendAppsRecoveryHandle] = [:]
    public init(runtime: BackendAppsRuntime) { self.runtime = runtime; self.stateRoot = runtime.stateRoot }
    public static func directory(_ appID: String) throws -> String { root + "/" + (try BackendAppsValidation.id(appID)) }
    public nonisolated func directory(_ appID: String) throws -> String { stateRoot + "/" + (try BackendAppsValidation.id(appID)) }

    public func readFile(_ serverID: String, path: String) async throws -> Data? {
        try checkPath(path)
        let q = BackendAppsRuntime.quote(path)
        let result = try await runtime.run(serverID, Self.parentChecks(path, root: stateRoot) + "; test ! -L \(q) || exit 45; test -e \(q) || exit 44; test -f \(q) || exit 45; cat -- \(q)")
        if result.code == 44 { return nil }
        guard result.code == 0, !result.truncated else { throw NativeRPCError(code: "state-failed", message: "The app's saved state could not be read safely.") }
        return Data(result.stdout.utf8)
    }
    public func writeFile(_ serverID: String, path: String, contents: Data) async throws {
        try checkPath(path)
        guard contents.count <= 1_048_576 else { throw NativeRPCError.invalidArguments("The app's saved state is too large.") }
        if let recovery = runtime.recovery {
            let relative = String(path.dropFirst(stateRoot.count + 1)), app = String(relative.split(separator: "/").first ?? "")
            guard let transaction = BackendAppsRecoveryContext.transaction(serverID: serverID, appID: app), transaction.belongs(to: recovery) else { throw NativeRPCError(code: "access-denied", message: "This app write has no approved transaction recovery scope.") }
            if await transaction.registered(.restoreAppFile(path: path)) == nil { _ = try await transaction.register(.restoreAppFile(path: path)) }
        }
        let parent = String(path[..<path.lastIndex(of: "/")!]), temporary = path + "." + UUID().uuidString + ".tmp"
        let q = BackendAppsRuntime.quote
        let script = """
        set -eu
        umask 077
        \(Self.parentChecks(path, root: stateRoot))
        test ! -L \(q(parent)) && test ! -L \(q(path))
        mkdir -p -- \(q(parent))
        chmod 700 -- \(q(parent))
        trap 'rm -f -- \(q(temporary))' EXIT
        trap 'exit 130' HUP INT TERM
        set -C
        cat > \(q(temporary))
        chmod 600 -- \(q(temporary))
        sync -f \(q(temporary))
        mv -f -- \(q(temporary)) \(q(path))
        sync -f \(q(parent))
        """
        _ = try await runtime.checked(serverID, script, stdin: contents, code: "state-failed", message: "The app's saved state could not be safely saved.")
    }
    public func read(_ serverID: String, _ appID: String) async throws -> NativeRPCValue {
        guard let bytes = try await readFile(serverID, path: directory(appID) + "/state.json") else { throw NativeRPCError(code: "not-found", message: "That app is not saved on this server.") }
        let record: NativeRPCValue
        do { record = try BackendAppsValidation.json(bytes) }
        catch { throw NativeRPCError(code: "state-failed", message: "The app's saved state is damaged.") }
        guard record.fields != nil, record["id"].string == appID, record["name"].string != nil else { throw NativeRPCError(code: "state-failed", message: "The app's saved state does not match its ID.") }
        return record
    }
    public func write(_ serverID: String, _ appID: String, _ record: NativeRPCValue) async throws {
        guard record["id"].string == appID, record["name"].string != nil else { throw NativeRPCError.invalidArguments("Saved app state must match the selected app.") }
        try await writeFile(serverID, path: directory(appID) + "/state.json", contents: record.encodedJSON(pretty: true))
    }
    public func list(_ serverID: String) async throws -> [NativeRPCValue] {
        try checkPath(stateRoot + "/state.json")
        let result = try await runtime.run(serverID, Self.parentChecks(stateRoot + "/state.json", root: stateRoot) + "; test -d \(stateRoot) || exit 44; find \(stateRoot) -mindepth 2 -maxdepth 2 -type f -name state.json -printf '%h\\n'")
        if result.code == 44 { return [] }
        guard result.code == 0, !result.truncated else { throw NativeRPCError(code: "state-failed", message: "The saved app list could not be read.") }
        let names = result.stdout.split(separator: "\n").map { String($0).components(separatedBy: "/").last ?? "" }.filter { !$0.hasPrefix(".") }
        guard names.count <= 512 else { throw NativeRPCError(code: "state-failed", message: "The saved app list exceeds this build's limit.") }
        var records: [NativeRPCValue] = []
        for name in names.sorted() { records.append(try await read(serverID, name)) }
        return records
    }
    public func environment(_ serverID: String, _ appID: String) async throws -> [String: String] {
        guard let bytes = try await readFile(serverID, path: directory(appID) + "/.env") else { return [:] }
        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeRPCError(code: "state-failed", message: "The app's settings could not be read.") }
        var rows: [NativeRPCValue.Field] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { throw NativeRPCError(code: "state-failed", message: "The app's settings are damaged.") }
            rows.append(.init(String(line[..<equal]), .string(String(line[line.index(after: equal)...]))))
        }
        return try BackendAppsValidation.environment(.object(rows))
    }
    public func applyEnvironment(_ serverID: String, _ appID: String, _ env: [String: String]) async throws {
        let valid = try BackendAppsValidation.environment(.object(env.map { .init($0.key, .string($0.value)) }))
        let text = valid.keys.sorted().map { $0 + "=" + valid[$0]! + "\n" }.joined()
        try await writeFile(serverID, path: directory(appID) + "/.env", contents: Data(text.utf8))
    }

    /// mkdir gives exclusion across Macs. Never steal or auto-expire a lock.
    public func withLock<T: Sendable>(_ serverID: String, _ appID: String, body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await runtime.withRecoveryTransaction(serverID: serverID, appID: appID) {
            try await self.withOwnedLock(serverID, appID, body: body)
        }
    }
    private func withOwnedLock<T: Sendable>(_ serverID: String, _ appID: String, body: @escaping @Sendable () async throws -> T) async throws -> T {
        let path = try directory(appID), key = serverID + ":" + appID
        try checkPath(path + "/state.json")
        guard busy.insert(key).inserted else { throw NativeRPCError(code: "busy", message: "This app already has an action in progress.") }
        let transaction = BackendAppsRecoveryContext.current
        defer { busy.remove(key); locks[key] = nil; lockRecovery[key] = nil }
        let q = BackendAppsRuntime.quote, lock = path + "/.lock", token = transaction?.scope.ownerToken ?? UUID().uuidString
        if let transaction { lockRecovery[key] = try await transaction.register(.releaseOwnedLock(path: lock, ownerToken: token)) }
        locks[key] = (lock, token)
        do {
            let result = try await runtime.run(serverID, "umask 077; \(Self.parentChecks(path + "/state.json", root: stateRoot)); test ! -L \(q(path)) || exit 45; mkdir -p -- \(q(path)) || exit 45; chmod 700 -- \(q(path)) || exit 45; mkdir -- \(q(lock)) 2>/dev/null || exit 73; cat > \(q(lock + "/owner")) || exit 45", stdin: Data(token.utf8))
            guard result.code == 0, !result.truncated else { throw NativeRPCError(code: result.code == 73 ? "busy" : "state-failed", message: result.code == 73 ? "Another Mac is changing this app. If it stopped, inspect its server lock before retrying." : "The server could not protect this app's state.") }
        } catch { _ = await release(serverID, lock, token: token, handle: lockRecovery[key]); throw error }
        let value: T
        do { value = try await body() }
        catch {
            if let held = locks[key], !(await release(serverID, held.path, token: held.token, handle: lockRecovery[key])) { throw NativeRPCError(code: "state-failed", message: "The app action did not finish and its owned lock recovery could not be verified. Inspect its saved recovery notes.") }
            throw error
        }
        if let held = locks[key], !(await release(serverID, held.path, token: held.token, handle: lockRecovery[key])) { throw NativeRPCError(code: "state-failed", message: "The action finished, but its owned app lock could not be released. Inspect the transaction audit before retrying.") }
        return value
    }
    /// Restores the exact captured before-image; caller-supplied new bytes
    /// never cross the cancelled authority boundary.
    public func recoverFile(_ serverID: String, path: String) async throws -> Bool {
        try checkPath(path)
        let relative = String(path.dropFirst(stateRoot.count + 1)), app = String(relative.split(separator: "/").first ?? "")
        guard let recovery = runtime.recovery, let transaction = BackendAppsRecoveryContext.transaction(serverID: serverID, appID: app), transaction.belongs(to: recovery) else { throw NativeRPCError(code: "access-denied", message: "That app file has no sealed recovery before-image.") }
        let captured = await transaction.registered(.restoreAppFile(path: path))
        guard let handle = captured else { throw NativeRPCError(code: "access-denied", message: "That app file has no sealed recovery before-image.") }
        return try await transaction.perform(handle).completed
    }
    public func archiveLocked(_ serverID: String, _ appID: String) async throws {
        let key = serverID + ":" + appID
        guard let held = locks[key] else { throw NativeRPCError(code: "conflict", message: "The app must be locked before it can be archived.") }
        let path = try directory(appID), archive = stateRoot + "/" + (runtime.resourcePrefix == "td-test" ? "td-test-removed-" : ".removed-") + appID + "-" + UUID().uuidString
        let archivedHandle: BackendAppsRecoveryHandle?
        if let transaction = BackendAppsRecoveryContext.current { archivedHandle = try await transaction.register(.releaseOwnedLock(path: archive + "/.lock", ownerToken: held.token)) }
        else { archivedHandle = nil }
        let q = BackendAppsRuntime.quote
        do { _ = try await runtime.checked(serverID, "set -eu; mv -- \(q(path + "/state.json")) \(q(path + "/.archived-state.json")); if ! mv -- \(q(path)) \(q(archive)); then mv -- \(q(path + "/.archived-state.json")) \(q(path + "/state.json")); exit 1; fi", code: "state-failed", message: "The app stopped, but its saved state could not be archived.") }
        catch {
            // A lost reply may follow both successful moves. Both possible
            // paths were sealed while live, and absent paths are idempotent.
            if let archivedHandle, let transaction = BackendAppsRecoveryContext.current {
                let outcome = await Task { try? await transaction.perform(archivedHandle) }.value
                guard outcome?.completed == true else { throw NativeRPCError(code: "state-failed", message: "The archive result is uncertain and its owned archived lock could not be recovered. Inspect the transaction audit and saved app data.") }
            }
            throw error
        }
        locks[key] = (archive + "/.lock", held.token)
        if let archivedHandle { lockRecovery[key] = archivedHandle }
    }
    private func release(_ serverID: String, _ lock: String, token: String, handle: BackendAppsRecoveryHandle?) async -> Bool {
        if runtime.recovery != nil {
            guard let transaction = BackendAppsRecoveryContext.current, let handle else { return false }
            return await Task { (try? await transaction.perform(handle).completed) ?? false }.value
        }
        let execute = runtime.execute
        // A fresh task releases the lock even when the action was cancelled.
        let q = BackendAppsRuntime.quote
        let script = "test ! -L \(q(lock)) && test ! -L \(q(lock + "/owner")) && test -f \(q(lock + "/owner")) && test \"$(cat -- \(q(lock + "/owner")))\" = \(q(token)) && rm -- \(q(lock + "/owner")) && rmdir -- \(q(lock))"
        let result = await Task { try? await execute(serverID, "sh -c " + q(script), nil, 10_000, 1024) }.value
        return result?.code == 0 && result?.truncated == false
    }
    private func checkPath(_ path: String) throws {
        let expectedTestRoot = "/var/lib/" + (try BackendAppsValidation.id(runtime.resourcePrefix)) + "-apps"
        guard [Self.root, expectedTestRoot].contains(stateRoot), path.hasPrefix(stateRoot + "/"), !path.contains(".."), path.range(of: #"^[A-Za-z0-9/_.-]+$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("That saved app path is invalid.") }
    }
    private static func parentChecks(_ path: String, root: String) -> String {
        var checks = ["test ! -L " + root + " || exit 45"]
        if root == Self.root { checks.insert("test ! -L /var/lib/terminaldeck || exit 45", at: 0) }
        let relative = String(path.dropFirst(root.count + 1)).split(separator: "/").dropLast()
        var parent = root
        for component in relative { parent += "/" + component; checks.append("test ! -L " + BackendAppsRuntime.quote(parent) + " || exit 45") }
        return checks.joined(separator: "; ")
    }
    public static func publicRecord(_ record: NativeRPCValue) -> NativeRPCValue {
        let keys: Set<String> = ["id", "name", "kind", "status", "address", "domains", "source", "activeDeploymentId", "createdAt", "updatedAt", "envKeys", "backupPolicy", "autoDeploy", "lastError"]
        var result = sanitize(.object((record.fields ?? []).filter { keys.contains($0.key) }))
        if let fields = result["source"].fields {
            let textKeys: Set<String> = ["kind", "repository", "branch", "build", "dockerfile", "composeFile", "service", "templateId"]
            result = result.setting("source", .object(fields.filter {
                if textKeys.contains($0.key) { return $0.value.string != nil }
                if $0.key == "port", let value = $0.value.number { return value.rounded() == value && (1...65535).contains(value) }
                return false
            }))
        }
        return result
    }
    private static func sanitize(_ value: NativeRPCValue) -> NativeRPCValue {
        if let fields = value.fields { return .object(fields.filter { !["env", "password", "token", "secret", "secretKey", "accessKey", "credentials"].contains($0.key) }.map { .init($0.key, sanitize($0.value)) }) }
        if let elements = value.elements { return .array(elements.map(sanitize)) }
        return value
    }
}
