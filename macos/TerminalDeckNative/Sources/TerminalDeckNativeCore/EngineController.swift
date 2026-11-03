import Foundation
import Observation

/// Why the engine is not running, shown verbatim in the window.
public struct EngineFailure: Equatable, Sendable {
    public var title: String
    public var message: String
    /// More text shown under the message, when there is any.
    public var detail: String?

    public init(title: String, message: String, detail: String?) {
        self.title = title
        self.message = message
        self.detail = detail
    }

    /// This copy cannot run its backend, in plain words.
    public static func needsTerminalDeck(_ problem: EngineConfiguration.Problem) -> EngineFailure {
        switch problem {
        case .bundledEngine(let detail):
            return EngineFailure(title: "Terminal Deck couldn't start", message: detail, detail: nil)
        }
    }
}

public enum EnginePhase: Equatable, Sendable {
    case idle
    case starting
    case ready(URL)
    case failed(EngineFailure)
}

/// The app's backend lifecycle. The Node-free app assembles its backend in
/// process and its pages come from the native bridge; nothing is spawned (D14).
@MainActor
@Observable
public final class EngineController {
    public private(set) var phase: EnginePhase = .idle

    public private(set) var configuration: EngineConfiguration
    public let log: EngineLog

    /// Called once per start when the backend's pages are ready.
    @ObservationIgnored public var onReady: ((URL) -> Void)?
    /// `.nativeOnly`: starts the in-process backend and its page bridge and
    /// returns the page URL. No process is spawned (night plan step 4, D14).
    @ObservationIgnored public var nativeStarter: (@MainActor () async throws -> URL)?

    @ObservationIgnored private var generation = 0

    public init(configuration: EngineConfiguration) {
        self.configuration = configuration
        self.log = EngineLog(url: configuration.logFile)
    }

    /// Take a changed configuration at the next start; the data folder and log stay the same.
    public func reconfigure(_ configuration: EngineConfiguration) {
        self.configuration = EngineConfiguration(source: configuration.source, dataRoot: self.configuration.dataRoot)
    }

    // MARK: Start

    public func start() {
        generation += 1
        let gen = generation
        phase = .starting

        let config = configuration
        log.note("---- starting engine ----")
        log.note("engine: \(config.engineDescription)")

        switch config.source {
        case .nativeOnly:
            guard let starter = nativeStarter else {
                fail(EngineFailure(title: "Terminal Deck couldn't start", message: "The native backend was not assembled.", detail: nil))
                return
            }
            log.note("native backend: no engine process")
            Task { [weak self] in
                do {
                    let url = try await starter()
                    self?.ready(url, generation: gen)
                } catch {
                    guard let self, gen == self.generation, self.phase == .starting else { return }
                    self.fail(EngineFailure(title: "Terminal Deck couldn't start", message: error.localizedDescription, detail: nil))
                }
            }
        case .unavailable(let problem):
            fail(.needsTerminalDeck(problem))
        }
    }

    // MARK: Events

    private func ready(_ url: URL, generation gen: Int) {
        guard gen == generation, phase == .starting else { return }
        log.note("engine ready at \(EngineLineParser.redacted(url))")
        phase = .ready(url)
        onReady?(url)
    }

    private func fail(_ failure: EngineFailure) {
        log.note("failure: \(failure.message)")
        phase = .failed(failure)
    }

    // MARK: Stop

    /// "Try again": start afresh.
    public func restart() {
        generation += 1
        phase = .starting
        Task { [weak self] in self?.start() }
    }

    /// Nothing runs outside this app: only the log needs writing out.
    public func stopAndWait() async {
        log.flush()
    }

    /// Quit path: never waits.
    public func stopNow() {
        generation += 1
        log.flush()
    }
}
