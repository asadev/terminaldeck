/**
 * The phone's half of the `github` capability: read the host's GitHub login,
 * start a sign-in on the host, cancel one, or sign the host out.
 *
 * The account lives on the machine now. This object holds no token and no
 * secret — it holds the last `GitHubHostWire` the host sent and a little state
 * about which verb is in flight, and everything a screen draws is a projection
 * of that. It is the direct sibling of `ServerSettingsLink`: the same rid-based
 * request/answer plumbing, the same `welcomed(capabilities:)` reset on every
 * connection, the same "nothing is drawn until a state lands, nothing at all
 * over a machine whose welcome did not name the capability".
 *
 * The screen is `ConnectGitHubView`, mounted by the server-page lane as
 * `ConnectGitHubView(host:)`; it reaches this through `HostLink.github`.
 *
 * ## The connect flow, and what `working` means
 *
 * `working` is true from the moment a verb is sent until its answering
 * `github.state` (carrying the same rid) lands. Tapping **Connect** sends
 * `github.connect`; the host answers a `github.state` whose `pending` holds the
 * code and URL, and `working` drops so the screen shows the code. When somebody
 * authorises on github.com the host pushes an unsolicited `github.changed` with
 * `connected: true` — no rid — and the screen becomes the connected state.
 * **Cancel** and **Disconnect** are the same shape: a verb, then the machine's
 * own re-read as the answer, so a refused or lapsed one settles by construction.
 */

import Foundation

@MainActor
@Observable
final class GitHubLink {
    /// The last state the host sent, or nil until the first `github.state` has
    /// landed. The screen draws a quiet loading state off nil, never a guess.
    private(set) var state: GitHubHostWire?

    /// A verb is in flight, awaiting its `github.state`. Both connect and
    /// disconnect lock their buttons on it, and the screen shows a spinner.
    private(set) var working = false

    /// The host did not answer a verb in time. A sentence the screen can show
    /// beside a still-usable control, cleared the next time a verb is sent.
    private(set) var timedOut = false

    static let readTimeout: TimeInterval = 20
    /// Longer than a read: starting a device flow is a round trip to GitHub from
    /// the host, and signing out can wait on the host revoking a token.
    static let verbTimeout: TimeInterval = 45

    private enum Ask: Equatable { case read; case connect; case cancel; case disconnect }

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

    /// Whether this machine speaks `github.*` at all. A machine whose welcome
    /// did not name it gets a screen exactly as it was — no controls that reach
    /// nothing.
    var offered: Bool { capabilities.contains(WireCapability.github) }

    /// A new welcome: forget what the last machine said and re-read on the next
    /// visit. Called for every welcome — the machine on the other end can change.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        pending.removeAll()
        state = nil
        requested = false
        working = false
        timedOut = false
    }

    /// Ask for the host's GitHub status once, when the screen opens. A no-op over
    /// a machine that does not serve it, and after the first ask on a connection
    /// — the `github.changed` push keeps it fresh without a poll.
    func ensureRead() {
        guard offered, !requested, state == nil else { return }
        send(.read)
    }

    /// Start a device-flow sign-in on the host.
    func connect() {
        guard offered, !working else { return }
        send(.connect)
    }

    /// Cancel a sign-in in flight on the host.
    func cancel() {
        guard offered, !working else { return }
        send(.cancel)
    }

    /// Sign the host out.
    func disconnect() {
        guard offered, !working else { return }
        send(.disconnect)
    }

    private func send(_ ask: Ask) {
        let rid = nextRid()
        let message: ClientMessage
        switch ask {
        case .read:       message = .githubRead(rid: rid)
        case .connect:    message = .githubConnect(rid: rid)
        case .cancel:     message = .githubCancel(rid: rid)
        case .disconnect: message = .githubDisconnect(rid: rid)
        }
        guard wire.send(message) else { return }
        timedOut = false
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
                self.working = false
                self.timedOut = true
            }
        }
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .githubState(rid, github):
            guard pending.removeValue(forKey: rid) != nil else { return false }
            disarm(rid)
            state = github
            working = false
            requested = true
            return true

        case let .githubChanged(github):
            // Unsolicited: another device changed it, or a sign-in this phone
            // started finished while nobody was looking. No rid to match, and it
            // clears any verb in flight — the flow reached its end by a push
            // rather than an answer.
            state = github
            working = false
            timedOut = false
            return true

        default:
            return false
        }
    }

    private func nextRid() -> String {
        counter += 1
        return "gh-\(counter)-\(UUID().uuidString.prefix(6))"
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
