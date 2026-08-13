package dev.terminaldeck.android.transfer

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.Base64
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.random.Random

/**
 * The upload state machine, against a scripted Mac.
 *
 * There is no `ContentResolver` here and no socket: the file is a byte array and the wire is a list.
 * That is not a compromise — everything interesting about this class is the *ordering* it enforces
 * (nothing is read before a path arrives, nothing is read past the window, the digest describes what
 * was actually read) and every one of those is visible in the sequence of frames it emits.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FileUploadTest {

    private class Wire {
        val sent = mutableListOf<ClientMessage>()
        var live = true

        fun send(message: ClientMessage): Boolean {
            if (!live) return false
            sent += message
            return true
        }

        inline fun <reified T> only(): List<T> = sent.filterIsInstance<T>()
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Acknowledge everything that has been sent, the way the desktop would. */
    private fun ackAll(upload: FileUpload, wire: Wire, from: Int): Int {
        val slices = wire.only<ClientMessage.UploadData>()
        for (index in from until slices.size) {
            val bytes = Base64.getDecoder().decode(slices[index].data).size
            upload.onFrame(ServerMessage.UploadAck(upload.id, bytes))
        }
        return slices.size
    }

    @Test
    fun `nothing is read until the Mac has named a path`() = runTest {
        val payload = Random(1).nextBytes(100_000)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()

        // Exactly one frame: the announcement. A client that started streaming here would be writing
        // to somebody's disk before they had been shown where.
        assertEquals(1, wire.sent.size)
        assertTrue(wire.sent.single() is ClientMessage.UploadBegin)
    }

    @Test
    fun `the whole file goes out in slices, in order, and the digest describes it`() = runTest {
        val payload = Random(2).nextBytes(200_000)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()

        var acked = 0
        while (wire.only<ClientMessage.UploadEnd>().isEmpty()) {
            val before = wire.only<ClientMessage.UploadData>().size
            acked = ackAll(upload, wire, acked)
            advanceUntilIdle()
            if (wire.only<ClientMessage.UploadData>().size == before && acked == before) break
        }
        assertTrue("the upload never finished", wire.only<ClientMessage.UploadEnd>().isNotEmpty())

        val rebuilt = wire.only<ClientMessage.UploadData>()
            .fold(ByteArray(0)) { all, slice -> all + Base64.getDecoder().decode(slice.data) }
        assertTrue("no bytes were sent", rebuilt.isNotEmpty())
        assertEquals(payload.size, rebuilt.size)
        assertTrue("the bytes that arrived are not the bytes that were picked", payload.contentEquals(rebuilt))
        assertEquals(sha(payload), wire.only<ClientMessage.UploadEnd>().single().sha256)
    }

    @Test
    fun `no slice is larger than one frame's worth`() = runTest {
        val payload = Random(3).nextBytes(120_000)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()

        for (slice in wire.only<ClientMessage.UploadData>()) {
            val raw = Base64.getDecoder().decode(slice.data).size
            assertTrue("slice of $raw bytes is over the chunk cap", raw <= Protocol.MAX_UPLOAD_CHUNK_BYTES)
            // And the *encoded* string has to fit a frame, which is the number the desktop's parser
            // actually checks.
            assertTrue("encoded slice is over the message cap", slice.data.length < Protocol.MAX_MESSAGE_BYTES)
        }
    }

    /**
     * The window is the whole reason this class is not a `for` loop.
     *
     * Without it a 200 MB video is handed to the socket as fast as flash can be read and the Mac's
     * backpressure cap drops the phone. With no acknowledgements at all, nothing past one window may
     * be in flight.
     */
    @Test
    fun `it stops reading one window ahead when nothing is acknowledged`() = runTest {
        val payload = Random(4).nextBytes(4 * Protocol.UPLOAD_WINDOW_BYTES)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()

        val inFlight = wire.only<ClientMessage.UploadData>()
            .sumOf { Base64.getDecoder().decode(it.data).size }
        assertTrue("nothing was sent at all", inFlight > 0)
        assertTrue(
            "sent $inFlight bytes with nothing acknowledged — the window is not holding",
            inFlight <= Protocol.UPLOAD_WINDOW_BYTES + Protocol.MAX_UPLOAD_CHUNK_BYTES,
        )
        // And no `upload.end`: the file is nowhere near finished.
        assertTrue(wire.only<ClientMessage.UploadEnd>().isEmpty())
    }

    @Test
    fun `progress comes from acknowledgements, not from bytes handed to the socket`() = runTest {
        val payload = Random(5).nextBytes(4 * Protocol.UPLOAD_WINDOW_BYTES)
        val wire = Wire()
        var latest: UploadView? = null
        val upload = upload(payload, wire, this, onChange = { latest = it })
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()

        // A window of bytes is with the socket and none has been acknowledged. A bar drawn from the
        // socket would already be a quarter full.
        assertEquals(0f, latest?.fraction ?: -1f, 0.0001f)
        upload.onFrame(ServerMessage.UploadAck(upload.id, Protocol.MAX_UPLOAD_CHUNK_BYTES))
        advanceUntilIdle()
        assertTrue((latest?.acked ?: 0) > 0)
    }

    @Test
    fun `cancel tells the Mac, so the half-written file is deleted`() = runTest {
        val payload = Random(6).nextBytes(100_000)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()
        upload.cancel()
        advanceUntilIdle()

        assertEquals(1, wire.only<ClientMessage.UploadCancel>().size)
        assertTrue(upload.view.phase is UploadPhase.Failed)
        assertTrue(!upload.view.isRunning)
    }

    @Test
    fun `a dropped socket ends the upload rather than leaving the bar creeping`() = runTest {
        val payload = Random(7).nextBytes(100_000)
        val wire = Wire()
        val upload = upload(payload, wire, this)
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()
        upload.connectionLost("Reconnecting…")
        advanceUntilIdle()

        assertEquals(UploadPhase.Failed("Reconnecting…"), upload.view.phase)
        // Nothing is sent over a socket that is gone.
        assertTrue(wire.only<ClientMessage.UploadCancel>().isEmpty())
    }

    @Test
    fun `a file past the ceiling is refused with both numbers, before anything is read`() = runTest {
        val wire = Wire()
        val upload = FileUpload(
            file = PickedFile("huge.mov", Protocol.MAX_UPLOAD_BYTES + 1),
            scope = this,
            send = wire::send,
            open = { throw AssertionError("nothing should be opened for a file that was refused") },
            onChange = {},
            onLanded = { throw AssertionError("it did not land") },
            io = EmptyCoroutineContext,
        )
        upload.start()
        advanceUntilIdle()

        assertTrue(wire.sent.isEmpty())
        val detail = (upload.view.phase as UploadPhase.Failed).detail
        assertTrue("the refusal must name the file's size: $detail", detail.contains("512 MB") || detail.contains("GB"))
        assertTrue("the refusal must name the limit: $detail", detail.contains("512 MB"))
    }

    @Test
    fun `the path lands exactly once, and only from the Mac's own done frame`() = runTest {
        val payload = Random(8).nextBytes(1000)
        val wire = Wire()
        val landed = mutableListOf<String>()
        val upload = upload(payload, wire, this, onLanded = { landed += it })
        upload.start()
        advanceUntilIdle()
        upload.onFrame(ServerMessage.UploadReady(upload.id, "/tmp/x.bin"))
        advanceUntilIdle()
        ackAll(upload, wire, 0)
        advanceUntilIdle()

        assertTrue("nothing has landed until the Mac says so", landed.isEmpty())
        upload.onFrame(ServerMessage.UploadDone(upload.id, "/D/Terminal Deck/x.bin", payload.size.toLong(), "ff"))
        advanceUntilIdle()
        assertEquals(listOf("/D/Terminal Deck/x.bin"), landed)
        // A second one — a duplicate frame, a reconnect — must not type the path twice.
        upload.onFrame(ServerMessage.UploadDone(upload.id, "/D/Terminal Deck/x.bin", payload.size.toLong(), "ff"))
        assertEquals(1, landed.size)
    }

    @Test
    fun `frames for another upload are not claimed`() = runTest {
        val wire = Wire()
        val upload = upload(Random(9).nextBytes(10), wire, this)
        assertTrue(!upload.onFrame(ServerMessage.UploadReady("someone-else", "/tmp/y")))
        assertTrue(!upload.onFrame(ServerMessage.UploadAck("someone-else", 1)))
    }

    /**
     * The upload's own scope, sharing the test's scheduler but not its job.
     *
     * `advanceUntilIdle` still drives it, but `runTest` does not *wait* for it — and it should not:
     * the pump is deliberately suspended on an acknowledgement that will never come in the tests
     * that assert the window is holding. Launched into the test's own scope, those tests hung for
     * the full sixty-second timeout and reported nothing about the thing they were checking.
     */
    private fun upload(
        payload: ByteArray,
        wire: Wire,
        scope: TestScope,
        onChange: (UploadView) -> Unit = {},
        onLanded: (String) -> Unit = {},
    ): FileUpload = FileUpload(
        file = PickedFile("x.bin", payload.size.toLong()),
        scope = CoroutineScope(StandardTestDispatcher(scope.testScheduler)),
        send = wire::send,
        open = { ByteArrayInputStream(payload) },
        onChange = onChange,
        onLanded = onLanded,
        // Keeps the reads on the test scheduler, so `advanceUntilIdle` can actually see them.
        io = EmptyCoroutineContext,
    )
}

