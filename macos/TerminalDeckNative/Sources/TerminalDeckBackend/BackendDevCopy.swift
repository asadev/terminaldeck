import Foundation
import CryptoKit
import Security
import TerminalDeckNativeCore

/// The dev copy ("Terminal Deck Dev", bundle `dev.terminaldeck.app.dev`, data in `~/Library/Application Support/Terminal Deck Dev`).
///
/// 11 Oct: the dev copy asked Asad for his keychain password again and again, for the REAL app's item
/// "Terminal Deck Receiver Key": every per-app keychain name was derived from the app name, and the dev copy
/// ran with the real app's name. Every rebuild is signed afresh, so macOS asked each time.
/// Fixed at the root: the dev copy's app name is "Terminal Deck Dev" (BackendCompositionSuppliers.configuration),
/// so any name derived from it is the dev copy's own, and the dev copy keeps its secrets in owner-only files in
/// its own data folder (BackendAccountDevKey), so it never opens the keychain at all and never prompts.
/// The real app never takes any of these paths.
public enum BackendDevCopy {
    public static let bundleID = "dev.terminaldeck.app.dev"
    public static let name = "Terminal Deck Dev"

    /// The dev copy: its bundle id, its data folder's name, or its app name.
    public static func isDevCopy(dataDirectory: URL?, bundleID: String? = Bundle.main.bundleIdentifier, appName: String? = nil) -> Bool {
        bundleID == Self.bundleID || appName == name || dataDirectory?.standardizedFileURL.lastPathComponent == name
    }
    /// The name every per-app keychain item, folder and label is derived from.
    public static func appName(dataDirectory: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        isDevCopy(dataDirectory: dataDirectory, bundleID: bundleID) ? name : BackendSharedBrand.name
    }
    /// The Electron app's original "<name> Safe Storage" item that browser cookies were encrypted with, or nil:
    /// the dev copy never reads it (it has no Electron data of its own, and the item is the real app's).
    public static func originalSafeStorageName(dataDirectory: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        isDevCopy(dataDirectory: dataDirectory, bundleID: bundleID) ? nil : BackendSharedBrand.name
    }

    /// Every keychain service name derived from an app name (for checks that the dev copy never names the real app's).
    public static func keychainServices(appName: String) -> [String] {
        [BackendAccountKeychainCipher(appName: appName).service, BackendRCVKeychainCipher(appName: appName).service,
         BackendConnectedTasksKeychain(appName: appName).service]
    }
}

extension BackendAccountDevKey {
    /// The dev copy's own secret file `name` in its data folder, or nil when this process is not the dev copy.
    static func devFile(named name: String) -> URL? { folderURL()?.appendingPathComponent(name) }

    /// Exactly `count` random bytes kept in an owner-only file (created on first use when `create`).
    static func rawKey(at file: URL, count: Int, create: Bool) throws -> Data {
        if let bytes = try? Data(contentsOf: file), bytes.count == count { return bytes }
        guard create else { throw BackendAccountFailure("The dev copy's key is missing, so its saved data cannot be opened.") }
        var random = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &random) == errSecSuccess else {
            throw BackendAccountFailure("macOS could not create a secure key for the dev copy.")
        }
        let bytes = Data(random)
        try writeOwnerOnly(bytes, to: file, replace: false)
        return (try? Data(contentsOf: file)).flatMap { $0.count == count ? $0 : nil } ?? bytes
    }

    /// Owner-only from the first byte. `replace` false never overwrites a file that appeared meanwhile.
    static func writeOwnerOnly(_ bytes: Data, to file: URL, replace: Bool) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = replace ? file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString) : file
        let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST, !replace { return }
            throw BackendAccountFailure("The dev copy could not save its key.")
        }
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        Darwin.close(descriptor)
        guard written == bytes.count else { try? FileManager.default.removeItem(at: target); throw BackendAccountFailure("The dev copy could not save its key.") }
        if replace {
            guard Darwin.rename(target.path, file.path) == 0 else { try? FileManager.default.removeItem(at: target); throw BackendAccountFailure("The dev copy could not save its key.") }
        }
    }
}

