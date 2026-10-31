import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Deck Memory, Hoot's desk: the playbook fill, the few lines with each message, and the rule that the
/// app's lines never enter the visible chat. (The planned refresh was removed on 28 Oct 2026.) A private
/// memory store and a stub CLI; no AI is called.
final class L6HootDeskTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("L6HootDesk-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func memory() async throws -> DeckMemoryStore {
        let root = try temporary()
        return try await DeckMemoryStore.open(root: root.appendingPathComponent("memory"), dataRoot: root.appendingPathComponent("data"), embedder: nil, watch: false)
    }

    func testThePlaybookFillsWhatWasLeftOutAndDifferingNeedsAReason() throws {
        let row = DeckMemoryPlaybookRow(jobKind: "bug fix", ai: "Claude Code", model: "claude-opus-5-5", effort: "High",
                                        permission: "auto", instructions: "Run the tests before you report.")
        let filled = try BackendPlaybookFill.resolve(row: row, asked: .init())
        XCTAssertEqual(filled.provider, "claude")
        XCTAssertEqual(filled.model, "claude-opus-5-5")
        XCTAssertEqual(filled.effort, "high")
        XCTAssertEqual(filled.permissionMode, "acceptEdits")
        XCTAssertEqual(filled.instructions, "Run the tests before you report.")
        XCTAssertEqual(filled.fromPlaybook, ["ai", "model", "effort", "permission", "instructions"])

        XCTAssertThrowsError(try BackendPlaybookFill.resolve(row: row, asked: .init(model: "claude-sonnet-5-5"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("reason"))
        }
        let own = try BackendPlaybookFill.resolve(row: row, asked: .init(model: "claude-sonnet-5-5", reason: "a two-line change"))
        XCTAssertEqual(own.model, "claude-sonnet-5-5")
        XCTAssertEqual(own.effort, "high")
        XCTAssertTrue(own.notes.contains { $0.contains("a two-line change") })

        // Bypass is the person's choice: only the playbook can carry it.
        XCTAssertThrowsError(try BackendPlaybookFill.resolve(row: row, asked: .init(permission: "bypass", reason: "faster")))
        let trusted = try BackendPlaybookFill.resolve(row: .init(jobKind: "default", permission: "bypass"), asked: .init(provider: "codex"))
        XCTAssertEqual(trusted.permissionMode, "danger-full-access")

        // A model written for one AI is never handed to another.
        let other = try BackendPlaybookFill.resolve(row: row, asked: .init(provider: "codex"))
        XCTAssertNil(other.model); XCTAssertNil(other.effort)
        XCTAssertEqual(other.permissionMode, "workspace-write")

        let brief = BackendPlaybookFill.brief("Fix the login crash in the iOS app.", choice: filled)
        XCTAssertTrue(brief.hasPrefix("Fix the login crash in the iOS app."))
        XCTAssertTrue(brief.contains("## Standing instructions\nRun the tests before you report."))
        XCTAssertTrue(brief.contains("Done or not done."))
    }

    func testEachMessageGetsItsFewLinesAndACleanDeskGetsTheLastMessages() async throws {
        let memory = try await memory()
        try await memory.saveCard(.hoot, text: "# Hoot\n\n## Top rules\n- Answer in three lines.\n\n## Permissions\n- Never allow a force push.\n")
        try await memory.savePlaybook(.hoot, rows: [.init(jobKind: "bug fix", ai: "claude", model: "claude-opus-5-5", effort: "high"),
                                                    .init(jobKind: "default", model: "claude-sonnet-5-5")])
        try await memory.updateTopic(.hoot, title: "Release 12", body: "Build 12 is in review; waiting on Apple.")
        var hooks = BackendHootDesk.Hooks(); hooks.memory = { memory }
        let desk = BackendHootDesk(hooks: hooks)

        let start = await desk.start(fresh: true, recent: [.init(fromPerson: true, text: "Where is the release?"),
                                                           .init(fromPerson: false, text: "Build 12 is in review.")])
        XCTAssertTrue(start.memoryReady)
        XCTAssertTrue(start.text.contains("Answer in three lines."))
        XCTAssertTrue(start.text.contains("Build 12 is in review; waiting on Apple."))
        XCTAssertTrue(start.text.contains("The person: Where is the release?\n\nYou: Build 12 is in review."))
        XCTAssertTrue(start.text.contains("## How this desk works"))
        let resumed = await desk.start(fresh: false, recent: [])
        XCTAssertFalse(resumed.text.contains("The last messages, word for word"))

        try await memory.updateBoard(.init(id: DeckMemoryBoardRow.rowID(.session, "s1"), kind: .session, stamp: .init(owner: .hoot, session: "s1"),
                                           title: "Login fix", doing: "running the tests"))
        let plain = await desk.lines(for: "thanks")
        XCTAssertTrue(plain.hasPrefix("<deck-memory>") && plain.hasSuffix("</deck-memory>"))
        XCTAssertEqual(DeckMemoryBrief.stripInjected("thanks\n\n" + plain), "thanks\n\n")
        XCTAssertTrue(plain.contains("Answer in three lines."))
        XCTAssertTrue(plain.contains("Login fix"))
        XCTAssertFalse(plain.contains("claude-opus-5-5"))
        XCTAssertLessThan(plain.count, 1_500)

        let work = await desk.lines(for: "please get a bug fix going for the login crash")
        XCTAssertTrue(work.contains("claude-opus-5-5"))
        XCTAssertFalse(work.contains("Login fix"), "a board change is told once")
        try await memory.addNote(.init(title: "Login crash came from the token refresh", body: "The crash on login was the token refresh racing the first request.",
                                       type: .result, stamp: .init(owner: .hoot)))
        let indexed = await desk.lines(for: "what did we find about the login crash last week")
        XCTAssertTrue(indexed.contains("Login crash came from the token refresh"), "what else is stored on this, by title")
        XCTAssertFalse(indexed.contains("racing the first request"), "titles only, never the content")
        let ask = await desk.lines(for: "the session asks for permission to push")
        XCTAssertTrue(ask.contains("Never allow a force push."))
        let command = await desk.lines(for: "/model")
        XCTAssertEqual(command, "")

        let delivered = BackendHootDesk.deliver(hidden: plain, message: "thanks")
        XCTAssertTrue(delivered.hasPrefix("thanks\n\n<deck-memory>") && delivered.hasSuffix("</deck-memory>"))
        XCTAssertEqual(BackendHootDesk.deliver(hidden: "", message: "thanks"), "thanks")

        // The card is edited while the desk is open: the new line goes with the next message, once.
        try await memory.saveCard(.hoot, text: "# Hoot\n\n## Top rules\n- Answer in three lines.\n\n## Permissions\n- Never allow a force push.\n\n## People\n- Sara signs off every release.\n")
        let edited = await desk.lines(for: "ok")
        XCTAssertTrue(edited.contains("Your card was edited") && edited.contains("Sara signs off every release."))
        let later = await desk.lines(for: "ok")
        XCTAssertFalse(later.contains("Your card was edited"))
    }

    func testTheLastMessagesAreASizeBudgetNotACount() {
        let long = String(repeating: "x", count: 5_000)
        let recent: [BackendHootDeskMessage] = [.init(fromPerson: true, text: "OLDEST " + long), .init(fromPerson: false, text: "OLD " + long),
            .init(fromPerson: true, text: "Is build 13 out?"), .init(fromPerson: false, text: "Not yet, it is in review."),
            .init(fromPerson: true, text: "LATEST " + String(repeating: "y", count: 9_000)), .init(fromPerson: false, text: "Looking.")]
        let tail = BackendHootDesk.tail(recent, at: Date(timeIntervalSince1970: 0)) ?? ""
        XCTAssertTrue(tail.contains("The person: LATEST " + String(repeating: "y", count: 9_000)), "the person's last message is given in full")
        XCTAssertTrue(tail.hasSuffix("You: Looking."))
        XCTAssertFalse(tail.contains("OLDEST"), "older messages that do not fit stay in the diary")
        XCTAssertNil(BackendHootDesk.tail([], at: Date()))
        // A message the app sent in (a task) is never handed back as the person's words.
        let task = BackendHootDesk.tail([.init(fromPerson: true, text: "hello"), .init(fromPerson: false, text: "Task 12 is assigned to you.", label: "The app (task)")], at: Date()) ?? ""
        XCTAssertTrue(task.contains("The app (task): Task 12 is assigned to you.") && !task.contains("The person: Task 12"))
    }

    /// Through the real catalogue tool: a start that names no model gets the playbook's.
    func testASessionStartedWithNoModelGetsThePlaybooks() async throws {
        let memory = try await memory()
        try await memory.savePlaybook(.hoot, rows: [
            .init(jobKind: "bug fix", ai: "claude", model: "claude-opus-5-5", effort: "high", permission: "plan", instructions: "Run the tests before you report."),
            .init(jobKind: "default")])
        DeckMemoryCenter.shared.install(memory, root: await memory.location().root)
        defer { DeckMemoryCenter.shared.uninstall() }
        typealias F = BackendDeckCoreTestPortS1StartFixture
        func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
        let surface = BackendDeckCoreTestPortS1StartSurface.lane(), start = try F.start(surface)
        let context = F.context(callID: "call-1", now: 10_000, owned: .init([]))

        let answer = try await start.run(object([("cwd", .string("/work/web")), ("job", .string("bug fix"))]), context)
        let first = try XCTUnwrap(surface.started.first)
        XCTAssertEqual(first["provider"], .string("claude"))
        XCTAssertEqual(first["model"], .string("claude-opus-5-5"))
        XCTAssertEqual(first["effort"], .string("high"))
        XCTAssertEqual(first["permissionMode"], .string("plan"))
        XCTAssertEqual(answer.value["playbook"]["job"].string, "bug fix")
        XCTAssertEqual(answer.value["playbook"]["instructions"].string, "Run the tests before you report.")

        // Differing needs a reason, and is refused before anything starts. (Another folder: one session per folder.)
        do {
            _ = try await start.run(object([("cwd", .string("/work/api")), ("job", .string("bug fix")), ("differ", object([("model", .string("claude-sonnet-5-5"))]))]), context)
            XCTFail("a different model without a reason must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("reason"), error.localizedDescription) }
        XCTAssertEqual(surface.started.count, 1)
        _ = try await start.run(object([("cwd", .string("/work/api")), ("job", .string("bug fix")),
                                        ("differ", object([("model", .string("claude-sonnet-5-5")), ("reason", .string("a two-line change"))]))]), context)
        XCTAssertEqual(surface.started.last?["model"], .string("claude-sonnet-5-5"))

        // No matching job and an empty default row: the start is left exactly as it was asked.
        let other = BackendDeckCoreTestPortS1StartSurface.lane(), untouched = try F.start(other)
        _ = try await untouched.run(object([("cwd", .string("/work/web"))]), F.context(callID: "call-2", now: 10_000, owned: .init([])))
        let plain = try XCTUnwrap(other.started.last)
        XCTAssertFalse((plain.fields ?? []).map(\.key).contains("model"))
        XCTAssertFalse((plain.fields ?? []).map(\.key).contains("permissionMode"))
    }

    func testTheAppsLinesNeverEnterTheVisibleChat() async throws {
        let root = try temporary(), file = root.appendingPathComponent("chat.json")
        func event(_ sequence: Int, _ kind: String, id: String = "", _ value: String) -> String {
            #"{"version":1,"id":"c1:\#(sequence)","conversationId":"c1","turnId":"t1","sequence":\#(sequence),"provider":"claude","kind":"\#(kind)","messageId":"\#(id)","value":\#(value),"at":1000}"#
        }
        let saved = #"{"version":1,"conversationId":"c1","provider":"claude","sessionId":"cli-1","contextKey":null,"events":["#
            + [event(1, "user", #"{"text":"Where is the release?","attachmentCount":0}"#),
               event(2, "message", id: "m1", #"{"text":"Build 12 is in review."}"#), event(3, "completed", "{}")].joined(separator: ",") + "]}"
        try Data(saved.utf8).write(to: file)
        func rows(_ snapshot: NativeRPCValue) throws -> [HootChatRow] {
            HootChatProjection.rows(try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:)))
        }

        let store = try BackendHootChatStore(file: file)
        // The app's lines go to the CLI with the message; the chat keeps only what was written.
        await store.setDesk(lines: { _, _ in DeckMemoryBrief.wrap("Top rules:\n- Answer in three lines.") })
        // The stub CLI writes the first line it is given to a file, then waits to be stopped.
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "IFS= read -r line; printf '%s\\n' \"$line\" > got.tmp; /bin/mv got.tmp got.jsonl; read more"],
                                     cwd: root.path, environment: [:]))
        let said = try await store.say("And build 13?")
        let received = root.appendingPathComponent("got.jsonl")
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: received.path) { try await Task.sleep(for: .milliseconds(20)) }
        await store.stop()
        let got = try String(contentsOf: received, encoding: .utf8)
        XCTAssertTrue(got.contains("Answer in three lines."))
        XCTAssertTrue(got.contains("And build 13?"))
        let shown = try rows(said).last { $0.kind == .user }
        XCTAssertEqual(shown?.value["text"].string, "And build 13?")
        XCTAssertFalse(said.compact.contains("Answer in three lines."))
    }

    /// A task the owner assigned: no user bubble, one compact line, Hoot's answer read back for the task,
    /// and the task's own tools allowed for that task only.
    func testATaskTurnHasNoUserBubbleAndItsToolsAreAllowedForThatTaskOnly() async throws {
        let root = try temporary()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        let reply = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Posted the comment on the task."}]}}"#
        let done = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s1"}"#
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "IFS= read -r line; printf '%s\\n' '\(reply)' '\(done)'; read more"],
                                     cwd: root.path, environment: [:]))
        let task = BackendHootTaskTurn(taskID: "local:2de355f0", title: "test", body: "Hi", brief: "Post a comment when you have read it.")
        let background = BackendHootBackgroundTurn(reason: "task", id: task.taskID, title: task.title, message: BackendHootTaskTurns.message(task),
                                                   chatLine: "Working on task \u{201C}test\u{201D}")
        _ = try await store.say(background.message, background: background)
        let turn = await store.activeTurnID
        XCTAssertTrue(turn.hasPrefix("bg:task:local:2de355f0:"))
        await store.waitUntilIdle()
        let snapshot = await store.snapshot(limit: 500)
        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertFalse(events.contains { $0.record.kind == .user }, "no user bubble")
        let line = try XCTUnwrap(events.first { $0.record.kind == .message && $0.record.value["background"].fields != nil })
        XCTAssertEqual(line.record.value["text"].string, "Working on task \u{201C}test\u{201D}")
        XCTAssertEqual(line.record.value["background"]["id"].string, "local:2de355f0")
        let kept = try XCTUnwrap(events.first { $0.record.kind == .session && $0.record.value["background"].fields != nil })
        XCTAssertTrue(kept.record.value["background"]["brief"].string?.contains("Post a comment when you have read it.") == true, "what Hoot was given is kept for the diary")
        // What a chat shows of the turn: the compact line and nothing else.
        let shown = HootChatProjection.rows(events).filter { !$0.id.hasPrefix("bg:") || $0.value["background"].fields != nil }
        XCTAssertEqual(shown.map { $0.value["text"].string ?? "" }, ["Working on task \u{201C}test\u{201D}"])
        let read = BackendHootTaskTurns.read(events.filter { $0.turnID == turn })
        XCTAssertEqual(read.answer, "Posted the comment on the task.")
        XCTAssertTrue(read.finished); XCTAssertNil(read.problem)
        let recent = await store.recentMessages()
        XCTAssertEqual(recent, [], "a task turn is its own topic, not part of the chat with the person")
        await store.stop()

        func input(_ json: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(json.utf8)) }
        let allowed = BackendHootChatStore.taskToolAllowed
        XCTAssertTrue(allowed("mcp__deck-control__tools_describe", try input(#"{"tools":["tasks_comment"]}"#), "local:2de355f0"))
        XCTAssertTrue(allowed("mcp__deck-control__tools_run", try input(#"{"name":"tasks_comment","arguments":{"task":"2de355f0","kind":"progress","body":"Read it."}}"#), "local:2de355f0"))
        XCTAssertTrue(allowed("mcp__deck-control__tasks_verify", try input(#"{"task":"local:2de355f0","verified":true}"#), "local:2de355f0"))
        XCTAssertTrue(allowed("mcp__deck-control__tools_run", try input(#"{"name":"tasks.review","arguments":{"task":"local:2de355f0","pass":true}}"#), "local:2de355f0"))
        XCTAssertFalse(allowed("mcp__deck-control__tools_run", try input(#"{"name":"tasks_comment","arguments":{"task":"another-task","body":"x"}}"#), "local:2de355f0"), "another task still asks")
        XCTAssertFalse(allowed("mcp__deck-control__tools_run", try input(#"{"name":"sessions_start","arguments":{"cwd":"/work"}}"#), "local:2de355f0"), "anything else still asks")
        XCTAssertFalse(allowed("Bash", try input(#"{"command":"ls"}"#), "local:2de355f0"))
    }

    /// Rewind: what came after the chosen message is set aside (kept in the chat file), a message of the
    /// person's comes back for the box, and Undo puts everything back until the next message.
    func testRewindSetsTheRestAsideAndUndoPutsItBack() async throws {
        let root = try temporary(), file = root.appendingPathComponent("chat.json")
        func event(_ sequence: Int, _ turn: String, _ kind: String, id: String = "", _ value: String) -> String {
            #"{"version":1,"id":"c1:\#(sequence)","conversationId":"c1","turnId":"\#(turn)","sequence":\#(sequence),"provider":"claude","kind":"\#(kind)","messageId":"\#(id)","value":\#(value),"at":\#(sequence * 1000)}"#
        }
        let saved = #"{"version":1,"conversationId":"c1","provider":"claude","sessionId":"cli-1","contextKey":null,"events":["#
            + [event(1, "t1", "user", #"{"text":"first question","attachmentCount":0}"#), event(2, "t1", "message", id: "m1", #"{"text":"first answer"}"#), event(3, "t1", "completed", "{}"),
               event(4, "t2", "user", #"{"text":"second question","attachmentCount":0}"#), event(5, "t2", "message", id: "m2", #"{"text":"second answer"}"#), event(6, "t2", "completed", "{}")].joined(separator: ",") + "]}"
        try Data(saved.utf8).write(to: file)
        func texts(_ store: BackendHootChatStore) async throws -> [String] {
            let snapshot = await store.snapshot(limit: 500)
            return HootChatProjection.rows(try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))).map { $0.value["text"].string ?? "" }
        }
        let store = try BackendHootChatStore(file: file)
        // A handoff up to one message: the conversation is cut there, that message included, nothing after it.
        let questionCut = await store.cut(at: 4)
        let cutAtQuestion = try XCTUnwrap(questionCut)
        XCTAssertTrue(cutAtQuestion.fromPerson); XCTAssertEqual(cutAtQuestion.words, "second question"); XCTAssertEqual(cutAtQuestion.at, 4000)
        let upToQuestion = await store.recentMessages(through: 4)
        XCTAssertEqual(upToQuestion.map(\.text), ["first question", "first answer", "second question"])
        let answerCut = await store.cut(at: 5)
        let cutAtAnswer = try XCTUnwrap(answerCut)
        XCTAssertFalse(cutAtAnswer.fromPerson); XCTAssertEqual(cutAtAnswer.words, "second answer")
        let request = BackendHootTaskTurns.handoffRequest(upTo: cutAtQuestion, said: BackendHootDesk.said(upToQuestion))
        XCTAssertTrue(request.contains("UP TO AND INCLUDING the person's message"))
        XCTAssertTrue(request.contains(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 4))))
        XCTAssertTrue(request.contains("The person: second question") && !request.contains("second answer"))
        XCTAssertTrue(request.contains("handoff_present") && request.contains("Handoff up to: second question"))
        // The header's warning travels with the chat while the safety guard is off, and clears.
        await store.setGuardOff("macOS refused to run the app records fence.")
        var guardNote = await store.snapshot(limit: 1)["guardOff"].string
        XCTAssertEqual(guardNote, "macOS refused to run the app records fence.")
        await store.setGuardOff(nil)
        guardNote = await store.snapshot(limit: 1)["guardOff"].string
        XCTAssertNil(guardNote)

        let rewound = try await store.rewind(to: 4)
        XCTAssertEqual(rewound.text, "second question", "his message comes back for the box")
        var shown = try await texts(store)
        XCTAssertEqual(shown, ["first question", "first answer"])
        var cli = await store.cliSessionID
        XCTAssertNil(cli, "Hoot's own conversation is rebuilt from what is left")
        var mark = await store.snapshot(limit: 1)["rewound"].string
        XCTAssertEqual(mark, rewound.id)
        shown = try await texts(try BackendHootChatStore(file: file))
        XCTAssertEqual(shown, ["first question", "first answer"], "saved")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("second answer"), "the rewound part is kept, not deleted")

        try await store.undoRewind()
        shown = try await texts(store)
        XCTAssertEqual(shown, ["first question", "first answer", "second question", "second answer"])
        mark = await store.snapshot(limit: 1)["rewound"].string
        XCTAssertNil(mark)

        // Rewinding to one of Hoot's messages keeps it and sets aside what follows; nothing returns to the box.
        let fromHoot = try await store.rewind(to: 2)
        XCTAssertEqual(fromHoot.text, "")
        shown = try await texts(store)
        XCTAssertEqual(shown, ["first question", "first answer"])
        try await store.undoRewind()

        // An @ mention's receipt is kept with the message it belongs to, and no chat row shows it by itself.
        await store.noteReceipts([try NativeRPCValue.parseJSON(Data(#"{"id":"role:shop/ios","name":"Shop · iOS","outcome":"started","detail":"Sent to Shop · iOS. It was asleep and is starting.","taskID":"local:q1"}"#.utf8))], turn: "t2")
        let withReceipt = await store.snapshot(limit: 500)
        let filed = try (withReceipt["events"].elements ?? []).map(HootChatEvent.init(wire:)).first { $0.record.value["receipts"].elements != nil }
        XCTAssertEqual(filed?.turnID, "t2")
        XCTAssertEqual(filed?.record.value["receipts"].elements?.first?["outcome"].string, "started")
        shown = try await texts(store)
        XCTAssertEqual(shown, ["first question", "first answer", "second question", "second answer"])

        // "<seat> answered" is filed under the same message, once per answer.
        let reply = try NativeRPCValue.parseJSON(Data(#"{"receiptID":"r-1","id":"role:shop/ios","name":"Ana","seat":"Shop · iOS","taskID":"local:q1","commentID":"c1","preview":"It is the token refresh.","at":9000}"#.utf8))
        await store.noteReceipts([try NativeRPCValue.parseJSON(Data(#"{"id":"role:shop/ios","name":"Shop · iOS","outcome":"awake","detail":"Sent to Shop · iOS.","taskID":"local:q1","receiptID":"r-1"}"#.utf8))], turn: "t2")
        let waitingBefore = await store.receiptsWithoutAnswer()
        XCTAssertEqual(waitingBefore, ["r-1"], "a delivery with no answer line yet is found at start")
        await store.noteAnswer(reply); await store.noteAnswer(reply)
        let waitingAfter = await store.receiptsWithoutAnswer()
        XCTAssertEqual(waitingAfter, [])
        let withAnswer = try (await store.snapshot(limit: 500)["events"].elements ?? []).map(HootChatEvent.init(wire:)).filter { $0.record.value["answered"].elements != nil }
        XCTAssertEqual(withAnswer.map(\.turnID), ["t2"], "one line, under the message that was sent")

        // A builder's test exchange is taken out whole, the rest stays.
        let gone = try await store.setAsideExchanges(reason: "test") { $0.hasPrefix("second") }
        XCTAssertEqual(gone, 1)
        shown = try await texts(store)
        XCTAssertEqual(shown, ["first question", "first answer"])
        cli = await store.cliSessionID
        XCTAssertNil(cli)
    }

    func testMemoryThatDoesNotFitIsLeftOutFromTheEndAndSaysSo() {
        let small = BackendCopilotLayer.compose(contract: "CONTRACT", yours: "", desk: "## Your card\nBe brief.")
        XCTAssertEqual(small.deskCut, 0)
        XCTAssertTrue(small.text.hasPrefix("CONTRACT") && small.text.contains("# Your desk") && small.text.contains("Be brief."))
        XCTAssertEqual(BackendCopilotLayer.compose(contract: "CONTRACT", yours: "", desk: "").text, BackendCopilotLayer.compose(contract: "CONTRACT", yours: ""))

        let big = String(repeating: "A line of memory that is kept in a file.\n", count: 6_000)
        let cut = BackendCopilotLayer.compose(contract: "CONTRACT", yours: "", desk: big)
        XCTAssertGreaterThan(cut.deskCut, 0)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, BackendCopilotLayer.maximumComposedBytes)
        XCTAssertTrue(cut.text.contains("did not fit here and were left out"))
    }
}
