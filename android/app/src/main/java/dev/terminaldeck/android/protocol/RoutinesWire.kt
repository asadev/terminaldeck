package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The routines card, as this client reads it. A port of the `routines`/`routine.*` family in
 * `src/main/remote/protocol.ts` — the saved instructions a machine runs on its own: *"what happened
 * overnight"*, *"check the work before it counts as done"*.
 *
 * ## Read, run, hold, delete. Not write.
 *
 * There is no verb on this wire that writes a routine file and this file must not grow one. Writing
 * chosen bytes into the routines folder is marked `human` on the desktop rather than given a
 * permission tier — a window is a person, a frame is not — so a routine arrives here as text to read
 * and [RoutineFile.readOnlyBecause] carries the machine's own sentence saying why there is no Save.
 *
 * ## A state a newer machine grows is drawn as it stands.
 *
 * [RoutineRow.state] is the raw word off the wire, never folded onto a neighbour, because *quiet* and
 * *broken* must not look the same and there is no honest default among the seven — see [RoutineStates].
 */
object RoutinesWire {
    /** [Capability.ROUTINES] on the host. Owner devices only — a routine runs with the machine's own
     *  tools in its own folders, so it goes where the copilot goes. */
    const val CAPABILITY = "routines"

    /** The most rows this client draws off one `routines.rows` — the host caps itself at the same. */
    const val MAX_ROUTINE_ROWS = 100

    /** The most characters of a routine file this client holds — the backstop behind the host's cut. */
    const val MAX_TEXT_CHARS = 12 * 1024

    /** The longest reason this client sends with a hold — `RoutineApi.pause` clamps to the same. */
    const val MAX_PAUSE_REASON = 300
}

/**
 * How a routine's last run ended. Null when it has never run, or when the machine could not say —
 * three answers, and a row draws all three differently. An unknown word folds to null through
 * `coerceInputValues`, so a value a newer engine grows does not fail the row.
 */
@Serializable
enum class RoutineOutcome {
    @SerialName("ok")
    Ok,

    @SerialName("failed")
    Failed,
}

/**
 * The badge each routine state is drawn as, kept out of a view so a routine reads the same on the
 * phone as on the machine it runs on. The seven phrases are `ROUTINE_STATE_TEXT`'s; a word this build
 * has never heard of is drawn as it came, which is the whole reason [RoutineRow.state] is a raw string
 * rather than an enum with no room for an eighth.
 */
object RoutineStates {
    fun badge(state: String): String = when (state) {
        "armed" -> "armed"
        "running" -> "running now"
        "disabled" -> "off in its own file"
        "broken" -> "broken"
        "unarmed" -> "nothing is listening"
        "paused" -> "paused"
        "stale" -> "stale"
        else -> state
    }
}

/**
 * One routine, as a row.
 *
 * Identified by [id] — the name of its file without the extension, and the only thing this client
 * sends back. [armed], [canRun] and [canArm] are the **host's** answers and default to on/allowed, so
 * a host too old to send one of them draws a switch that can be pressed and a refusal it will explain
 * rather than a dead control — a control that opens onto no reason is the failure this app has been
 * reviewed for by name. The `*At` fields are epoch milliseconds, absent (null) when there is no such
 * moment — *never run* and *run in 1970* are different rows.
 */
@Serializable
data class RoutineRow(
    val id: String,
    /** Cleaned for display on the host. Falls back to the id when the file names nothing. */
    val name: String = "",
    /** The first line of its prompt — what it is for, in its own words. */
    val purpose: String = "",
    /** The `when:` lines as the machine serialised them, joined. Empty for a routine with no trigger. */
    val schedule: String = "",
    /** The folder it watches and runs in. Null when it names none. */
    val folder: String? = null,
    /** The raw state word — one of seven, or a word a newer engine grew. Read through [RoutineStates]. */
    val state: String = "unarmed",
    /** Its file's own `enabled:` line. Not the switch — that is [armed]. */
    val enabled: Boolean = false,
    val paused: Boolean = false,
    /** Whether the switch on this row reads as on. Defaulted **on** for a host that did not send it. */
    val armed: Boolean = true,
    /** The engine's one sentence saying why the state is what it is. */
    val reason: String? = null,
    /** What the parser could not read, when it could not. */
    val problems: List<String> = emptyList(),
    /** When it last **finished**, epoch millis, or null. */
    val lastRunAt: Long? = null,
    val lastOutcome: RoutineOutcome? = null,
    val lastError: String? = null,
    val nextDueAt: Long? = null,
    /** When a held routine comes back on its own, or null when a person has to act. */
    val pausedUntil: Long? = null,
    /** Times a schedule came due while the machine's app was not running. */
    val missedWhileClosed: Int = 0,
    val consecutiveFailures: Int = 0,
    /** Calls its runs were not allowed to make — the boundary working, and the answer to *it ran and
     *  nothing happened*. */
    val refusedCalls: Int = 0,
    /** Defaulted **true**: a host that did not send it gets a button that refuses and explains itself. */
    val canRun: Boolean = true,
    /** Why Run now is not offered, when it is not. */
    val runBecause: String? = null,
    val canArm: Boolean = true,
    /** Why the switch cannot be moved, when it cannot. */
    val armBecause: String? = null,
) {
    /** The routine the engine stopped after it kept failing — the one case a card calls out above
     *  everything else, because in any list showing a name and a last-run time it is indistinguishable
     *  from a routine that simply has not been triggered lately. */
    val stoppedByFailures: Boolean get() = state == "paused" && consecutiveFailures > 0
}

/**
 * One routine's file, to read — the answer to a `routine.text`, and a frame in its own right.
 *
 * [file] is the file's bare name and never its path — a person looking at a trigger is not asking
 * where on the disk it lives. [readOnlyBecause] is the machine's own sentence and is **not** optional,
 * because the absence of a Save button is the thing somebody asks about; it falls back to a sentence
 * of this client's own only as a backstop, since the host always sends one. [problem] is set when the
 * file could not be read at all — deleted between the list and the tap — the frame arriving either
 * way so a screen never spins.
 */
@Serializable
@SerialName("routine.text.rows")
data class RoutineFile(
    val id: String,
    val file: String = "",
    val text: String = "",
    /** True when the file was longer than one frame carries. */
    val truncated: Boolean = false,
    val readOnlyBecause: String =
        "Routines are written where they run. This is the file as it stands there.",
    val problem: String? = null,
) : ServerMessage
