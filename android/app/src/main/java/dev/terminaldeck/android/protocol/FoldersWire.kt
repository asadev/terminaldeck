package dev.terminaldeck.android.protocol

import kotlinx.serialization.Serializable

/**
 * Walking the machine's folders, so a device can name one it cannot see — a port of the
 * `folders.pick`/`folders.browse`/`folders.entries` family in `src/main/remote/protocol.ts`.
 *
 * It reads directory names and nothing else: it grants nothing, changes nothing, writes nothing. The
 * folder a person picks is passed to the ordinary `create`, which applies exactly the rule it always
 * has — one of the owner's own devices may name any absolute folder, so `welcome.folders` is a
 * *suggestion* for that device, and this is the answer to *what is on that machine* that the
 * suggestion could not give on a bare server with nothing open on it.
 */
object FoldersWire {
    /** [Capability.FOLDER_PICK] on the host. Advertised to one of the owner's own devices only — its
     *  absence means an older host *or* a guest, and the picker draws the same either way. */
    const val CAPABILITY = "folders.pick"
}

/**
 * One sub-folder in a `folders.entries` answer.
 *
 * Both flags default the safe way for a client older than the host: an unsaid [readable] draws a row
 * somebody may try, and an unsaid [granted] draws one they may add — the machine refuses either
 * honestly, which is the layer that matters. [granted] says this folder is already shared with an
 * agent, so a screen can draw it as *Shared* rather than offering to add what is already there.
 */
@Serializable
data class FolderEntry(
    val name: String,
    val path: String,
    val readable: Boolean = true,
    val granted: Boolean = false,
)
