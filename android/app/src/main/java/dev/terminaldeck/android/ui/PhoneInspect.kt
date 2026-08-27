package dev.terminaldeck.android.ui

import kotlin.math.floor

/**
 * One element on the path from the tapped node up to the document root, as the guest script reports
 * it. Every field is optional except [tag], because a hostile or merely unusual page may not supply
 * any of it.
 */
data class ElementDescriptor(
    val tag: String,
    val id: String? = null,
    val testAttr: String? = null,
    val testValue: String? = null,
    val idUnique: Boolean = false,
    val testUnique: Boolean = false,
    val nthOfType: Int? = null,
    val ofTypeCount: Int? = null,
)

/** A sanitised, ready-to-show capture. Nothing here came straight from the page. */
data class ElementCapture(
    val selector: String,
    val tag: String,
    /** Best human-readable handle for the element, already trimmed and clamped. */
    val label: String,
    /** The page URL as *this app* knows it — never the page's own claim. */
    val url: String,
    /** Whitelisted attributes, sanitised. Shown in the row, not used in selectors. */
    val attributes: Map<String, String>,
)

/**
 * The selector engine — a port of the parts of `ios/TerminalDeck/Inspect/ElementCapture.swift` the
 * phone recorder needs, itself a transcription of `selector.ts`.
 *
 * Everything a page produces passes through here before it can reach a terminal: control characters
 * removed (the composed line is written into a PTY, where a stray newline submits early), bidi
 * overrides removed (they render text as something other than what it says), and every string clamped.
 * A payload that arrived from the page is treated as hostile — nothing about a selector is decided in
 * JavaScript, and a `data-testid` counts only when the attribute name is one **we** named.
 *
 * ## Kotlin strings are UTF-16, which is the win here
 *
 * `String.prototype.slice` counts UTF-16 units, and so do Kotlin's `length` and `substring` — so a
 * string clamped here is clamped at the same place the desktop clamps it, the one property that has to
 * hold across three clients. The only care is not to split a surrogate pair, which [clampUtf16] takes.
 */
object PhoneInspect {

    /** Test-hook attributes in priority order — `data-testid` first, what Testing Library and
     *  Playwright default to, so the one most likely to be in the codebase the agent will edit. */
    val testIdAttrs = listOf(
        "data-testid", "data-test-id", "data-test", "data-qa", "data-cy", "data-automation-id",
    )

    /** Attributes worth carrying across. A **closed** list: the page controls attribute names as well
     *  as values, and an open copy would let it stuff arbitrary keys into this app's UI. */
    val captureAttrs = listOf(
        "aria-label", "alt", "placeholder", "title", "role", "type", "name", "href", "value",
    )

    const val MAX_PATH_DEPTH = 64
    const val MAX_LABEL_LENGTH = 150
    const val MAX_IDENT_LENGTH = 200
    const val MAX_ATTR_LENGTH = 300
    const val MAX_URL_LENGTH = 400
    const val SCAN_HEADROOM = 32

    /* -------------------------------------------------------------- whitespace -- */

    /** `\s` in a JavaScript regular expression, written out because it is **not** the same set as any
     *  Kotlin/JVM helper — the difference is silent and shows up on the one string meant to be
     *  identical across clients. */
    private fun isJsWhitespace(cp: Int): Boolean = when (cp) {
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20 -> true
        0xa0, 0x1680 -> true
        in 0x2000..0x200a -> true
        0x2028, 0x2029, 0x202f, 0x205f, 0x3000 -> true
        0xfeff -> true
        else -> false
    }

    /** `value.replace(/\s+/g, ' ').trim()`, over the set above. */
    private fun collapseAndTrim(s: String): String {
        val out = StringBuilder()
        var pendingSpace = false
        var wroteAnything = false
        for (ch in s) {
            if (isJsWhitespace(ch.code)) {
                pendingSpace = wroteAnything
                continue
            }
            if (pendingSpace) {
                out.append(' ')
                pendingSpace = false
            }
            out.append(ch)
            wroteAnything = true
        }
        return out.toString()
    }

    /* ---------------------------------------------------------------- sanitise -- */

    /**
     * Everything the page produces passes through here before it can reach a terminal. Control
     * characters and Unicode line breaks become a space; bidi overrides are dropped; the result is
     * collapsed, trimmed, and clamped to [max] UTF-16 units with an ellipsis.
     */
    fun sanitizeLine(value: Any?, max: Int): String {
        val text = value as? String ?: return ""
        val scanLimit = max * SCAN_HEADROOM + 1024
        val scanned = if (text.length > scanLimit) clampUtf16(text, scanLimit) else text

        val stripped = StringBuilder()
        for (ch in scanned) {
            val c = ch.code
            when {
                c in 0x0000..0x001f || c in 0x007f..0x009f || c == 0x2028 || c == 0x2029 -> stripped.append(' ')
                c in 0x202a..0x202e || c in 0x2066..0x2069 || c == 0x200e || c == 0x200f -> Unit
                else -> stripped.append(ch)
            }
        }

        val collapsed = collapseAndTrim(stripped.toString())
        if (collapsed.length <= max) return collapsed
        return trimEnd(clampUtf16(collapsed, max)) + "…"
    }

