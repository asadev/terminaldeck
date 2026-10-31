import Foundation
import TerminalDeckNativeCore

/// Default is a launch choice, never proof that its remembered email can still sign in.
public enum BackendDefaultClaudeLogin {
    public typealias IdentityCheck = @Sendable (BackendAccountProfile) async -> String?
    public static let chooseMarker = "Choose a saved Claude login in Switch before starting."
    @TaskLocal public static var environmentOverrides: [String: String] = [:]

    public static func email(_ profile: BackendAccountProfile, home: URL) -> String? {
        let folder = URL(fileURLWithPath: profile.configDir)
        let files = profile.system && folder.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path
            ? [home.appendingPathComponent(".claude.json"), folder.appendingPathComponent(".claude.json")]
            : [folder.appendingPathComponent(".claude.json")]
        for file in files {
            guard let data = try? BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024),
                  let value = try? NativeRPCValue.parseJSON(data),
                  let email = CodingAILogins.normalizedEmail(value["oauthAccount"]["emailAddress"].string) else { continue }
            return email
        }
        return profile.system ? nil : CodingAILogins.normalizedEmail(profile.name)
    }

    public static func candidates(remembered: String?, signedIn: [BackendAccountProfile], emails: [String: String]) -> [BackendAccountProfile] {
        if let remembered { return signedIn.filter { emails[$0.id] == remembered } }
        return signedIn.count == 1 ? signedIn : []
    }

    public static func choose(_ candidates: [BackendAccountProfile], preferred: [String]) throws -> BackendAccountProfile? {
        if candidates.count == 1 { return candidates[0] }
        for id in preferred { if let found = candidates.first(where: { $0.id == id }) { return found } }
        guard candidates.isEmpty else { throw BackendAccountFailure(chooseMarker) }
        return nil
    }

    public static func resolve(_ login: BackendAccountProfile, saved: [BackendAccountProfile], preferred: [String],
                               configuration: BackendAccountConfiguration, check: BackendAccountLaunchAdapter.SignInCheck, identity: IdentityCheck? = nil) async throws -> BackendAccountProfile {
        guard login.system, login.provider == "claude" else { return login }
        let seen = configuration.inheritedEnvironment.merging(environmentOverrides) { _, new in new }
        let settings = [login.configDir + "/settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json"].map { path -> NativeRPCValue in
            guard let data = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: path), maximum: 1_048_576),
                  let value = try? NativeRPCValue.parseJSON(data) else { return .object([]) }
            return value
        }
        guard await BackendAccountLaunchAdapter.refusal(login, check: check, environment: seen, settings: settings) != nil else { return login }
        var ready: [BackendAccountProfile] = [], emails: [String: String] = [:]
        for account in saved where !account.system && account.provider == "claude" && !BackendAPIAccountRecord.isAPIAccountID(account.id) {
            guard await check(account, true) == "signed-in" else { continue }
            ready.append(account)
            if let identity {
                emails[account.id] = CodingAILogins.normalizedEmail(await identity(account))
            } else {
                emails[account.id] = email(account, home: configuration.homeDirectory)
            }
        }
        let matches = candidates(remembered: email(login, home: configuration.homeDirectory), signedIn: ready, emails: emails)
        return try choose(matches, preferred: preferred) ?? login
    }
}
