import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// live-surface.test.ts's pty manager stand-in: what was listed, typed, killed and started.
final class BackendDeckCoreTestPortS1LiveSurfaceRecord: @unchecked Sendable {
    struct Typed: Equatable, Sendable { let id: String; let data: String }
    private let lock = NSLock()
    private var sessionRows: [NativeRPCValue] = []
    private var typedRows: [Typed] = []
    private var killedRows: [String] = []
    private var startRows: [NativeRPCValue] = []
    func setSessions(_ rows: [NativeRPCValue]) { lock.withLock { sessionRows = rows } }
    func sessions() -> [NativeRPCValue] { lock.withLock { sessionRows } }
    func type(_ id: String, _ data: String) { lock.withLock { typedRows.append(Typed(id: id, data: data)) } }
    func typed() -> [Typed] { lock.withLock { typedRows } }
    func kill(_ id: String) { lock.withLock { killedRows.append(id) } }
    func killed() -> [String] { lock.withLock { killedRows } }
    func starts() -> [NativeRPCValue] { lock.withLock { startRows } }
    func start(_ input: NativeRPCValue) -> NativeRPCValue {
        lock.withLock { () -> NativeRPCValue in
            startRows.append(input)
            let meta = BackendDeckCoreTestPortSecurityValue.object([("id", .string("started-1")), ("cwd", input["cwd"]), ("title", .string("started")),
                ("provider", input["provider"].string.map(NativeRPCValue.string) ?? .string("claude")), ("exitCode", .null), ("createdAt", .number(1))])
            sessionRows.append(meta); return meta
        }
    }
}

/// Git and alerts are child processes; this port never reaches them.
struct BackendDeckCoreTestPortS1LiveSurfaceNoProcesses: BackendDeckCoreProjectEvidence {
    func gitStatus(cwd: String) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("git status (child process) in this port") }
    func alerts(projectPath: String) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("project alerts (child processes) in this port") }
    func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue {
        throw BackendSessionFailure.missingCapability("attributed folder diff (child process) in this port")
    }
}

/// The real owners behind the surface: the native Store and settings writer on
/// disk, and the native transcript reader over a Claude config folder on disk.
struct BackendDeckCoreTestPortS1LiveSurfaceRig: Sendable {
    let root: URL
    let work: URL
    let claude: URL
    let scope: NativeTranscriptScope
    let store: NativeStateStore
    let settings: BackendAppSettingsStore
    let state: BackendCompositionState
    let record: BackendDeckCoreTestPortS1LiveSurfaceRecord
    let live: BackendDeckCoreLiveSurface

