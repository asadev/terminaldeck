import Foundation
import TerminalDeckNativeCore

/// Copies a private database connection into an app's protected settings on the same saved server.
/// The channel authorizes both selected resources first; no URI, password or deploy leaves this service.
public struct BackendAppsDataDatabaseBinding: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) { self.runtime = runtime; self.store = store }

    /// Internal log-redaction input only. Apps can print a decoded password from a stored connection URI.
    /// DKA/APE must feed these fragments to existing chunk-safe log masking; never return them through a tool.
    public static func redactionSecrets(in environment: [String: String]) -> [String] {
        redactionSecrets(values: Array(environment.values))
    }

    /// Combine saved settings and inspected running-service secrets before expanding URI passwords.
    public static func redactionSecrets(values: [String]) -> [String] {
        var secrets = Set(values.filter { !$0.isEmpty })
        for value in values {
            guard let components = URLComponents(string: value),
                  ["postgresql", "mysql", "redis", "mongodb"].contains(components.scheme?.lowercased() ?? "") else { continue }
            if let password = components.password, !password.isEmpty { secrets.insert(password) }
            if let encoded = components.percentEncodedPassword, !encoded.isEmpty { secrets.insert(encoded) }
        }
        return secrets.sorted { $0.count > $1.count }
    }

    public func bind(serverID: String, appID: String, targetAppID: String, key: String?) async throws -> NativeRPCValue {
        try BackendAppsDataDatabases.validateRuntime(runtime, appID: appID)
        try BackendAppsDataDatabases.validateRuntime(runtime, appID: targetAppID)
        guard appID != targetAppID, !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              serverID.utf8.count <= 256, !serverID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeRPCError.invalidArguments("Choose a different app on the same saved server.")
        }
        if let key { try Self.validateKey(key) }
        let ordered = [appID, targetAppID].sorted(), store = self.store
        if let recovery = runtime.recovery {
            guard BackendAppsRecoveryContext.current == nil, BackendAppsRecoveryContext.active.isEmpty,
                  let context = NativeCompositionCallContext.rpc else {
                throw NativeRPCError(code: "access-denied", message: "Database binding needs its own two-app approved request; it cannot borrow an active transaction.")
            }
            // Both captures use the same still-live approved request. The trusted issuer admits only
            // its exact source/target pair; this consumer neither clears a scope nor grants another app.
            let first = try await recovery.begin(runtime: runtime, serverID: serverID, appID: ordered[0])
            do {
                let second = try await recovery.begin(runtime: runtime, serverID: serverID, appID: ordered[1])
                do {
                    guard Self.matches(first, recovery: recovery, runtime: runtime, serverID: serverID, appID: ordered[0], context: context),
                          Self.matches(second, recovery: recovery, runtime: runtime, serverID: serverID, appID: ordered[1], context: context),
                          first.scope.transactionID != second.scope.transactionID,
                          NativeCompositionCallContext.rpc?.requestID == context.requestID,
                          NativeCompositionCallContext.rpc?.ownerID == context.ownerID,
                          NativeCompositionCallContext.rpc?.caller == context.caller else {
                        throw NativeRPCError(code: "access-denied", message: "The two app recovery transactions do not belong to the same approved request.")
                    }
                    let targetTransaction = ordered[0] == targetAppID ? first : second
                    let value = try await BackendAppsRecoveryContext.$active.withValue([first, second]) {
                        try await BackendAppsRecoveryContext.$current.withValue(first) {
                            try await store.withLock(serverID, ordered[0]) {
                                try await BackendAppsRecoveryContext.$current.withValue(second) {
                                    try await store.withLock(serverID, ordered[1]) {
                                        try await BackendAppsRecoveryContext.$current.withValue(targetTransaction) {
                                            try await bindLocked(serverID: serverID, appID: appID, targetAppID: targetAppID, requestedKey: key)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    await recovery.finish(second); await recovery.finish(first)
                    return value
                } catch { await recovery.finish(second); throw error }
            } catch { await recovery.finish(first); throw error }
        }
        // Nil recovery remains only the existing inert fake/custom-adapter compatibility path.
        return try await store.withLock(serverID, ordered[0]) {
            try await store.withLock(serverID, ordered[1]) {
                try await bindLocked(serverID: serverID, appID: appID, targetAppID: targetAppID, requestedKey: key)
            }
        }
    }

    private func bindLocked(serverID: String, appID: String, targetAppID: String, requestedKey: String?) async throws -> NativeRPCValue {
        let source = try await store.read(serverID, appID), target = try await store.read(serverID, targetAppID)
        let sourceDirectory = try store.directory(appID), targetDirectory = try store.directory(targetAppID)
        for (directory, names) in [(sourceDirectory, ["data-restore-intent.json", "data-backup-policy-recovery.json"]),
                                  (targetDirectory, ["data-binding-intent.json"])] {
            for name in names {
                if try await store.readFile(serverID, path: directory + "/" + name) != nil {
                    throw NativeRPCError(code: "conflict", message: "This app has saved recovery notes. Resolve them before changing its connection settings.")
                }
            }
        }
        guard target["kind"].string == "app", target["pendingDeploymentId"].isNullish,
              target["status"].string != "deploying" else {
            throw NativeRPCError(code: "conflict", message: "Choose an ordinary app with no deploy or recovery change in progress.")
        }
        let connection = try BackendAppsDataDatabases.publicConnection(source, runtime: runtime)
        let kind = connection["kind"].string!, host = connection["host"].string!, port = Int(connection["port"].number!)
        guard let containerID = source["database"]["containerId"].string,
              source["containerId"].string == containerID,
              let volume = source["database"]["volumeName"].string,
              let imageID = source["database"]["imageId"].string else {
            throw NativeRPCError(code: "state-failed", message: "The database's saved identities need recovery before it can be connected.")
        }
        let inspected = try await BackendAppsDataDatabases.inspectOwned(runtime: runtime, serverID: serverID, appID: appID,
                                                                       containerID: containerID, volumeName: volume, expectedImageID: imageID, kind: kind)
        guard source["status"].string == "running", inspected["State"]["Running"].bool == true,
              inspected["State"]["Health"]["Status"].string == "healthy",
              inspected["Config"]["Healthcheck"]["Test"].elements == [.string("CMD-SHELL"), .string(try BackendAppsDataDatabases.authenticatedHealthcheck(kind: kind))],
              inspected["NetworkSettings"]["Networks"][runtime.privateNetwork]["Aliases"].elements?.contains(.string(host)) == true else {
            throw NativeRPCError(code: "health-failed", message: "The database must pass its private sign-in check before connecting an app.")
        }
        let environment = try await store.environment(serverID, appID)
        let credentials = try Self.credentials(kind: kind, environment: environment, inspectedEnvironment: inspected["Config"]["Env"])
        let setting = requestedKey ?? (kind == "redis" ? "REDIS_URL" : "DATABASE_URL")
        try Self.validateKey(setting)
        let uri = try Self.connectionURI(kind: kind, host: host, port: port, username: credentials.username, password: credentials.password)
        let previousEnvironment = try await store.environment(serverID, targetAppID)
        var nextEnvironment = previousEnvironment
        nextEnvironment[setting] = uri
        _ = try BackendAppsValidation.environment(.object(nextEnvironment.map { .init($0.key, .string($0.value)) }))
        let now = runtime.now()
        guard now.isFinite, now > 0 else { throw NativeRPCError(code: "state-failed", message: "The connection setting time is invalid.") }
        let updated = target.setting("envKeys", .array(nextEnvironment.keys.sorted().map(NativeRPCValue.string))).setting("updatedAt", .number(now))
        let nonce = UUID().uuidString.lowercased(), intentPath = targetDirectory + "/data-binding-intent.json"
        let environmentSnapshot = targetDirectory + "/.data-binding-" + nonce + ".env"
        let recordSnapshot = targetDirectory + "/.data-binding-" + nonce + ".state.json"
        let previousText = previousEnvironment.keys.sorted().map { $0 + "=" + previousEnvironment[$0]! + "\n" }.joined()
        for path in [environmentSnapshot, recordSnapshot, intentPath] {
            if try await store.readFile(serverID, path: path) != nil {
                throw NativeRPCError(code: "conflict", message: "Protected connection recovery files already use this action's names. They were preserved.")
            }
        }
        let recoveryPlan: RecoveryPlan?
        if let transaction = BackendAppsRecoveryContext.current {
            guard runtime.recovery != nil, transaction.scope.appID == targetAppID, transaction.scope.serverID == serverID else {
                throw NativeRPCError(code: "access-denied", message: "The target settings require their own approved app recovery scope.")
            }
            let environmentHandle = try await transaction.register(.restoreAppFile(path: targetDirectory + "/.env"))
            let recordHandle = try await transaction.register(.restoreAppFile(path: targetDirectory + "/state.json"))
            var cleanup: [BackendAppsRecoveryHandle] = []
            // Capture absent snapshot paths and note before creation, deleting the note last only after
            // env/record recovery is verified. No caller-supplied recovery bytes cross the sealed API.
            for path in [environmentSnapshot, recordSnapshot, intentPath] {
                cleanup.append(try await transaction.register(.restoreAppFile(path: path)))
            }
            recoveryPlan = .init(transaction: transaction, environment: environmentHandle, record: recordHandle, cleanup: cleanup)
        } else { recoveryPlan = nil }
        let intent = BackendAppsValidation.object([
            ("phase", .string("binding")), ("appId", .string(appID)), ("targetAppId", .string(targetAppID)),
            ("key", .string(setting)), ("environmentSnapshot", .string(environmentSnapshot)),
            ("recordSnapshot", .string(recordSnapshot)), ("createdAt", .number(now))
        ])
        var committed = false
        do {
            try await store.writeFile(serverID, path: environmentSnapshot, contents: Data(previousText.utf8))
            try await store.writeFile(serverID, path: recordSnapshot, contents: target.encodedJSON(pretty: true))
            try await store.writeFile(serverID, path: intentPath, contents: intent.encodedJSON())
            try await store.applyEnvironment(serverID, targetAppID, nextEnvironment)
            try await store.write(serverID, targetAppID, updated)
            guard try await store.environment(serverID, targetAppID) == nextEnvironment,
                  Self.sameRecord(try await store.read(serverID, targetAppID), updated) else {
                throw NativeRPCError(code: "state-failed", message: "The app's saved connection setting could not be verified.")
            }
            committed = true
            if let recoveryPlan {
                guard try await recoveryPlan.clearNotes() else { throw NativeRPCError(code: "state-failed", message: "Protected connection recovery notes could not be verified as cleared.") }
            } else {
                try await clearNotes(serverID: serverID, directory: targetDirectory, paths: [intentPath, environmentSnapshot, recordSnapshot])
            }
            return BackendAppsValidation.object([
                ("bound", .bool(true)), ("appId", .string(appID)), ("targetAppId", .string(targetAppID)),
                ("key", .string(setting)), ("value", .string("••••••••")), ("secret", .bool(true)), ("requiresDeploy", .bool(true))
            ])
        } catch {
            if committed {
                throw NativeRPCError(code: "state-failed", message: "The private connection setting was saved, but its protected cleanup result could not be verified. Inspect the binding state before another change; deploy separately when ready.")
            }
            if let recoveryPlan {
                let recovered = await Task { (try? await recoveryPlan.restore()) ?? false }.value
                // If sealed recovery fails or is revoked, retain the existing intent/snapshots. A new
                // journal phase is not authorized by the old before-image handles after cancellation.
                throw NativeRPCError(code: "state-failed", message: recovered ? "The connection setting was not saved. The app's previous settings were restored and no deploy started." : "The connection setting needs recovery. Protected recovery or cleanup could not be verified; inspect the binding state. No deploy started.")
            }
            let recovered = await Task {
                do {
                    try await store.applyEnvironment(serverID, targetAppID, previousEnvironment)
                    try await store.write(serverID, targetAppID, target)
                    guard try await store.environment(serverID, targetAppID) == previousEnvironment,
                          Self.sameRecord(try await store.read(serverID, targetAppID), target) else { return false }
                    try await clearNotes(serverID: serverID, directory: targetDirectory, paths: [intentPath, environmentSnapshot, recordSnapshot])
                    return true
                } catch { return false }
            }.value
            if !recovered {
                let recovery = intent.setting("phase", .string("recovery-required"))
                await Task { try? await store.writeFile(serverID, path: intentPath, contents: recovery.encodedJSON()) }.value
            }
            throw NativeRPCError(code: "state-failed", message: recovered ? "The connection setting was not saved. The app's previous settings were restored and no deploy started." : "The connection setting needs recovery. Protected recovery or cleanup could not be verified; inspect the binding state. No deploy started.")
        }
    }

    private struct RecoveryPlan: Sendable {
        let transaction: BackendAppsRecoveryTransaction
        let environment: BackendAppsRecoveryHandle
        let record: BackendAppsRecoveryHandle
        let cleanup: [BackendAppsRecoveryHandle]
        func restore() async throws -> Bool {
            let environmentRestored = try await transaction.perform(environment).completed
            let recordRestored = try await transaction.perform(record).completed
            guard environmentRestored && recordRestored else { return false }
            return try await clearNotes()
        }
        func clearNotes() async throws -> Bool {
            for handle in cleanup {
                guard try await transaction.perform(handle).completed else { return false }
            }
            return true
        }
    }
    private static func matches(_ transaction: BackendAppsRecoveryTransaction, recovery: BackendAppsRecovery,
                                runtime: BackendAppsRuntime, serverID: String, appID: String, context: NativeRPCContext) -> Bool {
        let scope = transaction.scope
        return transaction.belongs(to: recovery) && scope.serverID == serverID && scope.appID == appID &&
            scope.ownerID == context.ownerID && scope.requestID == context.requestID &&
            scope.stateRoot == runtime.stateRoot && scope.resourcePrefix == runtime.resourcePrefix &&
            scope.privateNetwork == runtime.privateNetwork && scope.caddyServerKey == runtime.caddyServerKey &&
            scope.caddyAutosavePath == runtime.caddyAutosavePath
    }

    private static func validateKey(_ key: String) throws {
        guard key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]{0,127}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Use a setting name with letters, numbers and underscores.")
        }
    }
    private static func credentials(kind: String, environment: [String: String], inspectedEnvironment: NativeRPCValue) throws -> (username: String, password: String) {
        let keys: [String], username: String
        switch kind {
        case "postgres": keys = ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]; username = environment["POSTGRES_USER"] ?? ""
        case "mysql": keys = ["MYSQL_ROOT_PASSWORD", "MYSQL_DATABASE"]; username = "root"
        case "redis": keys = ["REDIS_PASSWORD"]; username = "default"
        case "mongodb": keys = ["MONGO_INITDB_ROOT_USERNAME", "MONGO_INITDB_ROOT_PASSWORD", "MONGO_INITDB_DATABASE"]; username = environment["MONGO_INITDB_ROOT_USERNAME"] ?? ""
        default: throw NativeRPCError.invalidArguments("Choose a managed database.")
        }
        let passwordKey = keys.first { $0.contains("PASSWORD") }!
        guard !username.isEmpty, let password = environment[passwordKey], !password.isEmpty,
              !["••••••••", "••••••", "[redacted]"].contains(password), let rows = inspectedEnvironment.elements else {
            throw NativeRPCError(code: "state-failed", message: "The database's protected sign-in settings are unavailable.")
        }
        for key in keys {
            guard let value = environment[key], rows.filter({ $0.string?.hasPrefix(key + "=") == true }).count == 1,
                  rows.contains(.string(key + "=" + value)) else {
                throw NativeRPCError(code: "conflict", message: "The saved database sign-in settings differ from its running service. Resolve them before connecting an app.")
            }
        }
        let databaseKey = kind == "postgres" ? "POSTGRES_DB" : (kind == "mysql" ? "MYSQL_DATABASE" : "MONGO_INITDB_DATABASE")
        guard kind == "redis" || environment[databaseKey] == "terminaldeck" else {
            throw NativeRPCError(code: "conflict", message: "The database's saved name differs from its managed connection details.")
        }
        return (username, password)
    }
    private static func connectionURI(kind: String, host: String, port: Int, username: String, password: String) throws -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let user = username.addingPercentEncoding(withAllowedCharacters: unreserved),
              let secret = password.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw NativeRPCError(code: "state-failed", message: "The database sign-in setting could not be safely encoded.")
        }
        let scheme: String, path: String
        switch kind {
        case "postgres": scheme = "postgresql"; path = "terminaldeck"
        case "mysql": scheme = "mysql"; path = "terminaldeck"
        case "redis": scheme = "redis"; path = "0"
        case "mongodb": scheme = "mongodb"; path = "terminaldeck?authSource=admin"
        default: throw NativeRPCError.invalidArguments("Choose a managed database.")
        }
        return "\(scheme)://\(user):\(secret)@\(host):\(port)/\(path)"
    }
    private static func sameRecord(_ lhs: NativeRPCValue, _ rhs: NativeRPCValue) -> Bool {
        guard let left = lhs.fields, let right = rhs.fields, left.count == right.count,
              Set(left.map(\.key)).count == left.count, Set(right.map(\.key)).count == right.count else { return false }
        return left.allSatisfy { field in equalValue(field.value, rhs[field.key]) }
    }
    private static func equalValue(_ lhs: NativeRPCValue, _ rhs: NativeRPCValue) -> Bool {
        if lhs.fields != nil || rhs.fields != nil { return sameRecord(lhs, rhs) }
        if let left = lhs.elements, let right = rhs.elements {
            return left.count == right.count && zip(left, right).allSatisfy { equalValue($0.0, $0.1) }
        }
        return lhs == rhs
    }
    private func clearNotes(serverID: String, directory: String, paths: [String]) async throws {
        let root = String(directory[..<directory.lastIndex(of: "/")!]), q = BackendAppsRuntime.quote
        let ancestor = root == BackendAppsStore.root ? "test ! -L /var/lib/terminaldeck; " : ""
        let checks = ancestor + [root, directory].map { "test -d " + q($0) + " && test ! -L " + q($0) }.joined(separator: "; ")
        let files = paths.map { "test -f " + q($0) + " && test ! -L " + q($0) }.joined(separator: "; ")
        _ = try await runtime.checked(serverID, "set -eu; " + checks + "; " + files + "; rm -- " + paths.map(q).joined(separator: " ") + "; sync -f " + q(directory), code: "state-failed", message: "Protected connection recovery notes could not be safely cleared.")
    }
}
