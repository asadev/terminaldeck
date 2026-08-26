package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The four read-only panels the desktop has and a phone did not — **artifacts, store, AI readiness,
 * MCP servers** — as this client reads them.
 *
 * A port of the `panel.*` family in `src/main/remote/protocol.ts`. One capability and one frame pair
 * for four panels, deliberately: every one of them is a list of rows a person reads and acts on, and
 * the differences between them are in the words rather than in the structure. A generic
 * [PanelData]/`panel.rows` says that honestly and gets all four onto a phone in one pass.
 *
 * The line this does **not** cross: nothing here writes a file. A [PanelAction] the host declared may
 * be sent back on a `panel.act` ([ClientMessage.PanelAct]), and the host does the write — the client
 * only ever sends an action it was handed, which is what lets a panel grow a button with no change on
 * this side and is why that is safe.
 */

/** Which of the four panels a frame is about. An unrecognised name has no screen to draw on, so —
 *  unlike an unknown enum elsewhere — it carries no fallback and refuses the frame, matching the
 *  host, which only ever answers a `panel.read` it sent by name. */
@Serializable
enum class PanelKind {
    @SerialName("artifacts")
    Artifacts,

    @SerialName("store")
    Store,

    @SerialName("readiness")
    Readiness,

    @SerialName("mcp")
    Mcp,
}

/** A row's health light. Absent is the ordinary case — a row that is neither good nor bad — and an
 *  unknown word a newer host grows folds to null through `coerceInputValues`. */
@Serializable
enum class PanelStatus {
    @SerialName("ok")
    Ok,

    @SerialName("warn")
    Warn,

    @SerialName("bad")
    Bad,
}

/**
 * One field of an action's form.
 *
 * `value` is prefilled and edited and sent back, which is what makes one action serve both *add* and
 * *edit*, so it keeps whatever the host wrote rather than being cleaned. [choices] present draws a
 * picker rather than a keyboard — the difference between choosing a scope and spelling one; absent is
 * free text.
 */
@Serializable
data class PanelField(
    val id: String,
    val label: String,
    val value: String = "",
    val placeholder: String? = null,
    val required: Boolean = false,
    val choices: List<String> = emptyList(),
)

/**
 * A button a panel offered, and the form behind it if it needs one.
 *
 * `kind` is the only thing the phone reads for itself, through [destructive]: a destructive action is
 * drawn in the warning colour and asks before it fires, because *remove this MCP server* and
 * *connect it* must not look the same under a thumb. Every other field is declared by the host and
 * drawn without this build knowing what it means.
 */
@Serializable
data class PanelAction(
    val id: String,
    val label: String,
    /** `"default"` or `"destructive"`; read through [destructive]. */
    val kind: String? = null,
    /** One line under the confirmation, for an action that cannot be undone. */
    val confirm: String? = null,
    /** Ask for these before sending. Absent means fire on the tap. */
    val fields: List<PanelField> = emptyList(),
) {
    val destructive: Boolean get() = kind == "destructive"
}

/** One of a panel's filters. */
@Serializable
data class PanelScope(
    val id: String,
    val label: String,
    val on: Boolean = false,
)

/**
 * One row of a panel, and what can be done to it.
 *
 * `id` is stable across redraws and is what a [PanelAction] on this row names on a `panel.act`; it is
 * null for a row nothing acts on. There is deliberately no client-assigned index here — a screen keys
 * a row by its position in [PanelData.rows] or by this id — because an index is a drawing concern and
 * the wire carries none.
 */
@Serializable
data class PanelRow(
    val title: String,
    val detail: String? = null,
    val value: String? = null,
    val status: PanelStatus? = null,
    val id: String? = null,
    val actions: List<PanelAction> = emptyList(),
)

/**
 * One panel's rows — the answer to a `panel.read` or a `panel.act`, and a frame in its own right.
 *
 * [panel] is required and must be one of the four: an unrecognised one is an answer with no screen to
 * be drawn on, so it refuses the frame rather than being folded. `path` is a heading and is not
 * strict — a frame that omitted it is still a panel's rows. A panel with nothing to say sends a
 * [note] rather than an empty list, so *nothing configured* is not read as *failed to load*.
 */
@Serializable
@SerialName("panel.rows")
data class PanelData(
    val panel: PanelKind,
    val path: String = "",
    /** Why the list is empty, when it is — *"nothing configured"*, in the host's words. */
    val note: String? = null,
    /** What a verb just did, when one did. */
    val notice: String? = null,
    val scopes: List<PanelScope> = emptyList(),
    val actions: List<PanelAction> = emptyList(),
    val rows: List<PanelRow> = emptyList(),
) : ServerMessage
