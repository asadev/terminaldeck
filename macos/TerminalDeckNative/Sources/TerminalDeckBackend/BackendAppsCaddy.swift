import Foundation
import TerminalDeckNativeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Caddy is a host service; candidate apps have no published ports. The host
/// reaches their inspected private bridge IPs. All API calls use the injected
/// existing SSH tunnel to 127.0.0.1:2019, never a remote HTTP URL.
public struct BackendAppsCaddy: Sendable {
    public let runtime: BackendAppsRuntime
    private static let serverKey = "terminaldeck"
    private static let serverID = "td-app-server"

    public init(runtime: BackendAppsRuntime) { self.runtime = runtime }

    /// Read only. These are the exact commands install sends after the caller
    /// has obtained approval. Unsupported systems fail before package changes.
    public func plan() -> NativeRPCValue {
        BackendAppsValidation.object([
            ("commands", .array([.string(Self.installScript)])),
            ("adminAddress", .string("127.0.0.1:2019")),
            ("instructions", .string("Install the address manager on a Debian or Ubuntu server with systemd. It uses ports 80 and 443 for your apps. An existing address manager is kept unchanged."))
        ])
    }

    /// The public channels authorize this write before invoking it. This does
    /// not adopt/stop a pre-existing Caddy installation or other web server.
    public func install(serverID: String) async throws -> NativeRPCValue {
        guard runtime.resourcePrefix == "terminaldeck", runtime.caddyServerKey == nil else {
            throw BackendAppsRuntime.unavailable("This connection keeps its existing address manager. Installation is disabled.")
        }
        let result = try await runtime.run(serverID, Self.installScript, timeoutMS: 300_000, maximumBytes: 16_384)
        guard result.code == 0, !result.truncated else {
            if result.code == 72 { throw BackendAppsRuntime.unavailable("Install the address manager on a Debian or Ubuntu server with systemd and administrator access.") }
            if result.code == 73 { throw NativeRPCError(code: "conflict", message: "An address manager is already installed on this server. Keep it in place and connect it before using Apps.") }
            throw BackendAppsRuntime.unavailable("The address manager could not be installed. Check the server connection and administrator access.")
        }
        _ = try await managedConfiguration(serverID)
        let saved = try await persistedConfiguration(serverID)
        guard saved["apps"]["http"]["servers"][Self.serverKey]["@id"].string == Self.serverID else { throw Self.routeFailure() }
        return BackendAppsValidation.object([("installed", .bool(true))])
    }

    public func defaultDomain(serverID: String, appID: String) async throws -> String {
        let app = try BackendAppsValidation.id(appID)
        let addresses = try await serverAddresses(serverID)
        guard let ipv4 = addresses.first(where: { Self.ipv4($0) != nil }) else {
            throw BackendAppsRuntime.unavailable("This server needs a public IPv4 address for an automatic web address. You can use your own domain instead.")
        }
        if runtime.resourcePrefix == "td-test" {
            return (app.hasPrefix("td-test-") ? app : "td-test-" + app) + "." + ipv4.replacingOccurrences(of: ".", with: "-") + ".sslip.io"
        }
        return app + "." + ipv4 + ".sslip.io"
    }

