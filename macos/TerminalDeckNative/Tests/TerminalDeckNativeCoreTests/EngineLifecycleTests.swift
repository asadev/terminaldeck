import Foundation
import Darwin
import Testing
@testable import TerminalDeckNativeCore

/// Drives the real EngineController against a fake "Electron" shell script:
/// real process, real pipes, real signals — no GUI, no real engine.
@MainActor
@Suite("Engine lifecycle (fake engine)")
struct EngineLifecycleTests {

    /// A throwaway repo whose node_modules/…/Electron is a bash script that
    /// behaves according to the `mode` file next to it.
    final class FakeRepo {
        let root: URL
        let repo: URL
        let dataRoot: URL

        static let script = #"""
        #!/bin/bash
        repo="$1"
        printf '%s\n' "$@" > "$repo/args"
        case "$(cat "$repo/mode")" in
          ready)
            echo "booting"
            echo "TD_NATIVE_READY http://127.0.0.1:4567/?t=SECRETTOKEN"
            cat > /dev/null          # run until our stdin closes
            echo "stdin closed, bye" >&2
            exit 0 ;;
          fail)
            echo "TD_NATIVE_FAILED port 4567 is already in use"
            exit 3 ;;
          crash)
            echo "boom: renderer bundle missing" >&2
            exit 7 ;;
          die-after-ready)
            echo "TD_NATIVE_READY http://127.0.0.1:4567/?t=x"
            sleep 0.3
            exit 9 ;;
          silent)
            exec sleep 30 ;;
          stubborn)
            trap '' TERM
            exec 0<&-
            echo "TD_NATIVE_READY http://127.0.0.1:4567/?t=x"
            while :; do sleep 0.1; done ;;
        esac
        """#

        init(mode: String, installEngine: Bool = true) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("tdn-test-\(UUID().uuidString)", isDirectory: true)
            repo = root.appendingPathComponent("repo", isDirectory: true)
            dataRoot = root.appendingPathComponent("support", isDirectory: true)
            try fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try mode.write(to: repo.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            if installEngine {
                let bin = EngineConfiguration(repo: repo, dataRoot: dataRoot).executable!
                try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.script.write(to: bin, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            }
        }

        var configuration: EngineConfiguration { EngineConfiguration(repo: repo, dataRoot: dataRoot) }

        func logText() -> String {
            (try? String(contentsOf: configuration.logFile, encoding: .utf8)) ?? ""
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    @discardableResult
    func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func failure(of engine: EngineController) -> EngineFailure? {
        if case .failed(let f) = engine.phase { return f }
        return nil
    }

    // MARK: Tests

    @Test func readyThenQuitLeavesNoOrphan() async throws {
        let repo = try FakeRepo(mode: "ready")
        let engine = EngineController(configuration: repo.configuration)
        var readyURL: URL?
        engine.onReady = { readyURL = $0 }

        engine.start()
        #expect(await waitUntil { engine.phase != .starting })
        let expected = try #require(URL(string: "http://127.0.0.1:4567/?t=SECRETTOKEN"))
        #expect(engine.phase == .ready(expected))
        #expect(readyURL == expected)

        // Launched exactly per contract.
        let args = try String(contentsOf: repo.repo.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(args == [repo.repo.path, "--native-shell", "--user-data-dir=\(repo.dataRoot.path)/engine"])

        let pid = try #require(engine.enginePID)
        #expect(Self.isAlive(pid))
        engine.stopNow()
        #expect(!engine.isRunning)
        #expect(await waitUntil(.seconds(2)) { !Self.isAlive(pid) })

        let log = repo.logText()
        #expect(log.contains("booting"))
        #expect(log.contains("TD_NATIVE_READY http://127.0.0.1:4567/?…"))
        #expect(!log.contains("SECRETTOKEN"), "the bridge token must never be logged")
    }

    @Test func closingTheHeldStdinStopsTheEngine() async throws {
        // What happens if the shell itself dies: the kernel closes our end of stdin.
        let repo = try FakeRepo(mode: "ready")
        let process = Process()
        process.executableURL = repo.configuration.executable
        process.arguments = repo.configuration.arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let handle = EngineHandle(process: process, stdin: stdin, stdout: stdout, stderr: stderr)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(process.isRunning)
        handle.closeStdin() // no signal sent
        #expect(await waitUntil(.seconds(2)) { !process.isRunning })
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
    }

    @Test func failedLineShowsTheEnginesExactReason() async throws {
        let repo = try FakeRepo(mode: "fail")
        let engine = EngineController(configuration: repo.configuration)
        engine.start()
        #expect(await waitUntil { failure(of: engine) != nil })
        // The process exit (code 3) lands afterwards and must not replace the reason.
        try? await Task.sleep(for: .milliseconds(900))
        #expect(failure(of: engine)?.message == "port 4567 is already in use")
        #expect(!engine.isRunning)
    }

    @Test func crashBeforeReadyReportsExitCodeAndStderr() async throws {
        let repo = try FakeRepo(mode: "crash")
        let engine = EngineController(configuration: repo.configuration)
        engine.start()
        #expect(await waitUntil { failure(of: engine) != nil })
        let failure = try #require(failure(of: engine))
        #expect(failure.message == "The engine exited with code 7 before it was ready.")
        #expect(failure.detail?.contains("boom: renderer bundle missing") == true)
    }

    @Test func dyingAfterReadyIsReported() async throws {
        let repo = try FakeRepo(mode: "die-after-ready")
        let engine = EngineController(configuration: repo.configuration)
        engine.start()
        #expect(await waitUntil { if case .ready = engine.phase { return true }; return false })
        #expect(await waitUntil { failure(of: engine) != nil })
        #expect(failure(of: engine)?.title == "Terminal Deck stopped")
        #expect(failure(of: engine)?.message == "The engine exited with code 9 unexpectedly.")
    }

    @Test func silentEngineTimesOutAndIsStopped() async throws {
        let repo = try FakeRepo(mode: "silent")
        let engine = EngineController(configuration: repo.configuration, readyTimeout: .seconds(1), stopGrace: 1)
        engine.start()
        let pid = try #require(engine.enginePID)
        #expect(await waitUntil(.seconds(4)) { failure(of: engine) != nil })
        #expect(failure(of: engine)?.message == "The engine didn't report ready within 1 seconds.")
        #expect(await waitUntil(.seconds(3)) { !Self.isAlive(pid) })
    }

    @Test func stubbornEngineIsKilledAfterTheGracePeriod() async throws {
        let repo = try FakeRepo(mode: "stubborn")
        let engine = EngineController(configuration: repo.configuration, stopGrace: 1)
        engine.start()
        #expect(await waitUntil { if case .ready = engine.phase { return true }; return false })
        let pid = try #require(engine.enginePID)

        let started = ContinuousClock.now
        engine.stopNow() // ignores stdin and SIGTERM → SIGKILL after 1 s
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(900) && took < .seconds(3), "took \(took)")
        #expect(await waitUntil(.seconds(1)) { !Self.isAlive(pid) })
        #expect(repo.logText().contains("SIGKILL"))
    }

    @Test func tryAgainReplacesTheEngine() async throws {
        let repo = try FakeRepo(mode: "ready")
        let engine = EngineController(configuration: repo.configuration)
        engine.start()
        #expect(await waitUntil { if case .ready = engine.phase { return true }; return false })
        let first = try #require(engine.enginePID)

        engine.restart()
        #expect(engine.phase == .starting)
        #expect(await waitUntil { if case .ready = engine.phase { return engine.enginePID != first }; return false })
        #expect(await waitUntil(.seconds(2)) { !Self.isAlive(first) })
        let second = try #require(engine.enginePID)
        engine.stopNow()
        #expect(await waitUntil(.seconds(2)) { !Self.isAlive(second) })
    }

    @Test func missingEngineSaysHowToFixIt() async throws {
        let repo = try FakeRepo(mode: "ready", installEngine: false)
        let engine = EngineController(configuration: repo.configuration)
        engine.start()
        let failure = try #require(failure(of: engine))
        #expect(failure.message.contains("isn't installed"))
        #expect(failure.message.contains("npm install"))
        #expect(!engine.isRunning)
    }
}
