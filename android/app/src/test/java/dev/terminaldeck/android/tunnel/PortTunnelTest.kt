package dev.terminaldeck.android.tunnel

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The tunnel, driven against a **real loopback socket**.
 *
 * A stubbed socket layer would prove that the code calls the functions it calls. What has to be
 * proven is that a browser connecting to `127.0.0.1:<port>` on this device produces `net.open` and
 * `net.data` on the wire, and that bytes coming the other way arrive at that socket in order — and
 * the only honest way to prove that is to open one. `ServerSocket` and `Socket` are `java.net`, so
 * this runs in the ordinary unit-test JVM with no device and no emulator.
 *
 * The deadline is a [FakeExpiry] rather than the real twenty seconds, which is this repository's own
 * rule about timing: a test that waited would either be twenty seconds long or be proving a
 * different number.
 */
class PortTunnelTest {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @After
    fun tearDown() {
        scope.cancel()
    }

    /** A clock somebody can move by hand. Returns the cancel, exactly as the real one does. */
    private class FakeExpiry : Expiry {
        private val armed = mutableListOf<Pair<Long, () -> Unit>>()
        override fun after(ms: Long, onExpired: () -> Unit): () -> Unit {
            val entry = ms to onExpired
            armed += entry
            return { armed.remove(entry) }
        }

        val pending: Int get() = armed.size

        fun fire() {
            val due = armed.toList()
            armed.clear()
            for ((_, run) in due) run()
        }
    }

    private class Wire {
        val sent = CopyOnWriteArrayList<ClientMessage>()
        var connected = true
        fun send(message: ClientMessage): Boolean {
            if (!connected) return false
            sent += message
            return true
        }

        inline fun <reified T : ClientMessage> only(): List<T> = sent.filterIsInstance<T>()
    }

    /** A port nothing is on, taken by binding and letting go — the same trick the JDK's own tests use. */
    private fun freePort(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }

    /** Wait for a condition without a fixed sleep. Real sockets settle in microseconds. */
    private fun waitFor(what: String, timeoutMs: Long = 4_000, check: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (check()) return
            Thread.sleep(5)
        }
        throw AssertionError("timed out waiting for $what")
    }

    private fun tunnel(wire: Wire, expiry: Expiry, port: Int): PortTunnel = PortTunnel(
        port = port,
        send = wire::send,
        expiry = expiry,
        onChange = {},
        scope = scope,
        openTimeoutMs = PortTunnel.OPEN_TIMEOUT_MS,
    )

    @Test
    fun `nothing is bound until the machine says yes`() {
        val wire = Wire()
        val expiry = FakeExpiry()
        val port = freePort()
        val tunnel = tunnel(wire, expiry, port)

        tunnel.start()

        // The frame went, and it named the port and this tunnel's own id.
        val open = wire.only<ClientMessage.TunnelOpen>().single()
        assertEquals(port, open.port)
        assertEquals(tunnel.id, open.id)
        // A listener standing open for a tunnel that was refused would accept a browser connection
        // it can do nothing with — so nothing is listening yet.
        assertTrue(tunnel.phase is PortTunnel.Phase.Opening)
        assertNull("nothing should be listening yet", connectOrNull(port))
        tunnel.stop()
    }

    @Test
    fun `a machine that never answers is given up on, and the machine is told`() {
        val wire = Wire()
        val expiry = FakeExpiry()
        val tunnel = tunnel(wire, expiry, freePort())

        tunnel.start()
        assertEquals("the deadline is armed by the send", 1, expiry.pending)
        expiry.fire()

        val phase = tunnel.phase
        assertTrue(phase is PortTunnel.Phase.Ended)
        assertTrue((phase as PortTunnel.Phase.Ended).detail.contains("did not answer"))
        // `tellHost = true`: from this end the frame was sent and may well have arrived, and a
        // machine that is merely slow would otherwise hold a tunnel this phone has forgotten.
        assertEquals(1, wire.only<ClientMessage.TunnelClose>().size)
    }

    @Test
    fun `the deadline is cancelled the moment the machine answers`() {
        val wire = Wire()
        val expiry = FakeExpiry()
        val port = freePort()
        val tunnel = tunnel(wire, expiry, port)

        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        assertEquals("a settled tunnel holds no timer", 0, expiry.pending)
        // Firing a deadline that has been cancelled must do nothing at all.
        expiry.fire()
        assertTrue(tunnel.phase is PortTunnel.Phase.Live)
        tunnel.stop()
    }

    @Test
    fun `the page is served at the same port number the machine uses`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)

        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        // Matching the number is not a nicety: a dev server writes absolute URLs into its own
        // redirects, cookies and hot-reload sockets, and every one of them escapes a tunnel served
        // on a different number.
        assertEquals("http://127.0.0.1:$port/", (tunnel.phase as PortTunnel.Phase.Live).url)
        tunnel.stop()
    }

    @Test
    fun `a browser connection opens a stream and its bytes reach the wire`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)

        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        val browser = connectOrNull(port)
        assertNotNull("the tunnel should be accepting", browser)
        browser!!.use { socket ->
            waitFor("net.open") { wire.only<ClientMessage.NetOpen>().isNotEmpty() }
            val opened = wire.only<ClientMessage.NetOpen>().single()
            assertEquals(tunnel.id, opened.tunnel)
            // `net.open` is sent *before* the stream is registered — deliberately, so a send the
            // wire refuses creates nothing — which means the frame can be observed a moment before
            // the count moves. Waited for rather than asserted on the same tick.
            waitFor("the stream to be counted") { tunnel.streamCount == 1 }

            socket.getOutputStream().write("GET / HTTP/1.1\r\n\r\n".toByteArray())
            socket.getOutputStream().flush()

            waitFor("net.data") { wire.only<ClientMessage.NetData>().isNotEmpty() }
            val data = wire.only<ClientMessage.NetData>().first()
            assertEquals(opened.ch, data.ch)
            // Forwarded without being read: the whole point is that nothing here has to know what
            // an HTTP request, a WebSocket upgrade or a chunked body is.
            assertEquals("GET / HTTP/1.1\r\n\r\n", String(Base64.getDecoder().decode(data.data)))
        }
        tunnel.stop()
    }

    @Test
    fun `bytes from the machine arrive at the browser in order, and are acknowledged`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)

        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        connectOrNull(port)!!.use { socket ->
            waitFor("net.open") { wire.only<ClientMessage.NetOpen>().isNotEmpty() }
            val ch = wire.only<ClientMessage.NetOpen>().single().ch

            // Two writes, because the failure this guards against is a response interleaved with
            // itself — which is not a bug that looks like a bug, it looks like the framework being
            // broken.
            tunnel.receive(ServerMessage.NetData(ch, Base64.getEncoder().encodeToString("HTTP/1.1 200 OK\r\n".toByteArray())))
            tunnel.receive(ServerMessage.NetData(ch, Base64.getEncoder().encodeToString("\r\nhello".toByteArray())))

            val expected = "HTTP/1.1 200 OK\r\n\r\nhello"
            val buffer = ByteArray(expected.length)
            var read = 0
            while (read < buffer.size) {
                val n = socket.getInputStream().read(buffer, read, buffer.size - read)
                if (n <= 0) break
                read += n
            }
            assertEquals(expected, String(buffer, 0, read))

            // Acknowledged once this phone's socket has taken it, so the machine's window is
            // measuring this phone's appetite rather than measuring nothing.
            waitFor("two acks") { wire.only<ClientMessage.NetAck>().size >= 2 }
            assertEquals(expected.length, wire.only<ClientMessage.NetAck>().sumOf { it.bytes })
        }
        tunnel.stop()
    }

    @Test
    fun `a frame for another tunnel is not claimed`() {
        val wire = Wire()
        val tunnel = tunnel(wire, FakeExpiry(), freePort())
        tunnel.start()

        assertEquals(false, tunnel.receive(ServerMessage.TunnelOpened("somebody-else", 1234)))
        assertEquals(false, tunnel.receive(ServerMessage.TunnelClosed("somebody-else", "gone")))
        // A channel this side has forgotten is the ordinary result of a page being closed while
        // bytes were in flight.
        assertEquals(false, tunnel.receive(ServerMessage.NetData("no-such-channel", "aGk=")))
        assertTrue(tunnel.phase is PortTunnel.Phase.Opening)
        tunnel.stop()
    }

    @Test
    fun `a tunnel the machine closed is not closed back at it`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)
        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        tunnel.receive(ServerMessage.TunnelClosed(tunnel.id, "Nothing is listening on that port."))

        assertEquals(
            PortTunnel.Phase.Ended("Nothing is listening on that port."),
            tunnel.phase,
        )
        // The machine decided, so it is not told again.
        assertEquals(0, wire.only<ClientMessage.TunnelClose>().size)
        // And the listener is down: a socket held open for a tunnel that is over would accept a
        // browser connection with nowhere to send it.
        waitFor("the listener to be down") { connectOrNull(port) == null }
    }

    @Test
    fun `a dropped socket ends the page rather than leaving a spinner`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)
        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        wire.connected = false
        tunnel.connectionLost("The connection to the machine went.")

        assertEquals(PortTunnel.Phase.Ended("The connection to the machine went."), tunnel.phase)
        // Nothing is sent: the wire that would carry it is the thing that broke.
        assertEquals(0, wire.only<ClientMessage.TunnelClose>().size)
    }

    @Test
    fun `a port already in use on this phone is refused with a sentence rather than moved`() {
        val port = freePort()
        ServerSocket(port, 1, InetAddress.getByName("127.0.0.1")).use {
            val wire = Wire()
            val tunnel = tunnel(wire, FakeExpiry(), port)
            tunnel.start()
            tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
            waitFor("the tunnel to give up") { tunnel.phase is PortTunnel.Phase.Ended }

            val detail = (tunnel.phase as PortTunnel.Phase.Ended).detail
            // Serving the site on a different number would break every absolute URL the framework
            // writes for itself, so this says why rather than half-working.
            assertTrue(detail, detail.contains("already in use"))
            // The phase is set before the frame is sent and the bind runs on the IO dispatcher, so
            // the frame lands a moment after the phase does. Waited for rather than asserted on the
            // same tick — a test that raced this would fail once a week on a loaded machine.
            waitFor("the machine to be told") { wire.only<ClientMessage.TunnelClose>().isNotEmpty() }
        }
    }

    @Test
    fun `a port Android reserves says so, because the fix is different`() {
        val wire = Wire()
        val tunnel = tunnel(wire, FakeExpiry(), 80)
        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, 80))
        waitFor("the tunnel to give up") { tunnel.phase is PortTunnel.Phase.Ended }
        val detail = (tunnel.phase as PortTunnel.Phase.Ended).detail
        assertTrue(detail, detail.contains("reserves"))
    }

    @Test
    fun `a port outside the wire's range is refused before a socket is asked for`() {
        val wire = Wire()
        val tunnel = tunnel(wire, FakeExpiry(), Protocol.MAX_PORT + 1)
        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, Protocol.MAX_PORT + 1))
        waitFor("the tunnel to give up") { tunnel.phase is PortTunnel.Phase.Ended }
        assertTrue((tunnel.phase as PortTunnel.Phase.Ended).detail.contains("not a port"))
    }

    @Test
    fun `a tunnel is taken down exactly once, however many ways it ends`() {
        val wire = Wire()
        val port = freePort()
        val tunnel = tunnel(wire, FakeExpiry(), port)
        tunnel.start()
        tunnel.receive(ServerMessage.TunnelOpened(tunnel.id, port))
        waitFor("the tunnel to be live") { tunnel.phase is PortTunnel.Phase.Live }

        tunnel.stop()
        tunnel.stop()
        tunnel.connectionLost("and again")

        assertEquals(PortTunnel.Phase.Ended("Closed."), tunnel.phase)
        assertEquals("one teardown, one frame", 1, wire.only<ClientMessage.TunnelClose>().size)
    }

    private fun connectOrNull(port: Int): Socket? = try {
        Socket().apply {
            connect(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 300)
        }
    } catch (_: Exception) {
        null
    }
}
