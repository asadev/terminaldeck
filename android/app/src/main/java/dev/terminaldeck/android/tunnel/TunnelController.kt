package dev.terminaldeck.android.tunnel

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

/**
 * What a screen draws when it is showing one of the machine's ports.
 *
 * [url] is null until the tunnel is serving, and [detail] is non-null only once it has ended — so a
 * screen never has to decide between three booleans which sentence it is in.
 */
data class TunnelView(
    val port: Int,
    val url: String? = null,
    val detail: String? = null,
    val streams: Int = 0,
) {
    val opening: Boolean get() = url == null && detail == null
    val live: Boolean get() = url != null
}

/**
 * One tunnel at a time, per machine.
 *
 * A phone shows one page. Holding a table of tunnels would mean a socket on somebody's machine for
 * every port ever tapped, kept alive by a screen that is no longer on top — so opening a second
 * closes the first, which is what a person pressing a different port means.
 *
 * The controller exists rather than the screen owning a [PortTunnel] directly because the frames
 * arrive on the machine's connection, not on the screen: `net.data` for a page has to reach the
 * tunnel whether or not the composable that opened it is currently in composition.
 */
class TunnelController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val scope: CoroutineScope,
    private val onChange: () -> Unit,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {

    private var tunnel: PortTunnel? = null

    /** Whether this machine will tunnel at all. Nothing is drawn over one that did not say so. */
    fun canTunnel(): Boolean = capabilities().contains(Capability.LOCALHOST)

    /**
     * A snapshot, or null when no page is open.
     *
     * Null rather than an empty view, so a screen that is not showing a page has nothing to draw
     * rather than a card explaining that it is not showing one.
     */
    fun view(): TunnelView? {
        val open = tunnel ?: return null
        return when (val phase = open.phase) {
            is PortTunnel.Phase.Opening -> TunnelView(open.port, streams = open.streamCount)
            is PortTunnel.Phase.Live -> TunnelView(open.port, url = phase.url, streams = open.streamCount)
            is PortTunnel.Phase.Ended -> TunnelView(open.port, detail = phase.detail, streams = open.streamCount)
        }
    }

    /** Open one of the machine's ports here. Closes whatever was open, which is what a tap means. */
    fun open(port: Int) {
        if (!canTunnel()) return
        close()
        val next = PortTunnel(
            port = port,
            send = send,
            expiry = expiry,
            onChange = onChange,
            scope = scope,
            io = io,
        )
        tunnel = next
        onChange()
        next.start()
    }

    /** The screen closed. The machine is told, so it is not left holding a socket. */
    fun close() {
        val open = tunnel ?: return
        tunnel = null
        open.stop()
        onChange()
    }

    /**
     * A frame from the machine.
     *
     * Unclaimed frames are dropped rather than logged: `net.data` for a channel this side has
     * forgotten is the ordinary result of a page being closed while bytes were in flight, and it is
     * the far end's next `net.close` that settles it.
     */
    fun receive(message: ServerMessage) {
        tunnel?.receive(message)
    }

    /** The socket went. Every stream through it is dead, and saying so beats a spinner. */
    fun connectionLost(detail: String) {
        tunnel?.connectionLost(detail)
        onChange()
    }

    fun stop() {
        tunnel?.connectionLost("Closed.")
        tunnel = null
    }
}
