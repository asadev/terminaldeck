/**
 * Pointing at one thing inside a window on the machine: the arithmetic, the
 * mode, and the promise that both browsers describe an element the same way.
 *
 * `ParityWireTests` covers the two frames — what an ask carries and what an
 * answer decodes to. This covers the three things between them that a wire test
 * cannot see:
 *
 *  - **the mapping**, which turns a tap on a picture into a point on a page. Get
 *    it wrong and every assertion still passes while the sheet describes the
 *    element next to the one somebody's finger was on;
 *  - **the mode**, which is what makes a tap a question instead of a click;
 *  - **the parity**, which is the whole of item V9: one element, described by
 *    two entirely different mechanisms, must reach an agent as one line.
 */

import XCTest
@testable import TerminalDeck

final class MachinePickTests: XCTestCase {

    /// A frame with the geometry a cast actually carries. `scale` is the
    /// picture's pixels over the CSS viewport they cover — `w / dw` — which is
    /// how the host stamps it in `browser-watch.ts`.
    private func frame(w: Int = 800, h: Int = 600, dw: Int = 400, dh: Int = 300,
                       scale: Double = 2, pageScale: Double = 1,
                       scrollX: Double = 0, scrollY: Double = 0,
                       masked: Bool = false) -> BrowserFrame {
        BrowserFrame(window: "B2", seq: 7, w: w, h: h, dw: dw, dh: dh, scale: scale,
                     offsetTop: 0, pageScale: pageScale, scrollX: scrollX, scrollY: scrollY,
                     masked: masked, prompt: nil, data: Data())
    }

    // MARK: - The mapping

    /**
     * An image pixel becomes a point on the **document**, and the scroll is the
     * half that makes it survive the trip.
     *
     * This is the inverse of `BrowserWatch.mapPoint` in
     * `src/main/browser-watch.ts` — `(x / scale) / pageScale` — with the frame's
     * own scroll added back. `mapPoint` deliberately does not add it, because CDP
     * mouse coordinates are viewport ones and a click never wanted the scroll; a
     * pick always does, so that the host can convert back with the page's **live**
     * scroll and say plainly when the page has moved since the picture.
     */
    func testATapOnThePictureBecomesAPointOnTheDocument() {
        // 2× picture: 400 image pixels across is 200 CSS pixels of page.
        let point = MachinePick.documentPoint(frame: frame(scrollX: 0, scrollY: 1200),
                                              imageX: 400, imageY: 200)
        XCTAssertEqual(point.x, 200)
        XCTAssertEqual(point.y, 1300, "the page is scrolled 1200 down; a tap 100 into the "
                       + "viewport is 1300 down the document")
    }

    /// A page zoomed by a pinch is divided out too, the same second divide the
    /// host applies. Headless Chromium reports 1 and always has; the divide is
    /// kept on both sides for the day a scaled visual viewport is streamed, and
    /// this is what stops the two ends disagreeing about it in the meantime.
    func testThePagesOwnZoomIsDividedOutTheSameWayTheHostDividesIt() {
        let point = MachinePick.documentPoint(frame: frame(scale: 2, pageScale: 2, scrollY: 0),
                                              imageX: 400, imageY: 400)
        XCTAssertEqual(point.x, 100)
        XCTAssertEqual(point.y, 100)
    }

    /**
     * A frame whose geometry could not be read maps to the picture's own size
     * rather than to infinity.
     *
     * Dividing by a zero `scale` produces a point the host's parser refuses as *a
     * pick without a point on the page* — an ask that goes nowhere with nothing on
     * screen to explain it. One is the honest guess, and it puts the tap somewhere
     * on the page rather than nowhere.
     */
    func testANonsenseScaleFallsBackToTheImagesOwnSize() {
        let point = MachinePick.documentPoint(frame: frame(scale: 0, pageScale: 0, scrollX: 5),
                                              imageX: 300, imageY: 100)
        XCTAssertEqual(point.x, 305)
        XCTAssertEqual(point.y, 100)
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
    }

    // MARK: - The mode

