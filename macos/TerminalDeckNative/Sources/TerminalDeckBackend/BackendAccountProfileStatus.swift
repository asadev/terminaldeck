import Foundation
import TerminalDeckNativeCore

/// Port of TS src/main/platform/credential-store.ts `profileIsolation` and
/// src/main/profiles.ts `profileStatus` / the `credentialsRetained` rule of
/// `deleteProfile`. Pure: reads only whether files exist, never a login.
public enum BackendAccountProfileStatus {
    public struct Isolation: Sendable, Equatable {
        public let store: String, isolated: Bool, note: String
        public var wireValue: NativeRPCValue {
            .object([.init("store", .string(store)), .init("isolated", .bool(isolated)), .init("note", .string(note))])
        }
    }

    /// TS `profileIsolation(platform, credentialsInConfigDir)`.
    public static func isolation(platform: String = "darwin", credentialsInConfigDir: Bool) -> Isolation {
        if platform == "darwin" {
            return Isolation(store: "macos-keychain", isolated: true,
                note: "Logins are kept in the macOS Keychain under a name derived from this profile’s config directory, so profiles cannot overwrite each other’s login, and deleting this profile’s files does not sign it out.")
        }
        if credentialsInConfigDir {
            return Isolation(store: "config-directory", isolated: true,
                note: "This profile keeps its own credentials file inside its config directory, so its login is separate from the others — and deleting this profile’s files does sign it out.")
        }
        let named = platform == "win32" ? "Windows" : platform
        return Isolation(store: "unknown", isolated: false,
            note: "Profile isolation is unverified on \(named). The config directory is redirected, but where the agent keeps its credentials there has not been checked, so two profiles may share one login until this one has been signed into at least once.")
    }

    /// TS profiles.ts `initializedMarkers`.
    public static func initializedMarkers(_ provider: String) -> [String] {
        provider == "claude" ? [".claude.json"] : ["config.toml", "auth.json", "sessions"]
    }

    /// TS profiles.ts `hasCredentialFile`.
    public static func hasCredentialFile(_ profile: BackendAccountProfile) -> Bool {
        guard let name = BackendAccountStrategies.strategy(profile.provider)?.credentialFile, !name.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: profile.configDir).appendingPathComponent(name).path)
    }

    /// TS `profileStatus(profile, platform)`: id, exists, initialized, configDir, provider, isolation.
    public static func status(_ profile: BackendAccountProfile, platform: String = "darwin") -> NativeRPCValue {
        let root = URL(fileURLWithPath: profile.configDir)
        return .object([.init("id", .string(profile.id)),
            .init("exists", .bool(FileManager.default.fileExists(atPath: root.path))),
            .init("initialized", .bool(initializedMarkers(profile.provider).contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })),
            .init("configDir", .string(profile.configDir)), .init("provider", .string(profile.provider)),
            .init("isolation", isolation(platform: platform, credentialsInConfigDir: hasCredentialFile(profile)).wireValue)])
    }

    /// TS `deleteProfile` result rule: a login the app kept survives only if forgetting it failed;
    /// otherwise it survives unless the deleted files held it.
    public static func credentialsRetained(keptInApp: Bool, forgot: Bool, filesDeleted: Bool, isolation: Isolation) -> Bool {
        keptInApp ? !forgot : (!filesDeleted || isolation.store != "config-directory")
    }
}
