package dev.terminaldeck.android.store

import android.content.Context
import dev.terminaldeck.android.protocol.RemoteSessionView
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Which of a machine's sessions this phone has put away, and which it has pulled to the top.
 *
 * Asad, asking for the swipe: *"close the session (with a confirmation), archive, move. When we will
 * have a lot of sessions we will not like to have all of them over here."* This is the *over here* —
 * the place a row goes, and therefore the place it comes back from. A transcription of
 * `ios/TerminalDeck/App/SessionShelf.swift`.
 *
 * ## It is about this phone, not about the machine
 *
 * Nothing here reaches the wire and nothing here stops a session. Archiving is a **view** on a list
 * this device is shown; the agent on the other machine carries on exactly as it was. That is the one
 * thing about this feature that can be dangerously misread, which is why the screen that lists the
 * archived rows says it in a sentence rather than leaving it to be inferred.
 *
 * ## Pure over a store, so the ordering rules can be tested
 *
 * [split] is a function of values with no Android in it, for the reason the wire codecs are: every
 * rule about ordering can be pinned by a unit test with no device, and the list screen makes one
 * call rather than holding three predicates that could drift out of step.
 */
class SessionShelf(private val store: Store) {

    /** Where the shelf is kept. A seam so a test can drive one that is not a device's disk. */
    interface Store {
        fun read(): String?
        fun write(value: String)
    }

    /**
     * host id → the session ids that machine's list should not draw, in the order they were archived.
     *
     * A list rather than a set, and the order is what makes [trim] possible: dropping the oldest
     * needs an oldest, and a set has none. Lookup is a linear scan over at most [MAX_PER_HOST] short
     * strings, which is nothing next to the work of drawing the row it decides about.
     */
    private val archived = HashMap<String, List<String>>()

    /** host id → the session ids pinned to the top, most recently pinned first. */
    private val pinned = HashMap<String, List<String>>()

    init {
        load()
    }

    fun isArchived(host: String, session: String): Boolean = archived[host]?.contains(session) == true

    /** Every archived id on one machine, for the screen that lists them. */
    fun archived(host: String): List<String> = archived[host].orEmpty()

    /**
     * Put a row away, or bring it back.
     *
     * Archiving also **unpins**, because the two states contradict each other: a row cannot be both
     * at the top of the list and absent from it, and leaving a stale pin behind would make an
     * unarchive jump the row to the top for reasons nobody could see. Unarchiving does not re-pin — a
     * row that comes back comes back where it belongs.
     */
    fun setArchived(on: Boolean, host: String, session: String) {
        if (host.isEmpty() || session.isEmpty()) return
        if (on) {
            setPinned(false, host, session, save = false)
            val ids = archived[host].orEmpty()
            if (session in ids) return
            archived[host] = trim(ids + session)
        } else {
            val ids = archived[host].orEmpty().filterNot { it == session }
            if (ids.isEmpty()) archived.remove(host) else archived[host] = ids
        }
        save()
    }

    fun isPinned(host: String, session: String): Boolean = pinned[host]?.contains(session) == true

    fun setPinned(on: Boolean, host: String, session: String) = setPinned(on, host, session, save = true)

    /**
     * Pinning also **unarchives**, the mirror of the rule above and for the same reason: pinning
     * something is a statement that it matters, and the only honest response to that is to put it
     * back on the screen.
     *
     * The private save flag exists so the two verbs can call each other without writing the store
     * twice for one gesture. Not an optimisation — a double write is cheap — but so that a reader of
     * [setArchived] sees one save at the end of it and knows there is exactly one commit point.
     */
    private fun setPinned(on: Boolean, host: String, session: String, save: Boolean) {
        if (host.isEmpty() || session.isEmpty()) return
        if (on) {
            val left = archived[host].orEmpty().filterNot { it == session }
            if (left.isEmpty()) archived.remove(host) else archived[host] = left
            // Newest first: the row somebody just pinned goes to the very top, which is where they
            // are looking when they let go of the swipe.
            val ids = listOf(session) + pinned[host].orEmpty().filterNot { it == session }
            pinned[host] = ids.take(MAX_PER_HOST)
        } else {
            val ids = pinned[host].orEmpty().filterNot { it == session }
            if (ids.isEmpty()) pinned.remove(host) else pinned[host] = ids
        }
        if (save) save()
    }

