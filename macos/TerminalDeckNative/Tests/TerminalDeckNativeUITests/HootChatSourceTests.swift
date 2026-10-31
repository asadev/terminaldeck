import Foundation
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Asad, 13 Oct: a chat session shows Hoot's chat screen itself ("instead of building new screens give same as Hoot,
/// just use same"), reading its own conversation. Hoot's own chat must stay exactly as it was.
@MainActor final class HootChatSourceTests: XCTestCase {
    func testHootsOwnChatSendsExactlyWhatItAlwaysSent() {
        let hoot = HootChatSource.hoot
        XCTAssertTrue(hoot.isHoot)
        for verb in ["read", "say", "stop", "answer", "new", "options"] { XCTAssertEqual(hoot.channel(verb), "hoot:chat:" + verb) }
        XCTAssertEqual(hoot.event, "hoot:chat:changed")
        // The arguments go through untouched: same count, same order, same values.
        let arguments: [Any?] = ["hello", [Any](), ["mentions": [Any]()]]
        let passed = hoot.arguments(arguments)
        XCTAssertEqual(passed.count, 3)
        XCTAssertEqual(passed.first as? String, "hello")
        XCTAssertEqual(hoot.arguments([]).count, 0)
        XCTAssertEqual(hoot.agentName, "Hoot")
        // Every Hoot chat model there is (the page's, the island's, the pictures') is Hoot's.
        XCTAssertEqual(NativeHootChatModel.shared.source, .hoot)
        XCTAssertEqual(NativeHootChatModel(fixture: .object([])).source, .hoot)
    }

    func testAChatSessionReadsItsOwnConversationWithItsIDFirst() {
        let source = HootChatSource.session("7f1c2a9e-0c55-4c1e-9d4e-1f2a3b4c5d6e", provider: "codex")
        XCTAssertFalse(source.isHoot)
        XCTAssertEqual(source.channel("say"), "session:chat:say")
        XCTAssertEqual(source.channel("ensure"), "session:chat:ensure")
        XCTAssertEqual(source.event, "session:chat:changed")
        let passed = source.arguments(["hi", NSNull()])
        XCTAssertEqual(passed.count, 3)
        XCTAssertEqual(passed.first as? String, "7f1c2a9e-0c55-4c1e-9d4e-1f2a3b4c5d6e")
        XCTAssertEqual(passed[1] as? String, "hi")
        XCTAssertEqual(source.agentName, "Codex")
        XCTAssertEqual(HootChatSource.session("x", provider: "claude").agentName, "Claude Code")
        // Hoot-only parts (rewind, handoff to Hoot's panel) are not offered in a session's chat.
        let model = NativeHootChatModel(fixture: .object([]), source: source)
        XCTAssertEqual(model.source, source)
        XCTAssertFalse(model.canRewind)
        XCTAssertFalse(model.canHandoff)
    }

    func testR82HandoverRetainsMessagesAndAgentUntilHistoryIsSeeded() {
        let store = AGTAgentsStore.shared, history = AGTTeamChatHistory.shared
        let savedFixture = store.fixture, savedOwners = history.explicitOwners
        defer { store.fixture = savedFixture; history.explicitOwners = savedOwners }
        let oldID = UUID().uuidString, newID = UUID().uuidString
        store.fixture = TasksState(agents: [AgentProfile(id: "r82-fixture", name: "Fixture agent", provider: "claude", status: .active)])
        history.explicitOwners[oldID] = "r82-fixture"
        func snapshot(_ conversation: String, _ texts: [String], more: Bool = false) -> NativeRPCValue {
            let events = texts.enumerated().map { index, text in
                HootChatEvent(conversationID: conversation, turnID: "turn", sequence: index + 1, provider: .codex,
                              record: .text(index == 0 ? .user : .message, id: "message-\(index)", text))
            }
            return .object([.init("conversationId", .string(conversation)), .init("sequence", .number(Double(events.count))),
                            .init("events", .array(events.map(\.wireValue))), .init("hasMore", .bool(more))])
        }
        let old = NativeHootChatModel(fixture: snapshot("old", ["Old question", "Old answer"]), source: .session(oldID, provider: "claude"))
        let replacement = NativeHootChatModel(fixture: snapshot("new", []), source: .session(newID, provider: "codex"))
        XCTAssertEqual(old.replyAgent?.name, "Fixture agent")
        replacement.carryDisplay(from: old)
        history.explicitOwners[oldID] = nil
        store.fixture = TasksState(agents: [])
        for page in [snapshot("new", []), snapshot("new", ["Partial history"], more: true)] {
            replacement.acceptFixtureUpdate(page)
            XCTAssertFalse(replacement.loading)
            XCTAssertEqual(replacement.rows.compactMap { $0.value["text"].string }, ["Old question", "Old answer"])
            XCTAssertEqual(replacement.replyAgent?.name, "Fixture agent")
            XCTAssertEqual(replacement.displayState["agentAvatar"].bool, true)
        }
        replacement.acceptFixtureUpdate(snapshot("new", ["New question", "New answer"]))
        XCTAssertFalse(replacement.loading)
        XCTAssertEqual(replacement.rows.compactMap { $0.value["text"].string }, ["New question", "New answer"])
        XCTAssertEqual(replacement.replyAgent?.name, "Fixture agent")
    }

