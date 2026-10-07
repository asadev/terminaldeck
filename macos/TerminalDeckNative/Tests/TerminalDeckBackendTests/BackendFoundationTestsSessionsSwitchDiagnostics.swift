import Testing
@testable import TerminalDeckBackend

@Suite("Foundation: process last-line diagnostics")
struct BackendFoundationTestsSessionsSwitchDiagnostics {
    // TS session-switch.test.ts:87
    @Test func previewAndMutationChannelsRemainDistinct() {
        #expect(BackendSessionLifecycleRPC.channels.contains("session:switch-plan"))
        #expect(BackendSessionLifecycleRPC.channels.contains("session:switch-account"))
        #expect("session:switch-plan" != "session:switch-account")
    }
    // TS switch-later.test.ts:45
    @Test func deferredSwitchChannelsNamedForTheirOperations() {
        let requests: Set<String> = ["session:switch-later", "session:switch-cancel", "session:switch-armed"]
        let announcements: Set<String> = ["session:switched", "session:switch-failed"]
        #expect(requests.union(announcements).count == 5)
        #expect(requests.isSubset(of: BackendSessionLifecycleRPC.channels)); #expect(announcements.isSubset(of: BackendCompositionSessions.eventChannels))
        #expect("session:switched" != "session:switch-failed")
    }
    // TS session-held.test.ts:207
    @Test func heldListChannelExportedByOwner() { #expect(BackendSessionLifecycleRPC.channels.contains("sessions:held")) }
    // TS session-switch.test.ts:378
    @Test func lastNonemptyLineTrimmed() { #expect(BackendSessionReplacementReadiness.lastLine("a\r\nb\r\n\r\n   \r\n") == "b") }
    // TS session-switch.test.ts:382
    @Test func longLineCutWithVisibleEllipsis() {
        let cut = BackendSessionReplacementReadiness.lastLine(String(repeating: "x", count: 200), limit: 20)
        #expect(cut?.count == 20); #expect(cut?.hasSuffix("…") == true)
    }
    // TS session-switch.test.ts:391
    @Test func emptyBufferHasNoInventedReason() {
        #expect(BackendSessionReplacementReadiness.lastLine("") == nil); #expect(BackendSessionReplacementReadiness.lastLine("\n\n  \n") == nil)
    }
}
