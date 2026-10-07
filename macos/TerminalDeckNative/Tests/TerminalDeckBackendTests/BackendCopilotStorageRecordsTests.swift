import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// These tests are written for the final combined macOS gate. They run the
/// existing launch resolver's actual Seatbelt profile, with positive controls,
/// from both the default cwd and a chosen cwd. No second fence implementation.
final class BackendCopilotStorageRecordsTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let paths: BackendCopilotPaths
        let chosen: String
        let profile: String
        let runner: BackendCommandRunner
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRecords-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // copilot-writable-boundary.test.ts:141 `realpathSync(mkdtempSync(...))`: the kernel path
        // (/private/var/...), which is what the Seatbelt profile names.
        let canonical = URL(fileURLWithPath: BackendMacConfinement.kernelPath(root.path)), data = canonical.appendingPathComponent("data")
        let paths = BackendCopilotPaths(userData: data.path), chosen = canonical.appendingPathComponent("chosen").path
        XCTAssertNil(BackendCopilotHome.scaffold(paths).error)
        for dir in [chosen, chosen + "/memory", data.path + "/routines", data.path + "/remote"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data("# their assistant\n".utf8).write(to: URL(fileURLWithPath: chosen + "/CLAUDE.md"))
        try Data("{\"action\":\"real\"}\n".utf8).write(to: URL(fileURLWithPath: paths.actions))
        try Data("{\"action\":\"older\"}\n".utf8).write(to: URL(fileURLWithPath: paths.actions + ".1"))
        try Data("{\"version\":1,\"routines\":{}}\n".utf8).write(to: data.appendingPathComponent("routine-state.json"))
        try Data("# existing routine\n".utf8).write(to: data.appendingPathComponent("routines/existing.md"))
        let runner = BackendCommandRunner()
        let confinement = try BackendMacConfinement(storageRoot: data.appendingPathComponent("remote"), appDataRoot: data,
            accountHome: canonical.path, inheritedEnvironment: [:], runner: runner)
        let account = BackendAccountLaunch(profile: nil, environment: [:], path: "/bin:/usr/bin")
        let launch = try await confinement.resolve(command: "/bin/echo", args: ["alive"], input: .init(cwd: paths.root),
            account: account, context: .init(appFenceID: BackendMacConfinement.recordsFenceID))
        XCTAssertEqual(launch.command, "/usr/bin/sandbox-exec")
        XCTAssertTrue(launch.enforcedBoundary)
        XCTAssertEqual(launch.args.first, "-p")
        return .init(root: canonical, paths: paths, chosen: chosen, profile: launch.args[1], runner: runner)
    }
    private func run(_ f: Fixture, cwd: String, script: String, arguments: [String]) async throws -> BackendCommandRunner.Result {
        try await f.runner.run(command: "/usr/bin/sandbox-exec", arguments: ["-p", f.profile, "/bin/sh", "-c", script, "fence-test"] + arguments,
            environment: ["PATH": "/bin:/usr/bin"], cwd: cwd, timeoutMilliseconds: 20_000)
    }
    private func contents(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    func testCanonicalFenceHasSevenRecordsAndNoDefaultOrChosenHomeDeny() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertTrue(f.profile.contains("(allow default)"))
        XCTAssertEqual(f.profile.components(separatedBy: "\n").filter { $0.hasPrefix("(deny ") }.count, 7)
        XCTAssertTrue(f.profile.contains(BackendMacConfinement.seatbeltString(f.paths.log)))
        XCTAssertFalse(f.profile.contains("(subpath " + BackendMacConfinement.seatbeltString(f.paths.root) + ")"))
        XCTAssertFalse(f.profile.contains("(subpath " + BackendMacConfinement.seatbeltString(f.chosen) + ")"))
        XCTAssertEqual(BackendCopilotPaths(userData: f.root.path + "/data", home: f.chosen).actions, f.paths.actions)
    }
    func testPositiveControlsAndAllLogTamperingAttemptsFromBothHomes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for cwd in [f.paths.root, f.chosen] {
            let positive = try await run(f, cwd: cwd, script: "printf remembered > memory/fact.md; cat memory/fact.md", arguments: [])
            XCTAssertTrue(positive.succeeded)
            XCTAssertTrue(positive.output.contains("remembered"))
            let attempts = ["printf forged >> \"$1\"", ": > \"$1\"", "rm -f \"$1\"", "sh -c 'printf forged >> \"$1\"' child \"$1\"", "cat \"$1\""]
            for script in attempts {
                let denied = try await run(f, cwd: cwd, script: script, arguments: [f.paths.actions])
                XCTAssertFalse(denied.succeeded, script)
                XCTAssertFalse(denied.output.contains("\"action\":\"real\""))
                XCTAssertEqual(try contents(f.paths.actions), "{\"action\":\"real\"}\n")
            }
            let rolled = try await run(f, cwd: cwd, script: "printf forged > \"$1\"", arguments: [f.paths.actions + ".1"])
            XCTAssertFalse(rolled.succeeded)
            XCTAssertEqual(try contents(f.paths.actions + ".1"), "{\"action\":\"older\"}\n")
            let moved = try await run(f, cwd: cwd, script: "mv \"$1\" \"$2\"", arguments: [f.paths.log, f.paths.log + "-old"])
            XCTAssertFalse(moved.succeeded)
            let linked = try await run(f, cwd: cwd, script: "ln -sfn \"$1\" escape; printf forged >> escape/actions.jsonl", arguments: [f.paths.log])
            XCTAssertFalse(linked.succeeded)
            XCTAssertEqual(try contents(f.paths.actions), "{\"action\":\"real\"}\n")
        }
    }
    func testRoutineAndBudgetWritesDeniedWhileProjectWritesRemainAllowed() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let routine = f.root.path + "/data/routines", state = f.root.path + "/data/routine-state.json"
        let project = f.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: project.appendingPathComponent("index.swift"))
        for cwd in [f.paths.root, f.chosen] {
            let positive = try await run(f, cwd: cwd, script: "printf touched >> \"$1\"", arguments: [project.appendingPathComponent("index.swift").path])
            XCTAssertTrue(positive.succeeded)
            let denied = try await run(f, cwd: cwd, script: "printf '# Mine' > \"$1/new.md\"", arguments: [routine])
            XCTAssertFalse(denied.succeeded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: routine + "/new.md"))
            let nested = try await run(f, cwd: cwd, script: "mkdir -p \"$1/nested\"", arguments: [routine])
            XCTAssertFalse(nested.succeeded)
            let stateWrite = try await run(f, cwd: cwd, script: "printf forged > \"$1\"", arguments: [state])
            XCTAssertFalse(stateWrite.succeeded)
            XCTAssertEqual(try contents(state), "{\"version\":1,\"routines\":{}}\n")
            let link = try await run(f, cwd: cwd, script: "ln -sfn \"$1\" routine-link; printf forged > routine-link/linked.md", arguments: [routine])
            XCTAssertFalse(link.succeeded)
            let child = try await run(f, cwd: cwd, script: "sh -c 'printf forged > \"$1\"' child \"$1/grandchild.md\"", arguments: [routine])
            XCTAssertFalse(child.succeeded)
        }
        let own = try await run(f, cwd: f.chosen, script: "cat CLAUDE.md", arguments: [])
        XCTAssertTrue(own.succeeded); XCTAssertTrue(own.output.contains("their assistant"))
        let legacy = try await run(f, cwd: f.paths.root, script: "mkdir -p log; printf invented > log/actions.jsonl", arguments: [])
        XCTAssertTrue(legacy.succeeded)
        XCTAssertEqual(try contents(f.paths.actions), "{\"action\":\"real\"}\n")
    }
}
