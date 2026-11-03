import Foundation

/// Where the app's pages come from, and where it keeps its data.
///
/// The app is Node-free: its backend runs in process and its pages are served
/// by the native bridge from the bundle's own resources (night plan step 4, D14).
/// A copy without those resources (a bare developer run) says so instead.
public struct EngineConfiguration: Equatable, Sendable {
    /// Test runs only: a separate data folder, so a check never touches the real preview's data or log.
    public static let dataEnvironmentKey = NativeLaunchSwitches.dataFolder
    /// A copy without its pages keeps the old preview folder, never the app's own data.
    public static let dataFolderName = "Terminal Deck Native Proof"

    public static let appBundleID = "dev.terminaldeck.app"

    public enum Source: Equatable, Sendable {
        /// The Node-free native app: its backend runs in process and its web
        /// pages are served by the native bridge (night plan step 4, D14).
        case nativeOnly(NativeWebAssets)
        /// It cannot run here: say so, plainly.
        case unavailable(Problem)
    }

    public enum Problem: Equatable, Sendable {
        case bundledEngine(String)
    }

    public let source: Source
    /// `~/Library/Application Support/terminaldeck` for the app.
    public let dataRoot: URL

    public init(source: Source, dataRoot: URL) {
        self.source = source
        self.dataRoot = dataRoot
    }

    /// The bundle's pages when it has them; otherwise what is wrong, so the window can say it.
    public static func resolve(environment: [String: String], applicationSupport: URL, resources: URL?) -> EngineConfiguration {
        var dataRoot = applicationSupport.appendingPathComponent(resources == nil ? dataFolderName : "terminaldeck", isDirectory: true)
        if let custom = environment[dataEnvironmentKey]?.trimmingCharacters(in: .whitespaces), custom.hasPrefix("/") {
            dataRoot = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        }
        guard let resources else {
            return EngineConfiguration(source: .unavailable(.bundledEngine("This copy was built without its pages. Open the Terminal Deck app instead.")), dataRoot: dataRoot)
        }
        do {
            return EngineConfiguration(source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: dataRoot)
        } catch {
            return EngineConfiguration(source: .unavailable(.bundledEngine(error.localizedDescription)), dataRoot: dataRoot)
        }
    }

    /// For the log.
    public var engineDescription: String {
        switch source {
        case .nativeOnly: "native backend in this app (no Node engine)"
        case .unavailable(.bundledEngine(let detail)): "none — \(detail)"
        }
    }

    public var engineDataDirectory: URL { dataRoot }

    public var logFile: URL {
        dataRoot.appendingPathComponent("engine.log", isDirectory: false)
    }
}
