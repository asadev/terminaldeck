import Foundation
import TerminalDeckNativeCore

/// Captured by the recovery kernel while the original receipt is live. Probe
/// text references the existing service environment; no credential is copied.
struct BackendAppsRecoveryDatabaseBaseline: Sendable {
    let originalID: String
    let kind: String
    let imageID: String
    let running: Bool
    let connected: Bool
    let aliases: [String]
    let authenticatedHealthTest: [String]
    let originalVolume: String
    let dataPath: String
}

enum BackendAppsRecoveryDatabase {
    typealias Docker = @Sendable (_ method: String, _ path: String, _ body: Data?) async throws -> BackendAppsHTTPResponse
    private struct State: Sendable {
        let id: String
        let running: Bool
        let connected: Bool
        let aliases: [String]
    }

    static func capture(scope: BackendAppsRecoveryScope, originalID: String, record: NativeRPCValue,
                        original: NativeRPCValue) throws -> BackendAppsRecoveryDatabaseBaseline {
        let kind = record["kind"].string ?? ""
        guard ["postgres", "mysql", "redis", "mongodb"].contains(kind), validID(originalID),
              record["id"].string == scope.appID, record["containerId"].string == originalID,
              record["database"]["containerId"].string == originalID, record["database"]["kind"].string == kind,
              record["database"]["network"].string == scope.privateNetwork,
              let imageID = record["database"]["imageId"].string, validImage(imageID),
              original["Id"].string == originalID, original["Image"].string == imageID, owns(original, scope: scope),
              original["Config"]["Labels"]["io.terminaldeck.transaction"].string != scope.ownerToken,
              let running = original["State"]["Running"].bool else { throw invalidBaseline() }
        let test = ["CMD-SHELL", try BackendAppsDataDatabases.authenticatedHealthcheck(kind: kind)]
        guard original["Config"]["Healthcheck"]["Test"].elements == test.map(NativeRPCValue.string) else { throw invalidBaseline() }
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        guard let volume = record["database"]["volumeName"].string, validVolume(volume),
              record["database"]["dataPath"].string == spec.dataPath,
              try dataVolume(original, dataPath: spec.dataPath, kind: kind) == volume else { throw invalidBaseline() }
        let network = original["NetworkSettings"]["Networks"][scope.privateNetwork]
        let aliases = try checkedAliases(network)
        return .init(originalID: originalID, kind: kind, imageID: imageID, running: running,
                     connected: !network.isNullish, aliases: aliases, authenticatedHealthTest: test, originalVolume: volume, dataPath: spec.dataPath)
    }

