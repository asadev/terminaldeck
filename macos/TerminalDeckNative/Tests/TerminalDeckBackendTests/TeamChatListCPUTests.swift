import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Team lists use conversation metadata directly; no per-conversation unread reads remain.
@Suite("Team chat list: no unrelated refreshes")
struct TeamChatListCPUTests {
    /// The side panel's list re-reads itself for its own team chats' status, not for every session's.
    @Test func onlyItsOwnChatsStatusRefreshesTheList() {
        let jobs: Set<String> = ["job-1", "job-2"]
        #expect(!TeamChatListRefresh.wanted(event: "session:status", sessionID: "deck-dev-terminal", knownJobs: jobs),
                "a terminal working (Decker, his phone typing) changes nothing in the team list")
        #expect(TeamChatListRefresh.wanted(event: "session:status", sessionID: "job-2", knownJobs: jobs))
        #expect(!TeamChatListRefresh.wanted(event: "session:status", sessionID: nil, knownJobs: jobs))
        for event in ["session:created", "session:removed", "tasks:changed"] {
            #expect(TeamChatListRefresh.wanted(event: event, sessionID: nil, knownJobs: jobs), "\(event) can change the list")
        }
    }
}
