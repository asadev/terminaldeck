import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: saved restore launch fields and separate device boundary")
struct BackendFoundationTestsSessionsRestoreFields {
    private func saved(_ fields: [NativeRPCValue.Field] = []) throws -> BackendSessionSaved {
        try BackendSessionSaved(NativeRPCValue.object([.init("cwd", .string("/home/asad/ClaudeKiwi")), .init("provider", .string("claude")), .init("profileId", .null), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1700000000000))]).merging(.object(fields)))
    }
    // TS session-restore.test.ts:607 — saved-to-launch half only; full restore driver needs a fake lifecycle seam.
    @Test func identicalTabsKeepSeparateStableKeys() throws {
        let left = try saved([.init("cwd", .string("/w")), .init("tabKey", .string("k-left"))]), right = try saved([.init("cwd", .string("/w")), .init("tabKey", .string("k-right"))])
        #expect([left.input(resume: true).tabKey, right.input(resume: false).tabKey] == ["k-left", "k-right"])
    }
    // TS session-restore.test.ts:624 — saved-to-launch half only; spawn ownership remains a gap.
    @Test func legacyInputHasNoTabKeyProperty() throws {
        let input = try saved([.init("cwd", .string("/old"))]).input(resume: false)
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(input)); #expect(!wire.has("tabKey"))
    }
    // TS session-restore.test.ts:634 — field projection only, not the unavailable full driver.
    @Test func profileAndTerminalSizeSurviveProjection() throws {
        let input = try saved([.init("profileId", .string("work")), .init("cols", .number(173)), .init("rows", .number(51)), .init("provider", .string("codex"))]).input(resume: true)
        #expect(input.profileId == "work"); #expect(input.cols == 173); #expect(input.rows == 51); #expect(input.provider == "codex")
    }
    // TS session-restore.test.ts:700 — boundary/projection half; actual spawn still needs lifecycle injection.
    @Test func deviceBoundaryTravelsOutsideRendererInput() async throws {
        let saved = try saved([.init("confineDeviceId", .string("phone-7"))])
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        #expect(try await context.context(for: saved).deviceBoundary?.deviceKey == "phone-7")
        let input = try NativeRPCValue.parseJSON(JSONEncoder().encode(saved.input(resume: true)))
        #expect(!input.has("confineDeviceId")); #expect(!input.has("deviceId"))
    }
    // TS session-restore.test.ts:715 — boundary half; actual spawn still needs lifecycle injection.
    @Test func keyboardTabRequestsNoDeviceBoundary() async throws {
        let saved = try saved(), context = BackendSessionRestoreContext(readiness: .ready) { _, _ in throw BackendSessionFailure.invalidInput("A keyboard tab must never ask for a device.") }
        #expect(try await context.context(for: saved).deviceBoundary == nil)
    }
}
