package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.LocalPort
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * What is listening on the machine, and the one thing a phone can honestly do about it.
 *
 * Two capabilities behind one screen, because to a person they are one question. [Capability
 * .LOCALHOST] answers *what is running over there*; [Capability.WEB] is what a tap on a row does —
 * the page opens **on the machine**, in that machine's own browser, and the device holding the phone
 * is driving rather than viewing.
 *
 * ## Why opening on the machine is the honest verb
 *
 * `pwa/src/localhost.ts` opens by rejecting three ways round the fact that a browser tab cannot
 * listen on a socket, and concludes — correctly — that a client can say which ports are open and
 * whether one answers, and cannot serve through them. Asad's complaint about that was the right one:
 *
 *   > *"Localhost lists ports with no way to open any of them. The whole reason localhost exists is
 *   > to drive them."*
 *
 * and his answer, in the same review:
 *
 *   > *"A browser started from the phone must run on the machine you are inside — a live link or a
 *   > localhost link both open on the connected machine."*
 *
 * So a row's tap is a `web.open` of `http://localhost:<port>`, and what comes back is `web.opened` —
 * sent only once a tab was actually made, so the sentence this draws is about something that
 * happened. A refusal is an ordinary `error`. The host refuses anything that is not http(s) and
 * refuses a guest outright; neither is second-guessed here.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this section's.
 */
class LocalhostController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
) {
    private var ports: List<LocalPort>? = null
    private var requested = false

    /** The port whose row is mid-open, so its button reads "Opening…" and a second press is inert. */
    private var opening: Int? = null
    private var notice: ActionNotice? = null

    private var readCancel: (() -> Unit)? = null
    private var openCancel: (() -> Unit)? = null
    private var confirmCancel: (() -> Unit)? = null

    fun offered(): Boolean = capabilities().contains(Capability.LOCALHOST)

    /** Whether a row may be tapped at all. A list with no way to open one is still worth drawing. */
    fun canOpen(): Boolean = capabilities().contains(Capability.WEB)

    fun view(): LocalhostView? {
        if (!offered()) return null
        return LocalhostView(ports = ports, canOpen = canOpen(), opening = opening, notice = notice)
    }

    /**
     * Ask once when the screen opens.
     *
     * There is no push for this list — nothing on the wire says "a port appeared" — so a refresh is
     * a person's own act, which is why [refresh] exists and a timer does not.
     */
    fun ensureRead() {
        if (!offered() || requested) return
        ask()
    }

    fun refresh() {
        if (!offered()) return
        ask()
    }

    fun renew() {
        stop()
        ports = null
        requested = false
        opening = null
        notice = null
        onChange()
    }

    private fun ask() {
        if (!offered()) return
        if (!send(ClientMessage.Ports)) return
        requested = true
        readCancel?.invoke()
        readCancel = expiry.after(READ_TIMEOUT_MS) {
            readCancel = null
            // A read nobody answered keeps the previous list — it is still the last thing the
            // machine genuinely said — and the next visit tries again.
            requested = false
        }
    }

    /**
     * Open a listening port on the machine.
     *
     * The URL is composed here rather than taken from anywhere, because it is the one place that can
     * guarantee the shape the host will accept: `http://localhost:<port>`, with the port checked
     * against the range the wire allows before a frame is spent on it.
     */
    fun open(port: Int) {
        if (!canOpen() || opening != null) return
        if (port < Protocol.MIN_PORT || port > Protocol.MAX_PORT) return
        openUrl("http://localhost:$port", port)
    }

    /**
     * Open an arbitrary page on the machine — what a dev server's own `url` is opened through.
     *
     * [marker] is the row to lock while it is in flight, or null for a call from somewhere with no
     * row of its own.
     */
    fun openUrl(url: String, marker: Int? = null) {
        if (!canOpen() || opening != null) return
        if (url.isEmpty() || url.length > Protocol.MAX_URL_LENGTH) return
        if (!send(ClientMessage.WebOpen(url))) {
            say(ActionNotice(false, NOT_CONNECTED))
            onChange()
            return
        }
        opening = marker ?: OPENING_ANY
        notice = null
        openCancel?.invoke()
        openCancel = expiry.after(OPEN_TIMEOUT_MS) {
            openCancel = null
            opening = null
            say(ActionNotice(false, NO_ANSWER))
            onChange()
        }
        onChange()
    }

    private fun say(next: ActionNotice?) {
        notice = next
        confirmCancel?.invoke()
        confirmCancel = null
        if (next != null && next.ok) {
            confirmCancel = expiry.after(CONFIRM_MS) {
                confirmCancel = null
                notice = null
                onChange()
            }
        }
    }

    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.Ports -> {
                readCancel?.invoke()
                readCancel = null
                requested = true
                ports = message.ports
                onChange()
                return true
            }
            is ServerMessage.WebOpened -> {
                openCancel?.invoke()
                openCancel = null
                opening = null
                // The host's own url, echoed back, so what is confirmed is what was actually
                // opened rather than what was asked for.
                say(ActionNotice(true, "Opened ${message.url} on the machine."))
                onChange()
                return true
            }
            else -> return false
        }
    }

    /**
     * A refusal came back as a plain `error`.
     *
     * There is no `web.failed` — the three ways `web.open` can fail are all things `error` already
     * says with a code and a sentence — so the view model hands the error here rather than only
     * putting it in a snackbar, or a row would sit at "Opening…" forever after a refusal.
     */
    fun failed(sentence: String) {
        if (opening == null) return
        openCancel?.invoke()
        openCancel = null
        opening = null
        say(ActionNotice(false, sentence))
        onChange()
    }

    fun stop() {
        readCancel?.invoke()
        readCancel = null
        openCancel?.invoke()
        openCancel = null
        confirmCancel?.invoke()
        confirmCancel = null
    }

    companion object {
        const val READ_TIMEOUT_MS = 20_000L
        const val OPEN_TIMEOUT_MS = 30_000L
        private const val CONFIRM_MS = 4_000L

        /** The marker for an open with no port row behind it — a dev server's own url. */
        const val OPENING_ANY = -1

        const val NOT_CONNECTED = "Not connected right now, so nothing was sent."
        const val NO_ANSWER = "That machine did not answer, so nothing was opened."
    }
}

/** What the Localhost screen reads. [ports] null means "reading…"; empty means nothing is listening. */
data class LocalhostView(
    val ports: List<LocalPort>?,
    val canOpen: Boolean,
    val opening: Int?,
    val notice: ActionNotice?,
)
