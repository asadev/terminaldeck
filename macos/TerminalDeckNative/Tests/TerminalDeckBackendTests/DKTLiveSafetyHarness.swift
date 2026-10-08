import Foundation
import CryptoKit

/// Test-harness policy, independent of UI/MCP approval. It grants no product access.
enum DKTLiveTarget: String, Codable, Sendable {
    case demo = "terminaldeck-server"
    case store = "terminaldeck-store"
    static func resolve(_ alias: String) throws -> Self {
        guard let target = Self(rawValue: alias) else {
            throw DKTLiveSafetyRefusal("Only the approved demo and read-only store aliases may be contacted. The relay and all other hosts are refused.")
        }
        return target
    }
}

struct DKTLiveSafetyRefusal: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DKTLiveResourceProof: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case container, image, volume, network, app, database, backup, caddyRoute, serverFolder }
    let kind: Kind
    let id: String
    /// Resolved from the real resource before a destructive request, not a payload claim.
    let name: String
}

enum DKTLiveOperation: Sendable {
    case read(channel: String)
    case mutation(channel: String, resources: [DKTLiveResourceProof])
    case caddyRouteMutation(method: String, path: String, routeID: String, body: Data?)
    case filesystemMutation(paths: [String])
}

enum DKTLiveSafetyHarness {
    static let prefix = "td-test-"
    static let protectedHostname = "178-105-239-176.sslip.io"
    static let readChannels: Set<String> = [
        "docker:targets", "docker:status", "docker:containers:list", "docker:containers:inspect", "docker:images:list",
        "docker:volumes:list", "docker:networks:list", "docker:compose:list", "docker:compose:inspect",
        "docker:logs:open", "docker:stats:open", "docker:events:open", "docker:stream:close",
        "apps:capabilities", "apps:list", "apps:read", "apps:deployments", "apps:env:read", "apps:domains:check", "apps:databases:connection",
        "apps:caddy:plan", "apps:backups:list", "apps:backups:policy:read", "apps:templates:list", "apps:logs:read", "apps:logs:watch", "apps:logs:unwatch",
    ]
    static let mutationChannels: Set<String> = [
        "docker:containers:start", "docker:containers:stop", "docker:containers:restart", "docker:containers:remove",
        "docker:images:remove", "docker:volumes:create", "docker:volumes:remove", "docker:networks:create", "docker:networks:remove",
        "docker:exec:open", "docker:exec:write", "docker:exec:resize", "docker:exec:close",
        "apps:create", "apps:deploy", "apps:rollback", "apps:restart", "apps:remove", "apps:env:apply", "apps:env:patch", "apps:domains:apply",
        "apps:databases:create", "apps:backups:create", "apps:backups:policy", "apps:backups:restore", "apps:templates:deploy",
    ]

