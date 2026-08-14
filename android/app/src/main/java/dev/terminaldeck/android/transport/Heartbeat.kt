package dev.terminaldeck.android.transport

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * One timer, every socket.
 *
 * ## Why the ping cannot simply be dropped
 *
 * A long-lived TCP connection through a carrier NAT dies silently when the mapping is reclaimed,
 * which happens after 30–60 seconds of silence on most mobile networks; TCP keepalive defaults to
 * hours and does not save it. A phone holding a socket open to a machine therefore has to say
 * something regularly or it will discover the socket is dead only when somebody types into it — and
 * "somebody types into it" is the one moment this app must not be wrong about. So the poll is
 * load-bearing rather than laziness: dropping it does not save work, it loses sessions.
 *
 * ## Why there is exactly one of them
 *
 * Every paired machine holds its own socket and every socket needs that ping, so N machines on N
 * independent timers is N chances per cycle to wake the radio out of its idle state. The radio is
 * the expensive part, not the CPU: a wake-up costs about the same whether one byte or five hundred
 * follow it, and it holds the radio in a high-power state for seconds afterwards. Three
 * unsynchronised 25-second timers cost roughly three times what three synchronised ones do, for
 * identical traffic.
 *
 * Folding them into one tick makes the whole set cost one wake-up: every host's ping goes out in the
 * same turn of the loop, into the same radio window, and the answers come back into it.
 *
 * ## The cadence, and what it adds up to
 *
 * One tick every **25 seconds** — comfortably under the 30 after which idle NAT and proxy entries
 * start being reclaimed — so 144 ticks an hour whatever the number of machines. A `ping` is 12 bytes
 * of JSON and a `pong` 14, which the sealed envelope and the WebSocket frame carry to roughly 60 and
 * 62 on the wire. Three paired machines is therefore about 53 KB an hour of keepalive across all of
 * them, in 144 radio windows rather than 432.
 *
 * ## Two phases, still one timer
 *
 * The tick sends, waits out the grace, and then asks every member whether it was answered. That
 * second pass wakes the CPU and sends nothing, so it costs no radio window at all — which is why it
 * is worth keeping the honest 10-second deadline rather than folding the check into the next tick
 * and taking a minute to notice a dead socket.
 */
class Heartbeat(
    /**
     * Where the loop runs. Defaulted to a scope of this class's own rather than taken from a
     * caller: the tick outlives any one transport, and a loop parented to the first transport's
     * scope would stop the moment that machine was forgotten, silently taking the keepalive for
     * every other machine with it.
     */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val intervalMs: Long = INTERVAL_MS,
    private val graceMs: Long = GRACE_MS,
) {

    /**
     * What a socket does when the tick comes round.
     *
     * Two calls rather than one, because a keepalive is a question and an answer and only the
     * member knows whether its answer arrived.
     */
    interface Member {

        /**
         * Say something on this socket.
         *
         * False means there is nothing to say it on any more, and the member is dropped from the
         * tick rather than asked again — a transport that has torn its socket down must not keep a
         * timer alive on the strength of having once joined one.
         */
        fun ping(): Boolean

        /** The grace has run out. Answered or not, the member decides what that means. */
        fun pongDue()
    }

    private val lock = Any()
    private val members = LinkedHashMap<Any, Member>()
    private var loop: Job? = null

    /** Only the tests read these, to prove there is one loop and that it stops. */
    val memberCount: Int get() = synchronized(lock) { members.size }

    val isTicking: Boolean get() = synchronized(lock) { loop?.isActive == true }

    /**
     * Beat with everyone else.
     *
     * Keyed by the owner rather than by the member, so a transport that reconnects replaces its own
     * entry instead of accumulating one per connection — which would have every socket pinged as
     * many times per tick as it had ever been opened.
     */
    fun join(owner: Any, member: Member) {
        synchronized(lock) {
            members[owner] = member
            start()
        }
    }

    fun leave(owner: Any) {
        synchronized(lock) {
            members.remove(owner)
            // Stopped rather than left spinning over an empty set. A timer with nothing to do is
            // pure cost, and on a phone it is cost that shows up in a battery screen with this
            // app's name against it.
            if (members.isEmpty()) stop()
        }
    }

    /**
     * The app came back to the foreground, or the network changed.
     *
     * The tick is realigned rather than left where it was, so the first beat after a resume is a
     * full interval away instead of every machine being pinged at once on top of the reconnects
     * that are already in flight.
     */
    fun realign() {
        synchronized(lock) {
            if (loop?.isActive != true) return
            stop()
            start()
        }
    }

    /** Caller holds [lock]. */
    private fun start() {
        if (loop?.isActive == true || members.isEmpty()) return
        loop = scope.launch {
            while (isActive) {
                delay(intervalMs - graceMs)
                // Snapshotted, and the beats run outside the lock. A member that finds its socket
                // dead tears itself down from inside `ping`, which calls back into `leave` — under
                // the lock that would be a deadlock, and iterating the live map would be a
                // concurrent modification.
                for ((owner, member) in snapshot()) {
                    if (!member.ping()) leave(owner)
                }
                delay(graceMs)
                for ((_, member) in snapshot()) member.pongDue()
            }
        }
    }

    /** Caller holds [lock]. */
    private fun stop() {
        loop?.cancel()
        loop = null
    }

    private fun snapshot(): List<Pair<Any, Member>> =
        synchronized(lock) { members.entries.map { it.key to it.value } }

    companion object {

        /** Well under the 30 seconds after which idle NAT entries start being reclaimed. */
        const val INTERVAL_MS = 25_000L

        /** How long a machine has to answer before its socket is treated as gone. */
        const val GRACE_MS = 10_000L

        /**
         * The one every transport joins.
         *
         * A second instance would be a second timer, which is the thing this class exists to
         * prevent — so the app has exactly one and the tests build their own over a test scheduler.
         */
        val shared = Heartbeat()
    }
}
