import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor PulseConsent: BackendPluginsConsent {
    func ask(_ question: BackendPluginsConsentRequest) -> BackendPluginsConsentOutcome { .init(granted: true, at: 1) }
    func shutdown() async {}
}
private actor PulseRows {
    var rows: [BackendTaskRecord] = []
    var hook: (@Sendable () async throws -> Void)?
    func set(_ rows: [BackendTaskRecord]) { self.rows = rows }
    func onRead(_ hook: @escaping @Sendable () async throws -> Void) { self.hook = hook }
    func read() async throws -> [BackendTaskRecord] { if let hook { self.hook = nil; try await hook() }; return rows }
}
private actor PulsePeer: BackendPluginsRunningProcess {
    let answer: BackendPluginsProcess.RequestHandler
    let exit: @Sendable (String) async -> Void
    var active = false
    var project = ""
    var autoComplete: Bool
    var pauseOK = true
    var completeOnPause = false
    var loseStartAck = false
    var support = true
    var uiHook: (@Sendable () async throws -> Void)?
    var jobs: [NativeRPCValue] = []
    var delivered: [NativeRPCValue] = []
    var toolCalls = 0
    var holdStop = false
    var stopping = false
    var stopRelease: CheckedContinuation<Void, Never>?
    var stopObservers: [CheckedContinuation<Void, Never>] = []
    func holdStopping() { holdStop = true }
    func waitForStop() async { if stopping { return }; await withCheckedContinuation { stopObservers.append($0) } }
    func releaseStop() { holdStop = false; stopRelease?.resume(); stopRelease = nil }
    var alive: Bool { active }
    var pid: Int32? { active ? 1234 : nil }
    init(autoComplete: Bool, support: Bool = true, answer: @escaping BackendPluginsProcess.RequestHandler, exit: @escaping @Sendable (String) async -> Void) { self.autoComplete = autoComplete; self.support = support; self.answer = answer; self.exit = exit }
    func configure(pauseOK: Bool = true, completeOnPause: Bool = false, loseStartAck: Bool = false, support: Bool = true) { self.pauseOK = pauseOK; self.completeOnPause = completeOnPause; self.loseStartAck = loseStartAck; self.support = support }
    func onUI(_ hook: @escaping @Sendable () async throws -> Void) { uiHook = hook }
    func start() async throws { active = true }
    func stop(_ why: String) async { stopping = true; let observers = stopObservers; stopObservers = []; for observer in observers { observer.resume() }; if holdStop { await withCheckedContinuation { stopRelease = $0 } }; active = false; await exit(why) }
    func kill(_ why: String) async { await stop(why) }
    func child(_ method: String, _ params: NativeRPCValue) async throws -> NativeRPCValue { try await answer(method, params) }
    func complete(_ params: NativeRPCValue) async throws {
        let tasks = try await answer("tasks.list", .object([]))["tasks"].elements ?? []
        let count = tasks.filter { $0["status"].string == "Done" }.count
        let value = NativeRPCValue.object([.init("count", .number(Double(count)))])
        let old = try await answer("state/get", .object([.init("key", .string("pulse"))]))
        _ = try await answer("state/put", .object([.init("key", .string("pulse")), .init("expected", old["version"]), .init("value", value)]))
        for (method, receipt) in [("jobs/progress", "progress"), ("jobs/checkpoint", "checkpoint"), ("jobs/complete", "complete")] {
            _ = try await answer(method, .object([.init("id", params["id"]), .init("attempt", params["attempt"]), .init("receipt", .string(receipt + "-" + params["attempt"].string!)), .init("value", value)]))
        }
    }
    func request(_ method: String, params: NativeRPCValue, timeoutMilliseconds: Int?) async throws -> NativeRPCValue {
        if method == "initialize" {
            project = params["projects"].elements?.first?.string ?? ""
            return .object([.init("protocol", .number(1)), .init("methods", .array(support ? ["ui/read", "jobs/start", "jobs/pause", "events/deliver"].map(NativeRPCValue.string) : []))])
        }
        guard active else { throw BackendPluginsError(-32000, "stopped fake peer") }
        switch method {
        case "ui/read":
            if let uiHook { self.uiHook = nil; try await uiHook() }
            let state = try await answer("state/get", .object([.init("key", .string("pulse"))]))
            return .object([.init("cards", .array([.object([.init("id", .string("pulse")), .init("project", .string(project)), .init("summary", .string("Finished tasks in this selected project")), .init("status", .string("Ready")), .init("fields", .object([.init("count", state["value"]["count"].number.map(NativeRPCValue.number) ?? .number(0))]))])]))])
        case "jobs/start":
            jobs.append(params)
            if autoComplete { try await complete(params) }
            if loseStartAck { throw BackendPluginsError(-32000, "lost start acknowledgement") }
            return .object([.init("accepted", .bool(true)), .init("attempt", params["attempt"])])
        case "jobs/pause":
            if completeOnPause, let last = jobs.last { try await complete(last) }
            guard pauseOK else { throw BackendPluginsError(-32000, "pause timeout fixture") }
            return .object([.init("paused", .bool(true)), .init("attempt", params["attempt"])])
        case "events/deliver": delivered.append(params); return .object([.init("acknowledged", .bool(true)), .init("id", params["id"])])
        case "tools/call": toolCalls += 1; return .object([.init("text", params["arguments"]["text"])])
        default: throw BackendPluginsError(-32601, "unsupported fake method")
        }
    }
}
private final class PulseFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [PulsePeer] = []
    var autoComplete = true
    var support = true
    func make(_ launch: BackendPluginsProcessLaunch, answer: @escaping BackendPluginsProcess.RequestHandler, exit: @escaping @Sendable (String) async -> Void) -> any BackendPluginsRunningProcess {
        lock.withLock { let peer = PulsePeer(autoComplete: autoComplete, support: support, answer: answer, exit: exit); peers.append(peer); return peer }
    }
    var last: PulsePeer? { lock.withLock { peers.last } }
    var count: Int { lock.withLock { peers.count } }
}

