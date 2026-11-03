import Foundation

/// A device that reconnects too often is slowed down BEFORE its credential's scrypt check runs (26 Oct 2026: a
/// phone that reconnected every second kept this Mac's app at 44% CPU). More than `limit` hellos from one key in
/// `window` seconds pause it for a while that doubles with each further try, up to `longestPause`. Only the cost of
/// trying is limited: the password check itself, its result and the failed-attempt lockout are unchanged.
public struct BackendRemoteReconnectThrottle: Sendable {
    public var limit = 10
    public var window: Double = 60
    public var firstPause: Double = 2
    public var longestPause: Double = 60
    private struct Entry: Sendable { var times: [Double] = []; var pausedUntil: Double = 0; var strikes = 0 }
    private var seen: [String: Entry] = [:]

    public init() {}

    /// The key a hello is counted under: the device a credential names (its id before the dot, read without any
    /// check), else the address a pairing code came from.
    public static func key(token: String, address: String) -> String {
        if let dot = token.firstIndex(of: "."), dot != token.startIndex { return "device:" + token[..<dot].prefix(64) }
        return "address:" + address.prefix(128)
    }

    /// Nil: go ahead. Otherwise the seconds this key must wait; a try during a pause makes the pause longer.
    public mutating func admit(_ key: String, now: Double) -> Double? {
        var entry = seen[key] ?? Entry()
        if now < entry.pausedUntil {
            entry.strikes += 1
            entry.pausedUntil = now + pause(entry.strikes)
            seen[key] = entry
            return entry.pausedUntil - now
        }
        entry.times = entry.times.filter { now - $0 < window }
        entry.times.append(now)
        if entry.times.count > limit {
            entry.strikes += 1
            entry.pausedUntil = now + pause(entry.strikes)
            seen[key] = entry
            prune(now)
            return entry.pausedUntil - now
        }
        if entry.times.count <= limit / 2 { entry.strikes = 0 }
        seen[key] = entry
        prune(now)
        return nil
    }

    /// What the phone is told: plain words and the wait, never a silent drop.
    public static func slowDown(_ wait: Double) -> String {
        "Slow down: this device is reconnecting too often. Try again in \(max(1, Int(wait.rounded(.up)))) seconds."
    }

    private func pause(_ strikes: Int) -> Double { min(longestPause, firstPause * pow(2, Double(max(0, strikes - 1)))) }

    /// Bounded: keys with nothing recent and no pause go once the table is large.
    private mutating func prune(_ now: Double) {
        guard seen.count > 1024 else { return }
        seen = seen.filter { _, entry in entry.pausedUntil > now || entry.times.contains { now - $0 < window } }
    }
}
