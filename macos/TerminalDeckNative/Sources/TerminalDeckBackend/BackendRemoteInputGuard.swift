import Foundation
import MachO
import notify
import TerminalDeckNativeCore

/// R3 (device trust design 5.9, review round 2): the app's own "Mac reach" feature lets a phone control this Mac's
/// screen with clicks and keys the app cannot tell from the person's. So that path records the time of every event
/// it posts, and every trust or approval button refuses a press made within two seconds of one. A press made from
/// the phone is itself such an event, so it is always refused, whatever the order.
///
/// TWO records, and the guard reads both (security review, items 4 and S7):
/// - The IN-PROCESS mark. When the Mac is unlocked the app itself posts the phone's clicks, and this mark is what
///   covers them. Nothing outside this process can read, set or clear it, and the remote path can only move it
///   forward. Never remove it as "unused".
/// - The SYSTEM-WIDE record (one notify state, 64 bits: the uptime clock, in nanoseconds, of the last posted event).
///   It covers the Mac reach helper process and other copies of the app. Any program on this Mac can set or clear
///   it, so it can only ever ADD a refusal: the guard takes the later of the two, and a cleared record leaves the
///   in-process mark standing.
/// Both hold a time only: nothing about what was typed or clicked.
///
/// WHAT A POSTED EVENT COSTS, signed in to Cloud or not (this path runs for every phone click and key, up to 120 a
/// second, and has nothing to do with whether a Cloud account exists): one lock and one comparison for the
/// in-process mark, and AT MOST TEN TIMES A SECOND one message to the system's notify service for the system-wide
/// record (security review S8). No file, no Keychain item, no network, no allocation, nothing of Cloud is built.
public enum BackendRemoteInputMark {
    static let realName = "dev.terminaldeck.reach.input-posted"
    /// Security review S15: a test run never writes the record an installed copy of the app reads (it would close an
    /// open trust sheet there and refuse a press for two seconds). A process that has a test bundle loaded uses a
    /// record of its own.
    static let name: String = recordName(testProcess: inTestProcess(), pid: getpid())
    static func recordName(testProcess: Bool, pid: Int32) -> String {
        testProcess ? realName + ".test." + String(pid) : realName
    }
    /// Decided only from what is loaded into this process, never from the environment.
    static func inTestProcess() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        for index in 0..<_dyld_image_count() {
            if let image = _dyld_get_image_name(index), String(cString: image).contains(".xctest/") { return true }
        }
        return false
    }
    /// The system-wide record is written at most this often. A reader allows for it (see `lastPost`).
    public static let sharedWriteInterval: UInt64 = 100_000_000
    /// The uptime clock: one clock for every process on this Mac, never moved by the date and time settings.
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    private static let token: Int32? = {
        var made: Int32 = 0
        return notify_register_check(name, &made) == 0 ? made : nil
    }()
    private static let local = BackendRemoteInputLocalMark()
    /// Called by the remote-input path for every event it posts (`BackendMacReachInput`). The in-process mark moves
    /// every time; the system-wide record at most ten times a second.
    public static func posted() {
        let at = now()
        guard local.set(at, sharedEvery: sharedWriteInterval), let token else { return }
        _ = notify_set_state(token, at)
    }
    /// Keeps the system-wide record alive for this process: the system drops a record once no process holds its
    /// name, so one written by the Mac reach helper just before it exited would be lost. Called when a Cloud
    /// account attaches (only then can a trust or approval sheet exist); it writes nothing.
    public static func keepRecord() { _ = token }
    /// The last posted event's time, by this process or any other; nil when nothing was ever posted. Throws when the
    /// record cannot be read: a guard that cannot tell refuses.
    public static func lastPost() throws -> UInt64? {
        guard let token else { throw CloudFailure.unavailable }
        var shared: UInt64 = 0
        guard notify_get_state(token, &shared) == 0 else { throw CloudFailure.unavailable }
        return latest(shared: allowingForWriteInterval(shared), inProcess: local.get())
    }
    /// Another process may have posted up to `sharedWriteInterval` after the time its record shows, so the record is
    /// read as that much later: a refusal can only last longer, never end early. Zero (never set, or cleared) stays zero.
    static func allowingForWriteInterval(_ shared: UInt64) -> UInt64 {
        shared == 0 ? 0 : shared &+ sharedWriteInterval
    }
    /// The later of the two records; nil when neither was ever set. A cleared (zero) system-wide record never
    /// hides the in-process mark.
    static func latest(shared: UInt64, inProcess: UInt64) -> UInt64? {
        let value = max(shared, inProcess)
        return value == 0 ? nil : value
    }
    /// This process's own mark alone (tests, and the proof that it does not depend on the system-wide record).
    static func inProcessMark() -> UInt64 { local.get() }
}

