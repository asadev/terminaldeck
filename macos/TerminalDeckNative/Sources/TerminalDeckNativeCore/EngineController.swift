import Foundation
import Darwin
import Observation

/// Why the engine is not running, shown verbatim in the window.
public struct EngineFailure: Equatable, Sendable {
    public var title: String
    public var message: String
    /// Last lines the engine wrote to stderr, when it died without saying why.
    public var detail: String?
    /// Set when the fix is getting Terminal Deck: the window offers "Download Terminal Deck".
    public var downloadURL: URL?

    public init(title: String, message: String, detail: String?, downloadURL: URL? = nil) {
        self.title = title
        self.message = message
        self.detail = detail
        self.downloadURL = downloadURL
    }

    /// No usable Terminal Deck on this Mac, in plain words.
    public static func needsTerminalDeck(_ problem: EngineConfiguration.Problem) -> EngineFailure {
        let minimum = EngineConfiguration.minimumVersion
        switch problem {
        case .bundledEngine(let detail):
            return EngineFailure(title: "Terminal Deck couldn't start", message: detail, detail: nil)
        case .notInstalled:
            return EngineFailure(
                title: "Terminal Deck isn't installed",
                message: "Terminal Deck Native (Preview) runs on Terminal Deck \(minimum) or newer, and this Mac doesn't have it. Install Terminal Deck, then try again.",
                detail: nil, downloadURL: EngineConfiguration.downloadURL)
        case .tooOld(let found):
            return EngineFailure(
                title: "Terminal Deck needs an update",
                message: "This Mac has Terminal Deck \(found). Terminal Deck Native (Preview) needs \(minimum) or newer. Update Terminal Deck, then try again.",
                detail: nil, downloadURL: EngineConfiguration.downloadURL)
        }
    }
}

public enum EnginePhase: Equatable, Sendable {
    case idle
    case starting
    case ready(URL)
    case failed(EngineFailure)
}

/// A launched engine process plus the stdin pipe we hold open for it.
/// Closing that pipe (or SIGTERM) tells the engine to stop; if this app dies,
/// the kernel closes it for us, so the engine never outlives the shell.
final class EngineHandle: @unchecked Sendable {
    let process: Process
    private let stdinWriter: FileHandle
    private let stdoutReader: FileHandle
    private let stderrReader: FileHandle
    private let lock = NSLock()
    private var stdinClosed = false

    init(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdinWriter = stdin.fileHandleForWriting
        self.stdoutReader = stdout.fileHandleForReading
        self.stderrReader = stderr.fileHandleForReading
    }

    var pid: pid_t { process.processIdentifier }

    func closeStdin() {
        lock.lock(); defer { lock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinWriter.close()
    }

    func detachReaders() {
        stdoutReader.readabilityHandler = nil
        stderrReader.readabilityHandler = nil
    }

    /// Close stdin + SIGTERM, wait up to `grace` seconds, then SIGKILL. Blocking.
    func shutdown(grace: TimeInterval, log: EngineLog) {
        closeStdin()
        guard process.isRunning else { detachReaders(); return }
        let pid = self.pid
        log.note("stopping engine pid \(pid) (SIGTERM)")
        process.terminate() // SIGTERM
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            log.note("engine pid \(pid) still running after \(Int(grace)) s — SIGKILL")
            kill(pid, SIGKILL)
            let hardDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < hardDeadline { usleep(20_000) }
        } else {
            log.note("engine pid \(pid) stopped (exit \(process.terminationStatus))")
        }
        detachReaders()
        log.flush()
    }
}

/// Thread-safe line splitter for a pipe's readability handler.
private final class LockedLineBuffer: @unchecked Sendable {
    private var buffer = LineBuffer()
    private let lock = NSLock()
    func append(_ data: Data) -> [String] { lock.lock(); defer { lock.unlock() }; return buffer.append(data) }
    func flush() -> String? { lock.lock(); defer { lock.unlock() }; return buffer.flush() }
}

/// Keeps the last few stderr lines, to explain a crash that printed no TD_NATIVE_FAILED.
private final class StderrTail: @unchecked Sendable {
    private var buffer = LineBuffer()
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for line in buffer.append(data) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(line)
            if lines.count > 4 { lines.removeFirst() }
        }
    }
    var text: String? {
        lock.lock(); defer { lock.unlock() }
        var all = lines
        if let rest = buffer.flush(), !rest.trimmingCharacters(in: .whitespaces).isEmpty { all.append(rest) }
        return all.isEmpty ? nil : all.joined(separator: "\n")
    }
}

