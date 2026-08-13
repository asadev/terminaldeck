package dev.terminaldeck.android.transfer

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlin.coroutines.CoroutineContext

/**
 * One file on its way from this phone to the Mac.
 *
 * A person picks a photo, a video or a document in the system picker; this reads it in slices, puts
 * them on the sealed channel that is already open, and ends with a path on the Mac that the terminal
 * screen types into the session.
 *
 * ## Why there is a window
 *
 * Flash on a phone reads faster than any link this travels over. Without a window a 200 MB video is
 * handed to the socket in seconds and then sits in the desktop's heap until its backpressure cap
 * drops this phone — a feature that fails *only* on the large files, which is the worst way for it
 * to fail. So the next slice is read only when there is room: the Mac acknowledges each one **from
 * its own write callback**, meaning the bytes are with its kernel rather than merely received, and
 * this stops reading once [Protocol.UPLOAD_WINDOW_BYTES] are unacknowledged.
 *
 * The same acknowledgements are what the progress bar is drawn from. Drawn from bytes handed to the
 * socket it would fill in two seconds and then sit at 100% for a minute, which is not a progress
 * bar, it is a lie with an animation.
 *
 * ## Why the digest
 *
 * [ClientMessage.UploadEnd] carries the SHA-256 of everything read here; the Mac compares it against
 * the digest of everything it wrote and deletes the file when they differ. Nothing else can tell a
 * file that arrived from one that *nearly* arrived, and a truncated video with the right name is
 * worse than no video — it surfaces later, somewhere else, as a file nobody can open.
 *
 * ## Where the bytes come from
 *
 * A `content://` URI from `PickVisualMedia` (the system photo picker) or `OpenDocument` (the storage
 * access framework). Both run in another process and hand back a URI this app may read; neither
 * needs `READ_MEDIA_IMAGES` or any other runtime permission, and this app requests none. That is a
 * design constraint rather than a preference — see `MainActivity`.
 *
 * ## Threading
 *
 * Reads happen on [Dispatchers.IO]; every field below is touched only from the scope's main
 * dispatcher, which is where [onFrame] is called from and where [onChange] fires. The one loop lives
 * in [job] and is cancelled with it, so an upload cannot outlive the screen that started it.
 */
