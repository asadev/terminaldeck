import Foundation
import Darwin
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor TeamChats20Delivery {
    var turns: [String] = []
    func note(_ id: String) { turns.append(id) }
}

private actor TeamChats20HootWorker: BackendHootTaskWorker {
    var rested = false
    func backgroundTurn(_ turn: BackendHootBackgroundTurn, progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult {
        .init(answer: "Finished this job", finished: true)
    }
    func cancelBackgroundTurn(reason: String, id: String?) async {}
    func rest() async { rested = true }
}
private actor TeamChats20HootFactory {
    var workers: [TeamChats20HootWorker] = []
    func make() -> TeamChats20HootWorker { let worker = TeamChats20HootWorker(); workers.append(worker); return worker }
}

private actor TeamChats20Shown {
    var ids: Set<String> = []
    func show(_ id: String) { ids.insert(id) }
    func contains(_ id: String) -> Bool { ids.contains(id) }
}
/// Counts the app's closes of finished jobs: how many ran at once, and refuses one once (a busy helper).
private actor TeamChats20Closes {
    private var running = 0, refused = false
    private(set) var most = 0, done = 0
    func run(refusing: Bool, _ close: @Sendable () async throws -> Void) async throws {
        running += 1; most = max(most, running)
        defer { running -= 1; done += 1 }
        try await Task.sleep(for: .milliseconds(40))
        if refusing, !refused { refused = true; throw BackendSessionFailure.closed }
        try await close()
    }
}

@Suite("Team chats: separate visible jobs and kept history", .serialized)
struct TeamChats20Tests {
    private static let fake = #"""
    #!/bin/sh
    echo $$ > cli.pid
    read init
    id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
    while read line; do
      printf '{"type":"system","subtype":"init","session_id":"fake-job"}\n'
      case "$line" in
        *fail-this-job*) printf '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Fake job failed"]}\n';;
        *) case "$line" in
             *long-tool-job*) count=0
               while [ "$count" -lt 550 ]; do
                 printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"step-%s","name":"Read","input":{"file_path":"/scratch"}}]}}\n' "$count"
                 count=$((count + 1))
               done;;
           esac
           printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Lantern job complete"}]}}\n'
           printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-job","result":"Lantern job complete"}\n';;
      esac
    done
    """#
    private func fixture() throws -> (URL, BackendPTYManager, BackendSpawnSpec) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-team-chats20-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("claude")
        try Data(Self.fake.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        return (root, manager, BackendSpawnSpec(provider: "claude", command: cli.path, args: [], path: "/usr/bin:/bin", tabKey: "same-tab"))
    }
    private func input(_ root: URL, title: String, task: String? = nil) -> BackendCreateSessionInput {
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.chat = true; input.projectId = "deck"; input.agentProfileID = "sessions"
        input.teamJob = .init(fromID: "decker", fromName: "Decker", agentID: "sessions", agentName: "Sessions", title: title, taskID: task)
        return input
    }
    private func gone(_ root: URL) throws -> Bool {
        let pid = try Int32(String(contentsOf: root.appendingPathComponent("cli.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)).unwrap()
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    @Test func oneJobEndsWithNoProcessAndAnotherJobMakesAnotherSearchableHistory() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try await DeckMemoryStore.open(root: root.appendingPathComponent("memory"), dataRoot: root, embedder: nil, watch: false)
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in }, diary: { job, snapshot in
            _ = try await memory.appendDiary(BackendTeamChatDiary.drafts(job, snapshot: snapshot, owner: .role(project: "deck", role: "sessions")))
        })
        let first = try await chats.launch(input(root, title: "First job"), spawn: spawn)
        #expect(manager.list().contains { $0.id == first.id && $0.title == "Decker → Sessions · First job" && $0.chat == true })
        #expect(await chats.conversations(project: "deck", agent: "decker", state: "open").count == 1)
        _ = try await chats.say(first.id, text: "First lantern brief")
        #expect(try await chats.waitForTurn(first.id, timeout: .seconds(8)).state == .done(answer: "Lantern job complete"))
        #expect(try gone(root))
        #expect(manager.pidOf(first.id) == nil)
        #expect(manager.list().first { $0.id == first.id }?.exitCode == 0)
        #expect(await chats.conversations(agent: "sessions", state: "finished").count == 1)
        let saved = try await chats.read(first.id, cursor: 0, limit: 500)
        #expect(saved["readOnly"].bool == true)
        #expect(saved["events"].elements?.contains { $0["value"]["text"].string == "First lantern brief" } == true)
        await #expect(throws: (any Error).self) { try await chats.ensure(first.id) }
        await #expect(throws: (any Error).self) { try await chats.say(first.id, text: "new work") }
        #expect(throws: (any Error).self) { try manager.write(first.id, data: "new work") }
        let found = try await memory.search(.init("lantern", kinds: [.diary], mode: .words))
        #expect(found.hits.contains { $0.labels.session == first.id })
        #expect(found.hits.allSatisfy { $0.labels.agent == "sessions" })

        let second = try await chats.launch(input(root, title: "Second job"), spawn: spawn)
        #expect(second.id != first.id)
        #expect(try await chats.read(second.id, cursor: 0, limit: 500)["events"].elements?.contains { $0["value"]["text"].string == "First lantern brief" } == false)
        _ = try await chats.say(second.id, text: "Second lantern brief")
        #expect(try await chats.waitForTurn(second.id, timeout: .seconds(8)).state == .done(answer: "Lantern job complete"))
        #expect(try gone(root))
        #expect(await chats.conversations(project: "deck", state: "finished").count == 2)
        manager.kill(first.id); manager.kill(second.id)
        let reopened = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        try await reopened.restoreJobHistory()
        // 21 Oct: finished jobs stay off the bar at startup; their history still reads, and opening one registers it.
        #expect(manager.list().isEmpty)
        #expect(await reopened.conversations(project: "deck", state: "finished").count == 2)
        #expect(try await reopened.read(first.id, cursor: 0, limit: 500)["events"].elements?.contains { $0["value"]["text"].string == "First lantern brief" } == true)
        _ = try await reopened.openJobHistory(first.id)
        #expect(manager.list().count == 1)
        #expect(manager.list().allSatisfy { $0.exitCode == 0 && manager.pidOf($0.id) == nil })
        manager.killAll()
        await memory.close()
    }

    /// 22 Oct (Asad, "remove this 128 limit"): a finished job leaves the session list once (unless the person is
    /// looking at it); its record and history stay, and opening it brings it back until it is closed.
    @Test func aFinishedJobLeavesTheListOnceUnlessOnScreenAndOpensAgainOnDemand() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        let shown = TeamChats20Shown()
        await chats.setFinishedJobRetirement { id in
            guard await !shown.contains(id), let meta = manager.list().first(where: { $0.id == id }) else { return }
            try? await chats.removeSession(meta); manager.kill(id) // what the app's Close does
        }
        let watched = try await chats.launch(input(root, title: "On screen"), spawn: spawn)
        await shown.show(watched.id)
        _ = try await chats.say(watched.id, text: "Watched lantern brief")
        #expect(try await chats.waitForTurn(watched.id, timeout: .seconds(8)).state == .done(answer: "Lantern job complete"))
        let job = try await chats.launch(input(root, title: "Off screen"), spawn: spawn)
        _ = try await chats.say(job.id, text: "Quiet lantern brief")
        #expect(try await chats.waitForTurn(job.id, timeout: .seconds(8)).state == .done(answer: "Lantern job complete"))
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.list().contains(where: { $0.id == job.id }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!manager.list().contains { $0.id == job.id })
        #expect(manager.list().contains { $0.id == watched.id && $0.exitCode == 0 })
        #expect(await chats.conversations(state: "finished").count == 2)
        #expect(try await chats.read(job.id, cursor: 0, limit: 500)["events"].elements?.contains { $0["value"]["text"].string == "Quiet lantern brief" } == true)
        _ = try await chats.openJobHistory(job.id)
        await chats.retireFinishedJobs() // a later sweep never takes an explicitly opened history away again
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.list().contains { $0.id == job.id && $0.exitCode == 0 })
        manager.killAll()
    }

    /// 22 Oct (Reviewer, finding 5): finished jobs leave one close at a time (the helper takes 16 connections, and
    /// about 95 finished jobs left at once at a first start), and a refused close is tried again at the next sweep.
    @Test func finishedJobsLeaveOneCloseAtATimeAndARefusedCloseIsTriedAgain() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var ids: [String] = []
        for index in 0..<4 {
            let job = try await chats.launch(input(root, title: "Job \(index)"), spawn: spawn)
            _ = try await chats.say(job.id, text: "Lantern brief \(index)")
            #expect(try await chats.waitForTurn(job.id, timeout: .seconds(8)).state == .done(answer: "Lantern job complete"))
            ids.append(job.id)
        }
        #expect(Set(manager.list().map(\.id)).isSuperset(of: ids)) // finished before any rule: still listed
        let closes = TeamChats20Closes(), refused = ids[2]
        await chats.setFinishedJobRetirement { id in
            try await closes.run(refusing: id == refused) {
                guard let meta = manager.list().first(where: { $0.id == id }) else { return }
                try? await chats.removeSession(meta); manager.kill(id) // what the app's Close does
            }
        }
        await chats.retireFinishedJobs()
        var deadline = ContinuousClock.now + .seconds(5)
        while await closes.done < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await closes.done == 4)
        #expect(await closes.most == 1)
        #expect(manager.list().filter { ids.contains($0.id) }.map(\.id) == [refused])
        await chats.retireFinishedJobs()
        deadline = ContinuousClock.now + .seconds(5)
        while manager.list().contains(where: { $0.id == refused }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!manager.list().contains { ids.contains($0.id) })
        #expect(await closes.most == 1)
        manager.killAll()
    }

    @Test func failedAndStoppedJobsAlsoKeepReadOnlyHistory() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        let failed = try await chats.launch(input(root, title: "Failure"), spawn: spawn)
        _ = try await chats.say(failed.id, text: "fail-this-job")
        let turn = try await chats.waitForTurn(failed.id, timeout: .seconds(8))
        guard case .failed = turn.state else { Issue.record("The failed CLI must fail the job"); return }
        #expect(try gone(root))
        #expect(await chats.conversations(state: "finished").first?.failed == true)
        let stopped = try await chats.launch(input(root, title: "Stopped"), spawn: spawn)
        _ = try await chats.stop(stopped.id)
        #expect(try gone(root))
        #expect(try await chats.read(stopped.id, cursor: nil, limit: 500)["readOnly"].bool == true)
        manager.killAll()
    }

    @Test func fastTaskAnswersWaitForTheTaskBindingBeforeDelivery() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        let delivered = TeamChats20Delivery()
        await chats.setJobObservers(turn: { id, _ in await delivered.note(id) }, closed: { _ in })
        let session = try await chats.launch(input(root, title: "Task", task: "task-1"), spawn: spawn)
        _ = try await chats.say(session.id, text: "task brief")
        _ = try await chats.waitForTurn(session.id, timeout: .seconds(8))
        #expect(try gone(root))
        #expect(await delivered.turns.isEmpty)
        await chats.activateTaskJob(session.id)
        let deadline = ContinuousClock.now + .seconds(3)
        while await delivered.turns.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await delivered.turns == [session.id])
        await chats.activateTaskJob(session.id)
        #expect(await delivered.turns == [session.id])
        manager.killAll()
    }

    @Test func aLongTurnStillFinishesWhenItsBriefLeavesTheLiveWindow() async throws {
        let (root, manager, spawn) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        let session = try await chats.launch(input(root, title: "Long turn"), spawn: spawn)
        _ = try await chats.say(session.id, text: "long-tool-job")
        #expect(try await chats.waitForTurn(session.id, timeout: .seconds(30)).state == .done(answer: "Lantern job complete"))
        #expect(try gone(root))
        #expect(await chats.conversations(state: "finished").count == 1)
        #expect(try await chats.read(session.id, cursor: 0, limit: 500)["events"].elements?.contains { $0["value"]["text"].string == "long-tool-job" } == true)
        manager.killAll()
    }

    @Test func hootTaskVisibilityClosesTheWorkerAndTheNextRequestStartsFresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-hoot-visible20-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try await DeckMemoryStore.open(root: root.appendingPathComponent("memory"), dataRoot: root, embedder: nil, watch: false)
        let factory = TeamChats20HootFactory(), starts = TeamChats20Delivery(), finishes = TeamChats20Delivery()
        let tasks = BackendHootTaskConversations(memory: { memory }, make: { _ in await factory.make() })
        await tasks.setJobVisibility(started: { id, _, _ in await starts.note(id) }, finished: { id, _ in await finishes.note(id) })
        _ = try await tasks.turn(taskID: "one-task", title: "One job", message: "First request")
        _ = try await tasks.turn(taskID: "one-task", title: "Next job", message: "Another request after the answer")
        #expect(await starts.turns == ["one-task", "one-task"])
        #expect(await finishes.turns == ["one-task", "one-task"])
        let workers = await factory.workers
        #expect(workers.count == 2)
        for worker in workers { #expect(await worker.rested) }
        #expect(await tasks.tasks().isEmpty)
        await memory.close()
    }

    @Test func aHootTaskBriefAndAnswerShowInTheirOwnSession() {
        let events = [
            HootChatEvent(conversationID: "job", turnID: "bg:task:one:turn", sequence: 1, provider: .claude,
                record: .init(.session, value: .object([.init("background", .object([.init("brief", .string("The whole job brief"))]))]))),
            HootChatEvent(conversationID: "job", turnID: "bg:task:one:turn", sequence: 2, provider: .claude,
                record: .text(.message, id: "answer", "The job is done")),
            HootChatEvent(conversationID: "job", turnID: "bg:task:one:turn", sequence: 3, provider: .claude, record: .init(.completed))
        ]
        let raw = NativeRPCValue.object([.init("events", .array(events.map(\.wireValue))), .init("busy", .bool(false)), .init("sequence", .number(3))])
        let visible = BackendSessionChats.visibleJobSnapshot(raw, adopted: true)
        #expect(visible["events"].elements?.first?["kind"].string == "user")
        #expect(visible["events"].elements?.first?["value"]["text"].string == "The whole job brief")
        #expect(BackendSessionChats.turn(of: visible).state == .done(answer: "The job is done"))
        #expect(BackendSessionChats.visibleJobSnapshot(raw, adopted: false) == raw)
    }

    @Test func anAdoptedLeadKeepsItsSavedIdentityAndAnExplicitWorkerKeepsItsOwn() {
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: ["/work/imatch"], lead: "agent:commander", leadName: "Commander")]
        let owner = DeckMemorySessionOwner(kind: .lead, id: "imatch", name: "Commander", project: "imatch")
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "lead-session", projectRoot: "/work/imatch")
        let adopted = BackendTeamChatSender.resolve(caller: caller, input: nil, session: nil, owner: owner, projects: projects)
        #expect(adopted == .init(id: "commander", name: "Commander"))
        var input = BackendCreateSessionInput(cwd: "/work/imatch", provider: "claude")
        input.agentProfileID = "sessions"
        input.teamJob = .init(fromID: "commander", fromName: "Commander", agentID: "sessions", agentName: "Sessions", title: "Fix chat")
        #expect(BackendTeamChatSender.resolve(caller: caller, input: input, session: nil, owner: owner, projects: projects) == .init(id: "sessions", name: "Sessions"))
    }

    @Test func taskRequestsAndExternalCallersShowTheirOwnNames() {
        let agents = [NativeRPCValue.object([.init("id", .string("commander")), .init("name", .string("Commander"))])]
        #expect(BackendTeamChatSender.request("taskagent:commander", agents: agents) == .init(id: "commander", name: "Commander"))
        #expect(BackendTeamChatSender.request("hoot") == .init(id: "hoot", name: "Hoot"))
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], keyID: "tools", keyName: "Alex tools")
        #expect(BackendTeamChatSender.resolve(caller: caller, input: nil, session: nil, owner: nil, projects: []) == .init(id: "key:tools", name: "Alex tools"))
    }

    @Test func aHistoryKeepsMoreThanFourThousandEventsAndCanReadFromTheStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-team-history20-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("chat.json")
        let events = (1...4100).map { HootChatEvent(conversationID: "history", turnID: "turn", sequence: $0, provider: .claude,
            record: .init(.message, value: .object([.init("text", .string("Message \($0)"))]))) }
        let value = NativeRPCValue.object([.init("conversationId", .string("history")), .init("provider", .string("claude")), .init("events", .array(events.map(\.wireValue)))])
        try value.encodedJSON().write(to: file)
        let store = try BackendHootChatStore(file: file, retainAllHistory: true)
        let page = await store.snapshot(after: 0, limit: 500)
        #expect(page["events"].elements?.first?["value"]["text"].string == "Message 1")
        #expect(page["cursor"].number == 500 && page["sequence"].number == 4100 && page["hasMore"].bool == true)
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw NativeRPCError.invalidArguments("The fake CLI did not record its process") }
        return value
    }
}
