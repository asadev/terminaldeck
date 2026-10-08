import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendStaysFixedParityLatch {
    private var isStarted = false, opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = [], started: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        isStarted = true; let pending = started; started.removeAll(); pending.forEach { $0.resume() }
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() { isStarted = true; let pending = started; started.removeAll(); pending.forEach { $0.resume() } }
    func waitStarted() async { if isStarted { return }; await withCheckedContinuation { started.append($0) } }
    func release() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private actor BackendStaysFixedParityChanges {
    private var values: [String] = [], waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func changed(_ root: String) {
        values.append(root)
        let ready = waiting.filter { values.count >= $0.0 }; waiting.removeAll { values.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func count(_ expected: Int) async { if values.count >= expected { return }; await withCheckedContinuation { waiting.append((expected, $0)) } }
    var total: Int { values.count }
}
actor BackendStaysFixedParityDriver: BackendStaysFixedEngineRunning {
    nonisolated let home = BackendStaysFixedEngineHome(dir: URL(fileURLWithPath: "/fixture/staysfixed"),
        bin: URL(fileURLWithPath: "/fixture/staysfixed/bin/staysfixed.js"), version: "0.15.0", versionNote: "")
    private let gate: BackendStaysFixedParityLatch?
    private var good = false, acceptedRegression = false
    private(set) var checks = 0, ships: [Bool] = []
    init(gate: BackendStaysFixedParityLatch? = nil) { self.gate = gate }
    func cli(_ args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        let raw: NativeRPCValue
        switch args.first {
        case "doctor": raw = BackendStaysFixedFixtures.doctor
        case "init":
            if !args.contains("--dry-run") {
                do {
                    try Data("export default {}\n".utf8).write(to: URL(fileURLWithPath: cwd).appendingPathComponent("staysfixed.config.js"))
                    try Data(".staysfixed\n".utf8).write(to: URL(fileURLWithPath: cwd).appendingPathComponent(".gitignore"))
                } catch { return .init(code: 1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
            }
            raw = BackendStaysFixedFixtures.`init`.setting("written",
                BackendMemoryParsing.strings([cwd + "/staysfixed.config.js", cwd + "/.gitignore"]))
        case "ship":
            let force = args.contains("--force"); ships.append(force)
            if !good { good = true; raw = BackendStaysFixedFixtures.ship_cut }
            else if checks >= 2 && !acceptedRegression && !force { raw = BackendStaysFixedFixtures.ship_refused }
            else { acceptedRegression = true; raw = BackendStaysFixedFixtures.ship_forced }
        default: raw = .object([])
        }
        return .init(code: 0, stdout: raw.compact + "\n", stderr: "", timedOut: false, cancelled: false)
    }
    func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        if source == BackendStaysFixedScripts.describe {
            let reference: NativeRPCValue = good ? .object([.init("buildId", .string("known-build")), .init("version", .string("1.0.0")),
                .init("setAt", .string("2026-10-03T23:41:27Z")), .init("setBy", .string("staysfixed ship"))]) : .null
            let value = NativeRPCValue.object([.init("guards", .array([])), .init("guardProblem", .null), .init("reference", reference)])
            return .init(code: 0, stdout: value.compact + "\n", stderr: "", timedOut: false, cancelled: false)
        }
        checks += 1
        onEvent(.object([.init("type", .string("check:start")), .init("message", .string("Comparing."))]))
        if let gate { await gate.hold() }
        let raw = !good ? BackendStaysFixedFixtures.cli_check_cold : acceptedRegression ? BackendStaysFixedFixtures.cli_check_clean : BackendStaysFixedFixtures.cli_check_regression
        let folder = URL(fileURLWithPath: cwd).appendingPathComponent(".staysfixed/v2")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let envelope = NativeRPCValue.object([.init("at", raw["startedAt"]), .init("result", .string(raw.compact))])
            try envelope.encodedJSON().write(to: folder.appendingPathComponent("last-check.json"))
            // A fake successful run needs the same completed product evidence
            // as the bundled engine; its summary alone is not a baseline.
            let buildID = try raw["candidate"]["id"].requireString("fixture candidate id", nonempty: true)
            let captureFolder = folder.appendingPathComponent("builds/" + BackendStaysFixedRead.fileSafe(buildID) + "/receipt")
            try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
            let sample = BackendStaysFixedFixtures.cli_check_regression["findings"].elements?.first?["sample"] ?? .missing
            let cold = buildID == BackendStaysFixedFixtures.cli_check_cold["candidate"]["id"].string
            let output = sample[cold ? "reference" : "candidate"]
            _ = try output.requireString("captured command output", nonempty: true)
            let capture: [NativeRPCValue] = [
                .object([.init("kind", .string("capture"))]),
                .object([.init("path", sample["path"]), .init("channel", sample["channel"]),
                         .init("value", output), .init("meta", .object([.init("refused", .bool(false))]))]),
                .object([.init("kind", .string("end")), .init("count", .number(1))])
            ]
            try Data((capture.map(\.compact).joined(separator: "\n") + "\n").utf8)
                .write(to: captureFolder.appendingPathComponent(String(format: "%08d.jsonl", checks)))
        } catch { return .init(code: 1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
        return .init(code: 0, stdout: raw.compact + "\n", stderr: "", timedOut: false, cancelled: false)
    }
}
@MainActor final class BackendStaysFixedParityServiceTests: XCTestCase {
    private func temp() throws -> (root: URL, project: URL, data: URL, runtime: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-stays-service-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("tiny-greeter/.git"), withIntermediateDirectories: true)
        let root = try BackendFilesystemAuthority.canonical(url), project = root.appendingPathComponent("tiny-greeter")
        let executable = root.appendingPathComponent("runtime/bin/node")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable; never run\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (root, project, root.appendingPathComponent("userData"), executable.path)
    }
    private func make(_ f: (root: URL, project: URL, data: URL, runtime: String), driver: BackendStaysFixedParityDriver,
                      changed: BackendStaysFixedParityChanges? = nil, joined: BackendStaysFixedParityLatch? = nil) -> BackendStaysFixedService {
        BackendStaysFixedService(userData: f.data, home: f.root.path, executable: f.runtime, inheritedEnvironment: [:],
            locate: { driver.home }, loginPath: { "/usr/bin:/bin" }, changed: { root in await changed?.changed(root) },
            now: { 1_000 }, driverFactory: { _, _, _, _, _ in driver }, checkJoined: { _, _ in await joined?.signal() })
    }
    func testWholeSourceOwnerLoopThroughServiceWithFakePackage() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let driver = BackendStaysFixedParityDriver(), changes = BackendStaysFixedParityChanges(), service = make(f, driver: driver, changed: changes)
        let before = await service.status(f.project.path)
        XCTAssertEqual(before["available"].bool, true); XCTAssertEqual(before["setUp"].bool, false)
        XCTAssertEqual(before["agents"].bool, false); XCTAssertEqual(before["git"].bool, true)
        let setup = try await service.setup(f.project.path)
        XCTAssertEqual(setup["ok"].bool, true); XCTAssertTrue(setup["wrote"].elements?.contains(.string("staysfixed.config.js")) == true)
        let ready = await service.status(f.project.path)
        XCTAssertEqual(ready["setUp"].bool, true); XCTAssertEqual(ready["agents"].bool, true); XCTAssertEqual(ready["configFile"].string, "staysfixed.config.js")
        let unchecked = try await service.markGood(f.project.path, anyway: true)
        XCTAssertEqual(unchecked["marked"], .bool(false)); XCTAssertEqual(unchecked["refusedFor"], .string("unchecked"))
        let earlyShips = await driver.ships; XCTAssertEqual(earlyShips, [])
        let cold = try await service.check(f.project.path, by: "you")
        XCTAssertEqual(cold["verdict"].string, "not-compared"); let progress = await service.progress(f.project.path); XCTAssertEqual(progress, .null)
        XCTAssertNil(BackendSFXReferenceGuard.refusal(f.project.path), cold.compact)
        let cut = try await service.markGood(f.project.path, anyway: false); XCTAssertEqual(cut["marked"].bool, true)
        let good = await service.status(f.project.path); XCTAssertTrue(good["reference"]["name"].string?.hasPrefix("1.0.0") == true)
        let regression = try await service.check(f.project.path, by: "Hoot")
        XCTAssertEqual(regression["verdict"].string, "differences"); XCTAssertEqual(regression["differences"].elements?.count, 1)
        let difference = try XCTUnwrap(regression["differences"].elements?.first, "Expected regression evidence from the checked fixture")
        let change = try XCTUnwrap(difference["changes"].elements?.first, "Expected the receipt change; fail the test instead of indexing absent evidence")
        XCTAssertEqual(difference["changes"].elements?.count, 1); XCTAssertTrue(change["before"].string?.contains("Total: 10.00") == true)
        XCTAssertTrue(change["after"].string?.contains("Total: 10.0\n") == true); XCTAssertEqual(difference["needsPerson"].bool, true)
        XCTAssertNotNil(regression["unchanged"].string?.range(of: #"Everything else it looked at — \d+ things — is unchanged\."#, options: .regularExpression))
        let disk = await service.results(f.project.path); XCTAssertEqual(disk["verdict"].string, "differences")
        let refused = try await service.markGood(f.project.path, anyway: false)
        XCTAssertEqual(refused["marked"].bool, false); XCTAssertEqual(refused["refusedFor"].string, "differences")
        let accepted = try await service.markGood(f.project.path, anyway: true); XCTAssertEqual(accepted["marked"].bool, true)
        let clean = try await service.check(f.project.path, by: "you")
        XCTAssertEqual(clean["verdict"].string, "clean"); XCTAssertEqual(clean["differences"], .array([]))
        let source = try await service.projectSource()
        let composition = try BackendProjectToolComposition(source: source, userData: f.data,
            inheritedEnvironment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": f.root.appendingPathComponent("no-defaults.json").path])
        let launch = try await composition.prepare(provider: "claude", cwd: f.project.path, loginPath: "/usr/bin:/bin")
        XCTAssertEqual(launch?.arguments.first, "--mcp-config"); if let launch { await composition.abandon(launch.id) }
        _ = try await service.setAgents(f.project.path, on: false)
        let off = try await composition.prepare(provider: "claude", cwd: f.project.path, loginPath: "/usr/bin:/bin"); XCTAssertNil(off)
        _ = try await service.setAgents(f.project.path, on: true)
        let codex = try await composition.prepare(provider: "codex", cwd: f.project.path, loginPath: "/usr/bin:/bin"); XCTAssertNotNil(codex)
        if let codex { await composition.abandon(codex.id) }; await composition.stop(); await service.dispose()
    }
    func testProgressAndJoiningObservedWithoutSleepOrSchedulerGuesses() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("{}\n".utf8).write(to: f.project.appendingPathComponent("staysfixed.config.json"))
        let gate = BackendStaysFixedParityLatch(), joined = BackendStaysFixedParityLatch(), changes = BackendStaysFixedParityChanges()
        let driver = BackendStaysFixedParityDriver(gate: gate), service = make(f, driver: driver, changed: changes, joined: joined)
        let first = Task { try await service.check(f.project.path, by: "you") }
        await gate.waitStarted(); await changes.count(2)
        let running = await service.progress(f.project.path)
        XCTAssertEqual(running["step"].string, "Comparing."); XCTAssertGreaterThanOrEqual(running["steps"].number ?? 0, 1)
        let second = Task { try await service.check(f.project.path, by: "an AI app") }
        await joined.waitStarted(); await gate.release()
        let one = try await first.value, two = try await second.value
        XCTAssertEqual(one, two); let checks = await driver.checks; XCTAssertEqual(checks, 1)
        let total = await changes.total; XCTAssertGreaterThanOrEqual(total, 3)
        let progress = await service.progress(f.project.path); XCTAssertEqual(progress, .null); await service.dispose()
    }
}
