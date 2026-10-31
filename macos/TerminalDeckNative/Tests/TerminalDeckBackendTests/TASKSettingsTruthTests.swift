import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// SETTINGS-TRUTH (12 Oct), tasks seat, row 37: Settings › Tasks › CRM connection › "Counts as complete" was saved and
/// never read. A CRM marking a task with that status now ends the work on it here; any other status is only recorded.
@Suite("TASK settings truth")
struct TASKSettingsTruthTests {
    @Test func theCompleteStatusFromTheCRMStopsTheTaskAndOtherStatusesOnlyRecord() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
            let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
            try await r.seed(); let h = try await r.recording()
            func status(_ event: String, _ value: String) -> NativeRPCValue {
                routinesTaskObject([("eventId", .string(event)), ("externalTaskId", .string("m")), ("status", .string(value)), ("changedBy", .string("u-asad"))])
            }
            #expect(try await r.call("status", status("s1", "In Progress"), api: h.api)["value"]["outcome"].string == "recorded")
            #expect(await h.cancelled().isEmpty, "another status changes nothing here")
            // The connection's "Counts as complete" is Done (the default).
            #expect(try await r.call("status", status("s2", "Done"), api: h.api)["value"]["outcome"].string == "recorded")
            #expect(await h.cancelled() == ["m"], "Done in the CRM stops the agent")
            #expect(try await r.core.store.byID("k1:m")?.value["crmStatus"].string == "Done")
            // Already stopped: saying it again stops nothing more.
            _ = try await r.call("status", status("s3", "Done"), api: h.api)
            #expect(await h.cancelled() == ["m"])
        }
    }
}
