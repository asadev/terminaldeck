import Testing
@testable import TerminalDeckNativeCore

struct ROUTINESPresentationTests {
    @Test func editingPreservesUnownedHeadersCommentsAndAdditionalTriggers() {
        let source = "# Old\nwhen: schedule 08:30\nwhen: session-failed\nin: /tmp/routines-test\nenabled: yes\nquiet-for: 2m\nmax-runs-per-hour: 3\ncustom: keep me\n# A note\n\n---\nOld instructions\n"
        var draft = ROUTINESDraft.read(id: "test", text: source)
        draft.name = "New"; draft.prompt = "Read logs"; draft.projectID = "imatch"; draft.agentID = "critic"
        #expect(draft.problem == nil)
        #expect(draft.text.contains("when: session-failed"))
        #expect(draft.text.contains("quiet-for: 2m"))
        #expect(draft.text.contains("max-runs-per-hour: 3"))
        #expect(draft.text.contains("custom: keep me"))
        #expect(draft.text.contains("# A note"))
        #expect(draft.text.contains("agent-id: critic"))
        #expect(draft.text.contains("project-id: imatch"))
        #expect(!draft.text.contains("Old instructions"))
    }
    @Test func invalidFieldsCannotInjectRoutineHeaders() {
        var draft = ROUTINESDraft(id: "test")
        draft.name = "Test"; draft.folder = "/tmp/routines-test"; draft.prompt = "Read logs"
        #expect(draft.problem == nil)
        draft.name = "Test\nenabled: no"; #expect(draft.problem != nil)
        draft.name = "Test"; draft.prompt = String(repeating: "x", count: 8_193); #expect(draft.problem != nil)
        draft.prompt = "Read logs"; draft.time = "25:00"; #expect(draft.problem != nil)
        draft.time = "08:30"; draft.hours = 169; #expect(draft.problem != nil)
    }
    @Test func legacyRoutinesBelongToHootAndMetadataSurvivesReading() {
        let rows = ROUTINESRoutine.list(.parse("[{\"id\":\"legacy\",\"name\":\"Legacy\",\"state\":\"armed\",\"enabled\":true},{\"id\":\"owned\",\"name\":\"Owned\",\"agentId\":\"critic\",\"projectId\":\"imatch\",\"state\":\"paused\",\"enabled\":true,\"lastOutcome\":\"failed\"}]"))
        #expect(rows.count == 2)
        #expect(rows[0].agentID == "@hoot")
        #expect(rows[0].projectID == "every-project")
        #expect(rows.filter { $0.projectID == "imatch" }.map(\.id) == ["owned"])
        #expect(rows.filter(ROUTINESFilter.on.accepts).map(\.id) == ["legacy"])
        #expect(rows.filter(ROUTINESFilter.failed.accepts).map(\.id) == ["owned"])
    }
    @Test func policyEditsPreserveUnknownHeadersAndLegacyTiming() {
        let original = "# Old\nwhen: schedule 08:30\nwhen: session-failed\nin: /tmp/project\noverlap: queue\ncustom: keep\n# Note\n---\nGo"
        var draft = ROUTINESDraft.read(id: "old", text: original)
        #expect(draft.catchUp == "legacy"); #expect(draft.text.contains("overlap: queue")); #expect(!draft.text.contains("catch-up:"))
        draft.overlap = "queue-all"; draft.catchUp = "replay"; draft.maxPending = 9; draft.maxCatchUp = 3
        let reread = ROUTINESDraft.read(id: "old", text: draft.text)
        #expect(reread.overlap == "queue-all"); #expect(reread.catchUp == "replay"); #expect(reread.maxPending == 9); #expect(reread.maxCatchUp == 3)
        #expect(draft.text.contains("custom: keep")); #expect(draft.text.contains("# Note")); #expect(draft.text.contains("when: session-failed"))
        draft.catchUp = "once\nenabled: no"; #expect(draft.problem != nil)
    }
    @Test func structuredSchedulesUseExistingBackendGrammar() {
        var draft = ROUTINESDraft(id: "test")
        draft.schedule = "weekdays"; #expect(draft.trigger == "schedule 08:30 weekdays")
        draft.schedule = "weekly"; draft.day = "sun"; #expect(draft.trigger == "schedule 08:30 sun")
        draft.schedule = "hours"; draft.hours = 6; #expect(draft.trigger == "schedule every 6h")
        draft.whenKind = "event"; draft.event = "file-change"; draft.glob = "src/**"; #expect(draft.trigger == "file-change src/**")
    }
}
