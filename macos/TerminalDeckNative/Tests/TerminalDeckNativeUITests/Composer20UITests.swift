import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private enum Composer20Fixture {
    static func options(fast: Bool) -> NativeRPCValue {
        .object([.init("ready", .bool(true)), .init("permissionMode", .string("bypass")),
            .init("model", .string("claude:sample-opus")), .init("effort", .string("high")),
            .init("efforts", .array([.string("low"), .string("medium"), .string("high"), .string("max")])),
            .init("fastMode", .bool(fast)), .init("catalog", .object([.init("claude", .object([
                .init("models", .array([.object([.init("id", .string("sample-opus")), .init("name", .string("Sample Opus"))])])),
                .init("featured", .array([.string("sample-opus")])),
                .init("fastMode", .object([.init("available", .bool(true)), .init("on", .bool(fast))]))
            ]))]))])
    }
    static func chat(fast: Bool = false, busy: Bool = false) -> NativeRPCValue {
        .object([.init("conversationId", .string("composer20-fixture")), .init("sequence", .number(0)),
            .init("events", .array([])), .init("alive", .bool(true)), .init("busy", .bool(busy)),
            .init("options", options(fast: fast)), .init("draft", .string("Keep going with this conversation."))])
    }
    static let now = 1_791_864_000_000.0
    static var report: UsageReport {
        let account = UsageAccountRef(provider: "claude", id: "work", name: "Work account")
        return UsageReport(readings: [
            .init(id: "five", account: account, window: .fiveHour, used: 0.25, resets: .at(now + 7_200_000), reportedAt: now),
            .init(id: "week", account: account, window: .weekly, used: 0.63, resets: .at(now + 172_800_000), reportedAt: now)
        ], account: account)
    }
}

@MainActor final class Composer20UITests: XCTestCase {
    func testFastModeUsesABooleanOptionAndKeepsTheSessionAndDraft() async throws {
        var written: Bool?
        let model = NativeHootChatModel(fixture: Composer20Fixture.chat(), optionsInvoke: { _, args in
            let patch = args.first as? [String: Any]
            written = patch?["fastMode"] as? Bool
            return Composer20Fixture.options(fast: written ?? false).foundation ?? [:]
        }, source: .session("fixture-session", provider: "claude"))
        model.changeFastMode(true)
        for _ in 0..<100 where model.changingOptions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(written, true)
        XCTAssertEqual(model.catalogue.sections.first?.fastMode, true)
        XCTAssertEqual(model.source.sessionID, "fixture-session")
        XCTAssertEqual(model.composerDraft.text, "Keep going with this conversation.")
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testFastModeWaitsForTheCurrentReplyAndFailureRestoresTheReportedChoice() async throws {
        var writes = 0
        let model = NativeHootChatModel(fixture: Composer20Fixture.chat(busy: true), optionsInvoke: { _, args in
            if !args.isEmpty { writes += 1; throw NativeRPCError.invalidArguments("Fast mode is unavailable.") }
            return Composer20Fixture.options(fast: false).foundation ?? [:]
        }, source: .session("fixture-session", provider: "claude"))
        model.changeFastMode(true)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(model.catalogue.sections.first?.fastMode, true, "the choice shows at once")
        model.acceptFixtureUpdate(Composer20Fixture.chat(busy: false).setting("sequence", .number(1)))
        for _ in 0..<100 where model.changingOptions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.catalogue.sections.first?.fastMode, false)
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}

/// Add the composer frames to the existing opt-in renderer, without rendering the other areas.
extension HOOTSIMRenderingTests {
    func testComposer20LightAndDarkFrames() throws {
        guard ProcessInfo.processInfo.environment["HOOTSIM_OFFSCREEN_XCTEST"] == "1" else { throw XCTSkip("Offscreen renders run only on request.") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"])
        XCTAssertTrue(path.hasSuffix(".noindex"))
        XCTAssertFalse(EngineBridge.shared.isReady)
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let model = NativeHootChatModel(fixture: Composer20Fixture.chat(), source: .session("fixture-session", provider: "claude"))
            let composer = HootComposer(draft: .constant(model.composerDraft), catalogue: model.catalogue,
                placeholder: "Message Claude Code", agentName: "Claude Code", plainMeta: true,
                microphoneAvailable: false, onSend: { _ in }, onStop: {})
            let scheme = dark ? "dark" : "light"
            try Self.render(composer.padding(20), size: CGSize(width: 760, height: 230), dark: dark,
                to: output.appendingPathComponent("composer20-\(scheme).png"))
            try Self.render(SessionChatUsagePanel(report: Composer20Fixture.report, provider: "claude", now: Composer20Fixture.now),
                size: CGSize(width: 380, height: 270), dark: dark,
                to: output.appendingPathComponent("composer20-usage-\(scheme).png"))
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
