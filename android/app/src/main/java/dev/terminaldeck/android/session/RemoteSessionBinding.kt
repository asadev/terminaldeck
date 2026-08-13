package dev.terminaldeck.android.session

import android.util.Log
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import dev.terminaldeck.android.protocol.ClientFrames
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.transport.DeckTransport
import java.nio.charset.StandardCharsets

/**
 * One live session: a Termux emulator on one side, the wire protocol on the other.
 *
 * This class is the whole join. Above it the UI knows about a [TerminalSession] and nothing about
 * frames; below it the transport knows about frames and nothing about emulators. The two halves are
 * bolted together by [TerminalSession.Transport], which is the single modification Terminal Deck
 * makes to the vendored Termux code.
 *
 * ## Threading
 *
 * Everything here runs on the main thread except [feed], which is called from wherever the socket
 * delivers. That asymmetry is why output goes through [TerminalSession.feedOutput] — which queues
 * and posts — rather than touching the emulator directly.
 */
class RemoteSessionBinding(
    val sessionId: String,
    private val transport: DeckTransport,
    private val onScreenUpdate: () -> Unit,
    private val onTitleChange: () -> Unit,
    /** Selection copied out of the terminal. The clipboard belongs to the UI layer, not here. */
    private val onCopy: (String) -> Unit = {},
    /** What the clipboard holds, or null. Read lazily: a paste that never happens reads nothing. */
    private val onPaste: () -> String? = { null },
    /**
     * A frame did not go.
     *
     * The transport refuses rather than queues when the connection is down, and something has to
     * say so — a keystroke that vanished silently is the failure this whole app is written to
     * avoid. Deliberately not drawn into the terminal: writing local text into the emulator would
     * put a line in the transcript that the remote shell never sent.
     */
    private val onSendFailed: () -> Unit = {},
    transcriptRows: Int = TRANSCRIPT_ROWS,
) : TerminalSessionClient, TerminalSession.Transport {

    val session: TerminalSession = TerminalSession(sessionId, transcriptRows, this)

    /**
     * Whether `attach` has gone out.
     *
     * The desktop replays scrollback on attach, so attaching twice would draw the transcript twice.
     * The flag lives here rather than in the transport because it is a fact about this binding: a
     * second binding for the same session — a second window onto it — is a legitimate thing the
     * protocol allows.
     */
    private var attached = false

    /** The last size the view reported, so an attach after a reconnect asks for the right shape. */
    private var lastCols = 0
    private var lastRows = 0

    /** A re-attach is in flight and the screen should be cleared when its replay is announced. */
    private var replayPending = false

    init {
        session.setTransport(this)
    }

    /**
     * Attach again after a reconnect.
     *
     * The desktop forgets every attachment when the socket goes, so a binding that survived the
     * outage has to ask for the session back — and it asks with `attach`, not `resize`, because the
     * point is the scrollback replay that comes with it.
     *
     * The screen is **not** cleared here. An earlier version cleared it before sending, which
     * looked right until the session no longer existed on the Mac: the attach came back
     * `unknown-session`, no replay ever arrived, and the user was left staring at an empty black
     * terminal with no idea what had happened to their output. The clear now waits for
     * [onAttached], which only runs when the desktop has agreed to send the transcript.
     */
    fun reattach() {
        attached = false
        if (lastCols <= 0 || lastRows <= 0) return
        attached = true
        replayPending = true
        transport.send(ClientMessage.attach(sessionId, lastCols, lastRows))
    }

    /**
     * The desktop answered `attached`, so the replay is on its way.
     *
     * Clearing here rather than on the first `output` frame: replay is the whole transcript, and
     * appending it under the old screen shows the session twice. `reset()` also drops the modes the
     * dead connection left behind — bracketed paste and mouse tracking outlive a socket otherwise.
     */
    fun onAttached() {
        if (!replayPending) return
        replayPending = false
        session.reset()
        session.feedOutput(CLEAR)
    }

    /** Paste text into the session, through the emulator so bracketed paste is honoured. */
    fun paste(text: String) {
        session.emulator?.paste(text)
    }

    /** Output from the desktop. Any thread. */
    fun feed(data: String) {
        session.feedOutput(data)
    }

    /** The desktop says the remote process is gone. Any thread. */
    fun remoteExited(exitCode: Int) {
        session.remoteExited(exitCode)
    }

    /** Stop reading this session. Does not ask the desktop to kill anything. */
    fun close() {
        session.finishIfRunning()
        session.setTransport(null)
    }

    // ---------------------------------------------------------------- TerminalSession.Transport --

    /**
     * A keystroke leaving the phone.
     *
     * The bytes are UTF-8 from the emulator's own encoder, and the protocol's `input.data` is a
     * JSON string, so they are decoded here rather than base64'd — that is what the desktop's
     * `input` field is: text. [ClientFrames.chunkInput] is what keeps a large paste under
     * [Protocol.MAX_INPUT_BYTES]; a single keystroke never reaches it.
     *
     * The array is the emulator's reusable scratch buffer, so the substring is taken immediately
     * and nothing retains the range.
     */
    override fun onInput(session: TerminalSession, data: ByteArray, offset: Int, count: Int) {
        if (count <= 0) return
        val text = String(data, offset, count, StandardCharsets.UTF_8)
        var landed = true
        for (frame in ClientFrames.chunkInput(sessionId, text)) {
            landed = transport.send(frame) && landed
        }
        if (!landed) onSendFailed()
    }

    /**
     * The view measured itself.
     *
     * The first size travels with `attach` so the desktop's first replay is already the right
     * shape — a replay reflowed twice is a visibly mangled first screen. Later sizes are a plain
     * `resize`.
     */
    override fun onSizeChanged(session: TerminalSession, columns: Int, rows: Int, initial: Boolean) {
        val cols = Protocol.clampCols(columns)
        val rowCount = Protocol.clampRows(rows)
        lastCols = cols
        lastRows = rowCount
        if (initial && !attached) {
            attached = true
            transport.send(ClientMessage.attach(sessionId, cols, rowCount))
        } else {
            transport.send(ClientMessage.Resize(sessionId, cols, rowCount))
        }
    }

    override fun onDetach(session: TerminalSession) {
        if (!attached) return
        attached = false
        transport.send(ClientMessage.Detach(sessionId))
    }

    // ------------------------------------------------------------------- TerminalSessionClient --

    override fun onTextChanged(changedSession: TerminalSession) = onScreenUpdate()

    override fun onTitleChanged(changedSession: TerminalSession) = onTitleChange()

    override fun onSessionFinished(finishedSession: TerminalSession) = onScreenUpdate()

    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
        if (!text.isNullOrEmpty()) onCopy(text)
    }

    /**
     * Paste goes through the emulator rather than straight to the transport.
     *
     * `TerminalEmulator.paste` strips the control bytes a paste has no business carrying and wraps
     * the text in bracketed-paste markers when the remote program asked for them — which is what
     * stops a pasted multi-line command from being executed line by line as it arrives.
     */
    override fun onPasteTextFromClipboard(session: TerminalSession?) {
        onPaste()?.takeIf { it.isNotEmpty() }?.let { paste(it) }
    }

    override fun onBell(session: TerminalSession) = Unit

    override fun onColorsChanged(session: TerminalSession) = Unit

    override fun onTerminalCursorStateChange(state: Boolean) = Unit

    /**
     * Upstream reports the forked shell's pid here. There is no local process, and the remote pid
     * is not something the protocol carries, so there is nothing true to report.
     */
    override fun setTerminalShellPid(session: TerminalSession, pid: Int) = Unit

    override fun getTerminalCursorStyle(): Int? = null

    override fun logError(tag: String?, message: String?) {
        Log.e(tag ?: TAG, message ?: "")
    }

    override fun logWarn(tag: String?, message: String?) {
        Log.w(tag ?: TAG, message ?: "")
    }

    override fun logInfo(tag: String?, message: String?) {
        Log.i(tag ?: TAG, message ?: "")
    }

    override fun logDebug(tag: String?, message: String?) {
        Log.d(tag ?: TAG, message ?: "")
    }

    override fun logVerbose(tag: String?, message: String?) {
        Log.v(tag ?: TAG, message ?: "")
    }

    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
        Log.e(tag ?: TAG, message ?: "", e)
    }

    override fun logStackTrace(tag: String?, e: Exception?) {
        Log.e(tag ?: TAG, "", e)
    }

    companion object {
        private const val TAG = "TerminalDeck"

        /**
         * Scrollback kept on the phone.
         *
         * Not the same number as the desktop's. The desktop is the archive; the phone is a window,
         * and every retained row is a `TerminalRow` of live objects in a process Android will kill
         * for using memory while backgrounded.
         */
        const val TRANSCRIPT_ROWS = 2_000

        /** Home, erase display, erase scrollback. Written as escapes; never as raw bytes. */
        private const val CLEAR = "\u001b[H\u001b[2J\u001b[3J"
    }
}