class FileUpload(
    private val file: PickedFile,
    private val scope: CoroutineScope,
    /** How the bytes reach the Mac. False when the socket is down; never queues. */
    private val send: (ClientMessage) -> Boolean,
    /** Opens the picked URI. Injected so a test needs no `ContentResolver`. */
    private val open: () -> InputStream,
    /** Fires on every state change, so the view model can republish its UI state. */
    private val onChange: (UploadView) -> Unit,
    /** Called once, with the path on the Mac, when the file has landed. */
    private val onLanded: (String) -> Unit,
    /**
     * Where the blocking reads happen.
     *
     * A parameter rather than a hardcoded [Dispatchers.IO] because the tests drive this class with a
     * `TestScope`, and `advanceUntilIdle` cannot see work that has hopped onto a real thread pool —
     * the first version of those tests read zero bytes and then sat for the full sixty-second
     * `runTest` timeout waiting for a coroutine it could not schedule. Production passes nothing and
     * gets the IO pool; a test passes `EmptyCoroutineContext` and keeps everything on its scheduler.
     */
    private val io: CoroutineContext = Dispatchers.IO,
) {
    /** A UUID, which satisfies the desktop's id shape: alphanumeric first, then `[A-Za-z0-9_-]`. */
    val id: String = UUID.randomUUID().toString()

    private var phase: UploadPhase = UploadPhase.Opening
    /** Bytes the Mac has said it has written. The numerator of the bar. */
    private var acked = 0L
    /**
     * Bytes sent that have not been acknowledged.
     *
     * A flow rather than a plain field because the pump *waits* on it: `first { it < window }` is
     * the whole of the backpressure, and it is why there is no polling loop and no timer here.
     */
    private val inFlight = MutableStateFlow(0)
    private var job: Job? = null
    private var over = false

    val view: UploadView
        get() = UploadView(id = id, name = file.name, size = file.size, acked = acked, phase = phase)

    /**
     * Announce the file. Nothing is read until the Mac answers with a path.
     *
     * The size is checked here rather than left to the desktop's refusal, because this side is the
     * only one that knows what the person picked and can therefore say both numbers.
     */
    fun start() {
        if (file.size <= 0) {
            finish(UploadPhase.Failed("That file is empty."), tellMac = false)
            return
        }
        if (file.size > Protocol.MAX_UPLOAD_BYTES) {
            finish(
                UploadPhase.Failed(
                    "That file is ${byteSize(file.size)}. The most this can send is " +
                        "${byteSize(Protocol.MAX_UPLOAD_BYTES)}."
                ),
                tellMac = false,
            )
            return
        }
        if (!send(ClientMessage.UploadBegin(id, file.name, file.size))) {
            finish(UploadPhase.Failed("The connection to the Mac is not up."), tellMac = false)
        }
    }

    /** The Cancel button — and the only way to stop an upload that has stalled. */
    fun cancel(detail: String = "Cancelled.") {
        finish(UploadPhase.Failed(detail), tellMac = true)
    }

    /** The socket went away. The Mac deletes its half when the connection closes. */
    fun connectionLost(detail: String) {
        finish(UploadPhase.Failed(detail), tellMac = false)
    }

    /**
     * A frame from the Mac. True when it belonged to this upload.
     *
     * Returning a Boolean rather than filtering in the view model keeps the routing in one place:
     * the view model has no idea which upload ids are whose, and giving it one would be a second
     * copy of this state to keep in step by hand.
     */
    fun onFrame(message: ServerMessage): Boolean = when {
        message is ServerMessage.UploadReady && message.id == id -> {
            begin(message.path)
            true
        }
        message is ServerMessage.UploadAck && message.id == id -> {
            acked = minOf(file.size, acked + message.bytes)
            inFlight.value = (inFlight.value - message.bytes).coerceAtLeast(0)
            onChange(view)
            true
        }
        message is ServerMessage.UploadDone && message.id == id -> {
            // Guarded, because `onLanded` **types into somebody's terminal**. `finish` is already
            // idempotent, but the callback used to sit outside it — so a duplicate `upload.done`,
            // or one arriving after a cancel had raced it, pasted the path a second time at whatever
            // prompt was there by then. Caught by a test that sends the frame twice.
            if (!over) {
                acked = file.size
                // The Mac decided it is over, so it is not told again.
                finish(UploadPhase.Landed(message.path), tellMac = false)
                onLanded(message.path)
            }
            true
        }
        message is ServerMessage.UploadFailed && message.id == id -> {
            finish(UploadPhase.Failed(message.message), tellMac = false)
            true
        }
        else -> false
    }

    private fun begin(path: String) {
        if (phase !is UploadPhase.Opening) return
        phase = UploadPhase.Sending(path)
        onChange(view)
        job = scope.launch {
            val stream = try {
                withContext(io) { open() }
            } catch (e: Exception) {
                finish(UploadPhase.Failed("This phone could not read that file."), tellMac = true)
                return@launch
            }
            try {
                pump(stream, path)
            } catch (e: Exception) {
                finish(UploadPhase.Failed("This phone could not read that file any more."), tellMac = true)
            } finally {
                withContext(io) { runCatching { stream.close() } }
            }
        }
    }

    private suspend fun pump(stream: InputStream, path: String) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(Protocol.MAX_UPLOAD_CHUNK_BYTES)
        var read = 0L

        while (read < file.size) {
            // The backpressure, and the whole reason this is a coroutine: it suspends here until an
            // acknowledgement has made room, rather than spinning or buffering.
            inFlight.first { it < Protocol.UPLOAD_WINDOW_BYTES }
            val n = withContext(io) { stream.read(buffer) }
            if (n <= 0) {
                // Shorter than it said. Sending what there is would produce a truncated file the Mac
                // refuses on the byte count; saying so from the end that knows why is clearer.
                finish(UploadPhase.Failed("That file changed while it was being sent."), tellMac = true)
                return
            }
            val slice = buffer.copyOf(n)
            digest.update(slice)
            read += n
            if (!send(ClientMessage.UploadData(id, Base64.getEncoder().encodeToString(slice)))) {
                finish(UploadPhase.Failed("The connection to the Mac dropped."), tellMac = false)
                return
            }
            inFlight.value += n
        }

        // Every byte is on the wire; wait for the Mac to have written all of them before declaring
        // the digest, so a failure mid-write is reported as a failure rather than as a bad checksum.
        inFlight.first { it == 0 }
        if (over) return
        phase = UploadPhase.Finishing(path)
        onChange(view)
        val hex = digest.digest().joinToString("") { "%02x".format(it) }
        if (!send(ClientMessage.UploadEnd(id, hex))) {
            finish(UploadPhase.Failed("The connection to the Mac dropped."), tellMac = false)
        }
    }

    private fun finish(next: UploadPhase, tellMac: Boolean) {
        if (over) return
        over = true
        // Told rather than merely abandoned: the Mac is holding an open descriptor and a half-written
        // `.part` file, and only this frame deletes it.
        if (tellMac) send(ClientMessage.UploadCancel(id))
        job?.cancel()
        job = null
        phase = next
        onChange(view)
    }
}