/// The dev copy's connected-task tokens: one owner-only file per connection in its own data folder,
/// instead of the keychain (a rebuilt dev copy is a new app to the keychain, which would ask every time).
public struct BackendConnectedTasksDevFiles: BackendConnectedTasksSecrets {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }
    private func file(_ id: String) -> URL {
        folder.appendingPathComponent(SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    public func read(_ connectionID: String) throws -> String? {
        guard let data = try? Data(contentsOf: file(connectionID)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    public func write(_ connectionID: String, token: String) throws {
        try BackendAccountDevKey.writeOwnerOnly(Data(token.utf8), to: file(connectionID), replace: true)
    }
    public func remove(_ connectionID: String) throws {
        do { try FileManager.default.removeItem(at: file(connectionID)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
    }
}

/// 29 Oct (standing rule: scratch installs get separate data AND keychain names). A copy that is not the installed
/// app (the dev copy, a scratch install with its own data folder) gives each AI's own login a home inside its data
/// folder, so its "Default" accounts never read or write this Mac's own Claude Code, Codex or Gemini login. Claude
/// Code names its keychain item after CLAUDE_CONFIG_DIR, so the Mac-wide "Claude Code-credentials" is never touched.
/// A home the launcher set itself (TD_ACCOUNTS18_PROOF) stays.
///
/// 3 Nov (#26, install-25 final check "for Decker" 5): a scratch copy's Claude home held his `oauthAccount` (email,
/// organisation). Claude Code writes that only when it has a working login (2.1.310: at start, a token and no
/// complete profile fetch the profile; it never copies ~/.claude.json, measured with a fake home). A copy started from
/// inside an agent session (`open`, devloop.sh) inherits that session's route to the INSTALLED app's login: the vault
/// socket and ticket, CLAUDE_SECURESTORAGE_CONFIG_DIR (…/terminaldeck/account-vault/store/system) and the installed
/// app's `account-vault-shim` (its `security`) first on PATH. So a scratch copy now drops that route at its start, and
/// a profile copied from one of this Mac's real logins is taken out of its Claude home. The installed app: unchanged.
public enum BackendScratchAgentHomes {
    public static let homes: [(key: String, folder: String)] = [("CLAUDE_CONFIG_DIR", "claude"), ("CODEX_HOME", "codex"), ("GEMINI_CLI_HOME", "gemini")]
    /// What leads an AI started by a scratch copy to the installed app's login (or straight to a token).
    public static let inheritedLogin: Set<String> = BackendSessionEnvironment.vaultVariables.union(["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"])
    /// This copy's own data folder when it is a scratch copy; nil for the installed app.
    public static func scratchData(environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        let primary = BackendCompositionSuppliers.primaryDataDirectory(home: home)
        let named = environment[NativeLaunchSwitches.dataFolder].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        // The installed app's folder by any spelling (a link, another letter case) is never a scratch copy's.
        func same(_ a: URL, _ b: URL) -> Bool { canonical(a) == canonical(b) }
        if let named, !same(named, primary) { return named }
        guard bundleID == BackendDevCopy.bundleID else { return nil }
        let data = named ?? home.appendingPathComponent("Library/Application Support/" + BackendDevCopy.name, isDirectory: true).standardizedFileURL
        return same(data, primary) ? nil : data
    }
    /// The variables to add for this process: none for the installed app.
    public static func additions(environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        guard let data = scratchData(environment: environment, home: home, bundleID: bundleID) else { return [:] }
        var out: [String: String] = [:]
        for entry in homes where (environment[entry.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out[entry.key] = data.appendingPathComponent("agent-homes", isDirectory: true).appendingPathComponent(entry.folder, isDirectory: true).path
        }
        return out
    }
    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
    /// PATH without the installed app's own folders (its `shim` and `account-vault-shim`); every other entry as it was.
    static func withoutInstalledFolders(_ path: String, home: URL) -> String {
        let installed = canonical(BackendCompositionSuppliers.primaryDataDirectory(home: home)) + "/"
        return path.split(separator: ":", omittingEmptySubsequences: false).filter { entry in
            entry.isEmpty || !(canonical(URL(fileURLWithPath: String(entry))) + "/").hasPrefix(installed)
        }.joined(separator: ":")
    }
    /// A scratch copy's environment without the inherited route to the installed app's login; the installed app's as it is.
    public static func withoutInstalledLogin(_ environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        guard scratchData(environment: environment, home: home, bundleID: bundleID) != nil else { return environment }
        var out = environment.filter { !inheritedLogin.contains($0.key) }
        if let path = environment["PATH"] { out["PATH"] = withoutInstalledFolders(path, home: home) }
        return out
    }
    /// The environment with the scratch homes in it: what the account setup and every session are given directly.
    public static func environment(_ environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        withoutInstalledLogin(environment, home: home, bundleID: bundleID)
            .merging(additions(environment: environment, home: home, bundleID: bundleID)) { current, _ in current }
    }
    /// At the very start of the app, before anything reads its environment: the inherited login route dropped, the
    /// homes made (0700) and set, and a copied profile taken out of the Claude home. Nothing at all for the installed app.
    public static func apply(home: URL = URL(fileURLWithPath: NSHomeDirectory()), bundleID: String? = Bundle.main.bundleIdentifier) {
        let inherited = ProcessInfo.processInfo.environment
        guard let data = scratchData(environment: inherited, home: home, bundleID: bundleID) else { return }
        for key in inheritedLogin where inherited[key] != nil { unsetenv(key) }
        if let path = inherited["PATH"], case let clean = withoutInstalledFolders(path, home: home), clean != path { setenv("PATH", clean, 1) }
        for (key, path) in additions(environment: inherited, home: home, bundleID: bundleID) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            setenv(key, path, 1)
        }
        if let claude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !claude.isEmpty {
            neutralizeCopiedProfile(claudeHome: URL(fileURLWithPath: claude), scratchData: data, home: home)
        }
    }

    /// The accounts of this Mac's real Claude logins: its own (~/.claude.json) and each one the installed app keeps.
    /// Read only.
    static func realLoginAccounts(home: URL) -> Set<String> {
        let logins = BackendCompositionSuppliers.primaryDataDirectory(home: home).appendingPathComponent("account-logins", isDirectory: true)
        let kept = ((try? FileManager.default.contentsOfDirectory(at: logins, includingPropertiesForKeys: nil)) ?? []).map { $0.appendingPathComponent(".claude.json") }
        return Set(([home.appendingPathComponent(".claude.json")] + kept).compactMap { file in
            (try? BackendAccountFiles.boundedRead(file, maximum: 32 << 20))
                .flatMap { try? NativeRPCValue.parseJSON($0, maximumBytes: 32 << 20) }?["oauthAccount"]["accountUuid"].string?.lowercased()
        })
    }
    /// Takes `oauthAccount` out of a scratch copy's Claude home when it is one of this Mac's real logins (copied in
    /// through an inherited route). Only a home inside the scratch copy's own data folder, never while Claude Code holds
    /// its lock, every other key kept in order. A home with its own working login of that account gets it back from
    /// Claude Code at its next start. True when it was taken out.
    @discardableResult
    static func neutralizeCopiedProfile(claudeHome: URL, scratchData: URL, home: URL) -> Bool {
        let file = claudeHome.appendingPathComponent(".claude.json")
        guard canonical(claudeHome).hasPrefix(canonical(scratchData) + "/"), !FileManager.default.fileExists(atPath: file.path + ".lock"),
              let bytes = try? BackendAccountFiles.boundedRead(file, maximum: 32 << 20),
              let config = try? NativeRPCValue.parseJSON(bytes, maximumBytes: 32 << 20), config.fields != nil,
              let account = config["oauthAccount"]["accountUuid"].string?.lowercased(), realLoginAccounts(home: home).contains(account),
              let neutral = try? config.removing("oauthAccount").encodedJSON(pretty: true) else { return false }
        return (try? BackendAccountFiles.writeAtomic(neutral + Data("\n".utf8), to: file)) != nil
    }
}
