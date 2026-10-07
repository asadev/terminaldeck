import Foundation
import AppKit
import TerminalDeckNativeCore

/// Safari supplies its actual app-owned website-data clear; no second cookie store is created.
public protocol BackendAppSettingsBrowserData: Sendable {
    func clearStorageCacheAndAuthentication() async throws
}

public struct BackendAppSettingsEnvironment: Sendable {
    public let userData: URL, logs: URL, trace: URL
    public let about: @Sendable () async throws -> NativeRPCValue
    public let browser: (any BackendAppSettingsBrowserData)?
    public let publish: @Sendable (String, NativeRPCValue) async -> Void
    public init(userData: URL, logs: URL, trace: URL, browser: (any BackendAppSettingsBrowserData)?,
                about: @escaping @Sendable () async throws -> NativeRPCValue,
                publish: @escaping @Sendable (String, NativeRPCValue) async -> Void) {
        self.userData = userData; self.logs = logs; self.trace = trace; self.browser = browser; self.about = about; self.publish = publish
    }
}

/// settings-extra.ts; seven source channels and the settings:changed echo.
public enum BackendAppSettingsChannels {
    public static let channels = ["settings:get", "settings:set", "settings:reset", "settings:paths", "settings:open-path", "settings:about", "settings:clear-browser-data"]
    public static func paths(_ env: BackendAppSettingsEnvironment) -> NativeRPCValue {
        let entries: [(String, String, String, URL, String)] = [
            ("userData", "App data", "Everything below lives in here.", env.userData, "folder"),
            ("settings", "Settings", "The options in this window.", env.userData.appendingPathComponent("settings.json"), "file"),
            ("settingsLastGood", "Settings — last good", "A copy of your settings taken before \(BackendSharedBrand.assistant) changed any. Written only then.", env.userData.appendingPathComponent(BackendAppSettingsStore.snapshotFile), "file"),
            ("state", "Projects and preferences", "Your project list, theme, default agent and window size.", env.userData.appendingPathComponent("state.json"), "file"),
            ("profiles", "Profiles", "The list of agent profiles. Logins themselves live in the OS keychain.", env.userData.appendingPathComponent("profiles.json"), "file"),
            ("profilesDir", "Profile folders", "One config directory per profile this app created.", env.userData.appendingPathComponent("profiles"), "folder"),
            ("logs", "Logs", "Crash and diagnostic logs written by the runtime.", env.logs, "folder"),
            ("ipcTrace", "Debug trace", "Every IPC call, recorded while Debug mode is on. Off by default.", env.trace, "file")
        ]
        return .array(entries.map { key, label, purpose, path, kind in .object([.init("key", .string(key)), .init("label", .string(label)),
            .init("purpose", .string(purpose)), .init("path", .string(path.path)), .init("kind", .string(kind)), .init("exists", .bool(FileManager.default.fileExists(atPath: path.path)))]) })
    }
    public static func repositoryURL(_ field: NativeRPCValue) -> String? {
        guard let original = field.string ?? field["url"].string, !original.isEmpty else { return nil }
        var text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expression = try? NSRegularExpression(pattern: "^(?:github:)?([\\w.-]+)/([\\w.-]+)$"),
           let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let owner = Range(found.range(at: 1), in: text), let repo = Range(found.range(at: 2), in: text) {
            return "https://github.com/\(text[owner])/\(text[repo])"
        }
        for (pattern, replacement) in [("^git\\+", ""), ("\\.git$", ""), ("^git://", "https://"), ("^ssh://git@", "https://"), ("^git@([^:]+):", "https://$1/")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.hasPrefix("https://") || text.hasPrefix("http://") ? text : nil
    }
    public static func clearBrowserData(_ env: BackendAppSettingsEnvironment) async -> NativeRPCValue {
        guard let browser = env.browser else { return .object([.init("cleared", .bool(false)), .init("message", .string("Native browsing-data clearing is unavailable until the app-owned Safari data service is connected."))]) }
        do {
            try await browser.clearStorageCacheAndAuthentication()
            return .object([.init("cleared", .bool(true)), .init("message", .string("Cookies, storage and cache for the browser tab are gone."))])
        } catch { return .object([.init("cleared", .bool(false)), .init("message", .string(error.localizedDescription))]) }
    }
    public static func clearIfNotPersisting(store: BackendAppSettingsStore, environment: BackendAppSettingsEnvironment) async -> NativeRPCValue {
        guard await store.value(BackendAppSettingsStore.browserPersistKey) == .bool(false) else {
            return .object([.init("cleared", .bool(false)), .init("message", .string("Browsing data is kept between runs."))])
        }
        return await clearBrowserData(environment)
    }
    @MainActor public static func openPath(_ key: NativeRPCValue, environment: BackendAppSettingsEnvironment) -> NativeRPCValue {
        func answer(_ opened: Bool, _ path: String?, _ message: String) -> NativeRPCValue {
            .object([.init("opened", .bool(opened)), .init("path", path.map(NativeRPCValue.string) ?? .null), .init("message", .string(message))])
        }
        guard let entry = paths(environment).elements?.first(where: { $0["key"] == key }), let path = entry["path"].string else { return answer(false, nil, "No such location.") }
        let file = URL(fileURLWithPath: path)
        if entry["kind"].string == "file" {
            guard FileManager.default.fileExists(atPath: path) else { return answer(false, path, "That file has not been written yet.") }
            NSWorkspace.shared.activateFileViewerSelecting([file]); return answer(true, path, "Revealed in your file manager.")
        }
        if !FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
            catch { return answer(false, path, "That folder does not exist yet.") }
        }
        return NSWorkspace.shared.open(file) ? answer(true, path, "Opened.") : answer(false, path, "Could not open that folder.")
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, store: BackendAppSettingsStore, environment env: BackendAppSettingsEnvironment) async throws -> [String] {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try context.require(channel == "settings:get" || channel == "settings:paths" || channel == "settings:about" ? "settings.read" : "settings.write")
                switch channel {
                case "settings:get": return await store.get()
                case "settings:set":
                    let stored = try await store.patch(context.argument(0, in: args)); await env.publish("settings:changed", stored); return stored
                case "settings:reset":
                    let stored = try await store.reset(); await env.publish("settings:changed", stored); return stored
                case "settings:paths": return paths(env)
                case "settings:open-path": return await openPath(context.argument(0, in: args), environment: env)
                case "settings:about": return try await env.about()
                default: return await clearBrowserData(env)
                }
            }
        }
        return channels
    }
}
