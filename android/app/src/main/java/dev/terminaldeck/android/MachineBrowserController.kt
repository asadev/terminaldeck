package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.BrowserWindowAction
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.InspectedElement
import dev.terminaldeck.android.protocol.MachineBrowserState
import dev.terminaldeck.android.protocol.MachineBrowserWire
import dev.terminaldeck.android.protocol.MachineProfileList
import dev.terminaldeck.android.protocol.MachineShot
import dev.terminaldeck.android.protocol.MachineWindow
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.RecordedStep
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.WindowSession

/**
 * The machine's **own** browser, as this phone drives it — the windows open on the machine's disk,
 * the sessions one could be bound to, the profiles the machine keeps, and the four answers a verb
 * carries a payload of its own.
 *
 * The client half of [Capability.BROWSER_CONTROL] and [Capability.BROWSER_PROFILES], a port of
 * `ios/TerminalDeck/Screens/MachineBrowserView.swift` + `MachineWindowView.swift` +
 * `MachineProfilesView.swift`. The distinction the whole feature holds: the Localhost tab's address
 * bar opens a **tunnel** — a machine port bound on this phone's loopback, the page loading in this
 * phone's own web view — while everything here drives the **machine's** Chromium, the phone sending
 * verbs and receiving pictures. The pictures themselves are [WatchController]'s job; this owns the
 * list, the profiles, and the three payload answers (a screenshot, an inspected element, a recorder's
 * steps).
 *
 * ## Every verb answers with the list
 *
 * A [MachineBrowserState] is the answer to every `browser.window.*` verb except the three with a
 * payload of their own, and a [MachineProfileList] is the answer to every `browser.profile.*` verb —
 * so the screen redrawing *is* the confirmation and there is nothing to reconcile. Nothing here is
 * optimistic against the machine: no row is removed and no badge drawn ahead of the machine agreeing
 * to it. The one exception is [asked] — a self-clearing line the home shows for a beat after an open
 * or an attach, because `browser.window.open`'s effect arrives asynchronously and the row can lag a
 * second behind the press.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this section's.
 */
