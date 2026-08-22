package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The session's control cluster on the wire — model, effort, fast mode, permission — and the
 * narrowing that turns a `controls.reading` into it.
 *
 * A transcription of the reading half of `src/main/remote/protocol.ts` (`ControlName`,
 * `ControlReadingWire`, `ControlsReadingWire`) and of the same port iOS keeps in
 * `ios/TerminalDeck/Protocol/ControlsWire.swift`. Nothing here is new protocol: `controls.read` and
 * `controls.apply` have been answered by every desktop since 0.5.0 — the desktop's own remote
 * window already sends them — and this client simply never did, which is why an Android phone could
 * watch a session and not once change what it runs at.
 *
 * ## Why the reading is narrowed here rather than carried
 *
 * The `ControlsReadingWire` the desktop composes is total over its own shapes because the client it
 * was designed for is another copy of the desktop. This app is not that client, so every field
 * carries a default: a sub-object this build cannot make sense of narrows to [ControlReadingWire
 * .EMPTY], which draws the unread label, rather than failing the whole frame. `source` is dropped
 * rather than narrowed — a build newer or older than this one may name a source it has no word for,
 * and nothing on a phone prints source notes, so the honest translation is to drop it (the same call
 * `asCatalogReading` in `pwa/src/session-controls.ts` makes).
 */

/**
 * The four controls, named on the wire.
 *
 * A frozen set for the reason the desktop's `CONTROL_IDS` is: the value selects a branch that types
 * into somebody's terminal, and a name nothing recognises must be unrepresentable rather than merely
 * refused. Outbound only — `controls.apply` carries one of these, so this client cannot express a
 * frame the desktop's parser would close the socket over.
 */
@Serializable
enum class ControlName {
    @SerialName("model")
    Model,

    @SerialName("effort")
    Effort,

    @SerialName("fast")
    Fast,

    @SerialName("permission")
    Permission,
}

/**
 * One control's current reading, as the far machine read it.
 *
 * [value] and [label] are null together when nothing real could be read. [unavailableReason] travels
 * because the whole value of it is the wording — it is the sentence a blocked chip opens onto, and a
 * sentence composed on this side would be this phone guessing at the far machine's reason.
 */
@Serializable
data class ControlReadingWire(
    val value: String? = null,
    val label: String? = null,
    val unavailableReason: String? = null,
) {
    /** The reading as bounded for display: an over-long model name cannot push a chip off screen. */
    val shortValue: String? get() = value?.take(Protocol.MAX_CONTROL_VALUE_LENGTH)

    companion object {
        val EMPTY = ControlReadingWire()
    }
}

/** Whether an agent CLI is drawing that session's screen over there. */
@Serializable
data class ControlAgentWire(val running: Boolean = false, val saw: String? = null)

/**
 * Whether a command could be typed at that session this instant, and the far end's sentence for why
 * not. What lets a remote chip grey out for the same reasons a local one does.
 */
@Serializable
data class ControlGateWire(val canType: Boolean = false, val reason: String? = null)

/** Everything one session's control cluster needs, in one answer. */
@Serializable
data class ControlsReadingWire(
    val model: ControlReadingWire = ControlReadingWire.EMPTY,
    val effort: ControlReadingWire = ControlReadingWire.EMPTY,
    val fast: ControlReadingWire = ControlReadingWire.EMPTY,
    val permission: ControlReadingWire = ControlReadingWire.EMPTY,
    /** False when the far end had no such session, so nothing could be read. */
    val live: Boolean = false,
    /**
     * A model menu over `/bin/zsh` is the defect the desktop's own cluster withdraws itself for, so
     * this app draws nothing when [ControlAgentWire.running] is false.
     */
    val agent: ControlAgentWire = ControlAgentWire(),
    /**
     * Absent gate reads as "cannot type" — the safe reading, which greys the chips rather than
     * offering a press that would be refused.
     */
    val gate: ControlGateWire = ControlGateWire(),
) {
    /** One control's reading, by name — so a caller can loop over [ControlName]. */
    fun reading(control: ControlName): ControlReadingWire = when (control) {
        ControlName.Model -> model
        ControlName.Effort -> effort
        ControlName.Fast -> fast
        ControlName.Permission -> permission
    }

    /**
     * One field replaced by an apply's re-read — the row that ticks is the one the session is
     * actually on, never the one that was pressed. Mirrors `appliedTo` in the PWA, which is what
     * makes a refused apply revert by construction.
     */
    fun applying(control: ControlName, answer: ControlReadingWire): ControlsReadingWire = when (control) {
        ControlName.Model -> copy(model = answer)
        ControlName.Effort -> copy(effort = answer)
        ControlName.Fast -> copy(fast = answer)
        ControlName.Permission -> copy(permission = answer)
    }
}

/**
 * The pure decisions, transcribed from the exported functions of `pwa/src/session-controls.ts`.
 *
 * Kept out of the composable so that the one part of this surface with a decision in it can be
 * tested where a composable cannot.
 */
object SessionControls {

    /**
     * Whether there is a cluster to draw at all.
     *
     * Three answers fold to false: no reading has landed, the far end had no such session, or the
     * session is a plain shell. Absent, not greyed — the desktop's own cluster withdraws itself
     * over `/bin/zsh` and a phone that drew four dead chips there would be claiming a session has an
     * agent when it does not.
     */
    fun clusterShown(reading: ControlsReadingWire?): Boolean =
        reading != null && reading.live && reading.agent.running

    /**
     * Why nothing can be changed at this instant, for one control, or null.
     *
     * The control's own `unavailableReason` first — every sentence here is the far end's — then the
     * typing gate. The one fallback claims only what is known: nothing was sent.
     */
    fun blocked(control: ControlName, reading: ControlsReadingWire): String? {
        val barred = reading.reading(control).unavailableReason
        if (!barred.isNullOrEmpty()) return barred
        if (!reading.gate.canType) {
            return reading.gate.reason?.takeIf { it.isNotEmpty() }
                ?: "This session cannot be typed into right now, so nothing was sent."
        }
        return null
    }

    /** What a chip prints: the value alone, never the control's name beside it. */
    fun chipText(control: ControlName, reading: ControlsReadingWire): String =
        ControlCatalog.displayValue(reading.reading(control), control)

    /** Whether an option is the one in force, for this control's reading. */
    fun chosen(reading: ControlReadingWire, option: ControlOption): Boolean =
        ControlCatalog.isCurrent(reading, option)

    /**
     * The value to send when the fast switch is pressed — computed from the reading, never from what
     * the switch looks like, so a stale picture cannot send "on" to a session already on.
     */
    fun fastFlip(reading: ControlReadingWire): String = if (reading.value == "on") "off" else "on"
}
