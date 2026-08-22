package dev.terminaldeck.android.protocol

import kotlinx.serialization.Serializable
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Watching — and driving — the machine's browser: the frame that arrives, the surfaces that can be
 * watched, and the input that goes back.
 *
 * A transcription of the `browser.*` live-view family from `src/main/remote/protocol.ts`, of the
 * coordinate math in `pwa/src/browser-view.ts`, and of the same port iOS keeps in
 * `ios/TerminalDeck/Protocol/BrowserWatchWire.swift`. A `browser.frame` is a JPEG of a web page the
 * machine is holding; the viewer turns it back into something a finger can act on, and every tap
 * becomes a `browser.input` aimed at the frame it was measured against.
 *
 * ## The four rules a viewer cannot get wrong silently (from the PWA)
 *
 *  1. Ack from the paint callback, not on receipt — the host holds one un-acked frame per watcher,
 *     so acking early asks for frames faster than the phone can draw them.
 *  2. The page lives on the server, so the surface never scrolls itself — a swipe is a
 *     `browser.input` wheel, an act the server performs.
 *  3. Coordinates are image pixels of a *named* frame ([ServerMessage.BrowserFrame.seq]), so a scroll landing
 *     mid-gesture cannot desync the mapping.
 *  4. A masked frame is a curtain, never pixels — `data` is empty and the viewer draws its own lock
 *     card.
 *
 * The pure parts — the width negotiation, the view→image transform, the paste cleaning — live in
 * [WatchMath] so they can be tested without a live cast. The frame itself is a `ServerMessage`
 * variant rather than a type of its own: `browser.frame` is flat on the wire, `t` and its fields in
 * one object, so it is declared where every other inbound frame is — see
 * [ServerMessage.BrowserFrame].
 */

/** The working jpeg quality, sent unless a caller asks for another. Matches `DEFAULT_WATCH_QUALITY`. */
const val DEFAULT_WATCH_QUALITY = 50

/** The sentence under the lock card when the host sent no prompt of its own. */
const val DEFAULT_CURTAIN_PROMPT = "The person is entering something private."

/** How far a touch may drift in device pixels and still be a tap rather than a scroll. */
const val TAP_SLOP_PX = 24f

/**
 * One watchable surface — a tab in the strip.
 *
 * [window] is `""` for the front tab or a slot name; [live] is whether it is currently being cast.
 */
@Serializable
data class BrowserSurfaceWire(
    val window: String,
    val url: String = "",
    val title: String = "",
    val live: Boolean = false,
) {
    /** What a row prints when the page has not named itself. Never an empty line. */
    val displayTitle: String
        get() = title.take(Protocol.MAX_SURFACE_TITLE_LENGTH).ifBlank {
            window.ifBlank { "Front tab" }
        }
}

/** A mouse act, in image pixels of the frame it was measured against. */
@Serializable
data class BrowserMouseWire(
    val type: String,
    val x: Int,
    val y: Int,
    val button: String? = null,
    val clicks: Int? = null,
    val dx: Int? = null,
    val dy: Int? = null,
)

/** A key act. [text] is what a `char` inserts; [mods] is the modifier bitmask CDP wants. */
@Serializable
data class BrowserKeyWire(
    val type: String,
    val key: String? = null,
    val code: String? = null,
    val text: String? = null,
    val mods: Int = 0,
)

@Serializable
data class BrowserTouchPointWire(val x: Int, val y: Int)

@Serializable
data class BrowserTouchWire(
    val type: String,
    val points: List<BrowserTouchPointWire> = emptyList(),
)

/**
 * The pure geometry and cleaning, transcribed from `pwa/src/browser-view.ts`.
 *
 * Everything here is a function of numbers, which is the point: the viewer is a canvas and a
 * gesture recogniser, and the arithmetic that decides *where on the page a finger landed* is the
 * part that can be got wrong silently, so it is the part that lives where a test can reach it.
 */
object WatchMath {

    fun clamp(value: Double, low: Double, high: Double): Double {
        if (value.isNaN() || value.isInfinite()) return low
        return min(high, max(low, value))
    }

    /**
     * The width this viewer asks the host to render at, in device pixels.
     *
     * Asking for more is bytes no display can resolve; asking for fewer is a blurry page. Clamped
     * into the host's own range rather than sent raw, so what arrives is what was asked for instead
     * of what the host quietly reduced it to.
     */
    fun watchWidth(pixelWidth: Int): Int =
        clamp(
            pixelWidth.toDouble(),
            Protocol.MIN_WATCH_WIDTH.toDouble(),
            Protocol.MAX_WATCH_WIDTH.toDouble(),
        ).roundToInt()

    /** The jpeg quality this viewer asks for, clamped into the host's range. */
    fun watchQuality(quality: Int): Int =
        clamp(
            quality.toDouble(),
            Protocol.MIN_WATCH_QUALITY.toDouble(),
            Protocol.MAX_WATCH_QUALITY.toDouble(),
        ).roundToInt()

    /**
     * A point at view coordinates, in image pixels of the frame it was drawn against.
     *
     * The frame fills the view's box on both axes, so the mapping is the box ratio on each axis
     * independently — `x = px * (w / viewW)` — which is the exact transform the host inverts under
     * this frame's `seq`. Clamped into the image so a drag that leaves the view still names a pixel
     * on the page, and rounded because a fractional pixel is not a place a click can land.
     */
    fun imageCoords(
        frameW: Int,
        frameH: Int,
        viewW: Float,
        viewH: Float,
        px: Float,
        py: Float,
    ): Pair<Int, Int> {
        val sx = if (viewW > 0f) frameW.toDouble() / viewW.toDouble() else 0.0
        val sy = if (viewH > 0f) frameH.toDouble() / viewH.toDouble() else 0.0
        val x = clamp((px.toDouble() * sx).roundToDouble(), 0.0, frameW.toDouble())
        val y = clamp((py.toDouble() * sy).roundToDouble(), 0.0, frameH.toDouble())
        return x.toInt() to y.toInt()
    }

    private fun Double.roundToDouble(): Double = if (isFinite()) roundToInt().toDouble() else 0.0

    /**
     * Strip the control bytes a page's field would choke on and bound the result the way a paste is
     * bounded on the wire.
     *
     * The host refuses an over-cap paste and one into a secret field; this is the cheap client-side
     * pass that keeps an ordinary paste from being refused for a reason a person cannot see. C0
     * controls and DEL go, tab and newline stay, and the cut is on a code-point boundary measured in
     * UTF-8 bytes so a multi-byte character is never split at the cap. Mirrors `cleanPaste`.
     */
    fun cleanPaste(text: String, maxBytes: Int = Protocol.MAX_INPUT_BYTES): String {
        val out = StringBuilder()
        var bytes = 0
        var index = 0
        while (index < text.length) {
            val code = text[index].code
            val isPair = code in 0xd800..0xdbff &&
                index + 1 < text.length &&
                text[index + 1].code in 0xdc00..0xdfff
            val width = when {
                code < 0x80 -> 1
                code < 0x800 -> 2
                isPair -> 4
                else -> 3
            }
            val drop = (code < 0x20 && code != 0x09 && code != 0x0a) || code == 0x7f
            if (!drop) {
                if (bytes + width > maxBytes) break
                bytes += width
                out.append(text, index, index + if (isPair) 2 else 1)
            }
            index += if (isPair) 2 else 1
        }
        return out.toString()
    }

    /** How many base64 characters a JPEG of this many bytes becomes. Used only by the size tests. */
    fun base64Chars(bytes: Int): Int = ceil(bytes / 3.0).toInt() * 4
}