class MachineBrowserController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
) {
    /** The machine's open windows and the sessions one could own — null until the first answer. */
    private var state: MachineBrowserState? = null
    private var requested = false

    /** The machine's browser profiles — null until the first answer; re-read on every appearance
     *  because this family has no unsolicited push. */
    private var profiles: MachineProfileList? = null

    /** The last screenshot handed back to *this phone* — the ones sent to a session never come here. */
    private var shot: MachineShot? = null

    /** The recorder's steps and the inspected element, per window: both are payload answers that do
     *  not ride the window list, so a screen holding one keeps it against the id it asked about. */
    private val steps = mutableMapOf<String, List<RecordedStep>>()
    private val picked = mutableMapOf<String, InspectedElement>()

    /** The window a `browser.window.pick` is out for, so its sheet can spin. Cleared by the answer,
     *  which is either the element or a [MachineBrowserState] carrying a sentence. */
    private var pickingWindow: String? = null

    /** The profile a `use`/`clear` is out for, so the whole list stops taking taps until it returns —
     *  there is no correlation id on this wire, so "the list changed" is the only completion signal. */
    private var working: String? = null

    /** The optimistic line the home shows for a beat after an open or attach. See the class header. */
    private var asked: String? = null
    private var askedCancel: (() -> Unit)? = null
    private var workingCancel: (() -> Unit)? = null

    fun offered(): Boolean = capabilities().contains(Capability.BROWSER_CONTROL)

    fun profilesOffered(): Boolean = capabilities().contains(Capability.BROWSER_PROFILES)

    /** A snapshot the home and the window screen read, or null over a machine that does not offer its
     *  browser for driving. Immutable so a redraw compares equal when nothing this screen reads moved. */
    fun view(): MachineBrowserView? {
        if (!offered()) return null
        return MachineBrowserView(
            windows = state?.windows.orEmpty(),
            sessions = state?.sessions.orEmpty(),
            notice = state?.notice,
            asked = asked,
            loaded = state != null,
            notDrawn = state?.notDrawn ?: 0,
            shot = shot,
            steps = steps.toMap(),
            picked = picked.toMap(),
            pickingWindow = pickingWindow,
        )
    }

    /** A snapshot the profiles screen reads, or null over a machine that does not offer its profiles. */
    fun profilesView(): MachineProfilesUiView? {
        if (!profilesOffered()) return null
        return MachineProfilesUiView(list = profiles, working = working)
    }

    /* ------------------------------------------------------------------ reads -- */

    /** Ask for the window list once, when the home opens. The `browser.surfaces` push is what keeps it
     *  fresh after that — a binding change or a navigation on the machine re-pushes the strip, and the
     *  overlay re-asks off it; the home has pull-to-refresh. */
    fun ensureRead() {
        if (!offered() || requested) return
        readWindows()
    }

    fun refresh() {
        if (!offered()) return
        readWindows()
    }

    /** Ask again for the window list — the overlay calls this off a `browser.surfaces` push, because
     *  the window list is only ever an answer and a window bound to a session on the machine would
     *  otherwise change nothing this phone holds. */
    fun readWindows() {
        if (!offered()) return
        if (!send(ClientMessage.BrowserWindows)) return
        requested = true
        onChange()
    }

    /** Read the machine's profiles. Sent on every appearance rather than once, because this family has
     *  no push — a profile made at the desk would otherwise never arrive. */
    fun readProfiles() {
        if (!profilesOffered()) return
        send(ClientMessage.BrowserProfiles)
    }

    /* ------------------------------------------------------------ window verbs -- */

    /**
     * Open a window on the machine. [session] opens it **and attaches it in one move** — the honest
     * way to attach a page a phone typed an address for, which lives in no machine window yet and has
     * no id to bind. Answered with a [MachineBrowserState].
     */
    fun openWindow(url: String?, isolated: Boolean = false, session: String? = null) {
        if (!offered()) return
        if (url != null && url.length > Protocol.MAX_URL_LENGTH) return
        if (!send(ClientMessage.BrowserWindowOpen(url = url, isolated = isolated, session = session))) return
        markAsked(if (session != null) "Opening a window for that session…" else "Opening a window…")
    }

    /** Send an open window somewhere. */
    fun go(id: String, url: String) {
        if (!offered() || id.isEmpty() || url.isEmpty() || url.length > Protocol.MAX_URL_LENGTH) return
        send(ClientMessage.BrowserWindowGo(id = id, url = url))
    }

    /** Back, forward, reload, close, record on/off, share or isolate — a closed set, because the host
     *  refuses a word it does not know. */
    fun act(id: String, action: BrowserWindowAction) {
        if (!offered() || id.isEmpty()) return
        send(ClientMessage.BrowserWindowAct(id = id, action = action))
    }

    /**
     * Lay a window's page out in a rectangle, in CSS pixels. Both numbers are clamped on the way out
     * so what a screen believes it asked for is what the machine was asked for — an over-range one is
     * silently changed host-side, which is the arithmetic this exists to fix, not to trip over.
     */
    fun size(id: String, width: Int, height: Int) {
        if (!offered() || id.isEmpty()) return
        send(
            ClientMessage.BrowserWindowSize(
                id = id,
                width = MachineBrowserWire.clampPageWidth(width),
                height = MachineBrowserWire.clampPageHeight(height),
            )
        )
    }

    /** Bind a window to a session, or unbind with a null [session] — the same frame, deliberately, so
     *  a client that meant to unbind and one whose field went missing are one message. */
    fun bind(id: String, session: String?) {
        if (!offered() || id.isEmpty()) return
        if (!send(ClientMessage.BrowserWindowBind(id = id, session = session))) return
        markAsked(if (session != null) "Attaching that window…" else "Detaching that window…")
    }

    /** Photograph the window. With a [session] the picture is handed to that session — its name typed
     *  into the transcript with the note — rather than coming back here as a [MachineShot]. */
    fun shot(id: String, session: String? = null, note: String? = null) {
        if (!offered() || id.isEmpty()) return
        send(ClientMessage.BrowserWindowShot(id = id, session = session, note = note?.ifBlank { null }))
    }

    /** What the recorder has collected on the window so far. Answered with a `browser.record.rows`. */
    fun readSteps(id: String) {
        if (!offered() || id.isEmpty()) return
        send(ClientMessage.BrowserWindowSteps(id = id))
    }

    /**
     * What is at one point on the window's page — the tap that says *change this*. [x]/[y] are
     * document coordinates. [up] is how many ancestors to walk and **must never** exceed the host's
     * limit, because it is checked in the host's parser and a parse failure closes the socket — so it
     * is clamped here. Answered with a `browser.window.picked`, or a [MachineBrowserState] carrying a
     * sentence when the page has moved out from under the tap.
     */
    fun pick(id: String, x: Double, y: Double, up: Int = 0) {
        if (!offered() || id.isEmpty()) return
        if (!send(ClientMessage.BrowserWindowPick(id = id, x = x, y = y, up = MachineBrowserWire.clampPickUp(up)))) return
        pickingWindow = id
        onChange()
    }

    /**
     * Forget the last element pointed at in one window — the screen leaving inspect mode, or the sheet
     * that describes the element being dismissed. The twin of iOS's `clearMachinePick`: an element
     * left behind is a description of something nobody is asking about any more, and Wider on it would
     * walk a chain measured against a page that has since scrolled.
     */
    fun clearPicked(id: String) {
        val had = picked.remove(id) != null
        val wasAsking = pickingWindow == id
        if (wasAsking) pickingWindow = null
        if (had || wasAsking) onChange()
    }

    /* ----------------------------------------------------------- profile verbs -- */

    /** Switch the machine's browser to a profile — it decides which cookie jar the **next** page opens
     *  into. Answered with the whole [MachineProfileList], which is how the screen confirms itself. */
    fun useProfile(id: String) {
        if (!profilesOffered() || working != null) return
        if (!send(ClientMessage.BrowserProfileUse(id))) return
        markWorking(id)
    }

    /** Empty one profile's jar on the machine — signs that machine's browser out of everything in it,
     *  and touches nothing this phone holds. */
    fun clearProfile(id: String) {
        if (!profilesOffered() || working != null) return
        if (!send(ClientMessage.BrowserProfileClear(id))) return
        markWorking(id)
    }

    /* --------------------------------------------------------------- receiving -- */

    fun receive(message: ServerMessage): Boolean = when (message) {
        is MachineBrowserState -> {
            state = message
            requested = true
            // A window verb answered, so any optimistic line has done its job — the real list is here.
            clearAsked()
            // A pick that failed comes back as this rather than an element, so the spinner stops.
            pickingWindow = null
            onChange()
            true
        }

        is MachineShot -> {
            shot = message
            onChange()
            true
        }

        is MachineProfileList -> {
            profiles = message
            clearWorking()
            onChange()
            true
        }

        is ServerMessage.BrowserWindowPicked -> {
            picked[message.id] = message.element
            if (pickingWindow == message.id) pickingWindow = null
            onChange()
            true
        }

        is ServerMessage.BrowserRecordRows -> {
            steps[message.id] = message.steps
            onChange()
            true
        }

        else -> false
    }

    /* ------------------------------------------------------------------ notice -- */

    private fun markAsked(line: String) {
        asked = line
        askedCancel?.invoke()
        askedCancel = expiry.after(ASKED_MS) {
            askedCancel = null
            asked = null
            onChange()
        }
        onChange()
    }

    private fun clearAsked() {
        askedCancel?.invoke()
        askedCancel = null
        asked = null
    }

    private fun markWorking(id: String) {
        working = id
        workingCancel?.invoke()
        // A backstop: if the answering list never comes the row cannot sit at "Clearing…" for ever.
        workingCancel = expiry.after(WORKING_MS) {
            workingCancel = null
            working = null
            onChange()
        }
        onChange()
    }

    private fun clearWorking() {
        workingCancel?.invoke()
        workingCancel = null
        working = null
    }

    /**
     * A fresh welcome: forget the last machine's browser.
     *
     * The windows, the profiles and the payload answers all belong to whichever machine this
     * connection reaches, and a guest is not told the capability exists — so a list left over from the
     * machine before would be one computer's windows drawn under another's name.
     */
    fun renew() {
        clearAsked()
        clearWorking()
        state = null
        profiles = null
        shot = null
        steps.clear()
        picked.clear()
        pickingWindow = null
        requested = false
        onChange()
    }

    fun stop() {
        clearAsked()
        clearWorking()
    }

    private companion object {
        const val ASKED_MS = 2_500L
        const val WORKING_MS = 30_000L
    }
}

