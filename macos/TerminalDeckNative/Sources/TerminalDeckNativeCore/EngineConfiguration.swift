import Foundation

/// Which program runs as the engine, and where the preview keeps its own data
/// (never Terminal Deck's own data folder).
///
/// By default the engine is the Terminal Deck app installed on this Mac, started
/// windowless with `--native-shell` (0.18.7 is the first release that has it).
/// A developer can point `TD_REPO` at a code checkout instead.
public struct EngineConfiguration: Equatable, Sendable {
    public static let repoEnvironmentKey = "TD_REPO"
    /// Test runs only: a separate data folder, so a check never touches the real preview's data or log.
    public static let dataEnvironmentKey = "TD_NATIVE_DATA_DIR"
    /// Unchanged since the proof, so existing state survives.
    public static let dataFolderName = "Terminal Deck Native Proof"
    public static let readyTimeout: Duration = .seconds(45)
    public static let stopGracePeriod: TimeInterval = 3

    public static let appBundleID = "dev.terminaldeck.app"
    public static let fallbackAppPath = "/Applications/Terminal Deck.app"
    /// The first Terminal Deck release that can run as the engine. 0.18.8: every screen
    /// is native and leans on page commands and engine channels that 0.18.7 doesn't have.
    public static let minimumVersion = AppVersion("0.18.8")!
    public static let downloadURL = URL(string: "https://terminaldeck.dev/download.html")!

    public enum Source: Equatable, Sendable {
        /// The installed Terminal Deck app.
        case installedApp(app: URL, executable: URL, version: String)
        /// A code checkout (developer override, `TD_REPO`).
        case checkout(repo: URL)
        /// No usable Terminal Deck: say so, plainly.
        case unavailable(Problem)
    }

    public enum Problem: Equatable, Sendable {
        case notInstalled
        case tooOld(found: String)
    }

    public let source: Source
    /// `~/Library/Application Support/Terminal Deck Native Proof`
    public let dataRoot: URL

    public init(source: Source, dataRoot: URL) {
        self.source = source
        self.dataRoot = dataRoot
    }

    /// A code checkout (tests and the developer override).
    public init(repo: URL, dataRoot: URL) {
        self.init(source: .checkout(repo: repo), dataRoot: dataRoot)
    }

    // MARK: Choosing the engine

    /// `TD_REPO` set → that checkout. Otherwise the installed Terminal Deck, if it is
    /// new enough; otherwise what is wrong, so the window can say it.
    public static func resolve(environment: [String: String], applicationSupport: URL, home: String,
                               installed: InstalledApp?) -> EngineConfiguration {
        var dataRoot = applicationSupport.appendingPathComponent(dataFolderName, isDirectory: true)
        if let custom = environment[dataEnvironmentKey]?.trimmingCharacters(in: .whitespaces), custom.hasPrefix("/") {
            dataRoot = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        }

        if var repoPath = environment[repoEnvironmentKey]?.trimmingCharacters(in: .whitespaces), !repoPath.isEmpty {
            if repoPath == "~" {
                repoPath = home
            } else if repoPath.hasPrefix("~/") {
                repoPath = home + repoPath.dropFirst(1)
            }
            let repo = URL(fileURLWithPath: repoPath, isDirectory: true).standardizedFileURL
            return EngineConfiguration(source: .checkout(repo: repo), dataRoot: dataRoot)
        }

        guard let installed else {
            return EngineConfiguration(source: .unavailable(.notInstalled), dataRoot: dataRoot)
        }
        let found = installed.version ?? "an unknown version"
        guard let version = installed.version.flatMap(AppVersion.init), version >= minimumVersion else {
            return EngineConfiguration(source: .unavailable(.tooOld(found: found)), dataRoot: dataRoot)
        }
        let executable = installed.url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(installed.executableName ?? "Terminal Deck", isDirectory: false)
        return EngineConfiguration(source: .installedApp(app: installed.url, executable: executable, version: found),
                                   dataRoot: dataRoot)
    }

    /// Of every copy LaunchServices knows (and the usual path), the newest one —
    /// never one sitting in the Trash.
    public static func bestInstalled(_ candidates: [InstalledApp]) -> InstalledApp? {
        let usable = candidates.filter { !$0.url.path.contains("/.Trash/") }
        return usable.max { a, b in
            let va = a.version.flatMap(AppVersion.init), vb = b.version.flatMap(AppVersion.init)
            switch (va, vb) {
            case let (x?, y?): return x < y
            case (nil, _?): return true
            default: return false
            }
        }
    }

    // MARK: Running it

    /// The program to start; nil when there is none to start.
    public var executable: URL? {
        switch source {
        case .installedApp(_, let executable, _): executable
        case .checkout(let repo):
            repo.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron", isDirectory: false)
        case .unavailable: nil
        }
    }

    /// Installed: `Terminal Deck --native-shell --user-data-dir=<dir>`.
    /// Checkout: `Electron $REPO --native-shell --user-data-dir=<dir>`.
    public var arguments: [String] {
        let shared = ["--native-shell", "--user-data-dir=\(engineDataDirectory.path)"]
        switch source {
        case .installedApp: return shared
        case .checkout(let repo): return [repo.path] + shared
        case .unavailable: return []
        }
    }

    public var workingDirectory: URL? {
        if case .checkout(let repo) = source { return repo }
        return nil
    }

    /// For the log.
    public var engineDescription: String {
        switch source {
        case .installedApp(let app, _, let version): "installed Terminal Deck \(version) at \(app.path)"
        case .checkout(let repo): "code checkout at \(repo.path) (TD_REPO)"
        case .unavailable(.notInstalled): "none — Terminal Deck is not installed"
        case .unavailable(.tooOld(let found)): "none — Terminal Deck \(found) is older than \(Self.minimumVersion)"
        }
    }

    public var engineDataDirectory: URL {
        dataRoot.appendingPathComponent("engine", isDirectory: true)
    }

    public var logFile: URL {
        dataRoot.appendingPathComponent("engine.log", isDirectory: false)
    }

    /// The engine inherits our environment, minus anything that would turn
    /// Electron into plain Node instead of the app.
    public static func childEnvironment(from parent: [String: String]) -> [String: String] {
        var env = parent
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        return env
    }
}

/// A Terminal Deck copy found on this Mac.
public struct InstalledApp: Equatable, Sendable {
    public let url: URL
    /// CFBundleShortVersionString
    public let version: String?
    /// CFBundleExecutable
    public let executableName: String?

    public init(url: URL, version: String?, executableName: String?) {
        self.url = url
        self.version = version
        self.executableName = executableName
    }
}

/// A release number like 0.18.7 (a pre-release such as 0.18.7-beta.2 sorts before 0.18.7).
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        var pre: String?
        if let dash = core.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            if core[dash] == "-" { pre = String(core[core.index(after: dash)...]).components(separatedBy: "+")[0] }
            core = String(core[..<dash])
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = numbers.map { $0! }
        prerelease = pre.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for i in 0..<count {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public var description: String {
        parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }
}
