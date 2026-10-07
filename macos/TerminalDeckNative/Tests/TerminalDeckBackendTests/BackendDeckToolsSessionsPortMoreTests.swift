import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendDeckToolsSessionsPortMoreTests: XCTestCase {
    private typealias V = BackendDeckToolsSessionsPortValues
    private func call(_ id: String, _ args: NativeRPCValue, rig: BackendDeckToolsSessionsPortRig,
                      clock: BackendDeckToolsSessionsClock = .init(sleep: { _ in })) async throws -> BackendMCPToolReply {
        let definitions = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: rig, surface: rig, clock: clock)
        return try await V.handler(id, in: definitions)(V.context(), args)
    }
    func testSessionMoreL83WorkingTurnSettlesAndReturnsLatestAnswerWithoutScreen() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "working", at: c.now); await r.setFiles([V.file("/t/a.jsonl")])
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1")), ("after", .number(9_500))]), rig: r, clock: c.clock { now in
            if now == 10_500 {
                await r.setSignal(status: "waiting", at: now)
                await r.setMessages("/t/a.jsonl", [V.message("fix it", at: 9_000, role: "you", id: "you:1"), V.message("Fixed: the test was wrong.", at: now)])
            }
        })
        XCTAssertEqual(out.structuredContent?["outcome"], .string("finished")); XCTAssertEqual(out.structuredContent?["answer"]["text"], .string("Fixed: the test was wrong."))
        XCTAssertEqual(out.structuredContent?["answer"]["afterSend"], .bool(true)); XCTAssertEqual(out.structuredContent?["screen"], .null)
        XCTAssertEqual(out.structuredContent?["waitedMs"], .number(1_500))
    }
    func testSessionMoreL114BriefIdleFlickerDoesNotFinishTurn() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "working", at: c.now)
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1")), ("timeoutSeconds", .number(3))]), rig: r, clock: c.clock { now in
            if now == 10_250 { await r.setSignal(status: "idle", at: now) }
            if now == 10_500 { await r.setSignal(status: "working", at: now) }
        })
        XCTAssertEqual(out.structuredContent?["outcome"], .string("timed-out"))
    }
    func testSessionMoreL150QuietNeverAskedSessionTimesOutHonestly() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "waiting", at: 1)
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1")), ("timeoutSeconds", .number(2))]), rig: r, clock: c.clock())
        XCTAssertEqual(out.structuredContent?["outcome"], .string("timed-out")); XCTAssertGreaterThanOrEqual(out.structuredContent?["waitedMs"].number ?? 0, 2_000)
    }
    func testSessionMoreL135BlockedReturnsQuestionAttentionAndZeroWait() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "input", at: 1); await r.setScreen("Do you want to run npm test?\n❯ 1. Yes\n  2. No\n\n\n")
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig: r, clock: c.clock())
        XCTAssertEqual(out.structuredContent?["outcome"], .string("blocked")); XCTAssertEqual(out.structuredContent?["attention"], .string("blocked"))
        XCTAssertEqual(out.structuredContent?["screen"], .string("Do you want to run npm test?\n❯ 1. Yes\n  2. No")); XCTAssertEqual(out.structuredContent?["waitedMs"], .number(0))
        XCTAssertEqual(c.sleeps, [])
    }
    func testSessionMoreL182CompletedAfterSendCountsAsFinishedTurn() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock(11_000)
        await r.setSignal(status: "completed", at: 10_500)
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1")), ("after", .number(10_000))]), rig: r, clock: c.clock())
        XCTAssertEqual(out.structuredContent?["outcome"], .string("finished")); XCTAssertEqual(c.sleeps, [])
    }
    func testSessionMoreL194ExitedOrDroppedSessionDoesNotWaitOnNothing() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setRows([V.row(exit: 0)])
        let exited = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig: r, clock: c.clock())
        XCTAssertEqual(exited.structuredContent?["outcome"], .string("exited"))
        await r.setRows([V.row()]); await r.setSignal(status: "working", at: 1)
        let stopped = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig: r, clock: c.clock { _ in await r.setRows([]) })
        XCTAssertEqual(stopped.structuredContent?["outcome"], .string("stopped"))
        XCTAssertEqual(stopped.structuredContent?["note"], .string("This app no longer holds that session — it was stopped, which drops it. Nothing more can be read from it here."))
    }
    func testSessionMoreL214TimeoutClampsBelowServerDeadline() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "waiting", at: 1)
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1")), ("timeoutSeconds", .number(100_000))]), rig: r,
            clock: .init(now: { c.now }, sleep: { ms in c.advance(ms); c.advance(240_000) }))
        let waited = try XCTUnwrap(out.structuredContent?["waitedMs"].number)
        XCTAssertLessThanOrEqual(waited, 240_250); XCTAssertGreaterThanOrEqual(waited, 240_000)
        XCTAssertEqual(out.structuredContent?["outcome"], .string("timed-out"))
    }
    func testSessionMoreL226CalmMustLastAtLeastSourceSettleWindow() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        await r.setSignal(status: "working", at: c.now)
        let out = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig: r, clock: c.clock { now in
            if now == 10_250 { await r.setSignal(status: "idle", at: now) }
        })
        XCTAssertEqual(out.structuredContent?["outcome"], .string("finished"))
        XCTAssertEqual(out.structuredContent?["waitedMs"], .number(1_250))
        XCTAssertGreaterThanOrEqual((out.structuredContent?["waitedMs"].number ?? 0) - 250, 500)
    }
    func testSessionMoreL234NamedKeysAreSeparateWritesWithSourceLabels() async throws {
        let r = BackendDeckToolsSessionsPortRig(), c = BackendDeckToolsSessionsPortClock()
        let out = try await call("sessions.keys", V.object([("sessionId", .string("s1")), ("keys", .array([.string("down"), .string("2"), .string("Enter")]))]), rig: r, clock: c.clock())
        let writes = await r.captured("write")
        XCTAssertEqual(writes.map { $0["data"] }, [.string("\u{1b}[B"), .string("2"), .string("\r")])
        XCTAssertEqual(out.structuredContent?["pressed"], .array([.string("Down"), .string("“2”"), .string("Enter")]))
        XCTAssertEqual(c.sleeps, [50, 50])
    }
    func testSessionMoreL253UnknownEscapeSequenceFailsBeforeConsent() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        let out = try await call("sessions.keys", V.object([("sessionId", .string("s1")), ("keys", .array([.string("\u{1b}[2J")]))]), rig: r)
        XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains("no key called"))
        let gates = await r.gates, writes = await r.captured("write"); XCTAssertEqual(gates.count, 0); XCTAssertEqual(writes, [])
    }
    func testSessionMoreL259CannotPressKeysAfterExit() async throws {
        let r = BackendDeckToolsSessionsPortRig(); await r.setRows([V.row(exit: 1)])
        let out = try await call("sessions.keys", V.object([("sessionId", .string("s1")), ("keys", .array([.string("enter")]))]), rig: r)
        XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains("already exited")); let writes = await r.captured("write"); XCTAssertEqual(writes, [])
    }
    func testSessionMoreL272ScreenOmitsBlankViewportRows() async throws {
        let r = BackendDeckToolsSessionsPortRig(); await r.setScreen("$ npm test\n  12 passing\n$ \n\n\n\n")
        let out = try await call("sessions.screen", V.object([("sessionId", .string("s1"))]), rig: r)
        XCTAssertEqual(out.structuredContent?["screen"], .string("$ npm test\n  12 passing\n$"))
    }
    func testSessionMoreL283RenameDelegatesTrimmedTitleAndEmptyRestoresFolder() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        let named = try await call("sessions.rename", V.object([("sessionId", .string("s1")), ("title", .string("  Fix login  "))]), rig: r)
        let reset = try await call("sessions.rename", V.object([("sessionId", .string("s1")), ("title", .string(""))]), rig: r)
        XCTAssertEqual(named.structuredContent, V.object([("sessionId", .string("s1")), ("title", .string("Fix login"))]))
        XCTAssertEqual(reset.structuredContent?["title"], .string("api")); let calls = await r.captured("rename")
        XCTAssertEqual(calls.map { $0["title"] }, [.string("Fix login"), .string("")])
    }
    func testSessionMoreL295TitleRefusesMultipleLinesOrOver120BeforeConsent() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        for (title, message) in [("two\nlines", "one line"), (String(repeating: "x", count: 121), "120")] {
            let out = try await call("sessions.rename", V.object([("sessionId", .string("s1")), ("title", .string(title))]), rig: r)
            XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains(message))
        }
        let gates = await r.gates, changes = await r.captured("rename"); XCTAssertEqual(gates.count, 0); XCTAssertEqual(changes, [])
    }
    func testSessionMoreL306HeldActionsUseReadActAlter() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        _ = try await call("sessions.held", V.object([("action", .string("list"))]), rig: r)
        _ = try await call("sessions.held", V.object([("action", .string("retry")), ("key", .string("k1"))]), rig: r)
        await r.setHeld([V.held("k1")]); _ = try await call("sessions.held", V.object([("action", .string("forget")), ("key", .string("k1"))]), rig: r)
        let tiers = await r.gates.map(\.0); XCTAssertEqual(tiers, [.read, .act, .alter])
    }
    func testSessionMoreL314RetryReportsNewSessionThatCameBack() async throws {
        let r = BackendDeckToolsSessionsPortRig(); await r.setHeld([V.held("k1")]); await r.setRetry(held: [], started: [V.row("back-1")])
        let out = try await call("sessions.held", V.object([("action", .string("retry")), ("key", .string("k1"))]), rig: r)
        XCTAssertEqual(out.structuredContent?["cameBack"], .bool(true)); XCTAssertEqual(out.structuredContent?["started"].elements?.map { $0["id"] }, [.string("back-1")])
    }
    func testSessionMoreL333FailedRetryCarriesRowsOwnReason() async throws {
        let r = BackendDeckToolsSessionsPortRig(), reason = "it could not be started again: claude is not installed"
        await r.setHeld([V.held("k1")]); await r.setRetry(held: [V.held("k1", reason: reason)])
        let out = try await call("sessions.held", V.object([("action", .string("retry")), ("key", .string("k1"))]), rig: r)
        XCTAssertEqual(out.structuredContent?["cameBack"], .bool(false)); XCTAssertEqual(out.structuredContent?["reason"], .string(reason))
    }
    func testSessionMoreL341UnknownHeldKeyRefusesWithoutForget() async throws {
        let r = BackendDeckToolsSessionsPortRig(), out = try await call("sessions.held", V.object([("action", .string("forget")), ("key", .string("nope"))]), rig: r)
        XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains("nothing is being held")); let calls = await r.captured("forget"); XCTAssertEqual(calls, [])
    }
    func testSessionMoreL352AccountNameSwitchCarriesCallerOwnershipToReplacement() async throws {
        let r = BackendDeckToolsSessionsPortRig(); await r.setOwn(["s1"])
        let out = try await call("sessions.account", V.object([("action", .string("switch")), ("sessionId", .string("s1")), ("account", .string("work"))]), rig: r)
        let calls = await r.captured("switch"); XCTAssertEqual(calls, [V.object([("sessionId", .string("s1")), ("profileId", .string("p-work"))])])
        XCTAssertEqual(out.structuredContent?["session"]["id"], .string("s1-as-p-work")); let noted = await r.noted; XCTAssertEqual(noted, ["s1-as-p-work"])
    }
    func testSessionMoreL365SwitchingHumanSessionDoesNotGiveItToCaller() async throws {
        let r = BackendDeckToolsSessionsPortRig(), out = try await call("sessions.account", V.object([("action", .string("switch")), ("sessionId", .string("s1")), ("account", .string("Work"))]), rig: r)
        let own = await r.own; XCTAssertFalse(own.contains(out.structuredContent?["session"]["id"].string ?? ""))
    }
    func testSessionMoreL375UnknownAccountListsActualChoices() async throws {
        let r = BackendDeckToolsSessionsPortRig(), out = try await call("sessions.account", V.object([("action", .string("plan")), ("sessionId", .string("s1")), ("account", .string("Holiday"))]), rig: r)
        XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains("Personal (claude), Work (claude)")); let calls = await r.captured("plan"); XCTAssertEqual(calls, [])
    }
    func testSessionMoreL385AccountFromDifferentAgentCannotSwitch() async throws {
        let r = BackendDeckToolsSessionsPortRig(), out = try await call("sessions.account", V.object([("action", .string("switch")), ("sessionId", .string("s1")), ("account", .string("Codex work"))]), rig: r)
        XCTAssertTrue(out.isError); XCTAssertTrue(V.error(out).contains("codex login")); let calls = await r.captured("switch"); XCTAssertEqual(calls, [])
    }
    func testSessionMoreL395OnlySwitchAndLaterNeedAlterCancelIsAct() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        for action in ["show", "plan", "armed", "cancel", "later", "switch"] {
            _ = try await call("sessions.account", V.object([("action", .string(action)), ("sessionId", .string("s1")), ("account", .string("Work"))]), rig: r)
        }
        let tiers = await r.gates.map(\.0); XCTAssertEqual(tiers, [.read, .read, .read, .act, .alter, .alter])
    }
    func testSessionMoreL409AccountAndPlanLimitsArriveTogether() async throws {
        let r = BackendDeckToolsSessionsPortRig(), out = try await call("sessions.account", V.object([("action", .string("show")), ("sessionId", .string("s2"))]), rig: r)
        XCTAssertEqual(out.structuredContent, V.object([("sessionId", .string("s2")), ("account", V.object([("kind", .string("known")), ("profileName", .string("account of s2"))])), ("limits", V.object([("limits", .array([]))]))]))
    }
    func testSessionMoreL422SearchClosedFolderFailsAndHitsRolesAreCapped() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        let refused = try await call("sessions.search", V.object([("cwd", .string("/etc")), ("query", .string("x"))]), rig: r)
        XCTAssertTrue(refused.isError); XCTAssertTrue(V.error(refused).contains("not a folder this app has open"))
        _ = try await call("sessions.search", V.object([("cwd", .string("/work/api")), ("query", .string("login")), ("maxHits", .number(5_000)), ("roles", .array([.string("assistant"), .string("nonsense")]))]), rig: r)
        let recorded = await r.captured("search")
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request["cwd"], .string("/work/api")); XCTAssertEqual(request["query"], .string("login")); XCTAssertEqual(request["maxHits"], .number(100))
        XCTAssertEqual(request["roles"], .array([.string("assistant")])); XCTAssertEqual(request["scope"], .string("project"))
    }
    func testSessionMoreL446ChatsListNewestConversationFirst() async throws {
        let r = BackendDeckToolsSessionsPortRig(); await r.setFiles([V.file("/t/old.jsonl", id: "old", created: 1, modified: 10, bytes: 5), V.file("/t/new.jsonl", id: "new", created: 2, modified: 20, bytes: 5)])
        let out = try await call("chats.list", V.object([("cwd", .string("/work/api"))]), rig: r)
        XCTAssertEqual(out.structuredContent?["chats"].elements?.map { $0["conversationId"] }, [.string("new"), .string("old")])
    }
    func testSessionMoreL455ReadsNewestOrNamedChatAndRejectsOutsidePath() async throws {
        let r = BackendDeckToolsSessionsPortRig()
        await r.setFiles([V.file("/t/old.jsonl", id: "old", created: 1, modified: 10, bytes: 5), V.file("/t/new.jsonl", id: "new", created: 2, modified: 20, bytes: 5)])
        await r.setMessages("/t/new.jsonl", [V.message("hello", at: 3, id: "a")]); await r.setMessages("/t/old.jsonl", [V.message("older", at: 1, id: "b")])
        let newest = try await call("chats.read", V.object([("cwd", .string("/work/api"))]), rig: r)
        XCTAssertEqual(newest.structuredContent?["messages"].elements?.first?["text"], .string("hello"))
        let named = try await call("chats.read", V.object([("cwd", .string("/work/api")), ("transcriptPath", .string("/t/old.jsonl"))]), rig: r)
        XCTAssertEqual(named.structuredContent?["messages"].elements?.first?["text"], .string("older"))
        let outside = try await call("chats.read", V.object([("cwd", .string("/work/api")), ("transcriptPath", .string("/Users/x/.ssh/id_rsa"))]), rig: r)
        XCTAssertTrue(outside.isError); XCTAssertTrue(V.error(outside).contains("not one of the conversations"))
    }
    func testSessionMoreL468InspectorTrimsChartsAndPreservesExactTopRankings() {
        let raw = V.object([("requests", .number(3)), ("timeline", .array([.number(1)])), ("contextSeries", .array([.number(1)])),
            ("heaviest", .array((1...6).map { .number(Double($0)) })), ("compactions", .array([.number(1), .number(2)]))])
        XCTAssertEqual(BackendDeckToolsSessionsRules.trimInsights(raw), V.object([("requests", .number(3)), ("heaviest", .array((1...5).map { .number(Double($0)) })), ("compactions", .number(2))]))
    }
}
