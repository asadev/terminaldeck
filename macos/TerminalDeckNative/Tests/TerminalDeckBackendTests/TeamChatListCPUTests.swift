import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct (Asad: every terminal slow, the app and the session helper each at ~100% CPU): the team-chat list read every
/// chat again on every session status change, and the helper loaded each finished chat's whole history from disk to
/// answer. A chat's unread is now remembered from its last read or change; the list reads a chat only when nothing is
/// known since it last changed.
@Suite("Team chat list: no re-read of every chat")
struct TeamChatListCPUTests {
    private func snapshot(unread count: Int?, conversation: String = "c1") -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("conversationId", .string(conversation)), .init("events", .array([]))]
        if let count { fields.append(.init("unread", .object([.init("count", .number(Double(count)))]))) }
        return .object(fields)
    }

    /// The list as the side panel draws it, twice, over 156 finished chats: 156 reads the first time, none after.
    @Test func aFinishedChatIsReadOnceNotOnEveryRedraw() {
        var cache = BackendChatUnreadCache(), reads = 0
        let ids = (0..<156).map { "job-\($0)" }
        for _ in 0..<2 {
            for id in ids where cache.entry(id) == nil { reads += 1; cache.noteRead(id, snapshot(unread: 0)) }
        }
        #expect(reads == 156)
        #expect(cache.count == 156)
    }

    @Test func aChangeCarryingItsUnreadIsTakenWithoutARead() {
        var cache = BackendChatUnreadCache()
        cache.noteRead("a", snapshot(unread: 0))
        cache.noteChange("a", snapshot(unread: 3))
        #expect(cache.entry("a")?.unread["count"].number == 3)
    }

    @Test func aChangeWithoutUnreadIsReadOnceMore() {
        var cache = BackendChatUnreadCache()
        cache.noteRead("a", snapshot(unread: 2))
        cache.noteChange("a", snapshot(unread: nil))
        #expect(cache.entry("a") == nil, "the next list reads this one chat again, never all of them")
        cache.noteRead("a", snapshot(unread: nil))
        #expect(cache.entry("a") != nil, "a read answer is kept even without an unread field")
    }

    @Test func aGoneChatIsForgotten() {
        var cache = BackendChatUnreadCache()
        cache.noteRead("a", snapshot(unread: 1))
        cache.forget("a")
        #expect(cache.entry("a") == nil)
    }

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
