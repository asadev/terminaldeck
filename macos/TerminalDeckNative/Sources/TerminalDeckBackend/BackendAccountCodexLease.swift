import Foundation
import Dispatch
import Darwin
import TerminalDeckNativeCore

/// Port of src/main/account-vault/codex-auth.ts `CodexAuthKeeper`.
///
/// The CLI's required runtime auth.json is a lease, not a second at-rest
/// credential store. All durable values remain in the encrypted vault: the file
/// is placed (0600, atomically) while the app runs, every write Codex makes to it
/// is captured back, and at quit it is captured one last time and removed.
public actor BackendAccountCodexLease {
    /// TS `CODEX_AUTH_FILE` / `CODEX_AUTH_SLOT`.
    public static let authFile = "auth.json"
    public static let authSlot = "file:auth.json"
    /// TS `MAX_AUTH_BYTES`: a login file is a few kilobytes.
    static let maximumAuthBytes = 256 * 1024

    /// TS `SettleResult`.
    public enum Settle: String, Sendable, Equatable { case kept, placed, none }
    /// TS `capture()` result.
    public enum Capture: String, Sendable, Equatable { case kept, unchanged, signedOut = "signed-out", ignored }
    /// What quit did with the file (TS `release()` returns nothing; the native quit path reports it).
    public enum Release: Sendable, Equatable {
        /// The newest copy is kept and the plaintext file is gone.
        case removed
        /// There was no file to remove.
        case absent
        /// Something outside this app runs Codex on that folder (TS: the file stays).
        case retainedForForeignProcess
        /// Native guard: the newest file could not be captured, so it stays for the next launch to settle.
        case retainedBecauseCaptureFailed(String)
        /// TS: nothing is kept, so the file is not ours to take away.
        case retainedNothingKept
        /// TS ignores a failed unlink; the file stays and the next launch settles it.
        case retainedRemovalFailed
    }

    /// TS `DirWatch`: start watching a directory; returns the stop. Injected so tests drive events.
    public typealias DirWatch = @Sendable (_ directory: String, _ onEvent: @escaping @Sendable () async -> Void) -> @Sendable () -> Void
    /// The debounce timer (TS `setTimeout`); returns the cancel (TS `clearTimeout`).
    public typealias Debounce = @Sendable (_ milliseconds: Int, _ fire: @escaping @Sendable () async -> Void) -> @Sendable () -> Void

    private struct Follow {
        let profile: BackendAccountProfile
        let token: UInt64
        var stop: @Sendable () -> Void
        var timer: (token: UInt64, cancel: @Sendable () -> Void)?
    }
    public nonisolated let readiness: BackendLaunchReadiness
    private let vault: BackendAccountVault
    private var follows: [String: Follow] = [:]
    /// TS Map insertion order, for `following()`.
    private var order: [String] = []
    private var releasing = Set<String>()
    private var tokens: UInt64 = 0
    private let captureEvent: @Sendable (String, String) -> Void
    /// Awaited after every keep or sign-out (TS wire.ts `onCapture` -> `markSlotKept`).
    private let onKept: (@Sendable (String) async -> Void)?
    private let inUse: @Sendable (String) async -> Bool
    private let watchDirectory: DirWatch
    private let debounceMs: Int
    private let schedule: Debounce

    /// TS `new CodexAuthKeeper(vault, options)`. `captureEvent` is TS `onCapture` (account id, kind);
    /// `inUse` defaults to the real process-table check, `watch` to the real directory watcher,
    /// `schedule` to a real clock and `debounceMs` to 250.
    public init(vault: BackendAccountVault,
                captureEvent: @escaping @Sendable (String, String) -> Void = { _, _ in },
                inUse: @escaping @Sendable (String) async -> Bool = { await BackendAccountForeignCodexUse.inUse($0) },
                watch: @escaping DirWatch = BackendAccountCodexLease.realWatch,
                debounceMs: Int = 250,
                schedule: @escaping Debounce = BackendAccountCodexLease.realDebounce,
                onKept: (@Sendable (String) async -> Void)? = nil) {
        self.vault = vault; readiness = vault.readiness; self.captureEvent = captureEvent; self.onKept = onKept
        self.inUse = inUse; watchDirectory = watch; self.debounceMs = debounceMs; self.schedule = schedule
    }

    /// TS wire.ts: the keeper as the app wires it. Something kept for an account, or signed out of it,
    /// marks `file:auth.json` kept on the account — from then on an empty vault reads "signed out",
    /// not "cannot tell" (vault-profiles.test.ts:359).
    public static func wired(vault: BackendAccountVault, profiles: BackendAccountProfileStore,
                             inUse: @escaping @Sendable (String) async -> Bool = { await BackendAccountForeignCodexUse.inUse($0) },
                             watch: @escaping DirWatch = BackendAccountCodexLease.realWatch) -> BackendAccountCodexLease {
        BackendAccountCodexLease(vault: vault, inUse: inUse, watch: watch, onKept: { id in try? await profiles.markSlotKept(id: id, slot: authSlot) })
    }

    private func file(_ profile: BackendAccountProfile) -> URL { URL(fileURLWithPath: profile.configDir).appendingPathComponent(Self.authFile) }
    private func nextToken() -> UInt64 { tokens &+= 1; return tokens }

    /// TS `readAuthFile()`: the contents when they can be a login (a JSON object), or nil.
    /// Half-written text does not parse and is ignored rather than kept. Internal: it returns a secret.
    static func readAuthFile(_ path: String) -> String? {
        guard let bytes = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: path), maximum: maximumAuthBytes), !bytes.isEmpty,
              let raw = try? NativeRPCValue.parseJSON(bytes), raw.fields != nil else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// TS `settle()`: bring the file and the vault into agreement, then follow the file.
    /// A file that is there is the newer copy; a file that is not there is placed from the vault.
    @discardableResult
    public func settle(_ profile: BackendAccountProfile) async throws -> Settle {
        guard readiness == .ready, profile.provider == "codex", !profile.system else { throw BackendAccountFailure("A managed Codex credential lease needs the ready native vault and a named Codex account.") }
        var result = Settle.none
        let path = file(profile)
        let onDisk = Self.readAuthFile(path.path)
        let kept = await vault.readSlot(profile.id, slot: Self.authSlot)
        if let onDisk {
            if onDisk != kept {
                let source = kept == nil ? "adopted" : "refresh"
                let written = await vault.write(accountID: profile.id, provider: "codex", slot: Self.authSlot, value: onDisk, source: source)
                if written.ok && written.changed { captureEvent(profile.id, source); await onKept?(profile.id) }
            }
            // Native hardening: Codex writes it owner-only; keep it that way.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            result = .kept
        } else if let kept, FileManager.default.fileExists(atPath: profile.configDir) {
            // TS writeSecretFile: atomic, owner-only.
            try BackendAccountFiles.writeAtomic(Data(kept.utf8), to: path)
            result = .placed
        }
        follow(profile)
        return result
    }

    /// TS `capture()`: read the file and keep it if it changed. What every watcher event ends in.
    @discardableResult
    public func capture(_ profile: BackendAccountProfile) async -> Capture {
        if releasing.contains(profile.id) { return .ignored }
        return await captureNow(profile)
    }

    private func captureNow(_ profile: BackendAccountProfile) async -> Capture {
        let path = file(profile).path
        let kept = await vault.readSlot(profile.id, slot: Self.authSlot)
        if !FileManager.default.fileExists(atPath: path) {
            if kept == nil { return .unchanged }
            // Codex removed its own login: `codex logout`. Kept copy goes too.
            _ = await vault.dropSlot(profile.id, slot: Self.authSlot)
            captureEvent(profile.id, "signed-out"); await onKept?(profile.id)
            return .signedOut
        }
        guard let onDisk = Self.readAuthFile(path) else { return .ignored }
        if onDisk == kept { return .unchanged }
        let kind = kept == nil ? "sign-in" : "refresh"
        let written = await vault.write(accountID: profile.id, provider: "codex", slot: Self.authSlot, value: onDisk, source: kind)
        guard written.ok else { return .ignored }
        captureEvent(profile.id, kind); await onKept?(profile.id)
        return .kept
    }

    /// TS `follow()`: watch this account's directory for Codex writing its login. Idempotent.
    public func follow(_ profile: BackendAccountProfile) {
        guard follows[profile.id] == nil else { return }
        let token = nextToken(), id = profile.id
        let stop = watchDirectory(profile.configDir) { [weak self] in await self?.changed(id, token) }
        follows[id] = Follow(profile: profile, token: token, stop: stop, timer: nil)
        order.append(id)
    }

    /// A watcher event: restart the debounce.
    private func changed(_ id: String, _ token: UInt64) {
        guard var entry = follows[id], entry.token == token else { return }
        entry.timer?.cancel()
        let timerToken = nextToken()
        let cancel = schedule(debounceMs) { [weak self] in await self?.fired(id, token, timerToken) }
        entry.timer = (timerToken, cancel)
        follows[id] = entry
    }

    private func fired(_ id: String, _ token: UInt64, _ timerToken: UInt64) async {
        guard var entry = follows[id], entry.token == token, entry.timer?.token == timerToken else { return }
        entry.timer = nil
        follows[id] = entry
        await capture(entry.profile)
    }

    private func unfollow(_ id: String) {
        guard let entry = follows.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        entry.timer?.cancel()
        entry.stop()
    }

    /// TS `release()`: the app is quitting — keep the newest copy, stop watching, remove the file.
    /// Called only after this app's CLI children have been stopped.
    public func release(_ profile: BackendAccountProfile) async -> Release {
        // Set before anything awaits, so a watcher tick cannot read the removal as a sign-out.
        releasing.insert(profile.id)
        unfollow(profile.id)
        defer { releasing.remove(profile.id) }
        let path = file(profile).path
        let captured = await captureNow(profile)
        guard await vault.readSlot(profile.id, slot: Self.authSlot) != nil else {
            // Nothing kept, so the file is not ours to take away — it may be a login
            // the vault could not save, and removing it would sign the account out for nothing.
            return FileManager.default.fileExists(atPath: path) ? .retainedNothingKept : .absent
        }
        if captured == .ignored, FileManager.default.fileExists(atPath: path) {
            // Native guard: the newest copy could not be kept (half-written, or the vault refused it).
            return .retainedBecauseCaptureFailed("The newest Codex login could not be kept, so its file was left for the next launch to settle.")
        }
        // Something outside this app is running Codex on this folder right now: the file stays.
        if await inUse(profile.configDir) { return .retainedForForeignProcess }
        if Darwin.unlink(path) == 0 { return .removed }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .retainedRemovalFailed
    }

    /// TS `forget()`: the account was deleted — stop watching and take its file away.
    public func forget(_ profile: BackendAccountProfile) throws {
        releasing.insert(profile.id)
        defer { releasing.remove(profile.id) }
        unfollow(profile.id)
        // Already gone, or the directory went with the account (TS ignores every unlink error).
        _ = Darwin.unlink(file(profile).path)
    }

    /// TS `following()`: every account this keeper is following, in the order it began.
    public func following() -> [String] { order }

    public func releaseAll() async -> [String: Release] {
        let profiles = order.compactMap { follows[$0]?.profile }
        var result: [String: Release] = [:]
        for profile in profiles { result[profile.id] = await release(profile) }
        return result
    }

    /// TS `dispose()`: stop every watcher without touching any file.
    public func dispose() {
        for id in order { unfollow(id) }
        follows.removeAll(); order.removeAll()
    }

    // MARK: - Real defaults

    /// TS `defaultWatch`. A directory source sees the file appear, be replaced or go;
    /// a source on the file itself sees Codex rewrite it in place. Every event counts,
    /// because a missed refresh is a stale login. A directory that cannot be opened is not followed.
    public static let realWatch: DirWatch = { directory, onEvent in
        guard let watcher = BackendAccountCodexDirectoryWatch(directory: directory, onEvent: onEvent) else { return {} }
        return { watcher.stop() }
    }

    /// The real debounce clock.
    public static let realDebounce: Debounce = { milliseconds, fire in
        let task = Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            await fire()
        }
        return { task.cancel() }
    }
}

