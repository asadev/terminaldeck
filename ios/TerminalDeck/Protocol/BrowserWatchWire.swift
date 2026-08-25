/**
 * Watching — and driving — the machine's browser: the frame that arrives, the
 * surfaces that can be watched, and the input that goes back.
 *
 * A port of the `browser.*` live-view family from `src/main/remote/protocol.ts`
 * and of the coordinate math in `pwa/src/browser-view.ts`. A `browser.frame` is
 * a JPEG of a web page the machine is holding; `WatchView` turns it back into
 * something a finger can act on, and every tap becomes a `browser.input` aimed
 * at the frame it was measured against.
 *
 * ## The four rules a viewer cannot get wrong silently (from the PWA)
 *
 *  1. Ack from the paint callback, not on receipt — the host holds one un-acked
 *     frame per watcher, so acking early asks for frames faster than the phone
 *     can draw them.
 *  2. The page lives on the server, so the surface never scrolls itself — a
 *     swipe is a `browser.input` wheel, an act the server performs.
 *  3. Coordinates are image pixels of a *named* frame (`seq`), so a scroll
 *     landing mid-gesture cannot desync the mapping.
 *  4. A masked frame is a curtain, never pixels — `data` is empty and the viewer
 *     draws its own lock card.
 *
 * The pure parts — the width negotiation, the css→image transform, the paste
 * cleaning — live here so they can be tested without a live cast; `WatchView`
 * owns the canvas, the paint/ack loop and the gestures.
 */

import Foundation

/// The working jpeg quality, sent unless a caller asks for another. Matches the
/// PWA's `DEFAULT_WATCH_QUALITY`.
let defaultWatchQuality = 50

/// The sentence under the lock card when the host sent no prompt of its own.
let defaultCurtainPrompt = "The person is entering something private."

/// What a surface says instead of sitting dead when it may not be shown.
let watchUnavailableText = "This device may not watch this window."

/**
 * One screencast frame, host→client.
 *
 * `data` is a base64 JPEG and the only large field; `w`/`h` are its own pixels,
 * `dw`/`dh` the CSS viewport those cover. `masked` is the handover curtain:
 * `data` is empty and the viewer draws its own lock card under `prompt`. `seq`
 * is the frame's name — a gesture is measured against it and acked by it.
 */
struct BrowserFrame: Equatable {
    let window: String
    let seq: Int
    let w: Int
    let h: Int
    let dw: Int
    let dh: Int
    let scale: Double
    let offsetTop: Double
    let pageScale: Double
    let scrollX: Double
    let scrollY: Double
    let masked: Bool
    let prompt: String?
    /// The decoded JPEG bytes, or empty for a masked frame. Decoded at the door
    /// (like `net.data`) so a corrupt base64 is refused here, not handed
    /// half-formed to the image decoder.
    let data: Data
}

/// One watchable surface — a tab in the strip. `window` is `""` for the front
/// tab or a slot name; `live` is whether it is currently being cast.
struct BrowserSurfaceRow: Equatable, Identifiable, Hashable {
    let window: String
    let url: String
    let title: String
    let live: Bool

    var id: String { window }
}

/**
 * Who holds the handover on one window. Host→client.
 *
 * The answer to the half of Asad's sentence the cast could not give: *"Claude
 * can ask for the input to put password and put email and then he can
 * continue."* A `browser.handover` is the agent saying *I need a person for this
 * one*, and until this frame existed the only thing it sent a phone was the
 * opposite of an invitation — the cast curtained, `masked: true` with the
 * agent's sentence and no pixels, and input refused at the source. The one
 * surface that could answer was the only one told it may not.
 *
 * Two roads carry the same sentence. `BrowserFrame.prompt` under a curtain says
 * *somebody is entering something private here*, which is also true of a page
 * with a password box on it that nobody has been asked about. This frame is the
 * question itself, and `asking` is the field that separates them.
 *
 * `mine` is the only per-connection field: the same state is true for one
 * recipient and false for the others, because *whether I may type* is not a
 * property of the page. It is also what makes the pixels come back — a host that
 * has granted the baton to this connection stops curtaining **its** frames, so
 * the canvas needs no change at all to show them.
 */
