/**
 * One element somebody pointed at — **whichever browser they pointed at it in**.
 *
 * ## The complaint this type exists to answer
 *
 * > *"the bottom and here we have flow, screenshot, and all of this stuff. But in
 * > the page, if I click on something, I don't have something to, some option to
 * > specifically inspect one piece. Here I also don't have. And then in the own,
 * > in the own this phone page, we have it, but we don't have the rest of the
 * > options here. We have… some of one of them, but we don't have the rest. So
 * > everything should, all of them should be identical, and all of them should
 * > have all the options. Should not be that much of difference in all of them."*
 *
 * There are two places an element can be pointed at from this phone and until
 * this type there were two different things being pointed at:
 *
 *  - **a page on this phone** — a real `WKWebView` over a tunnel, with a real
 *    DOM. `InspectScript` runs inside it, a tap is caught before the page sees
 *    it, and `Inspect.parseCapture` turns the reported ancestor path into an
 *    `ElementCapture`. All of it happens on this device.
 *  - **a window on the machine** — a picture arriving frame by frame. There is
 *    no DOM here to run anything inside of. The tap is a point, the point goes
 *    over the wire as `browser.window.pick`, and the machine's own browser
 *    answers `browser.window.picked` with the same facts its desktop capture
 *    popup shows.
 *
 * Two sources, two entirely different mechanisms — and **one sheet**, because
 * the thing he counted was the screen, not the mechanism. Answering *"all of
 * them should be identical"* with two sheets that merely look alike is the shape
 * of defect this whole round is undoing: they drift, and the drift is invisible
 * in a screenshot of either one on its own.
 *
 * So `InspectSheet` takes this, and both roads fill it in.
 *
 * ## Why `labelSource` is a plain string
 *
 * It is `PICK_LABEL_SOURCES` in `src/main/remote/protocol.ts`, which is
 * `selector.ts`'s `LabelSource` **plus two words only a form field can produce**
 * — `name`, and `label` for a `<label for="…">` sitting elsewhere in the
 * document. A Swift enum over the phone's own seven cases would fail to decode
 * exactly those two, and the wire's own rule is explicit about what to do with a
 * word this build does not know: *"A client must draw an unfamiliar word as it
 * stands rather than refuse the frame."* That list grows the day the label rule
 * learns a new fallback, and a sheet that went blank on an element it could have
 * described perfectly is a worse answer than one that prints an unfamiliar word.
 *
 * `ElementCapture.labelSource` stays the enum it was: that side computes the
 * value here on the phone, from a closed set it owns, and nothing crosses a wire
 * to reach it. The conversion is one `rawValue` in the initialiser below.
 *
 * ## The context line is computed, never carried
 *
 * `context` is what gets typed into an agent's terminal, and it is a `var` on
 * this type rather than a field either source fills in. That is the whole
 * guarantee: there is one composer — `Inspect.composeAgentContext` — so a
 * machine window and a page on this phone cannot come to two different opinions
 * about how the same element should be described to an agent. A stored string
 * would let them.
 */

import Foundation

struct InspectedElement: Equatable {

    /// `button`, `div`, `input`. Empty where the tag could not safely be named —
    /// the sheet draws the noun *element* rather than an empty chip.
    let tag: String

    /// The CSS selector, worked out by whichever side owns the DOM. Never
    /// recomputed here: two selector rules over one element is the fourth
    /// opinion `browser.window.picked`'s own comment refuses to allow.
    let selector: String

    /// The best human-readable handle for it, already sanitised and clamped.
    let label: String

    /// Where that handle came from — one of `PICK_LABEL_SOURCES`, drawn as it
    /// stands when this build does not know the word. See the header.
    let labelSource: String

    /// The page's address **as the app knows it**, never as the page claims it.
    /// Both sources hold that line: the phone reads it off its own `WKWebView`
    /// and the host sends the window row's URL rather than the document's.
    let url: String

    /// How many ancestors up from the element the point actually hit. Zero is
    /// the tap itself, and it is what greys Narrower.
    let depth: Int

    /// How many further ancestors exist above this one. Zero is the top of the
    /// document, and it is what greys Wider. Named for the wire's own field;
    /// the phone's inspector calls the same number `ancestors`.
    let maxUp: Int

    /**
     * Where it sits on the page, in the page's own coordinates — or nil.
     *
     * Only a machine window has one. The page on this phone highlights the
     * element **inside its own document**, from `InspectScript`, so nothing up
     * here ever needed to know where the box was.
     *
     * Kept rather than dropped at the door, and that is a decision rather than
     * an oversight: the host measures this so a viewer can draw an outline over
     * the *next* frame it receives by subtracting that frame's scroll, and
     * throwing it away in the codec would make the day somebody draws that
     * outline a wire change instead of a drawing change. Nothing draws it today
     * — the outline belongs on the cast canvas, which is `WatchView`'s.
     */
    let rect: PickedRect?

    init(tag: String, selector: String, label: String, labelSource: String,
         url: String, depth: Int, maxUp: Int, rect: PickedRect? = nil) {
        self.tag = tag
        self.selector = selector
        self.label = label
        self.labelSource = labelSource
        self.url = url
        self.depth = depth
        self.maxUp = maxUp
        self.rect = rect
    }

    /**
     * The same element, out of the phone's own inspector.
     *
     * An adapter rather than a second sheet, which is the whole point of the
     * type. `ancestors` and `maxUp` are the same number under two names — how
     * much further up Wider can go — and the two names exist because one was
     * chosen on this phone before the wire had a word for it and the other is
     * the wire's. This is the one place they meet, so this is where the rename
     * happens rather than in six call sites.
     */
    init(_ capture: ElementCapture) {
        self.init(tag: capture.tag,
                  selector: capture.selector,
                  label: capture.label,
                  labelSource: capture.labelSource.rawValue,
                  url: capture.url,
                  depth: capture.depth,
                  maxUp: capture.ancestors,
                  rect: nil)
    }

    /**
     * The one line an agent receives about this element.
     *
     * Computed, and computed by the composer both clients and the desktop share.
     * `ElementCaptureTests` pins that composer against `CapturePanel.tsx`
     * character for character, so anything filling this type in gets that
     * agreement for free — and cannot opt out of it, which a stored field would
     * have allowed.
     */
    var context: String {
        Inspect.composeAgentContext(url: url, selector: selector, tag: tag,
                                    label: label, labelSource: labelSource)
    }

    /// Whether Wider has anywhere left to go. The sheet greys the control on
    /// this rather than on a guess, because the host counted the chain in the
    /// same pass that found the element — see `PICK_SCRIPT`.
    var canGoWider: Bool { maxUp > 0 }

    /// Whether Narrower does. Zero levels up is the element that was tapped, and
    /// there is nothing below it to come back to.
    var canGoNarrower: Bool { depth > 0 }

    /// *2 levels up*, or nothing at all at the tap itself. One phrasing, drawn
    /// by the sheet for both kinds of window.
    var depthLine: String? {
        guard depth > 0 else { return nil }
        return depth == 1 ? "1 level up" : "\(depth) levels up"
    }
}

/**
 * An element the machine described, and which of its windows it is on.
 *
 * The window travels with the element because this phone's stack can hold more
 * than one browser screen and `HostLink` holds one answer. A screen draws this
 * only when the window is its own; an answer about a window somebody has already
 * left is dropped rather than drawn, which is the same rule the folder picker
 * applies to a listing for a folder it has walked away from.
 */
struct MachinePickResult: Equatable {
    let window: String
    let element: InspectedElement
}