    /** The first [limit] UTF-16 units, without splitting a surrogate pair. */
    fun clampUtf16(value: String, limit: Int): String {
        if (value.length <= limit) return value
        var end = limit
        if (end > 0 && value[end - 1].isHighSurrogate()) end--
        return value.substring(0, end)
    }

    /** `String.prototype.trimEnd`, over the JavaScript whitespace set. */
    fun trimEnd(value: String): String {
        var end = value.length
        while (end > 0 && isJsWhitespace(value[end - 1].code)) end--
        return value.substring(0, end)
    }

    private fun isPrintable(value: String): Boolean {
        for (ch in value) {
            val c = ch.code
            if (c in 0x0000..0x001f || c in 0x007f..0x009f || c == 0x2028 || c == 0x2029) return false
        }
        return true
    }

    private fun isAsciiLetter(c: Int): Boolean = (c in 0x41..0x5a) || (c in 0x61..0x7a)

    /**
     * `CSS.escape`, implemented here because this side has no `CSS` global and must not ask the page
     * for one. Follows the CSSOM serialisation algorithm: leading digits, a lone hyphen and control
     * characters all need hex escapes, so `#3col` is not a valid selector even though `id="3col"` is a
     * perfectly legal id.
     */
    fun escapeIdent(value: String): String {
        if (value.isEmpty()) return ""
        val first = value[0].code
        val out = StringBuilder()
        for (i in value.indices) {
            val code = value[i].code
            if (code == 0x0000) {
                out.append('�')
                continue
            }
            val isDigit = code in 0x0030..0x0039
            if ((code in 0x0001..0x001f) || code == 0x007f ||
                (i == 0 && isDigit) ||
                (i == 1 && isDigit && first == 0x002d)
            ) {
                out.append('\\').append(Integer.toHexString(code)).append(' ')
                continue
            }
            val ch = value[i]
            if (i == 0 && code == 0x002d && value.length == 1) {
                out.append('\\').append(ch)
                continue
            }
            if (code >= 0x0080 || code == 0x002d || code == 0x005f || isDigit ||
                (code in 0x0041..0x005a) || (code in 0x0061..0x007a)
            ) {
                out.append(ch)
                continue
            }
            out.append('\\').append(ch)
        }
        return out.toString()
    }

    /** A CSS string literal, or null when the value cannot safely become one. */
    fun cssString(value: String): String? {
        if (!isPrintable(value)) return null
        val escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
        return "\"$escaped\""
    }

    /** Tag names we will emit. Allows custom elements and SVG's camelCase names. */
    private fun safeTag(tag: String?): String {
        if (tag.isNullOrEmpty() || tag.length > 60) return "*"
        if (!isAsciiLetter(tag[0].code)) return "*"
        for (i in 1 until tag.length) {
            val c = tag[i].code
            val ok = isAsciiLetter(c) || (c in 0x30..0x39) || c == 0x2d
            if (!ok) return "*"
        }
        return tag
    }

    /* --------------------------------------------------------------- selectors -- */

    private fun usableId(d: ElementDescriptor): String? {
        val id = (d.id ?: "").trim()
        if (id.isEmpty() || id.length > MAX_IDENT_LENGTH || !isPrintable(id)) return null
        return id
    }

    private fun usableTest(d: ElementDescriptor): Pair<String, String>? {
        val attr = d.testAttr ?: ""
        val value = d.testValue ?: ""
        // The attribute name must be one *we* named. The page does not get to pick.
        if (attr !in testIdAttrs) return null
        if (value.isEmpty() || value.length > MAX_IDENT_LENGTH || !isPrintable(value)) return null
        return attr to value
    }

    private fun attrSelector(attr: String, value: String): String? {
        val literal = cssString(value) ?: return null
        return "[$attr=$literal]"
    }

    /** `div` or `div:nth-of-type(3)` — position only when it actually disambiguates. */
    private fun segmentFor(d: ElementDescriptor): String {
        val tag = safeTag(d.tag)
        val count = d.ofTypeCount ?: 1
        val nth = d.nthOfType ?: 1
        if (count > 1 && nth >= 1) return "$tag:nth-of-type($nth)"
        return tag
    }

