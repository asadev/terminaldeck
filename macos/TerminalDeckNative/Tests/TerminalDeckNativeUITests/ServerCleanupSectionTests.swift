import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U121: the server Cleanup section.
@Suite("Server Cleanup section")
@MainActor
struct ServerCleanupSectionTests {
    static func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }

    /// A server whose saved cleanup schedule is the short form "daily", with a preview stored days ago.
    static func model() -> NativeAppsSRV2ServerModel {
        NativeAppsSRV2ServerModel(serverID: "s1", serverName: "box", transport: { channel, _ in
            switch channel {
            case "apps:server:status": return try json(#"{"installedVersion":"1","helperVersion":"1"}"#)
            case "apps:server:cleanup:read":
                return try json(#"{"settings":{"enabled":true,"schedule":"daily"},"preview":{"dryRun":true,"finishedAt":1000,"items":[{"kind":"image","id":"sha256:old","result":"would-remove"}]}}"#)
            case "apps:server:cleanup:preview":
                return try json(#"{"dryRun":true,"finishedAt":2000,"items":[{"kind":"image","id":"sha256:now","result":"would-remove"}]}"#)
            default: throw NativeRPCError(code: "unknown-channel", message: "Not in this test.")
            }
        })
    }

    static func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// #564: "daily" opens as saved, not as an unsaved change; a real edit still shows.
    @Test func shortScheduleOpensUnchanged() async throws {
        let model = Self.model()
        model.load()
        try await Self.settle { !model.loading }
        #expect(model.cleanup?.schedule == "daily")
        #expect(!model.cleanupChanged, "nothing was edited")
        model.cleanupSchedule.time = "03:00"
        #expect(model.cleanupChanged && model.proposedCleanup.schedule == "*-*-* 03:00:00")
        model.cleanupSchedule.time = "00:00"
        #expect(!model.cleanupChanged, "back to what was saved")
        #expect(NativeAppsSRV2Schedule(calendar: "weekly").calendar == "weekly")
        var weekly = NativeAppsSRV2Schedule(calendar: "weekly"); weekly.day = "Tue"
        #expect(weekly.calendar == "Tue *-*-* 00:00:00")
    }

    /// #585: an old stored preview is not shown as current and does not enable a run;
    /// a check made here does.
    @Test func onlyAFreshCheckEnablesRun() async throws {
        let model = Self.model()
        model.load()
        try await Self.settle { !model.loading }
        #expect(model.cleanupPreview == nil)
        model.previewCleanup()
        try await Self.settle { model.busy == nil }
        #expect(model.cleanupPreview?.items?.first?.id == "sha256:now")
    }
}
