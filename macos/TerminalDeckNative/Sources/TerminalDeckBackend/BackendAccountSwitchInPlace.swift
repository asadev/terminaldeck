import CryptoKit
import Darwin
import Foundation

/// Port of src/main/account-vault/switch-in-place.ts: hand a running agent another
/// account's login without touching the session — same terminal, same process,
/// same conversation. The seat is retargeted, then the agent is nudged to read its
/// login again. Every dependency is injected; production supplies the broker's.
/// No secret is ever returned, logged or placed on a command line here.
public enum BackendAccountSwitchInPlace {
    public static let nudgeFile = ".credentials.json"
    public static let nudgeBody = "{}\n"
    public static let refreshLock = ".oauth_refresh.lock"
    public static let refreshLockStaleMilliseconds: Double = 60_000
    public static let refreshWaitMilliseconds: Double = 10_000
    static let refreshPollMilliseconds: Double = 100
    public static let loginSlot = "keychain:Claude Code-credentials"

    public enum Nudged: String, Sendable, Equatable { case touched, created, none }
    /// TS `LoginSource`: kept by the app, or by the agent in its own keychain item under `directory`'s hash.
    public enum LoginSource: Sendable, Equatable { case vault, keychain(directory: String?) }
    /// TS `InPlaceAccount`.
    public struct Account: Sendable, Equatable {
        public let id: String, name: String, configDir: String
        public init(id: String, name: String, configDir: String) { self.id = id; self.name = name; self.configDir = configDir }
    }
    /// The parts of a seat this step reads (TS `Seat`).
    public struct SeatView: Sendable, Equatable {
        public let launchAccountID: String, launchDirectory: String?, storeDirectory: String?
        public init(launchAccountID: String, launchDirectory: String?, storeDirectory: String?) {
            self.launchAccountID = launchAccountID; self.launchDirectory = launchDirectory; self.storeDirectory = storeDirectory
        }
    }
    public struct KeychainAnswer: Sendable, Equatable {
        public let code: Int32, stdout: String, stderr: String
        public init(code: Int32, stdout: String, stderr: String) { self.code = code; self.stdout = stdout; self.stderr = stderr }
    }
    /// TS `InPlaceDeps`.
    public struct Dependencies: Sendable {
        public var seat: @Sendable (String) async -> SeatView?
        public var source: @Sendable (String) async -> LoginSource?
        public var adopting: @Sendable (String, String) async -> Bool
        public var held: @Sendable (String) async -> Bool
        /// Keep `value` in `slot` (nil = the agent has none: settle the slot). True when kept.
        public var keep: @Sendable (String, String, String?) async -> Bool
        /// The real `security` command (argv after the program name, stdin). Nil = none available.
        public var keychain: (@Sendable ([String], String?) async -> KeychainAnswer)?
        public var user: String
        public var retarget: @Sendable (String, String) async -> Bool
        public var launchDir: @Sendable (SeatView) -> String?
        public var sha256: @Sendable (String) -> String
        public var now: @Sendable () -> Double
        public var wait: @Sendable (Double) async -> Void
        public init(seat: @escaping @Sendable (String) async -> SeatView?, source: @escaping @Sendable (String) async -> LoginSource?,
                    adopting: @escaping @Sendable (String, String) async -> Bool, held: @escaping @Sendable (String) async -> Bool,
                    keep: @escaping @Sendable (String, String, String?) async -> Bool,
                    keychain: (@Sendable ([String], String?) async -> KeychainAnswer)?, user: String,
                    retarget: @escaping @Sendable (String, String) async -> Bool, launchDir: @escaping @Sendable (SeatView) -> String?,
                    sha256: @escaping @Sendable (String) -> String = BackendAccountSwitchInPlace.sha256Hex,
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                    wait: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .milliseconds(Int64($0))) }) {
            self.seat = seat; self.source = source; self.adopting = adopting; self.held = held; self.keep = keep; self.keychain = keychain
            self.user = user; self.retarget = retarget; self.launchDir = launchDir; self.sha256 = sha256; self.now = now; self.wait = wait
        }
    }
    /// TS `InPlaceResult`.
    public enum Result: Sendable, Equatable {
        case switched(nudged: Nudged, nudgeFile: String?, waitedForRefreshMilliseconds: Double)
        case refused(String)
        public var ok: Bool { if case .switched = self { true } else { false } }
    }

    public static func sha256Hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// TS keychain-requests.ts `serviceFor()`.
    static func serviceFor(_ slot: String, directory: String?, hash: (String) -> String) -> String {
        let base = slot.hasPrefix("keychain:") ? String(slot.dropFirst("keychain:".count)) : slot
        guard let directory else { return base }
        return base + "-" + String(hash(directory.precomposedStringWithCanonicalMapping).prefix(8))
    }

    /// TS `refreshInProgress()`: the CLI's own refresh lock in that folder, while it is fresh.
    public static func refreshInProgress(_ directory: String, now: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        var info = stat()
        guard stat((directory as NSString).appendingPathComponent(refreshLock), &info) == 0 else { return false }
        let modified = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        return now - modified < refreshLockStaleMilliseconds
    }

    /// TS `nudge()`: change only the time of a plaintext store that exists (a login in it is never
    /// touched); otherwise create `{}` owner-only, which the CLI reads exactly like none.
    @discardableResult
    public static func nudge(_ directory: String, at: Date = Date()) -> Nudged {
        let file = (directory as NSString).appendingPathComponent(nudgeFile)
        let seconds = at.timeIntervalSince1970
        var times = [timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000)),
                     timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))]
        if utimes(file, &times) == 0 { return .touched }
        let descriptor = Darwin.open(file, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .none }
        defer { Darwin.close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        let body = Data(nudgeBody.utf8)
        let written = body.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, body.count) }
        return written == body.count ? .created : .none
    }

    /// TS `clearNudge()`: take back only a file that still holds exactly what was put there.
    @discardableResult
    public static func clearNudge(_ file: String) -> Bool {
        guard let bytes = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: file), maximum: 4096),
              bytes == Data(nudgeBody.utf8), unlink(file) == 0 else { return false }
        return true
    }

    /// TS `readyToServe()`: nil when the account's login can be served; otherwise the sentence
    /// saying why the session was left as it is. A login the agent keeps is checked for presence
    /// only (no `-w`), so the secret is never asked for.
    public static func readyToServe(_ account: Account, dependencies deps: Dependencies) async -> String? {
        guard let source = await deps.source(account.id) else {
            return "\(account.name)’s login cannot be reached from here right now, so this session was left as it is."
        }
        if case .keychain(let directory) = source {
            guard let keychain = deps.keychain else { return nil }
            let service = serviceFor(loginSlot, directory: directory, hash: deps.sha256)
            let asked = await keychain(["find-generic-password", "-a", deps.user, "-s", service], nil)
            if asked.code == 0 { return nil }
            return asked.code == 44
                ? "\(account.name) is not signed in yet, so this session was left as it is. Sign in to it first, then switch."
                : "The keychain would not say whether \(account.name) is signed in, so this session was left as it is."
        }
        if await deps.held(account.id) { return nil }
        if !(await deps.adopting(account.id, loginSlot)) { return nil }
        guard let keychain = deps.keychain else { return nil }
        let service = serviceFor(loginSlot, directory: account.configDir, hash: deps.sha256)
        let read = await keychain(["find-generic-password", "-a", deps.user, "-w", "-s", service], nil)
        let value = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if read.code == 0, !value.isEmpty {
            return await deps.keep(account.id, loginSlot, value) ? nil : "\(account.name)’s login could not be saved here, so this session was left as it is."
        }
        if read.code == 44 {
            _ = await deps.keep(account.id, loginSlot, nil)
            return "\(account.name) is not signed in yet, so this session was left as it is. Sign in to it first, then switch."
        }
        return "The keychain would not hand over \(account.name)’s login, so this session was left as it is."
    }

    /// TS `switchInPlace()`: refuse before anything changes; wait (bounded) for a refresh in the
    /// session's folder; retarget the seat; nudge. Nothing else — no restart, no new process.
    public static func switchInPlace(sessionID: String, account: Account, dependencies deps: Dependencies) async -> Result {
        guard let seat = await deps.seat(sessionID) else {
            return .refused("This session was started before accounts could be switched in place.")
        }
        if let refused = await readyToServe(account, dependencies: deps) { return .refused(refused) }
        let directory = deps.launchDir(seat)
        let started = deps.now()
        while let directory, refreshInProgress(directory, now: deps.now()), deps.now() - started < refreshWaitMilliseconds {
            await deps.wait(refreshPollMilliseconds)
        }
        let waited = deps.now() - started
        guard await deps.retarget(sessionID, account.id) else { return .refused("This session ended before it could be switched.") }
        guard let directory else { return .switched(nudged: .none, nudgeFile: nil, waitedForRefreshMilliseconds: waited) }
        return .switched(nudged: nudge(directory), nudgeFile: (directory as NSString).appendingPathComponent(nudgeFile), waitedForRefreshMilliseconds: waited)
    }
}