    /**
     * Build the most stable selector the reported path supports. `path[0]` is the tapped element and
     * each entry after it is its parent. Preference: the element's own unique `#id`, then its unique
     * test hook, then a `>`-joined path of `tag:nth-of-type(n)` anchored at the nearest unique id/test
     * above it or at `body`. The anchor matters — an unanchored `div > span` matches at every depth, so
     * it is a guess, not a selector.
     */
    fun computeSelector(path: List<ElementDescriptor>): String {
        if (path.isEmpty()) return ""
        val segments = ArrayDeque<String>()
        for (d in path.take(MAX_PATH_DEPTH)) {
            val id = usableId(d)
            if (id != null && d.idUnique) {
                segments.addFirst("#${escapeIdent(id)}")
                return segments.joinToString(" > ")
            }
            val test = usableTest(d)
            if (test != null && d.testUnique) {
                val sel = attrSelector(test.first, test.second)
                if (sel != null) {
                    segments.addFirst(sel)
                    return segments.joinToString(" > ")
                }
            }
            // <html> is never worth a segment: `body` already anchors the path.
            if (d.tag == "html") break
            segments.addFirst(segmentFor(d))
            if (d.tag == "body") break
        }
        return segments.joinToString(" > ")
    }

    /* ----------------------------------------------------------------- capture -- */

    /** The element's own readable text, or the first naming attribute a human would read off the
     *  screen. Order matters: an icon-only button has no text but usually an aria-label. */
    private fun labelFrom(text: String, attributes: Map<String, String>): String {
        if (text.isNotEmpty()) return text
        for (key in listOf("value", "aria-label", "alt", "placeholder", "title")) {
            val value = attributes[key]
            if (!value.isNullOrEmpty()) return value
        }
        return ""
    }

    private fun sanitizeAttributes(raw: Any?): Map<String, String> {
        val record = raw as? Map<*, *> ?: return emptyMap()
        // A password or file field's live value must never travel — it would land in the row and in
        // the line handed to the agent. The guest withholds it too; this is the half a tampered payload
        // cannot skip.
        val type = (record["type"] as? String)?.trim()?.lowercase()
        val isSecret = type == "password" || type == "file"
        val out = mutableMapOf<String, String>()
        for (key in captureAttrs) {
            if (isSecret && key == "value") continue
            val value = sanitizeLine(record[key], MAX_ATTR_LENGTH)
            if (value.isNotEmpty()) out[key] = value
        }
        return out
    }

    private fun sanitizeDescriptor(raw: Any?): ElementDescriptor? {
        val r = raw as? Map<*, *> ?: return null
        val tag = r["tag"] as? String ?: return null
        return ElementDescriptor(
            tag = if (tag.length > 60) tag.substring(0, 60) else tag,
            id = (r["id"] as? String)?.let { clampUtf16(it, MAX_IDENT_LENGTH) },
            testAttr = (r["testAttr"] as? String)?.let { if (it.length > 60) it.substring(0, 60) else it },
            testValue = (r["testValue"] as? String)?.let { clampUtf16(it, MAX_IDENT_LENGTH) },
            idUnique = r["idUnique"] == true,
            testUnique = r["testUnique"] == true,
            nthOfType = wholeNumber(r["nthOfType"])?.takeIf { it >= 1 },
            ofTypeCount = wholeNumber(r["ofTypeCount"])?.takeIf { it >= 1 },
        )
    }

    /**
     * A whole number out of a JSON value. A JavaScript number crosses as a `Number`, which answers a
     * plain `as? Int` for `3.7` as well as `3` — so the integer check is made explicitly, and a value
     * that is not finite or not whole is not a sibling index.
     */
    fun wholeNumber(raw: Any?): Int? {
        val number = raw as? Number ?: return null
        val value = number.toDouble()
        if (!value.isFinite()) return null
        if (value != floor(value)) return null
        if (value < Int.MIN_VALUE.toDouble() || value > Int.MAX_VALUE.toDouble()) return null
        return value.toInt()
    }

    /**
     * Validate and sanitise a payload from the guest script. [url] comes from this app's own view of
     * the web view, not from the payload — a page that can post would otherwise be able to tell the
     * agent it is editing a different site than it is. Returns null for anything malformed; the caller
     * drops it silently rather than surfacing a page-authored error string.
     */
    fun parseCapture(raw: Any?, url: String): ElementCapture? {
        val payload = raw as? Map<*, *> ?: return null
        if (wholeNumber(payload["v"]) != 1) return null
        val rawPath = payload["path"] as? List<*> ?: return null
        if (rawPath.isEmpty()) return null

        val path = mutableListOf<ElementDescriptor>()
        for (entry in rawPath.take(MAX_PATH_DEPTH)) {
            // Stop, do not skip: the segments join with the child combinator, so dropping a link out of
            // the middle asserts a parent/child relationship that does not exist. Truncating leaves a
            // shorter path that is still true.
            val d = sanitizeDescriptor(entry) ?: break
            path.add(d)
        }
        if (path.isEmpty()) return null

        val selector = computeSelector(path)
        if (selector.isEmpty()) return null

        val attributes = sanitizeAttributes(payload["attributes"])
        val text = sanitizeLine(payload["text"], MAX_LABEL_LENGTH)
        val label = labelFrom(text, attributes)
        val tag = if (safeTag(path[0].tag) == "*") "" else path[0].tag
        return ElementCapture(selector, tag, label, sanitizeLine(url, MAX_URL_LENGTH), attributes)
    }
}
