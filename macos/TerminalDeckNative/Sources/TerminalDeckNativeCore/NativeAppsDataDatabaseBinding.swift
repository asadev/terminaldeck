import Foundation

/// Only an existing app ID and setting key enter the bind request. The engine
/// builds the real URI from protected server values; the Mac never sees it.
public struct NativeAppsDataDatabaseBindingDraft: Equatable, Sendable {
    public var targetAppID: String
    public var key: String
    public init(kind: String, targetAppID: String = "") {
        self.targetAppID = targetAppID
        key = kind == "redis" ? "REDIS_URL" : "DATABASE_URL"
    }

    public static func eligibleApps(_ apps: [NativeAppsSummary], databaseID: String) -> [NativeAppsSummary] {
        apps.filter { $0.kind == "app" && $0.id != databaseID && validID($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func validationMessage(apps: [NativeAppsSummary], databaseID: String) -> String? {
        guard Self.validID(targetAppID), Self.eligibleApps(apps, databaseID: databaseID).contains(where: { $0.id == targetAppID }) else {
            return "Choose an app on this server to receive the connection."
        }
        guard Self.validKey(key) else { return "Use a setting name with letters, numbers and underscores, starting with a letter or underscore." }
        return nil
    }

    public static func validKey(_ key: String) -> Bool {
        key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]{0,127}\z"#, options: .regularExpression) != nil
    }

    /// The bind result acknowledges a protected setting, never its real URI.
    public static func verifyReceipt(_ value: NativeRPCValue, databaseID: String, targetAppID: String, key: String) throws {
        let allowed: Set<String> = ["bound", "appId", "targetAppId", "key", "value", "secret", "requiresDeploy"]
        guard let fields = value.fields, fields.count == allowed.count,
              Set(fields.map(\.key)) == allowed,
              value["bound"].bool == true, value["secret"].bool == true,
              value["requiresDeploy"].bool == true, value["value"].string == "••••••••",
              value["appId"].string == databaseID, value["targetAppId"].string == targetAppID,
              value["key"].string == key, validKey(key) else {
            throw NativeRPCError.malformed("The server did not confirm a protected connection for the selected app.")
        }
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil
    }
}
