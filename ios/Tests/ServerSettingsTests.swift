/**
 * The "This server" section: the merge that keeps the two rows in order, and the
 * link that never asks a machine that did not offer them.
 *
 * A port of the checked parts of `pwa/src/server-settings.ts`. The value shown
 * is always the machine's own re-read, so a refused apply reverts by
 * construction; a push from another device folds in without a request.
 */

import XCTest
@testable import TerminalDeck

final class ServerSettingsTests: XCTestCase {

    private func row(_ key: ServerSettingKey, _ value: String, options: [String]? = nil) -> ServerSettingWire {
        ServerSettingWire(key: key, value: value, options: options)
    }

    @MainActor
    func testMergeReplacesByKeyAndKeepsTheFixedOrder() {
        let current = [row(.restoreSessions, "false"), row(.defaultProvider, "claude")]
        let merged = ServerSettingsLink.merge(current: current, next: [row(.defaultProvider, "codex")])
        // Order is always provider then restore, whatever order they arrived in,
        // so a push never reshuffles the section.
        XCTAssertEqual(merged.map(\.key), [.defaultProvider, .restoreSessions])
        XCTAssertEqual(merged.first?.value, "codex")
    }

    func testProviderLabelReadsBuiltinsAndFallsBackToTheId() {
        XCTAssertEqual(ServerSettingsText.providerLabel("claude"), "Claude Code")
        XCTAssertEqual(ServerSettingsText.providerLabel("custom:acme"), "custom:acme")
    }

    @MainActor
    func testNothingIsAskedOfAMachineThatDidNotOfferSettings() {
        let wire = TapWire()
        let link = ServerSettingsLink(wire: wire)
        link.welcomed(capabilities: [])
        link.ensureRead()
        XCTAssertTrue(wire.sent.isEmpty)

        link.welcomed(capabilities: [WireCapability.settings])
        link.ensureRead()
        guard case .settingsRead = wire.sent.first else { return XCTFail("expected a settings.read") }
        // A second visit does not re-ask — the push keeps it fresh.
        link.ensureRead()
        XCTAssertEqual(wire.sent.count, 1)
    }

    @MainActor
    func testARefusedApplyRevertsToTheMachinesReRead() {
        let wire = TapWire()
        let link = ServerSettingsLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.settings])
        link.ensureRead()
        guard case let .settingsRead(readRid) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.settingsState(rid: readRid, settings: [row(.defaultProvider, "claude", options: ["claude", "codex"])]))

        link.apply(.defaultProvider, "codex")
        guard case let .settingsApply(applyRid, key, value) = wire.sent.last else { return XCTFail() }
        XCTAssertEqual(key, .defaultProvider)
        XCTAssertEqual(value, "codex")

        // The server refuses and re-reads: still claude. The control shows what
        // the machine holds, not what was pressed.
        _ = link.receive(.settingsApplied(rid: applyRid, ok: false, message: "Not allowed.",
                                          setting: row(.defaultProvider, "claude", options: ["claude", "codex"])))
        XCTAssertEqual(link.rows?.first(where: { $0.key == .defaultProvider })?.value, "claude")
        XCTAssertEqual(link.notice?.ok, false)
    }

    @MainActor
    func testAChangedPushFoldsInWithoutARequest() {
        let wire = TapWire()
        let link = ServerSettingsLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.settings])
        link.ensureRead()
        guard case let .settingsRead(readRid) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.settingsState(rid: readRid, settings: [row(.restoreSessions, "false")]))
        // Another device turned it on. No rid to match.
        _ = link.receive(.settingsChanged(settings: [row(.restoreSessions, "true")]))
        XCTAssertEqual(link.rows?.first(where: { $0.key == .restoreSessions })?.value, "true")
    }
}

@MainActor
private final class TapWire: CopilotWire {
    var sent: [ClientMessage] = []
    @discardableResult
    func send(_ message: ClientMessage) -> Bool { sent.append(message); return true }
}
