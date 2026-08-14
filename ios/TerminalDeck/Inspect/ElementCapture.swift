/**
 * Turning a tapped element in the tunnelled page into something an agent can act on:
 * a CSS selector, a label, and one line of context.
 *
 * A faithful port of `src/main/selector.ts` plus `oneLine`/`composeSend` from
 * `src/renderer/browser/CapturePanel.tsx`. The desktop's copies are the normative
 * ones; every constant and every branch here is transcribed from them rather than
 * chosen, and if the two ever disagree the TypeScript is right and this is a bug.
 *
 * ## Why this is Swift and not more JavaScript
 *
 * The same split the desktop draws, for the same reason. The page inside the
 * `WKWebView` is somebody's dev server reached over a tunnel — it is not our code
 * — so the injected script only *reports facts* about the tapped element (tag,
 * id, whether that id is unique, sibling position). Every judgement — which
 * selector wins, what may reach a terminal, what a password field is allowed to
 * say — happens here, where it is tested against hostile input rather than hoped
 * about. `WKScriptMessageHandler` is reachable from the page's own scripts, so
 * "the payload came from our script" is not a fact this side may assume.
 *
 * ## The one-line rule, and why it is copied character for character
 *
 * The composed string is typed into a PTY running a coding CLI. A newline in it
 * **submits the prompt early** — the agent would receive the first line as the
 * whole instruction — and an ESC repaints the terminal it lands in. So controls
 * are removed rather than escaped, on both sides of the wire, by the same rules.
 * Both phones and the desktop have to hand the agent identical strings, which is
 * why `oneLine` below is a transcription and not an approximation: Swift's
 * `.trimmingCharacters(in: .whitespacesAndNewlines)` is a *different set* from
 * JavaScript's `\s` (it includes U+0085 and excludes U+FEFF), and using it would
 * have made the two clients disagree on inputs nobody would ever have tested.
 */

import Foundation

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * One element on the path from the tapped node up to the document root, as
 * reported by the guest script. Every field is optional except `tag`, because a
 * hostile or merely unusual page may not supply any of it.
 */
struct ElementDescriptor: Equatable {
    /// `localName` — lower-case for HTML, case-preserved for SVG (`clipPath`).
    var tag: String
    var id: String?
    /// Which test-hook attribute matched, e.g. `data-testid`.
    var testAttr: String?
    var testValue: String?
    /// `#id` matches exactly one element in the guest document.
    var idUnique = false
    /// The attribute selector matches exactly one element in the guest document.
    var testUnique = false
    /// 1-based position among siblings of the same element type.
    var nthOfType: Int?
    /// How many siblings of this element type the parent has.
    var ofTypeCount: Int?
}

/// Where a capture's label came from, so the context line can say so.
enum LabelSource: String, Equatable {
    case text
    case value
    case ariaLabel = "aria-label"
    case alt
    case placeholder
    case title
    case none
}

/// A sanitised, ready-to-show capture. Nothing here came straight from the page.
struct ElementCapture: Equatable {
    let selector: String
    let tag: String
    /// Best human-readable handle for the element, already trimmed and clamped.
    let label: String
    let labelSource: LabelSource
    /// The page URL as *this app* knows it — never the page's own claim.
    let url: String
    /// Whitelisted attributes, sanitised. Shown in the sheet, not used in selectors.
    let attributes: [String: String]
    /// The composed single-line context, already flattened. What the agent gets.
    let context: String

    /**
     * How far up the ancestor chain this capture sits from the element that was
     * actually touched, and how much further it could go.
     *
     * Not part of the desktop's shape, and it is here because a fingertip is not
     * a mouse pointer. On the desktop a miss is corrected by moving the mouse a
     * few pixels and clicking again; on a phone the tap lands on whatever wrapper
     * happens to be on top, and there is no second, more precise gesture to
     * offer. So the correction is a control instead — see `InspectSheet`.
     */
    let depth: Int
    let ancestors: Int
}

/* -------------------------------------------------------------------------- */
/* Constants, transcribed from selector.ts                                     */
/* -------------------------------------------------------------------------- */

enum Inspect {

    /**
     * Test-hook attributes in priority order. `data-testid` first because it is
     * what Testing Library and Playwright default to, so it is the one most
     * likely to actually be in the codebase the agent is about to edit.
     */
    static let testIdAttrs = [
        "data-testid",
        "data-test-id",
        "data-test",
        "data-qa",
        "data-cy",
        "data-automation-id",
    ]

