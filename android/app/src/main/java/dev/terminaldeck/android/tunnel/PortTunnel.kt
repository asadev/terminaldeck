package dev.terminaldeck.android.tunnel

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Base64
import java.util.UUID

/**
 * The phone's half of "see the machine's localhost on your phone".
 *
 * A port on the machine is made to exist on the phone, **at the same number**, by listening on this
 * device's own loopback and copying every byte across the connection that is already open. A
 * `WebView` is then pointed at `http://127.0.0.1:<port>/` and, as far as it is concerned, that is
 * simply where the site is.
 *
 * A transcription of `ios/TerminalDeck/Tunnel/PortTunnel.swift`, which is itself the phone half of
 * `src/main/remote/tunnel.ts`. The reasoning below is that file's and is repeated because it is the
 * part that is easy to get wrong twice.
 *
 * ## Why a byte pipe and not an HTTP client
 *
 * The obvious version fetches the page and hands it to the web view. It fails immediately and for
 * good: the page's own `fetch` calls, its stylesheets, its images and — the one that matters — its
 * **hot-reload WebSocket** all go wherever the page's origin says, which is a port on `localhost`.
 * Unless something is really listening there, the site is a screenshot.
 *
 * So this listens for real, and forwards bytes without reading them. The WebSocket upgrade is bytes.
 * Chunked transfer is bytes. Server-sent events are bytes. Nothing here has to know what any of them
 * are, which is why nothing here can get them wrong.
 *
 * ## Why the port number has to match
 *
 * A dev server puts absolute URLs in its own output — a redirect to `http://localhost:3000/login`, a
 * websocket at `ws://localhost:3000/_next/hmr`, a cookie scoped to a port. Serve the same site on a
 * different port on the phone and every one of those escapes the tunnel and fails, in ways that look
 * like the framework being broken. Matching the number is not a nicety; it is the reason this works
 * at all. When the number is unavailable, this says so rather than quietly choosing another and
 * half-working.
 *
 * ## Flow control
 *
 * Each side acknowledges what it has written to its own socket, and the reader stops pulling while
 * more than [Protocol.NET_WINDOW_BYTES] is outstanding. Without it a phone loading a 40 MB source
 * map would have the whole file buffered in the desktop's heap and the desktop would answer by
 * dropping the phone.
 */