struct BrowserHandoverState: Equatable {
    /**
     * Present when this answers a `browser.handover.take` or `.done` of ours,
     * absent when it is the unsolicited push every watcher of that window gets.
     *
     * Not matched to resolve anything — like `browser.surfaces.rows`, the state
     * is the whole truth either way, and with `taken` on the frame there is
     * nothing left that has to know which of the two roads it came by. Kept
     * because a frame that says how it arrived is worth being able to read.
     */
    let rid: String?
    let window: String
    /// Whether a handover is outstanding on that window at all.
    let asking: Bool
    /// The agent's own sentence, already sanitised by the driver — the thing the
    /// person has to read to know what to type.
    let prompt: String
    /// Whether **this** connection is the one holding it.
    let mine: Bool
    /**
     * Whether **anybody** holds it, whoever they are.
     *
     * The field that deletes a derivation. `asking && !mine` used to be two
     * situations the frame could not separate — *nobody has taken this* and
     * *another device did* — and this end inferred the difference from the shape
     * of the pushes. It worked and it was still wrong to ship: reading it
     * backwards is either a claim button that deadlocks a waiting agent or two
     * people typing into one password field. The host knows the answer, so the
     * host says it.
     */
    let taken: Bool
}

/// One gesture aimed at a watched surface. Exactly one kind, because each is
/// dispatched down a different CDP method and a frame naming two could not have
/// been one gesture. Mirrors the mouse/key/touch/paste split of `browser.input`.
enum BrowserInput: Equatable {
    case mouse(Mouse)
    case key(Key)
    case touch(Touch)
    case paste(String)

    struct Mouse: Equatable {
        enum Kind: String { case down, up, move, wheel }
        enum Button: String { case left, right, middle, none }
        let type: Kind
        let x: Int
        let y: Int
        let button: Button?
        let clicks: Int?
        let dx: Int?
        let dy: Int?
    }
    struct Key: Equatable {
        enum Kind: String { case down, up, char }
        let type: Kind
        let key: String?
        let code: String?
        let text: String?
        let mods: Int
    }
    struct Touch: Equatable {
        enum Kind: String { case start, move, end, cancel }
        let type: Kind
        let points: [CGPoint]
    }
}

// MARK: - Pure geometry and cleaning (ports of `pwa/src/browser-view.ts`)

