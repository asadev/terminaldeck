import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// HOOT-TASKS-SPLIT (Asad, 12 Oct): each task Hoot works on has its own Hoot conversation and process; the chat never
/// carries a task turn; the chat Hoot can still read how a task is going. Scratch folders and stand-in workers only.
final class HootTasksSplitTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() async throws { for folder in folders { try? FileManager.default.removeItem(at: folder) }; folders = [] }
    private func temp(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-hoot-tasks-" + name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Stands in for one task's Hoot (its own conversation): records what it was given.
    private actor Worker: BackendHootTaskWorker {
        let task: String, earlier: Int
        var turns: [BackendHootBackgroundTurn] = [], rested = 0, cancelled = 0
        /// `earlier`: turns the task's conversation already had in processes that rested.
        init(task: String, earlier: Int = 0) { self.task = task; self.earlier = earlier }
        func backgroundTurn(_ turn: BackendHootBackgroundTurn, progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult {
            turns.append(turn); await progress(.started)
            return .init(answer: "Turn \(earlier + turns.count) on \(task): the sign-in fix is in review.", finished: true)
        }
        func cancelBackgroundTurn(reason: String, id: String?) async { cancelled += 1 }
        func rest() async { rested += 1 }
    }
    private final class Made: @unchecked Sendable {
        let lock = NSLock(); var workers: [String: Worker] = [:]; var calls: [String] = []
        func make(_ task: String) -> Worker {
            lock.withLock {
                let worker = Worker(task: task, earlier: calls.filter { $0 == task }.count)
                calls.append(task); workers[task] = worker; return worker
            }
        }
    }

    func testATaskTurnNeverTouchesTheChatTranscript() async throws {
        let chat = try BackendHootChatStore(file: try temp("chat").appendingPathComponent("chat.json"))
        let before = await chat.snapshot()["events"].elements?.count ?? 0
        let memory = try await DeckMemoryStore.open(root: try temp("mem").appendingPathComponent("Memory"), dataRoot: try temp("data"), embedder: nil, watch: false)
        let made = Made()
        let conversations = BackendHootTaskConversations(memory: { memory }) { made.make($0) }
        let result = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "Brief for local:abc")
        XCTAssertTrue(result.finished)
        // The chat's transcript is exactly as it was: no user bubble, no compact line, no bg: record.
        let after = await chat.snapshot()["events"].elements ?? []
        XCTAssertEqual(after.count, before)
        XCTAssertFalse(after.contains { ($0["turnId"].string ?? "").hasPrefix("bg:") })
        // The task's own Hoot got it, with no chat line.
        let turns = await made.workers["local:abc"]!.turns
        XCTAssertEqual(turns.map(\.id), ["local:abc"]); XCTAssertNil(turns.first?.chatLine); XCTAssertEqual(turns.first?.reason, "task")
    }

    /// #555: no keep-open timer. Each turn opens the task's own conversation and its process rests
    /// as soon as the turn ends; the next turn resumes that same conversation.
    func testEachTurnUsesTheTasksOwnConversationAndRestsAfterwards() async throws {
        let memory = try await DeckMemoryStore.open(root: try temp("mem").appendingPathComponent("Memory"), dataRoot: try temp("data"), embedder: nil, watch: false)
        let made = Made()
        let conversations = BackendHootTaskConversations(memory: { memory }) { made.make($0) }
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "one")
        let first = try XCTUnwrap(made.workers["local:abc"])
        let firstRested = await first.rested
        XCTAssertEqual(firstRested, 1, "the process rests when its turn ends")
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "two")
        _ = try await conversations.turn(taskID: "local:xyz", title: "Release notes", message: "three")
        XCTAssertEqual(made.calls, ["local:abc", "local:abc", "local:xyz"], "each turn opens the task's own conversation")
        let second = await made.workers["local:abc"]!.turns.map(\.message)
        XCTAssertEqual(second, ["two"])
        let open = await conversations.tasks()
        XCTAssertEqual(open, [], "nothing is left running between turns")
        XCTAssertEqual(BackendHootTaskConversations.folderName("crm:k1/42"), "crm_k1_42")
    }

    func testTheChatHootCanReadATasksStatusAndSummary() async throws {
        let memory = try await DeckMemoryStore.open(root: try temp("mem").appendingPathComponent("Memory"), dataRoot: try temp("data"), embedder: nil, watch: false)
        let made = Made()
        let conversations = BackendHootTaskConversations(memory: { memory }) { made.make($0) }
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "one")
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "two")
        // One "where we are" topic per task in Hoot's memory, replaced each turn, found by the task's id.
        let topics = try await memory.topics(.hoot)
        XCTAssertEqual(topics.map(\.title), [BackendHootTaskConversations.topicTitle(taskID: "local:abc", title: "Fix sign-in")])
        let topic = try XCTUnwrap(topics.first)
        XCTAssertTrue(topic.body.contains("Turn 2 on local:abc: the sign-in fix is in review.") && topic.body.contains("finished"))
        XCTAssertTrue(topic.body.contains("tasks_get with task local:abc"))
        let found = try await memory.search(.init("Task abc Fix sign-in", kinds: [.topic], limit: 5))
        XCTAssertTrue(found.hits.contains { $0.title.contains("local:abc") })
        // And the chat Hoot is told to read them instead of guessing.
        XCTAssertTrue(BackendHootDesk.howTo.contains("separate task conversations") && BackendHootDesk.howTo.contains("Never guess"))
    }
}

