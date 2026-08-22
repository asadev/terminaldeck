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

/// How far a touch may drift and still be a tap rather than a scroll (points).
let tapSlopPoints: CGFloat = 8

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
     * A point at view coordinates, in image pixels of the frame it was drawn
     * against.
     *
     * The frame fills the view's box on both axes, so the mapping is the box
     * ratio on each axis independently — `x = px * (w / viewW)` — which is the
     * exact transform the host inverts under this frame's `seq`. Clamped into the
     * image so a drag that leaves the view still names a pixel on the page, and
     * rounded because a fractional pixel is not a place a click can land.
     */
    static func imageCoords(frameW: Int, frameH: Int, viewW: CGFloat, viewH: CGFloat,
                            px: CGFloat, py: CGFloat) -> (x: Int, y: Int) {
        let sx = viewW > 0 ? Double(frameW) / Double(viewW) : 0
        let sy = viewH > 0 ? Double(frameH) / Double(viewH) : 0
        let x = clamp((Double(px) * sx).rounded(), 0, Double(frameW))
        let y = clamp((Double(py) * sy).rounded(), 0, Double(frameH))
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
     */
    static func browserFrame(_ object: [String: Any]) -> BrowserFrame? {
        guard let window = string(object["window"]),
              let seq = whole(object["seq"]),
              let w = whole(object["w"]), let h = whole(object["h"]),
              let dw = whole(object["dw"]), let dh = whole(object["dh"]) else { return nil }
        let masked = object["masked"] as? Bool == true
        let rawData = string(object["data"]) ?? ""
        let bytes: Data
        if masked || rawData.isEmpty {
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