    static func authorize(target: DKTLiveTarget, operation: DKTLiveOperation) throws {
        switch operation {
        case .read(let channel):
            guard readChannels.contains(channel) else { throw DKTLiveSafetyRefusal("This live read operation is not allowlisted.") }
        case .mutation(let channel, let resources):
            try requireDemo(target)
            guard mutationChannels.contains(channel), !resources.isEmpty else {
                throw DKTLiveSafetyRefusal("This live mutation is unavailable or has no resolved test resources. Docker/Caddy installation and arbitrary commands are refused.")
            }
            guard resources.allSatisfy({ !$0.id.isEmpty && validTestName($0.name) }) else {
                throw DKTLiveSafetyRefusal("Every live mutation resource must have a verified td-test-* name.")
            }
            let expected: Set<DKTLiveResourceProof.Kind>
            if channel.hasPrefix("docker:containers:") || channel.hasPrefix("docker:exec:") { expected = [.container] }
            else if channel.hasPrefix("docker:images:") { expected = [.image] }
            else if channel.hasPrefix("docker:volumes:") { expected = [.volume] }
            else if channel.hasPrefix("docker:networks:") { expected = [.network] }
            else if channel.hasPrefix("apps:backups:") || channel == "apps:databases:create" { expected = [.database] }
            else { expected = [.app, .database] }
            guard resources.contains(where: { expected.contains($0.kind) }),
                  channel != "apps:backups:restore" || resources.contains(where: { $0.kind == .backup }) else {
                throw DKTLiveSafetyRefusal("The inspected resource kinds do not match this mutation.")
            }
        case .caddyRouteMutation(let method, let path, let routeID, let body):
            try requireDemo(target)
            guard validTestName(routeID), !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#") else {
                throw DKTLiveSafetyRefusal("Only a named td-test-* Caddy route may be changed.")
            }
            if method == "DELETE" {
                guard path == "/id/" + routeID, body == nil else {
                    throw DKTLiveSafetyRefusal("Remove Caddy test routes by their own id only.")
                }
            } else if method == "POST" || method == "PUT" || method == "PATCH" {
                let parts = path.split(separator: "/")
                let appending = method == "POST" && parts.count == 6
                    && parts.prefix(4).map(String.init) == ["config", "apps", "http", "servers"] && parts[5] == "routes"
                let insertingOwnRoute = method == "PUT" && parts.count == 7
                    && parts.prefix(4).map(String.init) == ["config", "apps", "http", "servers"]
                    && parts[5] == "routes" && parts[6] == "0"
                let updatingOwnRoute = method == "PATCH" && path == "/id/" + routeID
                guard appending || insertingOwnRoute || updatingOwnRoute, let body,
                      let route = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      route["@id"] as? String == routeID else {
                    throw DKTLiveSafetyRefusal("Append exactly one Caddy route with its own td-test-* id; whole-config replacement is refused.")
                }
                let matches = route["match"] as? [[String: Any]] ?? []
                let hosts = matches.flatMap { $0["host"] as? [String] ?? [] }
                guard !matches.isEmpty, matches.allSatisfy({ !($0["host"] as? [String] ?? []).isEmpty }),
                      !hosts.isEmpty, hosts.allSatisfy({ host in
                          let suffix = ".178-105-239-176.sslip.io"
                          return host.hasSuffix(suffix) && validTestName(String(host.dropLast(suffix.count)))
                      }),
                      !hosts.contains(protectedHostname) else {
                    throw DKTLiveSafetyRefusal("Caddy test routes must use the approved td-test-* demo addresses.")
                }
                guard caddyIDs(route) == [routeID], let handlers = route["handle"] as? [[String: Any]], handlers.count == 1,
                      handlers[0]["handler"] as? String == "reverse_proxy",
                      let upstreams = handlers[0]["upstreams"] as? [[String: Any]], upstreams.count == 1,
                      let dial = upstreams[0]["dial"] as? String, privateAppDial(dial) else {
                    throw DKTLiveSafetyRefusal("Only a simple test-app proxy to a private app port is allowed; nested ids and other handlers are refused.")
                }
            } else {
                throw DKTLiveSafetyRefusal("Caddy live checks may append, update by id or remove their own route only; whole-config load and replacement are refused.")
            }
        case .filesystemMutation(let paths):
            try requireDemo(target)
            guard !paths.isEmpty, paths.allSatisfy(validTestPath) else {
                throw DKTLiveSafetyRefusal("Only td-test-* server folders in the approved test roots may be changed.")
            }
        }
    }

    static func perform<T: Sendable>(target: DKTLiveTarget, operation: DKTLiveOperation,
                                    resolvePaths: (@Sendable ([String]) async throws -> [String])? = nil,
                                    transport: @Sendable () async throws -> T) async throws -> T {
        try authorize(target: target, operation: operation) // Refuse before the callback can contact a server.
        if case .filesystemMutation(let paths) = operation {
            guard let resolvePaths else { throw DKTLiveSafetyRefusal("The live file adapter must verify no symlink ancestor before any write.") }
            let resolved = try await resolvePaths(paths)
            guard resolved == paths, resolved.allSatisfy(validTestPath) else {
                throw DKTLiveSafetyRefusal("A test folder resolved through a symlink or outside its approved path; the write was refused.")
            }
        }
        try Task.checkCancellation()
        return try await transport()
    }

    static func validTestName(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.count > prefix.count && name.count <= 160
            && name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$"#, options: .regularExpression) != nil
    }
    static func validTestPath(_ path: String) -> Bool {
        guard !path.contains(".."), !path.contains("//"), !path.contains("\\"), !path.contains("\0") else { return false }
        let roots = ["/tmp/", "/var/lib/terminaldeck/apps/", "/var/lib/terminaldeck/", "/var/lib/", "/etc/systemd/system/"]
        for root in roots where path.hasPrefix(root) {
            let remainder = String(path.dropFirst(root.count))
            guard let directory = remainder.split(separator: "/").first, validTestName(String(directory)),
                  path.range(of: #"^[A-Za-z0-9/_.:-]+$"#, options: .regularExpression) != nil else { continue }
            return true
        }
        return false
    }
    private static func requireDemo(_ target: DKTLiveTarget) throws {
        guard target == .demo else { throw DKTLiveSafetyRefusal("terminaldeck-store is read-only. The harness refuses this write before server I/O.") }
    }
    private static func caddyIDs(_ value: Any) -> [String] {
        if let object = value as? [String: Any] {
            let own = (object["@id"] as? String).map { [$0] } ?? []
            return own + object.filter { $0.key != "@id" }.values.flatMap(caddyIDs)
        }
        if let values = value as? [Any] { return values.flatMap(caddyIDs) }
        return []
    }
    private static func privateAppDial(_ dial: String) -> Bool {
        let parts = dial.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), ![2019, 2375, 2376].contains(port) else { return false }
        let rawOctets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard rawOctets.count == 4, rawOctets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        let octets = rawOctets.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 172 && (16...31).contains(octets[1]) || octets[0] == 192 && octets[1] == 168
    }
}

