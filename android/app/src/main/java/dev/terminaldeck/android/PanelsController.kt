package dev.terminaldeck.android

import androidx.compose.runtime.mutableStateMapOf
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.PanelData
import dev.terminaldeck.android.protocol.PanelKind
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The four read-only panels the desktop has and a phone did not — **artifacts, store, AI readiness,
 * MCP servers** — as this phone reads and acts on them.
 *
 * The client half of [dev.terminaldeck.android.protocol.Capability.PANELS]. One capability and one
 * frame pair for four panels, deliberately: every one of them is a list of rows a person reads and
 * acts on, and the differences between them are in the words rather than in the structure — see
 * `PanelsWire.kt`. So this controller knows nothing about what a store row or an MCP scope *means*; it
 * sends the `panel.read` and the `panel.act` the screen hands it and holds the `panel.rows` that come
 * back.
 *
 * ## The one line this does not cross
 *
 * Nothing here writes a file. A [dev.terminaldeck.android.protocol.PanelAction] the host declared may
 * be sent back on a `panel.act`, and the host does the write — the client only ever sends an action it
 * was handed, which is what lets a panel grow a button with no change on this side.
 *
 * ## An answer per panel
 *
 * The artifact opener reads the artifacts panel's answer while a panel screen reads its own, so the
 * latest [PanelData] is kept **per [PanelKind]** rather than as a single most-recent. An act answers
 * with the same panel a read would have — the contract's own rule — so a screen never re-reads after
 * acting: the rows arriving are the confirmation.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this controller's.
 */
class PanelsController(
    private val send: (ClientMessage) -> Boolean,
) {
    /** The latest answer for each panel, so four panels do not clobber one another. Compose state, so
     *  a screen reading one key recomposes when that panel answers and no other surface is refolded. */
    private val answers = mutableStateMapOf<PanelKind, PanelData>()

    /** The latest rows for one panel, or null before its first answer. Read by the panel screen and,
     *  for the artifacts panel, by the artifact opener while it waits for a preview address. */
    fun data(panel: PanelKind): PanelData? = answers[panel]

    /**
     * Read one panel.
     *
     * [path] null means *somewhere sensible*, which the host answers as this device's first granted
     * folder; a screen with a folder passes it so the answer is about the project the list came from.
     * Empty search is sent as *nothing* rather than an empty string, so a host that distinguishes the
     * two sees the same request a screen with no field at all would send.
     */
    fun read(panel: PanelKind, path: String? = null, scope: String? = null, query: String? = null) {
        send(ClientMessage.PanelRead(panel = panel.wire, path = path, scope = scope, query = query))
    }

    /**
     * Do the thing a panel offered.
     *
     * [action] is a string this build never interprets — it came off a [dev.terminaldeck.android
     * .protocol.PanelAction] the host itself sent in the last [PanelData], and it goes straight back.
     * [id] names a row for a row's action and is null for the panel's own; [fields] is one action's
     * form filled in. The answer is a fresh [PanelData] for the same panel.
     */
    fun act(
        panel: PanelKind,
        action: String,
        path: String? = null,
        id: String? = null,
        scope: String? = null,
        query: String? = null,
        fields: Map<String, String>? = null,
    ) {
        send(
            ClientMessage.PanelAct(
                panel = panel.wire,
                action = action,
                path = path,
                id = id,
                scope = scope,
                query = query,
                fields = fields,
            )
        )
    }

    fun receive(message: ServerMessage): Boolean = when (message) {
        is PanelData -> {
            answers[message.panel] = message
            true
        }

        else -> false
    }

    /** Forget what the last connection said, for the reason [FilesGitController.renew] gives: an
     *  answer belongs to whichever machine this connection reaches, and the screens re-read on appear. */
    fun renew() {
        answers.clear()
    }

    /** A machine being taken down. Nothing here holds a timer or a socket, so this is [renew]. */
    fun stop() {
        renew()
    }
}

/**
 * The wire's own word for a panel — `artifacts`, `store`, `readiness`, `mcp` — which is what
 * `panel.read` and `panel.act` carry.
 *
 * Spelled out here rather than reflected off the `@SerialName`, because a `panel` field on the wire is
 * a plain string the host matches by value, and the one place that turns the typed kind back into that
 * string should be a `when` the compiler checks is exhaustive rather than a serializer detail read at a
 * distance. It mirrors the `@SerialName`s on [PanelKind] in `PanelsWire.kt`.
 */
private val PanelKind.wire: String
    get() = when (this) {
        PanelKind.Artifacts -> "artifacts"
        PanelKind.Store -> "store"
        PanelKind.Readiness -> "readiness"
        PanelKind.Mcp -> "mcp"
    }
