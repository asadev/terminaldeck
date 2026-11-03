import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

struct ROUTINESBackendTests {
    @Test func ownershipAndTaskTriggersRoundTripWithoutLosingLimits() throws {
        let text = "# Audit\nwhen: task-created\nwhen: task-finished\nin: /tmp/routines-test\nagent-id: critic\nproject-id: imatch\nquiet-for: 2m\ncustom: keep\n---\nRead the task.\n"
        let parsed = try #require(BackendRoutinesFormat.parseRoutine("audit", text: text).routine)
        #expect(parsed.routinesAgentID == "critic")
        #expect(parsed.projectID == "imatch")
        #expect(parsed.triggers.map(\.kind) == ["task-created", "task-finished"])
        #expect(parsed.quietForMs == 120_000)
        let reread = try #require(BackendRoutinesFormat.parseRoutine("audit", text: BackendRoutinesFormat.serializeRoutine(parsed)).routine)
        #expect(reread.routinesAgentID == "critic")
        #expect(reread.projectID == "imatch")
        #expect(reread.unknown["custom"] == ["keep"])
    }
    @Test func saveTextCreatesOnlyThroughNativePersonChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ROUTINES-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await BackendRoutinesService.create(options: .init(userData: root, runner: .disabled))
        let text = "# New\nwhen: schedule 08:30 weekdays\nin: /tmp/routines-test\nagent-id: @hoot\nproject-id: every-project\n---\nRead logs.\n"
        let saved = try await service.api.saveText(.string("new"), text: .string(text))
        #expect(saved.ok)
        #expect(service.store.readText("new").text == text)
        #expect(BackendRoutinesAPI.tiers["routines:save-text"] == .human)
        #expect(BackendRoutinesAPI.tiers["routines:recent-runs"] == .read)
        await service.stop()
    }
    @Test func durableRunReductionKeepsOwnershipAndDoesNotInventTokens() throws {
        let rows = try [
            "{\"action\":\"routine.run\",\"runId\":\"one\",\"routine\":\"audit\",\"at\":\"2026-10-10T00:00:00Z\",\"outcome\":\"started\",\"data\":{\"agentId\":\"critic\",\"projectId\":\"imatch\",\"name\":\"Audit\"}}",
            "{\"action\":\"routine.run\",\"runId\":\"one\",\"routine\":\"audit\",\"at\":\"2026-10-10T00:00:05Z\",\"outcome\":\"failed\",\"detail\":\"Failure\",\"data\":{\"ms\":5000,\"sessions\":[]}}"
        ].map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let result = BackendROUTINESHistory.reduce(rows)
        #expect(result.elements?.count == 1)
        let run = try #require(result.elements?.first)
        #expect(run["agentId"].string == "critic")
        #expect(run["projectId"].string == "imatch")
        #expect(run["outcome"].string == "failed")
        #expect(run["data"]["ms"].number == 5000)
        #expect(run["data"]["tokens"].isNullish)
    }
    @Test func taskEventsIgnoreInitialSnapshotAndFireOnlyRealEdges() async throws {
        let capture = ROUTINESEventCapture()
        let events = BackendROUTINESTaskEvents { kind, row in await capture.add(kind + ":" + row.id) }
        func record(_ id: String, done: Bool = false) throws -> BackendTaskRecord {
            try .init(.object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)), .init("project", .string("/tmp/routines-test")), .init("completedAt", done ? .number(1) : .null)]))
        }
        await events.accept([try record("old")]); #expect(await capture.rows == [])
        await events.accept([try record("old"), try record("new")]); #expect(await capture.rows == ["task-created:local:new"])
        await events.accept([try record("old"), try record("new", done: true)])
        await events.accept([try record("old"), try record("new", done: true)])
        #expect(await capture.rows == ["task-created:local:new", "task-finished:local:new"])
    }
    @Test func retainedTaskChangeFeedDeliversTaskFinishedUntilShutdown() async throws {
        // The composition's wiring: one change hub, its subscription kept by the root.
        let graph = try BackendCompositionRoot(dataRoot: URL(fileURLWithPath: "/tmp/native-routing-fixture"),
            state: NativeStateStore(), environment: [:], home: "/tmp")
        let capture = ROUTINESEventCapture(), rows = ROUTINESTaskRows(), changes = BackendCompositionChangeHub()
        let events = BackendROUTINESTaskEvents { kind, row in await capture.add(kind + ":" + row.id) }
        func record(_ id: String, done: Bool = false) throws -> BackendTaskRecord {
            try .init(.object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)), .init("project", .string("/tmp/routines-test")), .init("completedAt", done ? .number(1) : .null)]))
        }
        await rows.set([try record("one")]); await events.accept(await rows.rows)
        let feed = await changes.observe { await events.accept(await rows.rows) }
        try await graph.retain(.init(name: "routines-task-events", domains: ["routines-task-events"], ownerID: "native.routines-task-events", invokes: [], stop: { await feed.cancelAndWait() }))
        await rows.set([try record("one", done: true)]); await changes.fire()
        #expect(await capture.rows == ["task-finished:local:one"])
        try await graph.shutdown()
        await rows.set([try record("one", done: true), try record("two", done: true)]); await changes.fire()
        #expect(await capture.rows == ["task-finished:local:one"])
    }
    @Test func pausedAgentDoesNotStartAnyRealProcess() async throws {
        let hoot = ROUTINESStubRunner()
        let runner = BackendROUTINESRunner(hoot: hoot, profile: { id in .object([.init("id", .string(id)), .init("name", .string("Critic")), .init("status", .string("paused")), .init("provider", .string("claude"))]) }, profileRun: { _, _ in throw NativeRPCError(code: "test-wrong-launch", message: "The paused profile must never launch.") })
        let routine = BackendRoutinesRoutine(id: "audit", name: "Audit", triggers: [.manual], folder: "/tmp/routines-test", prompt: "Read logs", unknown: ["agent-id": ["critic"]])
        let result = await runner.run(.init(routine: routine, runId: "one", cause: .manual(by: "user"), chain: []))
        #expect(!result.ok)
        #expect(result.error?.contains("paused or archived") == true)
        #expect(await hoot.calls == 0)
    }
    @Test func hootOwnershipReusesExistingRunner() async {
        let hoot = ROUTINESStubRunner()
        let runner = BackendROUTINESRunner(hoot: hoot, profile: { _ in nil }, profileRun: { _, _ in throw NativeRPCError(code: "test-wrong-launch", message: "Hoot uses the existing runner.") })
        let routine = BackendRoutinesRoutine(id: "audit", name: "Audit", triggers: [.manual], folder: "/tmp/routines-test", prompt: "Read logs")
        let result = await runner.run(.init(routine: routine, runId: "one", cause: .manual(by: "user"), chain: []))
        #expect(result.ok)
        #expect(await hoot.calls == 1)
    }
    @Test func scopedProfileJoinReceivesExactOriginalOwnershipAndChain() async throws {
        let hoot = ROUTINESStubRunner(), cancellation = BackendMCPCancellation()
        let agent = NativeRPCValue.object([.init("id", .string("critic")), .init("name", .string("Critic")), .init("status", .string("active")), .init("provider", .string("codex")), .init("skillsOff", .bool(true)), .init("environment", .object([.init("FEATURE", .string("safe"))]))])
        let runner = BackendROUTINESRunner(hoot: hoot, profile: { _ in agent }, profileRun: { request, saved in
            #expect(saved == agent)
            #expect(request.routine.routinesAgentID == "critic")
            #expect(request.routine.projectID == "imatch")
            #expect(request.runId == "owned-run")
            #expect(request.chain == ["parent", "audit"])
            #expect(request.cancellation === cancellation)
            #expect(!request.attended)
            return .init(ok: true, output: "Scoped result", tokens: 20)
        })
        let routine = BackendRoutinesRoutine(id: "audit", name: "Audit", triggers: [.manual], folder: "/tmp/routines-test", prompt: "Read logs", unknown: ["agent-id": ["critic"]], projectID: "imatch")
        let result = await runner.run(.init(routine: routine, runId: "owned-run", cause: .manual(by: "user"), chain: ["parent", "audit"], cancellation: cancellation))
        #expect(result.ok)
        #expect(result.output == "Scoped result")
        #expect(result.tokens == 20)
        #expect(await hoot.calls == 0)
    }
    @Test func missingScopedProfileJoinNeverRunsHootOrLaunchesProcess() async {
        let hoot = ROUTINESStubRunner()
        let runner = BackendROUTINESRunner(hoot: hoot, profile: { id in .object([.init("id", .string(id)), .init("status", .string("active"))]) })
        let routine = BackendRoutinesRoutine(id: "audit", name: "Audit", triggers: [.manual], folder: "/tmp/routines-test", prompt: "Read logs", unknown: ["agent-id": ["critic"]])
        let result = await runner.run(.init(routine: routine, runId: "one", cause: .manual(by: "user"), chain: []))
        #expect(!result.ok)
        #expect(result.error?.contains("scoped routine runner is unavailable") == true)
        #expect(await hoot.calls == 0)
    }
}
private actor ROUTINESEventCapture { var rows: [String] = []; func add(_ row: String) { rows.append(row) } }
private actor ROUTINESTaskRows { var rows: [BackendTaskRecord] = []; func set(_ next: [BackendTaskRecord]) { rows = next } }
private actor ROUTINESStubRunner: BackendRoutinesRunner { var calls = 0; func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome { calls += 1; return .init(ok: true) } }