/// Public resource identity only. Never put inspect/env/config bodies in LIVE-LOG.
struct DKTLiveInventory: Equatable, Codable, Sendable {
    let resources: [DKTLiveResourceProof]
    let protectedCaddySHA256: String
    init(resources: [DKTLiveResourceProof], caddyConfig: Data) throws {
        let config = try JSONSerialization.jsonObject(with: caddyConfig)
        let canonical = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .fragmentsAllowed])
        protectedCaddySHA256 = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        self.resources = resources.sorted { ($0.kind.rawValue, $0.name, $0.id) < ($1.kind.rawValue, $1.name, $1.id) }
        guard Set(self.resources).count == self.resources.count else { throw DKTLiveSafetyRefusal("The live inventory contains duplicate resource identities.") }
    }
    func cleanupProof(after: Self) throws -> DKTLiveCleanupProof {
        let beforeSet = Set(resources), afterSet = Set(after.resources)
        guard beforeSet == afterSet, protectedCaddySHA256 == after.protectedCaddySHA256 else {
            throw DKTLiveSafetyRefusal("Cleanup proof failed: before/after resource lists or the existing Caddy configuration differ. Stop; do not remove unowned resources.")
        }
        return DKTLiveCleanupProof(before: resources, after: after.resources, caddySHA256: protectedCaddySHA256)
    }
}

struct DKTLiveCleanupProof: Codable, Sendable {
    let before: [DKTLiveResourceProof]
    let after: [DKTLiveResourceProof]
    let caddySHA256: String
    var listBeforeEqualsListAfter: Bool { before == after }
}

struct DKTFakeSuiteEvidence: Codable, Sendable {
    static let requiredSuites: Set<String> = ["DKTHTTPServerTests", "DKTDockerContractTests", "DKTDockerSafetyTests", "DKTDockerServerApprovalTests", "DKTAppsMCPSafetyTests",
        "DKTAppsDataContractTests", "DKTCaddyFixtureTests", "DKTCaddyAppsContractTests", "DKTCaddyAppsBackupLogTests",
        "DKTLiveSafetyHarnessTests", "DKTLiveInventoryCollectorTests"]
    let runner: String
    let completedAt: Date
    let passed: Int
    let failed: Int
    let skipped: Int
    let suites: Set<String>
    let logPath: String
    func validate(now: Date = Date()) throws {
        guard runner == "DKA", passed > 0, failed == 0, skipped == 0, Self.requiredSuites.isSubset(of: suites),
              now.timeIntervalSince(completedAt) >= 0, now.timeIntervalSince(completedAt) <= 3600, !logPath.isEmpty else {
            throw DKTLiveSafetyRefusal("A fresh DKA result with all required fake/contract/MCP/guard suites passing and none failed/skipped is required before live access.")
        }
    }
}

