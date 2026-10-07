import Foundation

/// Port of the rule in src/main/account-vault/runtime.ts (`keptBy`,
/// `vaultSignedIn`, `UNAVAILABLE_SENTENCE`) and profiles.ts `keptUnavailable`:
/// where an account's login lives, whether the app knows it is signed in, and
/// the one sentence for an account the app keeps but cannot reach here.
///
/// `usable` is TS `usable(account, runtime)`: this process can answer the
/// agent's logins — natively, the account vault opens.
public enum BackendSessionSwitchKeptLogin {
    public enum KeptBy: String, Sendable { case app, adopting, unavailable, agent }

    /// TS KEPT_PROVIDERS: the agents this app can hand a kept login to.
    public static let keptProviders: Set<String> = ["claude", "codex"]

    /// TS UNAVAILABLE_SENTENCE — one sentence, everywhere.
    public static let unavailableSentence = "This app keeps this account’s login, and its store is not open in this process, so nothing was started. Open the desktop app on this Mac, or sign the account in again there."

    /// TS keptBy.
    public static func keptBy(_ account: BackendAccountProfile, managed: Bool, usable: Bool) -> KeptBy {
        if account.system || !managed { return .agent }
        if !keptProviders.contains(account.provider) { return .agent }
        if !usable { return account.promised ? .unavailable : .agent }
        if account.provider == "codex" { return .app }
        if account.loginStore == "app" { return .app }
        // Moved in once its login slot has; the API-key slot keeps moving on its own.
        return (account.keptSlots ?? []).contains(where: BackendAccountProfile.loginSlot) ? .app : .adopting
    }

    /// TS vaultSignedIn with a running vault: true when the vault holds the
    /// login, false only where the app knows for certain it holds none, else
    /// nil (the agent's own answer is needed).
    public static func signedIn(_ account: BackendAccountProfile, kept: KeptBy, held: Bool) -> Bool? {
        guard kept == .app || kept == .adopting else { return nil }
        if held { return true }
        if kept != .app { return nil }
        // Codex is only "signed out" once something has actually been kept for it.
        if account.provider == "codex" { return (account.keptSlots ?? []).isEmpty ? nil : false }
        return false
    }

    /// TS keptUnavailable.
    public static func unavailable(_ kept: KeptBy) -> String? { kept == .unavailable ? unavailableSentence : nil }
}
