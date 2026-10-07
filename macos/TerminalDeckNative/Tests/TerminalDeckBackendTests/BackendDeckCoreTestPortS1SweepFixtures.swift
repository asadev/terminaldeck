import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// index.test.ts:397's `ensureCopilot` deps: the session starter records the
/// extra arguments the copilot is launched with; nothing is spawned.
actor BackendDeckCoreTestPortS1SweepHootDriver: BackendCopilotSessionDriving {
    private let configDir: String
    private var calls: [[String]] = []
    private var alive: Set<String> = []
    init(root: URL) { configDir = root.appendingPathComponent(".claude", isDirectory: true).path }
    func hasClaude() async throws -> Bool { true }
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        BackendAccountProfile(id: "system", name: "Default", provider: "claude", configDir: configDir, system: true, color: "#000000",
            createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { ("unknown", nil, nil) }
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        calls.append(extraArguments)
        let meta = BackendSessionMeta(id: "copilot-1", input: input,
            spawn: .init(provider: "claude", command: "/bin/echo", args: extraArguments, path: "/bin"), now: Date(timeIntervalSince1970: 1))
        alive.insert(meta.id); return meta
    }
    func isAlive(_ sessionID: String) async -> Bool { alive.contains(sessionID) }
    func stop(_ sessionID: String) async throws { alive.remove(sessionID) }
    func launches() -> [[String]] { calls }
}

/// `fence: async () => ({ fence: null, reason: 'not measured here' })`.
struct BackendDeckCoreTestPortS1SweepHootRecords: BackendCopilotSessionRecordsProviding {
    let records: BackendCopilotLayerRecords
    init(_ root: URL) throws {
        records = try .init(paths: ["routines", "routine-state.json", "copilot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json",
            "remote/access-keys.json", "plugin-grants.json"].map { root.appendingPathComponent($0).path })
    }
    func paths(userData: String) async throws -> BackendCopilotLayerRecords { records }
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement { .init(fence: nil, reason: "not measured here") }
}

/// A scripted `git` over a real folder, in place of live-surface.test.ts's real
/// `git init`: a repository is a folder holding `.git` (what `git init` leaves),
/// and `status --porcelain=v2 --branch -z` names the files actually in it as
/// untracked, the way git answers on an unborn branch. Anything asked of a
/// folder without `.git` gets git's own refusal. No process is launched.
final class BackendDeckCoreTestPortS1SweepGit: BackendGitExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    var calls: [[String]] { lock.withLock { seen } }
    func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool,
             timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        lock.withLock { seen.append(arguments) }
        func ok(_ stdout: String) -> BackendGitOutcome { .init(ok: true, stdout: stdout, stderr: "", missing: false, exitCode: 0, timedOut: false) }
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent(".git").path) else {
            return .init(ok: false, stdout: "", stderr: "fatal: not a git repository (or any of the parent directories): .git\n",
                missing: false, exitCode: 128, timedOut: false)
        }
        switch arguments.first {
        case "rev-parse": return ok(cwd + "\n")
        case "status":
            let names = try FileManager.default.contentsOfDirectory(atPath: cwd).filter { $0 != ".git" }.sorted()
            return ok((["# branch.oid (initial)", "# branch.head main"] + names.map { "? " + $0 }).map { $0 + "\0" }.joined())
        case "diff": return ok("")
        default: return .init(ok: false, stdout: "", stderr: "fatal: unexpected git call in this port", missing: false, exitCode: 129, timedOut: false)
        }
    }
}

/// The git cases never reach alerts (live-surface.test.ts:428 is not ported; see S1i.md).
struct BackendDeckCoreTestPortS1SweepNoAlerts: BackendDeckCoreProjectAlertsReading {
    func deckCoreProjectAlerts(_ projectPath: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        throw BackendSessionFailure.missingCapability("project alerts (child processes) in this port")
    }
}
