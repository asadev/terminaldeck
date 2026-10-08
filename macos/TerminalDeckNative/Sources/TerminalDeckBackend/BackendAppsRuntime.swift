import Foundation
import TerminalDeckNativeCore

/// Inject the existing server pool, Docker transport and credential provider.
/// Nothing runs at construction; no process, timer, socket or secret cache.
public struct BackendAppsRuntime: Sendable {
    public typealias Execute = @Sendable (_ serverID: String, _ command: String, _ stdin: Data?, _ timeoutMS: Int, _ maximumBytes: Int) async throws -> BackendServersRunResult
    public typealias HTTP = @Sendable (_ serverID: String, _ method: String, _ path: String, _ body: Data?) async throws -> BackendAppsHTTPResponse
    public let execute: Execute
    public let docker: HTTP
    public let caddy: HTTP
    public let githubCredential: @Sendable (String) async throws -> String?
    public let serverAddresses: @Sendable (String) async throws -> [String]
    public let resolveDNS: @Sendable (String) async throws -> [String]
    public let watchLogs: @Sendable (String, String, @escaping @Sendable (BackendAppsLogEvent) async -> Void) async throws -> NativeRPCSubscription
    public let features: Set<String>
    public let privateNetwork: String
    public let resourcePrefix: String
    public let caddyServerKey: String?
    public let caddyAutosavePath: String?
    public let stateRoot: String
    public let recovery: BackendAppsRecovery?
    public let now: @Sendable () -> Double

    public init(execute: @escaping Execute,
                docker: @escaping HTTP = { _, _, _, _ in throw BackendAppsRuntime.unavailable("The app engine has no Docker connection yet.") },
                caddy: @escaping HTTP = { _, _, _, _ in throw BackendAppsRuntime.unavailable("The app engine has no private address-manager connection yet.") },
                githubCredential: @escaping @Sendable (String) async throws -> String? = { _ in nil },
                serverAddresses: @escaping @Sendable (String) async throws -> [String] = { _ in throw BackendAppsRuntime.unavailable("The server's public address is unavailable.") },
                resolveDNS: @escaping @Sendable (String) async throws -> [String] = { _ in throw BackendAppsRuntime.unavailable("DNS checks are unavailable.") },
                watchLogs: @escaping @Sendable (String, String, @escaping @Sendable (BackendAppsLogEvent) async -> Void) async throws -> NativeRPCSubscription = { _, _, _ in throw BackendAppsRuntime.unavailable("Live app logs are unavailable.") },
                features: Set<String> = [], privateNetwork: String = "terminaldeck-apps", resourcePrefix: String = "terminaldeck", caddyServerKey: String? = nil, caddyAutosavePath: String? = "/var/lib/caddy/terminaldeck/config/caddy/autosave.json", stateRoot: String = "/var/lib/terminaldeck/apps", recovery: BackendAppsRecovery? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.execute = execute; self.docker = docker; self.caddy = caddy
        self.githubCredential = githubCredential; self.serverAddresses = serverAddresses
        self.resolveDNS = resolveDNS; self.watchLogs = watchLogs; self.features = features; self.now = now
        self.privateNetwork = privateNetwork; self.resourcePrefix = resourcePrefix
        self.caddyServerKey = caddyServerKey; self.caddyAutosavePath = caddyAutosavePath
        self.stateRoot = stateRoot
        self.recovery = recovery
    }

