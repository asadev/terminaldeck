import Foundation
import TerminalDeckNativeCore

/// APD's database implementation. The channel service must authorize writes before calling it.
/// Reuses APE's version/volume specification and protected server store; owns no Mac process.
public struct BackendAppsDataDatabases: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) {
        self.runtime = runtime; self.store = store
    }

    public func create(serverID: String, appID: String, name: String, kind: String, version: String?) async throws -> NativeRPCValue {
        try Self.validateRuntime(runtime)
        try Self.validateIdentity(runtime: runtime, serverID: serverID, appID: appID)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 120,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeRPCError.invalidArguments("Give the database a short name without control characters.")
        }
        if let version, version.range(of: #"\A[0-9]{1,2}(?:\.[0-9]{1,2}){0,2}(?:-alpine)?\z"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("Choose a numeric database version without control characters.")
        }
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: version)
        let runtime = self.runtime, store = self.store
        return try await store.withLock(serverID, appID) {
            let transaction = BackendAppsRecoveryContext.current
            if let recovery = runtime.recovery {
                guard let transaction, transaction.belongs(to: recovery), transaction.scope.serverID == serverID,
                      transaction.scope.appID == appID, transaction.scope.stateRoot == runtime.stateRoot,
                      transaction.scope.resourcePrefix == runtime.resourcePrefix, transaction.scope.privateNetwork == runtime.privateNetwork else {
                    throw NativeRPCError(code: "access-denied", message: "Database setup has no matching approved recovery transaction.")
                }
            }
            if try await store.readFile(serverID, path: store.directory(appID) + "/state.json") != nil {
                throw NativeRPCError(code: "conflict", message: "An app with that ID already exists. Its saved data was preserved.")
            }
            let volume = "\(runtime.resourcePrefix)-\(appID)-data"
            let serviceName = "\(runtime.resourcePrefix)-\(appID)"
            // Check collisions before changing anything. A volume-create response is verified again below,
            // because Engine volume creation is idempotent and another creator could win this race.
            try await Self.requireMissing(runtime, serverID, "/volumes/\(volume)", "A saved data space already uses that ID.")
            try await Self.requireMissing(runtime, serverID, "/containers/\(serviceName)/json", "A service already uses that ID.")
            let imageID = try await Self.resolveImage(runtime: runtime, serverID: serverID, spec: spec)
            let token = UUID().uuidString.lowercased()
            var labels = BackendAppsValidation.object([
                ("io.terminaldeck.app", .string(appID)), ("io.terminaldeck.managed", .string("true")),
                ("io.terminaldeck.provision", .string(token))
            ])
            if let transaction { labels = labels.setting("io.terminaldeck.transaction", .string(transaction.scope.ownerToken)) }
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let environment = spec.environment(password: password), now = runtime.now()
            var record = BackendAppsValidation.object([
                ("id", .string(appID)), ("name", .string(name)), ("kind", .string(kind)), ("status", .string("deploying")),
                ("address", .null), ("domains", .array([])), ("source", .null), ("activeDeploymentId", .null),
                ("createdAt", .number(now)), ("updatedAt", .number(now)),
                ("envKeys", .array(environment.keys.sorted().map(NativeRPCValue.string))),
                ("backupPolicy", BackendAppsValidation.object([("enabled", .bool(false))])),
                ("database", BackendAppsValidation.object([
                    ("kind", .string(kind)), ("image", .string(spec.image)), ("imageId", .string(imageID)),
                    ("volumeName", .string(volume)), ("dataPath", .string(spec.dataPath)),
                    ("network", .string(runtime.privateNetwork)), ("databaseName", .string("terminaldeck")),
                    ("port", .number(Double(spec.port))), ("provisionToken", .string(token)), ("provisionPhase", .string("planned"))
                ]))
            ])
            if let transaction { record = record.setting("database", record["database"].setting("transactionId", .string(transaction.scope.transactionID.uuidString))) }
            // Durable intent comes before creating saved data or a running service.
            // Store seals state/env before-images and the exact owned-lock release under this scope.
            // Provisioning deliberately never enrolls candidate deletion: a new database can contain data.
            try await store.write(serverID, appID, record)
            do {
                try await store.applyEnvironment(serverID, appID, environment)
                try await Self.ensureNetwork(runtime: runtime, serverID: serverID)
                let createdVolume = try await Self.request(runtime, serverID, "POST", "/volumes/create", body: BackendAppsValidation.object([
                    ("Name", .string(volume)), ("Driver", .string("local")), ("Labels", labels)
                ]))
                guard createdVolume.ok else { throw BackendAppsRuntime.unavailable("The database's saved data space could not be created.") }
                let volumeDetail = try await Self.readJSON(runtime, serverID, "/volumes/\(volume)")
                try Self.validateVolume(volumeDetail, appID: appID, volumeName: volume)
                guard volumeDetail["Labels"]["io.terminaldeck.provision"].string == token else {
                    throw NativeRPCError(code: "conflict", message: "Another action created that saved data space. It was preserved.")
                }
                record = record.setting("database", record["database"].setting("provisionPhase", .string("volume-created")))
                try await store.write(serverID, appID, record)
                let body = Self.container(spec: spec, appID: appID, volume: volume, environment: environment,
                                          labels: labels, network: runtime.privateNetwork, prefix: runtime.resourcePrefix).setting("Image", .string(imageID))
                let created = try await Self.request(runtime, serverID, "POST", "/containers/create?name=\(serviceName)", body: body)
                guard created.ok, let containerID = try Self.json(created)["Id"].string, Self.validContainerID(containerID) else {
                    throw BackendAppsRuntime.unavailable("The database service could not be created. Its saved data was preserved.")
                }
                record = record.setting("containerId", .string(containerID)).setting("database", record["database"].setting("containerId", .string(containerID)).setting("provisionPhase", .string("service-created")))
                try await store.write(serverID, appID, record)
                _ = try await Self.inspectOwned(runtime: runtime, serverID: serverID, appID: appID, containerID: containerID,
                                                volumeName: volume, expectedImageID: imageID, kind: kind)
                let start = try await Self.request(runtime, serverID, "POST", "/containers/\(containerID)/start")
                guard start.ok || start.status == 304 else { throw NativeRPCError(code: "health-failed", message: "The database could not start. Its saved data was preserved.") }
                try await Self.waitHealthy(runtime: runtime, serverID: serverID, appID: appID, containerID: containerID,
                                           volumeName: volume, expectedImageID: imageID, kind: kind)
                record = record.setting("status", .string("running")).setting("updatedAt", .number(runtime.now()))
                    .setting("database", record["database"].setting("provisionPhase", .string("ready")))
                try await store.write(serverID, appID, record)
                return BackendAppsStore.publicRecord(record)
            } catch {
                // Do not remove data, guess that cleanup worked, or replace a credential on retry.
                // Failed-state bytes still require the ordinary live write receipt. On cancellation/refusal,
                // keep the last durable deploying/setup journal; never restore its original absence or
                // consume a state before-image that would hide a created database or data volume.
                let failed = record.setting("status", .string("failed")).setting("updatedAt", .number(runtime.now()))
                let saved = await Task {
                    do { try await store.write(serverID, appID, failed); return true }
                    catch { return false }
                }.value
                if !saved {
                    throw NativeRPCError(code: "state-failed", message: "Database setup stopped and its saved state needs recovery. All saved data was preserved.")
                }
                if error is CancellationError { throw CancellationError() }
                if let known = error as? NativeRPCError { throw known }
                throw BackendAppsRuntime.unavailable("Database setup did not finish. Its saved data was preserved.")
            }
        }
    }

    /// Read-only connection help. This private address is reachable by apps on the server, not over the internet.
    public func connection(serverID: String, appID: String) async throws -> NativeRPCValue {
        try Self.validateRuntime(runtime)
        try Self.validateIdentity(runtime: runtime, serverID: serverID, appID: appID)
        let record = try await store.read(serverID, appID)
        return try Self.publicConnection(record, runtime: runtime)
    }

    public static func publicConnection(_ record: NativeRPCValue, runtime: BackendAppsRuntime) throws -> NativeRPCValue {
        try validateRuntime(runtime)
        let appID = try record["id"].requireString("Database ID", nonempty: true)
        try validateIdentity(runtime: runtime, serverID: "saved-server", appID: appID)
        let kind = try record["kind"].requireString("Database kind", nonempty: true)
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        guard record["database"]["kind"].string == kind, record["database"]["network"].string == runtime.privateNetwork,
              record["database"]["port"].number == Double(spec.port), record["database"]["databaseName"].string == "terminaldeck",
              record["status"].isNullish || ["stopped", "deploying", "running", "failed"].contains(record["status"].string ?? "") else {
            throw NativeRPCError(code: "state-failed", message: "The database's saved connection details need recovery.")
        }
        return BackendAppsValidation.object([
            ("kind", .string(kind)), ("host", .string("\(runtime.resourcePrefix)-\(appID)")), ("port", .number(Double(spec.port))),
            ("database", kind == "redis" ? .null : .string("terminaldeck")),
            ("username", .string(kind == "mysql" ? "root" : (kind == "redis" ? "default" : "terminaldeck"))),
            ("password", .string("••••••••")), ("passwordKey", .string(kind == "mongodb" ? "MONGO_INITDB_ROOT_PASSWORD" : (kind == "mysql" ? "MYSQL_ROOT_PASSWORD" : (kind == "redis" ? "REDIS_PASSWORD" : "POSTGRES_PASSWORD")))),
            ("scope", .string("private-network")),
            ("network", .string(runtime.privateNetwork)), ("status", record["status"]),
            ("authenticationDatabase", kind == "mongodb" ? .string("admin") : .null),
            ("instructions", .string("Use this private address from an app on the same server. The password stays protected in this database's settings."))
        ])
    }

    public static func validateRuntime(_ runtime: BackendAppsRuntime) throws {
        try BackendAppsDatabases.validateRuntime(runtime)
        guard runtime.resourcePrefix.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              runtime.privateNetwork.range(of: #"\A[a-z][a-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The database resource names are invalid.")
        }
        guard runtime.resourcePrefix != "td-test" || (runtime.privateNetwork.hasPrefix("td-test-") && runtime.stateRoot == "/var/lib/td-test-apps") else {
            throw NativeRPCError.invalidArguments("Test databases require their own private network and saved-state folder.")
        }
    }

    public static func validateRuntime(_ runtime: BackendAppsRuntime, appID: String) throws {
        try validateRuntime(runtime)
        try validateIdentity(runtime: runtime, serverID: "saved-server", appID: appID)
    }

    public static func ensureNetwork(runtime: BackendAppsRuntime, serverID: String) async throws {
        try validateRuntime(runtime)
        try validateServerID(serverID)
        let path = "/networks/\(runtime.privateNetwork)"
        let read = try await request(runtime, serverID, "GET", path)
        if read.ok { try validateNetwork(json(read), name: runtime.privateNetwork); return }
        guard read.status == 404 else { throw BackendAppsRuntime.unavailable("The database network could not be checked.") }
        let created = try await request(runtime, serverID, "POST", "/networks/create", body: BackendAppsValidation.object([
            ("Name", .string(runtime.privateNetwork)), ("Driver", .string("bridge")), ("CheckDuplicate", .bool(true)),
            ("Labels", BackendAppsValidation.object([("io.terminaldeck.managed", .string("true"))]))
        ]))
        guard created.ok || created.status == 409 else { throw BackendAppsRuntime.unavailable("The private database network could not be created.") }
        try validateNetwork(try await readJSON(runtime, serverID, path), name: runtime.privateNetwork)
    }

    /// Shared backup/restore preflight: the server record alone cannot grant ownership of Docker resources.
    public static func inspectOwned(runtime: BackendAppsRuntime, serverID: String, appID: String, containerID: String,
                                    volumeName: String, expectedImageID: String, kind: String) async throws -> NativeRPCValue {
        try validateRuntime(runtime)
        try validateIdentity(runtime: runtime, serverID: serverID, appID: appID)
        guard validContainerID(containerID), validImageID(expectedImageID),
              volumeName.hasPrefix(runtime.resourcePrefix + "-" + appID + "-"),
              volumeName.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,191}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "state-failed", message: "The saved database resource identities need recovery.")
        }
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: nil)
        let inspected = try await readJSON(runtime, serverID, "/containers/\(containerID)/json")
        let labels = inspected["Config"]["Labels"], host = inspected["HostConfig"]
        let mounts = inspected["Mounts"].elements ?? []
        let networks = inspected["NetworkSettings"]["Networks"].fields ?? []
        let expectedMounts = mounts.filter { $0["Type"].string == "volume" && $0["Name"].string == volumeName && $0["Destination"].string == spec.dataPath && $0["RW"].bool == true }
        let extraMounts = mounts.filter { !($0["Type"].string == "volume" && $0["Name"].string == volumeName && $0["Destination"].string == spec.dataPath && $0["RW"].bool == true) }
        guard inspected["Id"].string == containerID, inspected["Image"].string == expectedImageID,
              labels["io.terminaldeck.app"].string == appID, labels["io.terminaldeck.managed"].string == "true",
              expectedMounts.count == 1, extraMounts.allSatisfy({ kind == "mongodb" && $0["Type"].string == "tmpfs" && $0["Destination"].string == "/data/configdb" }),
              host["NetworkMode"].string == runtime.privateNetwork, networks.count == 1, networks.first?.key == runtime.privateNetwork,
              host["Privileged"].bool == false, host["PublishAllPorts"].bool == false,
              empty(host["PortBindings"]), empty(inspected["NetworkSettings"]["Ports"]), empty(host["Binds"]),
              empty(host["Devices"]), empty(host["DeviceRequests"]), empty(host["VolumesFrom"]), empty(host["CapAdd"]),
              !["host"].contains(host["PidMode"].string ?? ""), !["host"].contains(host["IpcMode"].string ?? ""),
              !(host["PidMode"].string ?? "").hasPrefix("container:"), !(host["IpcMode"].string ?? "").hasPrefix("container:"),
              !["host"].contains(host["UTSMode"].string ?? ""), !["host"].contains(host["UsernsMode"].string ?? ""),
              (host["SecurityOpt"].elements ?? []).allSatisfy({ !($0.string ?? "").contains("unconfined") }) else {
            throw NativeRPCError(code: "conflict", message: "The database service does not match this app's protected saved data and private network. No service was changed.")
        }
        try validateVolume(try await readJSON(runtime, serverID, "/volumes/\(volumeName)"), appID: appID, volumeName: volumeName)
        return inspected
    }

    public static func waitHealthy(runtime: BackendAppsRuntime, serverID: String, appID: String, containerID: String,
                                   volumeName: String, expectedImageID: String, kind: String,
                                   attempts: Int = 90, delayNanoseconds: UInt64 = 1_000_000_000) async throws {
        guard (1...90).contains(attempts), delayNanoseconds <= 1_000_000_000 else {
            throw NativeRPCError.invalidArguments("The database startup check limit is invalid.")
        }
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let detail = try await inspectOwned(runtime: runtime, serverID: serverID, appID: appID, containerID: containerID,
                                                volumeName: volumeName, expectedImageID: expectedImageID, kind: kind)
            let state = detail["State"], test = detail["Config"]["Healthcheck"]["Test"].elements
            guard test == [.string("CMD-SHELL"), .string(try authenticatedHealthcheck(kind: kind))] else {
                throw NativeRPCError(code: "health-failed", message: "The database has no trusted sign-in check. Its saved data was preserved.")
            }
            if state["Running"].bool == true, state["Health"]["Status"].string == "healthy" { return }
            guard state["Running"].bool == true, state["Restarting"].bool != true,
                  state["Health"]["Status"].string == "starting" else {
                throw NativeRPCError(code: "health-failed", message: "The database did not pass its startup sign-in check. Its saved data was preserved.")
            }
            if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
        }
        throw NativeRPCError(code: "health-failed", message: "The database took too long to become ready. Its saved data was preserved.")
    }

    /// For database create and recovery candidates: credentials are read from environment, never command arguments.
    public static func container(spec: BackendAppsDatabaseSpec, appID: String, volume: String, environment: [String: String],
                                 labels: NativeRPCValue, network: String, prefix: String, alias: Bool = true) -> NativeRPCValue {
        let body = spec.container(appID: appID, volume: volume, environment: environment, labels: labels, network: network, prefix: prefix, alias: alias)
        // spec.kind was validated by the existing initializer; this switch is exhaustive for those four kinds.
        let health = (try? authenticatedHealthcheck(kind: spec.kind)) ?? "exit 1"
        return body.setting("Healthcheck", body["Healthcheck"].setting("Test", .array([.string("CMD-SHELL"), .string(health)])))
    }

    public static func authenticatedHealthcheck(kind: String) throws -> String {
        switch kind {
        case "postgres": return #"export PGPASSWORD="$POSTGRES_PASSWORD"; test "$(psql --host=127.0.0.1 --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --no-password --no-psqlrc --tuples-only --no-align --command='SELECT 1' 2>/dev/null)" = 1"#
        case "mysql": return #"export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; test "$(mysql --protocol=TCP --host=127.0.0.1 --user=root --database="$MYSQL_DATABASE" --batch --skip-column-names --execute='SELECT 1' 2>/dev/null)" = 1"#
        case "redis": return #"export REDISCLI_AUTH="$REDIS_PASSWORD"; test "$(redis-cli --host 127.0.0.1 ping 2>/dev/null)" = PONG"#
        case "mongodb": return #"mongosh --host 127.0.0.1 --quiet --eval 'const a=process.env; const r=db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD); if(!(r===1||(r&&r.ok===1))) quit(1); if(!db.adminCommand({ping:1}).ok) quit(1)' >/dev/null 2>&1"#
        default: throw NativeRPCError.invalidArguments("Choose Postgres, MySQL, Redis or MongoDB.")
        }
    }

    private static func validateIdentity(runtime: BackendAppsRuntime, serverID: String, appID: String) throws {
        try validateServerID(serverID)
        _ = try BackendAppsValidation.id(appID)
        guard appID.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The database ID must contain only lowercase letters, numbers and dashes.")
        }
        guard runtime.resourcePrefix != "td-test" || appID.hasPrefix("td-test-") else {
            throw NativeRPCError.invalidArguments("Choose a saved server and an app ID in the permitted namespace.")
        }
    }
    private static func validateServerID(_ serverID: String) throws {
        guard !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, serverID.utf8.count <= 256,
              !serverID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeRPCError.invalidArguments("Choose a saved server without control characters.")
        }
    }
    private static func validateNetwork(_ detail: NativeRPCValue, name: String) throws {
        guard detail["Name"].string == name, detail["Driver"].string == "bridge", detail["Ingress"].bool != true,
              detail["Labels"]["io.terminaldeck.managed"].string == "true" else {
            throw NativeRPCError(code: "conflict", message: "The private app network name belongs to a different network. It was preserved.")
        }
    }
    private static func validateVolume(_ detail: NativeRPCValue, appID: String, volumeName: String) throws {
        guard detail["Name"].string == volumeName, detail["Driver"].string == "local",
              detail["Labels"]["io.terminaldeck.app"].string == appID,
              detail["Labels"]["io.terminaldeck.managed"].string == "true", empty(detail["Options"]) else {
            throw NativeRPCError(code: "conflict", message: "The saved data space is not owned by this database. It was preserved.")
        }
    }
    private static func empty(_ value: NativeRPCValue) -> Bool {
        if value.isNullish { return true }
        if let elements = value.elements { return elements.isEmpty }
        if let fields = value.fields { return fields.allSatisfy { $0.value.isNullish || $0.value.elements?.isEmpty == true } }
        return false
    }
    private static func validContainerID(_ id: String) -> Bool { id.range(of: #"\A[a-f0-9]{12,64}\z"#, options: .regularExpression) != nil }
    private static func validImageID(_ id: String) -> Bool { id.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil }
    private static func requireMissing(_ runtime: BackendAppsRuntime, _ serverID: String, _ path: String, _ message: String) async throws {
        let response = try await request(runtime, serverID, "GET", path)
        if response.ok { throw NativeRPCError(code: "conflict", message: message + " Choose a new database ID to preserve it.") }
        guard response.status == 404 else { throw BackendAppsRuntime.unavailable("Existing database resources could not be checked. No database was changed.") }
    }
    private static func resolveImage(runtime: BackendAppsRuntime, serverID: String, spec: BackendAppsDatabaseSpec) async throws -> String {
        var response = try await request(runtime, serverID, "GET", "/images/\(spec.image)/json")
        if response.status == 404 {
            guard runtime.resourcePrefix != "td-test" else {
                throw BackendAppsRuntime.unavailable("The test server needs a preapproved database image. No upstream image was downloaded.")
            }
            let pull = try await request(runtime, serverID, "POST", "/images/create?fromImage=\(spec.repository)&tag=\(spec.version)")
            guard pull.ok else { throw BackendAppsRuntime.unavailable("The database software could not be downloaded.") }
            response = try await request(runtime, serverID, "GET", "/images/\(spec.image)/json")
        }
        guard response.ok, let imageID = try json(response)["Id"].string, validImageID(imageID) else {
            throw BackendAppsRuntime.unavailable("The database software's exact identity could not be verified.")
        }
        return imageID
    }
    private static func request(_ runtime: BackendAppsRuntime, _ serverID: String, _ method: String, _ path: String, body: NativeRPCValue? = nil) async throws -> BackendAppsHTTPResponse {
        try Task.checkCancellation()
        do { return try await runtime.docker(serverID, method, path, body.map { try $0.encodedJSON() }) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendAppsRuntime.unavailable("The database connection did not complete this action. Check the server connection.") }
    }
    private static func json(_ response: BackendAppsHTTPResponse) throws -> NativeRPCValue {
        guard response.body.count <= 4_194_304 else { throw BackendAppsRuntime.unavailable("The database service returned too much information.") }
        do { return try response.value() }
        catch { throw BackendAppsRuntime.unavailable("The database service returned an unreadable response.") }
    }
    private static func readJSON(_ runtime: BackendAppsRuntime, _ serverID: String, _ path: String) async throws -> NativeRPCValue {
        let response = try await request(runtime, serverID, "GET", path)
        guard response.ok else { throw BackendAppsRuntime.unavailable("The database's saved resources could not be verified.") }
        return try json(response)
    }
}