final class BackendRemoteInputLocalMark: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var sharedAt: UInt64 = 0
    func get() -> UInt64 { lock.withLock { value } }
    /// Moves the mark forward. True when the system-wide record is due as well: the first post, and then at most
    /// once per `interval`.
    func set(_ next: UInt64, sharedEvery interval: UInt64) -> Bool {
        lock.withLock {
            value = max(value, next)
            guard sharedAt == 0 || next < sharedAt || next - sharedAt >= interval else { return false }
            sharedAt = next
            return true
        }
    }
}

/// What a trust or approval button asks before it takes a press, and what a trust or approval sheet watches while
/// it is open.
public struct BackendRemoteInputGuard: Sendable {
    /// A press this soon after the app's own remote input is not taken as the person's.
    public static let pressWindow: UInt64 = 2_000_000_000
    /// Remote control counts as going on while the path posted within this long. It starts with the first event
    /// after a quiet spell and ends when the spell is over; either change closes an open trust or approval sheet.
    public static let sessionWindow: UInt64 = 10_000_000_000
    /// A press event's own time is used only when it is at most this long before the press is handled.
    public static let pressEventMaxAge: UInt64 = 60_000_000_000
    private let lastPost: @Sendable () throws -> UInt64?
    private let now: @Sendable () -> UInt64
    public init(lastPost: @escaping @Sendable () throws -> UInt64?, now: @escaping @Sendable () -> UInt64) {
        self.lastPost = lastPost; self.now = now
    }
    /// The real record on this Mac.
    public static let system = BackendRemoteInputGuard(lastPost: { try BackendRemoteInputMark.lastPost() }, now: { BackendRemoteInputMark.now() })
    private func posted(within window: UInt64, at moment: UInt64? = nil) -> Bool {
        do {
            guard let last = try lastPost() else { return false }
            let current = now()
            // The moment judged is the press's own time when that is believable: not later than now and not more
            // than a minute before it. An earlier moment only adds refusals; anything else falls back to now.
            let judged: UInt64
            if let moment, moment <= current, current - moment <= Self.pressEventMaxAge { judged = moment } else { judged = current }
            // A mark later than the moment judged (posted after the press, or the clock base changed under us) is
            // treated as just now.
            return judged < last || judged - last < window
        } catch {
            // Cannot tell: refuse, and treat control as going on.
            return true
        }
    }
    /// True when a press must be refused: the remote-input path posted something in the two seconds before the
    /// press (or since), or the record cannot be read. `pressedAt` is the press event's OWN time on the uptime clock
    /// when the window knows it (security review S1): the press is then judged by when it was made, not by when the
    /// app got round to handling it, so a stalled app cannot let a remote click age into an accepted one. Without
    /// it the moment is now.
    public func refusesPress(at pressedAt: UInt64? = nil) -> Bool { posted(within: Self.pressWindow, at: pressedAt) }
    /// True while remote control of this Mac's screen is going on.
    public func remoteControlActive() -> Bool { posted(within: Self.sessionWindow) }
}