struct DKTLiveRunRecord: Codable, Sendable {
    let time: Date
    let target: DKTLiveTarget
    let whatRan: [String]
    let before: DKTLiveInventory?
    let after: DKTLiveInventory?
    let cleanupPassed: Bool
    let outcome: String
    var markdown: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Only public resource identities and config hashes are serialized.
        let json = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "\n## " + ISO8601DateFormatter().string(from: time) + " — " + target.rawValue + "\n\n```json\n" + json + "\n```\n"
    }
}

/// DKA wraps each full live run here, including failed bodies. Cleanup is always
/// attempted; before/after proof and the run record precede success or failure.
enum DKTLiveRunHarness {
    static func run<T: Sendable>(target: DKTLiveTarget, evidence: DKTFakeSuiteEvidence,
                                inventory: @escaping @Sendable () async throws -> DKTLiveInventory,
                                resolvePaths: (@Sendable ([String]) async throws -> [String])? = nil,
                                body: @Sendable (DKTLiveRunSession) async throws -> T,
                                cleanup: @escaping @Sendable (DKTLiveRunSession) async throws -> Void,
                                record: @escaping @Sendable (DKTLiveRunRecord) async throws -> Void) async throws -> T {
        try evidence.validate()
        let before: DKTLiveInventory
        do { before = try await inventory() }
        catch {
            let entry = DKTLiveRunRecord(time: Date(), target: target, whatRan: ["baseline inventory read"],
                before: nil, after: nil, cleanupPassed: false, outcome: "baseline-unavailable")
            try await Task.detached { try await record(entry) }.value
            throw DKTLiveSafetyRefusal("The live baseline inventory is unavailable; no test mutation was attempted. See LIVE-LOG.")
        }
        let session = DKTLiveRunSession(target: target, resolvePaths: resolvePaths)
        let result: Swift.Result<T, Error>
        do { result = .success(try await body(session)) }
        catch { result = .failure(error) }
        var cleanupFailed = false
        // Cleanup and the final read must still run after body cancellation.
        do { try await Task.detached { try await cleanup(session) }.value } catch { cleanupFailed = true }
        let after = try? await Task.detached { try await inventory() }.value
        let proof = after.flatMap { try? before.cleanupProof(after: $0) }
        let cleanupPassed = !cleanupFailed && proof != nil
        let bodyPassed: Bool
        switch result { case .success: bodyPassed = true; case .failure: bodyPassed = false }
        let entry = DKTLiveRunRecord(time: Date(), target: target, whatRan: await session.actions,
                                     before: before, after: after, cleanupPassed: cleanupPassed,
                                     outcome: !cleanupPassed ? "cleanup-proof-failed" : bodyPassed ? "passed" : "test-failed")
        try await Task.detached { try await record(entry) }.value
        guard cleanupPassed else { throw DKTLiveSafetyRefusal("Live cleanup did not prove before list = after list and unchanged existing Caddy config. See LIVE-LOG; stop live work.") }
        return try result.get()
    }
}

actor DKTLiveRunSession {
    let target: DKTLiveTarget
    private let resolvePaths: (@Sendable ([String]) async throws -> [String])?
    private(set) var actions: [String] = []
    init(target: DKTLiveTarget, resolvePaths: (@Sendable ([String]) async throws -> [String])? = nil) {
        self.target = target
        self.resolvePaths = resolvePaths
    }
    func perform<T: Sendable>(_ operation: DKTLiveOperation, transport: @Sendable () async throws -> T) async throws -> T {
        try DKTLiveSafetyHarness.authorize(target: target, operation: operation)
        let description: String
        switch operation {
        case .read(let channel): description = channel
        case .mutation(let channel, let resources): description = channel + " " + resources.map(\.name).sorted().joined(separator: ",")
        case .caddyRouteMutation(let method, _, let routeID, _): description = "caddy " + method + " " + routeID
        case .filesystemMutation(let paths): description = "test folders " + paths.sorted().joined(separator: ",")
        }
        actions.append(description)
        try Task.checkCancellation()
        return try await DKTLiveSafetyHarness.perform(target: target, operation: operation, resolvePaths: resolvePaths, transport: transport)
    }
}
