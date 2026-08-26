package dev.terminaldeck.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.FileListing
import dev.terminaldeck.android.protocol.FileText
import dev.terminaldeck.android.protocol.GitState
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The machine's disk and its git, as this phone reads them — the controller behind the Files, file
 * text, Source-control and Diff screens.
 *
 * The client half of [dev.terminaldeck.android.protocol.Capability.FILES] and
 * [dev.terminaldeck.android.protocol.Capability.GIT], both **owner-device only** on the host and both
 * **read-only, all of it**: there is a `files.list`, a `files.read`, a `git.status` and a `git.diff`
 * on this wire and no verb that writes. A file on a machine you cannot see is edited in a session with
 * an agent in it, not on a phone keyboard — see the capability notes in `FilesGitWire.kt`.
 *
 * ## Why it holds the latest of each rather than a history
 *
 * Every one of the four screens asks the same question the iOS ones do — *what is in this folder*,
 * *what is in this file*, *what does git say here*, *what does this file's diff look like* — and each
 * redraws off the single most-recent answer, matching the folder or the file it is standing on before
 * it draws. So this keeps one [FileListing], one [FileText], one [GitState] and one
 * [ServerMessage.GitPatch]; a screen pushed for a second folder re-asks on appear and the answer for
 * the folder it left is simply replaced. The matching — *is this the answer for the path I am on* —
 * is the screen's, because only the screen knows which path it is drawing.
 *
 * ## Compose state, not the ui-state fold
 *
 * The four fields are Compose state, so the screen reading one recomposes when the machine answers,
 * without folding every machine's summary into a new [DeckUiState] for a file's bytes. It is the same
 * reasoning the watcher's frames give for not going through the ui state — these answers are read by
 * exactly one screen at a time and change nothing any other surface draws.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this controller's.
 */
class FilesGitController(
    private val send: (ClientMessage) -> Boolean,
) {
    /** The most recent folder listing — the answer to a `files.list`. Null before the first. */
    var listing: FileListing? by mutableStateOf(null)
        private set

    /** The most recent file window — the answer to a `files.read`. Paged forward by [readFile]. */
    var fileText: FileText? by mutableStateOf(null)
        private set

    /** The most recent git answer — a repository, or a folder that is not one. Both are answers. */
    var gitState: GitState? by mutableStateOf(null)
        private set

    /** The most recent diff — the answer to a `git.diff`. All four of its fields are checked by the
     *  screen, because the staged and unstaged patches of one file are two different answers. */
    var gitPatch: ServerMessage.GitPatch? by mutableStateOf(null)
        private set

    /** Ask what is in a folder. Empty is not a path and is refused here rather than spent on a frame. */
    fun listFiles(path: String) {
        if (path.isEmpty()) return
        send(ClientMessage.FilesList(path))
    }

    /**
     * Read a window of a file, from a byte offset.
     *
     * [at] is where the window begins; the next screen is a second read from the offset the host
     * returned ([FileText.nextOffset]), never a bigger one, so a large file is read a bounded window
     * at a time rather than refused whole.
     */
    fun readFile(path: String, at: Int = 0) {
        if (path.isEmpty()) return
        send(ClientMessage.FilesRead(path, at = at))
    }

    /** Ask what git says about a folder. Both answers — a repository and a folder that is not one —
     *  come back on a `git.state`. */
    fun gitStatus(path: String) {
        if (path.isEmpty()) return
        send(ClientMessage.GitStatus(path))
    }

    /**
     * Ask for one file's diff.
     *
     * [staged] is always on the wire — index-against-HEAD or working-tree-against-index are two
     * different answers, and a file staged and then edited again legitimately appears on both sides.
     */
    fun gitDiff(path: String, file: String, staged: Boolean) {
        if (path.isEmpty() || file.isEmpty()) return
        send(ClientMessage.GitDiff(path, file, staged))
    }

    fun receive(message: ServerMessage): Boolean = when (message) {
        is FileListing -> {
            listing = message
            true
        }

        is FileText -> {
            fileText = message
            true
        }

        is ServerMessage.GitStateFrame -> {
            // The frame carries the folder it is about beside the union; the screen matches on it.
            gitState = message.status
            true
        }

        is ServerMessage.GitPatch -> {
            gitPatch = message
            true
        }

        else -> false
    }

    /**
     * Forget what the last connection said.
     *
     * A welcome is a fresh connection — possibly to a different machine after a re-pair — so the held
     * answers are dropped rather than drawn under a new machine's name. The screens re-ask on their
     * next appearance, which is what turns a stale listing back into the current one.
     */
    fun renew() {
        listing = null
        fileText = null
        gitState = null
        gitPatch = null
    }

    /** A machine being taken down. Nothing here holds a timer or a socket, so this is [renew]. */
    fun stop() {
        renew()
    }
}
