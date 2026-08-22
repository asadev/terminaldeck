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

    func testImageCoordsMapTheBoxRatioOnEachAxis() {
        // A 800×600 frame shown in a 400×300 view: the centre of the view is the
        // centre of the image.
        let mid = WatchMath.imageCoords(frameW: 800, frameH: 600, viewW: 400, viewH: 300, px: 200, py: 150)
        XCTAssertEqual(mid.x, 400)
        XCTAssertEqual(mid.y, 300)
        // A drag that leaves the view still names a pixel on the page, not one
        // beside it.
        let out = WatchMath.imageCoords(frameW: 800, frameH: 600, viewW: 400, viewH: 300, px: 500, py: -20)
        XCTAssertEqual(out.x, 800)
        XCTAssertEqual(out.y, 0)
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
}

@MainActor
private final class TapWire: CopilotWire {
    var sent: [ClientMessage] = []
    @discardableResult
    func send(_ message: ClientMessage) -> Bool { sent.append(message); return true }
}