@MainActor
@Observable
public final class EngineController {
    public private(set) var phase: EnginePhase = .idle

    public private(set) var configuration: EngineConfiguration
    public let log: EngineLog
    /// How long the engine has to print its READY line (45 s in the app).
    @ObservationIgnored public let readyTimeout: Duration
    /// SIGTERM → SIGKILL grace period (3 s in the app).
    @ObservationIgnored public let stopGrace: TimeInterval

    /// Called once per launch when the engine prints its READY line.
    @ObservationIgnored public var onReady: ((URL) -> Void)?
    /// `.nativeOnly`: starts the in-process backend and its page bridge and
    /// returns the page URL. No process is spawned (night plan step 4, D14).
    @ObservationIgnored public var nativeStarter: (@MainActor () async throws -> URL)?

    @ObservationIgnored private var handle: EngineHandle?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var stderrTail = StderrTail()

    public init(configuration: EngineConfiguration,
                readyTimeout: Duration = EngineConfiguration.readyTimeout,
                stopGrace: TimeInterval = EngineConfiguration.stopGracePeriod) {
        self.configuration = configuration
        self.readyTimeout = readyTimeout
        self.stopGrace = stopGrace
        self.log = EngineLog(url: configuration.logFile)
    }

    /// An engine process we started is alive (or being waited on).
    public var isRunning: Bool { handle != nil }

    /// Look for the engine again (Terminal Deck may have been installed or updated
    /// since). Takes effect at the next start; the data folder and log stay the same.
    public func reconfigure(_ configuration: EngineConfiguration) {
        self.configuration = EngineConfiguration(source: configuration.source, dataRoot: self.configuration.dataRoot)
    }

    /// pid of the current engine, for diagnostics and tests.
    public var enginePID: pid_t? { handle?.pid }

    // MARK: Start

