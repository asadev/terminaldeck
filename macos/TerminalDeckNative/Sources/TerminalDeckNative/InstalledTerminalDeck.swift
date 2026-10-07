import AppKit
import TerminalDeckNativeCore

/// Finds the Terminal Deck app on this Mac — every copy LaunchServices knows by its
/// bundle id, plus /Applications — and picks the newest (EngineConfiguration.bestInstalled).
@MainActor
enum InstalledTerminalDeck {
    static func find() -> InstalledApp? {
        var urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: EngineConfiguration.appBundleID)
        let fallback = URL(fileURLWithPath: EngineConfiguration.fallbackAppPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: fallback.path), !urls.contains(where: { $0.standardizedFileURL == fallback.standardizedFileURL }) {
            urls.append(fallback)
        }
        return EngineConfiguration.bestInstalled(urls.map(read))
    }

    /// Read straight from Info.plist (Bundle caches, and Terminal Deck may have just been updated).
    private static func read(_ app: URL) -> InstalledApp {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return InstalledApp(url: app,
                            version: info?["CFBundleShortVersionString"] as? String,
                            executableName: info?["CFBundleExecutable"] as? String)
    }

    /// Where the engine comes from right now.
    static func configuration() -> EngineConfiguration {
        let standalone = Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true
        return EngineConfiguration.resolve(
            environment: ProcessInfo.processInfo.environment,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            home: NSHomeDirectory(),
            installed: standalone ? nil : find(),
            resources: standalone ? Bundle.main.resourceURL : nil)
    }
}
