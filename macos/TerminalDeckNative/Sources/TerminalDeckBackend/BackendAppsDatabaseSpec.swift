import Foundation
import TerminalDeckNativeCore

/// The supported managed database kinds: image, data folder, port, settings and container shape.
/// Managed databases use named volumes and the private app network. No port is published.
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
