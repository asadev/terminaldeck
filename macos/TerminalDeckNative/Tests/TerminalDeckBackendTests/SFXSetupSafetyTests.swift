import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class SFXSetupSafetyTests: XCTestCase {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SFX-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }
    private func service(_ root: URL, state: SFXSetupSafetyState, clock: SFXSetupSafetyClock = .init()) -> BackendSFXSetupService {
        BackendSFXSetupService(plan: { _, _ in await state.plan(root) }, setup: { _ in await state.setup() }, now: { clock.value })
    }

    func testDetectedDefaultsAreShownAndUnsupportedProjectNeedsCommand() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        let defaultPreview = try await service.preview(root.path)
        XCTAssertEqual(defaultPreview["canApply"], .bool(true))
        XCTAssertEqual(defaultPreview["ready"], .array([.string("the local command")]))
        await state.setReady(false)
        let unsupported = try await service.preview(root.path)
        XCTAssertEqual(unsupported["canApply"], .bool(false)); XCTAssertEqual(unsupported["commandNeeded"], .bool(true))
        XCTAssertTrue(unsupported["problem"].string?.contains("No runnable product") == true)
        let fallback = try await service.preview(root.path, checkCommand: "/usr/bin/swift SFXGreeting.swift --help")
        XCTAssertEqual(fallback["canApply"], .bool(true)); XCTAssertEqual(fallback["ready"], .array([]))
        let config = try NativeRPCValue.parseJSON(Data(try XCTUnwrap(fallback["configText"].string).utf8))
        XCTAssertEqual(config["process"]["commands"].elements?.first?["run"], .string("/usr/bin/swift SFXGreeting.swift --help"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staysfixed.config.json").path))
    }

    func testExpiredAndWrongProjectTokensNeverCallWriter() async throws {
        let root = try project(), other = try project(), state = SFXSetupSafetyState(), clock = SFXSetupSafetyClock(), service = service(root, state: state, clock: clock)
        let preview = try await service.preview(root.path), token = try XCTUnwrap(preview["token"].string)
        do { _ = try await service.apply(other.path, token: token); XCTFail("Wrong project accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("another project")) }
        let next = try await service.preview(root.path), nextToken = try XCTUnwrap(next["token"].string)
        clock.set(700_000)
        do { _ = try await service.apply(root.path, token: nextToken); XCTFail("Expired preview accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
        let writes = await state.writes; XCTAssertEqual(writes, 0)
    }

    func testEngineConfigThroughProjectAliasIsKeptInsideCanonicalProject() async throws {
        let root = try project(), state = SFXSetupSafetyState()
        let alias = root.deletingLastPathComponent().appendingPathComponent("SFX-alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        let setup = BackendSFXSetupService(plan: { _, _ in
            let plan = await state.plan(root)
            return plan.setting("config", plan["config"].setting("file", .string(alias.appendingPathComponent("staysfixed.config.js").path)))
        }, setup: { _ in await state.setup() })
        let preview = try await setup.preview(root.path)
        XCTAssertEqual(preview["canApply"], .bool(true), preview.compact)
        XCTAssertEqual(preview["configFile"], .string(root.resolvingSymlinksInPath().appendingPathComponent("staysfixed.config.js").path))
    }

    func testDriftAndNewSettingsAreRefusedBeforeWriter() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        let preview = try await service.preview(root.path), token = try XCTUnwrap(preview["token"].string)
        await state.setText("export default { product: 'changed' };\n")
        do { _ = try await service.apply(root.path, token: token); XCTFail("Drift accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("changed since")) }
        let second = try await service.preview(root.path), secondToken = try XCTUnwrap(second["token"].string)
        let kept = Data("{\"product\":\"keep me\"}".utf8), file = root.appendingPathComponent("staysfixed.config.json")
        try kept.write(to: file)
        do { _ = try await service.apply(root.path, token: secondToken); XCTFail("Existing settings accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("nothing was overwritten")) }
        XCTAssertEqual(try Data(contentsOf: file), kept)
        let writes = await state.writes; XCTAssertEqual(writes, 0)
    }

    func testChangedIgnoreAndSymbolicLinkAreRefused() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        let preview = try await service.preview(root.path), token = try XCTUnwrap(preview["token"].string)
        let ignore = root.appendingPathComponent(".gitignore")
        try Data("mine\n".utf8).write(to: ignore)
        do { _ = try await service.apply(root.path, token: token); XCTFail("Changed ignore accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("ignore file changed")) }
        try FileManager.default.removeItem(at: ignore)
        let outside = root.appendingPathComponent("outside-ignore")
        try Data("private\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: ignore, withDestinationURL: outside)
        do { _ = try await service.preview(root.path); XCTFail("Linked ignore accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("linked")) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private\n")
        let writes = await state.writes; XCTAssertEqual(writes, 0)
    }

    func testBogusSuccessWithoutArtifactsIsNotReportedReady() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        let preview = try await service.preview(root.path), token = try XCTUnwrap(preview["token"].string)
        let result = try await service.apply(root.path, token: token)
        XCTAssertEqual(result["ok"], .bool(false)); XCTAssertTrue(result["problem"].string?.contains("differ from the preview") == true)
        let writes = await state.writes; XCTAssertEqual(writes, 1)
    }

    func testMalformedCommandsDoNotInspectOrWriteProject() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        for command in ["swift a.swift\nrm -rf x", "swift\0a.swift", String(repeating: "x", count: 2049)] {
            do { _ = try await service.preview(root.path, checkCommand: command, prepareRuntime: true); XCTFail("Malformed command accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("one command on one line")) }
        }
        let reads = await state.reads, writes = await state.writes
        XCTAssertEqual(reads, 0); XCTAssertEqual(writes, 0)
    }

    func testPlannerRejectsFailureJSONTimeoutAndMalformedPlan() async throws {
        let root = try project()
        for result in [BackendStaysFixedRunResult(code: 1, stdout: "{\"ok\":true,\"plan\":{\"config\":{\"text\":\"fake\"}}}", stderr: "denied", timedOut: false, cancelled: false),
                       BackendStaysFixedRunResult(code: 0, stdout: "{\"ok\":true,\"plan\":{\"config\":{\"text\":\"fake\"}}}", stderr: "", timedOut: true, cancelled: false),
                       BackendStaysFixedRunResult(code: 0, stdout: "{\"error\":{\"message\":\"bad settings\"}}", stderr: "", timedOut: false, cancelled: false)] {
            let planner = BackendSFXSetupPlanner(engine: SFXSetupSafetyDriver(result: result))
            do { _ = try await planner.plan(root.path); XCTFail("Invalid engine result accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Try the preview again")) }
        }
    }

    func testPartialCommandSetupCanFinishAfterReopeningAndKeepsSettings() async throws {
        let root = try project(), state = SFXSetupSafetyState(), service = service(root, state: state)
        await state.failSetup()
        let preview = try await service.preview(root.path, checkCommand: "/usr/bin/swift SFXGreeting.swift --help")
        let token = try XCTUnwrap(preview["token"].string)
        let partial = try await service.apply(root.path, token: token)
        XCTAssertEqual(partial["ok"], .bool(false)); XCTAssertEqual(partial["partialSetup"], .bool(true))
        XCTAssertEqual(partial["retryToken"], .string(token)); XCTAssertTrue(partial["problem"].string?.contains("Finish setup") == true)
        let file = root.appendingPathComponent("staysfixed.config.json"), saved = try Data(contentsOf: file)
        // A fresh actor can reissue a review from actual existing settings.
        let reopened = self.service(root, state: state)
        let resume = try await reopened.preview(root.path)
        XCTAssertEqual(resume["partialSetup"], .bool(true)); XCTAssertEqual(resume["canApply"], .bool(true))
        await state.finishSetup()
        let completed = try await reopened.apply(root.path, token: XCTUnwrap(resume["retryToken"].string))
        XCTAssertEqual(completed["ok"], .bool(true)); XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8).contains(".staysfixed/v2/builds/"))
    }
}

private actor SFXSetupSafetyState {
    var writes = 0, reads = 0
    private var ready = true, text = "export default { product: 'sample' };\n", fail = false, finish = false
    private var projectRoot: URL?
    func setReady(_ value: Bool) { ready = value }
    func setText(_ value: String) { text = value }
    func failSetup() { fail = true }
    func finishSetup() { fail = false; finish = true }
    func plan(_ root: URL) -> NativeRPCValue {
        reads += 1
        projectRoot = root
        return .object([.init("root", .string(root.path)), .init("summary", .string("A local command.")), .init("config", .object([.init("file", .string(root.appendingPathComponent("staysfixed.config.js").path)), .init("text", .string(text)), .init("exists", .bool(false))])), .init("readiness", .array([.object([.init("product", .string("the local command")), .init("state", .string(ready ? "ready" : "not possible here")), .init("needs", .array([]))])])), .init("covers", .object([.init("short", .string(ready ? "The command is available." : "Nothing can be checked here."))]))])
    }
    func setup() -> NativeRPCValue {
        writes += 1
        if fail { return .object([.init("ok", .bool(false)), .init("wrote", .array([])), .init("problem", .string("Disk full."))]) }
        if finish, let projectRoot {
            let text = "\n# Stays Fixed — evidence from the last run, not the promise\n.staysfixed/results/\n.staysfixed/report.html\n.staysfixed/watch-window.json\n.staysfixed/v2/builds/\n.staysfixed/v2/last-check.json\n.staysfixed/**/*.lock\n"
            try? Data(text.utf8).write(to: projectRoot.appendingPathComponent(".gitignore"))
        }
        return .object([.init("ok", .bool(true)), .init("wrote", .array([]))])
    }
}

private final class SFXSetupSafetyClock: @unchecked Sendable {
    private let lock = NSLock(); private var stored = 0.0
    var value: Double { lock.withLock { stored } }
    func set(_ value: Double) { lock.withLock { stored = value } }
}

private struct SFXSetupSafetyDriver: BackendStaysFixedEngineRunning {
    let result: BackendStaysFixedRunResult
    var home: BackendStaysFixedEngineHome { .init(dir: URL(fileURLWithPath: "/fixture"), bin: URL(fileURLWithPath: "/fixture/bin"), version: "0.15.0", versionNote: "") }
    func cli(_ args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult { result }
    func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult { result }
}