    /// Every observed A/AAAA answer must target this server. A matching A with
    /// an old AAAA elsewhere is not ready for HTTPS.
    public func check(serverID: String, domain: String) async throws -> NativeRPCValue {
        let host = try Self.hostname(domain)
        let expected = try await serverAddresses(serverID)
        let observed: [String]
        do { observed = try await runtime.resolveDNS(host) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The address check did not finish. Try again after checking the server connection.") }
        let expectedKeys = Set(expected.compactMap(Self.canonicalIP))
        let observedKeys = observed.compactMap(Self.canonicalIP)
        let matches = !observed.isEmpty && observedKeys.count == observed.count && observedKeys.allSatisfy { expectedKeys.contains($0) }
        let a = expected.filter { Self.ipv4($0) != nil }
        let aaaa = expected.filter { Self.ipv4($0) == nil }
        var steps: [String] = []
        if !a.isEmpty { steps.append("Set the A record for " + host + " to " + a.joined(separator: " or ") + ".") }
        if !aaaa.isEmpty { steps.append("If you use an AAAA record, set it to " + aaaa.joined(separator: " or ") + ".") }
        steps.append("Remove A or AAAA records pointing to another server. DNS changes can take time to appear.")
        return BackendAppsValidation.object([
            ("domain", .string(host)), ("pointsHere", .bool(matches)),
            ("expected", .array(expected.map(NativeRPCValue.string))),
            ("observed", .array(Array(Set(observed)).sorted().map(NativeRPCValue.string))),
            ("instructions", .string(steps.joined(separator: " ")))
        ])
    }

    /// DNS is checked by the public domains channel before calling swap. The
    /// deployment path also uses this method to compensate after failed state
    /// persistence, so swap must not depend on fresh DNS during compensation.
    public func swap(serverID: String, appID: String, domains: [String], upstream: String, port: Int) async throws {
        let app = try BackendAppsValidation.id(appID)
        guard (1...65_535).contains(port), Self.privateIPv4(upstream) else { throw NativeRPCError.invalidArguments("The app needs a private server address and a valid port.") }
        guard !domains.isEmpty, domains.count <= 32 else { throw NativeRPCError.invalidArguments("Add between 1 and 32 web addresses.") }
        let hosts = try domains.map(Self.hostname)
        guard Set(hosts).count == hosts.count else { throw NativeRPCError.invalidArguments("Each web address should appear once.") }
        let routeID = try resourceID(app)
        let route = Self.route(id: routeID, domains: hosts, upstream: upstream, port: port)
        _ = try autosavePath()
        try await withConfigurationLock(serverID, appID: app) {
            let config = try await managedConfiguration(serverID)
            let currentRoutes = try routes(config)
            // The lock is global across Macs/app IDs, so two apps cannot claim
            // one hostname between checking and appending/replacing a route.
            let allRoutes = (config["apps"]["http"]["servers"].fields ?? []).flatMap { $0.value["routes"].elements ?? [] }
            let ownOccurrences = allRoutes.filter { $0["@id"].string == routeID }
            guard ownOccurrences.count <= 1, ownOccurrences.isEmpty || currentRoutes.contains(where: { $0["@id"].string == routeID }) else {
                throw NativeRPCError(code: "conflict", message: "This app's address settings belong to a different server view.")
            }
            for other in allRoutes where other["@id"].string != routeID {
                let otherHosts = Set((other["match"].elements ?? []).flatMap { ($0["host"].elements ?? []).compactMap(\.string) }.map { $0.lowercased() })
                guard !hosts.contains(where: { host in otherHosts.contains(where: { existing in Self.hostPattern(existing, contains: host) }) }) else { throw NativeRPCError(code: "conflict", message: "One of these addresses already belongs to another app.") }
            }
            let previous = currentRoutes.first { $0["@id"].string == routeID }
            // The previous route must already be durable before replacing it.
            try await verifyPersistedRoute(serverID, routeID: routeID, expected: previous)
            let collectionPath = try routesPath()
            let recovery = try await registerRouteRecovery(serverID, routeID: routeID, collectionPath: collectionPath)
            do {
                // A new route is inserted ahead of any existing catch-all.
                // PUT /routes/0 inserts; it does not replace the old first row.
                let response = try await request(serverID, previous != nil ? "PATCH" : "PUT", previous != nil ? "/id/" + routeID : collectionPath + "/0", body: route)
                guard response.ok else { throw Self.routeFailure() }
                try await verifyPersistedRoute(serverID, routeID: routeID, expected: route)
            } catch {
                guard await compensate(serverID, routeID: routeID, previous: previous, collectionPath: collectionPath, recovery: recovery) else { throw Self.uncertainRouteFailure() }
                throw Self.recoveredRouteError(error)
            }
            // Caddy's individual mutation is atomic. Its autosave can fail
            // separately, so disk verification is required above. Never
            // GET-edit-POST the whole config, even during compensation.
        }
    }

    public func remove(serverID: String, appID: String) async throws {
        let app = try BackendAppsValidation.id(appID)
        let routeID = try resourceID(app)
        _ = try autosavePath()
        try await withConfigurationLock(serverID, appID: app) {
            let config = try await managedConfiguration(serverID)
            let previous = try routes(config).first(where: { $0["@id"].string == routeID })
            guard let previous else {
                try await verifyPersistedRoute(serverID, routeID: routeID, expected: nil)
                return
            }
            try await verifyPersistedRoute(serverID, routeID: routeID, expected: previous)
            let collectionPath = try routesPath()
            let recovery = try await registerRouteRecovery(serverID, routeID: routeID, collectionPath: collectionPath)
            do {
                let response = try await request(serverID, "DELETE", "/id/" + routeID)
                guard response.ok else { throw Self.routeFailure() }
                try await verifyPersistedRoute(serverID, routeID: routeID, expected: nil)
            } catch {
                guard await compensate(serverID, routeID: routeID, previous: previous, collectionPath: collectionPath, recovery: recovery) else { throw Self.uncertainRouteFailure() }
                throw Self.recoveredRouteError(error)
            }
        }
    }

    public static func hostname(_ text: String) throws -> String {
        let host = text.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, host == host.trimmingCharacters(in: .whitespacesAndNewlines), labels.count >= 2,
              ipv4(host) == nil, labels.last?.contains(where: { $0.isLetter && $0.isASCII }) == true,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal") else {
            throw NativeRPCError.invalidArguments("Enter a public domain name, without https://, a port, a path or a wildcard.")
        }
        return host
    }