/// The real directory watcher behind `BackendAccountCodexLease.realWatch`.
final class BackendAccountCodexDirectoryWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terminaldeck.codex-auth-watch", qos: .utility)
    private let directory: String
    private let onEvent: @Sendable () async -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var stopped = false

    init?(directory: String, onEvent: @escaping @Sendable () async -> Void) {
        self.directory = directory; self.onEvent = onEvent
        let fd = Darwin.open(directory, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.armFile(); self?.notify() }
        source.setCancelHandler { Darwin.close(fd) }
        directorySource = source
        queue.sync { armFile() }
        source.resume()
    }

    private func notify() { let onEvent = onEvent; Task { await onEvent() } }

    /// On `queue`: watch the current auth.json, if there is one.
    private func armFile() {
        guard !stopped else { return }
        fileSource?.cancel(); fileSource = nil
        let path = URL(fileURLWithPath: directory).appendingPathComponent(BackendAccountCodexLease.authFile).path
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let data = source?.data, !data.isDisjoint(with: [.delete, .rename, .revoke]) { self.armFile() }
            self.notify()
        }
        source.setCancelHandler { Darwin.close(fd) }
        fileSource = source
        source.resume()
    }

    func stop() {
        queue.sync {
            stopped = true
            fileSource?.cancel(); fileSource = nil
            directorySource?.cancel(); directorySource = nil
        }
    }
}