    public func withRecoveryTransaction<T: Sendable>(serverID: String, appID: String, body: @escaping @Sendable () async throws -> T) async throws -> T {
        if let existing = BackendAppsRecoveryContext.current {
            guard let recovery, existing.belongs(to: recovery), existing.scope.serverID == serverID,
                  existing.scope.stateRoot == stateRoot, existing.scope.privateNetwork == privateNetwork,
                  existing.scope.resourcePrefix == resourcePrefix, existing.scope.caddyServerKey == caddyServerKey,
                  existing.scope.caddyAutosavePath == caddyAutosavePath else { throw NativeRPCError(code: "access-denied", message: "An app transaction cannot borrow another app or server's recovery grant.") }
            let context = NativeCompositionCallContext.rpc
            guard context?.requestID == existing.scope.requestID,
                  context?.ownerID == existing.scope.ownerID || context == nil && existing.scope.requestID == nil else { throw NativeRPCError(code: "access-denied", message: "A binding's app scopes must share the same accepted request.") }
            if let own = BackendAppsRecoveryContext.transaction(serverID: serverID, appID: appID) {
                guard own.belongs(to: recovery), own.scope.ownerID == existing.scope.ownerID,
                      own.scope.requestID == existing.scope.requestID, own.scope.stateRoot == stateRoot,
                      own.scope.resourcePrefix == resourcePrefix, own.scope.privateNetwork == privateNetwork,
                      own.scope.caddyServerKey == caddyServerKey, own.scope.caddyAutosavePath == caddyAutosavePath else { throw NativeRPCError(code: "access-denied", message: "A binding cannot borrow an unrelated app capability.") }
                return try await BackendAppsRecoveryContext.$current.withValue(own) { try await body() }
            }
            // The issuer must verify both IDs in one accepted bind request.
            // A second app always gets a separately issued opaque capability.
            guard BackendAppsRecoveryContext.active.count <= 1 else { throw NativeRPCError(code: "access-denied", message: "A binding recovery request cannot add a third app.") }
        }
        guard let recovery else { return try await body() }
        let transaction = try await recovery.begin(runtime: self, serverID: serverID, appID: appID)
        if let parent = BackendAppsRecoveryContext.current,
           transaction.scope.ownerID != parent.scope.ownerID || transaction.scope.requestID != parent.scope.requestID {
            await recovery.finish(transaction)
            throw NativeRPCError(code: "access-denied", message: "The second app recovery scope does not belong to this bind request.")
        }
        do {
            let parents = BackendAppsRecoveryContext.active.isEmpty ? BackendAppsRecoveryContext.current.map { [$0] } ?? [] : BackendAppsRecoveryContext.active
            let result = try await BackendAppsRecoveryContext.$active.withValue(parents + [transaction]) {
                try await BackendAppsRecoveryContext.$current.withValue(transaction) { try await body() }
            }
            await recovery.finish(transaction); return result
        } catch { await recovery.finish(transaction); throw error }
    }

    public static func unavailable(_ reason: String) -> NativeRPCError { .init(code: "unavailable", message: reason) }
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public func run(_ serverID: String, _ script: String, stdin: Data? = nil, timeoutMS: Int = 30_000, maximumBytes: Int = 1_048_576) async throws -> BackendServersRunResult {
        try Task.checkCancellation()
        do { return try await execute(serverID, "sh -c " + Self.quote(script), stdin, timeoutMS, maximumBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.unavailable("The server command did not finish. Check the server connection.") }
    }
    public func checked(_ serverID: String, _ script: String, stdin: Data? = nil, timeoutMS: Int = 30_000, code: String = "unavailable", message: String = "The server could not complete this action.") async throws -> String {
        let result = try await run(serverID, script, stdin: stdin, timeoutMS: timeoutMS)
        guard result.code == 0, !result.truncated else { throw NativeRPCError(code: code, message: message) }
        return result.stdout
    }
}

public enum BackendAppsLogEvent: Sendable {
    case text(String)
    case ended(failed: Bool)
}

public struct BackendAppsHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data = Data()) { self.status = status; self.body = body }
    public var ok: Bool { (200..<300).contains(status) }
    public func value() throws -> NativeRPCValue { try BackendAppsValidation.json(body) }
}

public enum BackendAppsValidation {
    public static func json(_ data: Data) throws -> NativeRPCValue {
        guard BackendAppsPushVerifier.safeJSON(data) else { throw NativeRPCError.malformed("The server returned invalid, duplicated or oversized JSON.") }
        return try NativeRPCValue.parseJSON(data)
    }
    public static func id(_ text: String) throws -> String {
        guard text.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Use a short app ID with lowercase letters, numbers and dashes.") }
        return text
    }
    public static func identifier(_ text: String) throws -> String {
        guard text.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("That deployment or backup ID is invalid.") }
        return text
    }
    public static func environment(_ value: NativeRPCValue) throws -> [String: String] {
        guard let fields = value.fields, fields.count <= 256 else { throw NativeRPCError.invalidArguments("Settings must be a key and value map.") }
        var result: [String: String] = [:]
        for field in fields {
            guard field.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil,
                  let text = field.value.string, text.utf8.count <= 65_536, !text.unicodeScalars.contains(where: { [0, 10, 13].contains($0.value) }), result[field.key] == nil else { throw NativeRPCError.invalidArguments("Setting names or values are invalid. Values must fit on one line.") }
            result[field.key] = text
        }
        return result
    }
    public static func mask(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in [#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, #"(?i)((?:password|token|secret|api[_-]?key)\s*[=:]\s*)[^\s,;]+"#, #"(?i)https?://[^/@\s]+:[^/@\s]+@"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
    public static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
}
