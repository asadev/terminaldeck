/**
 * The "This server" section of Settings — the two settings this machine owns
 * rather than this phone.
 *
 * A port of `pwa/src/server-settings.ts`. The coding tool a fresh session starts
 * with, and whether the last layout is restored at launch, are facts about the
 * machine at the other end — the same on every device that reaches it — so
 * changing one here changes the server. Everything else in Settings is this
 * app's own.
 *
 * Nothing is drawn until a `settings.state` answers, and nothing at all over a
 * machine whose welcome did not name `settings` — an older desktop or a guest
 * gets a Settings screen exactly as it was. While an apply is in flight both
 * controls lock; the value shown is always the machine's own re-read, never the
 * pressed value, so a refused apply reverts by construction.
 */

import Foundation

@MainActor
@Observable
final class ServerSettingsLink {
    /// The rows, in `serverSettingsOrder`, or nil until a state has landed.
    private(set) var rows: [ServerSettingWire]?
    /// Which key is mid-change, or nil. Two writes never race into one store.
    private(set) var busy: ServerSettingKey?
    /// The server's own sentence about the last change.
    private(set) var notice: Notice?

    struct Notice: Equatable { let ok: Bool; let text: String }

    static let readTimeout: TimeInterval = 20
    static let applyTimeout: TimeInterval = 60
    private static let confirm: TimeInterval = 4

    private enum Ask: Equatable { case read; case apply(ServerSettingKey) }
    private struct Pending { let kind: Ask }

    private var capabilities: Set<String> = []
    /// Sent a read on this connection already — reset by `renew` on each welcome.
    private var requested = false
    private let wire: CopilotWire
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0
    private var confirmClear: Task<Void, Never>?

    init(wire: CopilotWire) {
        self.wire = wire
    }

    var offered: Bool { capabilities.contains(WireCapability.settings) }

    /// A new welcome: forget what the last machine said and re-read on the next
    /// visit. Called for every welcome — the machine on the other end can change.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        confirmClear?.cancel(); confirmClear = nil
        pending.removeAll()
        rows = nil
        requested = false
        busy = nil
        notice = nil
    }

    /// Ask for the settings once, when the screen that shows them opens. A no-op
    /// over a machine that does not serve them, and after the first ask on a
    /// connection — the `settings.changed` push keeps them fresh without a poll.
    func ensureRead() {
        guard offered, !requested, rows == nil else { return }
        ask()
    }

    private func ask() {
        guard offered else { return }
        let rid = nextRid()
        guard wire.send(.settingsRead(rid: rid)) else { return }
        requested = true
        pending[rid] = Pending(kind: .read)
        arm(rid, after: Self.readTimeout) { [weak self] in
            self?.pending.removeValue(forKey: rid)
            // A read that never answered is not an error to show — the screen
            // stays as it was and the next visit tries again.
            self?.requested = false
        }
    }

    func apply(_ key: ServerSettingKey, _ value: String) {
        guard busy == nil else { return }
        let rid = nextRid()
        guard wire.send(.settingsApply(rid: rid, key: key, value: value)) else { return }
        busy = key
        notice = nil
        pending[rid] = Pending(kind: .apply(key))
        arm(rid, after: Self.applyTimeout) { [weak self] in
            guard let self, self.pending.removeValue(forKey: rid) != nil else { return }
            if self.busy != key { return }
            self.busy = nil
            self.say(Notice(ok: false, text: "The server did not answer; nothing was changed."))
            self.requested = false
            self.ask()
        }
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .settingsState(rid, settings):
            guard let asked = pending.removeValue(forKey: rid), asked.kind == .read else { return false }
            disarm(rid)
            rows = ServerSettingsLink.merge(current: nil, next: settings)
            return true

        case let .settingsApplied(rid, ok, message, setting):
            guard let asked = pending.removeValue(forKey: rid), case .apply = asked.kind else { return false }
            disarm(rid)
            busy = nil
            // The server's own sentence, verbatim.
            say(Notice(ok: ok, text: message))
            // Settle on the machine's re-read whether the apply took or was
            // refused, so a refusal reverts by construction.
            rows = ServerSettingsLink.merge(current: rows, next: [setting])
            return true

        case let .settingsChanged(settings):
            // Unsolicited: another device changed one. No rid to match.
            rows = ServerSettingsLink.merge(current: rows, next: settings)
            return true

        default:
            return false
        }
    }

    private func say(_ notice: Notice?) {
        confirmClear?.cancel(); confirmClear = nil
        self.notice = notice
        if let notice, notice.ok {
            confirmClear = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.confirm * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.notice = nil
            }
        }
    }

    private func nextRid() -> String {
        counter += 1
        return "set-\(counter)-\(UUID().uuidString.prefix(6))"
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

    /**
     * Merge machine-sent rows into the held set, replacing by key and keeping
     * `serverSettingsOrder` so the section never reshuffles on a push. A pure
     * function so the merge can be tested where the view cannot. A port of
     * `mergeRows`.
     */
    static func merge(current: [ServerSettingWire]?, next: [ServerSettingWire]) -> [ServerSettingWire] {
        var byKey: [ServerSettingKey: ServerSettingWire] = [:]
        for row in current ?? [] { byKey[row.key] = row }
        for row in next { byKey[row.key] = row }
        return serverSettingsOrder.compactMap { byKey[$0] }
    }
}

// MARK: - Provider labels (a port of `PROVIDER_LABELS`/`providerLabel`)

enum ServerSettingsText {
    private static let providerLabels: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex CLI",
        "gemini": "Gemini CLI",
        "shell": "Plain shell",
    ]

    /// A builtin provider's own words, or its id — better a readable id than a
    /// guessed label for a `custom:` agent this build has not heard of.
    static func providerLabel(_ id: String) -> String {
        knownProviderLabel(id) ?? id
    }

    /**
     * The same table, answering nil where {@link providerLabel} answers the id.
     *
     * Two callers want opposite things from an agent this build has never heard
     * of, and both are right. A settings row is *about* that agent, so printing
     * its id is the most honest thing available — the row would otherwise be
     * about nothing. An account label is a sentence with the agent's name
     * inside it, and *"Your own custom:my-agent install"* is worse than "Your
     * own install": it reads as a slug leaking onto a screen, which is the
     * whole complaint {@link accountLoginLabel} exists to answer.
     *
     * So the difference is in the fallback and nowhere else. The table stays
     * single — a second copy in the naming file is how the phone comes to call
     * an agent one thing on the bar and another in Settings.
     */
    static func knownProviderLabel(_ id: String) -> String? {
        providerLabels[id]
    }
}
