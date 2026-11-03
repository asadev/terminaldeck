import Foundation

/// Safe projection of the read-only private database connection channel.
/// Password values and connection URIs are never stored in this UI record.
public struct NativeAppsDataDatabaseConnection: Equatable, Sendable {
    public let kind: String
    public let host: String
    public let port: Int
    public let database: String?
    public let username: String
    public let passwordKey: String
    public let authenticationDatabase: String?

    /// A private host and port only: safe to copy, with no credentials or URI.
    public var address: String { host + ":" + String(port) }

    public static func read(_ value: NativeRPCValue) throws -> Self {
        let allowed: Set<String> = ["kind", "host", "port", "database", "username", "password", "passwordKey",
                                    "scope", "network", "status", "authenticationDatabase", "instructions"]
        guard let fields = value.fields, Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)).isSubset(of: allowed),
              value["scope"].string == "private-network", value["password"].string == "••••••••",
              let kind = value["kind"].string, let host = value["host"].string,
              host.range(of: #"\A[a-z][a-z0-9-]{0,96}\z"#, options: .regularExpression) != nil,
              let network = value["network"].string,
              network.range(of: #"\A[a-z][a-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil,
              let number = value["port"].number, let port = Int(exactly: number) else {
            throw NativeRPCError.malformed("The server returned unreadable private database connection details.")
        }
        let expected: (port: Int, username: String, passwordKey: String, database: String?, authenticationDatabase: String?)
        switch kind {
        case "postgres": expected = (5432, "terminaldeck", "POSTGRES_PASSWORD", "terminaldeck", nil)
        case "mysql": expected = (3306, "root", "MYSQL_ROOT_PASSWORD", "terminaldeck", nil)
        case "redis": expected = (6379, "default", "REDIS_PASSWORD", nil, nil)
        case "mongodb": expected = (27017, "terminaldeck", "MONGO_INITDB_ROOT_PASSWORD", "terminaldeck", "admin")
        default: throw NativeRPCError.malformed("The server returned an unsupported database connection kind.")
        }
        guard port == expected.port, value["username"].string == expected.username,
              value["passwordKey"].string == expected.passwordKey,
              value["database"].string == expected.database,
              value["authenticationDatabase"].string == expected.authenticationDatabase,
              expected.database != nil || value["database"].isNullish,
              expected.authenticationDatabase != nil || value["authenticationDatabase"].isNullish else {
            throw NativeRPCError.malformed("The server returned connection settings that do not match this database.")
        }
        return .init(kind: kind, host: host, port: port, database: expected.database, username: expected.username,
                     passwordKey: expected.passwordKey, authenticationDatabase: expected.authenticationDatabase)
    }
}
