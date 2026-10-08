import Foundation
import TerminalDeckNativeCore

/// Managed databases use named volumes and the private app network. No port is published.
public struct BackendAppsDatabases: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) { self.runtime = runtime; self.store = store }

    public func create(serverID: String, appID: String, name: String, kind: String, version: String?) async throws -> NativeRPCValue {
        try Self.validateRuntime(runtime)
        _ = try BackendAppsValidation.id(appID)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 120, !name.contains("\0") else {
            throw NativeRPCError.invalidArguments("Give the database a short name.")
        }
        let spec = try BackendAppsDatabaseSpec(kind: kind, version: version)
        return try await store.withLock(serverID, appID) {
            do {
                _ = try await store.read(serverID, appID)
                throw NativeRPCError(code: "conflict", message: "An app with that ID already exists.")
            } catch let error as NativeRPCError where error.code == "not-found" { }
            var image = try await runtime.docker(serverID, "GET", "/images/\(spec.image)/json", nil)
            if image.status == 404 {
                guard runtime.resourcePrefix != "td-test" else {
                    throw BackendAppsRuntime.unavailable("The test server has no preapproved database image. This test cannot pull an image outside the td-test namespace.")
                }
                let pull = try await runtime.docker(serverID, "POST", "/images/create?fromImage=\(spec.repository)&tag=\(spec.version)", nil)
                guard pull.ok else { throw NativeRPCError(code: "unavailable", message: "The database software could not be downloaded.") }
                image = try await runtime.docker(serverID, "GET", "/images/\(spec.image)/json", nil)
            }
            guard image.ok else { throw NativeRPCError(code: "unavailable", message: "The downloaded database software could not be verified.") }
            let imageValue = try image.value()
            guard let imageID = imageValue["Id"].string, imageID.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw BackendAppsRuntime.unavailable("The database software's exact identity could not be verified.")
            }
            try await Self.ensureNetwork(runtime: runtime, serverID: serverID)
            let volume = "\(runtime.resourcePrefix)-\(appID)-data"
            let labels = BackendAppsValidation.object([("io.terminaldeck.app", .string(appID)), ("io.terminaldeck.managed", .string("true"))])
            let existingVolume = try await runtime.docker(serverID, "GET", "/volumes/\(volume)", nil)
            guard existingVolume.status == 404 else {
                throw NativeRPCError(code: "conflict", message: "A saved data volume already uses that ID. Choose a new database ID to preserve it.")
            }
            let volumeResponse = try await runtime.docker(serverID, "POST", "/volumes/create", try BackendAppsValidation.object([("Name", .string(volume)), ("Labels", labels)]).encodedJSON())
            guard volumeResponse.ok else { throw NativeRPCError(code: "unavailable", message: "The database's saved data space could not be created.") }
            // Credential generation stays in Swift. Values travel only through protected state and the private API.
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let environment = spec.environment(password: password)
            let now = runtime.now()
            var record = BackendAppsValidation.object([
                ("id", .string(appID)), ("name", .string(name)), ("kind", .string(kind)), ("status", .string("deploying")),
                ("address", .null), ("source", .null), ("activeDeploymentId", .null),
                ("envKeys", .array(environment.keys.sorted().map(NativeRPCValue.string))),
                ("createdAt", .number(now)), ("updatedAt", .number(now)),
                ("database", BackendAppsValidation.object([
                    ("kind", .string(kind)), ("image", .string(spec.image)), ("imageId", .string(imageID)), ("volumeName", .string(volume)),
                    ("dataPath", .string(spec.dataPath)), ("network", .string(runtime.privateNetwork)),
                    ("databaseName", .string("terminaldeck")), ("port", .number(Double(spec.port)))
                ]))
            ])
            try await store.write(serverID, appID, record)
            try await store.applyEnvironment(serverID, appID, environment)
            let body = spec.container(appID: appID, volume: volume, environment: environment, labels: labels, network: runtime.privateNetwork, prefix: runtime.resourcePrefix).setting("Image", .string(imageID))
            let create = try await runtime.docker(serverID, "POST", "/containers/create?name=\(runtime.resourcePrefix)-\(appID)", try body.encodedJSON())
            guard create.ok, let containerID = try create.value()["Id"].string,
                  containerID.range(of: #"^[a-f0-9]{12,64}$"#, options: .regularExpression) != nil else {
                record = record.setting("status", .string("failed")).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, record)
                throw NativeRPCError(code: "unavailable", message: "The database could not be created. Its saved data space was preserved.")
            }
            record = record.setting("containerId", .string(containerID)).setting("database", record["database"].setting("containerId", .string(containerID)))
            try await store.write(serverID, appID, record)
            do {
                let start = try await runtime.docker(serverID, "POST", "/containers/\(containerID)/start", nil)
                guard start.ok else { throw NativeRPCError(code: "health-failed", message: "The database could not start.") }
                try await Self.waitHealthy(runtime: runtime, serverID: serverID, containerID: containerID)
                record = record.setting("status", .string("running")).setting("updatedAt", .number(runtime.now()))
                try await store.write(serverID, appID, record)
                return BackendAppsStore.publicRecord(record)
            } catch {
                record = record.setting("status", .string("failed")).setting("updatedAt", .number(runtime.now()))
                try? await store.write(serverID, appID, record)
                throw error
            }
        }
    }

    public static func ensureNetwork(runtime: BackendAppsRuntime, serverID: String) async throws {
        try validateRuntime(runtime)
        let network = runtime.privateNetwork
        let read = try await runtime.docker(serverID, "GET", "/networks/\(network)", nil)
        if read.ok { try validateNetwork(try read.value()); return }
        guard read.status == 404 else { throw BackendAppsRuntime.unavailable("The app network could not be checked.") }
        let result = try await runtime.docker(serverID, "POST", "/networks/create", try BackendAppsValidation.object([
            ("Name", .string(network)), ("Driver", .string("bridge")), ("CheckDuplicate", .bool(true)),
            ("Labels", BackendAppsValidation.object([("io.terminaldeck.managed", .string("true"))]))
        ]).encodedJSON())
        // Two app creations may race; confirm the named network after a duplicate response.
        guard result.ok || result.status == 409 else { throw BackendAppsRuntime.unavailable("The private app network could not be created.") }
        let retry = try await runtime.docker(serverID, "GET", "/networks/\(network)", nil)
        guard retry.ok else { throw BackendAppsRuntime.unavailable("The private app network could not be verified.") }
        try validateNetwork(try retry.value())
    }
    public static func validateRuntime(_ runtime: BackendAppsRuntime) throws {
        guard runtime.resourcePrefix.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil,
              runtime.privateNetwork.range(of: #"^[a-z][a-z0-9_.-]{0,95}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The app engine's resource names are invalid.")
        }
    }
    private static func validateNetwork(_ network: NativeRPCValue) throws {
        guard network["Driver"].string == "bridge", network["Ingress"].bool != true,
              network["Labels"]["io.terminaldeck.managed"].string == "true" else {
            throw NativeRPCError(code: "conflict", message: "The app network name belongs to a different network. No existing network was changed.")
        }
    }

    public static func waitHealthy(runtime: BackendAppsRuntime, serverID: String, containerID: String) async throws {
        for attempt in 0..<90 {
            try Task.checkCancellation()
            let response = try await runtime.docker(serverID, "GET", "/containers/\(containerID)/json", nil)
            guard response.ok else { throw NativeRPCError(code: "health-failed", message: "The database's health could not be checked.") }
            let state = try response.value()["State"]
            if state["Health"]["Status"].string == "healthy", state["Running"].bool == true { return }
            if state["Running"].bool == false || state["Health"]["Status"].string == "unhealthy" {
                throw NativeRPCError(code: "health-failed", message: "The database did not pass its startup check. Its saved data was preserved.")
            }
            if attempt < 89 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw NativeRPCError(code: "health-failed", message: "The database took too long to become ready. Its saved data was preserved.")
    }
}

