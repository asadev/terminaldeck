import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct Routines21ReportsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routines21-reports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private var routine: BackendRoutinesRoutine { .init(id: "daily", name: "Daily check", triggers: [.manual], folder: "/tmp/routines21", prompt: "Read changes.") }
    @Test func everyRunPostsEvenShortOrNothingReportsAndKeepsOldEntries() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets())
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery, now: { 1000 })
        let runner = BackendRoutines21ReportingRunner(runner: Routines21ShortRunner(), reports: reports)
        _ = await runner.run(.init(routine: routine, runId: "one", cause: .manual(by: "test"), chain: []))
        _ = await runner.run(.init(routine: routine, runId: "two", cause: .manual(by: "test"), chain: []))
        let rows = try await reports.reports("daily")
        #expect(rows.count == 2 && rows.map { $0["runId"].string } == ["one", "two"])
        #expect(rows.allSatisfy { $0["text"].string == "Found one change." && $0["status"].string == "ok" && $0["at"].number == 1000 })
        let reopened = BackendRoutines21Reports(directory: dir, delivery: delivery)
        #expect(try await reopened.reports("daily") == rows)
        let nothing = BackendRoutines21Reports.reportText(.init(ok: true, output: "NOTHING-TO-REPORT"))
        #expect(nothing.contains("nothing new"))
    }
    @Test func failedRunHasItsOwnReportAndDeliveryFailureDoesNotChangeRun() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let counter = Routines21ReportsProbe()
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: { _ in await counter.hit(); return .init(status: 401) })
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery)
        _ = try await reports.setDestinations("daily", raw: [Routines21Destination(id: "hook", kind: "webhook", label: "Webhook", url: "http://127.0.0.1:1/report").wire])
        let runner = BackendRoutines21ReportingRunner(runner: Routines21ShortRunner(), reports: reports)
        let result = await runner.run(.init(routine: routine, runId: "ok", cause: .manual(by: "test"), chain: []))
        let attempts = await counter.hits
        #expect(result.ok && attempts == 2)
        let rows = try await reports.reports("daily")
        #expect(rows[0]["status"].string == "ok")
        let receipt = try #require(rows[0]["deliveries"].elements?.first)
        #expect(receipt["status"].string == "failed")
        #expect(receipt["attempts"].number == 2)
        try await reports.postRun(.init(routine: routine, runId: "failed", cause: .manual(by: "test"), chain: []), outcome: .init(ok: false, error: "Could not read the folder."))
        let failed = try await reports.reports("daily").last
        #expect(failed?["status"].string == "failed" && failed?["text"].string?.contains("Could not read") == true)
    }
    @Test func questionsStartDistinctJobsAndPersistTheirAnswersWithoutSendingToDestinations() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let probe = Routines21ReportsProbe()
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: { _ in await probe.hit(); return .init(status: 200) })
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery, followUp: { _, brief, jobID in
            await probe.job(jobID, brief); return .init(ok: true, sessionIds: [jobID], output: "Here is the answer.")
        })
        try await reports.postRun(.init(routine: routine, runId: "old", cause: .manual(by: "test"), chain: []), outcome: .init(ok: true, output: "Read three files."))
        let first = try await reports.ask(routine, text: "Which files?", reportID: "run-old")
        let second = try await reports.ask(routine, text: "What changed?", reportID: "run-old")
        #expect(first["jobId"].string != second["jobId"].string)
        for _ in 0..<100 {
            if try await reports.reports("daily").filter({ $0["kind"].string == "answer" }).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let rows = try await reports.reports("daily")
        #expect(rows.filter { $0["kind"].string == "question" }.count == 2)
        #expect(rows.filter { $0["kind"].string == "answer" }.count == 2)
        #expect(rows.filter { $0["kind"].string == "question" }.allSatisfy { $0["status"].string == "ok" })
        #expect(await probe.hits == 0)
        #expect(await probe.briefs.allSatisfy { $0.contains("Read three files.") })
    }
    @Test func duplicateRunDoesNotSendTwiceAndSecretStaysOutOfFiles() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = BackendConnectedTasksMemorySecrets(), probe = Routines21ReportsProbe()
        let delivery = BackendRoutines21Delivery(secrets: secrets, transport: { _ in await probe.hit(); return .init(status: 200) })
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery)
        let raw = Routines21Destination(id: "hook", kind: "webhook", label: "Webhook", url: "http://127.0.0.1:1/report", secretHeader: "X-Report-Secret").wire.setting("secret", .string("synthetic-private-value"))
        _ = try await reports.setDestinations("daily", raw: [raw])
        let request = BackendRoutinesRunRequest(routine: routine, runId: "same", cause: .manual(by: "test"), chain: [])
        try await reports.postRun(request, outcome: .init(ok: true, output: "Done."))
        try await reports.postRun(request, outcome: .init(ok: true, output: "Done."))
        #expect(await probe.hits == 1)
        #expect(try await reports.destinations("daily").first?.hasSecret == true)
        let text = try String(contentsOf: dir.appendingPathComponent("daily-destinations.json"), encoding: .utf8)
        #expect(!text.contains("synthetic-private-value"))
    }
    // U66: the agent's late answer replaces the "still running" report and is sent again.
    @Test func lateAnswerReplacesTheStillRunningReport() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let probe = Routines21ReportsProbe()
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: { _ in await probe.hit(); return .init(status: 200) })
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery)
        _ = try await reports.setDestinations("daily", raw: [Routines21Destination(id: "hook", kind: "webhook", label: "Webhook", url: "http://127.0.0.1:1/report").wire])
        let request = BackendRoutinesRunRequest(routine: routine, runId: "long", cause: .manual(by: "test"), chain: [])
        try await reports.postRun(request, outcome: BackendRoutines21TaskWaiter.stillRunning("task-1"))
        try await reports.finishLate(request, outcome: .init(ok: true, output: "Reviewed the week."))
        let rows = try await reports.reports("daily")
        #expect(rows.count == 1 && rows[0]["text"].string == "Reviewed the week." && rows[0]["status"].string == "ok")
        #expect(await probe.hits == 2)
        try await reports.postRun(request, outcome: BackendRoutines21TaskWaiter.stillRunning("task-1"))
        #expect(try await reports.reports("daily")[0]["text"].string == "Reviewed the week.")
    }
    // #358: a destination taken off the list, or a deleted routine, takes its secret along; a later one with the same id starts without it.
    @Test func removedDestinationsTakeTheirSecretAlong() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = BackendConnectedTasksMemorySecrets(), reports = BackendRoutines21Reports(directory: dir, delivery: BackendRoutines21Delivery(secrets: secrets))
        let hook = Routines21Destination(id: "hook", kind: "webhook", label: "Webhook", url: "http://127.0.0.1:1/report", secretHeader: "X-Report-Secret").wire, key = "routines21-webhook-5-daily-hook"
        _ = try await reports.setDestinations("daily", raw: [hook.setting("secret", .string("synthetic-private-value"))])
        #expect(try secrets.read(key) == "synthetic-private-value")
        _ = try await reports.setDestinations("daily", raw: [])
        #expect(try secrets.read(key) == nil)
        _ = try await reports.setDestinations("daily", raw: [hook.setting("url", .string("http://127.0.0.1:2/other"))])
        #expect(try await reports.destinations("daily").first?.hasSecret == false)
        _ = try await reports.setDestinations("daily", raw: [hook.setting("secret", .string("synthetic-private-value"))])
        await reports.forgetDestinations("daily")
        #expect(try secrets.read(key) == nil); #expect(try await reports.destinations("daily").isEmpty)
    }
    @Test func channelsReadSetAndTestSavedDestinations() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: { _ in .init(status: 200) })
        let reports = BackendRoutines21Reports(directory: dir, delivery: delivery)
        let store = BackendRoutinesStore(directory: dir.appendingPathComponent("routines")); _ = try store.save(routine)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: .init(userData: dir), log: { _ in }))
        let api = BackendRoutinesAPI(engine: engine, store: store, reports: reports)
        let registry = NativeChannelRegistry(); try await api.register(on: registry, ownerID: "routines21")
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "test", capabilities: ["routines.read", "routines.write"])
        let raw = Routines21Destination(id: "test", kind: "webhook", label: "Local", url: "http://127.0.0.1:1/report").wire
        _ = try await registry.invoke("routines:set-destinations", context: context, arguments: [.string("daily"), .array([raw])])
        let read = try await registry.invoke("routines:destinations", context: context, arguments: [.string("daily")])
        #expect(read.elements?.count == 1)
        let sent = try await registry.invoke("routines:test-destination", context: context, arguments: [.string("daily"), .string("test")])
        #expect(sent["status"].string == "sent")
        let empty = try await registry.invoke("routines:reports", context: context, arguments: [.string("daily")])
        #expect(empty.elements?.isEmpty == true)
    }
    @Test func mcpReadsSetsAndTestsWithoutRecordingTheSecret() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let probe = Routines21MCPProbe()
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets(), transport: { _ in .init(status: 200) })
        let reports = BackendRoutines21Reports(directory: dir.appendingPathComponent("reports"), delivery: delivery)
        let store = BackendRoutinesStore(directory: dir.appendingPathComponent("routines")); _ = try store.save(routine)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: .init(userData: dir), log: { _ in }))
        let api = BackendRoutinesAPI(engine: engine, store: store, reports: reports)
        try await reports.postRun(.init(routine: routine, runId: "prior", cause: .manual(by: "test"), chain: []), outcome: .init(ok: true, output: "One change found."))
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path }, session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, args, _, _, owner in await probe.note(args, owner: owner) }, record: { _, _, args, _ in await probe.note(args, owner: false) })
        let definitions = try BackendRoutines21MCP.definitions(api: api, access: access)
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: [.read, .act, .alter], cancellation: .init())
        let read = try #require(definitions.first { $0.spec.id == "routines.reports" })
        let readReply = try await read.handler(context, .object([.init("routineId", .string("daily"))]))
        #expect(!readReply.isError)
        let rows = try NativeRPCValue.parseJSON(Data((readReply.content[0]["text"].string ?? "").utf8))
        #expect(rows.elements?.count == 1 && rows.elements?.first?["text"].string == "One change found.")
        let set = try #require(definitions.first { $0.spec.id == "routines.set_destinations" })
        let destination = Routines21Destination(id: "local", kind: "webhook", label: "Local", url: "http://127.0.0.1:1/report", secretHeader: "X-Report-Secret").wire.setting("secret", .string("synthetic-mcp-private"))
        let setReply = try await set.handler(context, .object([.init("routineId", .string("daily")), .init("destinations", .array([destination]))]))
        #expect(!setReply.isError)
        let test = try #require(definitions.first { $0.spec.id == "routines.test_destination" })
        let sent = try await test.handler(context, .object([.init("routineId", .string("daily")), .init("destinationId", .string("local"))]))
        #expect(sent.structuredContent?["status"].string == "sent")
        let recorded = await probe.arguments
        #expect(recorded.count == 6)
        #expect(recorded.allSatisfy { !$0.compact.contains("synthetic-mcp-private") })
        #expect(await probe.ownerChecks == 2)
        #expect(!setReply.content[0]["text"].string!.contains("synthetic-mcp-private"))
        let actualCall = NativeRPCValue.object([.init("destinations", .array([destination])),
            .init("connection", .object([.init("botToken", .string("synthetic-mcp-private"))]))])
        #expect(!BackendDeckCoreSecurityActionLog.scrubArguments(actualCall).compact.contains("synthetic-mcp-private"))
    }
    @Test func mcpRefusesAChangedRoutineBeforeItWritesDestinations() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets())
        let reports = BackendRoutines21Reports(directory: dir.appendingPathComponent("reports"), delivery: delivery)
        let store = BackendRoutinesStore(directory: dir.appendingPathComponent("routines")); _ = try store.save(routine)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: .init(userData: dir), log: { _ in }))
        var replacement = routine; replacement.prompt = "A changed brief."
        let changed = replacement
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path }, session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, _, _, _, _ in _ = try store.save(changed) }, record: { _, _, _, _ in })
        let definitions = try BackendRoutines21MCP.definitions(api: .init(engine: engine, store: store, reports: reports), access: access)
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: [.read, .act, .alter], cancellation: .init())
        let set = try #require(definitions.first { $0.spec.id == "routines.set_destinations" })
        let result = try await set.handler(context, .object([.init("routineId", .string("daily")), .init("destinations", .array([Routines21Destination(id: "hoot", kind: "hoot", label: "Hoot").wire]))]))
        #expect(result.isError)
        #expect(try await reports.destinations("daily").isEmpty)
    }
    @Test func hootReportKeepsExistingChatAndStartsNoTurn() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let chat = try BackendHootChatStore(file: dir.appendingPathComponent("hoot.json"), provider: .codex)
        try await chat.postRoutineReport(routine: "Daily check", runTime: 1000, status: "failed", report: "One check needs attention.")
        try await chat.postRoutineReport(routine: "Daily check", runTime: 2000, status: "ok", report: "All checks passed.")
        let snapshot = await chat.snapshot()
        #expect(snapshot["busy"].bool != true)
        #expect(snapshot["events"].elements?.count == 2)
        let events = try #require(snapshot["events"].elements)
        #expect(events[0]["value"]["routing"]["routineReport"].bool == true)
        #expect(events[0]["value"]["text"].string == "One check needs attention.")
        #expect(events[1]["value"]["text"].string == "All checks passed.")
    }
    @Test func mcpDefinitionsHaveAllActionsAndUsableSchemas() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendRoutinesStore(directory: dir)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: .init(userData: dir), log: { _ in }))
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path }, session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let definitions = try BackendRoutines21MCP.definitions(api: .init(engine: engine, store: store), access: access)
        #expect(definitions.count == 8)
        #expect(definitions.first { $0.spec.id == "routines.reports_chat" }?.spec.inputSchema["properties"]["seenSequence"]["type"].string == "integer")
        #expect(Set(definitions.map { $0.spec.wireName }).contains("routines_test_destination"))
        #expect(definitions.first { $0.spec.id == "routines.set_destinations" }?.spec.inputSchema["properties"]["destinations"]["type"].string == "array")
    }
    // #336: the history keeps its newest entries with numbers that never move, and the chat sends the newest page.
    @Test func historyKeepsTheNewestEntriesWithStableNumbersAndTheChatPagesThem() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let kept = BackendRoutines21Reports.keptEntries
        let old = (1...kept).map { NativeRPCValue.object([.init("id", .string("run-\($0)")), .init("kind", .string("report")), .init("text", .string("Old.")), .init("at", .number(Double($0)))]) }
        try NativeRPCValue.array(old).encodedJSON().write(to: dir.appendingPathComponent("daily-reports.json"))
        let reports = BackendRoutines21Reports(directory: dir, delivery: BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets()))
        _ = try await reports.readChat("daily", seen: 3)
        try await reports.postRun(.init(routine: routine, runId: "new", cause: .manual(by: "test"), chain: []), outcome: .init(ok: true, output: "New."))
        let rows = try await reports.reports("daily")
        #expect(rows.count == kept && rows.first?["id"].string == "run-2" && rows.last?["sequence"].number == Double(kept + 1))
        let chat = try await reports.readChat("daily")
        #expect(chat["entries"].elements?.count == BackendRoutines21Reports.chatEntries && chat["entries"].elements?.last?["id"].string == "run-new")
        #expect(chat["unread"]["seenSequence"].number == 3 && chat["unread"]["count"].number == Double(kept - 2))
    }
    // #335: a question whose job ended with the app is answered as such, not left Working.
    @Test func aQuestionLeftWorkingWhenTheAppClosedSaysSo() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let question = NativeRPCValue.object([.init("id", .string("question-gone")), .init("kind", .string("question")), .init("jobId", .string("gone")),
            .init("at", .number(1)), .init("status", .string("pending")), .init("text", .string("Which files?"))])
        try NativeRPCValue.array([question]).encodedJSON().write(to: dir.appendingPathComponent("daily-reports.json"))
        let reports = BackendRoutines21Reports(directory: dir, delivery: BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets()), now: { 2000 })
        let rows = try await reports.reports("daily")
        #expect(rows.first?["status"].string == "failed")
        #expect(rows.last?["kind"].string == "answer" && rows.last?["text"].string?.contains("closed before the answer") == true)
    }
}
private struct Routines21ShortRunner: BackendRoutinesRunner {
    let cancellable = true
    func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome { .init(ok: true, output: "Found one change.") }
}
private actor Routines21ReportsProbe {
    var hits = 0, jobs: [String] = [], briefs: [String] = []
    func hit() { hits += 1 }
    func job(_ id: String, _ brief: String) { jobs.append(id); briefs.append(brief) }
}

private actor Routines21MCPProbe {
    var arguments: [NativeRPCValue] = []
    var ownerChecks = 0
    func note(_ args: NativeRPCValue, owner: Bool) { arguments.append(args); if owner { ownerChecks += 1 } }
}
