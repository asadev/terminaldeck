import Foundation
import TerminalDeckNativeCore

/// Billing is an observed account fact. A provider, model or token count does
/// not identify the person's payment arrangement.
public enum BackendAGOPTBilling {
    public static func kind(provider: String, accountID: String, configDirectory: String,
                            observedAccount: BackendUsageAccount?, sessionBilling: String?,
                            cachedBilling: String?) -> String? {
        guard !accountID.isEmpty, !configDirectory.isEmpty else { return nil }
        let cached = normalized(cachedBilling)
        guard let observedAccount else { return cached }
        guard observedAccount.provider == provider, observedAccount.id == accountID,
              observedAccount.configDirectory == configDirectory else { return cached }
        let current = normalized(sessionBilling)
        // The active, exactly attributed session supersedes an older cache.
        return current ?? cached
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, ["api", "subscription"].contains(value) else { return nil }
        return value
    }
}
