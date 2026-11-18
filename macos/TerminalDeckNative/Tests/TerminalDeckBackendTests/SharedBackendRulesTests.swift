import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class SharedBackendRulesTests: XCTestCase, @unchecked Sendable {
    func testRelayCodecUsesWireContract() {
        for count in [0, 1, 32, 64] {
            let secret = Data(repeating: 42, count: count)
            XCTAssertEqual(BackendRelayPacketCodec.hostID(for: secret), Rendezvous.slotName(for: secret))
        }
        let sealed = RelayWire.withSealedVersion(Data([1, 2, 3]))
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(sealed, expected: sealed.count), .message(Data([1, 2, 3])))
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(sealed, expected: 99), .malformed)
        XCTAssertEqual(BackendRelayPacketCodec.readSealedHandshake(Data([255, 1]), expected: 2), .wrongVersion)
    }

    func testCanonicalFolderScopeResolvesAliasesAndRejectsTraversal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: allowed)
        XCTAssertTrue(BackendCompositionAuthority.within(alias.path, allowed.path))
        XCTAssertFalse(BackendCompositionAuthority.within(allowed.path + "/../other", allowed.path))
        XCTAssertFalse(BackendCompositionAuthority.within(allowed.path + "-sibling", allowed.path))
    }

    func testNativeUsageWireKeepsItsNumbersThroughTheFrontendDecoder() throws {
        let account = BackendUsageAccount(provider: "claude", id: "work", name: "Work", configDirectory: "/fixture/work")
        let reading = BackendUsageReading(account: account, window: .weekly, windowMinutes: 10_080, label: "Current week", used: .percent(37),
            resets: .at(9_000_000), observedAt: 1_000, reportedAt: 1_000, source: "claude-usage-api")
        let report = BackendUsageReport(sessionID: "own", account: account, readings: [reading], reason: nil, assembledAt: 1_000)
        let raw = try JSONSerialization.jsonObject(with: report.wireValue.encodedJSON())
        let decoded = try XCTUnwrap(UsageReport.update([raw], sessionID: "own"))
        XCTAssertEqual(decoded.readings.first?.used, 0.37)
        XCTAssertEqual(decoded.readings.first?.resets, .at(9_000_000))
        XCTAssertEqual(UsageReadout.of(try XCTUnwrap(decoded.readings.first), now: 2_000).value, "37%")
        XCTAssertEqual(decoded.accountLabel, "Work")
    }

    func testEffortReadsTheRunningSessionBeforeAppEnvironmentAndAccountDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-effort-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"effortLevel":"low"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        func owner(screen: String, saved: String?) -> BackendCompositionDeckToolsAgentControls {
            .init(access: .init(write: { _, _ in XCTFail("A controls read must never type") }, screen: { _ in screen }, session: { _ in nil },
                                configDir: { _ in root.path }, rememberModel: nil,
                                savedLaunch: { _ in saved.map { .object([.init("effort", .string($0))]) } ?? .null }),
                  transcripts: .init(configDirectory: root.path), environment: ["CLAUDE_CODE_EFFORT_LEVEL": "medium"])
        }
        let welcome = "Claude Code v2.1.224 · Opus 5.5 with xhigh effort · Claude Max\n❯ "
        let running = await owner(screen: welcome, saved: "high").read(sessionID: "s", cwd: nil, provider: "claude", onThisMachine: true)
        XCTAssertEqual(running["effort"]["value"].string, "xhigh")
        XCTAssertEqual(running["effort"]["source"].string, "screen")
        let changed = await owner(screen: welcome + "\nSet effort level to low for this session only", saved: "high").read(sessionID: "s", cwd: nil, provider: "claude", onThisMachine: true)
        XCTAssertEqual(changed["effort"]["value"].string, "low")
        let launched = await owner(screen: "❯ ", saved: "high").read(sessionID: "s", cwd: nil, provider: "claude", onThisMachine: true)
        XCTAssertEqual(launched["effort"]["value"].string, "high")
        XCTAssertEqual(launched["effort"]["source"].string, "launch")
        let accountDefault = await owner(screen: "❯ ", saved: nil).read(sessionID: "s", cwd: nil, provider: "claude", onThisMachine: true)
        XCTAssertEqual(accountDefault["effort"]["value"].string, "low")
        XCTAssertEqual(accountDefault["effort"]["source"].string, "settings")
        XCTAssertNil(BackendCompositionDeckToolsAgentControls.readEffortFromScreen("A reply discussed with high effort · elsewhere"))
    }

    private actor EffortSession {
        var screen = "❯ "
        var saved = "low"
        let refuse: Bool
        var remembered = 0
        init(refuse: Bool) { self.refuse = refuse }
        func write(_ text: String) {
            if text == "\r" { screen = refuse ? "Failed to set effort level: denied\n❯ " : "Set effort level to high for this session only\n❯ " }
            else { screen = "❯ " + text }
        }
        func remember(_ effort: String) { saved = effort; remembered += 1 }
        func launch() -> NativeRPCValue { .object([.init("effort", .string(saved))]) }
        func clear() { screen = "❯ " }
    }

    func testOnlyConfirmedEffortChangesAreRememberedAfterTheirScreenScrollsAway() async throws {
        for refused in [false, true] {
            let session = EffortSession(refuse: refused)
            let owner = BackendCompositionDeckToolsAgentControls(
                access: .init(write: { _, text in await session.write(text) }, screen: { _ in await session.screen }, session: { _ in nil },
                              configDir: nil, rememberModel: nil, savedLaunch: { _ in await session.launch() },
                              rememberEffort: { _, value in await session.remember(value) }),
                transcripts: .init(configDirectory: "/fixture/no-config"), environment: [:],
                timings: .init(poll: 1, echo: 100, command: 100, cycleStep: 100))
            let applied = try await owner.apply(sessionID: "s", cwd: nil, control: "effort", value: "high", provider: "claude")
            XCTAssertEqual(applied["ok"].bool, !refused)
            await session.clear()
            let read = await owner.read(sessionID: "s", cwd: nil, provider: "claude", onThisMachine: true)
            XCTAssertEqual(read["effort"]["value"].string, refused ? "low" : "high")
            let remembered = await session.remembered
            XCTAssertEqual(remembered, refused ? 0 : 1)
        }
    }

    func testSettingsProtectionAndEffortCatalogueAreShared() {
        for key in BackendDeckCoreCatalogueRules.protectedKeys + BackendDeckCoreCatalogueRules.protectedPrefixes.map({ $0 + "future" }) + ["appearance.theme"] {
            XCTAssertEqual(BackendDeckToolsAppApplication.isProtected(key), BackendDeckCoreCatalogueRules.isProtectedSetting(key))
        }
        XCTAssertEqual(BackendCompositionDeckToolsAgentControls.effortLevels.map(\.id), AGSCapabilities.claudeEffortOptions.map(\.id))
    }
}
