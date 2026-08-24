/**
 * The two settings this machine owns rather than each device — named on the
 * wire, and narrowed on arrival.
 *
 * A port of `SERVER_SETTINGS`, `ServerSettingWire` and `serverSettingWire` from
 * `src/main/remote/protocol.ts`. The coding tool a fresh session starts with,
 * and whether the last layout is restored at launch, are facts about the
 * *machine* — identical on every device that reaches it — so a phone changing
 * one is changing the server. Everything else in Settings is this app's own.
 *
 * The client is `ServerSettingsLink`, a port of `pwa/src/server-settings.ts`.
 */

import Foundation

/// The settings this machine owns, a closed allowlist. A key not in here is
/// unrepresentable on the wire — refused at the parser, not carried inward —
/// which is the whole reason `remote.*` and `advanced.*` cannot travel this way.
enum ServerSettingKey: String, Equatable, CaseIterable {
    case defaultProvider = "agents.defaultProvider"
    case restoreSessions = "general.restoreSessions"
}

/// The order the "This server" section keeps, so a push never reshuffles it.
let serverSettingsOrder: [ServerSettingKey] = [.defaultProvider, .restoreSessions]

/// The longest a server setting's value may be. A provider id is the long one.
let maxServerSettingValueLength = 64
/// The most options a chooser may carry, so a garbled frame is not a list bomb.
let maxServerSettingOptions = 64

/**
 * One server-owned setting, on the wire.
 *
 * `value` is stringly, like `controls.apply` — `"true"`/`"false"` for the
 * boolean, a provider id for the chooser. `options` is present only for a
 * chooser and holds the provider ids this host can actually start, so the
 * default-tool picker offers what will run rather than a fixed list.
 */
struct ServerSettingWire: Equatable, Identifiable {
    let key: ServerSettingKey
    let value: String
    let options: [String]?

    var id: ServerSettingKey { key }

    /**
     * A switch's value as three answers, not two.
     *
     * `on`, `off`, and **the machine has not said** — and the third one is the
     * one this defect was made of. Asad photographed *"Restore sessions at
     * launch"* ticked in one frame and unticked moments later with nothing
     * touched in between; nothing had toggled, because nothing on this phone or
     * that machine changes a server setting without an `apply` and an answer.
     * What changed was the drawing: the row read `value == "true"`, and every
     * other string on earth — including the empty one `WireCodec.serverSetting`
     * produces for a value it could not read — collapsed into a confident,
     * unticked **Off**.
     *
     * A control that cannot tell *off* from *I was not told* will eventually
     * show somebody the wrong one, and this row's wrong one says their sessions
     * are not being restored. So the unknown is a case, it is drawn as itself,
     * and it cannot be pressed — see `ServerSettingsSection.toggleRow`.
     */
    var flag: Bool? {
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

extension WireCodec {
    /**
     * One `ServerSettingWire` off an inbound frame, or nil.
     *
     * A row whose key is not in the allowlist is dropped rather than carried
     * inward — the same closed set the parser admits on the way in, asserted
     * again here. The value is bounded and the options list clipped, for the
     * reason every reader here bounds what it reads.
     */
    static func serverSetting(_ value: Any?) -> ServerSettingWire? {
        guard let row = value as? [String: Any],
              let raw = string(row["key"]),
              let key = ServerSettingKey(rawValue: raw) else { return nil }
        let val = string(row["value"]).map { String($0.prefix(maxServerSettingValueLength)) } ?? ""
        var options: [String]?
        if let list = row["options"] as? [Any] {
            options = list.compactMap { string($0) }
                .prefix(maxServerSettingOptions)
                .map { String($0.prefix(maxServerSettingValueLength)) }
        }
        return ServerSettingWire(key: key, value: val, options: options)
    }

    /// A `settings` array off a `settings.state` / `settings.changed`, keeping
    /// only the rows whose key is in the allowlist. A malformed row is dropped,
    /// not fatal — one bad row does not discard the set.
    static func serverSettings(_ value: Any?) -> [ServerSettingWire] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { serverSetting($0) }
    }
}
