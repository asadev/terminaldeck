/**
 * The live browser view: the coordinate math a tap depends on, the width a
 * viewer negotiates, the paste cleaning — and the link that routes frames and
 * never watches a machine that did not offer it.
 *
 * A port of the checked parts of `pwa/src/browser-view.ts`. The canvas, the
 * paint/ack loop and the gestures are checked on a simulator; these are the
 * decisions a screenshot cannot show — the css→image transform the host inverts,
 * and the bytes a page's field would choke on.
 */

import XCTest
@testable import TerminalDeck

final class WatchTests: XCTestCase {

    // MARK: - Geometry

    /**
     * The letterbox, which is the whole of why a tap used to land somewhere else.
     *
     * A desktop page is wider than it is tall and a phone in portrait is the
     * other way round, so the picture is fitted to the width and there is black
     * under it. The old mapping divided the *view's* height into the frame, which
     * on these numbers reported a touch at the top of the picture as a third of
     * the way down the document.
     */
    func testFitIsWidthLimitedAndAnchoredToTheTop() {
        // 1280×800 into a 400×800-point view: width-limited, 250 points tall.
        let rect = WatchMath.fit(frameW: 1280, frameH: 800, in: CGSize(width: 400, height: 800))
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 0, "the page sits under the bar, not floating in the middle")
        XCTAssertEqual(rect.width, 400)
        XCTAssertEqual(rect.height, 250)
    }

    func testFitCentresAcrossWhenTheHeightIsWhatRunsOut() {
        // A page taller than the view's aspect: fitted to the height, centred.
        let rect = WatchMath.fit(frameW: 400, frameH: 800, in: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect.height, 400)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.minX, 100)
    }

    func testImageCoordsMeasureInsideTheDrawnRectangle() {
        let drawn = WatchMath.fit(frameW: 1280, frameH: 800, in: CGSize(width: 400, height: 800))
        // The top-left of the *picture* is the top-left of the page, not a third
        // of the way down it.
        let corner = WatchMath.imageCoords(frameW: 1280, frameH: 800, drawn: drawn, px: 0, py: 0)
        XCTAssertEqual(corner.x, 0)
        XCTAssertEqual(corner.y, 0)
        // Its centre is the page's centre.
        let mid = WatchMath.imageCoords(frameW: 1280, frameH: 800, drawn: drawn,
                                        px: drawn.midX, py: drawn.midY)
        XCTAssertEqual(mid.x, 640)
        XCTAssertEqual(mid.y, 400)
        // A drag that leaves the picture still names a pixel on the page, not one
        // beside it. (A *tap* out there is refused before it gets here — see
        // `WatchSurfaceUIView.page(at:)`.)
        let out = WatchMath.imageCoords(frameW: 1280, frameH: 800, drawn: drawn, px: 900, py: -20)
        XCTAssertEqual(out.x, 1280)
        XCTAssertEqual(out.y, 0)
    }

    func testClampDrawnPlacesASmallPictureAndPinsALargeOne() {
        let view = CGSize(width: 400, height: 800)
        // Smaller than the view on both axes: centred across, pinned to the top,
        // wherever it was dragged to.
        let small = WatchMath.clampDrawn(CGRect(x: -300, y: 500, width: 200, height: 100), in: view)
        XCTAssertEqual(small.minX, 100)
        XCTAssertEqual(small.minY, 0)
        // Magnified past the view: the near edge cannot come inside it.
        let big = WatchMath.clampDrawn(CGRect(x: 40, y: 60, width: 800, height: 1600), in: view)
        XCTAssertEqual(big.minX, 0)
        XCTAssertEqual(big.minY, 0)
        let far = WatchMath.clampDrawn(CGRect(x: -900, y: -2000, width: 800, height: 1600), in: view)
        XCTAssertEqual(far.maxX, 400)
        XCTAssertEqual(far.maxY, 800)
    }

    func testWatchWidthIsPointsTimesScaleClampedIntoTheHostsRange() {
        XCTAssertEqual(WatchMath.watchWidth(pointWidth: 400, scale: 3), 1200)
        // Beyond the ceiling is bytes no display can resolve.
        XCTAssertEqual(WatchMath.watchWidth(pointWidth: 1000, scale: 3), Wire.maxWatchWidth)
        // A nonsense scale falls to 1 rather than a refusal.
        XCTAssertEqual(WatchMath.watchWidth(pointWidth: 300, scale: 0), 300)
    }

    func testWatchQualityIsClampedNotRefused() {
        XCTAssertEqual(WatchMath.watchQuality(200), Wire.maxWatchQuality)
        XCTAssertEqual(WatchMath.watchQuality(0), Wire.minWatchQuality)
        XCTAssertEqual(WatchMath.watchQuality(50), 50)
    }

    func testCleanPasteDropsControlsButKeepsTabAndNewline() {
        let cleaned = WatchMath.cleanPaste("a\u{0}b\tc\nd\u{7f}e")
        XCTAssertEqual(cleaned, "ab\tc\nde")
    }

    func testCleanPasteBoundsByBytesOnAScalarBoundary() {
        // A three-byte character never split at the cap.
        let long = String(repeating: "€", count: Wire.maxInputBytes) // 3 bytes each
        let cleaned = WatchMath.cleanPaste(long)
        XCTAssertLessThanOrEqual(cleaned.utf8.count, Wire.maxInputBytes)
        // Whole characters only — no replacement halves.
        XCTAssertFalse(cleaned.unicodeScalars.contains { $0 == "\u{FFFD}" })
    }

    // MARK: - The link

    @MainActor
    func testNothingIsWatchedOfAMachineThatDidNotOfferIt() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [])
        link.ensureRead()
        XCTAssertFalse(link.watch(window: "", maxWidth: 800, quality: 50))
        XCTAssertTrue(wire.sent.isEmpty)

        link.welcomed(capabilities: [WireCapability.watch])
        link.ensureRead()
        guard case .browserSurfaces = wire.sent.first else { return XCTFail("expected a browser.surfaces") }
    }

    @MainActor
    func testSurfacesUpdateFromTheStrip() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        _ = link.receive(.browserSurfaces(rid: nil, surfaces: [
            BrowserSurfaceRow(window: "", url: "https://x", title: "X", live: true),
        ]))
        XCTAssertEqual(link.surfaces.count, 1)
    }

    @MainActor
    func testAFrameIsRoutedToTheOpenViewerAndAckable() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        var received: BrowserFrame?
        link.frameHandler = { received = $0 }
        let frame = BrowserFrame(window: "", seq: 5, w: 8, h: 6, dw: 4, dh: 3, scale: 2,
                                 offsetTop: 0, pageScale: 1, scrollX: 0, scrollY: 0,
                                 masked: false, prompt: nil, data: Data())
        _ = link.receive(.browserFrame(frame))
        XCTAssertEqual(received?.seq, 5)

        link.ack(window: "", seq: 5)
        guard case let .browserFrameAck(_, seq) = wire.sent.last else { return XCTFail("expected an ack") }
        XCTAssertEqual(seq, 5)
    }

    @MainActor
    func testWatchAndUnwatchTrackTheWindowBeingShown() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        _ = link.watch(window: "B2", maxWidth: 800, quality: 50)
        XCTAssertEqual(link.watching, "B2")
        link.unwatch(window: "B2")
        XCTAssertNil(link.watching)
    }

    // MARK: - The handover

    /*
     * The half of *"Claude can ask for the input to put password and put email
     * and then he can continue"* that had no answer until three frames existed.
     * What is checked here is the part a photograph cannot show: which of the
     * four states this phone believes it is in, and which frame it will send.
     */

    @MainActor
    private func asking(_ link: WatchLink, window: String = "B2",
                        rid: String? = nil, mine: Bool = false, taken: Bool? = nil,
                        prompt: String = "Sign in to GitHub, then say done.") {
        // `taken` defaults to whatever `mine` says, because the host cannot
        // honestly report a page held by this device and held by nobody. Passed
        // explicitly only where a case is about the third state — somebody else.
        _ = link.receive(.browserHandover(BrowserHandoverState(
            rid: rid, window: window, asking: true, prompt: prompt,
            mine: mine, taken: taken ?? mine)))
    }

    @MainActor
    func testAHandoverArrivesAndCanBeClaimed() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])

        // Nothing outstanding: no bar, and no claim to send.
        XCTAssertNil(link.handover("B2"))
        XCTAssertFalse(link.take(window: "B2"), "a claim with no question to answer is not sent")
        XCTAssertTrue(wire.sent.isEmpty)

        asking(link)
        let state = link.handover("B2")
        XCTAssertEqual(state?.asking, true)
        XCTAssertEqual(state?.mine, false)
        XCTAssertEqual(state?.taken, false, "an unanswered question is held by nobody")
        XCTAssertEqual(state?.prompt, "Sign in to GitHub, then say done.")

        XCTAssertTrue(link.take(window: "B2"))
        guard case let .browserHandoverTake(_, window) = wire.sent.last else {
            return XCTFail("expected a browser.handover.take")
        }
        XCTAssertEqual(window, "B2")

        // In flight: a second tap is not a second claim.
        XCTAssertTrue(link.isAwaiting("B2"))
        XCTAssertFalse(link.take(window: "B2"))
        XCTAssertEqual(wire.sent.count, 1)

        // The answer, addressed to this connection.
        asking(link, rid: "wch-1", mine: true)
        XCTAssertEqual(link.handover("B2")?.mine, true)
        XCTAssertFalse(link.isAwaiting("B2"))
    }

    /**
     * The two answers are two frames, and the difference is on the wire.
     *
     * *Done, carry on* returns the baton; *stop* ends the drive. A `done` that
     * did not say which is refused at the far end, so the flag is never
     * defaulted — and neither answer may be sent by a device that is not holding
     * the page.
     */
    @MainActor
    func testOnlyTheHolderHandsBackAndBothAnswersAreSayable() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])

        asking(link)
        XCTAssertFalse(link.handBack(window: "B2", carryOn: true),
                       "a watcher that does not hold the page cannot hand it back")
        XCTAssertTrue(wire.sent.isEmpty)

        asking(link, mine: true)
        XCTAssertTrue(link.handBack(window: "B2", carryOn: true))
        guard case let .browserHandoverDone(_, _, carryOn) = wire.sent.last else {
            return XCTFail("expected a browser.handover.done")
        }
        XCTAssertTrue(carryOn)

        // And the other sentence, from a fresh claim.
        asking(link, rid: "wch-9", mine: true)
        XCTAssertTrue(link.handBack(window: "B2", carryOn: false))
        guard case let .browserHandoverDone(_, _, stop) = wire.sent.last else {
            return XCTFail("expected a second browser.handover.done")
        }
        XCTAssertFalse(stop)
    }

    /// Handed back — the question is over, and everything derived from it goes
    /// with it rather than being inherited by the next one.
    @MainActor
    func testAFinishedHandoverLeavesNothingBehind() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        asking(link, mine: true)
        _ = link.receive(.browserHandover(BrowserHandoverState(
            rid: nil, window: "B2", asking: false, prompt: "", mine: false, taken: false)))
        XCTAssertNil(link.handover("B2"))
        XCTAssertFalse(link.isAwaiting("B2"))
    }

    /**
     * The second phone, from the field rather than from a guess.
     *
     * `mine` and `taken` are two booleans and three states: claimable, mine,
     * somebody else's. This used to be inferred here — a second unsolicited push
     * for a window already asking could only be a take — and the inference was
     * right and was still the wrong thing to ship. The host says it now, so the
     * only thing left to check is that this end reads it and does not carry
     * anything over between pushes.
     */
    @MainActor
    func testTakenIsReadFromTheFrameAndNotInferred() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])

        asking(link)
        XCTAssertEqual(link.handover("B2")?.taken, false)

        // A repeat of the identical push is no longer evidence of anything.
        asking(link)
        XCTAssertEqual(link.handover("B2")?.taken, false,
                       "a second push says only what it carries")

        // Somebody else answers it.
        asking(link, taken: true)
        XCTAssertEqual(link.handover("B2")?.taken, true)
        XCTAssertEqual(link.handover("B2")?.mine, false)

        // And it is not sticky: the host is the source of truth in both
        // directions, so a state that says nobody holds it means nobody holds it.
        asking(link, taken: false)
        XCTAssertEqual(link.handover("B2")?.taken, false)
    }

    /**
     * A refused claim says the machine's words and leaves a way to ask again.
     *
     * The wire's error frame carries no correlation id, so this is narrowed to
     * the moment an answer of ours was outstanding — and does nothing at all
     * when none was.
     */
    @MainActor
    func testARefusedClaimCarriesTheMachinesOwnSentence() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])

        link.wireErrored("unrelated")
        XCTAssertNil(link.handover("B2"), "an error with nothing outstanding invents no handover")

        asking(link)
        XCTAssertTrue(link.take(window: "B2"))
        link.wireErrored("no handover is outstanding on that window")
        XCTAssertEqual(link.handover("B2")?.refusal, "no handover is outstanding on that window")
        XCTAssertFalse(link.isAwaiting("B2"))

        // Asking again clears the last refusal rather than stacking on it.
        XCTAssertTrue(link.take(window: "B2"))
        XCTAssertNil(link.handover("B2")?.refusal)
    }

    /// The grant belongs to a connection, so a reconnect starts with none of it.
    @MainActor
    func testAReconnectKeepsNoHandover() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        asking(link, mine: true)
        link.welcomed(capabilities: [WireCapability.watch])
        XCTAssertNil(link.handover("B2"))
    }

    /// Two windows can be asking at once — two sessions, two agents, two logins
    /// — and answering one says nothing about the other.
    @MainActor
    func testTwoWindowsAskAtOnceAndAreAnsweredSeparately() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [WireCapability.watch])
        asking(link, window: "B2")
        asking(link, window: "B7", mine: true)
        XCTAssertEqual(link.handover("B2")?.mine, false)
        XCTAssertEqual(link.handover("B7")?.mine, true)
        XCTAssertFalse(link.handBack(window: "B2", carryOn: true))
        XCTAssertTrue(link.handBack(window: "B7", carryOn: true))
    }

    /// A machine that never offered `watch` is never sent either verb, the same
    /// way it is never sent a `browser.watch`.
    @MainActor
    func testNoHandoverFrameReachesAMachineThatDidNotOfferWatching() {
        let wire = TapWire()
        let link = WatchLink(wire: wire)
        link.welcomed(capabilities: [])
        asking(link, mine: true)
        XCTAssertFalse(link.take(window: "B2"))
        XCTAssertFalse(link.handBack(window: "B2", carryOn: true))
        XCTAssertTrue(wire.sent.isEmpty)
    }
}

@MainActor
private final class TapWire: CopilotWire {
    var sent: [ClientMessage] = []
    @discardableResult
    func send(_ message: ClientMessage) -> Bool { sent.append(message); return true }
}