/**
 * What the Machine Browser home and the driven-window screen read.
 *
 * [loaded] tells an empty list apart from an unknown one — "nothing is open" and "not asked yet" are
 * different sentences. [asked] is the optimistic beat after an open or attach; [notice] is the
 * machine's own word on the last answer. [steps]/[picked] are keyed by window id because they are
 * payload answers that do not ride the list.
 */
data class MachineBrowserView(
    val windows: List<MachineWindow>,
    val sessions: List<WindowSession>,
    val notice: String?,
    val asked: String?,
    val loaded: Boolean,
    val notDrawn: Int,
    val shot: MachineShot?,
    val steps: Map<String, List<RecordedStep>>,
    val picked: Map<String, InspectedElement>,
    val pickingWindow: String?,
) {
    /** The window with this id, resolved on every redraw rather than captured — every verb answers
     *  with the whole list, so a value held from an earlier answer would name a closed window. */
    fun window(id: String): MachineWindow? = windows.firstOrNull { it.id == id }

    /** The window a session holds, if the machine says there is one. Drives the in-session overlay. */
    fun windowFor(session: String): MachineWindow? = windows.firstOrNull { it.session == session }
}

/** What the Machine Profiles screen reads. [list] null means "reading…"; [working] is the profile a
 *  switch or clear is out for, which stops the whole screen taking taps until the list returns. */
data class MachineProfilesUiView(
    val list: MachineProfileList?,
    val working: String?,
)