    private func request(_ serverID: String, _ method: String, _ path: String, body: NativeRPCValue? = nil) async throws -> BackendAppsHTTPResponse {
        try Task.checkCancellation()
        do { return try await runtime.caddy(serverID, method, path, try body?.encodedJSON()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The server's address manager is not reachable. Install it or check the server connection.") }
    }

    private func managedConfiguration(_ serverID: String) async throws -> NativeRPCValue {
        let response = try await request(serverID, "GET", "/config/")
        guard response.ok, let config = try? response.value(),
              config["admin"]["disabled"].bool != true,
              config["admin"]["remote"].isNullish, config["admin"]["config"]["persist"].bool != false else {
            throw BackendAppsRuntime.unavailable("The address manager is not configured for Apps. Install it before deploying.")
        }
        let listener = config["admin"]["listen"].string
        let loopback = ["127.0.0.1:2019", "localhost:2019", "[::1]:2019"].contains(listener ?? "")
        let selectedKey = try serverKey()
        let server = config["apps"]["http"]["servers"][selectedKey]
        if runtime.caddyServerKey != nil {
            // An explicit existing-server binding is made by DKA after checking
            // the existing tunnel/service. Missing listen uses Caddy's default.
            guard loopback || config["admin"]["listen"].isNullish, server.fields != nil else { throw BackendAppsRuntime.unavailable("The existing address manager needs a private connection for Apps.") }
        } else {
            guard loopback, server["@id"].string == Self.serverID, server["listen"].elements == [.string(":443")] else { throw BackendAppsRuntime.unavailable("The address manager is not configured for Apps. Install it before deploying.") }
        }
        _ = try routes(config)
        return config
    }

    private func routes(_ config: NativeRPCValue) throws -> [NativeRPCValue] {
        let key = try serverKey()
        guard let routes = config["apps"]["http"]["servers"][key]["routes"].elements, routes.allSatisfy({ $0.fields != nil }) else { throw Self.routeFailure() }
        return routes
    }

    private func serverKey() throws -> String { try BackendAppsValidation.identifier(runtime.caddyServerKey ?? Self.serverKey) }
    private func routesPath() throws -> String { "/config/apps/http/servers/" + (try serverKey()) + "/routes" }
    private func resourceID(_ app: String) throws -> String {
        let prefix = try BackendAppsValidation.id(runtime.resourcePrefix)
        // App IDs and route IDs are separate namespaces. Always prefix so
        // `site` and `terminaldeck-site` cannot share one recovery target.
        return prefix + "-" + app
    }

    private func autosavePath() throws -> String {
        guard let path = runtime.caddyAutosavePath, path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), path.utf8.count <= 4096 else {
            throw BackendAppsRuntime.unavailable("The address manager's saved settings location is unavailable.")
        }
        return path
    }

    private func persistedConfiguration(_ serverID: String) async throws -> NativeRPCValue {
        let path = try autosavePath()
        let result = try await runtime.run(serverID, "cat " + BackendAppsRuntime.quote(path), timeoutMS: 10_000, maximumBytes: 1_048_576)
        guard result.code == 0, !result.truncated, let config = try? NativeRPCValue.parseJSON(Data(result.stdout.utf8)) else { throw Self.routeFailure() }
        return config
    }

    private func verifyPersistedRoute(_ serverID: String, routeID: String, expected: NativeRPCValue?) async throws {
        let config = try await persistedConfiguration(serverID)
        let route = try routes(config).first { $0["@id"].string == routeID }
        if let expected {
            guard let route, Self.equivalent(route, expected) else { throw Self.routeFailure() }
        } else if route != nil { throw Self.routeFailure() }
    }

    private static func equivalent(_ left: NativeRPCValue, _ right: NativeRPCValue) -> Bool {
        guard let a = left.foundation, let b = right.foundation,
              let encodedA = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]),
              let encodedB = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
        return encodedA == encodedB
    }

    private static func hostPattern(_ pattern: String, contains host: String) -> Bool {
        if pattern == host || pattern == "*" { return true }
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst())) }
        // The app only creates exact host matches. An unusual existing pattern
        // gets a conservative overlap check rather than being overwritten.
        if pattern.contains("*") {
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return host.range(of: regex, options: .regularExpression) != nil
        }
        return false
    }

    private struct RecoveryStep: Sendable {
        let transaction: BackendAppsRecoveryTransaction
        let handle: BackendAppsRecoveryHandle
    }

    /// An outer app transaction can restore its pre-registered route after a
    /// later state commit fails. It cannot mint a handle or supply route JSON.
    public func recoverRoute(serverID: String, appID: String) async throws -> Bool {
        let app = try BackendAppsValidation.id(appID)
        guard let transaction = try recoveryTransaction(serverID), transaction.scope.appID == app else {
            throw NativeRPCError(code: "access-denied", message: "Only this app's captured route can be recovered.")
        }
        let operation = BackendAppsRecoveryOperation.restoreCaddyRoute(routeID: try resourceID(app), collectionPath: try routesPath())
        guard let handle = await transaction.registered(operation) else { return false }
        return await performRecovery(.init(transaction: transaction, handle: handle))
    }

    private func recoveryTransaction(_ serverID: String) throws -> BackendAppsRecoveryTransaction? {
        guard runtime.recovery != nil else { return nil }
        guard let transaction = BackendAppsRecoveryContext.current,
              transaction.scope.serverID == serverID, transaction.scope.resourcePrefix == runtime.resourcePrefix,
              transaction.scope.caddyServerKey == runtime.caddyServerKey,
              transaction.scope.caddyAutosavePath == runtime.caddyAutosavePath else {
            throw NativeRPCError(code: "access-denied", message: "The address change needs its approved app recovery transaction.")
        }
        return transaction
    }

    private func registerRouteRecovery(_ serverID: String, routeID: String, collectionPath: String) async throws -> RecoveryStep? {
        guard let transaction = try recoveryTransaction(serverID) else { return nil }
        // The trusted kernel captures the prior route itself through the
        // approved transport. No replacement JSON enters a recovery handle.
        let handle = try await transaction.register(.restoreCaddyRoute(routeID: routeID, collectionPath: collectionPath))
        return .init(transaction: transaction, handle: handle)
    }

    private func performRecovery(_ step: RecoveryStep) async -> Bool {
        await Task {
            do { return try await step.transaction.perform(step.handle).completed }
            catch { return false }
        }.value
    }

    private func compensate(_ serverID: String, routeID: String, previous: NativeRPCValue?, collectionPath: String, recovery: RecoveryStep?) async -> Bool {
        if let recovery { return await performRecovery(recovery) }
        // Only old fake runtimes use ordinary cleanup. Production coordinators
        // cannot fall back to expired caller I/O when a receipt is unavailable.
        guard runtime.recovery == nil else { return false }
        // A cancelled transport can have applied the request already. Restore
        // inside the same server lock, with an uncancelled cleanup task.
        let service = self
        // Unstructured Task inherits the existing connection's task-local RPC
        // identity while retaining independent cancellation for cleanup.
        return await Task {
            do {
                let config = try await service.managedConfiguration(serverID)
                let current = try service.routes(config).first { $0["@id"].string == routeID }
                if let previous {
                    let response = try await service.request(serverID, current == nil ? "PUT" : "PATCH", current == nil ? collectionPath + "/0" : "/id/" + routeID, body: previous)
                    guard response.ok else { return false }
                } else if current != nil {
                    let response = try await service.request(serverID, "DELETE", "/id/" + routeID)
                    guard response.ok else { return false }
                }
                try await service.verifyPersistedRoute(serverID, routeID: routeID, expected: previous)
                return true
            } catch { return false }
        }.value
    }

    private static func route(id: String, domains: [String], upstream: String, port: Int) -> NativeRPCValue {
        BackendAppsValidation.object([
            ("@id", .string(id)),
            ("match", .array([BackendAppsValidation.object([("host", .array(domains.map(NativeRPCValue.string)))] )])),
            ("handle", .array([BackendAppsValidation.object([
                ("handler", .string("reverse_proxy")),
                ("upstreams", .array([BackendAppsValidation.object([("dial", .string(upstream + ":" + String(port)))] )]))
            ])])),
            ("terminal", .bool(true))
        ])
    }

    private func withConfigurationLock(_ serverID: String, appID: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        let service = self
        // Reuse an existing app transaction; standalone address changes mint
        // one through the same approved issuer before any lock/API mutation.
        try await runtime.withRecoveryTransaction(serverID: serverID, appID: appID) {
            try await service.acquireConfigurationLock(serverID, operation: operation)
        }
    }

    private func acquireConfigurationLock(_ serverID: String, operation: @Sendable () async throws -> Void) async throws {
        let lockPath = "/var/lib/" + (try BackendAppsValidation.id(runtime.resourcePrefix)) + "-caddy-lock"
        let quotedPath = BackendAppsRuntime.quote(lockPath)
        let transaction = try recoveryTransaction(serverID)
        let ownerToken = transaction?.scope.ownerToken ?? UUID().uuidString.lowercased()
        let recovery: RecoveryStep?
        if let transaction {
            let handle = try await transaction.register(.releaseOwnedLock(path: lockPath, ownerToken: ownerToken))
            recovery = .init(transaction: transaction, handle: handle)
        } else { recovery = nil }
        let ownerPath = BackendAppsRuntime.quote(lockPath + "/owner")
        let acquire = "umask 077; if mkdir " + quotedPath + "; then set -C; printf '%s' " + BackendAppsRuntime.quote(ownerToken) + " > " + ownerPath + " && chmod 600 " + ownerPath + " || exit 74; elif [ -d " + quotedPath + " ]; then exit 73; else exit 74; fi"
        let result: BackendServersRunResult
        do { result = try await runtime.run(serverID, acquire, timeoutMS: 10_000, maximumBytes: 1024) }
        catch {
            // The remote mkdir/marker can have completed before its response
            // was lost. The pre-registered handle can release only this token.
            if !(await releaseLock(serverID, path: lockPath, ownerToken: ownerToken, recovery: recovery)), recovery != nil { throw Self.retainedLockFailure() }
            throw error
        }
        guard result.code == 0, !result.truncated else {
            if result.code == 73 { throw NativeRPCError(code: "busy", message: "The server's addresses are being updated. Try again shortly.") }
            if !(await releaseLock(serverID, path: lockPath, ownerToken: ownerToken, recovery: recovery)), recovery != nil { throw Self.retainedLockFailure() }
            throw BackendAppsRuntime.unavailable("The server cannot lock its address settings. Check administrator access.")
        }
        do {
            try await operation()
        } catch {
            guard await releaseLock(serverID, path: lockPath, ownerToken: ownerToken, recovery: recovery) else { throw Self.retainedLockFailure() }
            throw error
        }
        guard await releaseLock(serverID, path: lockPath, ownerToken: ownerToken, recovery: recovery) else { throw Self.retainedLockFailure() }
    }

    private func releaseLock(_ serverID: String, path: String, ownerToken: String, recovery: RecoveryStep?) async -> Bool {
        if let recovery { return await performRecovery(recovery) }
        guard runtime.recovery == nil else { return false }
        // Cancellation must not strand a lock: cleanup gets its own task and
        // does not share the cancelled operation's cancellation state. Never
        // remove an unknown/stale lock automatically.
        let runtime = runtime
        return await Task {
            let q = BackendAppsRuntime.quote
            let owner = q(path + "/owner")
            // read avoids putting the owner marker in command output. Never
            // remove another transaction's lock or a replaced/symlinked file.
            let script = "set -eu; test ! -L " + q(path) + " && test ! -L " + owner + " && test -f " + owner + " || exit 74; td_owner=''; { IFS= read -r td_owner < " + owner + " || [ -n \"$td_owner\" ]; } && [ \"$td_owner\" = " + q(ownerToken) + " ] && rm -- " + owner + " && rmdir " + q(path)
            do {
                let result = try await runtime.run(serverID, script, timeoutMS: 10_000, maximumBytes: 1024)
                return result.code == 0 && !result.truncated
            } catch { return false }
        }.value
    }

    private static func retainedLockFailure() -> NativeRPCError {
        .init(code: "state-failed", message: "The server's address lock release could not be verified. Inspect the saved recovery result before retrying.", details: BackendAppsValidation.object([("routeUncertain", .bool(true)), ("lockRecoveryUncertain", .bool(true))]))
    }

    private static func recoveredRouteError(_ error: Error) -> Error {
        let details = BackendAppsValidation.object([("routeRecovered", .bool(true))])
        if let rpc = error as? NativeRPCError { return NativeRPCError(code: rpc.code, message: rpc.message, details: rpc.details.merging(details)) }
        if error is CancellationError { return NativeRPCError(code: "cancelled", message: "The address change was cancelled. The previous settings were restored.", details: details) }
        let failure = routeFailure()
        return NativeRPCError(code: failure.code, message: failure.message, details: details)
    }

    private func serverAddresses(_ serverID: String) async throws -> [String] {
        let raw: [String]
        do { raw = try await runtime.serverAddresses(serverID) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The server's public address is unavailable.") }
        let valid = raw.filter(Self.publicIP)
        guard !valid.isEmpty else { throw BackendAppsRuntime.unavailable("The server's public address is unavailable.") }
        return Array(Set(valid.map { $0.lowercased() })).sorted()
    }

    private static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { Int($0) }
        guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }), zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return nil }
        return bytes
    }

    private static func privateIPv4(_ text: String) -> Bool {
        guard let ip = ipv4(text) else { return false }
        return ip[0] == 10 || (ip[0] == 172 && (16...31).contains(ip[1])) || (ip[0] == 192 && ip[1] == 168)
    }

    private static func canonicalIP(_ text: String) -> String? {
        guard !text.contains("\0") else { return nil }
        if let ip = ipv4(text) { return "v4:" + ip.map(String.init).joined(separator: ".") }
        var address = in6_addr()
        let parsed = text.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return nil }
        return "v6:" + withUnsafeBytes(of: address) { $0.map { String(format: "%02x", $0) }.joined() }
    }

    private static func publicIP(_ text: String) -> Bool {
        if let ip = ipv4(text) {
            return !privateIPv4(text) && ip[0] != 0 && ip[0] != 127 && ip[0] < 224 && !(ip[0] == 169 && ip[1] == 254) && !(ip[0] == 100 && (64...127).contains(ip[1]))
        }
        guard let key = canonicalIP(text), key.hasPrefix("v6:") else { return false }
        let hex = String(key.dropFirst(3))
        return hex != String(repeating: "0", count: 32) && hex != String(repeating: "0", count: 31) + "1" && !hex.hasPrefix("fc") && !hex.hasPrefix("fd") && !hex.hasPrefix("fe8") && !hex.hasPrefix("fe9") && !hex.hasPrefix("fea") && !hex.hasPrefix("feb") && !hex.hasPrefix("ff") && !hex.hasPrefix("00000000000000000000ffff")
    }

    private static func routeFailure() -> NativeRPCError { .init(code: "route-failed", message: "The new app address could not be activated. The previous address settings are kept.") }
    private static func uncertainRouteFailure() -> NativeRPCError {
        .init(code: "route-failed", message: "The app address change could not be verified. Keep both deployments until the server connection is checked.", details: BackendAppsValidation.object([("routeUncertain", .bool(true))]))
    }

    /// Official Debian repository/package; shell is sent to the Linux server
    /// only. No installer/helper runs on the Mac. A managed service resumes
    /// Caddy's persisted active config after reboot; bootstrap is fallback.
    private static let installScript = #"""
    set -eu
    [ "$(id -u)" -eq 0 ] || exit 72
    command -v systemctl >/dev/null 2>&1 || exit 72
    command -v apt-get >/dev/null 2>&1 || exit 72
    [ -r /etc/os-release ] || exit 72
    . /etc/os-release
    case "$ID" in debian|ubuntu) ;; *) exit 72 ;; esac
    td_service=/etc/systemd/system/terminaldeck-caddy.service
    if [ -f "$td_service" ]; then
      grep -q '^# Managed by Terminal Deck Apps$' "$td_service" || exit 73
      systemctl is-active --quiet terminaldeck-caddy
      systemctl is-enabled --quiet terminaldeck-caddy
      exit 0
    fi
    if command -v caddy >/dev/null 2>&1; then exit 73; fi
    if [ -e /var/lib/caddy/terminaldeck ]; then exit 73; fi
    td_work=$(mktemp -d)
    trap 'rm -rf "$td_work"' EXIT HUP INT TERM
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl --proto '=https' --tlsv1.2 -fsS https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$td_work/caddy.key"
    gpg --batch --yes --dearmor -o "$td_work/caddy.gpg" "$td_work/caddy.key"
    install -m 0644 "$td_work/caddy.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl --proto '=https' --tlsv1.2 -fsS https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$td_work/caddy.list"
    install -m 0644 "$td_work/caddy.list" /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy
    systemctl disable --now caddy.service
    install -d -o caddy -g caddy -m 0700 /var/lib/caddy/terminaldeck /var/lib/caddy/terminaldeck/config /var/lib/caddy/terminaldeck/data
    cat > "$td_work/bootstrap.json" <<'TD_CADDY_JSON'
    {"admin":{"listen":"127.0.0.1:2019","config":{"persist":true}},"apps":{"http":{"servers":{"terminaldeck":{"@id":"td-app-server","listen":[":443"],"routes":[]}}},"tls":{"automation":{"policies":[{"issuers":[{"module":"acme","ca":"https://acme-v02.api.letsencrypt.org/directory"}]}]}}}}
    TD_CADDY_JSON
    install -o caddy -g caddy -m 0600 "$td_work/bootstrap.json" /var/lib/caddy/terminaldeck/bootstrap.json
    cat > "$td_work/terminaldeck-caddy.service" <<'TD_CADDY_SERVICE'
    # Managed by Terminal Deck Apps
    [Unit]
    Description=Terminal Deck app addresses
    After=network-online.target
    Wants=network-online.target
    [Service]
    Type=notify
    User=caddy
    Group=caddy
    Environment=XDG_CONFIG_HOME=/var/lib/caddy/terminaldeck/config
    Environment=XDG_DATA_HOME=/var/lib/caddy/terminaldeck/data
    ExecStart=/usr/bin/caddy run --resume --config /var/lib/caddy/terminaldeck/bootstrap.json
    Restart=on-failure
    RestartSec=3
    TimeoutStopSec=30
    UMask=0077
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectSystem=full
    AmbientCapabilities=CAP_NET_BIND_SERVICE
    CapabilityBoundingSet=CAP_NET_BIND_SERVICE
    LimitNOFILE=1048576
    [Install]
    WantedBy=multi-user.target
    TD_CADDY_SERVICE
    install -m 0644 "$td_work/terminaldeck-caddy.service" "$td_service"
    systemctl daemon-reload
    systemctl enable --now terminaldeck-caddy.service
    systemctl is-active --quiet terminaldeck-caddy.service
    systemctl is-enabled --quiet terminaldeck-caddy.service
    """#
}
