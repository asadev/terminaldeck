/**
 * One timer, every socket.
 *
 * ## Why the ping cannot be dropped
 *
 * A long-lived TCP connection through a carrier NAT dies silently when the
 * mapping is reclaimed, which happens after 30–60 seconds of silence on most
 * mobile networks; TCP keepalive defaults to hours and does not save it. So a
 * phone holding a socket open to a machine has to say something regularly or it
 * will find out the socket is dead only when somebody types into it. That is the
 * `7.9` exception: this timer is load-bearing, and dropping it does not save
 * work, it loses sessions.
 *
 * ## Why there is exactly one of them
 *
 * `7.10`, and on a phone it is not a style point. Every host this phone is paired
 * with holds a socket, and every socket needs that ping — so N hosts on N
 * independent timers is N chances per cycle to wake the radio out of its idle
 * state. The cellular radio is the expensive thing here, not the CPU: a wake-up
 * costs the same whether one byte or five hundred follow it, and it keeps the
 * radio in a high-power state for seconds afterwards. Three unsynchronised
 * 25-second timers therefore cost roughly three times what three synchronised
 * ones do, for identical traffic.
 *
 * Folding them into one tick makes the whole set cost one wake-up: the pings for
 * every host go out in the same turn of the run loop, into the same radio window,
 * and the answers come back into it too.
 *
 * ## Measured
 *
 * By `scripts/keepalive-cost.ts`, which runs the shipping Noise channel, relay
 * envelope and frame writers rather than adding up remembered constants — an
 * earlier version of this comment did the latter and got two of the four numbers
 * wrong. One tick every 25 s, so 144 ticks an hour whatever the number of hosts.
 * A `ping` and a `pong` are both 12 bytes of JSON, which the sealed channel's
 * tag, the version byte, the 17-byte envelope header and the WebSocket frame
 * carry to **52 bytes out** (a client masks, which costs four) and **48 bytes
 * in** — 100 bytes per host per tick. Three paired machines is therefore
 * **43.2 kB an hour** of keepalive across all of them, in **144 radio windows
 * rather than 432**. The full reading is in `docs/multi-host-battery.md`.
 */

import Foundation

@MainActor
final class Heartbeat {

    /**
     * The app's single ping cadence.
     *
     * Well under the 30 seconds after which idle NAT and proxy entries start
     * being reclaimed, so no socket is ever idle long enough to be collected.
     */
    static let interval: TimeInterval = 25

    /// The one every transport joins. A second instance would be a second timer,
    /// which is the thing this type exists to prevent.
    static let shared = Heartbeat()

    private var members: [ObjectIdentifier: () -> Void] = [:]
    private var ticking = false
    /// Bumped when the set empties, so a loop from a previous run stops rather
    /// than racing a new one into existence.
    private var generation = 0

    /// Only the tests read these, to prove there is one loop and that it stops.
    var memberCount: Int { members.count }
    var isTicking: Bool { ticking }

    init() {}

    /**
     * Beat with everyone else.
     *
     * The owner is held by identity and the closure weakly by the caller's own
     * capture list — nothing here retains a transport, because a transport that
     * is deallocated without leaving would otherwise be kept alive by the timer
     * that exists to check on it.
     */
    func join(_ owner: AnyObject, beat: @escaping () -> Void) {
        members[ObjectIdentifier(owner)] = beat
        start()
    }

    func leave(_ owner: AnyObject) {
        members.removeValue(forKey: ObjectIdentifier(owner))
        // Stopped rather than left spinning over an empty set. A timer with no
        // consumer is pure cost, and on a phone it is cost that shows up as
        // battery in somebody's settings screen with this app's name on it.
        if members.isEmpty { stop() }
    }

    /**
     * The app came to the foreground, or the network changed.
     *
     * **Beats now, then realigns.** The earlier version of this deliberately did
     * not — the reasoning was that firing every host at once on resume was a
     * thundering herd worth avoiding, so the first beat was left a full interval
     * away. That reasoning was exactly backwards, and it cost the app the one
     * property it must never lose.
     *
     * Coming back from suspension is the moment a socket is *most* likely to be
     * dead: the app has not run for minutes or hours, and nothing tells it that a
     * carrier NAT reclaimed the mapping while it was away. Pushing the first
     * check a full interval out meant the badge could read Connected for 25
     * seconds plus the 10-second grace against nothing at all — and it was
     * observed doing so.
     *
     * The herd was never the problem either: firing every host in the same turn
     * of the run loop is *the entire point* of a shared tick. One radio window,
     * N pings.
     */
    func realign() {
        guard ticking else { return }
        stop()
        for beat in Array(members.values) { beat() }
        start()
    }

    private func start() {
        guard !ticking, !members.isEmpty else { return }
        ticking = true
        generation &+= 1
        let epoch = generation
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Heartbeat.interval))
                guard let self, self.ticking, self.generation == epoch else { return }
                // Copied before iterating: a beat may leave the set — a transport
                // that finds its socket dead tears itself down from inside this
                // loop — and mutating a dictionary while walking it is a crash,
                // not a warning.
                for beat in Array(self.members.values) { beat() }
            }
        }
    }

    private func stop() {
        ticking = false
        generation &+= 1
    }
}
