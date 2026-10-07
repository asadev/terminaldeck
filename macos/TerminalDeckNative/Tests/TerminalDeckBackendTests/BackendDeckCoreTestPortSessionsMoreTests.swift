import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortSessionsMoreTests: XCTestCase {
    typealias V = NativeRPCValue
    typealias F = BackendDeckCoreTestPortSessionsFixture
    func o(_ fields: [(String,V)]) -> V { .object(fields.map { .init($0.0,$0.1) }) }
    func fixture() -> F {
        let f = F(); f.rows = [f.session("s1", cwd: "/work/api"), f.session("s2", cwd: "/work/web")]; f.owned = []
        f.accountRows = [o([("id", .string("system:claude")), ("name", .string("Personal")), ("provider", .string("claude"))]), o([("id", .string("p-work")), ("name", .string("Work")), ("provider", .string("claude"))]), o([("id", .string("p-codex")), ("name", .string("Codex work")), ("provider", .string("codex"))])]
        f.heldRows = [held("k1"), held("k2")]; return f
    }
    func held(_ key: String, reason: String = "it could not be started") -> V { o([("key", .string(key)), ("cwd", .string("/work/api")), ("provider", .string("claude")), ("profileId", .null), ("reason", .string(reason)), ("at", .number(1)), ("lastSeenAt", .number(1))]) }
    func setStatus(_ f: F, _ value: String, at: Double) {
        f.live = o([("status", .string(value)), ("at", .number(at))])
        f.rows = f.rows.map { $0.setting("status", .string(value)).merging(BackendDeckCoreAttention.view(status: value, statusSince: at, exitCode: nil, now: at)) }
    }
    func call(_ id: String, _ args: V, f: F, clock: BackendDeckToolsSessionsClock = .init(now: { 10_000 }, sleep: { _ in })) async throws -> BackendMCPToolReply {
        let defs = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: f, surface: f, clock: clock)
        return try await XCTUnwrap(defs.first { $0.spec.id == id }).handler(F.context(), args)
    }
    func testWaitFinishesAfterWorkingSettlesAndHandsBackFreshAnswerWithoutScreen() async throws {
        let f = fixture(), clock = BackendDeckCoreTestPortSessionsClock(); setStatus(f,"working",at:clock.now)
        f.files = [o([("path", .string("/t/a.jsonl")), ("createdAt", .number(1000)), ("modifiedAt", .number(2000)), ("bytes", .number(1000))])]
        let simulated = BackendDeckToolsSessionsClock(now: { clock.now }, sleep: { amount in
            clock.advance(amount)
            if clock.sleeps == 2 {
                f.live = .object([.init("status", .string("waiting")), .init("at", .number(clock.now))])
                f.messages = [.object([.init("role", .string("agent")), .init("at", .number(clock.now)), .init("text", .string("Fixed: the test was wrong."))])]
            }
        })
        let reply = try await call("sessions.wait", o([("sessionId", .string("s1")), ("after", .number(9500))]), f:f,clock:simulated), value = try XCTUnwrap(reply.structuredContent)
        XCTAssertEqual(value["outcome"], .string("finished")); XCTAssertEqual(value["answer"]["text"], .string("Fixed: the test was wrong.")); XCTAssertEqual(value["answer"]["afterSend"], .bool(true)); XCTAssertEqual(value["screen"], .null)
        // Also guards source SETTLE_MS's >=500ms contract through real behavior.
        XCTAssertGreaterThanOrEqual(value["waitedMs"].number ?? -1, 500)
    }
    func testIdleFlickerDoesNotFinishWorkingTurnAndQuietTimeoutSaysSo() async throws {
        let f = fixture(), clock = BackendDeckCoreTestPortSessionsClock(); setStatus(f,"working",at:clock.now)
        let simulated = BackendDeckToolsSessionsClock(now: { clock.now }, sleep: { amount in
            clock.advance(amount)
            if clock.sleeps == 1 { f.live = .object([.init("status", .string("idle")), .init("at", .number(clock.now))]) }
            if clock.sleeps == 2 { f.live = .object([.init("status", .string("working")), .init("at", .number(clock.now))]) }
        })
        let flicker = try await call("sessions.wait", o([("sessionId", .string("s1")), ("timeoutSeconds", .number(3))]), f:f,clock:simulated)
        XCTAssertEqual(flicker.structuredContent?["outcome"], .string("timed-out"))
        setStatus(f,"waiting",at:1)
        let quietClock = BackendDeckCoreTestPortSessionsClock()
        let quiet = try await call("sessions.wait", o([("sessionId", .string("s1")), ("timeoutSeconds", .number(2))]), f:f,clock:.init(now:{quietClock.now},sleep:{quietClock.advance($0)}))
        XCTAssertEqual(quiet.structuredContent?["outcome"], .string("timed-out")); XCTAssertGreaterThanOrEqual(quiet.structuredContent?["waitedMs"].number ?? -1,2000)
    }
    func testBlockedWaitReturnsImmediatelyWithExactMenuAndAttention() async throws {
        let f = fixture(); setStatus(f,"input",at:1); f.screenText = "Do you want to run npm test?\n❯ 1. Yes\n  2. No\n\n\n"
        let reply = try await call("sessions.wait", o([("sessionId", .string("s1"))]), f:f)
        XCTAssertEqual(reply.structuredContent?["outcome"], .string("blocked")); XCTAssertEqual(reply.structuredContent?["attention"], .string("blocked"))
        XCTAssertEqual(reply.structuredContent?["screen"], .string("Do you want to run npm test?\n❯ 1. Yes\n  2. No")); XCTAssertEqual(reply.structuredContent?["waitedMs"], .number(0))
    }
    func testAlreadyLandedAnswerAndNewCompletedStatusBothFinish() async throws {
        let f = fixture(); setStatus(f,"waiting",at:9000)
        f.files = [o([("path", .string("/t/a.jsonl")), ("createdAt", .number(1000)), ("modifiedAt", .number(9000)), ("bytes", .number(1))])]
        f.messages = [o([("role", .string("agent")), ("at", .number(9200)), ("text", .string("done"))])]
        let answer = try await call("sessions.wait", o([("sessionId", .string("s1")), ("after", .number(9100))]), f:f)
        XCTAssertEqual(answer.structuredContent?["outcome"], .string("finished"))
        setStatus(f,"completed",at:10500)
        let completed = try await call("sessions.wait", o([("sessionId", .string("s1")), ("after", .number(10_000))]), f:f,clock:.init(now:{11_000},sleep:{_ in}))
        XCTAssertEqual(completed.structuredContent?["outcome"], .string("finished"))
    }
    func testExitAndDisappearingSessionNeverWaitOnNothingAndTimeoutClamps() async throws {
        let f = fixture(); f.rows = [f.session("s1",cwd:"/work/api",exit:.number(0))]
        let exited = try await call("sessions.wait", o([("sessionId", .string("s1"))]), f:f); XCTAssertEqual(exited.structuredContent?["outcome"], .string("exited"))
        f.rows = [f.session("s1",cwd:"/work/api")]; setStatus(f,"working",at:1)
        let clock = BackendDeckCoreTestPortSessionsClock()
        let stopped = try await call("sessions.wait", o([("sessionId", .string("s1"))]), f:f,clock:.init(now:{clock.now},sleep:{clock.advance($0);f.rows=[]}))
        XCTAssertEqual(stopped.structuredContent?["outcome"], .string("stopped"))
        f.rows = [f.session("s1",cwd:"/work/api")]; setStatus(f,"waiting",at:1)
        let cap = BackendDeckCoreTestPortSessionsClock()
        let capped = try await call("sessions.wait", o([("sessionId", .string("s1")), ("timeoutSeconds", .number(100_000))]), f:f,clock:.init(now:{cap.now},sleep:{_ in
            if cap.sleeps > 0 { throw NativeRPCError(code:"fixture",message:"A clamped request should end after this simulated deadline") }; cap.advance(240_000)
        }))
        XCTAssertFalse(capped.isError); XCTAssertLessThanOrEqual(try XCTUnwrap(capped.structuredContent?["waitedMs"].number),240_250)
    }
    func testKeysUseNamedBytesLabelsOwnershipAndRejectBeforeAuthorization() async throws {
        let f = fixture(), clock = BackendDeckCoreTestPortSessionsClock()
        let keys = try await call("sessions.keys", o([("sessionId", .string("s1")), ("keys", .array(["down","2","Enter"].map(V.string)))]), f:f,clock:.init(now:{clock.now},sleep:{clock.advance($0)}))
        XCTAssertEqual(f.calls.filter{$0.name=="write"}.map{$0.args["data"]},[.string("\u{1b}[B"),.string("2"),.string("\r")]); XCTAssertEqual(keys.structuredContent?["pressed"],.array(["Down","“2”","Enter"].map(V.string)))
        XCTAssertEqual(f.authorizations.last?.tier,.alter)
        f.owned=["s1"]
        _ = try await call("sessions.keys",o([("sessionId",.string("s1")),("keys",.array([.string("ctrl-c")]))]),f:f)
        XCTAssertEqual(f.authorizations.last?.tier,.act)
        let count=f.authorizations.count
        let invalid = try await call("sessions.keys",o([("sessionId",.string("s1")),("keys",.array([.string("\u{1b}[2J")]))]),f:f)
        XCTAssertTrue(invalid.isError); XCTAssertTrue(invalid.content.first?["text"].string?.contains("no key called") == true); XCTAssertEqual(f.authorizations.count,count)
        f.calls=[];f.rows=[f.session("s1",cwd:"/work/api",exit:.number(1))]
        let exited=try await call("sessions.keys",o([("sessionId",.string("s1")),("keys",.array([.string("enter")]))]),f:f)
        XCTAssertTrue(exited.isError);XCTAssertTrue(exited.content.first?["text"].string?.contains("already exited") == true);XCTAssertFalse(f.calls.contains{$0.name=="write"})
    }
    func testScreenTrimsBlankRowsAndRenameUsesActualSurfaceAndTitleGuards() async throws {
        let f=fixture();f.screenText="$ npm test\n  12 passing\n$ \n\n\n\n"
        let screen=try await call("sessions.screen",o([("sessionId",.string("s1"))]),f:f)
        XCTAssertEqual(screen.structuredContent?["screen"],.string("$ npm test\n  12 passing\n$"))
        let named=try await call("sessions.rename",o([("sessionId",.string("s1")),("title",.string("  Fix login  "))]),f:f)
        XCTAssertEqual(named.structuredContent,o([("sessionId",.string("s1")),("title",.string("Fix login"))]))
        let empty=try await call("sessions.rename",o([("sessionId",.string("s1")),("title",.string(""))]),f:f);XCTAssertEqual(empty.structuredContent?["title"],.string("api"))
        XCTAssertEqual(f.calls.filter{$0.name=="rename"}.map{$0.args["title"]},[.string("Fix login"),.string("")])
        for (title,text) in [("two\nlines","one line"),(String(repeating:"x",count:121),"120")] {
            let bad=try await call("sessions.rename",o([("sessionId",.string("s1")),("title",.string(title))]),f:f)
            XCTAssertTrue(bad.isError);XCTAssertTrue(bad.content.first?["text"].string?.contains(text) == true)
        }
    }
    func testHeldActionTiersSuccessfulRetryAndExactFailureReason() async throws {
        let f=fixture()
        for (action,tier) in [("list",BackendMCPTier.read),("retry",.act),("forget",.alter)] {
            f.heldRows=[held("k1")];_ = try await call("sessions.held",o([("action",.string(action)),("key",.string("k1"))]),f:f);XCTAssertEqual(f.authorizations.last?.tier,tier)
        }
        f.heldRows=[held("k1")];f.retryHandler={ _ in f.rows.append(f.session("back-1",cwd:"/work/api"));return [] };f.calls=[]
        let back=try await call("sessions.held",o([("action",.string("retry")),("key",.string("k1"))]),f:f)
        XCTAssertEqual(back.structuredContent?["cameBack"],.bool(true));XCTAssertEqual(back.structuredContent?["started"].elements?.map{$0["id"].string},["back-1"]);XCTAssertTrue(f.calls.isEmpty)
        let reason="it could not be started again: claude is not installed",still=held("k1",reason:reason)
        f.retryHandler={_ in [still]}
        let failed=try await call("sessions.held",o([("action",.string("retry")),("key",.string("k1"))]),f:f)
        XCTAssertEqual(failed.structuredContent?["cameBack"],.bool(false));XCTAssertEqual(failed.structuredContent?["reason"],.string(reason))
        let gone=try await call("sessions.held",o([("action",.string("forget")),("key",.string("nope"))]),f:f)
        XCTAssertTrue(gone.isError);XCTAssertTrue(gone.content.first?["text"].string?.contains("nothing is being held") == true)
    }
    func testAccountSwitchKeepsOnlyOriginalCallerOwnershipAndNamesUnknownOrWrongProvider() async throws {
        let f=fixture();f.owned=["s1"];f.switchHandler={session,profile in f.session(session+"-as-"+profile,cwd:"/work/api")}
        let mine=try await call("sessions.account",o([("action",.string("switch")),("sessionId",.string("s1")),("account",.string("work"))]),f:f)
        XCTAssertEqual(f.calls.filter{$0.name=="switch"}.map(\.args),[o([("sessionId",.string("s1")),("profileId",.string("p-work"))])])
        XCTAssertTrue(f.owned.contains(try XCTUnwrap(mine.structuredContent?["session"]["id"].string)))
        let theirs=fixture();let other=try await call("sessions.account",o([("action",.string("switch")),("sessionId",.string("s1")),("account",.string("Work"))]),f:theirs)
        XCTAssertFalse(theirs.owned.contains(try XCTUnwrap(other.structuredContent?["session"]["id"].string)))
        for (action,account,text) in [("plan","Holiday","Personal (claude), Work (claude)"),("switch","Codex work","codex login")] {
            let bad=try await call("sessions.account",o([("action",.string(action)),("sessionId",.string("s1")),("account",.string(account))]),f:f)
            XCTAssertTrue(bad.isError);XCTAssertTrue(bad.content.first?["text"].string?.contains(text) == true)
        }
    }
    func testAccountActionsExactTiersAndAccountWithPlanLimits() async throws {
        let f=fixture()
        for (action,tier) in [("show",BackendMCPTier.read),("plan",.read),("armed",.read),("cancel",.act),("later",.alter),("switch",.alter)] {
            _ = try await call("sessions.account",o([("action",.string(action)),("sessionId",.string("s1")),("account",.string("Work"))]),f:f);XCTAssertEqual(f.authorizations.last?.tier,tier)
        }
        f.accountView = o([("kind",.string("known")),("profileName",.string("account of s2"))]); f.limitsView = .object([.init("limits",.array([]))])
        let show=try await call("sessions.account",o([("action",.string("show")),("sessionId",.string("s2"))]),f:f)
        XCTAssertEqual(show.structuredContent,o([("sessionId",.string("s2")),("account",f.accountView!), ("limits",f.limitsView)]))
    }
    func testSearchRejectsClosedFolderCapsHitsAndFiltersRoles() async throws {
        let f=fixture(),closed=try await call("sessions.search",o([("cwd",.string("/etc")),("query",.string("x"))]),f:f)
        XCTAssertTrue(closed.isError);XCTAssertTrue(closed.content.first?["text"].string?.contains("not a folder this app has open") == true)
        _ = try await call("sessions.search",o([("cwd",.string("/work/api")),("query",.string("login")),("maxHits",.number(5000)),("roles",.array(["assistant","nonsense"].map(V.string)))]),f:f)
        let request=try XCTUnwrap(f.calls.first{$0.name=="search"}?.args)
        XCTAssertEqual(request["cwd"],.string("/work/api"));XCTAssertEqual(request["query"],.string("login"));XCTAssertEqual(request["maxHits"],.number(100));XCTAssertEqual(request["roles"],.array([.string("assistant")]));XCTAssertEqual(request["scope"],.string("project"))
    }
    func testChatsNewestFirstDefaultAndExplicitReadsStayInsideFolderAndInsightsDropCharts() async throws {
        let f=fixture();f.files=[o([("path",.string("/t/old.jsonl")),("sessionId",.string("old")),("createdAt",.number(1)),("modifiedAt",.number(10)),("bytes",.number(5))]),o([("path",.string("/t/new.jsonl")),("sessionId",.string("new")),("createdAt",.number(2)),("modifiedAt",.number(20)),("bytes",.number(5))])]
        f.messagesByPath=["/t/new.jsonl":[o([("role",.string("agent")),("text",.string("hello")),("at",.number(3))])],"/t/old.jsonl":[o([("role",.string("agent")),("text",.string("older")),("at",.number(1))])]]
        let listed=try await call("chats.list",o([("cwd",.string("/work/api"))]),f:f);XCTAssertEqual(listed.structuredContent?["chats"].elements?.map{$0["conversationId"].string},["new","old"])
        let newest=try await call("chats.read",o([("cwd",.string("/work/api"))]),f:f);XCTAssertEqual(newest.structuredContent?["messages"].elements?.first?["text"],.string("hello"))
        let old=try await call("chats.read",o([("cwd",.string("/work/api")),("transcriptPath",.string("/t/old.jsonl"))]),f:f);XCTAssertEqual(old.structuredContent?["messages"].elements?.first?["text"],.string("older"))
        let outside=try await call("chats.read",o([("cwd",.string("/work/api")),("transcriptPath",.string("/Users/x/.ssh/id_rsa"))]),f:f);XCTAssertTrue(outside.isError);XCTAssertTrue(outside.content.first?["text"].string?.contains("not one of the conversations") == true)
        let input=o([("requests",.number(3)),("timeline",.array([.number(1)])),("contextSeries",.array([.number(1)])),("heaviest",.array((1...6).map{.number(Double($0))})),("compactions",.array([.number(1),.number(2)]))])
        XCTAssertEqual(BackendDeckToolsSessionsRules.trimInsights(input),o([("requests",.number(3)),("heaviest",.array((1...5).map{.number(Double($0))})),("compactions",.number(2))]))
    }
}

final class BackendDeckCoreTestPortSessionsClock: @unchecked Sendable {
    private let lock=NSLock();private var value=10_000.0;private var count=0
    var now:Double {lock.withLock{value}};var sleeps:Int{lock.withLock{count}}
    func advance(_ amount:Int){lock.withLock{value+=Double(amount);count+=1}}
}