class PortTunnel(
    val port: Int,
    private val send: (ClientMessage) -> Boolean,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val openTimeoutMs: Long = OPEN_TIMEOUT_MS,
    /** Seam for the tests, which bind a real loopback socket and want a port they chose. */
    private val listenPort: Int = port,
    val id: String = UUID.randomUUID().toString(),
) {

    /**
     * Where a tunnel is in its short life. Every case a screen can be in, and each one carries the
     * sentence that screen should be showing.
     */
    sealed interface Phase {
        /** `tunnel.open` is on the wire; the machine has not answered yet. */
        data object Opening : Phase

        /** Serving. [url] is what the web view should load. */
        data class Live(val url: String) : Phase

        /** It never started, or it ended. [detail] is for the person, not the log. */
        data class Ended(val detail: String) : Phase
    }

    private val lock = Any()

    private var phaseState: Phase = Phase.Opening
    private var listener: ServerSocket? = null
    private val streams = LinkedHashMap<String, Stream>()
    private var finished = false
    private var cancelDeadline: (() -> Unit)? = null

    val phase: Phase get() = synchronized(lock) { phaseState }

    /**
     * Browser connections currently open through this tunnel.
     *
     * Shown, because a page that is quietly still talking — a hot-reload socket — is the difference
     * between "this stopped working" and "this is working and has nothing to say".
     */
    val streamCount: Int get() = synchronized(lock) { streams.size }

    /**
     * Ask the machine for the port. Nothing is bound until it says yes: a listener standing open for
     * a tunnel that was refused would accept a browser connection it can do nothing with.
     */
    fun start() {
        if (!send(ClientMessage.TunnelOpen(id, port))) {
            end("The connection to the machine is not up.", tellHost = false)
            return
        }
        /*
         * The deadline is armed by the *send*, not by the constructor, so a tunnel that was never
         * asked for cannot expire — and it is cancelled by [end], so a tunnel that opened and was
         * later closed does not have a timer still holding a reference to it twenty seconds later.
         *
         * `tellHost = true`, because from this end the frame was sent and may well have arrived: a
         * machine that is merely slow would otherwise be left holding a tunnel this phone has
         * forgotten, and it has no way to discover that on its own.
         */
        synchronized(lock) {
            cancelDeadline = expiry.after(openTimeoutMs) {
                if (phase is Phase.Opening) {
                    end(
                        "The machine did not answer about port $port. It may be running a version " +
                            "that cannot share its ports.",
                        tellHost = true,
                    )
                }
            }
        }
    }

    /** The user closed the view, or the app is going away. */
    fun stop() = end("Closed.", tellHost = true)

    /**
     * The connection to the machine went down.
     *
     * Every stream through it is dead, and saying so beats a browser spinner that never resolves.
     * Nothing is sent: the wire that would carry it is the thing that broke.
     */
    fun connectionLost(detail: String) = end(detail, tellHost = false)

    /**
     * A frame from the machine. True when it belonged to this tunnel.
     *
     * Returning a boolean rather than filtering upstream keeps the routing in one place: the view
     * model has no idea which channel ids are whose, and giving it one would be a second copy of
     * this map to keep in step.
     */
    fun receive(message: ServerMessage): Boolean = when (message) {
        is ServerMessage.TunnelOpened -> if (message.id == id) { begin(); true } else false
        // The machine decided, so it is not told again.
        is ServerMessage.TunnelClosed -> if (message.id == id) {
            end(message.message.ifEmpty { "The machine closed it." }, tellHost = false)
            true
        } else {
            false
        }
        is ServerMessage.NetData -> stream(message.ch)?.let { it.write(message.data); true } ?: false
        is ServerMessage.NetAck -> stream(message.ch)?.let { it.acknowledge(message.bytes); true } ?: false
        is ServerMessage.NetClose -> if (stream(message.ch) != null) { drop(message.ch, tell = false); true } else false
        else -> false
    }

    private fun stream(ch: String): Stream? = synchronized(lock) { streams[ch] }

    /* ------------------------------------------------------------------ listening -- */

    private fun begin() {
        synchronized(lock) {
            if (finished || phaseState !is Phase.Opening) return
            // The machine answered, so the deadline has nothing left to protect against.
            cancelDeadline?.invoke()
            cancelDeadline = null
        }
        scope.launch(io) { bind() }
    }

    /**
     * Listen on this phone's loopback, at the port the machine serves on.
     *
     * The address is `127.0.0.1` and nothing else. Binding the wildcard would take every interface
     * the phone has, which on a café's wifi is a stranger's route into a server on somebody's Mac —
     * so the bind address is stated rather than defaulted.
     *
     * A port already in use is refused with a sentence rather than worked around: serving the site
     * on a different number breaks every absolute URL the framework writes for itself, and a page
     * that half-works is harder to understand than one that says why it did not open.
     */
    private fun bind() {
        if (port < Protocol.MIN_PORT || port > Protocol.MAX_PORT) {
            end("$port is not a port this phone can listen on.", tellHost = true)
            return
        }
        val loopback = InetAddress.getByName("127.0.0.1")
        val bound = try {
            ServerSocket(listenPort, BACKLOG, loopback)
        } catch (error: IOException) {
            end(refusal(error), tellHost = true)
            return
        } catch (error: SecurityException) {
            end(refusal(error), tellHost = true)
            return
        }
        val settled = synchronized(lock) {
            if (finished) return@synchronized false
            listener = bound
            phaseState = Phase.Live("http://127.0.0.1:${bound.localPort}/")
            true
        }
        if (!settled) {
            closeQuietly(bound)
            return
        }
        onChange()
        accept(bound)
    }

    /**
     * Why the phone could not listen, in a sentence a person can act on.
     *
     * Two causes and they have different fixes: a port under 1024 is one Android will never let an
     * app hold, and any other refusal is something else on this phone already holding the number.
     */
    private fun refusal(error: Exception): String = when {
        port < PRIVILEGED_PORTS -> "Port $port is one Android reserves for the system, so this phone " +
            "cannot serve the machine's page at the address its own links point at."
        else -> "Port $port is already in use on this phone, so the page cannot be served at the " +
            "address the machine's server writes into its own links. Close whatever is using it and " +
            "tap again. (${error.message ?: "refused"})"
    }

    /** The accept loop. Ends when the listener is closed, which is what [end] does to stop it. */
    private fun accept(listener: ServerSocket) {
        while (true) {
            val socket = try {
                listener.accept()
            } catch (_: IOException) {
                return
            }
            if (!open(socket)) {
                closeQuietly(socket)
                return
            }
        }
    }

    /** One browser connection, admitted. False when the wire refused it and the tunnel is over. */
    private fun open(socket: Socket): Boolean {
        val ch = UUID.randomUUID().toString()
        val live = synchronized(lock) { !finished && phaseState is Phase.Live }
        if (!live) return false
        if (!send(ClientMessage.NetOpen(ch, id))) {
            end("The connection to the machine is not up.", tellHost = false)
            return false
        }
        // Hot-reload notices are forty bytes. Nagle would sit on each one waiting for company.
        try {
            socket.tcpNoDelay = true
        } catch (_: IOException) {
            // A socket that will not take the option still copies bytes. Not worth refusing over.
        }
        val stream = Stream(ch, socket)
        synchronized(lock) { streams[ch] = stream }
        stream.start()
        onChange()
        return true
    }

    private fun drop(ch: String, tell: Boolean) {
        val stream = synchronized(lock) { streams.remove(ch) } ?: return
        stream.cancel()
        if (tell) send(ClientMessage.NetClose(ch))
        onChange()
    }

    /**
     * Take the tunnel down, once.
     *
     * [tellHost] is false only when the machine already knows — it closed the tunnel itself, or the
     * connection carrying the message is the thing that broke. Every other path has to send: a
     * tunnel this phone abandoned quietly would leave a socket open on somebody's machine for a page
     * nobody is looking at.
     */
    private fun end(detail: String, tellHost: Boolean) {
        val (cancel, closing, socket) = synchronized(lock) {
            if (finished) return
            finished = true
            val cancel = cancelDeadline
            cancelDeadline = null
            val closing = streams.values.toList()
            streams.clear()
            val socket = listener
            listener = null
            phaseState = Phase.Ended(detail)
            Triple(cancel, closing, socket)
        }
        // Before anything else, and unconditionally: this runs on every path out of `opening`, and a
        // deadline left armed would fire later into a guard that has to be right rather than into
        // nothing.
        cancel?.invoke()
        if (tellHost) send(ClientMessage.TunnelClose(id))
        for (stream in closing) stream.cancel()
        socket?.let { closeQuietly(it) }
        onChange()
    }

    /**
     * One browser connection, and the two halves of copying it.
     *
     * Split out because the bookkeeping is per-socket and the lifetime is not: a page reloads a
     * dozen times through one tunnel, and a WebSocket outlives every one of those reloads.
     */
    private inner class Stream(private val ch: String, private val socket: Socket) {

        /**
         * Bytes written toward the browser, in order.
         *
         * A queue and one writer rather than a coroutine per frame, because HTTP is a byte stream:
         * two writes that raced would interleave a response with itself, which is not a bug that
         * looks like a bug — it looks like the framework being broken.
         */
        private val outbound = Channel<ByteArray>(Channel.UNLIMITED)

        /** Bytes sent to the machine that it has not said it has written yet. */
        private var unacked = 0
        private val window = Object()
        private var done = false

        fun start() {
            scope.launch(io) { pump() }
            scope.launch(io) { drain() }
        }

        /** Bytes from the machine, on their way to the browser. */
        fun write(data: String) {
            if (data.isEmpty()) return
            val bytes = try {
                Base64.getDecoder().decode(data)
            } catch (_: IllegalArgumentException) {
                // Refused rather than repaired: the parser already checked the alphabet, so a string
                // that fails here is a frame that lied, and guessing at its bytes would put invented
                // ones into somebody's HTTP response.
                return
            }
            if (bytes.isEmpty()) return
            outbound.trySend(bytes)
        }

        fun acknowledge(bytes: Int) {
            synchronized(window) {
                unacked = maxOf(0, unacked - bytes)
                // The read that was not armed while the window was full is armed now.
                (window as Object).notifyAll()
            }
        }

        fun cancel() {
            synchronized(window) {
                if (done) return
                done = true
                (window as Object).notifyAll()
            }
            outbound.close()
            closeQuietly(socket)
        }

        /** Browser → machine. Blocks on the window rather than buffering into the heap. */
        private fun pump() {
            val input = try {
                socket.getInputStream()
            } catch (_: IOException) {
                finish()
                return
            }
            val buffer = ByteArray(Protocol.MAX_NET_CHUNK_BYTES)
            while (true) {
                synchronized(window) {
                    while (!done && unacked >= Protocol.NET_WINDOW_BYTES) {
                        try {
                            (window as Object).wait(WINDOW_WAIT_MS)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            return
                        }
                    }
                }
                if (synchronized(window) { done }) return
                val read = try {
                    input.read(buffer, 0, buffer.size)
                } catch (_: IOException) {
                    finish()
                    return
                }
                if (read <= 0) {
                    // The browser closed its half. There is no half-open state worth keeping: the
                    // response it was waiting for has nowhere to go.
                    finish()
                    return
                }
                synchronized(window) { unacked += read }
                val slice = buffer.copyOfRange(0, read)
                if (!send(ClientMessage.NetData(ch, Base64.getEncoder().encodeToString(slice)))) {
                    finish()
                    return
                }
            }
        }

        /** Machine → browser, in order, acknowledged once this phone's socket has taken it. */
        private suspend fun drain() {
            val output = try {
                socket.getOutputStream()
            } catch (_: IOException) {
                finish()
                return
            }
            for (bytes in outbound) {
                if (synchronized(window) { done }) return
                try {
                    output.write(bytes)
                    output.flush()
                } catch (_: IOException) {
                    finish()
                    return
                }
                // Acknowledged once the socket has taken it, so the machine's window is measuring
                // this phone's appetite rather than measuring nothing.
                send(ClientMessage.NetAck(ch, bytes.size))
            }
        }

        private fun finish() {
            val already = synchronized(window) { done }
            if (already) return
            drop(ch, tell = true)
        }
    }

    companion object {
        /**
         * How long the machine has to answer `tunnel.open` before this gives up.
         *
         * Twenty seconds, and it is four times the longest the far end can honestly take: `tunnel.ts`
         * re-scans the machine's ports and then makes a real TCP connection to prove the address
         * answers, with a five-second dial timeout, and the relay round trip is milliseconds either
         * side of that. So this cannot fire on a slow-but-working machine.
         *
         * There is a deadline at all because without one there is a state with no exit. Every
         * *answered* outcome is handled — `tunnel.opened` binds, `tunnel.closed` says why, a dropped
         * socket calls [connectionLost] — and the case that was missing is the machine saying
         * **nothing at all**, which is what a desktop old enough to advertise `localhost` without
         * having the tunnel hub wired does with this frame: it parses it and drops it.
         */
        const val OPEN_TIMEOUT_MS = 20_000L

        /** Ports below this are the system's on Android. An app binding one gets an exception. */
        private const val PRIVILEGED_PORTS = 1024

        private const val BACKLOG = 32

        /**
         * The window wait is bounded rather than indefinite.
         *
         * A `net.ack` that never arrives — the machine went away between one frame and the next — is
         * not a reason for a reader thread to sit in `wait()` forever holding a socket open. The
         * loop re-checks `done` on every wake, so the cost of the bound is one wake a second on a
         * stream that is genuinely paused.
         */
        private const val WINDOW_WAIT_MS = 1_000L

        internal fun closeQuietly(socket: Socket) {
            try {
                socket.close()
            } catch (_: IOException) {
                // Closing something already closed is the ordinary case here, not a failure.
            }
        }

        internal fun closeQuietly(socket: ServerSocket) {
            try {
                socket.close()
            } catch (_: IOException) {
                // As above.
            }
        }

        /** Whether something already answers on this phone's loopback at [port]. */
        internal fun answers(port: Int, timeoutMs: Int = 300): Boolean = try {
            Socket().use {
                it.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), timeoutMs)
                true
            }
        } catch (_: IOException) {
            false
        }
    }
}
