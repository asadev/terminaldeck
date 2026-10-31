import Foundation
import TerminalDeckNativeCore

public extension BackendAppSettingsStore {
    /// Runs inside the existing actor's serial write boundary. This is not a
    /// second settings reader/writer. For an ordinary current-schema v1 source,
    /// a failed atomic write retains the committed snapshot for retry. The
    /// existing owner must refuse unsupported/corrupt sources before this call:
    /// its backup-before-write path needs separate failure-safe publication.
    @discardableResult
    func migrateRNMHootSettings(legacyDefaultHome: String? = nil,
                                hootDefaultHome: String? = nil) throws -> RNMHootSettingsMigration.Plan {
        try requireSupportedHootMigrationSource()
        let migration = RNMHootSettingsMigration.plan(values: get()["values"],
            legacyDefaultHome: legacyDefaultHome, hootDefaultHome: hootDefaultHome)
        if migration.needsWrite { _ = try patch(migration.patch) }
        return migration
    }
}