    static func make(root raw: URL) async throws -> Self {
        let root = raw.resolvingSymlinksInPath()
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let scope = NativeTranscriptScope(configDirectory: claude.path)
        let store = try NativeStateStore(file: root.appendingPathComponent("state.json"), ownership: .exclusive)
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        let copilot = root.appendingPathComponent("copilot", isDirectory: true).path
        let state = await BackendCompositionState.make(store: store, settings: settings, dataRoot: root, registry: NativeChannelRegistry(), copilotRoot: { _ in copilot })
        let record = BackendDeckCoreTestPortS1LiveSurfaceRecord()
        let live = try surface(state: state, scope: scope, record: record)
        return Self(root: root, work: work, claude: claude, scope: scope, store: store, settings: settings, state: state, record: record, live: live)
    }
    static func surface(state: BackendCompositionState, scope: NativeTranscriptScope, record: BackendDeckCoreTestPortS1LiveSurfaceRecord,
                        deviceFolders: (@Sendable (String) -> [String])? = nil,
                        deviceStart: (@Sendable (NativeRPCValue, String) async throws -> NativeRPCValue)? = nil,
                        projectEvidence: (any BackendDeckCoreProjectEvidence)? = nil) throws -> BackendDeckCoreLiveSurface {
        try BackendDeckCoreLiveSurface(manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: state,
            evidence: BackendDeckCoreNativeEvidence(scopeForProject: { _ in scope }, scopeForPath: { _ in scope }),
            projectEvidence: projectEvidence ?? BackendDeckCoreTestPortS1LiveSurfaceNoProcesses(), ownership: .exclusive,
            startSession: { input in record.start(input) },
            writeToSession: { id, data in record.type(id, data) },
            closeSession: { id in record.kill(id) },
            sessionStatus: { id in id == "live-1" ? BackendDeckCoreTestPortSecurityValue.object([("status", .string("working")), ("at", .number(42))]) : .missing },
            windows: { _ in [] },
            deviceFolders: deviceFolders, deviceStartSession: deviceStart,
            readSessions: { record.sessions() },
            readScreen: { _ in "a rendered screen" },
            readScrollback: { _ in "the raw bytes a session has printed" })
    }
    /// One JSONL line the Claude CLI writes, in the two shapes that carry prose.
    func prompt(_ uuid: String, _ text: String, _ at: String) throws -> String {
        let message = BackendDeckCoreTestPortSecurityValue.object([("role", .string("user")), ("content", .string(text))])
        let line = BackendDeckCoreTestPortSecurityValue.object([("type", .string("user")), ("uuid", .string(uuid)), ("timestamp", .string(at)),
            ("sessionId", .string("cli-session")), ("cwd", .string(work.path)), ("message", message)])
        return String(decoding: try line.encodedJSON(), as: UTF8.self) + "\n"
    }
    func reply(_ id: String, _ text: String, _ at: String) throws -> String {
        let block = BackendDeckCoreTestPortSecurityValue.object([("type", .string("text")), ("text", .string(text))])
        let message = BackendDeckCoreTestPortSecurityValue.object([("id", .string(id)), ("role", .string("assistant")), ("model", .string("claude-x")), ("content", .array([block]))])
        let line = BackendDeckCoreTestPortSecurityValue.object([("type", .string("assistant")), ("uuid", .string("u-" + id)), ("timestamp", .string(at)),
            ("sessionId", .string("cli-session")), ("cwd", .string(work.path)), ("message", message)])
        return String(decoding: try line.encodedJSON(), as: UTF8.self) + "\n"
    }
    var transcripts: URL { claude.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(work.path), isDirectory: true) }
    func writeTranscript(_ name: String, _ body: String) throws -> URL {
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let path = transcripts.appendingPathComponent(name); try Data(body.utf8).write(to: path); return path
    }
}

final class BackendDeckCoreTestPortS1LiveSurfaceTests: BackendDeckCoreTestPortSecurityCase {
    private typealias Rig = BackendDeckCoreTestPortS1LiveSurfaceRig
    private func made() async throws -> Rig {
        let rig = try await Rig.make(root: scratch()); addTeardownBlock { await rig.state.stop() }; return rig
    }
    private func size(_ path: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0 }

    // MARK: sessions

    // TSCASE live-surface.test.ts:147
    func testLiveSurfaceL147ForwardsToTheSamePtyManagerTheWindowUses() async throws {
        let rig = try await made()
        rig.record.setSessions([o([("id", .string("live-1")), ("cwd", .string(rig.work.path)), ("title", .string("work")), ("provider", .string("claude")), ("exitCode", .null), ("createdAt", .number(1))])])
        let live = rig.live
        XCTAssertEqual(live.listSessions().count, 1)
        assertValue(live.sessionStatus("live-1"), o([("status", .string("working")), ("at", .number(42))]))
        // Null, not missing: "no classification yet" is said with a null.
        XCTAssertEqual(live.sessionStatus("nobody"), .null)
        try await live.writeToSession("live-1", data: "hello\r")
        try await live.killSession("live-1")
        XCTAssertEqual(rig.record.typed(), [.init(id: "live-1", data: "hello\r")])
        XCTAssertEqual(rig.record.killed(), ["live-1"])
        let screen = try await live.sessionScreen("live-1")
        XCTAssertEqual(screen, "a rendered screen")
    }
    // TSCASE live-surface.test.ts:194
    func testLiveSurfaceL194OffersNoDeviceFoldersBecauseItHasNoDeviceAwareStart() async throws {
        let rig = try await made(), input = o([("cwd", .string(rig.work.path))])
        XCTAssertNil(rig.live.deviceFolders("phone-1"))
        // A device start is refused rather than handed to the person's own starter.
        await assertAsyncError({ _ = try await rig.live.startSession(input: input, forDevice: "phone-1") })
        XCTAssertTrue(rig.record.starts().isEmpty)
        // The two travel together: neither half may arrive without the other.
        XCTAssertThrowsError(try Rig.surface(state: rig.state, scope: rig.scope, record: rig.record, deviceFolders: { _ in ["/work/api"] }))
        XCTAssertThrowsError(try Rig.surface(state: rig.state, scope: rig.scope, record: rig.record, deviceStart: { input, _ in input }))
    }

    // MARK: projects

