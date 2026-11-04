import Foundation
import os
import TerminalDeckNativeCore

/// 4 Nov (Asad's recording, install #26): "I am trying to add one more account but it says 'this account already
/// exists'. But if I scroll all the accounts it's not there." The account "imzapremium@gmail.com" had been signed in
/// with another login (app.imatch.ae@gmail.com). Settings folds a second copy of a login into the row of its first
/// copy, so the list never showed that name, while Add account still refused it as taken.
///
/// The tidy makes the name match the login: an account whose name is an email address, while its own folder says
/// it is signed in as a different address, is renamed to that address (with "(second copy)" when another account
/// already has it). Nothing else changes: its login, folder, history and choices stay exactly as they are. The
/// profile list is copied aside first, and every rename is logged.
public enum BackendAccountTidy {
    public struct Rename: Equatable, Sendable {
        public let id: String, from: String, to: String, login: String
        public var line: String { "accounts tidy: renamed “\(from)” to “\(to)” (\(id)): its saved login is \(login)" }
    }
    static let log = Logger(subsystem: "dev.terminaldeck.app", category: "accounts-tidy")

    /// Where Claude Code keeps the address of its login: `<config>/.claude.json`, or `~/.claude.json` for the Mac's
    /// own install when no config folder is named.
    public static func claudeStateFile(configDir: String?, home: URL) -> URL {
        if let configDir = configDir?.trimmingCharacters(in: .whitespacesAndNewlines), !configDir.isEmpty {
            return URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        }
        return home.appendingPathComponent(".claude.json")
    }
    /// The address Claude Code wrote at its last sign-in (`oauthAccount.emailAddress`), or nil.
    public static func rememberedEmail(_ state: NativeRPCValue) -> String? {
        CodingAILogins.normalizedEmail(state["oauthAccount"]["emailAddress"].string)
    }
    /// The address an app account's own Claude folder remembers. Never the Mac's own login, an API account or another AI.
    public static func rememberedEmail(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration) -> String? {
        guard !profile.system, profile.provider == "claude", !BackendAPIAccountRecord.isAPIAccountID(profile.id), profile.configDir.hasPrefix("/") else { return nil }
        let file = claudeStateFile(configDir: profile.configDir, home: configuration.homeDirectory)
        guard let data = try? BackendAccountFiles.boundedRead(file, maximum: 16 * 1024 * 1024), let value = try? NativeRPCValue.parseJSON(data) else { return nil }
        return rememberedEmail(value)
    }

    /// The renames that make every email-named account carry the address it is really signed in as.
    /// `remembered`: account id → the address its own folder remembers.
    public static func plan(_ profiles: [BackendAccountProfile], remembered: [String: String]) -> [Rename] {
        func key(_ provider: String, _ name: String) -> String { provider + "\u{0}" + name.lowercased() }
        var taken = Set(profiles.map { key($0.provider, $0.name) })
        var out: [Rename] = []
        for profile in profiles where !profile.system && !BackendAPIAccountRecord.isAPIAccountID(profile.id) {
            guard let named = CodingAILogins.normalizedEmail(profile.name),
                  let login = remembered[profile.id].flatMap(CodingAILogins.normalizedEmail), login != named else { continue }
            let candidates = [login, login + " (second copy)"] + (3...9).map { "\(login) (copy \($0))" }
            guard let next = candidates.first(where: { !taken.contains(key(profile.provider, $0)) && $0.utf16.count <= BackendAccountProfile.maximumNameLength }) else { continue }
            taken.remove(key(profile.provider, profile.name)); taken.insert(key(profile.provider, next))
            out.append(Rename(id: profile.id, from: profile.name, to: next, login: login))
        }
        return out
    }

