package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.BrowserKeyWire
import dev.terminaldeck.android.protocol.BrowserMouseWire
import dev.terminaldeck.android.protocol.BrowserSurfaceWire
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.WatchMath

/**
 * Watching the machine's browser from a phone — the surface list, and the frame routing behind the
 * live view.
 *
 * The client half of [Capability.WATCH], reached over the capability the host advertises only to one
 * of the owner's own devices, because watching a signed-in browser is an owner act. This holds the
 * shared part — the tab strip, the capability, and the frames as they arrive — and the viewer
 * composable holds the per-surface part: the paint/ack loop and the gestures, because the ack has to
 * fire from the draw and a gesture is measured against the frame currently on screen.
 *
 * ## One surface at a time, on purpose
 *
 * The PWA mounts a canvas per watched window because a browser tab can hold several at once. A phone
 * screen is one surface: opening a tab from the strip casts it full-screen, and closing the viewer
 * stops the cast. So a single frame sink is enough, and [frameHandler] is it — set by the viewer
 * when it appears, cleared when it goes. A frame for a window nothing is showing is **dropped, not
 * buffered**: a live frame is stale before anything could catch up on it.
 *
 * ## Frames do not go through the ui state
 *
 * For the reason `output` does not: they are the chattiest thing on this socket and they change
 * nothing any screen reads off [DeckUiState]. Refolding every machine's summary per frame would
 * rebuild the world to arrive at a state that compares equal to the one already there. The strip
 * *does* go through it, because it is a list somebody looks at.
 *
 * One per [HostLink].
 */
class WatchController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val onChange: () -> Unit,
) {
    private var surfaces: List<BrowserSurfaceWire> = emptyList()

    /** The window currently being cast to the viewer, or null when none is open. */
    private var watching: String? = null

    private var requested = false
    private var counter = 0

    /**
     * The viewer's frame sink.
     *
     * Not part of the ui state: the viewer needs each frame in a callback it can ack from, not a
     * property change it re-renders on. Cleared by the viewer on the way out, and by [renew] when
     * the machine underneath changes.
     */
    var frameHandler: ((ServerMessage.BrowserFrame) -> Unit)? = null

    fun offered(): Boolean = capabilities().contains(Capability.WATCH)

    /** A snapshot the strip draws from, or null over a machine that does not offer watching. */
    fun view(): WatchView? {
        if (!offered()) return null
        return WatchView(surfaces = surfaces, watching = watching, asked = requested)
    }

    /**
     * A new welcome: forget the last machine's strip.
     *
     * The surfaces belong to whichever machine this connection reaches, and a guest is not told the
     * capability exists at all — so a list left over from the machine before would be one computer's
     * tabs drawn under another's name.
     */
    fun renew() {
        surfaces = emptyList()
        watching = null
        requested = false
        frameHandler = null
        onChange()
    }

    /** Ask for the tab strip once, when the screen opens. The pushed rows keep it fresh after that. */
    fun ensureRead() {
        if (!offered() || requested) return
        ask()
    }

    /** The user pulled to refresh: ask again even though a strip has already arrived. */
    fun refresh() {
        if (!offered()) return
        ask()
    }

    private fun ask() {
        counter += 1
        if (!send(ClientMessage.BrowserSurfaces("wch-$counter"))) return
        requested = true
        onChange()
    }

    /**
     * Start — or renegotiate — the cast of one surface.
     *
     * [window] is `""` for the front tab or a slot name. Idempotent on the host, which is what makes
     * a rotation a renegotiation rather than a second cast. Both numbers are clamped here rather
     * than left to the host, so what arrives is what was asked for.
     */
    fun watch(window: String, maxWidthPx: Int, quality: Int = dev.terminaldeck.android.protocol.DEFAULT_WATCH_QUALITY): Boolean {
        if (!offered()) return false
        watching = window
        val sent = send(
            ClientMessage.BrowserWatch(
                window = window,
                maxWidth = WatchMath.watchWidth(maxWidthPx),
                quality = WatchMath.watchQuality(quality),
            )
        )
        onChange()
        return sent
    }

    /** Stop the cast of the window being shown. Called when the viewer closes, always. */
    fun unwatch(window: String) {
        send(ClientMessage.BrowserUnwatch(window))
        if (watching == window) {
            watching = null
            onChange()
        }
    }

    /** Drawn — send the next frame. The one-in-flight backpressure; see the frame's own note. */
    fun ack(window: String, seq: Int) {
        send(ClientMessage.BrowserFrameAck(window, seq))
    }

    /** A tap, synthesised as a click so a page with no touch handlers still responds. */
    fun tap(window: String, seq: Int, x: Int, y: Int) {
        send(
            ClientMessage.BrowserInput(
                window = window,
                seq = seq,
                mouse = BrowserMouseWire(type = "down", x = x, y = y, button = "left", clicks = 1),
            )
        )
        send(
            ClientMessage.BrowserInput(
                window = window,
                seq = seq,
                mouse = BrowserMouseWire(type = "up", x = x, y = y, button = "left"),
            )
        )
    }

    /**
     * A swipe.
     *
     * Sent as a wheel because the page lives on the server: the surface never scrolls itself, and a
     * viewer that scrolled its own canvas would be showing a picture of a viewport the server has
     * not moved.
     */
    fun scroll(window: String, seq: Int, x: Int, y: Int, dx: Int, dy: Int) {
        send(
            ClientMessage.BrowserInput(
                window = window,
                seq = seq,
                mouse = BrowserMouseWire(type = "wheel", x = x, y = y, dx = dx, dy = dy),
            )
        )
    }

    /**
     * Text into the page, then Return.
     *
     * The two things a page form needs from a phone with no hardware keyboard. The text goes as one
     * paste rather than a key per character — a key-by-key replay of a soft keyboard would be dozens
     * of frames for one field — and is cleaned first so an ordinary paste is not refused for a reason
     * a person cannot see.
     */
    fun type(window: String, seq: Int, text: String) {
        val cleaned = WatchMath.cleanPaste(text)
        if (cleaned.isEmpty()) return
        send(ClientMessage.BrowserInput(window = window, seq = seq, paste = cleaned))
        send(
            ClientMessage.BrowserInput(
                window = window,
                seq = seq,
                key = BrowserKeyWire(type = "down", key = "Enter", code = "Enter"),
            )
        )
    }

    /** Frames this controller owns. True when the frame was claimed. */
    fun receive(message: ServerMessage): Boolean = when (message) {
        is ServerMessage.BrowserSurfacesRows -> {
            // Answer or unsolicited push — the strip is the whole list either way, so the rid is not
            // matched: there is nothing to resolve.
            surfaces = message.surfaces.take(dev.terminaldeck.android.protocol.Protocol.MAX_SURFACES_REPORTED)
            requested = true
            onChange()
            true
        }

        is ServerMessage.BrowserFrame -> {
            // Routed to the open viewer, or dropped. A frame for a surface nothing is showing is
            // stale the instant it is not drawn.
            frameHandler?.invoke(message)
            true
        }

        else -> false
    }

    fun stop() {
        frameHandler = null
        watching?.let { send(ClientMessage.BrowserUnwatch(it)) }
        watching = null
        surfaces = emptyList()
        requested = false
    }
}

/**
 * What the watch screens read.
 *
 * [asked] is whether a strip has been requested on this connection, so an empty list can be told
 * from an unknown one — "no windows to watch" and "not asked yet" are different sentences.
 */
data class WatchView(
    val surfaces: List<BrowserSurfaceWire>,
    val watching: String?,
    val asked: Boolean,
)
