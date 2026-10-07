import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsRootPortTourGateTests: XCTestCase {
    typealias S = BackendDeckToolsRootPortTourSupport
    struct Runtime: BackendDeckToolsTourRuntime {
        let kind: String, interactive: NativeRPCValue, evidence: S.Evidence
        func callerKind(_ context: BackendMCPCallContext) async throws -> String { kind }
        func interactiveSetting() async throws -> NativeRPCValue { interactive }
        func facts(sessionID: String) async throws -> NativeRPCValue? { try await evidence.facts(sessionID: sessionID) }
        func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool { try await evidence.supports(reason: reason, importance: importance, median: median, sample: sample) }
        func authorize(_ context: BackendMCPCallContext, tier: BackendMCPTier, summary: String) async throws { if !context.allowedTiers.contains(tier) { throw BackendDeckCoreSecurityRefusal(.notGranted, "This caller is not permitted to use that tool.") } }
        func completed(_ context: BackendMCPCallContext, summary: NativeRPCValue) async throws {}
    }
    private static func call(_ r: S.Rig, args: NativeRPCValue? = nil, kind: String = "local", attended: Bool = true,
                      tiers: Set<BackendMCPTier> = [.read, .act, .alter], interactive: NativeRPCValue = .missing) async throws -> BackendMCPToolReply {
        let runtime = Runtime(kind: kind, interactive: interactive, evidence: .init())
        let definition = try BackendDeckToolsTourTool.definitions(stage: r.stage, runtime: runtime).first!
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: attended,
            allowedTools: ["tour.play"], allowedTiers: tiers, cancellation: .init())
        return try await definition.handler(context, args ?? S.plan([S.stop()]))
    }
    private func play(_ r: S.Rig, args: NativeRPCValue? = nil) async throws -> BackendMCPToolReply {
        let task = Task { try await Self.call(r, args: args) }; let offer = await r.window.offered(); _ = await r.stage.acknowledge(offer.record.id); return try await task.value
    }
    private func baseline(_ r: S.Rig) async throws -> BackendDeckCoreSecurityControl {
        let ids: [(String, BackendMCPTier)] = [("sessions.send", .act), ("sessions.start", .act), ("sessions.list", .read), ("machines.session", .act), ("servers.shell", .act)]
        let policies = try ids.map { id, tier in
            BackendDeckCoreSecurityToolPolicy(tool: try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "fixture", inputSchema: S.o([("type", .string("object")), ("properties", .object([]))]), tier: tier), summary: { _, _ in id }, run: { _, _ in .init(value: .object([])) })
        }
        return try BackendDeckCoreSecurityControl(log: .init(directory: r.directory.appendingPathComponent("log"), now: { r.clock.now() }), consent: .init(ask: { _ in false }), policies: policies, now: { r.clock.now() }, driving: { await r.stage.driving() })
    }
    func testPhoneHoldingActCannotDriveAndMustAnswerInWords() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, kind: "remote")
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-granted")); XCTAssertTrue(reply.content.first?["text"].string?.contains("sitting at this machine") == true)
        let driving = await r.stage.driving(); XCTAssertFalse(driving)
    }
    func testPhoneWithNoTiersIsRefused() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, kind: "remote", tiers: [])
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-granted"))
    }
    func testPersonAtKeyboardCanPlay() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await play(r); XCTAssertFalse(reply.isError); XCTAssertEqual(reply.structuredContent?["played"], .bool(true)); await r.stage.stop()
    }
    func testUnattendedRunIsRefusedWithNoBypassSentence() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, attended: false)
        XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-permitted-unattended")); XCTAssertTrue(reply.content.first?["text"].string?.contains("Do not retry") == true)
    }
    func testNarrowedRoutineContextRemainsUnattended() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, attended: false, tiers: [.read, .act])
        XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-permitted-unattended"))
    }
    func testDrivingGateIncludesChangingFamiliesAndTour() {
        for id in ["sessions.send", "sessions.start", "sessions.stop", "settings.write", "routines.create", "tour.play"] { XCTAssertTrue(BackendDeckCoreSecurityControl.refusedWhileDriving(id), id) }
    }
    func testDrivingGateIncludesNewSessionUIAndRemoteTypingTools() {
        for id in ["sessions.keys", "sessions.rename", "sessions.account", "sessions.held", "ui.do", "hoot.run", "settings.reset", "agents.set_control", "accounts.sign_in", "updates.install", "machines.session", "servers.shell"] { XCTAssertTrue(BackendDeckCoreSecurityControl.refusedWhileDriving(id), id) }
        for id in ["sessions.wait", "sessions.screen", "ui.list", "files.read", "machines.look", "servers.details"] { XCTAssertFalse(BackendDeckCoreSecurityControl.refusedWhileDriving(id), id) }
    }
    func testReadingAndLogNotesRemainAllowed() {
        for id in ["sessions.list", "git.status", "log.note"] { XCTAssertFalse(BackendDeckCoreSecurityControl.refusedWhileDriving(id), id) }
    }
    func testMidTourSendRefusalIsLoggedAndSaysWait() async throws {
        let r = S.rig(); defer { r.dispose() }; let control = try await baseline(r); _ = try await play(r)
        let reply = await control.call(name: "sessions.send", arguments: .object([]))
        XCTAssertFalse(reply.ok); XCTAssertEqual(reply.refusal, .whileDriving); XCTAssertTrue(reply.error?.contains("Wait until the tour ends") == true); XCTAssertEqual(reply.row["outcome"], .string("refused")); await r.stage.stop()
    }
    func testMidTourReadStillAnswers() async throws {
        let r = S.rig(); defer { r.dispose() }; let control = try await baseline(r); _ = try await play(r)
        let reply = await control.call(name: "sessions.list", arguments: .object([])); XCTAssertTrue(reply.ok); await r.stage.stop()
    }
    func testTourEndImmediatelyLiftsGate() async throws {
        let r = S.rig(); defer { r.dispose() }; let control = try await baseline(r); _ = try await play(r); await r.stage.stop()
        let reply = await control.call(name: "sessions.start", arguments: .object([])); XCTAssertTrue(reply.ok)
    }
    func testReloadImmediatelyLiftsGate() async throws {
        let r = S.rig(); defer { r.dispose() }; let control = try await baseline(r); _ = try await play(r)
        await r.window.gone(); await r.window.waitForUnwatch()
        let reply = await control.call(name: "sessions.start", arguments: .object([])); XCTAssertNotEqual(reply.refusal, .whileDriving)
    }
    func testUnacceptedPlanNeverShutsGate() async throws {
        let r = S.rig(window: .init(available: false)); defer { r.dispose() }; let control = try await baseline(r)
        let tour = try await Self.call(r); XCTAssertFalse(tour.isError); XCTAssertEqual(tour.structuredContent?["played"], .bool(false))
        let reply = await control.call(name: "sessions.list", arguments: .object([])); XCTAssertTrue(reply.ok)
    }
    func testDroppedStopsAreReported() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await play(r, args: S.plan([S.stop(), S.stop(quote: "never printed")]))
        XCTAssertEqual(reply.structuredContent?["playing"], .number(1)); XCTAssertEqual(reply.structuredContent?["dropped"], .number(1)); await r.stage.stop()
    }
    func testEveryDroppedStopDoesNotDrive() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, args: S.plan([S.stop(quote: "never printed")]))
        XCTAssertEqual(reply.structuredContent?["played"], .bool(false)); let driving = await r.stage.driving(); XCTAssertFalse(driving)
    }
    func testOverBudgetIsRuleRefusalNotTrimmedSuccess() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, args: S.plan(Array(repeating: S.stop(), count: 13)))
        XCTAssertEqual(reply.structuredContent?["refusal"], .string("not-permitted")); XCTAssertTrue(reply.content.first?["text"].string?.contains("refused rather than trimmed") == true)
    }
    func testInteractiveDefaultShowsWork() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await play(r); XCTAssertEqual(reply.structuredContent?["played"], .bool(true)); await r.stage.stop()
    }
    func testInteractiveOffChecksAndRecordsSameAnswerWithoutShowing() async throws {
        let r = S.rig(); defer { r.dispose() }; let reply = try await Self.call(r, interactive: .bool(false)), value = reply.structuredContent!
        XCTAssertEqual(value["played"], .bool(false)); XCTAssertEqual(value["shown"], .string("background")); XCTAssertEqual(value["found"], .number(1))
        let record = await r.stage.list().first { $0["id"] == value["tourId"] }
        XCTAssertEqual(record?["shown"], .string("background")); XCTAssertEqual(record?["stops"].elements?.map { $0["quote"] }, [.string("the build failed")]); XCTAssertNotEqual(record?["endedAt"], .null)
        let offers = await r.window.offerCount(); XCTAssertEqual(offers, 0)
    }
    func testCopilotCannotTurnOffProtectedInteractiveSetting() {
        XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(S.o([("scope", .string("settings")), ("patch", S.o([("copilot.interactive", .bool(false))]))])))
    }
    func testRemoteTypingFamiliesAreRefusedMidTourThroughGate() async throws {
        let r = S.rig(); defer { r.dispose() }; let control = try await baseline(r); _ = try await play(r)
        for id in ["machines.session", "servers.shell"] {
            let reply = await control.call(name: id, arguments: .object([])); XCTAssertEqual(reply.refusal, .whileDriving); XCTAssertTrue(reply.error?.contains("Wait until the tour ends") == true)
        }
        await r.stage.stop()
    }
}