    /**
     * A tap is a click until somebody says otherwise, and then it is a question.
     *
     * `take` returning false is the canvas's signal to go on and dispatch the
     * mouse triple it was going to dispatch; true is the signal to send
     * **nothing**. That silence is the behaviour: a tap that both described a
     * link and followed it would navigate away from the element it had just
     * described, which is exactly what `InspectScript` cancels on the page this
     * phone holds itself.
     */
    @MainActor
    func testATapIsOnlyTakenWhileTheWindowIsArmed() {
        MachinePick.disarm()
        var asked: [(Double, Double)] = []

        XCTAssertFalse(MachinePick.take(window: "B2", frame: frame(), imageX: 100, imageY: 100),
                       "nothing is armed, so this is an ordinary click")

        MachinePick.arm(window: "B2") { asked.append(($0, $1)) }
        XCTAssertTrue(MachinePick.isArmed(window: "B2"))
        XCTAssertTrue(MachinePick.take(window: "B2", frame: frame(scrollY: 40),
                                       imageX: 200, imageY: 200))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, 100)
        XCTAssertEqual(asked.first?.1, 140)

        // A different window's canvas is not this screen's, and a tap on it is not
        // this screen's question.
        XCTAssertFalse(MachinePick.take(window: "B3", frame: frame(), imageX: 1, imageY: 1))
        XCTAssertEqual(asked.count, 1)