    public func start() {
        guard handle == nil else { return }
        generation += 1
        let gen = generation
        phase = .starting
        stderrTail = StderrTail()

        let config = configuration
        log.note("---- starting engine ----")
        log.note("engine: \(config.engineDescription)")

        let fm = FileManager.default
        let executable: URL
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
                    self?.handle(.ready(url), generation: gen)
                } catch {
                    guard let self, gen == self.generation, self.phase == .starting else { return }
                    self.fail(EngineFailure(title: "Terminal Deck couldn't start", message: error.localizedDescription, detail: nil))
                }
            }
            return
        case .unavailable(let problem):
            fail(.needsTerminalDeck(problem))
            return
        case .checkout(let repo):
            guard let binary = config.executable, fm.isExecutableFile(atPath: binary.path) else {
                fail(EngineFailure(
                    title: "Terminal Deck couldn't start",
                    message: "The engine isn't installed. Missing: \(config.executable?.path ?? "Electron")\nRun “npm install” in \(repo.path), then try again.",
                    detail: nil))
                return
            }
            executable = binary
        case .installedApp(let app, let binary, _):
            guard fm.isExecutableFile(atPath: binary.path) else {
                fail(EngineFailure(
                    title: "Terminal Deck couldn't start",
                    message: "Terminal Deck at \(app.path) is missing its program (\(binary.lastPathComponent)). Reinstall Terminal Deck, then try again.",
                    detail: nil, downloadURL: EngineConfiguration.downloadURL))
                return
            }
            executable = binary
        }
        do {
            try fm.createDirectory(at: config.engineDataDirectory, withIntermediateDirectories: true)
        } catch {
            fail(EngineFailure(
                title: "Terminal Deck couldn't start",
                message: "Couldn't create the engine's data folder at \(config.engineDataDirectory.path): \(error.localizedDescription)",
                detail: nil))
            return
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = config.arguments
        if let directory = config.workingDirectory { process.currentDirectoryURL = directory }
        process.environment = config.childEnvironment(from: ProcessInfo.processInfo.environment)

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let log = self.log
        let tail = stderrTail
        let lines = LockedLineBuffer()

        stderr.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            if data.isEmpty { reader.readabilityHandler = nil; return }
            log.append(data)
            tail.append(data)
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] reader in
            let data = reader.availableData
            var batch = lines.append(data)
            if data.isEmpty {
                reader.readabilityHandler = nil
                if let rest = lines.flush() { batch.append(rest) }
            }
            for line in batch {
                if let signal = EngineLineParser.parse(line) {
                    switch signal {
                    case .ready(let url):
                        log.line("TD_NATIVE_READY \(EngineLineParser.redacted(url))")
                    case .failed(let reason):
                        log.line("TD_NATIVE_FAILED \(reason)")
                    }
                    Task { @MainActor in self?.handle(signal, generation: gen) }
                } else {
                    log.line(line)
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in
                // Let any last stdout line (e.g. TD_NATIVE_FAILED) land first.
                try? await Task.sleep(for: .milliseconds(500))
                self?.engineExited(status: status, reason: reason, generation: gen)
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            fail(EngineFailure(
                title: "Terminal Deck couldn't start",
                message: "Couldn't launch the engine: \(error.localizedDescription)",
                detail: nil))
            return
        }

        handle = EngineHandle(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
        log.note("engine pid \(process.processIdentifier): \(executable.path) \(config.arguments.joined(separator: " "))")

        let timeout = readyTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.readyTimedOut(generation: gen)
        }
    }

    // MARK: Events

    private func handle(_ signal: EngineSignal, generation gen: Int) {
        guard gen == generation else { return }
        switch signal {
        case .ready(let url):
            guard phase == .starting else { return }
            timeoutTask?.cancel()
            log.note("engine ready at \(EngineLineParser.redacted(url))")
            phase = .ready(url)
            onReady?(url)
        case .failed(let reason):
            timeoutTask?.cancel()
            fail(EngineFailure(title: "Terminal Deck couldn't start", message: reason, detail: nil))
            stopInBackground()
        }
    }

    private func readyTimedOut(generation gen: Int) {
        guard gen == generation, phase == .starting else { return }
        fail(EngineFailure(
            title: "Terminal Deck couldn't start",
            message: "The engine didn't report ready within \(Int(readyTimeout.components.seconds)) seconds.",
            detail: stderrTail.text))
        stopInBackground()
    }

    private func engineExited(status: Int32, reason: Process.TerminationReason, generation gen: Int) {
        guard gen == generation else { return }
        handle?.detachReaders()
        handle = nil
        timeoutTask?.cancel()
        let how = reason == .uncaughtSignal ? "was killed by signal \(status)" : "exited with code \(status)"
        log.note("engine \(how)")
        switch phase {
        case .starting:
            fail(EngineFailure(
                title: "Terminal Deck couldn't start",
                message: "The engine \(how) before it was ready.",
                detail: stderrTail.text))
        case .ready:
            fail(EngineFailure(
                title: "Terminal Deck stopped",
                message: "The engine \(how) unexpectedly.",
                detail: stderrTail.text))
        case .failed, .idle:
            break // keep the engine's own reason
        }
    }

    private func fail(_ failure: EngineFailure) {
        log.note("failure: \(failure.message)")
        phase = .failed(failure)
    }

    // MARK: Stop

    /// Engines being stopped in the background; quitting finishes them synchronously.
    @ObservationIgnored private var dying: [EngineHandle] = []
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    /// "Try again": wait for any old engine to be fully gone (it may hold the
    /// data folder), then start a fresh one.
    public func restart() {
        timeoutTask?.cancel()
        stopInBackground()
        generation += 1
        phase = .starting
        let pending = shutdownTask
        Task { [weak self] in
            await pending?.value
            self?.start()
        }
    }

    /// Stops the engine without blocking the main thread (after a failure or before a restart).
    private func stopInBackground() {
        guard let old = handle else { return }
        handle = nil
        generation += 1
        dying.append(old)
        let log = self.log
        let grace = stopGrace
        let previous = shutdownTask
        shutdownTask = Task.detached { [weak self] in
            await previous?.value
            old.shutdown(grace: grace, log: log)
            await self?.forget(old)
        }
    }

    private func forget(_ old: EngineHandle) {
        dying.removeAll { $0 === old }
    }

    /// Leave the UI and native service actors responsive while the engine
    /// saves its ledger and drains its terminals during normal termination.
    public func stopAndWait() async {
        timeoutTask?.cancel()
        stopInBackground()
        if let task = shutdownTask { await task.value }
        log.flush()
    }

    /// Quit path: blocks until every engine we started is gone (at most ~4 s).
    /// Never leaves an orphan.
    public func stopNow() {
        timeoutTask?.cancel()
        generation += 1
        var all = dying
        if let current = handle { all.append(current) }
        handle = nil
        dying.removeAll()
        // Signal them all first so they stop in parallel, then wait on each.
        for engine in all { engine.closeStdin() }
        for engine in all { engine.shutdown(grace: stopGrace, log: log) }
        log.flush()
    }
}