enum WatchMath {
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return low }
        return Swift.min(high, Swift.max(low, value))
    }

    /// The width this viewer asks the host to render at, in device pixels: the
    /// point width times the screen scale, clamped into the host's range. Asking
    /// for more is bytes no display can resolve; fewer is a blurry page.
    static func watchWidth(pointWidth: CGFloat, scale: CGFloat) -> Int {
        let ratio = scale.isFinite && scale > 0 ? Double(scale) : 1
        let px = (Double(pointWidth) * ratio).rounded()
        return Int(clamp(px, Double(Wire.minWatchWidth), Double(Wire.maxWatchWidth)))
    }

    /// The jpeg quality this viewer asks for, clamped into the host's range.
    static func watchQuality(_ quality: Int) -> Int {
        Int(clamp(Double(quality), Double(Wire.minWatchQuality), Double(Wire.maxWatchQuality)))
    }

    /**
     * Where a frame is actually drawn inside a view of `size` — the rectangle a
     * gesture is measured against.
     *
     * ## This function exists because the old mapping was wrong, and wrong in the
     * way that makes a live page feel like a video
     *
     * `imageCoords` used to take the view's own width and height and map
     * `x = px * (w / viewW)` on each axis independently, on the stated grounds
     * that *"the frame fills the view's box on both axes"*. It does not. The
     * canvas draws with `.resizeAspect`, so a frame whose aspect ratio differs
     * from the view's is **letterboxed**, and every gesture was offset by the
     * bars.
     *
     * The size of the error is not a rounding matter. A desktop page is around
     * 1280×800 and a phone in portrait is around 393×760 points: the picture is
     * fitted to the width and comes out about 246 points tall, centred, with
     * roughly 257 points of black above it and the same below. A tap at the very
     * top of the page — where a site's own navigation lives — was measured
     * against a 760-point box and reported as a third of the way down the
     * document. Nothing landed where it was aimed, and a tap on the black bars
     * was clamped to the page's edge and sent anyway, so touching nothing still
     * clicked something.
     *
     * ## Anchored to the top, not centred
     *
     * `.resizeAspect` centres, and centring is what made the page read as a film
     * strip floating in a black frame. The page sits against the top edge, under
     * the navigation bar, with whatever is left over below it — which is also
     * where the bar with the address on it is, so the two are adjacent rather
     * than separated by a band of black.
     *
     * Both returned axes are in **view points**. `zoom` is the viewer's own
     * magnification of the received picture and is not a page zoom: see
     * `WatchSurfaceUIView`.
     */
    static func fit(frameW: Int, frameH: Int, in size: CGSize) -> CGRect {
        guard frameW > 0, frameH > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = Swift.min(size.width / CGFloat(frameW), size.height / CGFloat(frameH))
        let width = CGFloat(frameW) * scale
        let height = CGFloat(frameH) * scale
        return CGRect(x: ((size.width - width) / 2).rounded(), y: 0, width: width, height: height)
    }

    /**
     * Hold a magnified page inside the view: never a gap at an edge the page is
     * big enough to cover, and never dragged off the screen.
     *
     * An axis the page does not fill is not clamped but *placed* — centred
     * across, pinned to the top down — so letting go of a pinch cannot leave the
     * picture parked in a corner. An axis it does fill is clamped so that the
     * near edge cannot come inside the view, which is what a scroll view does
     * and what a finger expects.
     */
    static func clampDrawn(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        var out = rect
        if rect.width <= size.width {
            out.origin.x = ((size.width - rect.width) / 2).rounded()
        } else {
            out.origin.x = Swift.min(0, Swift.max(size.width - rect.width, rect.minX))
        }
        if rect.height <= size.height {
            out.origin.y = 0
        } else {
            out.origin.y = Swift.min(0, Swift.max(size.height - rect.height, rect.minY))
        }
        return out
    }

    /**
     * A point at view coordinates, in image pixels of the frame drawn into
     * `drawn`.
     *
     * `drawn` is where the picture is — `fit` above, magnified and panned — so
     * the mapping is a ratio inside that rectangle and nothing else. It is the
     * exact transform the host inverts under this frame's `seq`: image pixels are
     * what `browser.input` carries, and `browser-watch.ts` divides them by the
     * frame's own `scale` to reach the CSS viewport.
     *
     * Clamped into the image, because a **drag** that leaves the picture still
     * has to name a pixel on the page — a selection dragged past the edge is a
     * selection to the edge. A **tap** outside the picture is a different thing
     * and is refused before it gets here: see `WatchSurfaceUIView.page(at:)`.
     * Rounded, because a fractional pixel is not a place a click can land.
     */
    static func imageCoords(frameW: Int, frameH: Int, drawn: CGRect,
                            px: CGFloat, py: CGFloat) -> (x: Int, y: Int) {
        let sx = drawn.width > 0 ? Double(frameW) / Double(drawn.width) : 0
        let sy = drawn.height > 0 ? Double(frameH) / Double(drawn.height) : 0
        let x = clamp((Double(px - drawn.minX) * sx).rounded(), 0, Double(frameW))
        let y = clamp((Double(py - drawn.minY) * sy).rounded(), 0, Double(frameH))
        return (Int(x), Int(y))
    }

    /**
     * Strip the control bytes a page's field would choke on and bound the result
     * the way a paste is bounded on the wire.
     *
     * The host refuses an over-cap paste and one into a secret field; this is the
     * cheap client-side pass that keeps an ordinary paste from being refused for
     * a reason a person cannot see. C0 controls and DEL go, tab and newline stay,
     * and the cut is on a scalar boundary measured in UTF-8 bytes so a multi-byte
     * character is never split at the cap. Mirrors `cleanPaste` in the PWA.
     */
    static func cleanPaste(_ text: String, maxBytes: Int = Wire.maxInputBytes) -> String {
        var bytes = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let code = scalar.value
            if (code < 0x20 && code != 0x09 && code != 0x0a) || code == 0x7f { continue }
            let size = utf8Size(scalar)
            if bytes + size > maxBytes { break }
            bytes += size
            out.append(scalar)
        }
        return String(out)
    }

    private static func utf8Size(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0 ..< 0x80: return 1
        case 0x80 ..< 0x800: return 2
        case 0x800 ..< 0x1_0000: return 3
        default: return 4
        }
    }
}