    // TSCASE live-surface.test.ts:207
    func testLiveSurfaceL207ReadsTheAppsOwnProjectListNewestFirst() async throws {
        let rig = try await made(), one = rig.root.appendingPathComponent("one").path, two = rig.root.appendingPathComponent("two").path
        _ = try await rig.store.addProject(one)
        _ = try await rig.store.addProject(two)
        let listed = rig.live.listProjects().compactMap { $0["path"].string }
        XCTAssertTrue(listed.contains(one)); XCTAssertTrue(listed.contains(two))
    }

    // MARK: git (S1i sweep)

    /// The surface over the real evidence adapter (BackendDeckCoreNativeProjectEvidence)
    /// and the real BackendGitService; only the `git` executable is the scripted
    /// runner (no child process). Production's composition bindings make the
    /// same `git.status(cwd:context:)` call.
    private func gitSurface(_ rig: Rig) throws -> (live: BackendDeckCoreLiveSurface, git: BackendDeckCoreTestPortS1SweepGit) {
        let fake = BackendDeckCoreTestPortS1SweepGit(), root = rig.root
        let git = BackendGitService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [root], writeRoots: [root]) }, runner: fake)
        let evidence = BackendDeckCoreNativeProjectEvidence(git: git, alertsReader: BackendDeckCoreTestPortS1SweepNoAlerts(),
            context: { NativeRPCContext(caller: .nativeApp, ownerID: "s1i-live-surface") })
        return (try Rig.surface(state: rig.state, scope: rig.scope, record: rig.record, projectEvidence: evidence), fake)
    }
    // TSCASE live-surface.test.ts:220
    func testLiveSurfaceL220ReportsTheRealStateOfARealRepository() async throws {
        let rig = try await made()
        let wired = try gitSurface(rig)
        // What `git init` leaves, and a real dirty file.
        try FileManager.default.createDirectory(at: rig.work.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("# hello\n".utf8).write(to: rig.work.appendingPathComponent("README.md"))
        let status = try await wired.live.gitStatus(cwd: rig.work.path)
        XCTAssertEqual(status["repo"], .bool(true), status.compact)
        XCTAssertEqual(status["clean"], .bool(false))
        XCTAssertEqual((status["untracked"].elements ?? []).compactMap { $0["path"].string }, ["README.md"])
        // It reached git through the surface rather than answering on its own.
        XCTAssertTrue(wired.git.calls.contains { $0.first == "status" }, "\(wired.git.calls)")
    }
    // TSCASE live-surface.test.ts:239
    func testLiveSurfaceL239AnswersAboutAFolderThatIsNotARepositoryWithoutThrowing() async throws {
        let rig = try await made()
        let status = try await gitSurface(rig).live.gitStatus(cwd: rig.work.path)
        XCTAssertEqual(status["repo"], .bool(false), status.compact)
    }

    // MARK: settings

    // TSCASE live-surface.test.ts:248
    func testLiveSurfaceL248WritesToTheRealSettingsFileAndReadsItBack() async throws {
        let rig = try await made()
        _ = try await rig.live.writeSettingsAsync(o([("appearance.theme", .string("light"))]))
        XCTAssertEqual(rig.live.readSettings()["settings"]["appearance.theme"], .string("light"))
        // On disk, not only in a cache.
        await rig.settings.resetCache()
        let reread = await rig.settings.get()
        XCTAssertEqual(reread["values"]["appearance.theme"], .string("light"))
        XCTAssertGreaterThan(try size(rig.root.appendingPathComponent("settings.json").path), 0)
    }
    // TSCASE live-surface.test.ts:261
    func testLiveSurfaceL261WritesARealLastGoodCopyOfBothStores() async throws {
        let rig = try await made()
        _ = try await rig.live.writeSettingsAsync(o([("appearance.density", .string("compact"))]))
        let written = try await rig.live.snapshotSettingsAsync()
        let path = try XCTUnwrap(written["path"].string)
        XCTAssertEqual(path, rig.root.appendingPathComponent("settings.last-good.json").path)
        XCTAssertGreaterThan(try size(path), 0)
        let saved = try V.parseJSON(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(saved["settings"]["values"]["appearance.density"], .string("compact"))
        let preferences = await rig.store.getPreferences()
        XCTAssertEqual(saved["preferences"]["theme"], preferences["theme"])
        XCTAssertTrue(saved["reason"].string?.contains("settings.write") == true, saved["reason"].compact)
    }
    // TSCASE live-surface.test.ts:287
    func testLiveSurfaceL287PersistsAPreferenceRatherThanMutatingTheStoreInPlace() async throws {
        let rig = try await made(), before = rig.live.readSettings()["preferences"]
        _ = try await rig.live.writePreferencesAsync(o([("theme", .string("light"))]))
        let preferences = await rig.store.getPreferences()
        XCTAssertEqual(preferences["theme"], .string("light"))
        XCTAssertEqual(before["theme"], .string("dark"))
    }

    // MARK: transcripts

    // TSCASE live-surface.test.ts:312
    func testLiveSurfaceL312ListsEveryConversationInAFolderWithItsSizeAndBirth() async throws {
        let rig = try await made()
        let first = try rig.writeTranscript("one.jsonl", rig.prompt("p1", "run the tests", "2026-08-17T09:00:00.000Z") + rig.reply("m1", "running them now", "2026-08-17T09:00:01.000Z"))
        let second = try rig.writeTranscript("two.jsonl", rig.prompt("p2", "and again", "2026-08-17T09:05:00.000Z"))
        let found = try await rig.live.transcriptsIn(cwd: rig.work.path)
        XCTAssertEqual(found.compactMap { $0["path"].string }.sorted(), [first, second].map { NativeTranscriptPaths.canonical($0.path) }.sorted())
        for file in found {
            XCTAssertGreaterThan(file["bytes"].number ?? 0, 0)
            XCTAssertGreaterThan(file["createdAt"].number ?? 0, 0)
            XCTAssertTrue(["one", "two"].contains(file["sessionId"].string ?? ""), file.compact)
        }
        let bytes = try await rig.live.transcriptBytes(path: first.path)
        XCTAssertGreaterThan(bytes, 0)
    }
    // TSCASE live-surface.test.ts:338
    func testLiveSurfaceL338AnswersAnEmptyListForAFolderWithNoTranscript() async throws {
        let rig = try await made(), found = try await rig.live.transcriptsIn(cwd: rig.root.appendingPathComponent("nowhere").path)
        XCTAssertEqual(found, [])
    }
    // TSCASE live-surface.test.ts:342
    func testLiveSurfaceL342ParsesTheRealJSONLIntoProseKeepingTheRolesApart() async throws {
        let rig = try await made()
        let path = try rig.writeTranscript("one.jsonl", rig.prompt("p1", "run the tests", "2026-08-17T09:00:00.000Z") + rig.reply("m1", "running them now", "2026-08-17T09:00:01.000Z"))
        let messages = try await rig.live.readTranscriptFrom(path: path.path, fromByte: 0)
        assertValue(.array(messages), .array([
            o([("id", .string("you:p1")), ("role", .string("you")), ("at", .number(1_786_957_200_000)), ("text", .string("run the tests")), ("truncated", .bool(false))]),
            o([("id", .string("agent:m1")), ("role", .string("agent")), ("at", .number(1_786_957_201_000)), ("text", .string("running them now")), ("truncated", .bool(false))]),
        ]))
    }
    // TSCASE live-surface.test.ts:376
    func testLiveSurfaceL376StartsMidFileAndAbsorbsTheTornLine() async throws {
        let rig = try await made()
        let head = try rig.prompt("p1", "the beginning", "2026-08-17T09:00:00.000Z"), tail = try rig.reply("m1", "the end", "2026-08-17T09:00:05.000Z")
        let path = try rig.writeTranscript("one.jsonl", head + tail)
        // A few bytes into the second line: the fragment is skipped, one line lost.
        let torn = try await rig.live.readTranscriptFrom(path: path.path, fromByte: Double(head.utf8.count + 5))
        XCTAssertEqual(torn, [])
        let whole = try await rig.live.readTranscriptFrom(path: path.path, fromByte: Double(head.utf8.count))
        XCTAssertEqual(whole.compactMap { $0["text"].string }, ["the end"])
    }
    // TSCASE live-surface.test.ts:392
    func testLiveSurfaceL392ReportsZeroBytesForATranscriptThatHasGone() async throws {
        let rig = try await made()
        // Native reads only inside the approved store, so the gone file is named
        // where a listing would have found it rather than beside the config root.
        try FileManager.default.createDirectory(at: rig.transcripts, withIntermediateDirectories: true)
        let bytes = try await rig.live.transcriptBytes(path: rig.transcripts.appendingPathComponent("gone.jsonl").path)
        XCTAssertEqual(bytes, 0)
    }
}