public struct BackendAppsDatabaseSpec: Sendable {
    public let kind: String
    public let repository: String
    public let version: String
    public let dataPath: String
    public let port: Int
    public var image: String { "\(repository):\(version)" }
    public init(kind: String, version: String?) throws {
        self.kind = kind
        switch kind {
        case "postgres": repository = "postgres"; self.version = version ?? "17"; dataPath = "/var/lib/postgresql/data"; port = 5432
        case "mysql": repository = "mysql"; self.version = version ?? "8.4"; dataPath = "/var/lib/mysql"; port = 3306
        case "redis": repository = "redis"; self.version = version ?? "7.4"; dataPath = "/data"; port = 6379
        case "mongodb": repository = "mongo"; self.version = version ?? "8.0"; dataPath = "/data/db"; port = 27017
        default: throw NativeRPCError.invalidArguments("Choose Postgres, MySQL, Redis or MongoDB.")
        }
        guard self.version.range(of: #"^[0-9]{1,2}(?:\.[0-9]{1,2}){0,2}(?:-alpine)?$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Choose a numeric database version.")
        }
        // PostgreSQL 18 changed its volume layout; this engine deliberately handles 17 and older.
        if kind == "postgres", (Int(self.version.split(separator: ".").first?.split(separator: "-").first ?? "0") ?? 0) >= 18 {
            throw BackendAppsRuntime.unavailable("Postgres 18's data layout is not supported yet. Choose version 17.")
        }
    }
    public func environment(password: String) -> [String: String] {
        switch kind {
        case "postgres": ["POSTGRES_USER": "terminaldeck", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "terminaldeck"]
        case "mysql": ["MYSQL_ROOT_PASSWORD": password, "MYSQL_DATABASE": "terminaldeck"]
        case "redis": ["REDIS_PASSWORD": password]
        default: ["MONGO_INITDB_ROOT_USERNAME": "terminaldeck", "MONGO_INITDB_ROOT_PASSWORD": password, "MONGO_INITDB_DATABASE": "terminaldeck"]
        }
    }
    public func container(appID: String, volume: String, environment: [String: String], labels: NativeRPCValue, network: String = "terminaldeck-apps", prefix: String = "terminaldeck", alias: Bool = true) -> NativeRPCValue {
        let health: String
        switch kind {
        case "postgres": health = #"export PGPASSWORD="$POSTGRES_PASSWORD"; pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB""#
        case "mysql": health = #"export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; mysqladmin --user=root ping --silent"#
        case "redis": health = #"export REDISCLI_AUTH="$REDIS_PASSWORD"; test "$(redis-cli ping)" = PONG"#
        default: health = #"mongosh --quiet --eval 'const a=process.env; if(db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD)!==1) quit(1); if(!db.adminCommand({ping:1}).ok) quit(1)'"#
        }
        var result = BackendAppsValidation.object([
            ("Image", .string(image)), ("Env", .array(environment.keys.sorted().map { .string("\($0)=\(environment[$0]!)") })), ("Labels", labels),
            ("Healthcheck", BackendAppsValidation.object([("Test", .array([.string("CMD-SHELL"), .string(health)])), ("Interval", .number(2_000_000_000)), ("Timeout", .number(5_000_000_000)), ("Retries", .number(30)), ("StartPeriod", .number(10_000_000_000))])),
            ("HostConfig", BackendAppsValidation.object([
                ("RestartPolicy", BackendAppsValidation.object([("Name", .string("unless-stopped"))])),
                ("Mounts", .array([BackendAppsValidation.object([("Type", .string("volume")), ("Source", .string(volume)), ("Target", .string(dataPath))])])),
                ("NetworkMode", .string(network)), ("PortBindings", .object([]))
            ])),
            ("NetworkingConfig", BackendAppsValidation.object([("EndpointsConfig", BackendAppsValidation.object([(network, BackendAppsValidation.object([("Aliases", .array(alias ? [.string("\(prefix)-\(appID)")] : []))]))]))]))
        ])
        if kind == "mongodb" {
            // Standalone Mongo does not need persisted config-server state; avoid its image's anonymous volume.
            result = result.setting("HostConfig", result["HostConfig"].setting("Tmpfs", BackendAppsValidation.object([("/data/configdb", .string("rw,nosuid,noexec,size=16777216"))])))
        }
        if kind == "redis" {
            // Keep the password out of Redis argv. The config is protected inside the managed volume.
            result = result.setting("Cmd", .array([.string("sh"), .string("-c"), .string(#"umask 077; printf 'dir /data\nappendonly no\nsave 60 1\nrequirepass %s\n' "$REDIS_PASSWORD" > /data/.terminaldeck-redis.conf; chown redis:redis /data/.terminaldeck-redis.conf; exec docker-entrypoint.sh redis-server /data/.terminaldeck-redis.conf"#)]))
        }
        return result
    }
}