// MARK: - Narrowing

extension WireCodec {
    /**
     * One `browser.frame`, or nil.
     *
     * The geometry is required and `data` is decoded here — a masked frame
     * carries the empty string, which decodes to empty and is fine; a non-masked
     * frame whose `data` is not valid base64 is refused rather than handed
     * half-decoded to the image decoder, exactly the rule `net.data` keeps.
     *
     * ## `masked` is read the opposite way round from a grant, and on purpose
     *
     * Every other hardened boolean on this wire uses `literalTrue`, because the
     * dangerous mistake there is **believing a permission that was not given**.
     * The curtain is the mirror of that: `masked` is a protection, `true` is the
     * protection being *on*, and the dangerous mistake is failing to believe it.
     * `literalTrue` here would be strictly worse than the lenient spelling it
     * replaced — it reads `{"masked":1}` as *not curtained*, and a frame that is
     * not curtained is one `WatchSurfaceUIView` dispatches taps and keystrokes
     * against (`guard let frame = lastFrame, !frame.masked`). A page the host
     * withheld the pixels of would have taken input.
     *
     * So the reading is: **curtained unless the host said, in a real boolean,
     * that it is not.** Absent stays uncurtained, which is the ordinary frame
     * and must not change; anything present that is not literally `false` —
     * `1`, a string, a null — draws the lock card. The same shape
     * `CopilotWire`'s `linked` uses, and for the same reason it gives.
     *
     * ## No pixels is a curtain, whatever the flag says
     *
     * The far end enforces the pairing from its side — *"a masked browser.frame
     * must carry no data"*, refused outright if it does, because *"a masked
     * frame with pixels in it is a redaction that leaked."* This is that
     * invariant read from the other end: an **empty** frame is treated as
     * curtained even if nothing said so. It closes the one gap the flag alone
     * cannot, which is a frame that claims to be ordinary and carries nothing to
     * draw: before this, that produced a `masked: false` frame with no pixels,
     * and every gesture guard is written against `masked` rather than against
     * the bytes — so touches went to a page nobody could see. Drawing the lock
     * card over it is also the more honest picture: there is genuinely nothing
     * there.
     */
    static func browserFrame(_ object: [String: Any]) -> BrowserFrame? {
        guard let window = string(object["window"]),
              let seq = whole(object["seq"]),
              let w = whole(object["w"]), let h = whole(object["h"]),
              let dw = whole(object["dw"]), let dh = whole(object["dh"]) else { return nil }
        let claimsMasked = object["masked"] != nil && !literalFalse(object["masked"])
        let rawData = string(object["data"]) ?? ""
        let masked = claimsMasked || rawData.isEmpty
        let bytes: Data
        if masked {
            bytes = Data()
        } else if let decoded = strictBase64(rawData) {
            bytes = decoded
        } else {
            return nil
        }
        return BrowserFrame(
            window: window,
            seq: seq,
            w: w, h: h, dw: dw, dh: dh,
            scale: number(object["scale"]) ?? 1,
            offsetTop: number(object["offsetTop"]) ?? 0,
            pageScale: number(object["pageScale"]) ?? 1,
            scrollX: number(object["scrollX"]) ?? 0,
            scrollY: number(object["scrollY"]) ?? 0,
            masked: masked,
            prompt: string(object["prompt"]).map { String($0.prefix(Wire.maxWatchPromptLength)) },
            data: bytes)
    }

