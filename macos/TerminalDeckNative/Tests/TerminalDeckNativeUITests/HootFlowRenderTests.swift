import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// HOOT-FLOW (Asad, 12 Oct): the job flow (one fold per job, plain-language rows, rules with a tick, skill steps,
/// agents from the task records), the marked parts of Hoot's replies, and the icon-only message buttons. Drawn in a
/// real but never-shown window, light and dark. No app, engine, AI or real data.
@MainActor final class HootFlowRenderTests: XCTestCase {
    private static let conversation = "hoot-flow"
    private static let taskID = "local:7d1c2b9e-5f00-4a8e-9c11-2b3c4d5e6f70"
    private static let finalAnswer = """
    The sign-in fix went to the iOS fixer and is in.

    :::needs-you
    1. Ship it tonight, or wait for the review?
    2. Which account should the iOS agent use next?
    :::

    :::done
    - Sign-in fix merged; its test passes (verified).
    :::

    :::waiting
    - The iOS fixer is running the full suite.
    :::

    | Task | Agent | State |
    | --- | --- | --- |
    | Sign-in fix | iOS fixer | Verified |
    | Suite | iOS fixer | Running |
    | Release notes | Hoot | Done |
    """

    private static func event(_ sequence: Int, turn: String, _ record: HootChatRecord) -> HootChatEvent {
        HootChatEvent(conversationID: conversation, turnID: turn, sequence: sequence, provider: .claude, record: record,
                      at: 1_791_000_000_000 + Double(sequence) * 4_000)
    }
    private static func call(_ id: String, _ name: String, _ input: NativeRPCValue) -> HootChatRecord {
        .init(.toolCall, id: id, value: .object([.init("name", .string(name)), .init("input", input)]))
    }
    private static func result(_ id: String, _ output: String) -> HootChatRecord {
        .init(.toolResult, id: id, value: .object([.init("output", .string(output)), .init("isError", .bool(false))]))
    }
    private static func run(_ name: String, _ arguments: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object([.init("name", .string(name)), .init("arguments", .object(arguments.map { .init($0.0, $0.1) }))])
    }
    /// One job: Hoot reads the tasks, applies a rule, follows a skill step by step, hands the fix to an agent, answers.
    static func events(finished: Bool) -> [HootChatEvent] {
        var list: [HootChatEvent] = [
            event(1, turn: "t1", .text(.user, id: "u1", "Fix the sign-in bug on iOS and tell me when it is safe to ship.")),
            event(2, turn: "t1", .text(.message, id: "m1", "On it: I'll check the tasks first.")),
            event(3, turn: "t1", call("c1", "mcp__deck-control__tools_describe", .object([.init("area", .string("tasks"))]))),
            event(4, turn: "t1", result("c1", "tasks_list, tasks_delegate …")),
            event(5, turn: "t1", call("c2", "mcp__deck-control__tools_run", run("tasks_list", []))),
            event(6, turn: "t1", result("c2", "3 tasks")),
            event(7, turn: "t1", call("c3", "mcp__deck-control__tools_run", run("flow_applied", [("rule", .string("n-20261011-na3147"))]))),
            event(8, turn: "t1", result("c3", "Rule applied: Bypass only from playbook")),
            event(9, turn: "t1", call("c4", "Skill", .object([.init("skill", .string("bug-fix"))]))),
            event(10, turn: "t1", call("c5", "mcp__deck-control__flow_applied", .object([.init("skill", .string("bug-fix")), .init("step", .number(1)), .init("stepTitle", .string("Reproduce it"))]))),
            event(11, turn: "t1", result("c5", "Skill bug-fix · step 1: Reproduce it")),
            event(12, turn: "t1", call("c6", "Bash", .object([.init("command", .string("swift test --filter SignIn")), .init("description", .string("Run the sign-in tests"))]))),
            event(13, turn: "t1", result("c6", "Executed 4 tests, with 1 failure")),
            event(14, turn: "t1", call("c7", "mcp__deck-control__tools_run", run("tasks_delegate", [("taskId", .string(taskID)), ("agent", .string("ios-fixer"))]))),
            event(15, turn: "t1", result("c7", "Delegated " + taskID + " to iOS fixer")),
        ]
        if finished {
            list += [event(16, turn: "t1", .text(.message, id: "m2", finalAnswer)), event(17, turn: "t1", .init(.completed, value: .object([])))]
        } else {
            list.append(event(16, turn: "t1", call("c8", "mcp__deck-control__tools_run", run("tasks_progress", []))))
        }
        return list
    }
    static func fixture(finished: Bool) -> NativeRPCValue {
        let task: NativeRPCValue = .object([.init("id", .string(taskID)), .init("title", .string("Fix the iOS sign-in")), .init("agent", .string("iOS fixer")), .init("assignee", .string("ios-fixer")),
            .init("process", .string(finished ? "idle" : "running")), .init("completedAt", finished ? .number(1_791_000_090_000) : .null),
            .init("notes", .array([.object([.init("at", .number(1_791_000_080_000)), .init("by", .string("iOS fixer")), .init("kind", .string("result")),
                                             .init("text", .string("Fixed the token refresh; 4 of 4 sign-in tests pass."))])]))])
        let reports = [JobFlowEntry(id: "r1", at: 1_791_000_070_000, session: "s-ios", task: taskID, who: "iOS fixer", seat: "role:shop/ios", kind: .rule,
                                    title: "Never push live", full: "- Never push live without his word"),
                       JobFlowEntry(id: "r2", at: 1_791_000_075_000, session: "s-ios", task: taskID, who: "iOS fixer", seat: "role:shop/ios", kind: .skill,
                                    title: "bug-fix", step: 2, stepTitle: "Write the failing test")]
        let encoded = reports.compactMap { try? NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }
        return .object([.init("conversationId", .string(conversation)), .init("sequence", .number(40)),
            .init("events", .array(events(finished: finished).map(\.wireValue))), .init("ready", .bool(true)), .init("alive", .bool(true)),
            .init("busy", .bool(!finished)), .init("pending", .array([])), .init("tasks", .array([task])), .init("flowReports", .array(encoded))])
    }
    private func shot<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.agkitOffscreenSolid, true).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        XCTAssertFalse(window.isVisible)
        guard let path = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"], path.hasSuffix(".noindex") else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("HOOT-FLOW-\(name)-\(dark ? "dark" : "light").png"))
    }

    // MARK: One fold per job

    func testAJobIsOneReplyWithItsStepsAboveTheAnswer() {
        let rows = HootChatProjection.rows(Self.events(finished: true))
        let items = HootChatItem.items(rows)
        // The person's message and ONE reply, preserving both the first words and final answer.
        XCTAssertEqual(items.count, 2)
        guard items.count == 2, case .reply(let key, let answer, let steps, let open) = items[1] else { return XCTFail("one reply for the job") }
        XCTAssertEqual(key, rows[0].id); XCTAssertEqual(steps.count, 7); XCTAssertTrue(open)
        XCTAssertEqual(answer?.value["text"].string, "On it: I'll check the tasks first.\n\n" + Self.finalAnswer)
        XCTAssertEqual(answer?.value["combinedMessageIDs"].elements?.count, 2)
        // A new message starts a new job: the first job's reply is no longer the open one.
        let more = Self.events(finished: true) + [Self.event(18, turn: "t2", .text(.user, id: "u2", "Thanks"))]
        let next = HootChatItem.items(HootChatProjection.rows(more))
        guard next.count > 1, case .reply(_, _, _, let stillOpen) = next[1] else { return XCTFail() }
        XCTAssertFalse(stillOpen)
    }

    /// Decker, 8 Nov (D1, all four apps): a failed step is its own card, never inside the fold; it splits the fold.
    func testAFailedStepStandsOnItsOwnCardAndSplitsTheFold() {
        let failed = HootChatRecord(.toolResult, id: "c2", value: .object([.init("output", .string("make: *** [all] Error 2")), .init("isError", .bool(true))]))
        let rows = HootChatProjection.rows([
            Self.event(1, turn: "t1", .text(.user, id: "u1", "Build it")),
            Self.event(2, turn: "t1", Self.call("c1", "Bash", .object([.init("command", .string("ls"))]))), Self.event(3, turn: "t1", Self.result("c1", "ok")),
            Self.event(4, turn: "t1", Self.call("c2", "Bash", .object([.init("command", .string("make")), .init("description", .string("Build the app"))]))), Self.event(5, turn: "t1", failed),
            Self.event(6, turn: "t1", Self.call("c3", "Bash", .object([.init("command", .string("make test"))]))), Self.event(7, turn: "t1", Self.result("c3", "ok")),
            Self.event(8, turn: "t1", .text(.message, id: "m1", "The build failed once."))])
        guard case .reply(_, _, let steps, _)? = HootChatItem.items(rows).last else { return XCTFail("one reply for the job") }
        let parts = HootStepPart.parts(steps)
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3, case .fold(_, let before) = parts[0], case .failed(let card) = parts[1], case .fold(_, let after) = parts[2] else {
            return XCTFail("fold, failed card, fold")
        }
        XCTAssertEqual(before.map(\.id), [rows[1].id]); XCTAssertEqual(card.id, rows[2].id); XCTAssertEqual(after.map(\.id), [rows[3].id])
        XCTAssertEqual(HootStep.title(card, live: false), "Build the app")
        // A single good step still folds into one compact line.
        XCTAssertEqual(HootStep.summary(before).text, "Ran a command")
    }

    /// Asad: "It should instantly show Hoot's profile and then start thinking next to it". The reply is there the
    /// moment the message is sent, and it is the SAME item (same id) once steps and then the answer arrive.
    func testTheReplyIsThereAtOnceAndKeepsItsPlace() {
        let sent = HootChatProjection.rows([Self.event(1, turn: "t1", .text(.user, id: "u1", "Fix the sign-in bug"))])
        let thinking = HootChatItem.thinking(HootChatItem.items(sent), live: true)
        XCTAssertEqual(thinking.count, 2)
        guard case .reply(_, let answer, let steps, _) = thinking[1] else { return XCTFail("the thinking reply is there at once") }
        XCTAssertNil(answer); XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(HootChatItem.thinking(HootChatItem.items(sent), live: false).count, 1, "nothing is added when Hoot is not working")
        let working = HootChatItem.thinking(HootChatItem.items(HootChatProjection.rows(Self.events(finished: false))), live: true)
        let answered = HootChatItem.thinking(HootChatItem.items(HootChatProjection.rows(Self.events(finished: true))), live: true)
        XCTAssertEqual(thinking[1].id, working.last?.id); XCTAssertEqual(working.last?.id, answered.last?.id)
    }

    func testTheFlowSaysWhatHappenedInPlainWords() {
        let rows = HootChatProjection.rows(Self.events(finished: true)).filter(HootChatItem.isStep)
        let model = NativeHootChatModel(fixture: Self.fixture(finished: true))
        let agents = model.flowAgents(rows)
        XCTAssertEqual(agents.map(\.name), ["iOS fixer"])
        XCTAssertEqual(agents.first?.reports.count, 2); XCTAssertEqual(agents.first?.status, "Finished")
        let lines = HootFlow.lines(rows, agents: agents, live: false)
        let titles = lines.map(\.title)
        XCTAssertFalse(titles.contains { $0.lowercased().contains("tools") }, "looking up tools is not a step: \(titles)")
        XCTAssertTrue(titles.contains("Read the Tasks list"), "\(titles)")
        XCTAssertTrue(titles.contains("Bypass only from playbook"), "\(titles)")
        XCTAssertTrue(titles.contains("Using the skill bug-fix"))
        XCTAssertTrue(titles.contains("Skill bug-fix · step 1: Reproduce it"))
        XCTAssertTrue(titles.contains("Run the sign-in tests"))
        XCTAssertTrue(titles.contains("Gave a task to an agent"))
        XCTAssertTrue(titles.contains("Gave \u{201C}Fix the iOS sign-in\u{201D} to iOS fixer"))
        XCTAssertTrue(lines.contains { $0.who == "iOS fixer" && $0.kind == .rule && $0.title == "Never push live" })
        XCTAssertTrue(lines.contains { $0.who == "iOS fixer" && $0.title == "Skill bug-fix · step 2: Write the failing test" })
        XCTAssertEqual(lines.last?.title, "iOS fixer finished")
        XCTAssertEqual(lines.filter { $0.kind == .rule }.map(\.badge), ["Rule ✓", "Rule ✓"])
        XCTAssertEqual(lines.map(\.at), lines.map(\.at).sorted(), "in the order it happened")
        XCTAssertTrue(HootFlow.counts(lines, agents: agents.count).contains("2 rules"))
        // A call that only reads the task list never counts as handing any of them out.
        let listed = HootChatProjection.rows([Self.event(30, turn: "t9", Self.call("l1", "mcp__deck-control__tools_run", Self.run("tasks_local", [("do", .string("list"))]))),
                                              Self.event(31, turn: "t9", Self.result("l1", "[{\"id\":\"" + Self.taskID + "\"}]"))])
        XCTAssertTrue(HootFlow.agents(steps: listed, tasks: model.fixtureTasksForChecks, reports: []).isEmpty)
        XCTAssertEqual(HootFlow.lines(listed, agents: [], live: false).map(\.title), ["Read the Tasks list"])
        // Nothing is guessed: with no reports and no hand-out call there is no rule and no agent.
        let bare = rows.filter { !HootFlow.isReport($0) && HootFlow.toolName($0) != "tasks_delegate" }
        XCTAssertTrue(HootFlow.agents(steps: bare, tasks: [], reports: []).isEmpty)
        XCTAssertFalse(HootFlow.lines(bare, agents: [], live: false).contains { $0.kind == .rule })
    }

    /// Asad: "comments will stay as the place of comments and chat will stay as a chat". A task turn (Hoot @mentioned
    /// in a task thread) leaves nothing in the chat: no line, no flow, no reply.
    func testATaskTurnNeverShowsInTheChat() {
        let task = "bg:task:local:abc:5f1e"
        let about = NativeRPCValue.object([.init("reason", .string("task")), .init("id", .string("local:abc")), .init("title", .string("Fix sign-in"))])
        let events = Self.events(finished: true) + [
            Self.event(20, turn: task, .init(.session, value: .object([.init("background", about.setting("brief", .string("Comment from the task thread")))]))),
            Self.event(21, turn: task, .init(.message, value: .object([.init("text", .string("Working on a task: Fix sign-in")), .init("background", about)]))),
            Self.event(22, turn: task, Self.call("bgc1", "mcp__deck-control__tools_run", Self.run("tasks_comment", [("taskId", .string("local:abc"))]))),
            Self.event(23, turn: task, .text(.message, id: "bgm1", "Replied in the task thread."))]
        let rows = NativeHootChatModel.chatRows(events)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("bg:") })
        XCTAssertEqual(rows.count, HootChatProjection.rows(Self.events(finished: true)).count)
        XCTAssertEqual(HootChatItem.items(rows).count, 2, "the chat's own combined reply only")
    }

    // MARK: Marked parts of a reply

    func testMarkedPartsBecomeBoxesAndCopyKeepsPlainLabels() {
        let parts = HootCallout.parts(Self.finalAnswer)
        let kinds = parts.compactMap { part -> HootCallout.Kind? in if case .box(let kind, _) = part { return kind }; return nil }
        XCTAssertEqual(kinds, [.needsYou, .done, .waiting])
        XCTAssertEqual(parts.count, 5, "text, three boxes, the table")
        let plain = HootCallout.plain(Self.finalAnswer)
        XCTAssertTrue(plain.contains("Needs you:\n1. Ship it tonight") && plain.contains("Done:\n- Sign-in fix") && plain.contains("Waiting on:\n"))
        XCTAssertFalse(plain.contains(":::"))
        XCTAssertEqual(HootCallout.numbers("1. Ship?\n2) Which account?\nnot a number"), [1, 2])
        // Broken or unknown markers stay text; a marker inside a code block is code.
        XCTAssertEqual(HootCallout.parts("before\n:::done\nnever closed"), [.text("before\n:::done\nnever closed")])
        XCTAssertEqual(HootCallout.parts(":::recipe\nx\n:::"), [.text(":::recipe\nx\n:::")])
        XCTAssertEqual(HootCallout.parts("```\n:::done\nx\n:::\n```"), [.text("```\n:::done\nx\n:::\n```")])
        // While the reply is still coming in, an open box is already a box (no flash of raw text).
        XCTAssertEqual(HootCallout.parts("Hi\n:::needs-you\n1. Ship?", streaming: true), [.text("Hi"), .box(.needsYou, "1. Ship?")])
        XCTAssertEqual(HootCallout.Kind.named("Decision"), .needsYou)
        // Seen in the dev copy: Hoot wrote the parts as quoted bold labels. They are the same boxes.
        XCTAssertEqual(HootCallout.parts("Here it is.\n\n> **Needs you:** 1. Ship? 2. Which account?\n\n> **Done:** Fixed the sign-in.\n\nNote: plain."),
                       [.text("Here it is."), .box(.needsYou, "1. Ship? 2. Which account?"), .box(.done, "Fixed the sign-in."), .text("Note: plain.")])
        XCTAssertEqual(HootCallout.plain("no boxes here"), "no boxes here")
    }

    // MARK: Pictures

    func testTheJobFlowAndTheMessageButtonsDraw() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        XCTAssertLessThanOrEqual(HootQuickTip.delay, 150, "the tip comes almost at once")
        let rows = HootChatProjection.rows(Self.events(finished: true)).filter(HootChatItem.isStep)
        let finished = NativeHootChatModel(fixture: Self.fixture(finished: true))
        let agents = finished.flowAgents(rows)
        for dark in [false, true] {
            try shot(NativeHootChat(model: NativeHootChatModel(fixture: Self.fixture(finished: true))), size: CGSize(width: 900, height: 900), dark: dark, name: "answered")
            try shot(NativeHootChat(model: NativeHootChatModel(fixture: Self.fixture(finished: false))), size: CGSize(width: 900, height: 700), dark: dark, name: "working")
            try shot(HootFlowTable(lines: HootFlow.lines(rows, agents: agents, live: false), agents: agents, rows: rows).padding(20),
                     size: CGSize(width: 820, height: 560), dark: dark, name: "table")
            try shot(VStack(alignment: .leading, spacing: 20) {
                HootFlowLiveList(lines: HootFlow.lines(HootChatProjection.rows(Self.events(finished: false)).filter(HootChatItem.isStep),
                                                       agents: NativeHootChatModel(fixture: Self.fixture(finished: false)).flowAgents(rows), live: true))
                HStack(spacing: 4) {
                    HootMessageIcon(symbol: "doc.on.doc", tip: "Copy this message") {}
                    HootMessageIcon(symbol: "arrow.uturn.backward", tip: "Rewind") {}
                    HootMessageIcon(symbol: "doc.text", tip: "Handoff") {}
                }
            }.padding(20), size: CGSize(width: 700, height: 420), dark: dark, name: "live-and-icons")
            try shot(NativeHootScreen(fixture: Self.fixture(finished: true)), size: CGSize(width: 1100, height: 760), dark: dark, name: "page")
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