    /// The parent holds the owned app lock and supplies only its pinned,
    /// expiring private transport. This function never removes saved data.
    static func recover(scope: BackendAppsRecoveryScope, baseline: BackendAppsRecoveryDatabaseBaseline,
                        docker: @escaping Docker, healthAttempts: Int = 90, healthDelayNanoseconds: UInt64 = 1_000_000_000) async throws -> Bool {
        guard validID(baseline.originalID), validImage(baseline.imageID), baseline.running, baseline.connected,
              (1...90).contains(healthAttempts), healthDelayNanoseconds <= 1_000_000_000,
              baseline.authenticatedHealthTest == ["CMD-SHELL", try BackendAppsDataDatabases.authenticatedHealthcheck(kind: baseline.kind)] else { return false }
        let candidate: State?
        var originalTouched = false
        do {
            // Reject a changed/foreign data mount before quiescing the fallback.
            _ = try await inspect(baseline.originalID, scope: scope, baseline: baseline, candidate: false, docker: docker)
            let filters = BackendAppsValidation.object([("label", .array([
                .string("io.terminaldeck.app=" + scope.appID), .string("io.terminaldeck.managed=true"),
                .string("io.terminaldeck.transaction=" + scope.ownerToken)
            ]))]).compact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let listed = try await docker("GET", "/containers/json?all=true&filters=" + filters, nil)
            guard listed.ok, let rows = try listed.value().elements, rows.count <= 1 else { return false }
            if let row = rows.first {
                guard let id = row["Id"].string, validID(id), id != baseline.originalID,
                      row["Labels"]["io.terminaldeck.app"].string == scope.appID,
                      row["Labels"]["io.terminaldeck.managed"].string == "true",
                      row["Labels"]["io.terminaldeck.transaction"].string == scope.ownerToken else { return false }
                let detail = try await inspect(id, scope: scope, baseline: baseline, candidate: true, docker: docker)
                let captured = try state(detail, scope: scope)
                candidate = captured
                // Preserve a viable candidate exactly. A running service with
                // an untrusted/unhealthy probe cannot be a fallback baseline.
                if captured.running, (!captured.connected || detail["State"]["Restarting"].bool == true || detail["State"]["Health"]["Status"].string != "healthy") { return false }
            } else { candidate = nil }
        } catch { return false }
        do {
            if let candidate {
                if candidate.running { try await setRunning(candidate.id, running: false, scope: scope, baseline: baseline, candidate: true, docker: docker) }
                if candidate.connected { try await detach(candidate.id, scope: scope, baseline: baseline, candidate: true, docker: docker) }
            }
            originalTouched = true
            try await setNetwork(baseline.originalID, connected: baseline.connected, aliases: baseline.aliases,
                                 scope: scope, baseline: baseline, candidate: false, docker: docker)
            try await setRunning(baseline.originalID, running: baseline.running, scope: scope, baseline: baseline, candidate: false, docker: docker)
            try await healthy(baseline.originalID, aliases: baseline.aliases, scope: scope, baseline: baseline,
                              candidate: false, docker: docker, attempts: healthAttempts, delay: healthDelayNanoseconds)
            return true
        } catch {
            if let candidate {
                // An accepted request can lose its response. Inspect and apply
                // only the candidate's captured state, with positive checks.
                // Quiesce a partially revived original to avoid sharing aliases.
                if originalTouched {
                    // Lost responses are ambiguous: reinspection below can
                    // prove completion, but acknowledgements alone never can.
                    _ = try? await setRunning(baseline.originalID, running: false, scope: scope, baseline: baseline, candidate: false, docker: docker)
                    _ = try? await detach(baseline.originalID, scope: scope, baseline: baseline, candidate: false, docker: docker)
                    guard let detail = try? await inspect(baseline.originalID, scope: scope, baseline: baseline, candidate: false, docker: docker),
                          let checked = try? state(detail, scope: scope), !checked.running, !checked.connected else { return false }
                }
                do {
                    try await setNetwork(candidate.id, connected: candidate.connected, aliases: candidate.aliases,
                                         scope: scope, baseline: baseline, candidate: true, docker: docker)
                    try await setRunning(candidate.id, running: candidate.running, scope: scope, baseline: baseline, candidate: true, docker: docker)
                    if candidate.running {
                        try await healthy(candidate.id, aliases: candidate.aliases, scope: scope, baseline: baseline,
                                          candidate: true, docker: docker, attempts: healthAttempts, delay: healthDelayNanoseconds)
                    }
                    let restored = try state(await inspect(candidate.id, scope: scope, baseline: baseline, candidate: true, docker: docker), scope: scope)
                    guard restored.running == candidate.running, restored.connected == candidate.connected,
                          Set(restored.aliases) == Set(candidate.aliases) else { return false }
                } catch { return false }
            }
            return false
        }
    }

