package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CopilotFileRow
import dev.terminaldeck.android.protocol.CopilotFiles
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The copilot's own files, as this phone reads and edits them. The client half of
 * [Capability.COPILOT_FILES] — a transcription of the `copilot.file*` handling in
 * `ios/TerminalDeck/App/CopilotLink.swift`, drawn by `CopilotFilesView.swift`.
 *
 * ## Nothing here decides what may be written
 *
 * Every one of those questions is answered twice, by somebody who is not this file:
 * [CopilotFileRow.writable] is the machine's answer about the **file** — the two generated ones are
 * rewritten on every start — and the [Capability.COPILOT_FILES] grant is the answer about **this
 * phone**, which is the alter tier because *"the instruction file is the agent"*. This class draws a
 * Save when both say yes and re-derives neither. The one thing it owns is refusing an empty file and
 * one over the wire's ceiling before a frame goes, because those never reach the machine.
 *
 * ## A save is confirmed by the listing, not by the button
 *
 * [saveFile] answers whether the **frame went**, which is not the same news as *it is on the disk*.
 * The desktop reads the folder again after every write and sends the whole listing back, so a row's
 * [CopilotFileRow.modifiedAt] moving is the machine's own confirmation — see the editor, which
 * watches exactly that and calls nothing else *Saved*.
 */
class CopilotFilesController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val onChange: () -> Unit,
) {

    private var files: List<CopilotFileRow> = emptyList()

    /** Whether a `copilot.files.rows` has ever arrived, so *reading* can be told from *empty*. */
    private var answered = false

    /** True between asking for the listing and its arrival. */
    private var loadingFiles = false

    /** The file whose editor is open, or null. Addressed by id so a listing that arrives while
     *  somebody is typing keeps the facts under the title current without touching the box. */
    private var openId: String? = null
    private var openText: String = ""
    private var openError: String? = null
    private var loadingText = false

    /** A refusal this end made itself — an empty file, a file over the ceiling, a dead socket — so
     *  the editor has the sentence for a save that never reached the machine. */
    private var localError: String? = null

    /** Whether this machine offers the copilot's files to this phone at all. The card is absent, not
     *  disabled, without it: an older desktop closes the channel on a frame it has never heard of. */
    fun offered(): Boolean = capabilities().contains(Capability.COPILOT_FILES)

    /** Whether a Save may be served for a row: this phone's tier and the machine's answer about the
     *  file. Two different questions with two different sentences — see the editor's readOnlyBecause. */
    fun canEdit(): Boolean = offered()

    /** A snapshot the files card and editor draw from, or null when this machine offers none. */
    fun view(): CopilotFilesView? {
        if (!offered()) return null
        return CopilotFilesView(
            files = files,
            answered = answered,
            loadingFiles = loadingFiles,
            canEdit = canEdit(),
            openId = openId,
            openText = openText,
            openError = openError,
            loadingText = loadingText,
            openRow = openId?.let { id -> files.firstOrNull { it.id == id } },
            localError = localError,
        )
    }

    /* --------------------------------------------------------------------- verbs -- */

    /** Ask what files are there — a listing, nothing opened. `read` tier; spends nothing. */
    fun loadFiles() {
        if (!offered()) return
        if (!send(ClientMessage.CopilotFilesList)) return
        loadingFiles = true
        onChange()
    }

    /** Open one file, whole. The box is cleared first so a stale read is never seen under a new title. */
    fun openFile(id: String) {
        if (!offered() || !CopilotFiles.isFileId(id)) return
        openId = id
        openText = ""
        openError = null
        localError = null
        loadingText = send(ClientMessage.CopilotFileRead(id))
        onChange()
    }

    fun closeFile() {
        openId = null
        openText = ""
        openError = null
        loadingText = false
        localError = null
        onChange()
    }

    /**
     * Save one file. Returns whether the **frame went** — false keeps the draft in the box.
     *
     * The two refusals here never reach the machine, so their sentence is composed on this side: an
     * empty file (nothing to save over), and one past the wire's ceiling. Everything else — a
     * generated file, a file too large to have been sent whole — the host refuses, and its sentence
     * is better than anything composed here.
     */
    fun saveFile(id: String, text: String): Boolean {
        if (!canEdit() || !CopilotFiles.isFileId(id)) return false
        localError = null
        if (text.isBlank()) {
            localError = EMPTY
            onChange()
            return false
        }
        if (Protocol.overBytes(text, CopilotFiles.MAX_FILE_BYTES)) {
            localError = TOO_LARGE
            onChange()
            return false
        }
        if (!send(ClientMessage.CopilotFileWrite(id, text))) {
            localError = NOT_CONNECTED
            onChange()
            return false
        }
        return true
    }

    /** Put the instructions this build ships back. Only `yours` is served; carried for any id so the
     *  refusal for another file is a sentence rather than a frame that quietly did nothing. */
    fun restoreInstructions(): Boolean {
        if (!canEdit()) return false
        localError = null
        if (!send(ClientMessage.CopilotFileReset("yours"))) {
            localError = NOT_CONNECTED
            onChange()
            return false
        }
        return true
    }

    /** Forget one memory, by **name** — the only unlink on this surface, so no id can be pointed at
     *  an `rm`. */
    fun forgetMemory(name: String): Boolean {
        if (!canEdit() || name.isEmpty()) return false
        localError = null
        if (!send(ClientMessage.CopilotMemoryDelete(name))) {
            localError = NOT_CONNECTED
            onChange()
            return false
        }
        return true
    }

    /* -------------------------------------------------------------------- frames -- */

    /** True when the frame belonged to the copilot's files. Unclaimed frames fall through. */
    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.CopilotFilesRows -> {
                files = message.files
                answered = true
                loadingFiles = false
            }

            is ServerMessage.CopilotFileText -> {
                // The id is echoed back untouched, so a screen with two reads in flight tells them
                // apart. A frame for one somebody has navigated away from is dropped rather than
                // drawn under the wrong title.
                if (message.id == openId) {
                    openText = message.text
                    openError = message.error
                    loadingText = false
                }
            }

            else -> return false
        }
        onChange()
        return true
    }

    fun stop() {
        files = emptyList()
        answered = false
        loadingFiles = false
        closeFile()
    }

    companion object {
        const val EMPTY = "There is nothing in the box to save."
        const val TOO_LARGE =
            "That is larger than the machine will take in one message. Trim it and save again."
        const val NOT_CONNECTED = "Not connected, so that did not reach the machine."
    }
}

/**
 * What the copilot's files card and its editor read.
 *
 * [answered] is what separates *reading* from *there is nothing*: they look identical in any list
 * that draws a count, and one is a round trip in flight while the other is a machine that has replied.
 */
data class CopilotFilesView(
    val files: List<CopilotFileRow>,
    val answered: Boolean,
    val loadingFiles: Boolean,
    val canEdit: Boolean,
    val openId: String?,
    val openText: String,
    val openError: String?,
    val loadingText: Boolean,
    /** The row the open editor is about, looked up on every read so its facts follow a fresh listing. */
    val openRow: CopilotFileRow?,
    /** A refusal composed on this side, for a save that never reached the machine. */
    val localError: String?,
)
