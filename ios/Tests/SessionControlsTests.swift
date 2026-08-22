/**
 * The control cluster: the catalogue's decisions, and the link's rid/session
 * matching.
 *
 * A port of the checked parts of `pwa/src/session-controls.ts` — what draws
 * (`clusterShown`), what a chip prints, why one is blocked, and the rule that
 * makes a refused apply revert by construction (the ticked row is the far end's
 * re-read, never the pressed value). The shapes on screen are checked on a
 * simulator; these are the decisions a screenshot cannot show.
 */

import XCTest
@testable import TerminalDeck

final class SessionControlsTests: XCTestCase {

    private func reading(model: ControlReadingWire = .empty,
                         effort: ControlReadingWire = .empty,
                         fast: ControlReadingWire = .empty,
                         permission: ControlReadingWire = .empty,
                         live: Bool = true, agent: Bool = true,
                         canType: Bool = true, gate: String? = nil) -> ControlsReadingWire {
        ControlsReadingWire(model: model, effort: effort, fast: fast, permission: permission,
                            live: live, agentRunning: agent, canType: canType, gateReason: gate)
    }

    // MARK: - What is drawn

    func testTheClusterIsHiddenUntilThereIsSomethingRealToShow() {
        XCTAssertFalse(SessionControls.clusterShown(nil))
        XCTAssertFalse(SessionControls.clusterShown(reading(live: false)))
        // A plain shell: a model menu over /bin/zsh acts on nothing.
        XCTAssertFalse(SessionControls.clusterShown(reading(agent: false)))
        XCTAssertTrue(SessionControls.clusterShown(reading()))
    }

    func testABlockedControlKeepsItsChipAndOpensOntoTheReason() {
        // The control's own sentence first — every word is the far end's.
        let barred = ControlReadingWire(value: "on", label: "On", unavailableReason: "Fast mode requires usage credits")
        XCTAssertEqual(SessionControls.blocked(.fast, reading(fast: barred)), "Fast mode requires usage credits")
        // Then the typing gate, with the far end's reason.
        XCTAssertEqual(SessionControls.blocked(.model, reading(canType: false, gate: "mid-turn")), "mid-turn")
        // And a gate closed without a reason claims only what is known.
        XCTAssertEqual(SessionControls.blocked(.model, reading(canType: false)),
                       "This session cannot be typed into right now, so nothing was sent.")
        XCTAssertNil(SessionControls.blocked(.model, reading()))
    }

    func testAChipPrintsTheValueAloneAndShortensAModel() {
        let model = ControlReadingWire(value: "opus", label: "Opus 5 (recommended)", unavailableReason: nil)
        XCTAssertEqual(SessionControls.chipText(.model, reading(model: model)), "Opus 5")
        // An unread permission says so rather than guessing.
        XCTAssertEqual(SessionControls.chipText(.permission, reading()), "Not reported")
        XCTAssertEqual(SessionControls.chipText(.model, reading()), "Unknown")
    }

    func testFastFlipReadsTheReadingNotThePicture() {
        XCTAssertEqual(SessionControls.fastFlip(ControlReadingWire(value: "on", label: "On", unavailableReason: nil)), "off")
        XCTAssertEqual(SessionControls.fastFlip(ControlReadingWire(value: "off", label: "Off", unavailableReason: nil)), "on")
    }

    // MARK: - The catalogue

    func testTheCurrentRowIsTickedByIdOrByNormalisedName() {
        let opus = ControlOption(id: "opus", label: "Opus 5")
        // Exact id.
        XCTAssertTrue(ControlCatalog.isCurrent(ControlReadingWire(value: "opus", label: nil, unavailableReason: nil), opus))
        // A screen that printed a decorated label still ticks the row.
        XCTAssertTrue(ControlCatalog.isCurrent(ControlReadingWire(value: "x", label: "Opus 5 (recommended)", unavailableReason: nil), opus))
        // A different model does not.
        XCTAssertFalse(ControlCatalog.isCurrent(ControlReadingWire(value: "sonnet", label: "Sonnet 5", unavailableReason: nil), opus))
        // 1M and non-1M are different rows.
        let opus1m = ControlOption(id: "opus[1m]", label: "Opus 5 with 1M context")
        XCTAssertFalse(ControlCatalog.isCurrent(ControlReadingWire(value: "opus", label: "Opus 5", unavailableReason: nil), opus1m))
    }