    private static func inspect(_ id: String, scope: BackendAppsRecoveryScope, baseline: BackendAppsRecoveryDatabaseBaseline,
                                candidate: Bool, docker: Docker) async throws -> NativeRPCValue {
        let response = try await docker("GET", "/containers/\(id)/json", nil)
        guard response.ok else { throw failed() }
        let value = try response.value()
        guard value["Id"].string == id, value["Image"].string == baseline.imageID, owns(value, scope: scope),
              value["Config"]["Healthcheck"]["Test"].elements == baseline.authenticatedHealthTest.map(NativeRPCValue.string),
              candidate || value["Config"]["Labels"]["io.terminaldeck.transaction"].string != scope.ownerToken,
              !candidate || value["Config"]["Labels"]["io.terminaldeck.transaction"].string == scope.ownerToken else { throw failed() }
        let volume = try dataVolume(value, dataPath: baseline.dataPath, kind: baseline.kind)
        guard candidate ? volume != baseline.originalVolume : volume == baseline.originalVolume else { throw failed() }
        let saved = try await docker("GET", "/volumes/\(volume)", nil)
        guard saved.ok else { throw failed() }
        let storage = try saved.value()
        guard storage["Name"].string == volume, storage["Driver"].string == "local",
              storage["Labels"]["io.terminaldeck.app"].string == scope.appID,
              storage["Labels"]["io.terminaldeck.managed"].string == "true",
              storage["Options"].isNullish || storage["Options"].fields?.isEmpty == true,
              !candidate || storage["Labels"]["io.terminaldeck.transaction"].string == scope.ownerToken else { throw failed() }
        return value
    }
    private static func state(_ value: NativeRPCValue, scope: BackendAppsRecoveryScope) throws -> State {
        guard let id = value["Id"].string, validID(id), let running = value["State"]["Running"].bool else { throw failed() }
        let network = value["NetworkSettings"]["Networks"][scope.privateNetwork]
        return .init(id: id, running: running, connected: !network.isNullish, aliases: try checkedAliases(network))
    }
    private static func setRunning(_ id: String, running: Bool, scope: BackendAppsRecoveryScope,
                                   baseline: BackendAppsRecoveryDatabaseBaseline, candidate: Bool, docker: Docker) async throws {
        let current = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
        if current["State"]["Running"].bool != running {
            let response = try await docker("POST", "/containers/\(id)/" + (running ? "start" : "stop?t=10"), nil)
            guard response.ok || response.status == 304 else { throw failed() }
        }
        let checked = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
        guard checked["State"]["Running"].bool == running else { throw failed() }
    }
    private static func detach(_ id: String, scope: BackendAppsRecoveryScope, baseline: BackendAppsRecoveryDatabaseBaseline,
                               candidate: Bool, docker: Docker) async throws {
        let current = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
        if !current["NetworkSettings"]["Networks"][scope.privateNetwork].isNullish {
            let body = try BackendAppsValidation.object([("Container", .string(id)), ("Force", .bool(true))]).encodedJSON()
            guard try await docker("POST", "/networks/\(scope.privateNetwork)/disconnect", body).ok else { throw failed() }
        }
        let checked = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
        guard checked["NetworkSettings"]["Networks"][scope.privateNetwork].isNullish else { throw failed() }
    }
    private static func setNetwork(_ id: String, connected: Bool, aliases: [String], scope: BackendAppsRecoveryScope,
                                   baseline: BackendAppsRecoveryDatabaseBaseline, candidate: Bool, docker: Docker) async throws {
        let current = try state(await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker), scope: scope)
        if current.connected && (!connected || Set(current.aliases) != Set(aliases)) {
            try await detach(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
        }
        if connected {
            let checked = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
            if checked["NetworkSettings"]["Networks"][scope.privateNetwork].isNullish {
                let body = try BackendAppsValidation.object([("Container", .string(id)), ("EndpointConfig", BackendAppsValidation.object([("Aliases", .array(aliases.map(NativeRPCValue.string)))]))]).encodedJSON()
                guard try await docker("POST", "/networks/\(scope.privateNetwork)/connect", body).ok else { throw failed() }
            }
        }
        let checked = try state(await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker), scope: scope)
        guard checked.connected == connected, Set(checked.aliases) == Set(aliases) else { throw failed() }
    }
    private static func healthy(_ id: String, aliases: [String], scope: BackendAppsRecoveryScope,
                                baseline: BackendAppsRecoveryDatabaseBaseline, candidate: Bool, docker: Docker,
                                attempts: Int, delay: UInt64) async throws {
        for attempt in 0..<attempts {
            let detail = try await inspect(id, scope: scope, baseline: baseline, candidate: candidate, docker: docker)
            let status = detail["State"]["Health"]["Status"].string
            let current = try state(detail, scope: scope)
            guard current.running, current.connected, Set(current.aliases) == Set(aliases), detail["State"]["Restarting"].bool != true else { throw failed() }
            if status == "healthy" { return }
            guard status == "starting" else { throw failed() }
            if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delay) }
        }
        throw failed()
    }
    private static func checkedAliases(_ network: NativeRPCValue) throws -> [String] {
        if network.isNullish { return [] }
        guard let values = network["Aliases"].elements, values.count <= 32 else { throw invalidBaseline() }
        let aliases = try values.map { try $0.requireString("Private database address", nonempty: true) }
        guard Set(aliases).count == aliases.count, aliases.allSatisfy({ $0.utf8.count <= 253 && $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { throw invalidBaseline() }
        return aliases
    }
    private static func owns(_ value: NativeRPCValue, scope: BackendAppsRecoveryScope) -> Bool {
        value["Config"]["Labels"]["io.terminaldeck.app"].string == scope.appID && value["Config"]["Labels"]["io.terminaldeck.managed"].string == "true"
    }
    private static func validID(_ id: String) -> Bool { id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    private static func validImage(_ id: String) -> Bool { id.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    private static func validVolume(_ name: String) -> Bool { name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,191}$"#, options: .regularExpression) != nil }
    private static func dataVolume(_ value: NativeRPCValue, dataPath: String, kind: String) throws -> String {
        guard let mounts = value["Mounts"].elements else { throw invalidBaseline() }
        let data = mounts.filter { $0["Type"].string == "volume" && $0["Destination"].string == dataPath && $0["RW"].bool == true }
        guard data.count == 1, let name = data[0]["Name"].string, validVolume(name), mounts.allSatisfy({ mount in
            mount == data[0] || kind == "mongodb" && mount["Type"].string == "tmpfs" && mount["Destination"].string == "/data/configdb"
        }) else { throw invalidBaseline() }
        return name
    }
    private static func invalidBaseline() -> NativeRPCError { .init(code: "access-denied", message: "The original database's owned identity or authenticated check could not be captured.") }
    private static func failed() -> NativeRPCError { .init(code: "restore-failed", message: "The database's captured recovery state could not be verified. Both saved data versions were preserved.") }
}
