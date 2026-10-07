import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane BR: what a session's agent is told about its browser windows — the
/// sentences and the once-only change of browser-binding.ts hookContext /
/// takeAnnouncement, chosen as index.ts contextFor chooses.
@Suite struct BRBrowserSessionContextTests {
    static func view(_ windows: [(Int, String, String, String)], session: String = "s1", ended: Bool = false) -> BRBindingView {
        BRBindingView(sessions: [BRBoundSession(sessionId: session, ended: ended,
            windows: windows.map { BRBoundWindow(n: $0.0, tabId: $0.1, title: $0.2, url: $0.3) })])
    }

    @Test func aSessionThisAppDidNotStartWithNoWindowHearsNothing() {
        let context = BRBrowserSessionContext()
        #expect(context.hookContext(sessionID: "s9", known: false, opensInApp: false) == nil)
        #expect(context.hookContext(sessionID: nil, known: true, opensInApp: false) == nil)
    }

    @Test func aKnownSessionWithNoWindowHearsWhereItRuns() {
        let context = BRBrowserSessionContext()
        #expect(context.hookContext(sessionID: "s1", known: true, opensInApp: false) == """
            You are running inside Terminal Deck, a terminal app with browser windows of its own.
            Do not mention any of this unless it is asked about or you act on it.
            """)
        #expect(context.hookContext(sessionID: "s1", known: true, opensInApp: true)?.contains(
            "`open <url>` here opens a browser window in this app, not the machine's browser.") == true)
    }

    @Test func theStandingAnswerListsTheWindowsAndClearsTheChange() {
        let context = BRBrowserSessionContext()
        context.update(Self.view([(1, "t1", "Stripe", "https://stripe.test/"), (2, "t2", "", "https://b.test/")]))
        #expect(context.hasAnnouncement(sessionID: "s1"))
        #expect(context.hookContext(sessionID: "s1", known: true, opensInApp: false) == """
            You are running inside Terminal Deck, a terminal app with browser windows of its own.
            Browser windows attached to this session:
            B1 — Stripe — https://stripe.test/
            B2 — https://b.test/
            "the browser" means B1.
            Do not mention any of this unless it is asked about or you act on it.
            """)
        // Said at the top of the turn, so not again mid-turn.
        #expect(!context.hasAnnouncement(sessionID: "s1"))
        #expect(context.answer(event: "PostToolUse", sessionID: "s1", known: true, opensInApp: false) == nil)
        // A window held by a session it did not start is still described (TS: windows.length > 0).
        #expect(context.hookContext(sessionID: "s1", known: false, opensInApp: true)?.contains(
            "\"the browser\" means B1. `open <url>` goes to B1 unless you detach it.") == true)
    }

    @Test func aWindowAttachedMidTurnLandsAtTheNextToolCallOnce() {
        let context = BRBrowserSessionContext()
        context.update(Self.view([(1, "t1", "Docs", "https://docs.test/")]))
        let said = context.answer(event: "PostToolUse", sessionID: "s1", known: true, opensInApp: false, cannotDrive: "You cannot act.")
        #expect(said == """
            Browser windows attached to this session (this just changed):
            B1 — Docs — https://docs.test/
            "the browser" means B1.
            You cannot act.
            Do not mention any of this unless it is asked about or you act on it.
            """)
        #expect(context.answer(event: "AfterTool", sessionID: "s1", known: true, opensInApp: false) == nil)
        // A new title or address is not a change worth saying.
        context.update(Self.view([(1, "t1", "Docs — page 2", "https://docs.test/2")]))
        #expect(context.takeAnnouncement(sessionID: "s1") == nil)
    }

    @Test func detachingAndExitingAreSaidOnce() {
        let context = BRBrowserSessionContext()
        context.update(Self.view([(1, "t1", "A", "https://a.test/")]))
        _ = context.takeAnnouncement(sessionID: "s1")
        context.update(Self.view([], ended: true))
        #expect(context.takeAnnouncement(sessionID: "s1") == "No browser window is attached to this session now.")
        #expect(context.takeAnnouncement(sessionID: "s1") == nil)
        // A session removed from the map leaves nothing pending.
        context.update(Self.view([(1, "t1", "A", "https://a.test/")]))
        context.update(BRBindingView())
        #expect(!context.hasAnnouncement(sessionID: "s1"))
    }

    @Test func otherSessionsAndMachinesAreKeptApart() {
        let context = BRBrowserSessionContext()
        context.update(BRBindingView(sessions: [
            BRBoundSession(sessionId: "s1", windows: [BRBoundWindow(n: 1, tabId: "t1")]),
            BRBoundSession(sessionId: "s1", machineId: "m2", windows: [BRBoundWindow(n: 1, tabId: "t5", host: "LAPTOP")]),
        ]))
        #expect(context.takeAnnouncement(sessionID: "s2") == nil)
        #expect(context.takeAnnouncement(sessionID: "s1", machineID: "m2")?.contains("B1 — served by LAPTOP") == true)
        #expect(context.hasAnnouncement(sessionID: "s1"))
    }

    @Test func readsTheEngineViewAsTheMapPublishesIt() {
        let context = BRBrowserSessionContext()
        let window = BackendBrowserBindings.Window(tabID: "t1", viewID: "t1", url: "https://x.test/", title: "X")
        let value = NativeRPCValue.object([.init("sessions", .array([.object([
            .init("sessionId", .string("s1")), .init("machineId", .string("")), .init("colour", .number(0)), .init("ended", .bool(false)),
            .init("windows", .array([window.value.setting("n", .number(1))]))])]))])
        context.update(value)
        #expect(context.takeAnnouncement(sessionID: "s1")?.contains("B1 — X — https://x.test/") == true)
    }

    /// Walk 4: Hoot's own tab must outlive the call that opened it (one `own` slot, as
    /// browser-driver.ts); a session's calls share their session's slot.
    @Test func theOwnTabIsOneSlotNotOneCall() {
        let first = BackendBrowserPrincipal(ownerID: "core-call:1", managesWindows: true)
        let second = BackendBrowserPrincipal(ownerID: "core-call:2", managesWindows: true)
        #expect(BackendBrowserService.slot(first) == BackendBrowserService.slot(second))
        let s1a = BackendBrowserPrincipal(ownerID: "core-call:3", sessionID: "s1")
        let s1b = BackendBrowserPrincipal(ownerID: "core-call:4", sessionID: "s1")
        let s2 = BackendBrowserPrincipal(ownerID: "core-call:5", sessionID: "s2")
        #expect(BackendBrowserService.slot(s1a) == BackendBrowserService.slot(s1b))
        #expect(BackendBrowserService.slot(s1a) != BackendBrowserService.slot(s2))
        #expect(BackendBrowserService.slot(s1a) != BackendBrowserService.slot(first))
    }
}