    /// A copy of profiles.json beside it, taken before the first rename; nil when there is no file.
    public static func backup(_ configuration: BackendAccountConfiguration, now: Date = Date()) throws -> URL? {
        let file = configuration.dataDirectory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let target = configuration.dataDirectory.appendingPathComponent("profiles.json.bak-tidy-\(Int64(now.timeIntervalSince1970 * 1000))")
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    /// Reads the accounts from their owner, backs the list up and renames through the owner (works with an older
    /// session host too: it only uses list and rename). Quiet when there is nothing to do.
    public static func run(configuration: BackendAccountConfiguration,
                           list: @Sendable () async throws -> [BackendAccountProfile],
                           rename: @Sendable (String, String) async throws -> Void,
                           note: @Sendable (String) -> Void = { _ in }) async -> [Rename] {
        func say(_ text: String) { log.notice("\(text, privacy: .public)"); note(text) }
        guard let profiles = try? await list() else { return [] }
        var remembered: [String: String] = [:]
        for profile in profiles { remembered[profile.id] = rememberedEmail(profile, configuration: configuration) }
        let renames = plan(profiles, remembered: remembered)
        guard !renames.isEmpty else { return [] }
        do {
            if let copy = try backup(configuration) { say("accounts tidy: profile list copied to \(copy.lastPathComponent) before renaming") }
        } catch {
            say("accounts tidy: nothing renamed, the profile list could not be copied first (\(error.localizedDescription))")
            return []
        }
        var done: [Rename] = []
        for item in renames {
            do { try await rename(item.id, item.to); done.append(item); say(item.line) }
            catch { say("accounts tidy: “\(item.from)” was not renamed: \(error.localizedDescription)") }
        }
        return done
    }

    /// Add account, when the name typed is already an account's: frees it when that account really is another login
    /// (renamed as above, after a backup); otherwise says which account has it.
    public static func freeName(_ name: String, provider: String, among profiles: [BackendAccountProfile], configuration: BackendAccountConfiguration,
                                rename: @Sendable (String, String) async throws -> Void) async throws {
        guard let holder = profiles.first(where: { $0.provider == provider && $0.name.lowercased() == name.lowercased() }) else { return }
        let remembered = rememberedEmail(holder, configuration: configuration).map { [holder.id: $0] } ?? [:]
        guard let fix = plan(profiles, remembered: remembered).first(where: { $0.id == holder.id }) else { throw BackendAccountFailure(taken(holder)) }
        if let copy = try backup(configuration) { log.notice("accounts tidy: profile list copied to \(copy.lastPathComponent, privacy: .public) before renaming") }
        try await rename(fix.id, fix.to)
        log.notice("\(fix.line, privacy: .public)")
    }

    /// The one sentence for a name already in the list: which account has it and what to do.
    public static func taken(_ holder: BackendAccountProfile) -> String {
        let label = BackendAccountProfile.providerLabel(holder.provider)
        if holder.system { return "“\(holder.name)” is the name of this Mac’s own \(label) login. Type the email address of the login you want to add." }
        return "“\(holder.name)” is already one of your \(label) accounts in Settings › Coding AIs. Press Sign in again on its row, or type another email address."
    }
}

/// 4 Nov: signing in this Mac's own login of an AI, only after the person pressed its Sign in and confirmed.
public enum BackendAccountOwnLogin {
    /// What must never ride along into the sign-in: a token or API key from the app's surroundings.
    public static let overrides = ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                                   "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_ACCESS_TOKEN"]
    /// The sign-in acts on exactly the folder this Mac's own login is: the AI's default one when no variable names a
    /// folder (no variable is added, so Claude Code keeps its own Keychain entry), or the inherited one.
    public static func pinned(_ profile: BackendAccountProfile, environment: [String: String], key: String, home: URL) -> Bool {
        guard profile.system else { return false }
        let named = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = named.isEmpty ? home.appendingPathComponent("." + profile.provider).path : named
        return URL(fileURLWithPath: folder).standardizedFileURL.path == URL(fileURLWithPath: profile.configDir).standardizedFileURL.path
    }
}
