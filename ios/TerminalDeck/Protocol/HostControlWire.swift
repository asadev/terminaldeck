/**
 * The machine's own host, as this phone reads it **over the relay** — the answer
 * to a `host.status`, and the answer a `host.restart` / `host.stop` echoes back.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box by two roads: an SSH address it was added with,
 * and the relay it is paired over. Asad's SSH address is a Tailscale name
 * (`imza-pc-wsl`) that goes offline on its own — and when it does, the page
 * reports the box as unreachable while every session on it is still running over
 * the public relay. This shape is what the page draws *instead* of that failure:
 * a host the relay reached, so it is plainly running, whatever the SSH name is
 * doing.
 *
 * It carries only what the host knows about *itself* — that it is running (it
 * answered, so `running` is always true), its build, how it is supervised, and
 * how long it has been up. It is deliberately **not** the machine survey (disk,
 * CPU, services, the package manager); that reads the whole box and stays on the
 * SSH probe (`ProbeScripts`/`ServerFacts`). The relay answers *is the host alive
 * and can I manage it*; the fuller portrait of the server underneath it is a
 * different question with a different door.
 *
 * A port of `HostControlWire` in `src/main/remote/protocol.ts`, read-only here:
 * the three verbs this phone sends (`host.status/restart/stop`) carry nothing but
 * a `rid`, and everything a screen draws comes back inside this. The client is
 * `HostControlLink`; the screen is `HostRelayControlView`.
 */

import Foundation

/// How the host is supervised — what a restart will actually do. Decoded
/// leniently: an unrecognised word is `unknown`, which a screen shows as a plain
/// restart rather than a claim it cannot back.
enum HostManagedBy: String, Equatable {
    case systemd
    case direct
    case unknown

    init(_ raw: String?) {
        switch raw {
        case "systemd": self = .systemd
        case "direct": self = .direct
        default: self = .unknown
        }
    }
}

/// Bounds on the strings this frame carries, so a garbled or hostile frame is
/// clipped rather than drawn at full length. Generous — these are a version
/// string, a relay address and one sentence the host writes.
enum HostControlWireLimits {
    static let version = 64
    static let address = 2048
    static let note = 512
}

struct HostControlWire: Equatable {
    /// Always true on this wire: the host answered, so it is running.
    let running: Bool
    /// The build the host is on, e.g. `0.14.0`.
    let version: String
    /// The relay server address the host prints, or empty. A phone reading this
    /// is already connected and does not need it to dial.
    let address: String
    /// The host process id.
    let pid: Int
    /// When the host process started.
    let startedAt: Date
    /// How long the host has been up, in seconds.
    let uptimeSeconds: Int
    /// How the host is supervised.
    let managed: HostManagedBy
    /// A sentence about what a restart/stop just set in motion, or nil for a
    /// plain status. The connection drops as the host acts, so this is the last
    /// thing the phone hears — the confirmation, sent before the socket goes.
    let note: String?

    /// A not-running placeholder, used when a frame could not be read at all, so
    /// a screen has something honest to draw rather than a crash.
    static let empty = HostControlWire(running: false, version: "", address: "", pid: 0,
                                       startedAt: Date(timeIntervalSince1970: 0), uptimeSeconds: 0,
                                       managed: .unknown, note: nil)
}

extension WireCodec {
    /**
     * One `HostControlWire` off an inbound frame's `host` field.
     *
     * Lenient on every field for the reason the rest of this codec is: one bad
     * value is clipped or dropped rather than discarding the frame. `nil` is
     * returned only when the value is not an object at all — a `host.state`
     * without a `host` object is malformed, and the decode arm refuses it rather
     * than inventing a state.
     */
    static func hostControl(_ value: Any?) -> HostControlWire? {
        guard let object = value as? [String: Any] else { return nil }

        func bounded(_ any: Any?, _ limit: Int) -> String {
            guard let text = string(any) else { return "" }
            return String(text.prefix(limit))
        }

        func integer(_ any: Any?) -> Int {
            guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
            return number.intValue
        }

        // Epoch **milliseconds**, the same units `GitHubPending.expiresAt` uses.
        // A missing or absurd value lands as the epoch rather than a crash.
        var startedAt = Date(timeIntervalSince1970: 0)
        if let number = object["startedAt"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let millis = number.doubleValue
            if millis.isFinite, millis > 0 { startedAt = Date(timeIntervalSince1970: millis / 1000) }
        }

        let note = string(object["note"]).map { String($0.prefix(HostControlWireLimits.note)) }

        return HostControlWire(
            running: object["running"] as? Bool ?? true,
            version: bounded(object["version"], HostControlWireLimits.version),
            address: bounded(object["address"], HostControlWireLimits.address),
            pid: integer(object["pid"]),
            startedAt: startedAt,
            uptimeSeconds: max(0, integer(object["uptimeSeconds"])),
            managed: HostManagedBy(string(object["managed"])),
            note: note?.isEmpty == true ? nil : note)
    }
}
