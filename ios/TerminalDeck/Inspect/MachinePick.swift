/**
 * Pointing at one thing inside a window **on the machine**, from a phone that is
 * only watching pixels.
 *
 * ## What is different about this half
 *
 * A page open on this phone is a real `WKWebView` with a real document in it:
 * `InspectScript` runs inside it, catches the touch before the page sees it, and
 * hands back the element's whole ancestor path. Nothing crosses a wire.
 *
 * A window on the machine has none of that here. What arrives is a picture, frame
 * by frame, and a tap on it is a **point** — so the point is what goes over, as
 * `browser.window.pick`, and the machine's own browser answers with the same
 * facts its desktop capture popup shows. That is `browser.window.picked`, and one
 * `InspectedElement` is what both roads end at, because *"all of them should be
 * identical"* is a sentence about the screen rather than about the mechanism.
 *
 * ## Why a point has to become *document* coordinates before it leaves
 *
 * A tap lands on a picture that was taken a moment ago. Between that frame being
 * drawn and the finger arriving, the page can scroll — a lazy image loading, a
 * sticky header collapsing, somebody's own scroll gesture — and a *viewport*
 * point measured against the older picture then names whatever has moved into
 * that spot since. Document coordinates are the one space that survives the trip:
 * the host converts back using the page's **own live scroll**, and when the point
 * turns out to be off screen entirely it says so in a sentence rather than
 * guessing at an element nobody pointed at.
 *
 * `documentPoint` below is that conversion, and it is deliberately written from
 * the frame's own numbers rather than from anything about the view: the same
 * `scale`, `pageScale`, `scrollX` and `scrollY` the host stamped on the frame,
 * inverted the way `BrowserWatch.mapPoint` in `src/main/browser-watch.ts` applies
 * them. Both directions of one mapping, so a tap that drives the page and a tap
 * that describes it cannot land on two different elements.
 *
 * ## Why the hand-off is a static rather than a call
 *
 * The canvas is a `UIView` inside a `UIViewRepresentable` and the screen above it
 * is a SwiftUI value type; there is no reference from one to the other in either
 * direction. `WatchSurface` already solves the same problem the same way — a
 * static plus a notification for *put the keyboard away*, a static notification
 * for *I am holding the keyboard*. This is that seam for *a tap is a question,
 * not a click*, and it is written here rather than inside the canvas so the rule
 * has one place to be stated and the canvas keeps one line about it.
 *
 * ### The canvas has to call `take` for any of this to work
 *
 * Inspect mode is armed from `MachineWindowView` and the tap is the canvas's, so
 * `WatchSurfaceUIView.onTap` has to offer the touch here **before** it dispatches
 * the mouse triple. One line, at the top of that method, after it has already
 * mapped the touch:
 *
 *     guard let at = page(at: gesture.location(in: self)) else { return }
 *     if let frame = lastFrame,
 *        MachinePick.take(window: target, frame: frame, imageX: at.x, imageY: at.y) { return }
 *
 * `page(at:)` is reused rather than repeated: it is the mapping that already
 * refuses a touch on the letterbox — *"a finger resting on nothing pressed
 * whatever was at the top of the document"* — and inspecting has exactly the same
 * need. A second mapping written here would be a second thing to get wrong, and
 * the two would be wrong differently.
 *
 * **Until that line is in `WatchView.swift`, Inspect on a machine window turns on
 * and taps still drive the page.** Everything else is here — the ask, the answer,
 * the sheet, Wider, the sentences — and none of it is reachable without it. It is
 * written down at this length because it is one line in a file this work did not
 * own, and a one-line dependency that is not written down is one that gets lost.
 */

import Foundation

@MainActor
enum MachinePick {

    /// The window whose canvas is currently answering taps with a question
    /// instead of a click, or nil. One at a time, because there is one canvas —
    /// see `WatchStage`, which makes that a rule rather than an observation.
    private(set) static var armedWindow: String?

    /// What to do with a point once it has become document coordinates. Held
    /// beside `armedWindow` and cleared with it, so a stale closure from a screen
    /// that has been left cannot be called.
    private static var deliver: ((Double, Double) -> Void)?

    /**
     * The last point taken, in document coordinates — what Wider re-asks about.
     *
     * Held here rather than on the screen because it belongs to the tap, and the
     * tap arrives at this seam. Wider and Narrower are not new questions: they
     * are **the same point, asked again with a different `up`**, which is why the
     * host takes `up` as a field on the pick rather than as a verb of its own. A
     * screen that had re-derived the point from the sheet would have nothing to
     * derive it from — the answer carries the element's rectangle, not the place
     * a finger landed.
     *
     * Cleared by `disarm`, so leaving inspect mode and coming back cannot walk up
     * from where somebody tapped ten minutes ago on a page that has since moved.
     */
    private(set) static var lastPoint: (x: Double, y: Double)?

