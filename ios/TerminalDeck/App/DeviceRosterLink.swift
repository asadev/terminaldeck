/**
 * The device roster on a phone — every device signed in to a machine, and the
 * one verb that removes one.
 *
 * The client half of `devices`, reached over the capability the host advertises
 * only to one of the owner's own devices. A device that sees `devices` in the
 * welcome is both able to manage the roster and entitled to; there is no second
 * check. Revoke doubles as deny for a pending device — there is no approve on
 * the wire, because a device is admitted at the trusted surface and nowhere
 * else.
 *
 * The rows stay fresh without a poll: `devices.changed` is pushed whenever the
 * roster moves, which is why this client claims the capability in `hello`.
 * Self-revoke is sign-out — the cascade drops the asker's own socket, so the
 * socket closing after the frame is the confirmation, and no `devices.revoked`
 * comes back.
 */

import Foundation

@MainActor
@Observable
final class DeviceRosterLink {
    /// The roster, or nil until a `devices.rows` has landed.
    private(set) var rows: [DeviceRosterRow]?
    /// Which device is mid-revoke, or nil.
    private(set) var busy: String?
    /// The host's own sentence about the last revoke.
    private(set) var notice: Notice?

    struct Notice: Equatable { let ok: Bool; let text: String }

    static let listTimeout: TimeInterval = 20
    static let revokeTimeout: TimeInterval = 30
    private static let confirm: TimeInterval = 4

    private enum Ask: Equatable { case list; case revoke(String) }
    private struct Pending { let kind: Ask }

    private var capabilities: Set<String> = []
    private var requested = false
    private let wire: CopilotWire
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0
    private var confirmClear: Task<Void, Never>?

    init(wire: CopilotWire) {
        self.wire = wire
    }

    var offered: Bool { capabilities.contains(WireCapability.devices) }

    /// A new welcome: forget the last machine's roster and re-read on the next
    /// visit. The roster belongs to whichever machine this connection reaches,
    /// and a guest reconnecting is not told the capability exists at all.
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

    /// Ask for the roster once, when the screen opens. The `devices.changed`
    /// push keeps it fresh after that.
    func ensureRead() {
        guard offered, !requested, rows == nil else { return }
        ask()
    }

    private func ask() {
        guard offered else { return }
        let rid = nextRid()
        guard wire.send(.devicesList(rid: rid)) else { return }
        requested = true
        pending[rid] = Pending(kind: .list)
        arm(rid, after: Self.listTimeout) { [weak self] in
            self?.pending.removeValue(forKey: rid)
            self?.requested = false
        }
    }

    func revoke(_ device: String) {
        guard offered, busy == nil else { return }
        let rid = nextRid()
        guard wire.send(.devicesRevoke(rid: rid, device: device)) else { return }
        busy = device
        notice = nil
        pending[rid] = Pending(kind: .revoke(device))
        arm(rid, after: Self.revokeTimeout) { [weak self] in
            guard let self, self.pending.removeValue(forKey: rid) != nil else { return }
            if self.busy != device { return }
            self.busy = nil
            self.say(Notice(ok: false, text: "That machine did not answer, so the device was not removed."))
        }
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .devicesRows(rid, devices):
            guard let asked = pending.removeValue(forKey: rid), asked.kind == .list else { return false }
            disarm(rid)
            rows = devices
            return true

        case let .devicesRevoked(rid, ok, message, devices):
            guard let asked = pending.removeValue(forKey: rid), case .revoke = asked.kind else { return false }
            disarm(rid)
            busy = nil
            say(Notice(ok: ok, text: message))
            rows = devices
            return true

        case let .devicesChanged(devices):
            // Unsolicited: the roster moved. No rid to match.
            rows = devices
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

    func dismissNotice() { say(nil) }

    private func nextRid() -> String {
        counter += 1
        return "dev-\(counter)-\(UUID().uuidString.prefix(6))"
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