    /**
     * Attributes worth carrying across. Deliberately a closed list: the page
     * controls attribute *names* as well as values, and an open-ended copy would
     * let it stuff arbitrary keys into this app's payload and its UI.
     */
    static let captureAttrs = [
        "aria-label",
        "alt",
        "placeholder",
        "title",
        "role",
        "type",
        "name",
        "href",
        "value",
    ]

    /// Longest ancestor path considered. Deep DOMs exist; unbounded ones are attacks.
    static let maxPathDepth = 64
    /// Text is a hint for the agent, not the content of the page.
    static let maxLabelLength = 150
    static let maxIdentLength = 200
    static let maxAttrLength = 300
    static let maxURLLength = 400
    /// One line pasted into a prompt. Long enough for a real selector, short enough to read.
    static let maxContextLength = 1200
    /// Longest instruction the user may type before it is clamped, matching `composeAgentContext`.
    static let maxInstructionLength = 600

    /**
     * How much of an oversized string is worth looking at, as a multiple of the
     * limit. The page decides how long its strings are and this runs on the main
     * actor — which is also this app's UI thread — so the scan is bounded before
     * anything walks it.
     */
    static let scanHeadroom = 32
}

/* -------------------------------------------------------------------------- */
/* Whitespace, exactly as JavaScript defines it                                */
/* -------------------------------------------------------------------------- */

/**
 * `\s` in a JavaScript regular expression, and the set `String.prototype.trim`
 * removes. Written out rather than reached for from Foundation because the two
 * are **not** the same set, and the difference is silent: Swift's
 * `.whitespacesAndNewlines` contains U+0085 (NEL) which JavaScript's does not,
 * and lacks U+FEFF which JavaScript's has. Either mismatch produces a line that
 * differs from the desktop's by one character on input nobody would think to
 * test, on the one string that is supposed to be identical across three clients.
 */
private func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20: return true
    case 0xa0, 0x1680: return true
    case 0x2000 ... 0x200a: return true
    case 0x2028, 0x2029, 0x202f, 0x205f, 0x3000: return true
    case 0xfeff: return true
    default: return false
    }
}

/// `value.replace(/\s+/g, ' ').trim()`, over the set above.
private func collapseAndTrim(_ scalars: String.UnicodeScalarView) -> String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    var wroteAnything = false
    for scalar in scalars {
        if isJSWhitespace(scalar) {
            // Held rather than written: a run of whitespace becomes one space,
            // and a run at the very end becomes nothing at all.
            pendingSpace = wroteAnything
            continue
        }
        if pendingSpace {
            out.append(" ")
            pendingSpace = false
        }
        out.append(scalar)
        wroteAnything = true
    }
    return String(out)
}

/* -------------------------------------------------------------------------- */
/* Sanitising                                                                  */
/* -------------------------------------------------------------------------- */

extension Inspect {

    /**
     * Everything the page produces passes through here before it can reach a
     * terminal.
     *
     * Control characters are removed rather than escaped — the composed context is
     * written into a PTY, where a stray newline submits the prompt early and an
     * ESC can repaint the user's screen. Bidi overrides go too: they let text
     * render as something other than what it says, and this string is read by a
     * person deciding what to tell an agent to change.
     *
     * `max` is counted in UTF-16 units, which is what `String.prototype.slice`
     * counts, so a clamped string is clamped at the same place on both platforms.
     */
    static func sanitizeLine(_ value: Any?, max: Int) -> String {
        guard let text = value as? String else { return "" }

        let scanLimit = max * scanHeadroom + 1024
        let scanned = text.utf16.count > scanLimit ? clampUTF16(text, to: scanLimit) : text

        var stripped = String.UnicodeScalarView()
        for scalar in scanned.unicodeScalars {
            switch scalar.value {
            // C0/C1 controls (includes \n, \r, \t and ESC) and the Unicode line breaks.
            case 0x0000 ... 0x001f, 0x007f ... 0x009f, 0x2028, 0x2029:
                stripped.append(" ")
            // Bidi embedding/override/isolate controls — invisible, and they reorder text.
            case 0x202a ... 0x202e, 0x2066 ... 0x2069, 0x200e, 0x200f:
                continue
            default:
                stripped.append(scalar)
            }
        }

        let collapsed = collapseAndTrim(stripped)
        if collapsed.utf16.count <= max { return collapsed }
        // `slice(0, max).trimEnd()` then an ellipsis, as `sanitizeLine` does.
        let cut = clampUTF16(collapsed, to: max)
        return "\(trimEnd(cut))\u{2026}"
    }