    /// Whether taps on this window's picture are being read as questions.
    static func isArmed(window: String) -> Bool { armedWindow == window }

    /**
     * Turn taps on one window's picture into questions about the page.
     *
     * Replacing an arm rather than refusing one is deliberate: the screens that
     * mount a canvas can be swapped without either of them being torn down in a
     * predictable order, and *the last screen to say so wins* is the same rule
     * `WatchSurfaceUIView.owner` already applies to the frame sink.
     */
    static func arm(window: String, then: @escaping (Double, Double) -> Void) {
        armedWindow = window
        deliver = then
    }

    /// Back to ordinary browsing. Called when Inspect is switched off, and when
    /// the screen goes away — a canvas left armed behind a dismissed view would
    /// eat the first tap on whatever mounts next.
    static func disarm() {
        armedWindow = nil
        deliver = nil
        lastPoint = nil
    }

    /**
     * The canvas offering a touch. True when it was taken as a pick, which is the
     * canvas's signal to send **nothing** — no move, no down, no up.
     *
     * That silence is the whole behaviour: while Inspect is on, a tap describes
     * the thing under it instead of pressing it, exactly as it already does on
     * the page this phone holds itself, where `InspectScript` cancels the click.
     * A tap that both described a link and followed it would navigate away from
     * the element it had just described.
     *
     * A masked frame is refused here as well as at the source. It carries no
     * pixels — somebody is typing a password on the far side — so there is
     * nothing on this screen to have pointed at, and asking the machine what is
     * at a point on a page it is deliberately curtaining is the one question this
     * feature must never send.
     */
    @discardableResult
    static func take(window: String, frame: BrowserFrame, imageX: Int, imageY: Int) -> Bool {
        guard armedWindow == window, let deliver, !frame.masked else { return false }
        let point = documentPoint(frame: frame, imageX: imageX, imageY: imageY)
        lastPoint = point
        deliver(point.x, point.y)
        return true
    }

    /**
     * An image pixel on the frame → a point on the **document**.
     *
     * The inverse of `BrowserWatch.mapPoint` in `src/main/browser-watch.ts`,
     * which turns the image pixels a `browser.input` carries into CSS viewport
     * pixels with `(x / scale) / pageScale`. This is that undone and then the
     * frame's scroll added, which is the step `mapPoint` deliberately does **not**
     * take: CDP mouse coordinates are viewport ones, so a click never wanted the
     * scroll back, and a pick always does.
     *
     * `scale` is the frame's own — `w / dw`, the picture's pixels over the CSS
     * viewport they cover — so a host that renegotiated the render width mid-cast
     * is followed without anything here being told. Both divisors fall back to 1
     * when the frame reports a nonsense value: a frame with `scale: 0` is a frame
     * whose geometry could not be read, and dividing by it would send a point at
     * infinity, which the host's parser refuses as *a pick without a point on the
     * page*. One is the honest guess — the picture at its own size — and it puts
     * the tap somewhere on the page rather than nowhere.
     *
     * Rounded, because the far side's hit test wants a point and not a
     * measurement, and because a whole number is what a person reading a log of
     * these frames can compare against a rectangle in the answer.
     */
    nonisolated static func documentPoint(frame: BrowserFrame,
                                          imageX: Int, imageY: Int) -> (x: Double, y: Double) {
        let scale = frame.scale > 0 ? frame.scale : 1
        let pageScale = frame.pageScale > 0 ? frame.pageScale : 1
        let cssX = (Double(imageX) / scale) / pageScale
        let cssY = (Double(imageY) / scale) / pageScale
        return ((cssX + frame.scrollX).rounded(), (cssY + frame.scrollY).rounded())
    }

    /**
     * The step Wider takes, already clamped.
     *
     * `+1` towards the document and `-1` back towards the tap, held inside
     * `0...MachineBrowserWire.maxPickUp`. The ceiling is not politeness: the host
     * checks that range in its **parser**, and `server.ts` answers a parse failure
     * by closing the socket — so a Wider pressed once past the top of a very deep
     * document would drop the terminals and the cast along with it. The screen
     * greys the control at the end of the chain, the codec clamps on the last
     * line before the wire, and this is the arithmetic in between; all three,
     * because the cost of the one that gets missed is somebody's whole session.
     */
    nonisolated static func step(from depth: Int, by delta: Int) -> Int {
        min(max(0, depth + delta), MachineBrowserWire.maxPickUp)
    }
}
