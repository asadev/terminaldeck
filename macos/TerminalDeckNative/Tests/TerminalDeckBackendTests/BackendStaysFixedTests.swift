import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendStaysFixedTests: XCTestCase {
    func testCapturedColdRegressionCleanAndWebResults() {
        let cold = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_cold)
        XCTAssertEqual(cold["verdict"], .string("not-compared")); XCTAssertEqual(cold["unchanged"], .string("")); XCTAssertEqual(cold["against"], .null)
        let reg = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_regression)
        XCTAssertEqual(reg["verdict"], .string("differences")); XCTAssertEqual(reg["headline"], .string("1 difference nobody asked for."))
        let first = reg["differences"].elements![0]
        XCTAssertEqual(first["needsPerson"], .bool(true)); XCTAssertTrue(first["needsPersonWhy"].string!.contains("money")); XCTAssertFalse(first["title"].string!.contains("\\n"))
        XCTAssertEqual(first["changes"].elements![0]["before"], .string("Hello, --help!\nTotal: 10.00\n"))
        XCTAssertEqual(reg["unchanged"], .string("Everything else it looked at — 11 things — is unchanged."))
        let clean = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_clean)
        XCTAssertEqual(clean["verdict"], .string("clean")); XCTAssertEqual(clean["headline"], .string("Nothing that worked has changed."))
        XCTAssertEqual(BackendStaysFixedRead.results(BackendStaysFixedFixtures.web_check_regression)["unchanged"], .string("Everything else it looked at — 47 things — is unchanged."))
    }
    func testValueAndChangeLimitsAndFullReport() {
        XCTAssertTrue(BackendStaysFixedRead.valueText(.string(String(repeating: "x", count: 425))).string!.hasSuffix("(25 more characters)"))
        XCTAssertEqual(BackendStaysFixedRead.valueText(.string(String(repeating: "x", count: 425)), full: true).string!.count, 425)
        let finding = NativeRPCValue.object([.init("count", .number(10)), .init("differences", .array((0..<10).map { .object([.init("path", .string("p\($0)"))]) }))])
        XCTAssertEqual(BackendStaysFixedRead.difference(finding, full: false)["changes"].elements?.count, 6)
        XCTAssertEqual(BackendStaysFixedRead.difference(finding, full: false)["more"], .number(4))
        XCTAssertEqual(BackendStaysFixedRead.difference(finding, full: true)["changes"].elements?.count, 10)
        XCTAssertEqual(BackendStaysFixedRead.plainTitle("is now \"a\\nb\" where it was \\\"c\\\""), "is now \"a b\" where it was \"c\"")
    }
    func testBlockedResultAndOnDiskStringEnvelope() {
        let raw = NativeRPCValue.object([.init("blocked", .bool(true)), .init("coverage", .object([.init("gaps", .array([.object([.init("why", .string("No settings file here."))])]))]))])
        XCTAssertEqual(BackendStaysFixedRead.results(raw)["verdict"], .string("could-not-run")); XCTAssertEqual(BackendStaysFixedRead.results(raw)["headline"], .string("No settings file here."))
        let record = NativeRPCValue.object([.init("at", .string("2026-10-03T23:42:05.690Z")), .init("result", .string(BackendStaysFixedFixtures.cli_check_clean.compact))])
        XCTAssertEqual(BackendStaysFixedRead.lastRun(record.compact)?.0["verdict"], .string("clean"))
        XCTAssertNil(BackendStaysFixedRead.lastRun("not json")); XCTAssertNil(BackendStaysFixedRead.lastRun(#"{"result":"{}"}"#))
    }
    func testReadinessSetupAndMarkRefusals() {
        let readiness = BackendStaysFixedRead.readiness(BackendStaysFixedFixtures.doctor, plan: false)
        XCTAssertTrue(readiness["ready"].elements!.contains(.string("web apps and sites")))
        XCTAssertTrue(readiness["notHere"].elements!.contains(.string("Electron desktop apps")))
        let plan = BackendStaysFixedRead.readiness(BackendStaysFixedFixtures.`init`, plan: true)
        XCTAssertEqual(plan["ready"], .array([.string("the `greet` command")]))
        XCTAssertFalse(plan["gaps"].elements!.contains { $0["fix"].string?.contains("staysfixed ship") == true })
        let setup = BackendStaysFixedRead.setup(BackendStaysFixedFixtures.`init`, roots: ["/Users/you/Projects/tiny-greeter"], failure: nil)
        XCTAssertEqual(setup["wrote"], .array([.string("staysfixed.config.js"), .string(".gitignore")]))
        XCTAssertEqual(BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_cut, failure: nil)["marked"], .bool(true))
        XCTAssertEqual(BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_forced, failure: nil)["marked"], .bool(true))
        XCTAssertEqual(BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_refused, failure: nil)["refusedFor"], .string("differences"))
        let unchecked = NativeRPCValue.object([.init("ok", .bool(true)), .init("decision", .object([.init("state", .string("never-checked"))])), .init("refused", .string("Refusing…"))])
        XCTAssertEqual(BackendStaysFixedRead.mark(unchecked, failure: nil)["refusedFor"], .string("unchecked"))
        XCTAssertEqual(BackendStaysFixedRead.mark(.object([]), failure: "It took too long.")["summary"], .string("It took too long."))
    }
    func testPicturePairing() {
        let difference = NativeRPCValue.object([.init("journeys", .array([.string("the front page"), .string("/about.html")]))])
        let pictures = BackendStaysFixedRead.pictures(difference, files: ["old-single-the-front-page-end.png", "new-a-the-front-page-end.png", "new-b-the-front-page-end.png", "new-a--about.html-end.png"], candidate: "new", reference: "old")
        XCTAssertEqual(pictures.count, 2); XCTAssertEqual(pictures[0].1, "old-single-the-front-page-end.png"); XCTAssertEqual(pictures[0].2, "new-a-the-front-page-end.png"); XCTAssertNil(pictures[1].1)
    }
    func testEngineOutputEnvironmentAndQuoting() {
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON("Warning\n{\"ok\":true}\n")?["ok"], .bool(true))
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON("{\n  \"cut\": true\n}\n")?["cut"], .bool(true))
        XCTAssertNil(BackendStaysFixedEngineFiles.lastJSON("nothing"))
        let env = BackendStaysFixedEngineFiles.environment(base: ["HOME": "/h", "TD_SF_KEEP": "stale"], path: "/opt/bin:/usr/bin", shim: "/u/staysfixed/bin/node", keep: nil)
        XCTAssertEqual(env["PATH"], "/opt/bin:/usr/bin:/u/staysfixed/bin"); XCTAssertNil(env["TD_SF_KEEP"])
        XCTAssertTrue(BackendStaysFixedEngineFiles.nodeShimText("/App/it's").contains("'/App/it'\\''s'"))
        XCTAssertTrue(BackendStaysFixedScripts.check.contains("makeCheckEvents")); XCTAssertTrue(BackendStaysFixedScripts.preload.contains("copyFileSync"))
    }
    func testWhereStopsAtRepositoryAndPreferencesPersist() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), project = scratch.appendingPathComponent("mono"), nested = project.appendingPathComponent("web/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNil(BackendStaysFixedWhere.root(nested.path, home: scratch.path))
        try Data("{}".utf8).write(to: project.appendingPathComponent("staysfixed.config.json"))
        XCTAssertEqual(BackendStaysFixedWhere.root(nested.path, home: scratch.path), project.path)
        let driver = BackendStaysFixedFixtureDriver(), service = makeService(scratch, driver: driver)
        let status = await service.status(project.path); XCTAssertEqual(status["agents"], .bool(true)); XCTAssertEqual(status["configFile"], .string("staysfixed.config.json"))
        let off = try await service.setAgents(project.path, on: false); XCTAssertEqual(off["agents"], .bool(false))
        let relaunched = makeService(scratch, driver: driver), saved = await relaunched.status(project.path); XCTAssertEqual(saved["agents"], .bool(false))
        let source = try await relaunched.projectSource(); let resolution = try await source.resolve(cwd: nested.path, provider: "codex", loginPath: "/usr/bin")
        if resolution != nil { XCTFail("Disabled project tools resolved") }
    }
    func testOneCheckJoinsAndMarkForceIsOnlyForDifferences() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), project = scratch.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("{}".utf8).write(to: project.appendingPathComponent("staysfixed.config.json"))
        let driver = BackendStaysFixedFixtureDriver(), joint = BackendStaysFixedFixtureLatch()
        let service = makeService(scratch, driver: driver, checkJoined: { _, _ in await joint.signal() })
        let first = Task { try await service.check(project.path, by: "you") }
        await driver.waitUntilStarted()
        let joined = Task { try await service.check(project.path, by: "Hoot") }
        await joint.wait(); await driver.releaseCheck()
        let values = try await (first.value, joined.value); XCTAssertEqual(values.0, values.1)
        let checks = await driver.checks; XCTAssertEqual(checks, 1)
        let progress = await service.progress(project.path); XCTAssertEqual(progress, .null)
        XCTAssertNil(BackendSFXReferenceGuard.refusal(project.path), values.0.compact)
        let marked = try await service.markGood(project.path, anyway: true); XCTAssertEqual(marked["marked"], .bool(true))
        let calls = await driver.ships; XCTAssertEqual(calls, [false, true])
        await driver.setUnchecked()
        let unchecked = try await service.markGood(project.path, anyway: true)
        XCTAssertEqual(unchecked["marked"], .bool(false)); XCTAssertEqual(unchecked["refusedFor"], .string("unchecked"))
        let uncheckedCalls = await driver.ships; XCTAssertEqual(uncheckedCalls, [false, true, false])
    }
    func testUnavailableEngineIsExplicitAndChannelArgumentErrorsKeepShape() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = BackendStaysFixedService(userData: scratch, home: scratch.path, executable: nil, inheritedEnvironment: [:], locate: { throw NativeRPCError(code: "unavailable", message: "Stays Fixed is not part of this build.") }, loginPath: { "/usr/bin" })
        let status = await service.status(scratch.path); XCTAssertEqual(status["available"], .bool(false)); XCTAssertEqual(status["unavailable"], .string("Stays Fixed is not part of this build."))
        let registry = NativeChannelRegistry(); try await BackendStaysFixedChannels.register(registry: registry, ownerID: "owner", service: service)
        let bad = try await registry.invoke("staysfixed:check", context: .init(caller: .nativeApp, ownerID: "owner"), arguments: [.string("relative")])
        XCTAssertEqual(bad["ok"], .bool(false)); XCTAssertEqual(bad["message"], .string("That is not a project folder."))
    }
    func testRealFixtureProcessDrainsFinalJSONAndSeparatesProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fixture")
        let source = "#!/bin/sh\nprintf '%s\\n' '{\"ok\":true}'\nprintf '\\036SF %s\\n' '{\"type\":\"step\",\"message\":\"Walking.\"}' >&2\nprintf '%s' 'ordinary tail' >&2\n"
        try Data(source.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let driver = BackendStaysFixedEngine(home: .init(dir: dir, bin: executable, version: "0.15.0", versionNote: ""), executable: executable.path, shim: nil, path: "/usr/bin:/bin", environment: [:])
        let events = BackendStaysFixedFixtureEvents()
        let output = await driver.cli(["doctor", "--json"], cwd: dir.path, timeout: 5000, onEvent: { events.append($0) })
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON(output.stdout)?["ok"], .bool(true)); XCTAssertEqual(output.stderr, "ordinary tail"); XCTAssertEqual(output.code, 0)
        XCTAssertEqual(events.values.first?["message"], .string("Walking."))
    }
    private func makeService(_ data: URL, driver: BackendStaysFixedFixtureDriver, checkJoined: @escaping @Sendable (String, String) async -> Void = { _, _ in }) -> BackendStaysFixedService {
        BackendStaysFixedService(userData: data.appendingPathComponent("userData"), home: data.path, executable: "/fixture/node", inheritedEnvironment: [:], locate: { driver.home }, loginPath: { "/usr/bin" }, driverFactory: { _, _, _, _, _ in driver }, checkJoined: checkJoined)
    }
}

private final class BackendStaysFixedFixtureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeRPCValue] = []
    func append(_ event: NativeRPCValue) { lock.withLock { events.append(event) } }
    var values: [NativeRPCValue] { lock.withLock { events } }
}

private actor BackendStaysFixedFixtureDriver: BackendStaysFixedEngineRunning {
    nonisolated let home = BackendStaysFixedEngineHome(dir: URL(fileURLWithPath: "/fixture/staysfixed"), bin: URL(fileURLWithPath: "/fixture/staysfixed/bin/staysfixed.js"), version: "0.15.0", versionNote: "")
    var checks = 0, ships: [Bool] = [], unchecked = false
    private var checkWaiter: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    func setUnchecked() { unchecked = true }
    func waitUntilStarted() async { if checks > 0 { return }; await withCheckedContinuation { startedWaiters.append($0) } }
    func releaseCheck() { let waiter = checkWaiter; checkWaiter = nil; waiter?.resume() }
    func cli(_ args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        let raw: NativeRPCValue
        if args.first == "ship" {
            let forced = args.contains("--force"); ships.append(forced)
            raw = unchecked ? .object([.init("ok", .bool(true)), .init("refused", .string("Never checked.")), .init("decision", .object([.init("state", .string("never-checked"))]))]) : forced ? BackendStaysFixedFixtures.ship_forced : BackendStaysFixedFixtures.ship_refused
        } else { raw = args.first == "doctor" ? BackendStaysFixedFixtures.doctor : BackendStaysFixedFixtures.`init` }
        return .init(code: 0, stdout: raw.compact, stderr: "", timedOut: false, cancelled: false)
    }
    func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        if source == BackendStaysFixedScripts.check {
            checks += 1; onEvent(.object([.init("message", .string("Comparing."))]))
            let waiting = startedWaiters; startedWaiters.removeAll(); for waiter in waiting { waiter.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { checkWaiter = $0 }
            } onCancel: { Task { await self.releaseCheck() } }
            if Task.isCancelled { return .init(code: nil, stdout: "", stderr: "", timedOut: false, cancelled: true) }
            let raw = BackendStaysFixedFixtures.cli_check_regression
            do {
                let buildID = try raw["candidate"]["id"].requireString("fixture candidate id", nonempty: true)
                let sample = raw["findings"].elements?.first?["sample"] ?? .missing
                _ = try sample["candidate"].requireString("captured command output", nonempty: true)
                let folder = URL(fileURLWithPath: cwd).appendingPathComponent(".staysfixed/v2")
                let captureFolder = folder.appendingPathComponent("builds/" + BackendStaysFixedRead.fileSafe(buildID) + "/receipt")
                try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
                let capture: [NativeRPCValue] = [
                    .object([.init("kind", .string("capture"))]),
                    .object([.init("path", sample["path"]), .init("channel", sample["channel"]), .init("value", sample["candidate"]),
                             .init("meta", .object([.init("refused", .bool(false))]))]),
                    .object([.init("kind", .string("end")), .init("count", .number(1))])
                ]
                try Data((capture.map(\.compact).joined(separator: "\n") + "\n").utf8)
                    .write(to: captureFolder.appendingPathComponent(String(format: "%08d.jsonl", checks)), options: .atomic)
                let envelope = NativeRPCValue.object([.init("at", raw["startedAt"]), .init("result", .string(raw.compact))])
                try envelope.encodedJSON().write(to: folder.appendingPathComponent("last-check.json"), options: .atomic)
            } catch { return .init(code: 1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
            return .init(code: 0, stdout: raw.compact, stderr: "", timedOut: false, cancelled: false)
        }
        return .init(code: 0, stdout: "{}", stderr: "", timedOut: false, cancelled: false)
    }
}

private actor BackendStaysFixedFixtureLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; let waiting = waiters; waiters.removeAll(); for waiter in waiting { waiter.resume() } }
    func wait() async { if signalled { return }; await withCheckedContinuation { waiters.append($0) } }
}