    func testTheSlashMenuListsTheAIsOwnCommandsAndLeavesOutItsTerminalScreens() {
        let offered = HootSlashCommand.offered(.array([
            .object([.init("name", .string("recover")), .init("description", .string("Recover and continue after any interruption"))]),
            .object([.init("name", .string("compact")), .init("description", .string("Clear history but keep a summary"))]),
            .object([.init("name", .string("theme"))]), .object([.init("name", .string("model"))]), .object([.init("name", .string("resume"))])]))
        XCTAssertEqual(offered.map(\.name), ["recover", "compact", "model"])
        XCTAssertNil(offered[0].opensInApp)
        XCTAssertNotNil(offered[2].opensInApp, "the model is the app's own control")
        XCTAssertEqual(HootSlashCommand.query("/rec"), "rec")
        XCTAssertEqual(HootSlashCommand.query("/"), "")
        XCTAssertNil(HootSlashCommand.query("/recover now"))
        XCTAssertNil(HootSlashCommand.query("hello"))
        XCTAssertEqual(HootSlashCommand.matches(offered, query: "rec").map(\.name), ["recover"])
        XCTAssertEqual(HootSlashCommand.matches(offered, query: "summary").map(\.name), ["compact"])
        XCTAssertEqual(HootSlashCommand.matches(offered, query: "").count, 3)
    }

    func testTheNewSessionAgentMenuPicksTheProjectsLead() throws {
        let project = try JSONDecoder().decode(PROJProject.self, from: Data(#"{"id":"crm","name":"CRM","folders":["/w/crm"],"lead":"agent:alex","leadName":"Alex"}"#.utf8))
        let state = CodingAIJSON(["agents": [
            ["id": "alex", "name": "Alex", "projectId": "other", "provider": "claude"],
            ["id": "zoe", "name": "Zoe", "projectId": "crm", "provider": "codex"],
            ["id": "bob", "name": "Bob", "projectId": "crm", "provider": "gemini"],
            ["id": "old", "name": "Old", "projectId": "crm", "status": "archived"]]])
        let agents = NewSessionTeamAgent.parse(state)
        XCTAssertEqual(agents.count, 3)
        XCTAssertEqual(NewSessionTeamAgent.lead(agents, project: project)?.id, "alex")
        XCTAssertEqual(NewSessionTeamAgent.forProject(agents, project: project).map(\.id), ["alex", "bob", "zoe"])
        XCTAssertTrue(NewSessionTeamAgent.forProject(agents, project: project)[0].isLead)
        let leaderless = try JSONDecoder().decode(PROJProject.self, from: Data(#"{"id":"crm","name":"CRM","folders":["/w/crm"]}"#.utf8))
        XCTAssertNil(NewSessionTeamAgent.lead(agents, project: leaderless))
    }

    func testTheSessionRecordSaysWhetherItIsAChat() {
        let chat = TerminalSessionInfo.decode(["id": "s1", "cwd": "/w", "title": "w", "provider": "claude", "chat": true])
        let terminal = TerminalSessionInfo.decode(["id": "s2", "cwd": "/w", "title": "w", "provider": "claude"])
        XCTAssertEqual(chat?.chat, true)
        XCTAssertEqual(terminal?.chat, false)
        XCTAssertEqual(chat?.renamed("API").chat, true)
    }
}
