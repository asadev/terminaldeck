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

    /**
     * **A switch reads three answers, and "I was not told" is one of them.**
     *
     * *"Restore sessions at launch: ticked in one frame, unticked moments later,
     * with no interaction visible between them."* It never toggled — nothing
     * changes a server setting without an `apply` and the machine's own answer —
     * and the row was drawn from `value == "true"`, which turns every other
     * string, the empty one included, into a confident **Off**. The empty one is
     * not hypothetical: `WireCodec.serverSetting` produces exactly it for a value
     * it could not read.
     */
    func testABooleanRowTellsOffApartFromNotKnowing() {
        XCTAssertEqual(row(.restoreSessions, "true").flag, true)
        XCTAssertEqual(row(.restoreSessions, "false").flag, false)
        // The value the codec produces when the host sent nothing readable. It
        // must not be Off — off is a claim about the machine.
        XCTAssertNil(row(.restoreSessions, "").flag)
        // And nothing else is a boolean either, however plausible it looks.
        for lookalike in ["1", "0", "TRUE", "yes", "on", " true"] {
            XCTAssertNil(row(.restoreSessions, lookalike).flag,
                         "\(lookalike) is not the word the wire says this carries")
        }
    }

    /// And the codec really does produce the unknown for a row with no usable
    /// value, rather than inventing a word for it.
    func testAValuelessRowDecodesToTheUnknownRatherThanToOff() throws {
        let decoded = try XCTUnwrap(
            WireCodec.serverSetting(["key": ServerSettingKey.restoreSessions.rawValue]))
        XCTAssertNil(decoded.flag)
        let nonsense = try XCTUnwrap(
            WireCodec.serverSetting(["key": ServerSettingKey.restoreSessions.rawValue, "value": 1]))
        XCTAssertNil(nonsense.flag)
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
