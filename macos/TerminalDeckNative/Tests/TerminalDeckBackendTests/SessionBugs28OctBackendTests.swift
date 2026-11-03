import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct, Asad's session bugs (Sessions seat): A, a session comes back after a session-helper restart in the
/// conversation it was really in (it was saved with the one it started with, so after a /clear it came back
/// "not found"); C, a session started or reopened on the Mac reaches the paired phone's list at once.
@Suite("Session bugs 28 Oct: the saved conversation and the phone's list")
struct SessionBugs28OctBackendTests {
    // MARK: Bug A — the saved conversation follows /clear

    @Test func aClearMovesTheSavedConversation() {
        // ClaudeiMatch, 27 Oct 16:27:41: the desk refresh's /clear moved the CLI from 367082ac… to c278af7e….
        #expect(DeckMemorySessionCenter.followedConversation(named: "c278af7e-7b5f-4c5f-ba6c-a062a185bb54",
            current: "367082ac-bf9b-4634-aa9a-dc3f5c7d3c99") == "c278af7e-7b5f-4c5f-ba6c-a062a185bb54")
    }

    @Test func theSameConversationOrABadIdChangesNothing() {
        #expect(DeckMemorySessionCenter.followedConversation(named: "abc", current: "abc") == nil, "a compaction keeps its id")
        #expect(DeckMemorySessionCenter.followedConversation(named: nil, current: "abc") == nil)
        #expect(DeckMemorySessionCenter.followedConversation(named: "", current: "abc") == nil)
        #expect(DeckMemorySessionCenter.followedConversation(named: "../../etc", current: "abc") == nil)
        #expect(DeckMemorySessionCenter.followedConversation(named: "new", current: nil) == "new", "a first id is written down")
    }

    @Test func beforeARestartOnlyAConversationWithItsTranscriptIsTaken() {
        let path = "/Users/x/.claude/projects/-Users-x-ClaudeiMatch/c278af7e.jsonl"
        #expect(DeckMemorySessionCenter.reconciledConversation(named: "c278af7e", transcriptPath: path, current: "367082ac",
            exists: { $0 == path }) == "c278af7e")
        #expect(DeckMemorySessionCenter.reconciledConversation(named: "c278af7e", transcriptPath: path, current: "367082ac",
            exists: { _ in false }) == nil, "no transcript on disk: keep what is saved")
        #expect(DeckMemorySessionCenter.reconciledConversation(named: "c278af7e", transcriptPath: "/x/other.jsonl", current: "367082ac",
            exists: { _ in true }) == nil, "the transcript must be that conversation's own")
        #expect(DeckMemorySessionCenter.reconciledConversation(named: "c278af7e", transcriptPath: path, current: "c278af7e",
            exists: { _ in true }) == nil, "already right")
    }

    // MARK: Bug C — the phone hears of every session that appears on the Mac

    private func meta(_ id: String) -> BackendSessionMeta {
        BackendSessionMeta(id: id, input: BackendCreateSessionInput(cwd: "/fixture", provider: "claude"),
            spawn: .init(provider: "claude", command: "fixture", args: [], path: "/fixture"))
    }

    @Test func aSessionStartedOrReopenedOnTheMacSendsTheList() {
        // Commander reopened from its held row at 03:43 (a create), and a session replaced by an account switch.
        #expect(BackendRemoteSessionListNotice.announces(.created(meta("027ad6e4"))))
        #expect(BackendRemoteSessionListNotice.announces(.replaced(oldID: "old", session: meta("new"))))
    }

    @Test func nothingElseResendsIt() {
        #expect(!BackendRemoteSessionListNotice.announces(.status(sessionID: "a", status: .working, source: "hook")), "status is not the list")
        #expect(!BackendRemoteSessionListNotice.announces(.held([])))
        #expect(!BackendRemoteSessionListNotice.announces(.restored([])), "each restored session announces itself as created")
        #expect(!BackendRemoteSessionListNotice.announces(.process(.exit(id: "a", exitCode: 0))), "ends are sent by the remote host itself")
        #expect(!BackendRemoteSessionListNotice.announces(.switchFailed(sessionID: "a", message: "no")))
    }
}