class ShellQuotingTest {

    /**
     * The path is typed at a prompt, and a Mac path really does contain a space: the folder is named
     * after the product. Unquoted, that is two arguments and a command that cannot work.
     */
    @Test
    fun `a path with spaces becomes one word`() {
        assertEquals("'/Users/a/Downloads/Terminal Deck/IMG_1.HEIC'", shellQuoted("/Users/a/Downloads/Terminal Deck/IMG_1.HEIC"))
    }

    @Test
    fun `everything a shell would otherwise interpret is literal inside the quotes`() {
        for (nasty in listOf("\$HOME", "`id`", "a;rm -rf /", "a\\b", "a\"b", "a\$(id)b", "a&b", "a|b", "a*b")) {
            val quoted = shellQuoted("/tmp/$nasty")
            assertTrue(quoted.startsWith("'"))
            assertTrue(quoted.endsWith("'"))
            // Nothing inside was escaped or dropped — single quotes make that unnecessary, and a
            // version that escaped character-by-character would be a list with one entry missing.
            assertEquals("'/tmp/$nasty'", quoted)
        }
    }

    @Test
    fun `a single quote is closed, escaped and reopened`() {
        // The one character single-quoting cannot contain. `it's` must survive as `it's`.
        assertEquals("'/tmp/it'\\''s.txt'", shellQuoted("/tmp/it's.txt"))
    }
}

class ByteSizeTest {

    @Test
    fun `small numbers stay exact and large ones read like a person would say them`() {
        assertEquals("0 bytes", byteSize(0))
        assertEquals("512 bytes", byteSize(512))
        assertEquals("1.0 KB", byteSize(1024))
        assertEquals("3.0 MB", byteSize(3 * 1024 * 1024))
        assertEquals("512 MB", byteSize(Protocol.MAX_UPLOAD_BYTES))
    }
}