        MachinePick.disarm()
        XCTAssertFalse(MachinePick.take(window: "B2", frame: frame(), imageX: 1, imageY: 1))
        XCTAssertNil(MachinePick.lastPoint, "leaving the mode forgets where the finger was")
    }

    /**
     * **A curtained frame is never asked about.**
     *
     * A masked frame carries no pixels — somebody is typing a password on the far
     * side, or a secret field is on screen — so there is nothing here to have
     * pointed at. Asking the machine what is at a point on a page it is
     * deliberately hiding is the one question this feature must not send, and the
     * refusal is written on this side as well as at the source because every
     * gesture guard on the canvas is `!frame.masked` and this one has to be too.
     */
    @MainActor
    func testACurtainedFrameIsNotSomethingToPointAt() {
        MachinePick.disarm()
        var asked = 0
        MachinePick.arm(window: "B2") { _, _ in asked += 1 }
        XCTAssertFalse(MachinePick.take(window: "B2", frame: frame(masked: true),
                                        imageX: 10, imageY: 10))
        XCTAssertEqual(asked, 0)
        MachinePick.disarm()
    }

    /**
     * Wider and Narrower stay inside the range the host will **parse**.
     *
     * Not politeness. The host checks `up` in its parser and `server.ts` answers
     * a parse failure by closing the socket, so one press too many past the
     * ceiling would drop the terminals and the cast with it. Three locks hold this
     * — the greyed control, this arithmetic, and the codec on the last line before
     * the wire — because the cost of the one that gets missed is somebody's whole
     * session.
     */
    func testTheWalkIsClampedAtBothEnds() {
        XCTAssertEqual(MachinePick.step(from: 0, by: -1), 0)
        XCTAssertEqual(MachinePick.step(from: 3, by: 1), 4)
        XCTAssertEqual(MachinePick.step(from: 3, by: -1), 2)
        XCTAssertEqual(MachinePick.step(from: MachineBrowserWire.maxPickUp, by: 1),
                       MachineBrowserWire.maxPickUp)
        XCTAssertEqual(MachinePick.step(from: MachineBrowserWire.maxPickUp + 40, by: 1),
                       MachineBrowserWire.maxPickUp)
    }

    // MARK: - One element, two roads

    /**
     * **The parity, which is the requirement.**
     *
     * > *"everything should, all of them should be identical… Should not be that
     * > much of difference in all of them."*
     *
     * The phone's own inspector works an element out here, from a DOM it can
     * reach; a machine window's arrives over a wire from a browser this phone
     * cannot touch. If the two produced two different lines for the same element
     * they would be two features wearing one sheet, and nobody would find out
     * until an agent was told to change the wrong thing.
     *
     * So the line is **computed** from the shared value rather than carried on
     * it, by the one composer `ElementCaptureTests` already pins against the
     * desktop's `CapturePanel.tsx`. This says the adapter does not lose anything
     * on the way through.
     */
    func testBothBrowsersDescribeOneElementWithOneLine() {
        let capture = ElementCapture(
            selector: "#pay-now",
            tag: "button",
            label: "Pay now",
            labelSource: .text,
            url: "https://shop.example/checkout",
            attributes: [:],
            context: Inspect.composeAgentContext(Inspect.Core(
                selector: "#pay-now", tag: "button", label: "Pay now",
                labelSource: .text, url: "https://shop.example/checkout")),
            depth: 2,
            ancestors: 5)

        let fromThisPhone = InspectedElement(capture)
        let fromTheMachine = InspectedElement(tag: "button",
                                              selector: "#pay-now",
                                              label: "Pay now",
                                              labelSource: "text",
                                              url: "https://shop.example/checkout",
                                              depth: 2,
                                              maxUp: 5,
                                              rect: PickedRect(x: 40, y: 900, w: 120, h: 44))

        XCTAssertEqual(fromThisPhone.context, fromTheMachine.context,
                       "one element described two ways is the defect this type exists to stop")
        XCTAssertEqual(fromThisPhone.context, capture.context,
                       "the adapter must not change what the phone's own inspector already said")
        XCTAssertEqual(fromTheMachine.context,
                       "[browser: on https://shop.example/checkout, element `#pay-now`, "
                       + "<button>, text \"Pay now\"]")

        // And the two names for one number meet in the adapter rather than in six
        // call sites: `ancestors` on this phone, `maxUp` on the wire.
        XCTAssertEqual(fromThisPhone.maxUp, capture.ancestors)
        XCTAssertEqual(fromThisPhone.canGoWider, fromTheMachine.canGoWider)
        XCTAssertEqual(fromThisPhone.canGoNarrower, fromTheMachine.canGoNarrower)
        XCTAssertEqual(fromThisPhone.depthLine, "2 levels up")
    }

    /**
     * The ends of the chain grey the two controls, and they say the same thing on
     * both kinds of window.
     *
     * `maxUp` at zero is the top of the document — there is nothing above to walk
     * onto — and `depth` at zero is the element the finger actually landed on.
     */
    func testTheEndsOfTheChainAreTheEndsOfTheControls() {
        let atTheTap = InspectedElement(tag: "span", selector: "#a", label: "", labelSource: "none",
                                        url: "https://x/", depth: 0, maxUp: 4)
        XCTAssertTrue(atTheTap.canGoWider)
        XCTAssertFalse(atTheTap.canGoNarrower)
        XCTAssertNil(atTheTap.depthLine, "nothing to say about a walk nobody has taken")

        let atTheTop = InspectedElement(tag: "body", selector: "body", label: "", labelSource: "none",
                                        url: "https://x/", depth: 6, maxUp: 0)
        XCTAssertFalse(atTheTop.canGoWider)
        XCTAssertTrue(atTheTop.canGoNarrower)
        XCTAssertEqual(atTheTop.depthLine, "6 levels up")

        let oneUp = InspectedElement(tag: "div", selector: "#a > div", label: "", labelSource: "none",
                                     url: "https://x/", depth: 1, maxUp: 1)
        XCTAssertEqual(oneUp.depthLine, "1 level up", "singular, because somebody reads it")
    }

    /**
     * A label with no source draws no source, and an unfamiliar one draws itself.
     *
     * The second half is the one that would have been an enum. `PICK_LABEL_SOURCES`
     * carries two words a click on a rendered element cannot produce, and grows
     * the day the machine's label rule learns another.
     */
    func testWhereALabelCameFromIsDrawnAsAWord() {
        XCTAssertEqual(Inspect.describeLabelSource("none"), "")
        XCTAssertEqual(Inspect.describeLabelSource("name"), "name")
        XCTAssertEqual(Inspect.describeLabelSource("aria-label"), "aria-label")
        XCTAssertEqual(Inspect.describeLabelSource("a-rule-from-2027"), "a-rule-from-2027")

        // The enum spelling and the word spelling agree, which is what lets one
        // sheet draw both without a branch in it.
        for source in [LabelSource.text, .value, .ariaLabel, .alt, .placeholder, .title, .none] {
            XCTAssertEqual(Inspect.describeLabelSource(source),
                           Inspect.describeLabelSource(source.rawValue))
        }
    }

    /**
     * Every word the host is known to send is one this build can print.
     *
     * A list rather than an enum, deliberately — see `MachineBrowserWire.labelSources`.
     * This is the reminder of what has been seen, not a gate on what is accepted:
     * the only one that is treated specially is `none`, which is the absence of a
     * label's source rather than one of them.
     */
    func testEveryKnownLabelSourceSurvivesTheSheet() {
        for word in MachineBrowserWire.labelSources where word != "none" {
            XCTAssertEqual(Inspect.describeLabelSource(word), word)
        }
        XCTAssertTrue(MachineBrowserWire.labelSources.contains("name"))
        XCTAssertTrue(MachineBrowserWire.labelSources.contains("label"))
    }
}
