package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.FolderEntry
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Walking the machine's folders on a phone, so somebody can start a session in one they cannot see.
 *
 * The data half of [dev.terminaldeck.android.ui.FolderPickerScreen], and a port of the `browsed` /
 * `browseFolders` / `endBrowsing` shape iOS keeps on `HostLink`. It reads directory names off the
 * machine and nothing else: it grants nothing, changes nothing, writes nothing. The folder somebody
 * picks is handed to the ordinary `create`, which applies the rule it always has — one of the
 * owner's own devices may name any absolute folder, so `welcome.folders` is a *suggestion* for that
 * device, and this is the answer to *what is on that machine* the suggestion could not give on a
 * bare server with nothing open on it.
 *
 * ## One instance, pointed at the machine on screen
 *
 * Unlike [DeviceRosterController] and the others there is one of these for the whole app rather than
 * one per [HostLink], because the picker is only ever open for the machine on screen and sends every
 * `folders.browse` to that one. Its [send] is the view model's, which resolves the selected machine
 * each time rather than capturing one — so a picker opened after a machine switch browses the right
 * computer without this holding a link that could go stale.
 *
 * ## Late answers are dropped, not drawn
 *
 * [browsing] is what the picker last asked for, and it is cleared the moment the screen leaves. An
 * answer that arrives for a folder nobody is looking at any more — the screen closed, or a second
 * tap overtook the first — lands in [receive] and is discarded, because drawing it would put the
 * old folder's contents under whatever heading is on screen now.
 */
class FolderBrowseController(
    private val send: (ClientMessage) -> Boolean,
) {
    private val _state = MutableStateFlow(FolderBrowseView())
    val state: StateFlow<FolderBrowseView> = _state.asStateFlow()

    /**
     * What the picker last asked for, so a stale answer can be told from the current one. Null when
     * nothing is browsing, which is also the flag [open] reads to decide whether the first listing
     * still needs asking for. An empty string means "the machine's own sensible default was asked
     * for" — a real request in flight, distinct from null.
     */
    private var browsing: String? = null

    /**
     * Open the picker wherever the machine thinks is sensible, once, if nothing is loaded yet.
     *
     * Asked here rather than by the caller so every way in — a menu, an empty state — lands on a
     * screen that is already loading rather than one that needs a second press to fill. Idempotent:
     * a screen that recomposes on its way in does not fire a second browse over the first.
     */
    fun open() {
        if (browsing == null && _state.value.listing == null) browse(null)
    }

    /**
     * Ask the machine what is inside a folder. Null opens it wherever the machine thinks is sensible
     * — the folder this device already works in. The phone deliberately does not guess a starting
     * path: it does not know whether this machine's home is `/Users/apple`, `/root` or
     * `C:\Users\asad`, and a wrong guess opens the picker on an error.
     */
    fun browse(path: String?) {
        // Cleared rather than left standing: the rows on screen belong to the folder being left, and
        // holding them through the round trip shows the old folder's contents under the new heading.
        browsing = path ?: ""
        _state.value = FolderBrowseView(listing = null, error = null, loading = true)
        if (!send(ClientMessage.BrowseFolders(path))) {
            browsing = null
            _state.value = FolderBrowseView(listing = null, error = "Not connected to this machine.", loading = false)
        }
    }

    /**
     * A `folders.entries` answer off the wire. Returns true when the frame was one of this section's,
     * so [DeckViewModel.onFrame] can route it here and stop; a frame that arrives while no picker is
     * open is claimed and dropped, which is the same outcome as it having no screen at all.
     */
    fun receive(message: ServerMessage): Boolean {
        if (message !is ServerMessage.FolderEntries) return false
        if (browsing == null) return true
        browsing = null
        _state.value = FolderBrowseView(
            listing = FolderListing(message.path, message.parent, message.entries),
            error = null,
            loading = false,
        )
        return true
    }

    /** Leave the picker, so a late answer for a folder nobody is looking at is dropped rather than
     *  drawn, and the next open starts from the machine's own default instead of the last walk. */
    fun end() {
        browsing = null
        _state.value = FolderBrowseView()
    }
}

/**
 * What the folder picker reads.
 *
 * [listing] null with [loading] true is "reading…"; [error] is why the last browse could not be
 * shown, if it could not. The three are a small state machine: exactly one of listing / error is
 * ever set, and loading is true only in the gap before either arrives.
 */
data class FolderBrowseView(
    val listing: FolderListing? = null,
    val error: String? = null,
    val loading: Boolean = false,
)

/**
 * The folder the picker is showing, once the machine has answered.
 *
 * [parent] is null at the very top, which is what the "up" row is drawn from — working it out on the
 * phone would mean a phone that knows where the root is on Windows. [entries] carries `readable` and
 * `granted` per row, which is what draws a locked folder dimmed and a shared one as *Shared*.
 */
data class FolderListing(
    val path: String,
    val parent: String?,
    val entries: List<FolderEntry>,
)