    func testShortModelLabelFoldsPlanAndKeeps1M() {
        XCTAssertEqual(ControlCatalog.shortModelLabel("Opus 5 with 1M context"), "Opus 5 1M")
        XCTAssertEqual(ControlCatalog.shortModelLabel("Opus in plan mode, else Sonnet"), "Opus Plan")
        XCTAssertEqual(ControlCatalog.shortModelLabel("Sonnet 5 (recommended)"), "Sonnet 5")
    }

    // MARK: - The link

    @MainActor
    func testNothingIsAskedOfAMachineThatDidNotOfferControls() {
        let wire = TapWire()
        let link = SessionControlsLink(wire: wire)
        link.welcomed(capabilities: [])
        link.follow("s1")
        XCTAssertTrue(wire.sent.isEmpty)

        link.welcomed(capabilities: [WireCapability.controls])
        link.follow("s1")
        guard case .controlsRead = wire.sent.first else { return XCTFail("expected a controls.read") }
    }

    @MainActor
    func testAReadingForAnotherSessionIsDropped() {
        let wire = TapWire()
        let link = SessionControlsLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.controls])
        link.follow("s1")
        guard case let .controlsRead(rid, _) = wire.sent.first else { return XCTFail() }
        // Same rid, wrong session — a screen that moved on between question and
        // answer. Another session's model must not land on this chip.
        _ = link.receive(.controlsReading(rid: rid, id: "s2", reading: reading(model: ControlReadingWire(value: "opus", label: "Opus 5", unavailableReason: nil))))
        XCTAssertNil(link.reading)
    }

    @MainActor
    func testAnAppliedAnswerReplacesTheReadingWithTheFarEndsReRead() {
        let wire = TapWire()
        let link = SessionControlsLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.controls])
        link.follow("s1")
        guard case let .controlsRead(readRid, _) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.controlsReading(rid: readRid, id: "s1",
            reading: reading(effort: ControlReadingWire(value: "low", label: "Low", unavailableReason: nil))))

        link.apply(.effort, "xhigh")
        guard case let .controlsApply(applyRid, _, control, value) = wire.sent.last else { return XCTFail() }
        XCTAssertEqual(control, .effort)
        XCTAssertEqual(value, "xhigh")

        // The far end refuses and re-reads the session as it actually is — still
        // Low. The chip must show Low, not the pressed xhigh: a refused apply
        // reverts by construction.
        _ = link.receive(.controlsApplied(rid: applyRid, id: "s1", ok: false,
            message: "That could not be set.",
            reading: ControlReadingWire(value: "low", label: "Low", unavailableReason: nil)))
        XCTAssertEqual(link.reading?.effort.value, "low")
        XCTAssertEqual(link.notice?.ok, false)
    }

    @MainActor
    func testADroppedSocketClearsTheReading() {
        let wire = TapWire()
        let link = SessionControlsLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.controls])
        link.follow("s1")
        guard case let .controlsRead(rid, _) = wire.sent.first else { return XCTFail() }
        _ = link.receive(.controlsReading(rid: rid, id: "s1", reading: reading()))
        XCTAssertNotNil(link.reading)
        link.dropped()
        // A reading is a claim about now, and no dead socket will correct it.
        XCTAssertNil(link.reading)
    }
}

@MainActor
private final class TapWire: CopilotWire {
    var sent: [ClientMessage] = []
    var accepting = true
    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        guard accepting else { return false }
        sent.append(message)
        return true
    }
}
