/**
 * The device roster on the wire, and the sentences a row is drawn from.
 *
 * A port of `DeviceRosterRow` from `src/main/remote/protocol.ts` and of the
 * pure half of `pwa/src/devices.ts` — whether the host offers the roster, and
 * the three sentences a row shows. The client is `DeviceRosterLink`; the drawing
 * is `DeviceRosterView`.
 *
 * Withheld from a guest at the source: the host only ever advertises `devices`
 * to one of the owner's own devices, so a client that sees the capability is
 * both able to manage the roster and entitled to. There is no approve verb —
 * revoke doubles as deny for a pending device.
 */

import Foundation

/**
 * One row of the device roster.
 *
 * `kind` is `mine` or `guest`; `status` is `pending` or `approved` (a revoked
 * row is never listed). `addedAt`/`lastSeenAt` are epoch milliseconds off the
 * host's own `Device`; `lastSeenAt` is nil until the device has attached once.
 * `fingerprint` is the six-group key form, or nil for a device paired before the
 * host kept them.
 */
struct DeviceRosterRow: Equatable, Identifiable, Hashable {
    enum Kind: String, Equatable, Hashable { case mine, guest }
    enum Status: String, Equatable, Hashable { case pending, approved }

    let id: String
    let name: String
    let kind: Kind
    let status: Status
    let addedAt: Double
    let lastSeenAt: Double?
    let connected: Bool
    let fingerprint: String?
}

extension WireCodec {
    /**
     * One roster row, or nil. The id, name, kind and status are required —
     * a row without them is not a shorter row, it is a row about nothing — and a
     * kind or status this build does not recognise drops the row rather than
     * guessing (the same rule a dev-server status keeps). Everything else is
     * read leniently.
     */
    static func deviceRosterRow(_ value: Any?) -> DeviceRosterRow? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let name = displayLine(row["name"]),
              let kindRaw = string(row["kind"]), let kind = DeviceRosterRow.Kind(rawValue: kindRaw),
              let statusRaw = string(row["status"]), let status = DeviceRosterRow.Status(rawValue: statusRaw)
        else { return nil }
        return DeviceRosterRow(
            id: id,
            name: name,
            kind: kind,
            status: status,
            addedAt: epochMillis(row["addedAt"]) ?? 0,
            lastSeenAt: epochMillis(row["lastSeenAt"]),
            connected: row["connected"] as? Bool == true,
            // Checked against the shape a fingerprint has rather than trusted:
            // it is display text from another machine and its only use is to be
            // read and compared, so an escape sequence in it must not survive.
            fingerprint: displayLine(row["fingerprint"]))
    }

    /// A `devices` array off a roster frame. A malformed row is dropped rather
    /// than taking the list with it.
    static func deviceRoster(_ value: Any?) -> [DeviceRosterRow] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { deviceRosterRow($0) }
    }

    /// Epoch milliseconds, finite and positive, or nil. Bools bridge to
    /// `NSNumber` too, so `true` must not read as 1ms.
    static func epochMillis(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(value is NSNull),
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let at = number.doubleValue
        return at.isFinite && at > 0 ? at : nil
    }
}

// MARK: - The three sentences a row is drawn from (a port of `pwa/src/devices.ts`)

enum DeviceRosterText {
    /// What a row *is*, in one line. A pending row leads with the wait — there
    /// is no approve on the wire, so Remove (which doubles as deny) is the one
    /// act it has. An approved row names its kind.
    static func standing(_ row: DeviceRosterRow) -> String {
        if row.status == .pending { return "Waiting to be approved" }
        return row.kind == .mine ? "Your device" : "Guest"
    }

    /// When it was last here. Connected-now beats any time. A device that has
    /// never attached says so rather than printing a time it does not have.
    static func lastSeen(_ row: DeviceRosterRow, now: Date = Date()) -> String {
        if row.connected { return "Connected now" }
        guard let seen = row.lastSeenAt else { return "Never connected" }
        let ago = now.timeIntervalSince1970 * 1000 - seen
        if ago < 0 { return "Seen moments ago" }
        let minutes = Int(ago / 60_000)
        if minutes < 2 { return "Seen moments ago" }
        if minutes < 60 { return "Seen \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Seen \(hours)h ago" }
        let days = hours / 24
        return days == 1 ? "Seen yesterday" : "Seen \(days)d ago"
    }

    /// The fingerprint, or the sentence for a device that has none. Shown so a
    /// person can check it against the six groups the device itself displays.
    static func fingerprint(_ row: DeviceRosterRow) -> String {
        row.fingerprint ?? "No key — paired before this host kept them"
    }
}
