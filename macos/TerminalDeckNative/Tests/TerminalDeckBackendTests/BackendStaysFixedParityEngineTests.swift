import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendStaysFixedParityExecutionCapture {
    private(set) var plans: [BackendStaysFixedProcessPlan] = []
    func run(_ plan: BackendStaysFixedProcessPlan) -> BackendStaysFixedRunResult {
        plans.append(plan)
        let json = NativeRPCValue.object([.init("execPath", .string(plan.environment["TD_SF_EXEC_PATH"] ?? plan.command))])
        return .init(code: 0, stdout: json.compact + "\n", stderr: "", timedOut: false, cancelled: false)
    }
}
private actor BackendStaysFixedParityCancelledExecution {
    private var continuation: CheckedContinuation<BackendStaysFixedRunResult, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var waiting = false
    func run() async -> BackendStaysFixedRunResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation; waiting = true
                let pending = started; started.removeAll(); pending.forEach { $0.resume() }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitStarted() async {
        if waiting { return }; await withCheckedContinuation { started.append($0) }
    }
    private func cancel() {
        continuation?.resume(returning: .init(code: nil, stdout: "", stderr: "", timedOut: false, cancelled: true))
        continuation = nil
    }
}
@MainActor final class BackendStaysFixedParityEngineTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-stays-engine-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try BackendFilesystemAuthority.canonical(url)
    }
    private var home: BackendStaysFixedEngineHome {
        .init(dir: URL(fileURLWithPath: "/fixture/staysfixed"), bin: URL(fileURLWithPath: "/fixture/staysfixed/bin/staysfixed.js"),
            version: "0.15.0", versionNote: "")
    }
    func testCandidatesFindPinnedStagedPackageAndRefuseArchive() throws {
        let paths = BackendStaysFixedEngineFiles.candidates(resources: "/App/Contents/Resources", appPath: "/App/Contents/Resources/app.asar", cwd: "/cwd", override: nil)
        XCTAssertEqual(paths.first, "/App/Contents/Resources/app.asar.unpacked/node_modules/staysfixed")
        XCTAssertTrue(paths.contains("/cwd/node_modules/staysfixed"))
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("node_modules/staysfixed"), bin = dir.appendingPathComponent("bin/staysfixed.js")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: bin); try Data(#"{"version":"0.15.0"}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
        let pinned = try BackendStaysFixedEngineFiles.locate(resources: nil, appPath: root.path, cwd: root.path)
        XCTAssertEqual(pinned.version, "0.15.0"); XCTAssertEqual(pinned.versionNote, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.bin.path))
        let packed = root.appendingPathComponent("Resources/app.asar/node_modules/staysfixed/bin")
        try FileManager.default.createDirectory(at: packed, withIntermediateDirectories: true); try Data().write(to: packed.appendingPathComponent("staysfixed.js"))
        do {
            _ = try BackendStaysFixedEngineFiles.locate(resources: nil, appPath: root.appendingPathComponent("nowhere").path,
                cwd: root.appendingPathComponent("nowhere").path, override: packed.deletingLastPathComponent().path)
            XCTFail("Archived executable accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("archive")); XCTAssertTrue(error.localizedDescription.contains("packaging step")) }
    }
    func testShimShellQuotingRewriteAndMacExecutablePermissions() throws {
        let script = BackendStaysFixedEngineFiles.nodeShimText("/Applications/Terminal Deck.app/Contents/MacOS/it's")
        XCTAssertTrue(script.contains("ELECTRON_RUN_AS_NODE=1 exec '/Applications/Terminal Deck.app/Contents/MacOS/it'\\''s' \"$@\""))
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("shim"), old = BackendStaysFixedEngineFiles.ensureShim(dir, executable: "/old/place")
        XCTAssertEqual(old, dir.appendingPathComponent("node").path)
        _ = BackendStaysFixedEngineFiles.ensureShim(dir, executable: "/new/place")
        XCTAssertTrue(try BackendMemoryFiles.text(dir.appendingPathComponent("node").path).contains("/new/place"))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("node").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o755)
        // The source Windows branch is Mac-inapplicable, listed separately in the map.
    }
    func testEnvironmentAndActualCliScriptPlansPreservePreloadAndTimeout() async throws {
        let env = BackendStaysFixedEngineFiles.environment(base: ["HOME": "/h", "TD_SF_KEEP": "stale"], path: "/opt/bin:/usr/bin", shim: "/u/staysfixed/bin/node", keep: nil)
        XCTAssertEqual(env["ELECTRON_RUN_AS_NODE"], "1"); XCTAssertEqual(env["PATH"], "/opt/bin:/usr/bin:/u/staysfixed/bin")
        XCTAssertEqual(env["TD_SF_EXEC_PATH"], "/u/staysfixed/bin/node"); XCTAssertNil(env["TD_SF_KEEP"])
        XCTAssertEqual(BackendStaysFixedEngineFiles.environment(base: [:], path: "/usr/bin", shim: nil, keep: "/keep")["TD_SF_KEEP"], "/keep")
        let capture = BackendStaysFixedParityExecutionCapture()
        let engine = BackendStaysFixedEngine(home: home, executable: "/fixture/node", shim: "/u/staysfixed/bin/node",
            path: "/opt/bin:/usr/bin", environment: ["HOME": "/h"], execution: { plan, _ in await capture.run(plan) })
        _ = await engine.cli(["check"], cwd: "/fixture/project", timeout: 20_000)
        let script = "process.stdout.write(JSON.stringify({ execPath: process.execPath }) + \"\\n\")"
        let result = await engine.script(script, args: ["one"], cwd: "/fixture/project", timeout: 30_000, keep: "/keep")
        let plans = await capture.plans
        XCTAssertEqual(plans[0].arguments, ["--import", BackendStaysFixedScripts.preloadURL, home.bin.path, "check"])
        XCTAssertEqual(plans[1].arguments, ["--import", BackendStaysFixedScripts.preloadURL, "--input-type=module", "-e", script, "--", home.dir.path, "one"])
        XCTAssertEqual(plans[1].command, "/fixture/node"); XCTAssertEqual(plans[1].cwd, "/fixture/project")
        XCTAssertEqual(plans[1].timeoutMilliseconds, 30_000); XCTAssertEqual(plans[1].environment["TD_SF_KEEP"], "/keep")
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON(result.stdout)?["execPath"].string, "/u/staysfixed/bin/node")
        XCTAssertTrue(BackendStaysFixedScripts.preload.contains("process.execPath = process.env.TD_SF_EXEC_PATH"))
    }
    func testLastPrintedJsonLineAndPrettyObject() {
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON("(node:1) Warning: something\n{\"ok\":true}\n")?["ok"], .bool(true))
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON("{\n  \"cut\": true\n}\n")?["cut"], .bool(true))
        XCTAssertNil(BackendStaysFixedEngineFiles.lastJSON("nothing"))
    }
    func testProgressChunkParserAndDefaultsKeepOnlyOrdinaryStderr() {
        var parser = BackendStaysFixedOutputParser()
        let first = Data("ordinary\n\u{001e}SF {\"type\":\"check:start\",\"message\":\"Comparing.\",\"journey\":\"page\",\"count\":2,\"at\":7}\n".utf8)
        let split = first.count / 2
        XCTAssertTrue(parser.receive(Data(first.prefix(split))).isEmpty)
        let events = parser.receive(Data(first.dropFirst(split)))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0]["type"].string, "check:start"); XCTAssertEqual(events[0]["message"].string, "Comparing.")
        XCTAssertEqual(events[0]["journey"].string, "page"); XCTAssertEqual(events[0]["count"].number, 2); XCTAssertEqual(events[0]["at"].number, 7)
        let defaults = parser.receive(Data("\u{001e}SF {\"type\":1,\"message\":false,\"count\":\"bad\"}\n\u{001e}SF not json\n".utf8))
        XCTAssertEqual(defaults, [.object([.init("type", .string("note")), .init("message", .string("")), .init("journey", .null), .init("count", .null), .init("at", .number(0))])])
        _ = parser.receive(Data("a tail".utf8)); parser.finish()
        XCTAssertEqual(String(decoding: parser.stderr, as: UTF8.self), "ordinary\na tail")
    }
    func testCourtesyPicturePreloadPlanAndDeterministicFilesystemDependency() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("staysfixed-check-abc"), evidence = scratch.appendingPathComponent("evidence"), keep = root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: evidence.appendingPathComponent("build-a-page-end.png"))
        try Data("not a picture".utf8).write(to: evidence.appendingPathComponent("notes.txt"))
        let engine = BackendStaysFixedEngine(home: home, executable: "/fixture/node", shim: nil, path: "/usr/bin", environment: [:], execution: { plan, _ in
            let payload = String(plan.arguments[1].dropFirst("data:text/javascript,".count)).removingPercentEncoding
            XCTAssertEqual(payload, BackendStaysFixedScripts.preload)
            XCTAssertTrue(payload?.contains("fsp.rm = async function") == true); XCTAssertTrue(payload?.contains("copyFileSync") == true)
            XCTAssertEqual(plan.environment["TD_SF_KEEP"], keep.path)
            // Fake external fs dependency: model the package courtesy outcome,
            // without evaluating the JS preload or claiming a live engine run.
            do {
                try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: evidence.appendingPathComponent("build-a-page-end.png"), to: keep.appendingPathComponent("build-a-page-end.png"))
                try FileManager.default.removeItem(at: scratch)
                return .init(code: 0, stdout: "{\"done\":true}\n", stderr: "", timedOut: false, cancelled: false)
            } catch { return .init(code: 1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
        })
        let result = await engine.script("import fsp from 'node:fs/promises'; await fsp.rm('fixture')", args: [], cwd: root.path, timeout: 20_000, keep: keep.path)
        XCTAssertEqual(BackendStaysFixedEngineFiles.lastJSON(result.stdout)?["done"].bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path)); XCTAssertEqual(try BackendMemoryFiles.text(keep.appendingPathComponent("build-a-page-end.png").path), "png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keep.appendingPathComponent("notes.txt").path))
    }
    func testGuardLoaderReplyAndRefusedNameThroughActualDescribeEnvelope() async {
        let named = NativeRPCValue.object([.init("guards", .array([.object([.init("name", .string("the total keeps its pennies")),
            .init("because", .string("It printed 10.0 once.")), .init("file", .string("/fixture/.staysfixed/guards/total.js"))])])),
            .init("guardProblem", .null), .init("reference", .null)])
        let engine = BackendStaysFixedEngine(home: home, executable: "/fixture/node", shim: nil, path: "/usr/bin", environment: [:], execution: { plan, _ in
            XCTAssertEqual(plan.arguments[4], BackendStaysFixedScripts.describe); XCTAssertTrue(plan.arguments[4].contains("loadGuards"))
            XCTAssertFalse(plan.arguments[4].contains(".run("))
            return .init(code: 0, stdout: named.compact + "\n", stderr: "", timedOut: false, cancelled: false)
        })
        let result = await engine.script(BackendStaysFixedScripts.describe, args: ["/fixture/project"], cwd: "/fixture/project", timeout: 30_000)
        let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout)!
        XCTAssertEqual(raw["guards"].elements?.first?["name"].string, "the total keeps its pennies")
        XCTAssertEqual(raw["guards"].elements?.first?["because"].string, "It printed 10.0 once.")
        XCTAssertEqual(raw["guardProblem"], .null); XCTAssertEqual(raw["reference"], .null)
        let refused = NativeRPCValue.object([.init("guards", .array([])), .init("guardProblem", .string("sidebar_test is not a guard name."))])
        XCTAssertEqual(BackendStaysFixedRead.description(refused)["guards"], .array([]))
        XCTAssertNotEqual(BackendStaysFixedRead.description(refused)["guardProblem"], .null)
    }
    func testBareProjectCheckReplyHasEngineReasonAndNotUnsupported() async {
        let raw = NativeRPCValue.object([.init("error", .object([.init("message", .string("No settings file here."))]))])
        let engine = BackendStaysFixedEngine(home: home, executable: "/fixture/node", shim: nil, path: "/usr/bin", environment: [:], execution: { plan, event in
            XCTAssertEqual(plan.arguments[4], BackendStaysFixedScripts.check)
            XCTAssertEqual(Array(plan.arguments.suffix(2)), ["/fixture/bare", "stored"])
            XCTAssertTrue(plan.arguments[4].contains("makeCheckEvents"))
            event(.object([.init("type", .string("check:start")), .init("message", .string("Checking."))]))
            return .init(code: 2, stdout: raw.compact + "\n", stderr: "", timedOut: false, cancelled: false)
        })
        let result = await engine.script(BackendStaysFixedScripts.check, args: ["/fixture/bare", "stored"], cwd: "/fixture/bare", timeout: 180_000)
        let answer = BackendStaysFixedEngineFiles.lastJSON(result.stdout)
        XCTAssertNotNil(answer); XCTAssertEqual(answer?["unsupported"], .missing)
        XCTAssertTrue(answer?["error"].fields != nil || answer?["blocked"].bool == true)
    }
    func testCancellationReachesInjectedExecutionWithoutSleep() async {
        let peer = BackendStaysFixedParityCancelledExecution()
        let engine = BackendStaysFixedEngine(home: home, executable: "/fixture/node", shim: nil, path: "/usr/bin", environment: [:], execution: { _, _ in await peer.run() })
        let task = Task { await engine.script("fixture waiting operation", args: [], cwd: "/fixture", timeout: 60_000) }
        await peer.waitStarted(); task.cancel()
        let result = await task.value; XCTAssertTrue(result.cancelled)
    }
}