@MainActor final class PluginContractTests: XCTestCase {
    private let caps = ["tasks.read", "ui.contribute", "state.read", "state.write", "jobs.run", "events.receive", "tools.contribute"]
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private func manifest() throws -> NativeRPCValue {
        try .parseJSON(Data(#"{"terminaldeck":1,"id":"pulse","name":"Task pulse","summary":"A scoped fixture","version":"1.0.0","plugin":{"main":"main.js","runtime":"node","capabilities":["tasks.read","ui.contribute","state.read","state.write","jobs.run","events.receive","tools.contribute"],"tools":[{"name":"echo","title":"Echo","description":"Fixture target","tier":"act","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}}],"jobs":[{"id":"update","title":"Update task pulse","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}],"ui":{"cards":[{"id":"pulse","title":"Task pulse","fields":[{"id":"count","label":"Finished tasks"}],"actions":[{"id":"update","title":"Update now","kind":"job","target":"update"},{"id":"echo","title":"Echo","kind":"tool","target":"echo"}]}]},"events":[{"type":"tasks.finished","job":"update","input":{}}]}}"#.utf8))
    }
    private func row(_ id: String = "a", project: String, done: Double? = nil) throws -> BackendTaskRecord {
        try .init(object([("id", .string("local:" + id)), ("keyId", .string("local")), ("externalTaskId", .string(id)), ("project", .string(project)), ("title", .string("Sanitized task")), ("instructions", .string("PRIVATE-DIARY-DO-NOT-SEND")), ("crmStatus", .string(done == nil ? "Working on it" : "Done")), ("completedAt", done.map(NativeRPCValue.number) ?? .null)]))
    }
    private struct Rig {
        let root: URL, folder: URL, project: String, other: String
        let host: BackendPluginsHost, factory: PulseFactory, rows: PulseRows
        let control: BackendDeckCoreSecurityControl, authority: BackendCompositionClientsSecurityAuthority, registry: NativeChannelRegistry
        let owner = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        func native(_ op: String, extra: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            try await registry.invoke(BackendPluginExtensionTools.channel, context: owner, arguments: [.string("pulse"), .object([.init("op", .string(op))] + extra)])
        }
        func mcp(_ op: String, tier: BackendMCPTier = .act, extra: [NativeRPCValue.Field] = [], tools: Set<String>? = nil, before: (@Sendable (String, NativeRPCValue) async throws -> Void)? = nil, caller: BackendDeckCoreSecurityCaller = .local) async throws -> BackendDeckCoreSecurityCallResult {
            let names = tools ?? Set(authority.livePolicies().flatMap { [$0.tool.id, $0.tool.wireName] })
            let grant = BackendDeckCoreSecurityGrant(attended: true, tools: names, caller: { caller }, beforeTool: before)
            return try await authority.withAuthenticatedGrant(grant: grant, cancellation: grant.cancellation) {
                await control.call(name: BackendPluginExtensionTools.id("pulse", tier: tier), arguments: .object([.init("op", .string(op))] + extra), options: .init(caller: caller, granted: names))
            }
        }
        func view() async -> NativeRPCValue { await host.state()["plugins"].elements?.first?["extension"] ?? .null }
        func refresh() async throws { let tools = try await BackendPluginsChannels.tools(host: host, authority: authority); try await authority.replacePluginTools(host: host, registrations: tools) }
    }
    private func rig(automatic: Bool = true, wanted: [String]? = nil, support: Bool = true, privateRoot: URL? = nil) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-contract-" + UUID().uuidString), data = root.appendingPathComponent("data"), folder = data.appendingPathComponent("plugins/pulse")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("A"), other = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try manifest().encodedJSON().write(to: folder.appendingPathComponent("terminaldeck.json")); try Data("fixture only".utf8).write(to: folder.appendingPathComponent("main.js"))
        let path = BackendPluginsFiles.real(project.path), otherPath = BackendPluginsFiles.real(other.path), source = PulseRows(), factory = PulseFactory(); factory.autoComplete = automatic; factory.support = support
        let registry = NativeChannelRegistry()
        let privatePersistence = try privateRoot.map { try BackendTaskPersistence(directory: $0, ownership: .exclusive) }
        let host = BackendPluginsHost(userData: data, runtime: "/fixture/runtime/bin/node", environment: [:], consent: PulseConsent(), services: .init(projects: { [path, otherPath] }), desktop: .init(openFolder: { _ in }, trash: { try FileManager.default.removeItem(at: $0) }), changed: { try? await registry.publish("plugins:changed", arguments: []) }, processFactory: { factory.make($0, answer: $1, exit: $2) }, extensionPersistence: privatePersistence)
        let initial = try [row(project: path), row("b", project: otherPath)]
        await source.set(initial); await host.setTaskPulseSource { try await source.read() }; await host.noteTaskRows(initial)
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("accounts"), homeDirectory: root.appendingPathComponent("home"), appName: "Plugin fixture", appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-execute"), inheritedEnvironment: [:])
        let state = try NativeStateStore(file: configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive)
        let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let contexts = BackendDeckCoreToolContextAuthority(), holder = BackendDeckCoreSecurityTestBox<BackendCompositionClientsSecurityAuthority?>(nil)
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: root.appendingPathComponent("log")), consent: .init(ask: { _ in false }), liveTools: { holder.get()?.livePolicies() ?? [] })
        let authority = BackendCompositionClientsSecurityAuthority(contexts: contexts, manager: manager, profiles: profiles, surface: BackendDeckCoreTestPortSecuritySurface(), pluginControl: control); holder.set(authority)
        await host.scan()
        let allowed = await host.allow("pulse", input: object([("capabilities", .array((wanted ?? caps).map(NativeRPCValue.string))), ("projects", .array([.string(path)]))]))
        XCTAssertEqual(allowed["ok"], .bool(true)); XCTAssertEqual(factory.count, 0, "new contract does not auto-start on grant")
        let definitions = try await BackendPluginsChannels.tools(host: host, authority: authority); try await authority.replacePluginTools(host: host, registrations: definitions)
        let dispatch: BackendPluginExtensionTools.OwnerDispatch = { context, tool, args in try await authority.dispatchNativePlugin(context: context, control: control, tool: tool, arguments: args) }
        try await BackendPluginExtensionTools.register(registry: registry, ownerID: "fixture", host: host, dispatch: dispatch)
        try await BackendPluginsChannels.register(registry: registry, ownerID: "fixture", host: host, dispatch: dispatch)
        addTeardownBlock { await host.stopAll(); await profiles.close(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, folder: folder, project: path, other: otherPath, host: host, factory: factory, rows: source, control: control, authority: authority, registry: registry)
    }
    private func job(_ receipt: String, project: String) -> [NativeRPCValue.Field] { [.init("job", .string("update")), .init("project", .string(project)), .init("input", .object([])), .init("request", .string(receipt))] }
    func testNativeAndMCPTaskPulseThroughActualSharedDispatcher() async throws {
        let r = try await rig(); _ = try await r.native("start")
        _ = try await r.native("read")
        let result = try await r.native("card", extra: [.init("card", .string("pulse")), .init("action", .string("update")), .init("project", .string(r.project)), .init("input", .object([])), .init("request", .string("native-update"))])
        XCTAssertEqual(result["jobs"].elements?.last?["state"], .string("completed"))
        let mcp = try await r.mcp("job-start", extra: job("mcp-update", project: r.project)); XCTAssertTrue(mcp.ok)
        let view = try await r.native("read"); XCTAssertEqual(view["cards"].elements?.first?["fields"]["count"], .number(0))
        let peer = try XCTUnwrap(r.factory.last), starts = await peer.jobs; XCTAssertEqual(starts.count, 2)
        let read = try await peer.child("state/get", object([("key", .string("pulse"))])); XCTAssertEqual(read["value"]["count"], .number(0))
        let scoped = try await peer.child("tasks.list", .object([])); XCTAssertEqual(scoped["tasks"].elements?.count, 1); XCTAssertFalse(scoped.compact.contains("PRIVATE-DIARY")); XCTAssertFalse(scoped.compact.contains(r.other))
    }
    func testRealFinishedSourceScopedAcknowledgedPausedBacklogAndDuplicate() async throws {
        let r = try await rig(); _ = try await r.native("start")
        let done = try [row(project: r.project, done: 100), row("b", project: r.other, done: 100)]
        await r.rows.set(done); await r.host.noteTaskRows(done)
        var view = await r.view(); XCTAssertEqual(view["events"]["pending"].elements?.count, 1); XCTAssertEqual(view["events"]["paused"], .bool(true))
        let resumed = try await r.mcp("events-resume", tier: .alter); XCTAssertTrue(resumed.ok)
        view = await r.view(); XCTAssertEqual(view["events"]["acknowledged"].elements?.count, 1); XCTAssertEqual(view["jobs"].elements?.count, 1)
        await r.host.noteTaskRows([]); await r.host.noteTaskRows(done)
        let peer = try XCTUnwrap(r.factory.last), events = await peer.delivered, jobs = await peer.jobs
        XCTAssertEqual(events.count, 1); XCTAssertEqual(jobs.count, 1); XCTAssertFalse(events[0].compact.contains("PRIVATE-DIARY")); XCTAssertFalse(events[0].compact.contains("title"))
    }
    func testJobReceiptsCheckpointPauseExplicitResumeAndLateGeneration() async throws {
        let r = try await rig(automatic: false); _ = try await r.native("start")
        let first = try await r.native("job-start", extra: job("one", project: r.project)), record = try XCTUnwrap(first["jobs"].elements?.last), peer = try XCTUnwrap(r.factory.last)
        _ = try await r.native("job-start", extra: job("one", project: r.project)); var starts = await peer.jobs; XCTAssertEqual(starts.count, 1)
        do { _ = try await r.native("job-start", extra: job("two", project: r.project)); XCTFail("Second active job admitted") } catch {}
        _ = try await peer.child("jobs/checkpoint", object([("id", record["id"]), ("attempt", record["attempt"]), ("receipt", .string("checkpoint")), ("value", .string("untrusted saved offset"))]))
        let paused = try await r.native("job-pause"); XCTAssertEqual(paused["jobs"].elements?.last?["state"], .string("paused"))
        let next = try await r.native("job-resume", extra: job("resume", project: r.project)); XCTAssertEqual(next["jobs"].elements?.last?["state"], .string("running"))
        starts = await peer.jobs; XCTAssertEqual(starts.count, 2); XCTAssertNotEqual(starts[0]["attempt"], starts[1]["attempt"]); XCTAssertEqual(starts[1]["checkpoint"], .string("untrusted saved offset")); XCTAssertEqual(starts[1]["checkpointUntrusted"], .bool(true))
        do { _ = try await peer.child("jobs/complete", object([("id", record["id"]), ("attempt", record["attempt"]), ("receipt", .string("late")), ("value", .null)])); XCTFail("Old attempt completed current job") } catch {}
        let privatePersistence = try BackendTaskPersistence(directory: r.root.appendingPathComponent("data/plugin-host-private"), ownership: .exclusive)
        let reopened = try BackendPluginExtensionStore(persistence: privatePersistence).read("pulse")
        XCTAssertEqual(reopened["jobs"].elements?.last?["state"], .string("interrupted")); XCTAssertEqual(reopened["events"]["paused"], .bool(true))
        _ = await r.host.setEnabled("pulse", false)
        do { _ = try await peer.child("state/get", object([("key", .string("pulse"))])); XCTFail("Old generation still reads") } catch {}
    }
    /// Review paperclip #2: a full history of finished jobs no longer refuses every new job, and chatty progress stays bounded.
    func testFinishedJobHistoryIsTrimmedAndProgressStaysWithinItsBudget() async throws {
        let seedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-private-" + UUID().uuidString)
        let seedStore = try BackendTaskPersistence(directory: seedRoot, ownership: .exclusive)
        let finished = (0..<100).map { index in object([("id", .string("old-\(index)")), ("job", .string("update")), ("project", .string("/seed")), ("input", .object([])), ("request", .string("old-\(index)")),
            ("attempt", .string("attempt-\(index)")), ("attempts", .array([.string("attempt-\(index)")])), ("state", .string("completed")), ("checkpoint", .null), ("progress", .array([]))]) }
        try seedStore.write("plugin-pulse.json", value: object([("version", .number(1)), ("kv", .object([])), ("jobs", .array(finished)),
            ("events", object([("paused", .bool(true)), ("pending", .array([])), ("acknowledged", .array([])), ("overflow", .number(0))]))]))
        addTeardownBlock { try? FileManager.default.removeItem(at: seedRoot) }
        let r = try await rig(automatic: false, privateRoot: seedRoot); _ = try await r.native("start")
        let started = try await r.native("job-start", extra: job("after-full-history", project: r.project))
        let jobs = try XCTUnwrap(started["jobs"].elements), record = try XCTUnwrap(jobs.last), peer = try XCTUnwrap(r.factory.last)
        XCTAssertEqual(record["state"], .string("running")); XCTAssertLessThanOrEqual(jobs.count, BackendPluginsHost.finishedJobHistory)
        let note = String(repeating: "x", count: 7_000)
        for index in 0..<40 {
            _ = try await peer.child("jobs/progress", object([("id", record["id"]), ("attempt", record["attempt"]), ("receipt", .string("note-\(index)")), ("value", .string(note))]))
        }
        _ = try await peer.child("jobs/complete", object([("id", record["id"]), ("attempt", record["attempt"]), ("receipt", .string("done")), ("value", .null)]))
        let view = await r.view(), last = try XCTUnwrap(view["jobs"].elements?.last)
        XCTAssertEqual(last["state"], .string("completed"))
        XCTAssertLessThanOrEqual(try last["progress"].encodedJSON().count, BackendPluginsHost.progressBytesPerJob)
    }
    func testPauseFailureStopsOnlyOwnPluginAndNeverClaimsPaused() async throws {
        let r = try await rig(automatic: false); _ = try await r.native("start"); _ = try await r.native("job-start", extra: job("one", project: r.project))
        let peer = try XCTUnwrap(r.factory.last); await peer.configure(pauseOK: false)
        let paused = try await r.native("job-pause"); XCTAssertEqual(paused["jobs"].elements?.last?["state"], .string("interrupted")); let alive = await peer.alive; XCTAssertFalse(alive)
        let count = r.factory.count; _ = await r.host.state(); XCTAssertEqual(r.factory.count, count, "state/reopen must not auto-resume")
    }
    func testCompletionSurvivesLatePauseAckAndLostStartAck() async throws {
        let r = try await rig(automatic: false); _ = try await r.native("start"); _ = try await r.native("job-start", extra: job("one", project: r.project))
        let peer = try XCTUnwrap(r.factory.last); await peer.configure(completeOnPause: true)
        let result = try await r.native("job-pause"); XCTAssertEqual(result["jobs"].elements?.last?["state"], .string("completed"))
        do { _ = try await r.native("job-resume", extra: job("resume", project: r.project)); XCTFail("Completed job became resumable") } catch {}
        let lost = try await rig(); _ = try await lost.native("start"); let lostPeer = try XCTUnwrap(lost.factory.last); await lostPeer.configure(loseStartAck: true)
        do { _ = try await lost.native("job-start", extra: job("lost", project: lost.project)); XCTFail("Lost ack claimed success") } catch {}
        let view = await lost.view(); XCTAssertEqual(view["jobs"].elements?.last?["state"], .string("completed"))
        _ = try await lost.native("job-start", extra: job("lost", project: lost.project)); let calls = await lostPeer.jobs; XCTAssertEqual(calls.count, 1)
    }
    func testUncertainStartHoldsAdmissionUntilOldGenerationActuallyStops() async throws {
        let r = try await rig(automatic: false); _ = try await r.native("start")
        let peer = try XCTUnwrap(r.factory.last); await peer.configure(loseStartAck: true); await peer.holdStopping()
        let first = Task { try? await r.native("job-start", extra: self.job("unknown", project: r.project)) }
        await peer.waitForStop()
        let denied = try await r.mcp("job-start", extra: job("second", project: r.project)); XCTAssertFalse(denied.ok)
        let jobs = await peer.jobs; XCTAssertEqual(jobs.count, 1); XCTAssertEqual(r.factory.count, 1)
        await peer.releaseStop(); _ = await first.value
        let view = await r.view(); XCTAssertEqual(view["jobs"].elements?.last?["state"], .string("interrupted"))
        _ = try await r.native("job-start", extra: job("after-stop", project: r.project)); XCTAssertEqual(r.factory.count, 2)
    }
    func testManagementNativeAndMCPReadDisabledHistoryWithoutStartingChild() async throws {
        let r = try await rig(automatic: false); _ = try await r.native("start"); _ = try await r.native("job-start", extra: job("one", project: r.project))
        let off = try await r.registry.invoke("plugins:enable", context: r.owner, arguments: [.string("pulse"), .bool(false)])
        XCTAssertEqual(off["ok"], .bool(true)); let count = r.factory.count
        let names: Set<String> = ["plugins.state", "plugins.change"]
        let grant = BackendDeckCoreSecurityGrant(attended: true, tools: names, caller: { .local })
        let state = try await r.authority.withAuthenticatedGrant(grant: grant, cancellation: grant.cancellation) {
            await r.control.call(name: "plugins.state", arguments: .object([]), options: .init(caller: .local, granted: names))
        }
        XCTAssertTrue(state.ok); XCTAssertEqual(state.value["plugins"].elements?.first?["extension"]["jobs"].elements?.last?["state"], .string("interrupted")); XCTAssertEqual(r.factory.count, count)
        _ = try await r.registry.invoke("plugins:remove", context: r.owner, arguments: [.string("pulse")])
        try await r.refresh(); XCTAssertEqual(Set(r.authority.livePolicies().map { $0.tool.id }), BackendPluginManagementTools.ids)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.root.appendingPathComponent("data/plugin-host-private/plugin-pulse.json").path))
    }
    func testHashChangeAfterAwaitAndGrantNarrowingClearSensitiveCaches() async throws {
        let r = try await rig(); _ = try await r.native("start"); _ = try await r.native("read")
        let peer = try XCTUnwrap(r.factory.last), file = r.folder.appendingPathComponent("main.js")
        await peer.onUI { try Data("new bytes".utf8).write(to: file) }
        do { _ = try await r.native("read"); XCTFail("Changed code returned card data") } catch {}
        let alive = await peer.alive; XCTAssertFalse(alive); var view = await r.view(); XCTAssertTrue(view["cards"].elements?.isEmpty == true)
        let next = try await rig(automatic: false); _ = try await next.native("start"); _ = try await next.native("read"); _ = try await next.native("job-start", extra: job("one", project: next.project))
        _ = await next.host.allow("pulse", input: object([("capabilities", .array(caps.map(NativeRPCValue.string))), ("projects", .array([.string(next.other)]))]))
        view = await next.view(); XCTAssertEqual(view["jobs"].elements?.last?["state"], .string("failed")); XCTAssertEqual(view["jobs"].elements?.last?["input"], .null); XCTAssertTrue(view["cards"].elements?.isEmpty == true)
    }
    func testScopedLegacyTasksRPCRechecksHashAfterActualSourceAwait() async throws {
        let r = try await rig(); _ = try await r.native("start"); let peer = try XCTUnwrap(r.factory.last), file = r.folder.appendingPathComponent("main.js")
        await r.rows.onRead { try Data("changed in source callback".utf8).write(to: file) }
        do { _ = try await peer.child("tasks.list", .object([])); XCTFail("Old RPC leaked after source/hash change") } catch {}
        let alive = await peer.alive; XCTAssertFalse(alive)
    }
    func testTargetToolGrantAndBeforeToolCannotBeBypassedByCard() async throws {
        let r = try await rig(); _ = try await r.native("start"); _ = try await r.native("read")
        let input: [NativeRPCValue.Field] = [.init("card", .string("pulse")), .init("action", .string("echo")), .init("project", .string(r.project)), .init("input", object([("text", .string("hello"))]))]
        let missing = try await r.mcp("card", extra: input, tools: [BackendPluginExtensionTools.id("pulse", tier: .act)]); XCTAssertFalse(missing.ok)
        let denied = try await r.mcp("card", extra: input, before: { tool, _ in if tool == "plugin.pulse.echo" { throw NativeRPCError(code: "not-granted", message: "Fixture target denied") } }); XCTAssertFalse(denied.ok)
        let peer = try XCTUnwrap(r.factory.last); var count = await peer.toolCalls; XCTAssertEqual(count, 0)
        _ = try await r.native("card", extra: input); count = await peer.toolCalls; XCTAssertEqual(count, 1)
        let wrong = try await r.mcp("card", tier: .read, extra: input); XCTAssertFalse(wrong.ok)
    }
    func testNamespaceMissingCapsWrongCallerAndUnsupportedPeerRefuse() async throws {
        let r = try await rig(wanted: caps.filter { $0 != "state.write" }); _ = try await r.native("start"); let peer = try XCTUnwrap(r.factory.last)
        do { _ = try await peer.child("state/put", object([("key", .string("k")), ("expected", .number(0)), ("value", .null)])); XCTFail("Missing cap wrote") } catch {}
        do { _ = try await peer.child("state/get", object([("plugin", .string("other")), ("key", .string("k"))])); XCTFail("Payload chose another plugin") } catch {}
        let unsupported = try await rig(support: false); _ = try await unsupported.native("start")
        do { _ = try await unsupported.native("read"); XCTFail("Old protocol-1 peer appeared to support extension methods") } catch {}
        let key = try await r.mcp("start", caller: .init(kind: .key, tiers: [.read, .act, .alter], keyID: "fixture", tasks: true)); XCTAssertFalse(key.ok)
        do { _ = try await r.registry.invoke(BackendPluginExtensionTools.channel, context: .init(caller: .page, ownerID: "forged"), arguments: [.string("pulse"), object([("op", .string("start"))])]); XCTFail("Foreign UI caller entered") } catch {}
    }
    func testKVAtomicCASQuotasNullMissingAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-kv-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), store = BackendPluginExtensionStore(persistence: persistence)
        let first = try store.kv("pulse", method: "state/put", input: object([("key", .string("k")), ("expected", .number(0)), ("value", .null)])); XCTAssertEqual(first["present"], .bool(true))
        XCTAssertThrowsError(try store.kv("pulse", method: "state/put", input: object([("key", .string("k")), ("expected", .number(0)), ("value", .string("stale"))])))
        let missing = try store.kv("pulse", method: "state/get", input: object([("key", .string("missing"))])); XCTAssertEqual(missing["present"], .bool(false))
        let before = try store.read("pulse")
        XCTAssertThrowsError(try store.kv("pulse", method: "state/put", input: object([("key", .string("big")), ("expected", .number(0)), ("value", .string(String(repeating: "x", count: 9000)))])))
        XCTAssertEqual(try store.read("pulse"), before)
        var admitted = 0
        for i in 0..<34 {
            do { _ = try store.kv("aggregate", method: "state/put", input: object([("key", .string("k" + String(i))), ("expected", .number(0)), ("value", .string(String(repeating: "x", count: 8000)))])); admitted += 1 } catch { break }
        }
        XCTAssertGreaterThan(admitted, 0); XCTAssertLessThan(admitted, 34)
        let bounded = try store.read("aggregate")
        XCTAssertThrowsError(try store.kv("aggregate", method: "state/put", input: object([("key", .string("overflow")), ("expected", .number(0)), ("value", .string(String(repeating: "x", count: 8000)))])))
        XCTAssertEqual(try store.read("aggregate"), bounded)
        let reopened = BackendPluginExtensionStore(persistence: persistence); XCTAssertEqual(try reopened.kv("pulse", method: "state/get", input: object([("key", .string("k"))]))["value"], .null)
        XCTAssertThrowsError(try store.kv("../other", method: "state/get", input: object([("key", .string("k"))])))
        for i in 1..<100 { _ = try store.kv("pulse", method: "state/put", input: object([("key", .string("k" + String(i))), ("expected", .number(0)), ("value", .bool(true))])) }
        XCTAssertThrowsError(try store.kv("pulse", method: "state/put", input: object([("key", .string("overflow")), ("expected", .number(0)), ("value", .bool(true))])))
    }
    func testCorruptPrivateVersionsRefuseWithoutNumericTrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-corrupt-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), store = BackendPluginExtensionStore(persistence: persistence)
        let initial = try store.read("pulse")
        try persistence.write("plugin-pulse.json", value: initial.setting("kv", object([("k", object([("version", .number(1e30)), ("present", .bool(true)), ("value", .null)]))])))
        XCTAssertThrowsError(try BackendPluginExtensionStore(persistence: persistence).read("pulse"))
        try persistence.write("tasks-source.json", value: object([("version", .number(1)), ("sequence", .number(1e30))]))
        XCTAssertThrowsError(try BackendPluginExtensionStore(persistence: persistence).finished([]))
    }
    func testEventOverflowAndUnscopedCompletionNeverDeliverOrRunJobs() async throws {
        let r = try await rig(); _ = try await r.native("start")
        let open = try (0..<51).map { try row("task" + String($0), project: r.project) }
        await r.rows.set(open); await r.host.noteTaskRows(open)
        let done = try (0..<51).map { try row("task" + String($0), project: r.project, done: Double($0 + 1)) }
        await r.rows.set(done); await r.host.noteTaskRows(done)
        var view = await r.view(); XCTAssertEqual(view["events"]["pending"].elements?.count, 50); XCTAssertEqual(view["events"]["overflow"], .number(1)); XCTAssertEqual(view["events"]["paused"], .bool(true))
        let peer = try XCTUnwrap(r.factory.last), jobs = await peer.jobs; XCTAssertTrue(jobs.isEmpty)
        let invalid = try [row("none", project: "", done: 1), row("relative", project: "somewhere", done: 2)]
        await r.rows.set(invalid); await r.host.noteTaskRows(invalid); view = await r.view(); XCTAssertEqual(view["events"]["pending"].elements?.count, 50)
    }
    func testHostPrivateStoreRefusesSandboxSystemReadRootBeforeChildOrStoreIO() async throws {
        // The persistence constructor is inert. Host checks the forbidden root
        // before store.read/write; no system file or child is opened here.
        let r = try await rig(privateRoot: URL(fileURLWithPath: "/Library/terminaldeck-forbidden-plugin-fixture"))
        do { _ = try await r.native("start"); XCTFail("Child-readable host receipts accepted") } catch {}
        XCTAssertEqual(r.factory.count, 0)
        let view = await r.view(); XCTAssertTrue(view["problem"].string?.contains("outside child-readable") == true)
    }
    func testManifestRejectsExecutableCardsUnknownFieldsAndNewCapsDefaultOff() throws {
        let raw = try manifest(), parsed = try BackendPluginsManifestReader.parse(raw.compact, folder: "pulse")
        XCTAssertEqual(parsed.contract["cards"].elements?.count, 1)
        var block = raw["plugin"], ui = block["ui"], cards = ui["cards"].elements!
        cards[0] = cards[0].setting("html", .string("<script>bad</script>")); ui = ui.setting("cards", .array(cards)); block = block.setting("ui", ui)
        XCTAssertThrowsError(try BackendPluginsManifestReader.parse(raw.setting("plugin", block).compact, folder: "pulse"))
        let state = PluginsState.from(CodingAIJSON(["plugins": [["id": "pulse", "name": "Pulse", "state": "needs-ok", "declared": caps, "enabled": false, "allowed": false]]]))
        let plugin = try XCTUnwrap(state?.plugins.first), draft = PluginAllowDraft(plugin: plugin)
        XCTAssertTrue(PluginContract.newCapabilities.isDisjoint(with: Set(draft.chosen)))
    }
}
