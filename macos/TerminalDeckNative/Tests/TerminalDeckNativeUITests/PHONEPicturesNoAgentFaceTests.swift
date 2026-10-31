import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 28 Oct 2026: a chat started with "No agent" in a project led by a saved agent showed on both phones as
/// "Decker · Claude" / "Ask Decker": the Mac's phone pictures reported the project's lead as the one working in it,
/// copying the session list's lead fallback. The phones now get no face for such a session (they show the AI,
/// "Claude"); a session started as the agent keeps the agent's face, and the Mac's own list is unchanged. Fixture data only.
final class PHONEPicturesNoAgentFaceTests: XCTestCase {
    @MainActor private func withFixture(_ body: () throws -> Void) rethrows {
        let store = AGTAgentsStore.shared, hands = AGTHandsStore.shared, chats = AGTTeamChatHistory.shared
        let saved = (store.fixture, store.live, store.liveLoaded, NativePROJLabels.shared.projects, chats.explicitOwners, chats.ownersLoaded)
        defer {
            store.fixture = saved.0; store.live = saved.1; store.liveLoaded = saved.2
            NativePROJLabels.shared.projects = saved.3; chats.explicitOwners = saved.4; chats.ownersLoaded = saved.5
            hands.fixture = nil
        }
        NativePROJLabels.shared.projects = [
            PROJProject(id: "deckdev", name: "Deck Dev", folders: ["/work/DeckDev"], lead: "agent:decker", leadName: "Decker"),
            PROJProject(id: PROJProjects.independentID, name: "Independent"),
        ]
        store.fixture = TasksState(agents: [AgentProfile(id: "decker", name: "Decker", provider: "claude", status: .active, projectID: "deckdev")])
        // plain: started with "No agent" in Deck Dev's folder (the app seated it in the lead seat);
        // asAgent: started as Decker (its ledger names Decker as its agent). Both hold a hand on the lead seat.
        store.live = [AGTWorksAsLeadUITests.session("p", title: "Deck Dev", folder: "/work/DeckDev", session: "plain"),
                      AGTWorksAsLeadUITests.session("d", title: "Deck Dev", folder: "/work/DeckDev", session: "asAgent")]
        store.liveLoaded = true
        hands.fixture = [.init(seat: .lead("deckdev"), number: 1, sessionID: "plain", job: "", taskID: nil, startedAt: Date()),
                         .init(seat: .lead("deckdev"), number: 2, sessionID: "asAgent", job: "", taskID: nil, startedAt: Date())]
        chats.explicitOwners = ["asAgent": "decker"]
        chats.ownersLoaded = true
        try body()
    }

    @MainActor func testANoAgentSessionHasNoFaceOnThePhonesButAnAgentsSessionKeepsIt() throws {
        try withFixture {
            XCTAssertTrue(NativePhonePictureFaces.isLeadFallback("plain"))
            XCTAssertFalse(NativePhonePictureFaces.isLeadFallback("asAgent"))
            let faces = NativePhonePictureFaces.sessions(["plain", "asAgent"])
            XCTAssertNil(faces["plain"], "a No agent session is the AI's own chat on the phones, never the lead's")
            XCTAssertEqual(faces["asAgent"]?.name, "Decker")
            XCTAssertEqual(faces["asAgent"]?.id, "decker")
            // 29 Oct: the Mac's own session rows ask the same question, so they show the AI for it too.
            XCTAssertNil(NativePhonePictureFaces.agent("plain", agents: SIDEBARSessionAgents.all()))
            XCTAssertEqual(NativePhonePictureFaces.agent("asAgent", agents: SIDEBARSessionAgents.all())?.profileID, "decker")
            // The lead adoption itself (13 Oct) is unchanged: the Agents page still seats both with the lead.
            XCTAssertEqual(SIDEBARSessionAgents.all()["plain"]?.profileID, "decker")
            XCTAssertEqual(SIDEBARSessionAgents.all()["asAgent"]?.profileID, "decker")
        }
    }

    /// Reviewer 28 Oct: before the agents sessions were started as have been read, a missing owner means "not read
    /// yet", so a real lead session is never shown as "Claude": every face is kept.
    @MainActor func testBeforeTheOwnersAreReadEveryFaceIsKept() throws {
        try withFixture {
            let chats = AGTTeamChatHistory.shared
            chats.ownersLoaded = false
            chats.explicitOwners = [:]   // what an unread list looks like: the Decker session's owner is not known yet
            XCTAssertFalse(NativePhonePictureFaces.isLeadFallback("plain"))
            XCTAssertFalse(NativePhonePictureFaces.isLeadFallback("asAgent"))
            let faces = NativePhonePictureFaces.sessions(["plain", "asAgent"])
            XCTAssertEqual(faces["plain"]?.name, "Decker")
            XCTAssertEqual(faces["asAgent"]?.name, "Decker", "a session started as the lead keeps its face while the list loads")
        }
    }

    @MainActor func testAPlainSessionOutsideALeadSeatIsNotTouched() throws {
        try withFixture {
            XCTAssertFalse(NativePhonePictureFaces.isLeadFallback("unknown"))
            AGTHandsStore.shared.fixture = []
            XCTAssertFalse(NativePhonePictureFaces.isLeadFallback("plain"), "no hand on the lead seat: nothing to leave out")
        }
    }
}
