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
public enum BackendScratchAgentHomes {
    public static let homes: [(key: String, folder: String)] = [("CLAUDE_CONFIG_DIR", "claude"), ("CODEX_HOME", "codex"), ("GEMINI_CLI_HOME", "gemini")]
    /// The variables to add for this process: none for the installed app.
    public static func additions(environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        let primary = BackendCompositionSuppliers.primaryDataDirectory(home: home)
        let named = environment[NativeLaunchSwitches.dataFolder].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL }
        // The installed app's folder by any spelling (a link, another letter case) is never a scratch copy's.
        func same(_ a: URL, _ b: URL) -> Bool { canonical(a) == canonical(b) }
        let data: URL
        if let named, !same(named, primary) { data = named }
        else if bundleID == BackendDevCopy.bundleID {
            data = named ?? home.appendingPathComponent("Library/Application Support/" + BackendDevCopy.name, isDirectory: true).standardizedFileURL
            guard !same(data, primary) else { return [:] }
        } else { return [:] }
        var out: [String: String] = [:]
        for entry in homes where (environment[entry.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out[entry.key] = data.appendingPathComponent("agent-homes", isDirectory: true).appendingPathComponent(entry.folder, isDirectory: true).path
        }
        return out
    }
    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
    /// The environment with the scratch homes in it: what the account setup and every session are given directly.
    public static func environment(_ environment: [String: String], home: URL, bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        environment.merging(additions(environment: environment, home: home, bundleID: bundleID)) { current, _ in current }
    }
    /// At the very start of the app, before anything reads its environment: the homes made (0700) and set.
    public static func apply(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        for (key, path) in additions(environment: ProcessInfo.processInfo.environment, home: home) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            setenv(key, path, 1)
        }
    }
}
