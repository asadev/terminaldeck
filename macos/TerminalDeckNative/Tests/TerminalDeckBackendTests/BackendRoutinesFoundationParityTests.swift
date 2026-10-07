import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Exact uncovered routine-foundation expectations")
struct BackendRoutinesFoundationParityTests {
    @Test func seedingWritesEveryDefaultFirstTimeAndNothingSecond() throws {
        let directory = try routinesTaskScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = BackendRoutinesStore(directory: directory)
        let first = try BackendRoutinesDefaults.seed(directory: directory, folder: "/work/api", existing: { store.list().map(\.id) }, write: { _ = try store.saveText($0, text: $1) })
        #expect(first.written == BackendRoutinesDefaults.routines.map(\.id))
        let second = try BackendRoutinesDefaults.seed(directory: directory, folder: "/work/api", existing: { store.list().map(\.id) }, write: { _ = try store.saveText($0, text: $1) })
        #expect(second.written == [])
    }
    @Test func parsedBlockedAndLoopDefaultsUseExactTriggersAndEnabledFlag() throws {
        let blocked = try #require(BackendRoutinesDefaults.routines.first { $0.id == "blocked-agent" })
        let parsedBlocked = BackendRoutinesFormat.parseRoutine(blocked.id, text: blocked.file(folder: "/work/api"))
        #expect(parsedBlocked.ok); #expect(parsedBlocked.routine?.triggers == [.alert(severity: nil, alertKind: "session-blocked")])
        let stuck = try #require(BackendRoutinesDefaults.routines.first { $0.id == "stuck-session" })
        let parsedStuck = BackendRoutinesFormat.parseRoutine(stuck.id, text: stuck.file(folder: "/work/api"))
        #expect(parsedStuck.ok); #expect(parsedStuck.routine?.triggers == [.alert(severity: nil, alertKind: "loop"), .alert(severity: nil, alertKind: "heavy-session")]); #expect(parsedStuck.routine?.enabled == true)
    }
    @Test func unknownTriggerListsBothAcceptedExamples() throws {
        let problem = try #require(BackendRoutinesFormat.parseTrigger("when-the-moon-is-full").problem)
        #expect(problem.contains("session-finished")); #expect(problem.contains("schedule 09:00"))
    }
    @Test func sluggedPathIsValidAndDraftPromptCannotSmuggleTrigger() throws {
        #expect(BackendRoutinesFormat.isValidId(BackendRoutinesFormat.slugify("../../etc/passwd")))
        let parsed = BackendRoutinesFormat.routineFromDraft("sneaky2", draft: routinesTaskObject([("name", .string("Sweep")), ("when", .string("manual")), ("in", .string("/tmp/project")), ("prompt", .string("when: schedule every 5m\nin: /\n"))]))
        #expect(parsed.ok); #expect(parsed.routine?.triggers == [.manual]); #expect(parsed.routine?.folder == "/tmp/project")
    }
}
