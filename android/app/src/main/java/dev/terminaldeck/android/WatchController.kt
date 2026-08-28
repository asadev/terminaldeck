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
     * The handover outstanding on each window that has one, by window name.
     *
     * A map rather than a single value because two windows can be asking at once — two sessions, two
     * agents, two logins — and the screen that draws one is addressed by the window it is showing.
     * Windows with nothing outstanding are absent, so [handover] returning null is the ordinary answer
     * and the bar is simply not drawn. Mirrors iOS `WatchLink.handovers`.
     */
    private val handovers = mutableMapOf<String, BrowserHandover>()

    /**
     * Windows with a `take` or a `done` of ours in flight.
     *
     * Two jobs. It stops a double tap sending a second claim — which on a `done` would be a second,
     * opposite answer to a question already answered. And it is what [wireErrored] reads: the wire's
     * error frame carries no correlation id, so an error arriving while exactly one handover answer is
     * outstanding is treated as that one's refusal — the same assumption the copilot and a folder
     * browse already make. Mirrors iOS `WatchLink.awaiting`.
     */
    private val awaiting = mutableSetOf<String>()

    /**
     * The viewer's frame sink.
     *
     * Not part of the ui state: the viewer needs each frame in a callback it can ack from, not a
     * property change it re-renders on. Cleared by the viewer on the way out, and by [renew] when
     * the machine underneath changes.
     */
    var frameHandler: ((ServerMessage.BrowserFrame) -> Unit)? = null

    fun offered(): Boolean = capabilities().contains(Capability.WATCH)

    /** A snapshot the strip and the handover bar draw from, or null over a machine that does not
     *  offer watching. The handover maps are copied so the drawn snapshot cannot change under a
     *  frame arriving between fold and draw. */
    fun view(): WatchView? {
        if (!offered()) return null
        return WatchView(
            surfaces = surfaces,
            watching = watching,
            asked = requested,
            handovers = handovers.toMap(),
            awaiting = awaiting.toSet(),
        )
    }

    /** The handover outstanding on one window, or null when nothing is being asked there. */
    fun handover(window: String): BrowserHandover? = handovers[window]

    /** Whether an answer of ours about this window — a claim or a hand-back — is still in flight. */
    fun isAwaiting(window: String): Boolean = awaiting.contains(window)

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
        // A handover belongs to the connection that was asked, so a new welcome ends any that were
        // outstanding: an old login prompt drawn under a new machine's name is a question nobody asked.
        handovers.clear()
        awaiting.clear()
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

    /**
     * One key, pressed and then released.
     *
     * Both halves always, never just the down: a page listening on `keyup` — search-as-you-type is
     * the everyday one — needs the release to fire, and a viewer that sent only the press would drive
     * every such page half way and no further. The mirror of `WatchSurfaceUIView.key` on iOS.
     */
    fun key(window: String, seq: Int, key: String, code: String) {
        send(ClientMessage.BrowserInput(window = window, seq = seq, key = BrowserKeyWire(type = "down", key = key, code = code)))
        send(ClientMessage.BrowserInput(window = window, seq = seq, key = BrowserKeyWire(type = "up", key = key, code = code)))
    }

    /**
     * Text the soft keyboard committed, as one paste.
     *
     * A whole string in one frame rather than a key per character — a key-by-key replay of a soft
     * keyboard would be dozens of frames for one word, and a paste also carries an IME candidate
     * whole. Cleaned first so an ordinary one is not refused for a reason a person cannot see. This is
     * what a tap-focused canvas streams `insertText` through; it does **not** press Return, so a field
     * can be typed into without submitting it.
     */
    fun insert(window: String, seq: Int, text: String) {
        val cleaned = WatchMath.cleanPaste(text)
        if (cleaned.isEmpty()) return
        send(ClientMessage.BrowserInput(window = window, seq = seq, paste = cleaned))
    }

    /** Return, as its own key so a form submits. */
    fun enter(window: String, seq: Int) = key(window, seq, "Enter", "Enter")

    /**
     * Backspace: the key down-and-up, and a `char` event carrying the delete control beside it.
     *
     * Both, matching `WatchSurfaceUIView.deleteBackward`. The host does not act on either yet — so
     * nothing here is drawn as a delete key claiming it works — but both are cheap and are what a page
     * that grows the handler will read, so they are sent rather than held back for a wire that has not
     * landed.
     */
    fun backspace(window: String, seq: Int) {
        key(window, seq, "Backspace", "Backspace")
        send(ClientMessage.BrowserInput(window = window, seq = seq, key = BrowserKeyWire(type = "char", code = "Backspace", text = "\u0008")))
    }

    /* ------------------------------------------------------------------ handover -- */

    /**
     * **That person is me.** Claim the login the machine's agent is waiting on.
     *
     * Guarded on there actually being a question, because a `take` for a window with no handover is
     * refused at the far end — a sentence on a screen instead of a button that quietly does nothing.
     * The last refusal goes with the new attempt: leaving it up beside a claim in flight is the screen
     * contradicting itself. Once the host grants the baton it stops curtaining this connection's
     * frames, so the person taps the login field and types with the soft keyboard the cast already
     * raises — nothing else on the phone changes. Mirrors iOS `WatchLink.take`.
     */
    fun take(window: String): Boolean {
        if (!offered() || handovers[window]?.asking != true || awaiting.contains(window)) return false
        val rid = nextRid()
        if (!send(ClientMessage.BrowserHandoverTake(rid = rid, window = window))) return false
        handovers[window] = handovers[window]!!.copy(refusal = null)
        awaiting.add(window)
        onChange()
        return true
    }

    /**
     * Hand it back, and say which of the two things that means.
     *
     * [carryOn] `true` returns the baton and the agent's blocked call resolves; `false` ends the drive.
     * Only from the device that holds it — `mine` is the guard, and the far end applies the same one,
     * because a second watcher handing back a page mid-password on behalf of the person typing into it
     * is the exact thing both ends refuse. Mirrors iOS `WatchLink.handBack`.
     */
    fun handBack(window: String, carryOn: Boolean): Boolean {
        if (!offered() || handovers[window]?.mine != true || awaiting.contains(window)) return false
        val rid = nextRid()
        if (!send(ClientMessage.BrowserHandoverDone(rid = rid, window = window, carryOn = carryOn))) return false
        awaiting.add(window)
        onChange()
        return true
    }

    /**
     * The machine refused something while an answer of ours was in flight.
     *
     * The wire's `error` carries no correlation id, so this cannot be narrowed to *our* frame without
     * inventing a field. What it can be narrowed to is *a moment when exactly one handover answer was
     * outstanding* — [awaiting] — and the cost of being wrong is one sentence a following state frame
     * clears. The refusal is drawn **beside** the claim, which becomes *Try again*: this end cannot
     * know whether a refusal was permanent, and the likeliest one is a race. Mirrors iOS
     * `WatchLink.wireErrored`; a no-op when nothing was outstanding.
     */
    fun wireErrored(message: String) {
        if (awaiting.isEmpty()) return
        val sentence = message.ifEmpty { "The machine refused that." }
        for (window in awaiting) {
            handovers[window]?.let { handovers[window] = it.copy(refusal = sentence) }
        }
        awaiting.clear()
        onChange()
    }

    private fun nextRid(): String {
        counter += 1
        return "wch-h-$counter"
    }

    /**
     * Fold one `browser.handover.state` into what this phone is showing.
     *
     * Answer and push are the same here — the state is the whole truth either way, so the rid is not
     * matched. A plain overwrite now that `taken` is carried rather than derived: nothing needs the
     * last frame's value. A window that has stopped asking is **removed** rather than kept asking=false,
     * so a refusal from the last question does not outlive it. Mirrors iOS `WatchLink.apply`.
     */
    private fun apply(state: ServerMessage.BrowserHandover) {
        awaiting.remove(state.window)
        if (!state.asking) {
            handovers.remove(state.window)
        } else {
            handovers[state.window] = BrowserHandover(
                asking = true,
                prompt = state.sentence,
                mine = state.mine,
                taken = state.taken,
                refusal = null,
            )
        }
        onChange()
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

        is ServerMessage.BrowserHandover -> {
            apply(message)
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
        handovers.clear()
        awaiting.clear()
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
    /** The handover outstanding on each window that has one, by window name. Empty is the ordinary
     *  case: no agent is waiting on a person. */
    val handovers: Map<String, BrowserHandover> = emptyMap(),
    /** Windows with a claim or a hand-back of ours in flight, so the bar can show its buttons busy. */
    val awaiting: Set<String> = emptySet(),
) {
    /** The handover on one window, or null — what the overlay draws the bar off. */
    fun handoverFor(window: String): BrowserHandover? = handovers[window]

    /** Whether an answer of ours about this window is still in flight. */
    fun awaitingFor(window: String): Boolean = awaiting.contains(window)
}

/**
 * What this phone knows about the handover on one window — the wire's `browser.handover.state` plus
 * [refusal], which the frame has no field for and this end has to hold: the machine's own sentence
 * when a claim from this device was refused. Never this end's words for it — the wire's error frame
 * carries no reason code and inventing one would be inventing why. Mirrors iOS `BrowserHandover`.
 */
data class BrowserHandover(
    /** A handover is outstanding here: the agent has stopped and is waiting for a person. */
    val asking: Boolean,
    /** The agent's own sentence — what it wants typed. */
    val prompt: String,
    /** This device holds it: the pixels arrive unmasked and the taps land. */
    val mine: Boolean,
    /** Somebody holds it — this device or another. With [mine] it makes the three states exactly:
     *  `!taken` claimable, `taken && mine` yours, `taken && !mine` somebody else's. */
    val taken: Boolean,
    /** The machine's sentence when a claim from this device was refused, or null. */
    val refusal: String? = null,
)

/**
 * What the handover bar says and what it offers, from the state alone.
 *
 * Pulled out of the view because it is the one decision on that bar that is a decision and not a
 * layout: four states, four different things to draw, and getting it wrong either way is a real
 * defect — offering the claim to a device that cannot have it is a button that will be refused;
 * withholding it from the device that could answer is a blocked agent nobody can unblock. Mirrors
 * iOS `SessionHandover`, and `WatchHandoverTest` pins it here rather than in a composable.
 */
object SessionHandover {
    enum class Offer {
        /** Nobody has answered yet. The primary button — this is the feature. */
        Claim,

        /** This device asked and the machine said no. The same button, saying *Try again*, beside the
         *  machine's own sentence: this end cannot know a refusal was permanent, and the likeliest one
         *  is a race. */
        Retry,

        /** Somebody else answered it. Nothing to press — the far end would refuse it, and reaching
         *  into a page somebody is typing a password into is precisely what `taken` exists to prevent. */
        Elsewhere,

        /** This device holds it. Two answers, and they say what they do. */
        HandBack,
    }

    fun offer(state: BrowserHandover): Offer = when {
        // `mine` first and unconditionally: a device that holds the page is never offered a way to take
        // it again, whatever else is true — including a refusal left over from before it was granted.
        state.mine -> Offer.HandBack
        // Then `taken`, which outranks a leftover refusal: if somebody has it, *why this device's last
        // claim failed* is no longer interesting and a Try again would be a press that cannot succeed.
        state.taken -> Offer.Elsewhere
        state.refusal == null -> Offer.Claim
        else -> Offer.Retry
    }

    /** What the bar is about, in the fewest words that are still true. `mine` first: a person holding
     *  the page needs to know that before anything else. */
    fun headline(state: BrowserHandover): String = when (offer(state)) {
        Offer.HandBack -> "You have this page"
        Offer.Elsewhere -> "Another device is answering this"
        Offer.Claim, Offer.Retry -> "The agent needs you on this page"
    }
}
