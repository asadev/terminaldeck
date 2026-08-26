package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The copilot's own files — its instructions, its memory, its contract — as one of his devices reads
 * them. A port of `CopilotFileRow` and the `copilot.file*` family in `src/main/remote/protocol.ts`.
 *
 * ## The rule that makes them safe: no path is ever on the wire
 *
 * There is no filename in any frame here and no path on any row. An [CopilotFileRow.id] is one of four
 * fixed words — `yours`, `contract`, `composed`, `folder` — or `memory:` and a name; the host resolves
 * it by looking it up, never by joining it onto anything. [CopilotFiles.isFileId] is this end's copy
 * of that check, so a `copilot.file.read`/`.write`/`.reset` this build constructs names a file that
 * exists rather than a path it composed.
 */
object CopilotFiles {
    /** The four fixed files. `COPILOT_FILE_IDS` in `protocol.ts`. */
    val FILE_IDS = listOf("yours", "contract", "composed", "folder")

    /** How a memory file is addressed: this word, then its name. `COPILOT_MEMORY_PREFIX`. */
    const val MEMORY_PREFIX = "memory:"

    /** The most bytes of one file this wire carries. A file over this comes back with no text and a
     *  sentence naming its size — half a file is the one thing that must not arrive. */
    const val MAX_FILE_BYTES = 32 * 1024

    /** The most rows one `copilot.files.rows` is drawn from — the host caps itself at the same. */
    const val MAX_FILE_ROWS = 200

    /**
     * Whether an id is one this build can address — a fixed word, or `memory:` and a non-empty name.
     *
     * The name is not validated past *non-empty* here: the strict memory-name rule lives on the host,
     * which checks it again before anything is unlinked, and a client that re-derived it would be
     * keeping a second copy of a rule that decides what `rm` sees.
     */
    fun isFileId(id: String): Boolean =
        id in FILE_IDS || (id.startsWith(MEMORY_PREFIX) && id.length > MEMORY_PREFIX.length)
}

/**
 * Whose file this is, as the badge beside a row. The host decides this and sends it; nothing here
 * derives it from an id, because a client that worked ownership out from a filename would be keeping a
 * copy of a rule that lives on the machine.
 *
 *  - [App] — under the desktop's own storage, rewritten on every start: the tool contract and the
 *    composed file.
 *  - [Yours] — seeded once and never touched again: the copilot's instructions.
 *  - [Folder] — in the working folder, which may be a workspace of his own: `CLAUDE.md` and memory.
 *
 * [Unknown] is where a word a newer host grows folds. iOS drops such a row; this keeps it so one odd
 * memory row cannot take the copilot's instructions off the screen, and leaves hiding it to a screen.
 */
@Serializable
enum class CopilotFileOwner {
    @SerialName("app")
    App,

    @SerialName("yours")
    Yours,

    @SerialName("folder")
    Folder,

    @SerialName("unknown")
    Unknown,
}

/**
 * One of the copilot's files, described without being opened.
 *
 * [id] is the word to send back and the only thing this phone ever says about a file — there is no
 * path on this row and there must never be one. [size] and [modifiedAt] are null when the file is not
 * there rather than a plausible zero, so a number beside [exists] false cannot contradict it — the
 * folder's own `CLAUDE.md` is normally exactly that case, and its absence is the most reassuring row
 * on the screen. [writable] is carried rather than inferred so a Save button is drawn only where one
 * can work: false for the two generated files, and false for anything already too large to have been
 * sent whole.
 */
@Serializable
data class CopilotFileRow(
    val id: String,
    /** The file's own name — `instructions.md`, `CLAUDE.md`. Never a path. */
    val name: String = "",
    /** What it is for, in a phrase to print as-is. For a memory row, the `description:` the copilot
     *  itself wrote. */
    val purpose: String = "",
    val owner: CopilotFileOwner = CopilotFileOwner.Unknown,
    val exists: Boolean = false,
    /** Bytes on disk, or null when the file is not there. */
    val size: Long? = null,
    /** Last modified, epoch milliseconds, or null when the file is not there. */
    val modifiedAt: Long? = null,
    /** Whether a save would be served — false for the two generated files and anything too large. */
    val writable: Boolean = false,
) {
    /** A memory file rather than one of the four fixed ones — carried by the id's prefix, because it
     *  *is* the id: the prefix is the addressing scheme, not a flag. */
    val isMemory: Boolean get() = id.startsWith(CopilotFiles.MEMORY_PREFIX)

    /** The copilot's own instructions — the one file that changes what the copilot *is*, and the only
     *  one with a Restore. */
    val isOwnInstructions: Boolean get() = id == "yours"

    /** The name a memory file is deleted by — see [ClientMessage.CopilotMemoryDelete]. Null otherwise. */
    val memoryName: String?
        get() = if (isMemory) id.removePrefix(CopilotFiles.MEMORY_PREFIX) else null
}
