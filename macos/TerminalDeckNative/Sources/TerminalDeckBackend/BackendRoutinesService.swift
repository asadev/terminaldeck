import Foundation
import TerminalDeckNativeCore

/// Preserves index.ts's omitted/default runner versus explicit null distinction.
public enum BackendRoutinesRunnerSelection: Sendable {
    case automatic
    case disabled
    case provided(any BackendRoutinesRunner)
}

public struct BackendRoutinesServiceOptions: Sendable {
    public let userData: URL
    public let directory: URL?
    public let state: NativeStateStore?
    public let runner: BackendRoutinesRunnerSelection
    public let control: BackendRoutinesToolCaller?
    public let providers: (any BackendRoutinesLaunchEnvironmentProviding)?
    public let mcpConfig: @Sendable () -> String?
    public let copilotRoot: URL?
    public let actions: (any BackendRoutinesActionAppending)?
    public let sharedGit: BackendFileWatchService?
    public let files: BackendRoutinesFileWatchers?
    public let allowFolder: @Sendable (String) -> String?
    public let globalMaxRunsPerHour: @Sendable () -> Double
    public let now: @Sendable () -> Double
    public let wired: [String]
    public let seedFolder: (@Sendable () async -> String?)?
    public let launch: BackendRoutinesLaunch?
    public let model: String?
    public init(userData: URL = BackendRoutinesPaths.userData, directory: URL? = nil,
                state: NativeStateStore? = nil, runner: BackendRoutinesRunnerSelection = .automatic,
                control: BackendRoutinesToolCaller? = nil,
                providers: (any BackendRoutinesLaunchEnvironmentProviding)? = nil,
                mcpConfig: @escaping @Sendable () -> String? = { nil }, copilotRoot: URL? = nil,
                actions: (any BackendRoutinesActionAppending)? = nil, sharedGit: BackendFileWatchService? = nil,
                files: BackendRoutinesFileWatchers? = nil,
                allowFolder: @escaping @Sendable (String) -> String? = { _ in nil },
                globalMaxRunsPerHour: @escaping @Sendable () -> Double = { 60 },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                wired: [String] = [], seedFolder: (@Sendable () async -> String?)? = nil,
                launch: BackendRoutinesLaunch? = nil, model: String? = nil) {
        self.userData = userData; self.directory = directory; self.state = state; self.runner = runner
        self.control = control; self.providers = providers; self.mcpConfig = mcpConfig; self.copilotRoot = copilotRoot
        self.actions = actions; self.sharedGit = sharedGit; self.files = files; self.allowFolder = allowFolder
        self.globalMaxRunsPerHour = globalMaxRunsPerHour; self.now = now; self.wired = wired; self.seedFolder = seedFolder
        self.launch = launch; self.model = model
    }
}

/// index.ts assembly. Construct at boot, register channels, then start. The
/// caller must transfer exclusive ownership from Node before opening these stores.
public struct BackendRoutinesService: Sendable {
    public static let ceilingKey = "routines.maxRunsPerHour"
    public let engine: BackendRoutinesEngine
    public let store: BackendRoutinesStore
    public let runtime: BackendRoutinesRuntimeState
    public let api: BackendRoutinesAPI
    public let log: BackendRoutinesLogger
    public let actions: any BackendRoutinesActionAppending
    public let files: BackendRoutinesFileWatchers
    public let seedResult: BackendRoutinesSeedResult?
    public let seedingError: String?

    public static func create(options: BackendRoutinesServiceOptions = .init()) async -> BackendRoutinesService {
        let store = BackendRoutinesStore(directory: options.directory, userData: options.userData)
        let runtime = BackendRoutinesRuntimeState(userData: options.userData, now: options.now)
        let actions = options.actions ?? BackendRoutinesActionLog(userData: options.userData,
            now: { Date(timeIntervalSince1970: options.now() / 1_000) })
        let log = BackendRoutinesLogging.logger(using: actions)
        let files = options.files ?? BackendRoutinesFileWatchers()
        let folder: String?
        if let seedFolder = options.seedFolder { folder = await seedFolder() }
        else if let state = options.state {
            folder = BackendRoutinesDefaults.chooseSeedFolder(projects: await state.getProjects().compactMap { $0["path"].string },
                                                              stateRoot: options.userData.path)
        } else { folder = nil }
        var seedResult: BackendRoutinesSeedResult?, seedingError: String?
        do {
            // Defaults must be present before the engine's first reload.
            seedResult = try BackendRoutinesDefaults.seed(directory: store.directory, folder: folder,
                existing: { store.list().map(\.id) }, write: { _ = try store.saveText($0, text: $1) })
        } catch {
            seedingError = error.localizedDescription
            NSLog("[routines] could not write the default routines: %@", error.localizedDescription)
        }
        let runner: (any BackendRoutinesRunner)?
        switch options.runner {
        case .disabled: runner = nil
        case .provided(let supplied): runner = supplied
        case .automatic:
            runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: options.mcpConfig,
                copilotRoot: options.copilotRoot ?? URL(fileURLWithPath: BackendCopilotPaths(userData: options.userData.path).root),
                providers: options.providers, launch: options.launch, actions: actions, now: options.now, model: options.model))
        }
        let relay = BackendRoutinesSourceProblemRelay()
        let git: BackendRoutinesGitSources? = options.sharedGit.map { shared in
            BackendRoutinesGitSources(shared: shared,
                context: { _ in .init(caller: .internalEngine, ownerID: "native-routines-" + UUID().uuidString) },
                problem: { message in await relay.report(message) })
        }
        let watchGit: BackendRoutinesEngineOptions.WatchGit?
        if let git { watchGit = { folder, callback in git.watch(folder, onChange: callback) } }
        else { watchGit = nil }
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: log,
            runner: runner, control: options.control, allowFolder: options.allowFolder,
            globalMaxRunsPerHour: options.globalMaxRunsPerHour, now: options.now,
            watchFiles: { try files.watch($0, onChange: $1) }, watchGit: watchGit))
        relay.bind(engine)
        await engine.markSource("file-change", subscribed: true)
        await engine.markSource("git-change", subscribed: git != nil,
            note: git == nil ? "No git watch is wired in this process." : nil)
        for kind in options.wired where kind != "file-change" && kind != "git-change" {
            await engine.markSource(kind, subscribed: true)
        }
        return .init(engine: engine, store: store, runtime: runtime, api: BackendRoutinesAPI(engine: engine, store: store),
                     log: log, actions: actions, files: files, seedResult: seedResult, seedingError: seedingError)
    }

    public func start() async throws { try await engine.start() }
    public func stop() async { await engine.stop(); files.stop() }
}

/// Holds no engine strongly: the injected Git watcher callback cannot keep the
/// entire service alive after quit. Missing-source failures remain visible.
private final class BackendRoutinesSourceProblemRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: BackendRoutinesEngine?
    func bind(_ engine: BackendRoutinesEngine) { lock.withLock { self.engine = engine } }
    func report(_ message: String) async {
        let engine = lock.withLock { self.engine }
        await engine?.markSource("git-change", subscribed: false, note: message)
    }
}
