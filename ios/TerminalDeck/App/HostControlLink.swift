/**
 * The phone's half of the `host.control` capability: read the machine's own host
 * over the relay, restart it, stop it.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box two ways: an SSH address it was added with, and
 * the relay it is paired over. Asad's SSH address is a Tailscale name
 * (`imza-pc-wsl`) that drops on its own — and when it does, the page reports the
 * box as unreachable while every session on it still runs over the public relay.
 * This link is how the page reaches the box the other way: when the server is a
 * connected machine, its status and its restart/stop go over the relay, and SSH
 * is the fallback for the case the relay cannot cover.
 *
 * The host owns its own lifecycle. This object holds no more than the last
 * `HostControlWire` the host sent and a little state about which verb is in
 * flight. It is the direct sibling of `GitHubLink`: the same rid-based
 * request/answer plumbing, the same `welcomed(capabilities:)` reset on every
 * connection, the same "nothing at all over a machine whose welcome did not name
 * the capability".
 *
 * The screen is `HostRelayControlView`, mounted on the server page; it reaches
 * this through `HostLink.hostControl`.
 *
 * ## What restart and stop do to `working`, and why there is no push
 *
 * A restart or a stop drops the very connection the answer travels on. So the
 * host answers `host.state` with a `note` **first** and acts after — this link
 * shows that note, and then the connection goes and comes back (for a restart)
 * as a fresh welcome, which resets everything. There is no unsolicited "host
 * changed" push: a restarted host simply reconnects, and the reconnection is the
 * signal, not a frame.
 */

import Foundation

@MainActor
@Observable
final class HostControlLink {
    /// The last host state, or nil until the first `host.state` lands. The screen
    /// draws a quiet loading state off nil, never a guess.
    private(set) var state: HostControlWire?

    /// A restart or stop is in flight, awaiting its `host.state`. The buttons
    /// lock on it and the screen shows a spinner.
    private(set) var working = false

    /// The host did not answer a verb in time. A sentence the screen can show
    /// beside a still-usable control, cleared the next time a verb is sent.
    private(set) var timedOut = false

    /// The last restart/stop note the host sent, shown until the next verb. A
    /// restart that reconnects clears it through `welcomed`.
    private(set) var note: String?

    static let readTimeout: TimeInterval = 20
    /// Longer than a read: a restart shells out to systemd on the far end before
    /// it can even answer, and the answer races the drop it is about to cause.
    static let verbTimeout: TimeInterval = 30

    private enum Ask: Equatable { case read; case restart; case stop }

    private var capabilities: Set<String> = []
    /// Sent a read on this connection already — reset by `welcomed` on each
    /// welcome, so the next visit re-reads.
    private var requested = false
    private let wire: CopilotWire
    private var pending: [String: Ask] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0

    init(wire: CopilotWire) {
        self.wire = wire
    }

    /// Whether this machine speaks `host.control` at all. A machine whose welcome
    /// did not name it gets a screen exactly as it was — no relay controls that
    /// reach nothing, and the server page falls back to SSH.
    var offered: Bool { capabilities.contains(WireCapability.hostControl) }

    /// A new welcome: forget what the last machine said and re-read on the next
    /// visit. Called for every welcome — the machine on the other end can change,
    /// and a machine that just restarted comes back as a fresh welcome.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        pending.removeAll()
        state = nil
        note = nil
        requested = false
        working = false
        timedOut = false
    }

    /// Ask for the host's status once, when the screen opens. A no-op over a
    /// machine that does not serve it, and after the first ask on a connection —
    /// there is no push, but nothing here polls either: the status is read once
    /// and re-read on the next welcome or the next verb.
    func ensureRead() {
        guard offered, !requested, state == nil else { return }
        send(.read)
    }

    /// Read the host's status again on demand — the pull-to-refresh path, so a
    /// person who wants a fresh reading is not told to wait for a push that never
    /// comes. Silent over a machine that does not serve it.
    func refresh() {
        guard offered, !working else { return }
        send(.read)
    }

    /// Restart the host on this machine, over the relay.
    func restart() {
        guard offered, !working else { return }
        send(.restart)
    }

    /// Stop the host on this machine, over the relay.
    func stop() {
        guard offered, !working else { return }
        send(.stop)
    }

    private func send(_ ask: Ask) {
        let rid = nextRid()
        let message: ClientMessage
        switch ask {
        case .read:    message = .hostStatus(rid: rid)
        case .restart: message = .hostRestart(rid: rid)
        case .stop:    message = .hostStop(rid: rid)
        }
        guard wire.send(message) else { return }
        timedOut = false
        if ask != .read { note = nil }
        pending[rid] = ask
        if ask == .read {
            requested = true
        } else {
            working = true
        }
        arm(rid, after: ask == .read ? Self.readTimeout : Self.verbTimeout) { [weak self] in
            guard let self, self.pending.removeValue(forKey: rid) != nil else { return }
            if ask == .read {
                // A read that never answered is not an error to show — the screen
                // stays as it was and the next visit tries again.
                self.requested = false
            } else {
                // A restart that never answered is the ordinary case, not a
                // failure: the host may have dropped the connection *as* it acted,
                // before the reply flushed. So `timedOut` says "no confirmation
                // came" rather than "it failed", and the reconnection is the real
                // outcome — see the header.
                self.working = false
                self.timedOut = true
            }
        }
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .hostState(rid, host):
            guard let ask = pending.removeValue(forKey: rid) else { return false }
            disarm(rid)
            state = host
            note = host.note
            working = false
            requested = true
            _ = ask
            return true
        default:
            return false
        }
    }

    private func nextRid() -> String {
        counter += 1
        return "hc-\(counter)-\(UUID().uuidString.prefix(6))"
    }

    private func arm(_ rid: String, after seconds: TimeInterval, _ fire: @escaping () -> Void) {
        timers[rid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
            self?.timers.removeValue(forKey: rid)
        }
    }

    private func disarm(_ rid: String) {
        timers.removeValue(forKey: rid)?.cancel()
    }
}