    /** A machine that was forgotten. Its shelf goes with it rather than waiting for a re-pair. */
    fun forget(host: String) {
        if (archived.remove(host) == null && pinned.remove(host) == null) return
        save()
    }

    /**
     * Split one machine's sessions into what the list draws and what it hides.
     *
     * The pinned rows keep **the order they were pinned in**, not the order the machine sent. That is
     * the whole point of the gesture: a person who pins two sessions is stating which one they want
     * first, and re-sorting them by whatever the machine's list order happens to be would throw that
     * away. The rest keep the machine's order exactly, because that order is the machine's and this
     * has no business having an opinion about it.
     */
    fun split(sessions: List<RemoteSessionView>, host: String): Split {
        if (host.isEmpty()) return Split(sessions, emptyList())
        val hidden = archived[host].orEmpty()
        val order = pinned[host].orEmpty()
        if (hidden.isEmpty() && order.isEmpty()) return Split(sessions, emptyList())

        val listed = mutableListOf<RemoteSessionView>()
        val away = mutableListOf<RemoteSessionView>()
        val top = mutableListOf<RemoteSessionView>()
        for (session in sessions) {
            when {
                session.id in hidden -> away += session
                session.id in order -> top += session
                else -> listed += session
            }
        }
        // Sorted by where the id sits in the pin list rather than by the machine's order. The index
        // cannot be missing — every member of `top` was put there by the check above — and the
        // fallback keeps this total rather than throwing if that ever stops being true.
        top.sortBy { order.indexOf(it.id).takeIf { index -> index >= 0 } ?: 0 }
        return Split(top + listed, away)
    }

    /**
     * How many of one machine's *current* sessions are archived.
     *
     * Measured against the live list rather than against the store: a machine that has been rebooted
     * has archived ids for sessions that no longer exist, and a count of those is a menu item that
     * opens onto nothing.
     */
    fun archivedCount(sessions: List<RemoteSessionView>, host: String): Int =
        split(sessions, host).archived.size

    data class Split(val listed: List<RemoteSessionView>, val archived: List<RemoteSessionView>)

    /* ------------------------------------------------------------------- storage -- */

    @Serializable
    internal data class Stored(
        val archived: Map<String, List<String>> = emptyMap(),
        val pinned: Map<String, List<String>> = emptyMap(),
    )

    private fun load() {
        val raw = store.read() ?: return
        val stored = try {
            JSON.decodeFromString(Stored.serializer(), raw)
        } catch (_: Exception) {
            // A record written by another build, or half-written when the process died. A shelf that
            // refused to load would be an app that shows an archived session again on every launch.
            return
        }
        // Bounded on the way back out as well as on the way in: a record written by another build
        // must not be able to get around the limit this store promises to hold.
        archived.clear()
        pinned.clear()
        for ((host, ids) in stored.archived) archived[host] = trim(ids)
        for ((host, ids) in stored.pinned) pinned[host] = ids.take(MAX_PER_HOST)
    }

    private fun save() {
        store.write(JSON.encodeToString(Stored.serializer(), Stored(archived.toMap(), pinned.toMap())))
    }

    companion object {
        /**
         * The most rows one machine's shelf may hold.
         *
         * A bound rather than none, because this is written on every swipe and read on every launch:
         * an unbounded list of ids for sessions that stopped existing months ago is a file that only
         * grows. Two hundred is far past any real list and far below anything that costs a frame.
         */
        const val MAX_PER_HOST = 200

        private val JSON = Json { ignoreUnknownKeys = true }

        private fun trim(ids: List<String>): List<String> =
            if (ids.size <= MAX_PER_HOST) ids else ids.takeLast(MAX_PER_HOST)

        private const val FILE = "terminaldeck.preferences"
        private const val KEY = "terminaldeck.sessionShelf.v1"

        /** The real store: the same preferences file the appearance and the alert switches use. */
        fun on(context: Context): SessionShelf = SessionShelf(object : Store {
            private val prefs =
                context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

            override fun read(): String? = prefs.getString(KEY, null)

            override fun write(value: String) {
                prefs.edit().putString(KEY, value).apply()
            }
        })
    }
}
