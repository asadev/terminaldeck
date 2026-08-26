package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.RoutineFile
import dev.terminaldeck.android.protocol.RoutineRow
import dev.terminaldeck.android.protocol.RoutinesWire
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The machine's saved instructions — its routines — as this phone reads and drives them. The client
 * half of [RoutinesWire.CAPABILITY], a transcription of the `routine.*` handling in
 * `ios/TerminalDeck/App/CopilotLink.swift`, drawn by `CopilotRoutinesView.swift`.
 *
 * Asad, naming what these are: *"'check the work before it counts as done', 'what happened
 * overnight' … all of these are like separate settings for co-pilot."* Each name is one file in the
 * machine's routines folder, with a trigger, a folder and a prompt.
 *
 * ## Read, run, hold, delete. Not write.
 *
 * There is no verb here that writes a routine file and this class must not grow one — writing chosen
 * bytes into the routines folder is wider than the alter tier, so a routine arrives as text to read
 * and [RoutineFile.readOnlyBecause] carries the machine's own sentence saying why there is no Save.
 *
 * ## Nothing about state is worked out here
 *
 * Whether the switch reads as on, whether Run now can be pressed, and why not, all arrive already
 * decided — `armed`, `canRun`, `runBecause`, `canArm`, `armBecause`. The short version of
 * [RoutinesWire]'s argument is the failure it prevents: *a routine that looks armed on a phone and
 * is not*. The redraw is the confirmation and [RoutinesRows.notice] says what the last press did.
 */
class CopilotRoutinesController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val onChange: () -> Unit,
) {

    private var routines: List<RoutineRow> = emptyList()

    /** Whether a `routines.rows` has ever arrived — *there are none* is a fact about a machine that
     *  replied, *Reading…* is a frame in flight, and they look identical in any list with a count. */
    private var answered = false
    private var loading = false

    /** One line about what the last press did — the engine's own words, never this app's, because a
     *  run that refused to start is the only place a spent budget is ever explained. */
    private var notice: String? = null

    /** The routine whose file is being read, and the file itself. The id travels on the frame so a
     *  file that arrives for one somebody has navigated away from is not drawn under this heading. */
    private var openId: String? = null
    private var routineFile: RoutineFile? = null

    /** Whether this machine holds a routine engine this phone may drive. The screen is absent, not
     *  disabled, without it — a separate capability from the copilot's own, on purpose. */
    fun offered(): Boolean = capabilities().contains(RoutinesWire.CAPABILITY)

    /** A snapshot the routines screen and its file viewer draw from, or null when none is offered. */
    fun view(): CopilotRoutinesView? {
        if (!offered()) return null
        return CopilotRoutinesView(
            routines = routines,
            answered = answered,
            loading = loading,
            notice = notice,
            openId = openId,
            routineFile = routineFile,
        )
    }

    /* --------------------------------------------------------------------- verbs -- */

    /** Every routine on that machine. Carries nothing — one folder per machine — and it is the
     *  answer to each of the four verbs below as well as to itself. */
    fun load() {
        if (!offered()) return
        if (!send(ClientMessage.Routines)) return
        loading = true
        onChange()
    }

    /** Run this one now, whatever its triggers say. Starts an agent turn on that machine. The engine
     *  has the last word; a row's [RoutineRow.canRun] covers only the refusals certain before the tap. */
    fun run(id: String) {
        if (!offered()) return
        send(ClientMessage.RoutineRun(id))
    }

    /** Hold it. Its file is not touched — a hold is engine state beside the file. The reason is the
     *  phone's half of the sentence the desktop writes for the same press at the machine. */
    fun hold(id: String) {
        if (!offered()) return
        send(ClientMessage.RoutinePause(id, HELD_FROM_HERE))
    }

    /** Let it go again. Clears the hold and the failure count with it. */
    fun arm(id: String) {
        if (!offered()) return
        send(ClientMessage.RoutineResume(id))
    }

    /** Delete it. Its file is removed from the machine's disk. The confirmation is the screen's — a
     *  confirmation is a thing a person sees — so the protocol carries none. */
    fun delete(id: String) {
        if (!offered()) return
        send(ClientMessage.RoutineDelete(id))
    }

    /** Read one routine's file. There is no frame that writes one back. */
    fun openRoutine(id: String) {
        if (!offered()) return
        openId = id
        routineFile = null
        send(ClientMessage.RoutineText(id))
        onChange()
    }

    fun closeRoutine() {
        openId = null
        routineFile = null
        onChange()
    }

    fun dismissNotice() {
        if (notice == null) return
        notice = null
        onChange()
    }

    /* -------------------------------------------------------------------- frames -- */

    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.RoutinesRows -> {
                routines = message.routines
                answered = true
                loading = false
                // Set directly, including to null on a plain reload: the notice is the answer to an
                // act, and a fresh list with no notice is the machine saying the last thing has been
                // superseded. It is put away by hand otherwise — see [dismissNotice].
                notice = message.notice
            }

            is RoutineFile -> {
                // Kept whichever routine it is for; the file viewer draws it only when its id matches
                // the one it is standing on, so an answer for a routine left behind is simply unused.
                routineFile = message
            }

            else -> return false
        }
        onChange()
        return true
    }

    fun stop() {
        routines = emptyList()
        answered = false
        loading = false
        notice = null
        closeRoutine()
    }

    companion object {
        /** The reason sent with a hold, so the machine's own list says where it came from. The
         *  desktop writes *"Paused from Settings."* for the same press at the machine. */
        const val HELD_FROM_HERE = "Held from a phone."
    }
}

/** What the routines screen and its file viewer read. */
data class CopilotRoutinesView(
    val routines: List<RoutineRow>,
    val answered: Boolean,
    val loading: Boolean,
    val notice: String?,
    val openId: String?,
    val routineFile: RoutineFile?,
)