/// HOOT-THREAD: a task's Hoot sees the thread: all of it on its first turn (newest first when long), then every
/// comment posted since its last turn. Its own comments are not repeated to it.
final class HootTaskThreadTests: XCTestCase {
    private actor Worker: BackendHootTaskWorker {
        var messages: [String] = []
        func backgroundTurn(_ turn: BackendHootBackgroundTurn, progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult {
            messages.append(turn.message); return .init(answer: "ok", finished: true)
        }
        func cancelBackgroundTurn(reason: String, id: String?) async {}
        func rest() async {}
    }
    func testTheTasksHootSeesTheThreadThenEveryNewComment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-hoot-thread-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let memory = try await DeckMemoryStore.open(root: folder.appendingPathComponent("Memory"), dataRoot: folder.appendingPathComponent("data"), embedder: nil, watch: false)
        let worker = Worker()
        let conversations = BackendHootTaskConversations(memory: { memory }) { _ in worker }
        typealias C = BackendHootTaskConversations.Comment
        let first = [C(at: 1_000, by: "me", text: "Please fix the sign-in."), C(at: 2_000, by: "ios-fixer", text: "Found it: the token refresh."),
                     C(at: 3_000, by: "hoot", text: "On it."), C(at: 3_500, by: "crm", kind: "context", text: "Client: Acme")]
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "Brief", comments: first)
        let later = first + [C(at: 4_000, by: "ios-fixer", text: "Fix pushed; tests pass."), C(at: 5_000, by: "me", text: "Ship it?")]
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "Brief 2", comments: later)
        _ = try await conversations.turn(taskID: "local:abc", title: "Fix sign-in", message: "Brief 3", comments: later)
        let told = await worker.messages
        XCTAssertTrue(told[0].contains("## The task's thread so far") && told[0].contains("the owner: Please fix the sign-in.")
                      && told[0].contains("ios-fixer: Found it") && told[0].contains("crm (context): Client: Acme"))
        XCTAssertFalse(told[0].contains("On it."), "Hoot's own comment is not repeated to it")
        XCTAssertTrue(told[1].contains("## New on the task's thread since your last turn") && told[1].contains("Fix pushed; tests pass.") && told[1].contains("Ship it?"))
        XCTAssertFalse(told[1].contains("Please fix the sign-in."), "only what is new")
        XCTAssertEqual(told[2], "Brief 3", "nothing new, nothing added")
        // A long thread: the newest comments, the rest named.
        let long = (1...40).map { C(at: Double($0) * 1_000, by: "agent", text: "Update \($0): " + String(repeating: "x", count: 400)) }
        let section = try XCTUnwrap(BackendHootTaskConversations.threadSection(long, seen: nil))
        XCTAssertTrue(section.contains("newest first") && section.contains("Update 40:") && !section.contains("Update 1:") && section.contains("earlier comments left out"))
    }
}