/** A file the user picked, before anything has been sent. */
data class PickedFile(
    /** What to suggest calling it on the Mac. The Mac decides the real name. */
    val name: String,
    val size: Long,
)

/** Where an upload is, and what the row should say. */
sealed interface UploadPhase {
    /** `upload.begin` is on the wire; the Mac has not named a path yet. */
    data object Opening : UploadPhase

    /** Sending. [path] is where it will land, and it is on screen while Cancel still means something. */
    data class Sending(val path: String) : UploadPhase

    /** Every byte is acknowledged and the digest has gone; the Mac is checking and renaming. */
    data class Finishing(val path: String) : UploadPhase

    data class Landed(val path: String) : UploadPhase

    data class Failed(val detail: String) : UploadPhase
}

/** The upload as the UI is allowed to see it: no streams, no wire, no job. */
data class UploadView(
    val id: String,
    val name: String,
    val size: Long,
    val acked: Long,
    val phase: UploadPhase,
) {
    val fraction: Float get() = if (size > 0) (acked.toFloat() / size).coerceIn(0f, 1f) else 0f

    /** Whether Cancel should be there. A finished upload has nothing to cancel. */
    val isRunning: Boolean get() = phase is UploadPhase.Opening ||
        phase is UploadPhase.Sending ||
        phase is UploadPhase.Finishing

    /** One line for the row, which is the only place any of this is explained. */
    val detail: String
        get() = when (val current = phase) {
            is UploadPhase.Opening -> "Asking the Mac where to put it…"
            is UploadPhase.Sending -> "${byteSize(acked)} of ${byteSize(size)} → ${current.path}"
            is UploadPhase.Finishing -> "Checking it arrived intact…"
            is UploadPhase.Landed -> current.path
            is UploadPhase.Failed -> current.detail
        }
}

/**
 * A byte count as a person would say it.
 *
 * Written out rather than reached for through `Formatter.formatFileSize`, because these numbers
 * appear in refusals — "that file is 780 MB, the most this can send is 512 MB" — and two figures in
 * one sentence produced by different rules read as nonsense. Binary units, matching the constants
 * they are compared against.
 */
fun byteSize(bytes: Long): String {
    val units = arrayOf("bytes", "KB", "MB", "GB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024 && unit < units.size - 1) {
        value /= 1024
        unit += 1
    }
    if (unit == 0) return "$bytes bytes"
    return if (value < 10) "%.1f %s".format(value, units[unit]) else "%.0f %s".format(value, units[unit])
}

/**
 * A path, quoted so a shell reads it as one word.
 *
 * Single quotes, because inside them a shell interprets nothing at all — no `$`, no backtick, no
 * backslash — and a file name really can contain every one of those. The only character needing care
 * is the quote itself, which is closed, escaped and reopened: `it's` becomes `'it'\''s'`.
 *
 * This is why the desktop's `safeName` deliberately does **not** strip shell punctuation out of
 * people's file names: the hazard is handled here, once, where a path becomes a command line. The
 * iOS client's `shellQuoted` is the same function for the same reason — both phones must hand the
 * agent identical strings.
 */
fun shellQuoted(path: String): String = "'" + path.replace("'", "'\\''") + "'"
