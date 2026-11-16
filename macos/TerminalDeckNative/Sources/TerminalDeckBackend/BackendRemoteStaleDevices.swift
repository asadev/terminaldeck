import Foundation
import TerminalDeckNativeCore

/// Owner's rule (14 Nov): a device paired the old way (the pairing roster, `remote-auth.json`: a code, this Mac's own
/// browser button or its login; never an account device, which lives only in `reachAdmitted`) that has not connected
/// for 30 days is removed from this Mac by itself: the same removal as the Devices page's "Remove this device"
/// (revoke: it can no longer open this Mac and its row goes), with one plain line in the app's log.
///
/// The 30 days are RUNNING days (reviews 14 Nov 15:01 and after dd65a7b88): time counts only between two checks of a
/// running app with a sane clock, so days the Mac or the app was off are skipped and running days add up.
/// - The mark beside the roster (`remote-device-cleanup.json`) keeps `running` (the running time counted so far),
///   `lastCheckAt`, and for each device the running time when it was last seen (`seen`).
/// - Between two checks: a step of up to a day (`longestStep`) counts in full; a longer gap (Mac or app off, a weekend,
///   a clock jumped ahead) or a clock gone backwards counts NOTHING and removes nothing in that check. So one gap adds
///   at most 24 hours, and a wrong clock can never age anything at once.
/// - A device is seen at a check when it is connected then, or connected since the last check (`lastSeenAt` later
///   than it): its `seen` becomes the running time now. A device never seen since this build counts from its first
///   check. Due: 30 running days since it was seen.
/// - The first check runs half an hour after launch (`firstCheck`), then every six hours.
/// - Connected devices are marked as seen in the roster first (saved), the connection list is read again just before
///   each removal, and the roster's own removal refuses a device seen after the last check
///   (`BackendRemoteTrustStore.revoke(quietBefore:)`, the same actor that records each verified connection).
public enum BackendRemoteStaleDevices {
    public static let days = 30
    static let window = Double(days) * 24 * 3600 * 1000
    /// The most one step between two checks may count; a longer one counts nothing.
    static let longestStep = 24.0 * 3600 * 1000
    /// The first check after launch, then each next one.
    public static let firstCheck: Duration = .seconds(30 * 60)
    public static let interval: Duration = .seconds(6 * 3600)
    static let markFile = "remote-device-cleanup.json"

    /// The mark: running time counted, the last check's time, each device's running time when last seen.
    struct Mark: Equatable { var running: Double; var lastCheckAt: Double; var seen: [String: Double] }

    /// The devices due for removal: not connected, 30 running days or more since they were last seen.
    public static func due(_ devices: [BackendRemoteDevice], connected: Set<String>, running: Double, seen: [String: Double]) -> [BackendRemoteDevice] {
        devices.filter { device in
            !device.revoked && !connected.contains(device.id) && running - (seen[device.id] ?? 0) >= window
        }
    }

    static func read(_ file: URL) -> Mark? {
        guard let saved = try? BackendRemoteTrustStorage.read(file, maximumBytes: 262_144), saved["version"].number == 3,
              let running = saved["running"].number, let last = saved["lastCheckAt"].number, running.isFinite, running >= 0, last.isFinite
        else { return nil }
        var seen: [String: Double] = [:]
        for field in saved["seen"].fields ?? [] { if let at = field.value.number, at.isFinite { seen[field.key] = at } }
        return Mark(running: running, lastCheckAt: last, seen: seen)
    }

    static func write(_ mark: Mark, _ file: URL) throws {
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(3)), .init("running", .number(mark.running)),
            .init("lastCheckAt", .number(mark.lastCheckAt)),
            .init("seen", .object(mark.seen.sorted { $0.key < $1.key }.map { .init($0.key, .number($0.value)) }))]), file: file)
    }

    /// One step of the count. `mayRemove` only after a sane step from an earlier check.
    static func step(_ previous: Mark?, devices: [BackendRemoteDevice], online: Set<String>, now: Double) -> (mark: Mark, mayRemove: Bool) {
        let gap = previous.map { now - $0.lastCheckAt }
        let sane = gap.map { $0 >= 0 && $0 <= longestStep } ?? false
        let running = (previous?.running ?? 0) + (sane ? gap! : 0)
        var seen: [String: Double] = [:]
        for device in devices where !device.revoked {
            let since = previous.map { last in device.lastSeenAt.map { $0 > last.lastCheckAt || $0 > now } ?? false } ?? false
            seen[device.id] = online.contains(device.id) || since ? running : previous?.seen[device.id] ?? previous?.running ?? running
        }
        return (Mark(running: running, lastCheckAt: now, seen: seen), sane)
    }

    public static func line(_ name: String) -> String {
        "[devices] Removed \(name) from this Mac: it was paired the old way, before accounts, and has not connected for \(days) days."
    }

    /// One check: marks the connected devices as seen, counts the step, then removes what is due through `revoke` (the
    /// Devices page's own removal, refused by the roster for a device seen after the last check) and logs one line
    /// for each. Returns the ids removed.
    @discardableResult
    public static func sweep(directory: URL, now: Double = Date().timeIntervalSince1970 * 1000,
                             devices: @Sendable () async -> [BackendRemoteDevice],
                             connected: @Sendable () async -> Set<String>,
                             noteSeen: @Sendable (Set<String>, Double) async throws -> Void,
                             revoke: @Sendable (_ id: String, _ quietBefore: Double) async throws -> Bool,
                             report: @Sendable (String) -> Void) async -> [String] {
        let online = await connected()
        // Seen now, saved, before anything else: a failure to save removes nothing this time.
        do { try await noteSeen(online, now) } catch { return [] }
        let file = directory.appendingPathComponent(markFile)
        let previous = read(file)
        let roster = await devices()
        let counted = step(previous, devices: roster, online: online, now: now)
        do { try write(counted.mark, file) } catch { return [] }
        guard counted.mayRemove, let last = previous?.lastCheckAt else { return [] }
        var removed: [String] = []
        for device in due(roster, connected: online, running: counted.mark.running, seen: counted.mark.seen) {
            // Connected since the snapshot: kept (the roster's own removal checks once more, in one step).
            guard !(await connected()).contains(device.id) else { continue }
            do {
                if try await revoke(device.id, last) { removed.append(device.id); report(line(device.name)) }
            } catch { report("[devices] Could not remove \(device.name) after \(days) days unused: \(error.localizedDescription)") }
        }
        return removed
    }
}
