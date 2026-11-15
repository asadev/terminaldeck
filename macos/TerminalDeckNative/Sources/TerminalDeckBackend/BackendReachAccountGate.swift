import Foundation
import TerminalDeckNativeCore

/// The machine's own judgement of a reach connection (design section 2, "The machine's own checks"). It never trusts
/// the relay: a device is let in only when this machine's switch is on, this machine is signed in and entitled, the
/// device's key is in this account's roster (fetched with this machine's own token), the device is neither removed
/// nor signed out, its key matches the one this machine pinned for it, the relay's mark names that same device,
/// policy B's approval (when chosen) is there, and it is not knocking too often. Anything this machine cannot find
/// out is a refusal.
///
/// Everything the gate keeps lives in ONE file in the directory it is given (`reach-account.json`): the switch, the
/// policy, the pinned keys, devices removed or approved here, the last connections. A missing or unreadable file
/// means OFF.
public actor BackendReachAccountGate {
    public static let fileName = "reach-account.json"
    /// An unknown key makes the roster be fetched again when it is older than this (ms).
    static let rosterFreshMs = 10_000.0
    /// The roster is never used older than this (ms); a push (`rosterChanged`) drops it at once.
    static let rosterMaxAgeMs = 60_000.0
    /// The `reach` entitlement is asked again after this (ms).
    static let entitlementMaxAgeMs = 300_000.0
    /// Sealed handshakes allowed per device key in one minute.
    static let handshakesPerMinute = 10
    /// The page's "Last connections".
    static let recentKept = 20
    /// No good list of the account's devices for this long (ms): every account device is cut (REACH-CUT-2), and comes
    /// back by itself with the next good list. Someone blocking this Mac's way to the Cloud cannot hold a link open.
    static let listMissingCutMs = 600_000.0
    /// Removals kept in the file (oldest dropped first; a dropped one is long gone from the account's list).
    static let removalsKept = 256

    struct Pin: Codable, Equatable { let key: String; let firstSeenAtMs: Double; var label: String?; var platform: String? }
    /// One line of "Last connections": opened, or refused and why.
    public struct Connection: Codable, Equatable, Sendable {
        public let deviceId: String?
        public let label: String
        public let platform: String
        public let atMs: Double
        /// nil = opened.
        public let refused: BackendReachRefusal?
    }
    struct State: Codable, Equatable {
        var settings = BackendReachSettings()
        /// deviceId → the key first seen for it on this machine (base64url).
        var pins: [String: Pin] = [:]
        /// Removed with one click on this machine, or announced removed by the service: refused even before the
        /// service's list catches up.
        var removedHere: Set<String> = []
        /// Policy B: approved by the person at this machine.
        var approvedHere: Set<String> = []
        /// Removed (a `devices` push naming it, or Remove pressed here), id → the push's `devicesVersion` ("" when
        /// not known yet). One meaning of Remove (lead, 14 Nov): the removal ends that device's sign-in, and the Cloud
        /// never brings a removed id back (cloud worker reach.ts: `reachRemovedAt` is never cleared, a browser key row
        /// is deleted, a revoked device row is never active again); a FRESH sign-in always arrives as a new device id
        /// (a new random browser key id, a new device row), which is let in on every Mac by itself. So an id here is
        /// refused for good, and forgotten (with its key pin) once a list at least as new as the removal no longer
        /// lists it as usable: from then on the account's own list refuses it.
        var announced: [String: String] = [:]
        var recent: [Connection] = []
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = try c.decode(BackendReachSettings.self, forKey: .settings)
            pins = try c.decodeIfPresent([String: Pin].self, forKey: .pins) ?? [:]
            removedHere = try c.decodeIfPresent(Set<String>.self, forKey: .removedHere) ?? []
            approvedHere = try c.decodeIfPresent(Set<String>.self, forKey: .approvedHere) ?? []
            announced = (try? c.decodeIfPresent([String: String].self, forKey: .announced)) ?? [:]
            recent = try c.decodeIfPresent([Connection].self, forKey: .recent) ?? []
        }
    }

    /// What the page and `cloud.reach.status` read. No keys, no tokens.
    public struct Snapshot: Sendable, Equatable {
        public let settings: BackendReachSettings
        /// The account's devices as last fetched (nil: never fetched in this run), without this machine itself.
        public let devices: [BackendReachRosterDevice]?
        /// Device ids this machine has seen and pinned.
        public let known: Set<String>
        /// deviceId → when it first reached this Mac (ms).
        public let firstSeen: [String: Double]
        public let removedHere: Set<String>
        public let recent: [Connection]
        public let entitled: Bool?
    }

    private let file: URL
    private let service: any BackendReachAccountService
    private let notices: any BackendReachNoticeSink
    private let inputGuard: BackendRemoteInputGuard
    private let now: @Sendable () -> Double
    private var state: State
    /// The last GOOD list of the signed-in account (REACH-CUT-2): a failed fetch keeps it, so its expiry times still
    /// cut; it is dropped when the account signs out or changes. `stale`: a push said it changed, fetch before use.
    private var roster: (value: BackendReachRoster, atMs: Double)?
    private var rosterStale = false
    /// When this run last had a good list (starts at launch: no list at all for the limit also cuts), on the STEADY
    /// clock (REACH-CUT-3): setting the Mac's clock back never stretches the 10 minutes; sleep counts.
    private var lastGoodAtMs: Double
    private let steady: @Sendable () -> Double
    /// Milliseconds on a clock that never goes back and keeps counting while the Mac sleeps (`ContinuousClock`,
    /// mach_continuous_time on Apple platforms). Only differences matter.
    public static let steadyNowMs: @Sendable () -> Double = {
        let elapsed = steadyOrigin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
    private static let steadyOrigin = ContinuousClock.now
    private var entitlement: (value: Bool, account: String, atMs: Double)?
    private var knocks: [Data: [Double]] = [:]
    /// Every removal heard or made in this run, kept in memory even when the file cannot be written: refused for as
    /// long as this app runs.
    private var removedThisRun: Set<String> = []
    /// Removed by any route: here, by the service, or in this run.
    private func isRemoved(_ deviceId: String) -> Bool {
        state.removedHere.contains(deviceId) || state.announced[deviceId] != nil || removedThisRun.contains(deviceId)
    }

    public init(directory: URL, service: any BackendReachAccountService, notices: any BackendReachNoticeSink,
                inputGuard: BackendRemoteInputGuard = .system,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                steady: @escaping @Sendable () -> Double = BackendReachAccountGate.steadyNowMs) {
        self.file = directory.appendingPathComponent(Self.fileName)
        self.service = service; self.notices = notices; self.inputGuard = inputGuard; self.now = now
        self.state = Self.load(file)
        self.steady = steady
        self.lastGoodAtMs = steady()
        self.neverChosen = !FileManager.default.fileExists(atPath: file.path)
    }
    /// No settings file existed when this gate was made: this Mac never chose.
    private var neverChosen: Bool

    /// The Devices window's switch is ON by default (owner, 13 Nov: "sign in once and everything follows"). A Mac that
    /// never chose is switched on once, by the app, without a press; a choice that exists (on or off) is kept, and a
    /// damaged settings file still reads as OFF. Returns whether it switched on.
    @discardableResult
    public func switchOnByDefaultIfNeverChosen() -> Bool {
        guard neverChosen else { return false }
        neverChosen = false
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        var next = state; next.settings.enabled = true
        do { try save(next) } catch { return false }
        return true
    }

    static func load(_ file: URL) -> State {
        guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func save(_ next: State) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = next
        } catch { throw BackendReachFailure.storage }
    }

    // MARK: The person's controls

    public func settings() -> BackendReachSettings { state.settings }

    public func snapshot(machineDeviceId: String? = nil) -> Snapshot {
        .init(settings: state.settings, devices: roster?.value.devices.filter { $0.deviceId != machineDeviceId },
              known: Set(state.pins.keys), firstSeen: state.pins.mapValues(\.firstSeenAtMs),
              removedHere: state.removedHere.union(state.announced.keys).union(removedThisRun), recent: state.recent, entitled: entitlement?.value)
    }

    /// Turning reach ON (and loosening the policy) opens this machine to more devices, so it is a trust press: refused
    /// within the remote-input guard's window, exactly like a trust or approval button (a device already controlling
    /// this Mac's screen cannot switch it on). Turning it OFF is always taken.
    public func setEnabled(_ on: Bool, pressedAt: UInt64? = nil) throws {
        if on, !state.settings.enabled, inputGuard.refusesPress(at: pressedAt) { throw BackendReachFailure.remoteInput }
        var next = state; next.settings.enabled = on
        try save(next)
        if !on { roster = nil; rosterStale = false; knocks = [:] }
    }

    /// B is stricter and always taken; going back to A is guarded like switching on.
    public func setPolicy(_ policy: BackendReachPolicy, pressedAt: UInt64? = nil) throws {
        if policy == .accountOnly, state.settings.policy != .accountOnly, inputGuard.refusesPress(at: pressedAt) {
            throw BackendReachFailure.remoteInput
        }
        var next = state; next.settings.policy = policy
        try save(next)
    }

    /// Policy B: the person at this machine approves a device. A trust press, guarded.
    public func approve(deviceId: String, pressedAt: UInt64? = nil) throws {
        if inputGuard.refusesPress(at: pressedAt) { throw BackendReachFailure.remoteInput }
        var next = state; next.approvedHere.insert(deviceId); next.removedHere.remove(deviceId); next.announced[deviceId] = nil
        try save(next)
        removedThisRun.remove(deviceId)
    }

    /// One-click removal on this machine. Tightening, so never guarded; refused from the next handshake on (the
    /// coordinator also closes that device's live channels and tells the service).
    public func remove(deviceId: String) throws {
        removedThisRun.insert(deviceId)
        // The same removal as the service's (its push follows with the version): no separate per-Mac block.
        var next = state; next.announced[deviceId] = next.announced[deviceId] ?? ""; next.approvedHere.remove(deviceId)
        try save(next)
    }

    /// "Sign out this device" (DEVICE-SIGNOUT-2): the same removal, but this Mac's block holds even when its file
    /// cannot be written (kept in memory for this run). Returns whether it was saved.
    @discardableResult
    public func removeKeepingInMemory(deviceId: String) -> Bool {
        var next = state; next.removedHere.insert(deviceId); next.approvedHere.remove(deviceId)
        do { try save(next); return true } catch { state = next; return false }
    }

    /// The service pushed a new `devicesVersion`: the next judgement fetches the roster again.
    public func rosterChanged() { rosterStale = true; rosterRefusedFor = nil }

    /// Signed out on this machine: the account's list goes with it (never judged against another account's list).
    public func signedOut() { roster = nil; rosterStale = false; entitlement = nil }

    /// A `devices` push naming removed devices: kept as removed here at once (removal is final at the service), and
    /// the roster is fetched again. `version`: the push's `devicesVersion`. Returns the ids the caller must cut off now.
    @discardableResult
    public func devicesRemoved(_ ids: [String], version: String? = nil) -> [String] {
        rosterStale = true
        // In memory first: refused from this instant even if the file below cannot be written.
        removedThisRun.formUnion(ids)
        var next = state
        let known = version.flatMap { Self.isVersion($0) ? $0 : nil } ?? ""
        for id in ids where !next.removedHere.contains(id) && (next.announced[id] ?? "").isEmpty { next.announced[id] = known }
        // A standing approval (policy B) for it goes too.
        next.approvedHere.subtract(ids)
        if next.announced.count > Self.removalsKept {
            let oldest = next.announced.sorted { Self.versionLess($0.value, $1.value) }.prefix(next.announced.count - Self.removalsKept)
            for (id, _) in oldest { next.announced[id] = nil }
        }
        if next != state { try? save(next) }
        return ids
    }

    /// A good list: a removal it is at least as new as, and that it no longer lists as usable, is forgotten here (the
    /// list itself refuses it from now on) and so is that id's key pin (a new sign-in may carry the same browser key
    /// under its new id). A list older than the removal changes nothing. Nothing here ever lets a removed id back.
    private func reconcileAnnounced(_ list: BackendReachRoster) {
        guard !state.announced.isEmpty else { return }
        var next = state
        // The list's `version` and the push's `devicesVersion` are the one counter (cloud worker: both are the account
        // head's `devicesVersion`, raised by every change). Only a plain number at least the removal's counts.
        for (id, version) in state.announced where Self.versionAtLeast(list.version, version) {
            let listed = list.devices.contains { $0.deviceId == id && $0.active && !$0.removed }
            if !listed { next.announced[id] = nil; next.pins[id] = nil }
        }
        if next != state { try? save(next) }
    }

    static func isVersion(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 30 && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    /// Decimal `devicesVersion` order; "" (unknown) is older than everything.
    /// `a` ≥ `b`, both plain decimal numbers; anything else is false (never "new enough").
    static func versionAtLeast(_ a: String, _ b: String) -> Bool {
        guard isVersion(a), isVersion(b) else { return false }
        return !versionLess(a, b)
    }
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = String(a.drop(while: { $0 == "0" })), y = String(b.drop(while: { $0 == "0" }))
        guard x.isEmpty || Self.isVersion(x), y.isEmpty || Self.isVersion(y) else { return false }
        return x.count != y.count ? x.count < y.count : x < y
    }

    /// The list fetched now (the coordinator's re-check of connected devices, so a cached list never cuts a browser
    /// whose sign-in was just renewed). Nil when it cannot be fetched: nothing is judged removed for being unreachable.
    public func refreshRosterNow() async -> [BackendReachRosterDevice]? {
        rosterStale = true
        return await refreshRoster()
    }

    /// The page's list: fetched now when older than a minute.
    public func refreshRoster() async -> [BackendReachRosterDevice]? {
        guard let account = await service.signedInAccount() else { signedOut(); return nil }
        if await entitled(account: account) == false { return nil }   // as before (the 403 gave nil), without asking
        return try? await currentRoster(account: account, unknownKey: false).devices
    }

    // MARK: Judging a connection

    /// The keys the sealed handshake may accept for reach right now (empty when off, signed out, or nothing can be
    /// fetched). A key on this list still goes through `admit`, which makes every check again.
    public func candidateKeys() async -> Set<Data> {
        guard state.settings.enabled, let account = await service.signedInAccount(), await entitled(account: account) != false,
              let list = try? await currentRoster(account: account, unknownKey: false), list.account == account else { return [] }
        let at = now()
        return Set(list.devices.filter { usable($0, at: at) == nil }.map(\.reachKey))
    }

    /// The whole judgement for a device that finished the sealed handshake with `key`. `marked` is the device id
    /// the relay put in the channel's open mark: it must be the roster entry holding that key.
    public func admit(key: Data, marked: String? = nil) async -> BackendReachDecision {
        let decision = await judge(key: key, marked: marked)
        let at = now()
        switch decision {
        case .admitted(let a): note(.init(deviceId: a.deviceId, label: a.label, platform: a.platform, atMs: at, refused: nil))
        case .refused(.rateLimited), .refused(.switchOff): break   // not worth a line each
        case .refused(let why):
            let row = roster?.value.devices.first { $0.reachKey == key }
            note(.init(deviceId: row?.deviceId ?? marked, label: row?.label ?? "Unknown device", platform: row?.platform ?? "unknown", atMs: at, refused: why))
        }
        return decision
    }

    private func judge(key: Data, marked: String?) async -> BackendReachDecision {
        guard state.settings.enabled else { return .refused(.switchOff) }
        guard knock(key) else { return .refused(.rateLimited) }
        guard let account = await service.signedInAccount() else { return .refused(.signedOut) }
        switch await entitled(account: account) {
        case .none: return .refused(.unavailable)
        case .some(false): return .refused(.notEntitled)
        case .some(true): break
        }
        guard let list = try? await currentRoster(account: account, unknownKey: true) else { return .refused(.unavailable) }
        guard list.account == account else { return .refused(.otherAccount) }
        // The switch may have been turned off while the roster was fetched.
        guard state.settings.enabled else { return .refused(.switchOff) }
        guard let device = list.devices.first(where: { $0.reachKey == key }) else { return .refused(.unknownDevice) }
        if let marked, marked != device.deviceId { return .refused(.wrongDevice) }
        if let refusal = usable(device, at: now()) { return .refused(refusal) }
        let encoded = BackendReachWire.base64url(key)
        if let pin = state.pins[device.deviceId], pin.key != encoded {
            await notices.post(.keyChanged(deviceId: device.deviceId, label: device.label))
            return .refused(.keyChanged)
        }
        if state.pins.contains(where: { $0.key != device.deviceId && $0.value.key == encoded }) {
            await notices.post(.keyChanged(deviceId: device.deviceId, label: device.label))
            return .refused(.keyChanged)
        }
        if state.settings.policy == .approveNew, !device.approved, !state.approvedHere.contains(device.deviceId) {
            await notices.post(.awaitingApproval(deviceId: device.deviceId, label: device.label, platform: device.platform))
            return .refused(.notApproved)
        }
        let first = state.pins[device.deviceId] == nil
        if first {
            var next = state; next.pins[device.deviceId] = Pin(key: encoded, firstSeenAtMs: now(), label: device.label, platform: device.platform)
            // A pin that cannot be kept would let the next key through unchecked: refuse instead.
            do { try save(next) } catch { return .refused(.unavailable) }
            await notices.post(.firstConnection(deviceId: device.deviceId, label: device.label, platform: device.platform))
        }
        return .admitted(.init(deviceId: device.deviceId, label: device.label, platform: device.platform, reachKey: key, firstTime: first))
    }

    /// Whether an admitted device may still be connected (the coordinator asks after each roster change).
    /// Judged on the last GOOD list of the account signed in now (a failed fetch keeps it, so its expiry times still
    /// cut). No good list for `listMissingCutMs`: false for every account device (REACH-CUT-2).
    public func stillAdmitted(deviceId: String) async -> Bool {
        guard state.settings.enabled, !isRemoved(deviceId) else { return false }
        guard let account = await service.signedInAccount() else { signedOut(); return false }
        if let held = roster, held.value.account != account { roster = nil }
        if steady() - lastGoodAtMs > Self.listMissingCutMs { return false }
        guard let list = roster?.value else { return true }   // none yet this run (within the limit): pushes cut by id
        guard let device = list.devices.first(where: { $0.deviceId == deviceId }) else { return false }
        return usable(device, at: now()) == nil
    }

    /// Nil when the device may reach this machine as far as the roster and local removals tell.
    private func usable(_ device: BackendReachRosterDevice, at: Double) -> BackendReachRefusal? {
        if isRemoved(device.deviceId) || device.removed || !device.active { return .removed }
        if !device.sessionLive { return .sessionEnded }
        if let ends = device.expiresAtMs, ends <= at { return .sessionEnded }
        return nil
    }

    private func note(_ line: Connection) {
        var next = state
        next.recent.insert(line, at: 0)
        if next.recent.count > Self.recentKept { next.recent.removeLast(next.recent.count - Self.recentKept) }
        try? save(next)
    }

    private func knock(_ key: Data) -> Bool {
        let at = now()
        var recent = (knocks[key] ?? []).filter { at - $0 < 60_000 }
        guard recent.count < Self.handshakesPerMinute else { knocks[key] = recent; return false }
        recent.append(at); knocks[key] = recent
        return true
    }

    /// Nil when it cannot be found out (a refusal).
    private func entitled(account: String) async -> Bool? {
        if let held = entitlement, held.account == account, now() - held.atMs < Self.entitlementMaxAgeMs { return held.value }
        guard let value = try? await service.reachEntitled() else { return nil }
        entitlement = (value, account, now())
        return value
    }

    /// The entitlement as last known, asked again when stale (presence and the page use this too).
    public func entitledNow() async -> Bool? {
        guard let account = await service.signedInAccount() else { return nil }
        return await entitled(account: account)
    }

    private func currentRoster(account: String, unknownKey: Bool) async throws -> BackendReachRoster {
        if let held = roster, held.value.account != account { roster = nil }
        if let held = roster, !rosterStale {
            let age = now() - held.atMs
            if age < (unknownKey ? Self.rosterFreshMs : Self.rosterMaxAgeMs) { return held.value }
        }
        // D (13 Nov, two real Macs): GET /v1/reach/devices answered 403 four times per launch on an account without
        // reach. The service's own capabilities say so first; otherwise a refusal is remembered for this launch.
        if let held = entitlement, held.account == account, !held.value { throw BackendReachFailure.refused(.notEntitled) }
        if rosterRefusedFor == account { throw BackendReachFailure.refused(.notEntitled) }
        let fetched: BackendReachRoster
        do { fetched = try await service.roster() }
        catch let CloudFailure.remote(detail) where !detail.retryable { rosterRefusedFor = account; throw CloudFailure.remote(detail) }
        // Another account's list is never kept or judged with.
        guard fetched.account == account else { return fetched }
        roster = (fetched, now()); rosterStale = false; lastGoodAtMs = steady()
        reconcileAnnounced(fetched)
        return fetched
    }
    /// The account whose reach device list the service refused (not retryable) in this launch: not asked again.
    private var rosterRefusedFor: String?
}