    /**
     * The first `limit` UTF-16 units, without splitting a surrogate pair.
     *
     * JavaScript's `slice` would happily cut between the halves and leave a lone
     * surrogate; Swift cannot hold one, and a `String` rebuilt from a split pair
     * gains a replacement character — a *different* string, one code point longer
     * than the cap. Backing off by one unit produces a string JavaScript could
     * also have produced, which is the property that matters.
     */
    static func clampUTF16(_ value: String, to limit: Int) -> String {
        if value.utf16.count <= limit { return value }
        var units = Array(value.utf16.prefix(limit))
        if let last = units.last, last >= 0xd800, last <= 0xdbff { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// `String.prototype.trimEnd`, over the JavaScript whitespace set.
    static func trimEnd(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, isJSWhitespace(last) { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        for scalar in scalars { view.append(scalar) }
        return String(view)
    }

    /// True when a string is safe to place inside a CSS string or identifier.
    private static func isPrintable(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0000 ... 0x001f, 0x007f ... 0x009f, 0x2028, 0x2029: return false
            default: continue
            }
        }
        return true
    }

    /**
     * `CSS.escape`, implemented here because this side has no `CSS` global and
     * must not ask the page for one.
     *
     * Follows the CSSOM serialisation algorithm: leading digits, a lone hyphen and
     * control characters all need hex escapes, and `#3col` is not a valid selector
     * even though `id="3col"` is a perfectly legal id.
     */
    static func escapeIdent(_ value: String) -> String {
        let units = Array(value.utf16)
        guard let first = units.first else { return "" }
        var out = ""
        for (i, code) in units.enumerated() {
            if code == 0x0000 {
                out.append("\u{FFFD}")
                continue
            }
            let isDigit = code >= 0x0030 && code <= 0x0039
            if (code >= 0x0001 && code <= 0x001f)
                || code == 0x007f
                || (i == 0 && isDigit)
                || (i == 1 && isDigit && first == 0x002d) {
                out.append("\\\(String(code, radix: 16)) ")
                continue
            }
            let char = String(decoding: [code], as: UTF16.self)
            if i == 0 && code == 0x002d && units.count == 1 {
                out.append("\\\(char)")
                continue
            }
            if code >= 0x0080
                || code == 0x002d
                || code == 0x005f
                || isDigit
                || (code >= 0x0041 && code <= 0x005a)
                || (code >= 0x0061 && code <= 0x007a) {
                out.append(char)
                continue
            }
            out.append("\\\(char)")
        }
        return out
    }

    /// A CSS string literal, or nil when the value cannot safely become one.
    static func cssString(_ value: String) -> String? {
        guard isPrintable(value) else { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Tag names we will emit. Allows custom elements and SVG's camelCase names.
    private static func safeTag(_ tag: String?) -> String {
        guard let tag, !tag.isEmpty, tag.count <= 60 else { return "*" }
        var scalars = tag.unicodeScalars.makeIterator()
        guard let first = scalars.next(), isASCIILetter(first) else { return "*" }
        for scalar in tag.unicodeScalars.dropFirst() {
            let value = scalar.value
            let ok = isASCIILetter(scalar)
                || (value >= 0x30 && value <= 0x39)
                || value == 0x2d
            if !ok { return "*" }
        }
        return tag
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5a) || (scalar.value >= 0x61 && scalar.value <= 0x7a)
    }

    /* ---------------------------------------------------------- selectors -- */

    private static func usableId(_ d: ElementDescriptor) -> String? {
        let id = (d.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= maxIdentLength, isPrintable(id) else { return nil }
        return id
    }

    private static func usableTest(_ d: ElementDescriptor) -> (attr: String, value: String)? {
        let attr = d.testAttr ?? ""
        let value = d.testValue ?? ""
        // The attribute name must be one *we* named. The page does not get to pick.
        guard testIdAttrs.contains(attr) else { return nil }
        guard !value.isEmpty, value.count <= maxIdentLength, isPrintable(value) else { return nil }
        return (attr, value)
    }

    private static func attrSelector(_ attr: String, _ value: String) -> String? {
        guard let literal = cssString(value) else { return nil }
        return "[\(attr)=\(literal)]"
    }

    /// `div` or `div:nth-of-type(3)` — position only when it actually disambiguates.
    private static func segmentFor(_ d: ElementDescriptor) -> String {
        let tag = safeTag(d.tag)
        let count = d.ofTypeCount ?? 1
        let nth = d.nthOfType ?? 1
        if count > 1 && nth >= 1 { return "\(tag):nth-of-type(\(nth))" }
        return tag
    }

    /**
     * Build the most stable selector the reported path supports.
     *
     * `path[0]` is the tapped element and each entry after it is its parent, which
     * is the order a DOM walk naturally produces. Preference order:
     *
     * 1. the element's own `#id`, **if that id is unique in the document** — ids
     *    are supposed to be unique and routinely are not; React lists duplicate
     *    them constantly, which is exactly the case a naive `#id` gets wrong;
     * 2. its test-hook attribute, when that is unique;
     * 3. a `>`-joined path of `tag:nth-of-type(n)` segments, anchored at the
     *    nearest unique id/test hook above it, or failing that at `body`.
     *
     * The anchor matters: an unanchored path like `div > span` matches at every
     * depth, so it is not a selector, it is a guess.
     */
    static func computeSelector(_ path: [ElementDescriptor]) -> String {
        guard !path.isEmpty else { return "" }
        var segments: [String] = []

        for d in path.prefix(maxPathDepth) {
            if let id = usableId(d), d.idUnique {
                segments.insert("#\(escapeIdent(id))", at: 0)
                return segments.joined(separator: " > ")
            }

            if let test = usableTest(d), d.testUnique, let selector = attrSelector(test.attr, test.value) {
                segments.insert(selector, at: 0)
                return segments.joined(separator: " > ")
            }

            // <html> is never worth a segment: `body` already anchors the path.
            if d.tag == "html" { break }

            segments.insert(segmentFor(d), at: 0)

            if d.tag == "body" { break }
        }

        return segments.joined(separator: " > ")
    }

    /* ------------------------------------------------------------ capture -- */

    private static func labelFrom(
        _ text: String,
        _ attributes: [String: String],
    ) -> (label: String, source: LabelSource) {
        if !text.isEmpty { return (text, .text) }
        // Order matters: an icon-only button has no text but usually has an
        // aria-label, and an empty input has a placeholder. Whichever a human
        // would read off the screen is the one the agent should be told about.
        let order: [LabelSource] = [.value, .ariaLabel, .alt, .placeholder, .title]
        for key in order {
            if let value = attributes[key.rawValue], !value.isEmpty { return (value, key) }
        }
        return ("", .none)
    }

    private static func sanitizeAttributes(_ raw: Any?) -> [String: String] {
        guard let record = raw as? [String: Any] else { return [:] }
        // A password field's live value must never travel. It would land in the
        // sheet, in the line handed to the agent, and from there in the agent's
        // own transcript on disk. The guest withholds it too; this is the half
        // that can be tested, and the half a tampered payload cannot skip.
        let type = (record["type"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        // `file` belongs here with `password`: its value is a path on the user's
        // own device and it is the attribute `labelFrom` reaches for first.
        let isSecret = type == "password" || type == "file"

        var out: [String: String] = [:]
        for key in captureAttrs {
            if isSecret && key == "value" { continue }
            let value = sanitizeLine(record[key], max: maxAttrLength)
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    private static func sanitizeDescriptor(_ raw: Any?) -> ElementDescriptor? {
        guard let r = raw as? [String: Any], let tag = r["tag"] as? String else { return nil }
        var d = ElementDescriptor(tag: String(tag.prefix(60)))
        if let id = r["id"] as? String { d.id = clampUTF16(id, to: maxIdentLength) }
        if let attr = r["testAttr"] as? String { d.testAttr = String(attr.prefix(60)) }
        if let value = r["testValue"] as? String { d.testValue = clampUTF16(value, to: maxIdentLength) }
        if r["idUnique"] as? Bool == true { d.idUnique = true }
        if r["testUnique"] as? Bool == true { d.testUnique = true }
        if let nth = wholeNumber(r["nthOfType"]), nth >= 1 { d.nthOfType = nth }
        if let count = wholeNumber(r["ofTypeCount"]), count >= 1 { d.ofTypeCount = count }
        return d
    }

    /**
     * A whole number out of a JSON value.
     *
     * `WKScriptMessage.body` hands JavaScript numbers over as `NSNumber`, which
     * answers `as? Int` for `3.7` as well as for `3` — so the integer check has
     * to be made explicitly. `Number.isInteger` is false for `NaN` and both
     * infinities and this matches that: a `Double` that is not finite cannot be
     * compared into range, and one that is not whole is not a sibling index.
     */
    private static func wholeNumber(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(.towardZero) else { return nil }
        guard value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
        return Int(value)
    }

    /**
     * Validate and sanitise a payload from the guest script.
     *
     * `url` comes from this app's own view of the `WKWebView`, not from the
     * payload — a page that can post to the message handler (any script on it
     * can) would otherwise be able to tell the agent it is editing a different
     * site than it is.
     *
     * Returns nil for anything malformed; the caller drops it silently rather
     * than surfacing a page-authored error string.
     */
    static func parseCapture(_ raw: Any?, url: String) -> ElementCapture? {
        guard let payload = raw as? [String: Any] else { return nil }
        guard wholeNumber(payload["v"]) == 1 else { return nil }
        guard let rawPath = payload["path"] as? [Any], !rawPath.isEmpty else { return nil }

        var path: [ElementDescriptor] = []
        for entry in rawPath.prefix(maxPathDepth) {
            // Stop, do not skip. The segments are joined with the child
            // combinator, so dropping one link out of the middle of the chain
            // silently asserts a parent/child relationship that does not exist —
            // `body > span` for a span nested six levels down. Truncating leaves
            // a shorter path that is still true; splicing leaves a selector that
            // is confidently wrong.
            guard let d = sanitizeDescriptor(entry) else { break }
            path.append(d)
        }
        guard !path.isEmpty else { return nil }

        let selector = computeSelector(path)
        guard !selector.isEmpty else { return nil }

        let attributes = sanitizeAttributes(payload["attributes"])
        let text = sanitizeLine(payload["text"], max: maxLabelLength)
        let (label, labelSource) = labelFrom(text, attributes)
        let tag = safeTag(path[0].tag) == "*" ? "" : path[0].tag

        let core = Core(
            selector: selector,
            tag: tag,
            label: label,
            labelSource: labelSource,
            url: sanitizeLine(url, max: maxURLLength),
        )

        return ElementCapture(
            selector: core.selector,
            tag: core.tag,
            label: core.label,
            labelSource: core.labelSource,
            url: core.url,
            attributes: attributes,
            context: composeAgentContext(core),
            depth: max(0, wholeNumber(payload["depth"]) ?? 0),
            ancestors: max(0, wholeNumber(payload["ancestors"]) ?? 0),
        )
    }

    /// The five fields the context line is built from. Split out so
    /// `composeAgentContext` can be tested without inventing a whole capture.
    struct Core: Equatable {
        let selector: String
        let tag: String
        let label: String
        let labelSource: LabelSource
        let url: String
    }

    /**
     * The one line that goes into the agent's prompt.
     *
     * Single line by construction. This is typed into a PTY running a coding
     * agent, and in every one of those CLIs a newline submits — a multi-line
     * context string would send the first line as the whole instruction.
     */
    static func composeAgentContext(_ capture: Core, instruction: String = "") -> String {
        var parts: [String] = []
        if !capture.url.isEmpty { parts.append("on \(capture.url)") }
        parts.append("element `\(capture.selector)`")
        if !capture.tag.isEmpty { parts.append("<\(capture.tag)>") }
        if !capture.label.isEmpty {
            let word = capture.labelSource == .text ? "text" : capture.labelSource.rawValue
            parts.append("\(word) \"\(capture.label)\"")
        }

        let context = "[browser: \(parts.joined(separator: ", "))]"
        let lead = sanitizeLine(instruction, max: maxInstructionLength)
        return sanitizeLine(lead.isEmpty ? context : "\(lead) \(context)", max: maxContextLength)
    }

    /* -------------------------------------------------------------- send -- */

    /**
     * Flatten anything on its way to the agent.
     *
     * A transcription of `oneLine` in `src/renderer/browser/CapturePanel.tsx`, to
     * the character. This app types the result into a PTY running a coding CLI,
     * where a newline submits the prompt — a two-line message would send the
     * first line as the whole instruction. The context half is already flattened
     * by `sanitizeLine`; this covers what the user typed into the instruction
     * field, which is the half a phone keyboard can put a newline in.
     */
    static func oneLine(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let code = scalar.value
            // C0 and C1 controls plus the Unicode line separators, written as
            // numbers rather than a character class so the intent survives a
            // copy-paste: a newline in this string submits the agent's prompt
            // early, and an ESC can repaint the terminal it lands in.
            let control = code < 0x20 || (code >= 0x7f && code <= 0x9f) || code == 0x2028 || code == 0x2029
            out.append(control ? " " : scalar)
        }
        return collapseAndTrim(out)
    }

    /// The exact string the agent receives.
    static func composeSend(context: String, instruction: String) -> String {
        let lead = oneLine(instruction)
        let tail = oneLine(context)
        return lead.isEmpty ? tail : "\(lead) \(tail)"
    }

    /// How the sheet names where the label came from. Mirrors `describeLabelSource`.
    static func describeLabelSource(_ source: LabelSource) -> String {
        switch source {
        case .text: return "text"
        case .none: return ""
        default: return source.rawValue
        }
    }
}