/// TS `codexHomeInUseNow` / `codexHomeInUse`. Only the foreign-use decision leaves
/// this type. The process listing contains environment secrets and is never logged or persisted.
public enum BackendAccountForeignCodexUse {
    /// The process table as `ps -A -ww -E -o pid=,ppid=,command=` prints it, or nil when it could not be read.
    public typealias ProcessList = @Sendable () async -> String?

    /// TS `codexHomeInUseNow(dir)`.
    public static func inUse(_ directory: String) async -> Bool {
        await inUse(directory, processList: realProcessList, ownPID: getpid())
    }

    /// When in doubt — the listing fails — the answer is "in use", and the file is left for the next launch.
    public static func inUse(_ directory: String, processList: ProcessList, ownPID: Int32) async -> Bool {
        guard let listing = await processList() else { return true }
        return codexHomeInUse(listing: listing, directory: directory, ownPID: ownPID)
    }

    /// The real `/bin/ps` runner (3 s timeout, 32 MB cap). Never logged.
    public static let realProcessList: ProcessList = {
        await Task.detached(priority: .utility) { () -> String? in
            let child = Process(), out = Pipe(), error = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/ps")
            child.arguments = ["-A", "-ww", "-E", "-o", "pid=,ppid=,command="]
            child.standardOutput = out; child.standardError = error
            do { try child.run() } catch { return nil }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 3)
            timer.setEventHandler { if child.isRunning { child.terminate() } }
            timer.resume()
            var bytes = Data()
            do {
                while let chunk = try out.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    if bytes.count + chunk.count > 32 * 1024 * 1024 { child.terminate(); timer.cancel(); return nil }
                    bytes.append(chunk)
                }
            } catch { child.terminate(); timer.cancel(); return nil }
            _ = error.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit(); timer.cancel()
            guard child.terminationStatus == 0 else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }.value
    }

    /// TS `codexHomeInUse(listing, dir, ownPid)`, on UTF-16 code units exactly as the JS regex
    /// `^\s*(\d+)\s+(\d+)\s(.*)$` reads each line. A process counts when its environment names this
    /// exact `CODEX_HOME` (preceded by a space or the start, followed by a space or the end) and it
    /// does not descend from `ownPID` (this app's own sessions, stopped a moment before).
    public static func codexHomeInUse(listing: String, directory: String, ownPID: Int32) -> Bool {
        var parent: [Int: Int] = [:]
        var using: [Int] = []
        let needle = Array(("CODEX_HOME=" + directory).utf16)
        for line in listing.utf16.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard let row = parseRow(Array(line)) else { continue }
            parent[row.pid] = row.ppid
            if names(row.rest, needle) { using.append(row.pid) }
        }
        let own = Int(ownPID)
        func ours(_ pid: Int) -> Bool {
            var at: Int? = pid, hops = 0
            while let current = at, current > 1, hops < 64 {
                if current == own { return true }
                at = parent[current]; hops += 1
            }
            return false
        }
        return using.contains { !ours($0) }
    }

    /// JS `\s` (no `u` flag).
    private static func space(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    private static func digit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    private static func parseRow(_ units: [UInt16]) -> (pid: Int, ppid: Int, rest: ArraySlice<UInt16>)? {
        var at = 0
        while at < units.count, space(units[at]) { at += 1 }
        let pidStart = at
        while at < units.count, digit(units[at]) { at += 1 }
        guard at > pidStart, at < units.count, space(units[at]) else { return nil }
        let pidEnd = at
        while at < units.count, space(units[at]) { at += 1 }
        let ppidStart = at
        while at < units.count, digit(units[at]) { at += 1 }
        guard at > ppidStart, at < units.count, space(units[at]) else { return nil }
        let ppidEnd = at
        let rest = units[(at + 1)...]
        // JS `.` stops at a line terminator, so `$` cannot be reached past one.
        guard !rest.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x2028 || $0 == 0x2029 }) else { return nil }
        guard let pid = Int(String(decoding: units[pidStart..<pidEnd], as: UTF16.self)),
              let ppid = Int(String(decoding: units[ppidStart..<ppidEnd], as: UTF16.self)) else { return nil }
        return (pid, ppid, rest)
    }

    /// The `indexOf` loop: an exact `CODEX_HOME=<dir>` between spaces (or the ends).
    private static func names(_ rest: ArraySlice<UInt16>, _ needle: [UInt16]) -> Bool {
        let base = rest.startIndex, count = rest.count
        guard needle.count <= count else { return false }
        var at = 0
        while at + needle.count <= count {
            var matched = true
            for offset in 0..<needle.count where rest[base + at + offset] != needle[offset] { matched = false; break }
            if matched {
                let afterIndex = at + needle.count
                let beforeSpace = at == 0 || rest[base + at - 1] == 0x20
                let afterSpace = afterIndex == count || rest[base + afterIndex] == 0x20
                if beforeSpace && afterSpace { return true }
            }
            at += 1
        }
        return false
    }
}