    /// The tab strip off a `browser.surfaces.rows`. A malformed row is dropped
    /// and the list is trimmed to the reported cap.
    static func browserSurfaces(_ value: Any?) -> [BrowserSurfaceRow] {
        guard let rows = value as? [Any] else { return [] }
        var out: [BrowserSurfaceRow] = []
        for row in rows {
            if out.count >= Wire.maxSurfacesReported { break }
            guard let entry = row as? [String: Any],
                  let window = string(entry["window"]) else { continue }
            out.append(BrowserSurfaceRow(
                window: window,
                url: displayLine(entry["url"]) ?? "",
                title: displayLine(entry["title"]) ?? "",
                live: entry["live"] as? Bool == true))
        }
        return out
    }

    /**
     * One `browser.handover.state`, or nil.
     *
     * Only the window is required, and it may be the empty string — that is the
     * front tab, the surface most pages a phone opens on a server actually land
     * on. Everything else is read the safe way round: a missing or unusable
     * `asking` reads as *nothing is being asked*, and a missing `mine` as *not
     * mine*, because both of those errors leave a person looking at a page they
     * are told they may not type into, and the errors the other way round put a
     * claim button under a question nobody asked.
     *
     * The prompt crosses the same ceiling the curtain sentence on a
     * `browser.frame` crosses under, and by the same call — it is the same
     * sentence arriving by the other road.
     */
    static func browserHandover(_ object: [String: Any]) -> BrowserHandoverState? {
        guard let window = string(object["window"]) else { return nil }
        return BrowserHandoverState(
            rid: string(object["rid"]),
            window: window,
            // `literalTrue`, not `as? Bool == true`, and it is the same reader
            // the copilot grants already use. `JSONSerialization` hands back an
            // `NSNumber` for every JSON number and Foundation bridges
            // `NSNumber(1)` to `Bool` through the ObjC bridge, so the lenient
            // spelling reads `{"mine":1}` as *this device may type into that
            // login*. Measured — the parity test below caught it on its first
            // run. It is also the exact parity of the far end, which writes
            // every field of this frame as `parsed.x === true`.
            asking: literalTrue(object["asking"]),
            prompt: String((string(object["prompt"]) ?? "").prefix(Wire.maxWatchPromptLength)),
            mine: literalTrue(object["mine"]),
            taken: literalTrue(object["taken"]))
    }

    /// A finite JSON number, or nil. Bools bridge to `NSNumber`, so `true` must
    /// not read as 1.0 in a scale field.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !(value is NSNull),
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    /// Build the flat `browser.input` dictionary. Exactly one of the four kinds
    /// is written, because each rides a different CDP method on the far side and
    /// a frame naming two could not have been one gesture.
    static func encodeBrowserInput(window: String, seq: Int, input: BrowserInput) -> [String: Any] {
        var object: [String: Any] = ["t": "browser.input", "window": window, "seq": seq]
        switch input {
        case let .mouse(m):
            var mouse: [String: Any] = ["type": m.type.rawValue, "x": m.x, "y": m.y]
            if let button = m.button { mouse["button"] = button.rawValue }
            if let clicks = m.clicks { mouse["clicks"] = clicks }
            if let dx = m.dx { mouse["dx"] = dx }
            if let dy = m.dy { mouse["dy"] = dy }
            object["mouse"] = mouse
        case let .key(k):
            var key: [String: Any] = ["type": k.type.rawValue, "mods": k.mods]
            if let name = k.key { key["key"] = name }
            if let code = k.code { key["code"] = code }
            if let text = k.text { key["text"] = text }
            object["key"] = key
        case let .touch(t):
            let points = t.points.prefix(Wire.maxTouchPoints).map { ["x": Int($0.x), "y": Int($0.y)] }
            object["touch"] = ["type": t.type.rawValue, "points": points]
        case let .paste(text):
            object["paste"] = text
        }
        return object
    }
}
