import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// What the composition must do after an account change (AM8, N3).
public enum BackendCloudAccountSessionChange: Sendable, Equatable {
    /// Signed in and the server allows Cloud.
    case signedIn
    /// The server explicitly said Cloud is not allowed: nothing runs, the saved sign-in is KEPT.
    case dormant
    /// The person signed out, or the server said the session itself is invalid or revoked: the saved sign-in is gone.
    case signedOut
}

/// Sign-out removes THIS device from the account at the service (two-Mac proof, 13 Nov). The real transport has it;
/// a transport without it signs out locally only.
public protocol BackendCloudDeviceSelfRemoval: Sendable {
    /// `expectedVaultVersion` is sent when known; a device removing itself does not need it (proof 2).
    func removeOwnDevice(expectedVaultVersion: CloudSequence?) async throws
}
extension CloudSyncTransport: BackendCloudDeviceSelfRemoval {}

/// Settings → Devices "Sign out this device" (owner, 14 Nov: Remove has one meaning, it signs that device out): the
/// Cloud ends ANOTHER device's sign-in. The real transport has it; a transport without it cannot sign others out.
public protocol BackendCloudDeviceSignOut: Sendable {
    func removeDevice(deviceId: String, expectedVaultVersion: CloudSequence) async throws
}
extension CloudSyncTransport: BackendCloudDeviceSignOut {}
/// How many of his browser sign-ins the last sign-out also ended (the service's optional `browsersEnded`).
public protocol BackendCloudDeviceSignOutBrowsers: Sendable {
    func browsersEndedByLastRemoval() async -> Int
}
extension CloudSyncTransport: BackendCloudDeviceSignOutBrowsers {
    public func browsersEndedByLastRemoval() async -> Int { lastRemovalBrowsersEnded }
}

/// Settings → a device's page "Name" (owner, 15 Nov): the Cloud renames a device of the account.
public protocol BackendCloudDeviceRename: Sendable {
    func renameDevice(deviceId: String, name: String) async throws
}
extension CloudSyncTransport: BackendCloudDeviceRename {}

/// Why a device was not signed out. Nothing was changed in each case.
public enum BackendDeviceSignOutRefusal: Error, Equatable, Sendable {
    /// This Mac's own row: the person signs this Mac out from Profile, never from its row.
    case thisMac
    /// `rotation_required`: only a Cloud not yet updated says it (the new one signs a key-holding device out at once and
    /// marks the key change due; lost-device design A1).
    case holdsSavedPasswordsKey
    /// Not signed in here, or this copy cannot sign other devices out.
    case notSignedIn
}

/// Design B4: this Mac was signed out by another of his devices. `byName` from Cloud's refusal when it says it.
public struct BackendCloudSignedOutElsewhere: Sendable, Equatable {
    public let sub: String
    public let deviceId: String
    public let byName: String?
    public let at: Int64
    /// Cloud said "this device was removed" (device_revoked), not only "this sign-in ended" (the Store's refusal).
    public let revoked: Bool
    public init(sub: String, deviceId: String, byName: String?, at: Int64, revoked: Bool = true) {
        self.sub = sub; self.deviceId = deviceId; self.byName = byName; self.at = at; self.revoked = revoked
    }
    /// One plain line for Profile (no ids, no codes).
    public var line: String {
        let format = DateFormatter(); format.dateStyle = .medium; format.timeStyle = .short
        let when = format.string(from: Date(timeIntervalSince1970: TimeInterval(at) / 1000))
        let kept = "Everything on this Mac is kept; sign in again and it all comes back."
        if let byName { return "Signed out from \(byName) on \(when). " + kept }
        return (revoked ? "Signed out from another of your devices on \(when). " : "Your Cloud sign-in ended on \(when). ") + kept
    }
    static func plain(_ raw: String) -> String? {
        let name = String(raw.filter { !$0.isNewline }.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// What the Cloud's `POST /devices/remove` came to (DEVICE-SIGNOUT-2).
public enum BackendDeviceSignOutOutcome: Sendable, Equatable {
    /// The Cloud revoked it and ended its sign-in now.
    case signedOut
    /// The same, and the Cloud also ended his browser sign-ins (a computer signed out from another device).
    case signedOutBrowsersEnded
    /// The Cloud had no active row for it any more: its list shows it revoked (already signed out).
    case alreadyGone
    /// The Cloud has no such device at all: a browser's reach key, which only reach's removal signs out. The caller
    /// must judge success by that removal reaching the Cloud.
    case notAnAccountDevice
}

/// The trust change was made, but the device's reach could not be removed yet (item 4).
public struct BackendReachLinkFailure: Error, Equatable, Sendable { public init() {} }

public actor BackendCloudAccount {
    public let identity: BackendCloudAccountIdentity
    private let configuration: CloudAccountConfiguration
    private let http: any BackendCloudAccountHTTP
    private let connect: @Sendable () async throws -> BackendCloudAccountPorts
    private var lastPorts: BackendCloudAccountPorts?
    private let clock: @Sendable () -> Int64
    private var current: CloudAccountSnapshot = .signedOut
    /// Status-line lane: one "Sync now" pass at a time.
    public let syncNowGate = BackendCloudSyncNowGate()
    /// Status-line lane: the account's room left (`/state` budget `bytesLeft`); nil before the first answer.
    private var storageBytesLeft: Int64?
    public func storageLeft() -> Int64? { storageBytesLeft }
    private struct Flow: Sendable { let verifier: String; let state: String; let callback: CloudHandoffCallback; let expires: Int64 }
    private var flow: Flow?
    private var generation = 0
    private var userPaused = false
    private var refreshing: Task<Void, Never>?
    /// Cloud's own refusals (round 4): one fresh token or one re-registration first, then a repeat is a refused session.
    private var triedFreshToken = false
    private var triedReRegistration = false
    private var triedClock = false
    static let clockProblem = "Cloud could not check this Mac's request. Check this Mac's date and time; your local work is kept."
    /// A refusal that cannot be cured by waiting on our side but must never sign the Mac out (clock, repeated proof):
    /// the last decision holds, the person is told what to check, and it is retried with back-off (round 5).
    private func noAnswer(problem: String) {
        failures += 1
        publish(current.carried(phase: current.phase == .signedOut ? .needsSignIn : current.phase, problem: problem))
        scheduleRetry()
    }
    private var retrying: Task<Void, Never>?
    private var failures = 0
    /// Monotonic time (ns, keeps counting during sleep) of the last explicit server answer (N3a). Never a wall clock.
    private var checkedAt: UInt64?
    private let monotonic: @Sendable () -> UInt64
    /// Re-check the decision after this long; the decision itself never expires by time (N2).
    public static let recheckAfterNanoseconds: UInt64 = 240 * 1_000_000_000
    private var listeners: [UUID: AsyncStream<CloudAccountSnapshot>.Continuation] = [:]
    private var sessionHook: (@Sendable (BackendCloudAccountSessionChange) async -> Void)?
    /// Composition learns of sign-in, dormancy and sign-out so a Mac without Cloud returns to its no-account launch (AM8).
    public func setSessionHook(_ hook: @escaping @Sendable (BackendCloudAccountSessionChange) async -> Void) { sessionHook = hook }
    /// Design B4 (a lost Mac): this Mac was signed out by ANOTHER device (Cloud or the Store refused its session; the
    /// person's own "Sign out" never calls it). Called once, after Cloud work stopped and before the sign-in is
    /// cleared, so the app removes this device id's Cloud keys and shows the line. Never any of his data.
    private var signedOutElsewhereHook: (@Sendable (BackendCloudSignedOutElsewhere) async -> Void)?
    public func setSignedOutElsewhereHook(_ hook: @escaping @Sendable (BackendCloudSignedOutElsewhere) async -> Void) { signedOutElsewhereHook = hook }
    /// The last time this happened in this run (tests, and the page after the hook).
    public private(set) var lastSignedOutElsewhere: BackendCloudSignedOutElsewhere?
    public static func monotonicNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    /// 13 Nov (owner): no "Sign in to Cloud as …?" sheet. The account is named on the official website's page, and the
    /// app finishes only a return that answers the sign-in THIS app started (state, token, lifetime, once).
    /// How this Mac trusts the account's other devices (owner, 13 Nov). The app's SETTING defaults to automatic
    /// ("account") and the composition sets it here at activation; an account nobody set stays on the stricter
    /// "ask" (the earlier behaviour exactly). No tool reaches it.
    private var trustMode: BackendCloudTrustMode = .ask
    public func setTrustMode(_ mode: BackendCloudTrustMode) { trustMode = mode }
    public func currentTrustMode() -> BackendCloudTrustMode { trustMode }
    /// One Remove means one thing (item 4, 13 Nov): after "Remove" stops trusting a device here, reach by account is
    /// told too (the app hands in a link that removes the device's reach only while reach's switch is on).
    private var reachLink: (@Sendable (String) async throws -> Void)?
    public func setReachLink(_ link: (@Sendable (String) async throws -> Void)?) { reachLink = link }
    /// 13 Nov: the finish of a sign-in writes ONE plain line per stage to the app's log (`cloud sign-in: <stage>
    /// ok|failed: <kind>`), never a token, code, key, e-mail or name. The failing stage is kept for the page's notice.
    private var stageLog: (@Sendable (String) async -> Void)?
    public func setStageLog(_ log: @escaping @Sendable (String) async -> Void) { stageLog = log }
    /// The stage the last sign-in finish stopped at, or nil when it finished.
    public private(set) var lastFinishFailure: String?
    private var stage = ""
    private func reach(_ next: String) async {
        if !stage.isEmpty { await stageLog?("cloud sign-in: \(stage) ok") }
        stage = next
    }
    /// The error's kind only: a case name or the service's code, never a payload.
    public nonisolated static func kind(_ error: any Error) -> String {
        if let failure = error as? CloudFailure, case .remote(let detail) = failure { return "remote " + detail.code }
        if let url = error as? URLError { return "network \(url.code.rawValue)" }
        if error is CancellationError { return "cancelled" }
        return String(String(describing: error).prefix(80))
    }
    public init(configuration: CloudAccountConfiguration, identity: BackendCloudAccountIdentity, http: any BackendCloudAccountHTTP,
                transport: any CloudTransportPort, outbox: any CloudOutboxPort, trust: BackendCloudTrustStore? = nil,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                monotonic: @escaping @Sendable () -> UInt64 = { BackendCloudAccount.monotonicNow() },
                machine: BackendCloudMachineFacts? = nil) {
        self.configuration = configuration; self.identity = identity; self.http = http; self.clock = clock; self.monotonic = monotonic
        self.connect = { BackendCloudAccountPorts(transport: transport, outbox: outbox, trust: trust) }
        self.machine = machine
    }
    public init(configuration: CloudAccountConfiguration, identity: BackendCloudAccountIdentity, http: any BackendCloudAccountHTTP,
                ports: @escaping @Sendable () async throws -> BackendCloudAccountPorts,
                clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                monotonic: @escaping @Sendable () -> UInt64 = { BackendCloudAccount.monotonicNow() },
                machine: BackendCloudMachineFacts? = nil) {
        self.configuration = configuration; self.identity = identity; self.http = http; self.clock = clock; self.monotonic = monotonic; self.connect = ports
        self.machine = machine
    }
    // MARK: One row per machine (MAC-NEXT-10)
    /// What this Mac tells the service about itself (machine id + friendly name); nil = nothing is sent.
    private var machine: BackendCloudMachineFacts?
    /// The launch check runs once per run of the app; a sign-in sends the pair with its registration instead.
    private var describedThisRun = false
    public func setMachineFacts(_ facts: BackendCloudMachineFacts?) { machine = facts }
    /// An answer that refuses the request's SHAPE (an older service that rejects unknown fields): the registration is
    /// then sent again without them. Never a sign-in or proof refusal.
    nonisolated static func fieldsRefused(_ error: any Error) -> Bool {
        if let failure = error as? CloudFailure {
            if failure == .invalidRequest { return true }
            if case .remote(let detail) = failure { return ["invalid_request", "bad_request", "unknown_field", "validation_failed"].contains(detail.code) }
        }
        return false
    }
    /// Registers this device, with its machine id and friendly name when known. A service that refuses the fields
    /// gets the plain registration; one that echoes the name has the pair remembered so launch does not send it again.
    private func register(_ registration: CloudDeviceRegistration, subject: String, on transport: any CloudTransportPort) async throws -> CloudDeviceRegistrationReceipt {
        describedThisRun = true
        guard let machine, let full = machine.pair(subject: subject, hostName: configuration.deviceLabel) else { return try await transport.registerDevice(registration) }
        // A service that refuses a field it does not know yet: first without the host name, then plain.
        var short = full; short.hostName = nil
        for pair in [full, short] {
            var described = registration
            described.machineId = pair.machineId; described.displayName = pair.displayName; described.hostName = pair.hostName
            let receipt: CloudDeviceRegistrationReceipt
            do { receipt = try await transport.registerDevice(described) } catch where Self.fieldsRefused(error) {
                await stageLog?("cloud device: machine fields not taken at registration (\(Self.kind(error)))")
                continue
            }
            if receipt.deviceId == registration.deviceId, receipt.displayName == pair.displayName {
                machine.remember(BackendCloudMachineFacts.mark(deviceId: registration.deviceId, pair))
            }
            return receipt
        }
        await stageLog?("cloud device: registered plain; machine name tried again at next launch")
        return try await transport.registerDevice(registration)
    }
    /// Once per run, for a Mac that is already registered: send the pair through the self-rename call when it differs
    /// from the one the service accepted last. Any failure costs nothing; the next launch tries again.
    /// `listed` is the service's device list of this status read: a remembered pair whose name the list no longer
    /// shows for this Mac (the service lost it) is sent again.
    private func describeSelfOnce(_ bound: BackendCloudAccountPorts, subject: String, listed: [CloudDevice]) {
        guard !describedThisRun, let machine, let describer = bound.transport as? any BackendCloudDeviceSelfDescription else { return }
        describedThisRun = true
        let label = configuration.deviceLabel
        Task {
            guard let pair = machine.pair(subject: subject, hostName: label), let deviceId = try? await self.identity.deviceRegistration().deviceId else { return }
            let mark = BackendCloudMachineFacts.mark(deviceId: deviceId, pair)
            let shown = listed.first { $0.deviceId == deviceId }?.displayName
            guard machine.accepted() != mark || shown != pair.displayName else { return }
            do {
                var echoed: String?
                do { echoed = try await describer.describeOwnDevice(label: label, machineId: pair.machineId, displayName: pair.displayName, hostName: pair.hostName) }
                catch where Self.fieldsRefused(error) && pair.hostName != nil {
                    // A service that does not know the host name yet: the id and the name still go; the full set
                    // (with the host name) is tried again at the next launch, since only it is remembered.
                    _ = try await describer.describeOwnDevice(label: label, machineId: pair.machineId, displayName: pair.displayName, hostName: nil)
                    await self.stageLog?("cloud device: machine name sent without the host name; tried again at next launch")
                    return
                }
                if echoed == pair.displayName {
                    machine.remember(mark)
                    await self.stageLog?("cloud device: machine name sent")
                } else {
                    await self.stageLog?("cloud device: machine name not taken by this service; tried again at next launch")
                }
            } catch {
                await self.stageLog?("cloud device: machine name not sent (\(Self.kind(error))); tried again at next launch")
            }
        }
    }
    private func ports() async throws -> BackendCloudAccountPorts {
        let value = try await connect()
        lastPorts = value
        return value
    }
    /// The last EXPLICIT server decision holds (N2, N3): only an answer from the server closes Cloud; time passing,
    /// a timeout or no network never does and never pauses sending. Whoever reads re-checks lazily once it is due.
    public func state() -> CloudAccountSnapshot {
        renewIfDue()
        return current
    }
    public func renewIfDue() {
        guard refreshing == nil, retrying == nil, [.signedIn, .paused, .needsSignIn].contains(current.phase) else { return }
        if let checkedAt, monotonic() &- checkedAt < Self.recheckAfterNanoseconds { return }
        startRefresh()
    }
    private func startRefresh() {
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            try? await self?.refresh()
            await self?.renewed()
        }
    }
    private func renewed() { refreshing = nil }
    /// Proof 3 (13 Nov): the page read the sync core's progress only at a full status read, so it said "Sending is
    /// held up" through a whole first copy and "19 changes still to fetch" for minutes after they had arrived. This
    /// reads this Mac's own progress again (no request to the service) and republishes it. Returns whether it read.
    @discardableResult
    public func refreshLocalProgress() async -> Bool {
        guard [.signedIn, .paused].contains(current.phase), refreshing == nil, let bound = lastPorts else { return false }
        let version = generation
        guard let progress = try? await bound.outbox.restoreProgress() else { return false }
        let baseline = try? await bound.outbox.baselineProgress()
        guard generation == version, [.signedIn, .paused].contains(current.phase), refreshing == nil else { return false }
        let fresh = current.withLocalProgress(coverage: progress.coverage, waitingRecords: progress.queued, blockedRecords: progress.blocked,
                                              baseline: baseline, fetched: progress.brainSeq)
        if fresh != current { publish(fresh) }
        return true
    }
    /// Bounded notice of a revoked entitlement or session while signed in and awake with Settings closed (round 3):
    /// one quiet re-check every few hours, off the main path, skipped in Low Power Mode. Not a poll of the page.
    private var backgroundInterval: Duration = .seconds(3 * 3600)
    /// Fixtures shorten the interval; the app keeps three hours.
    public func setBackgroundCheckInterval(_ interval: Duration) { backgroundInterval = interval }
    private var background: Task<Void, Never>?
    private func startBackgroundCheck() {
        guard background == nil else { return }
        let interval = backgroundInterval
        background = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if ProcessInfo.processInfo.isLowPowerModeEnabled { continue }
                await self?.backgroundCheckDue()
            }
        }
    }
    private func backgroundCheckDue() {
        guard [.signedIn, .paused].contains(current.phase) else { background?.cancel(); background = nil; return }
        startRefresh()
    }
    /// Two-Mac proof (13 Nov): a running Mac saw a newly joined device only after a restart. The app asks this on a
    /// quiet timer while signed in (about once a minute while the Cloud page is open, every few minutes otherwise),
    /// when the app becomes active and on the service's `devices` event. ONE request (the device list); only when the
    /// account's devices really changed (joined, removed, new key, new name) does the full status read follow, which
    /// trusts a joined device automatically and puts up its "joined your account" notice. Signed out, dormant or
    /// before the first status read: nothing is sent. Returns whether the status was read again.
    @discardableResult
    public func refreshDevicesIfChanged() async throws -> Bool {
        guard [.signedIn, .paused].contains(current.phase), refreshing == nil, retrying == nil, let bound = lastPorts else { return false }
        let version = generation
        let fresh: [CloudDevice]
        do { fresh = try await bound.transport.devices().devices }
        catch {
            // MAC-NEXT-12b: a registration retired by the one-row-per-machine rule loses its session on the service
            // (user.ts retire(): device revoked, its sign-in session and refresh tokens deleted), so every request
            // of it answers 401 sign_in_required (403 device_revoked on a socket). The quiet device watch used to
            // drop that error, and the Mac retried in silence for hours. Now it runs the full status read at once,
            // which asks the Store for a fresh token: a live session carries on by itself, a deleted one is said
            // as "sign in again" (sessionRefused).
            if case .remote(let detail)? = error as? CloudFailure,
               ["sign_in_required", "token_expired", "device_revoked", "bad_device_proof"].contains(detail.code) {
                try await refresh()
                return true
            }
            throw error
        }
        guard generation == version, [.signedIn, .paused].contains(current.phase),
              Self.deviceFingerprint(fresh) != Self.deviceFingerprint(current.devices) else { return false }
        try await refresh()
        return true
    }
    /// What makes the account's device list "changed" for `refreshDevicesIfChanged`; the last-seen time does not.
    nonisolated static func deviceFingerprint(_ devices: [CloudDevice]) -> [String] {
        devices.map { [$0.deviceId, $0.status.rawValue, BackendCloudDeviceCode.keyId($0.signPublicJwk) ?? "-", $0.label,
                       String($0.secretsApproved)].joined(separator: "|") }.sorted()
    }
    /// The system reports the network path is usable again: retry a failed check now instead of waiting for back-off.
    public func networkReturned() {
        Task { await self.sendLeaveNotes() }
        guard failures > 0, [.signedIn, .paused, .needsSignIn].contains(current.phase) else { return }
        retrying?.cancel(); retrying = nil
        startRefresh()
    }
    /// Back-off for checks that got no answer: 30 s doubling to 30 min. A retry, never a poll of a healthy account.
    static func retrySeconds(_ failures: Int) -> Int { min(1800, 30 << min(max(failures, 1) - 1, 6)) }
    /// The service (or this Mac's own pacing) said "wait", not "no".
    public static func waitAnswer(_ error: any Error) -> Bool {
        guard let failure = error as? CloudFailure else { return false }
        if failure == .budgetPaused { return true }
        if case .remote(let detail) = failure { return ["rate_limited", "budget_paused"].contains(detail.code) }
        return false
    }
    public static func waitProblem(at date: Date) -> String {
        let format = DateFormatter(); format.dateStyle = .none; format.timeStyle = .short
        return "Cloud asked this Mac to wait. You are still signed in and your work is kept; Cloud tries again by itself at \(format.string(from: date))."
    }
    private func scheduleRetry() {
        guard retrying == nil else { return }
        let seconds = Self.retrySeconds(failures)
        retrying = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.retryDue()
        }
    }
    private func retryDue() { retrying = nil; startRefresh() }
    /// Only these mean the SESSION itself is invalid or revoked; anything else is "no answer" and keeps the sign-in (N3).
    static func sessionRefused(_ error: any Error) -> Bool {
        if let failure = error as? CloudFailure {
            switch failure {
            case .deviceRevoked: return true
            case .remote(let detail):
                guard !detail.retryable else { return false }
                // The Store's real answers (auth.ts): refresh_token_not_found, session_not_found, user_not_found. Not
                // refresh_token_already_used on its own: two refreshes can race and the winner's pair is already saved.
                return ["session_not_found", "refresh_token_not_found", "user_not_found",
                        "invalid_grant", "session_revoked", "session_invalid", "invalid_session", "device_revoked", "user_banned"].contains(detail.code)
            default: return false
            }
        }
        return false
    }
    public func events() -> AsyncStream<CloudAccountSnapshot> {
        AsyncStream { continuation in
            let id = UUID(); listeners[id] = continuation; continuation.yield(current)
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }
    private func remove(_ id: UUID) { listeners[id] = nil }
    private func publish(_ snapshot: CloudAccountSnapshot) {
        current = snapshot; listeners.values.forEach { $0.yield(snapshot) }
    }
    /// A link can only START a sign-in while no account is saved on this Mac; it never closes an open gate (finding 3).
    public func beginSignIn(callback: CloudHandoffCallback, provider: String? = nil) async throws -> URL {
        guard (1024...65535).contains(callback.port), callback.pathToken.count >= 20,
              provider == nil || ["google", "github"].contains(provider!) else { throw CloudFailure.invalidRequest }
        guard try await identity.existing() == nil else { throw CloudFailure.idReused }
        generation += 1
        let verifier = Self.random(bytes: Self.verifierBytes), state = Self.random(bytes: Self.stateBytes)
        let challenge = BackendCloudAccountIdentity.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        flow = .init(verifier: verifier, state: state, callback: callback, expires: clock() + 300_000)
        var url = URLComponents(url: configuration.websiteStartURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "challenge", value: challenge), .init(name: "state", value: state), .init(name: "port", value: String(callback.port)), .init(name: "callback", value: callback.pathToken)]
        if let provider { url.queryItems?.append(.init(name: "provider", value: provider)) }
        if !current.visible(at: 0) { publish(.init(phase: .signingIn, gate: .closed)) }
        return url.url!
    }
    /// 13 Nov (owner): the sign-in through the official website. The browser comes back to
    /// `terminaldeck://cloud/return/<token>?code&state`; no port and no listener. Same token (22), state (43) and PKCE.
    public func beginAppSignIn(provider: String? = nil, platform: String = "macos") async throws -> URL {
        guard provider == nil || ["google", "github"].contains(provider!) else { throw CloudFailure.invalidRequest }
        guard try await identity.existing() == nil else { throw CloudFailure.idReused }
        generation += 1
        let callback = CloudHandoffCallback.app(platform: platform, pathToken: Self.random(bytes: Self.callbackCodeBytes))
        let verifier = Self.random(bytes: Self.verifierBytes), state = Self.random(bytes: Self.stateBytes)
        let challenge = BackendCloudAccountIdentity.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        flow = .init(verifier: verifier, state: state, callback: callback, expires: clock() + 300_000)
        var url = URLComponents(url: configuration.websiteStartURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "challenge", value: challenge), .init(name: "state", value: state),
                          .init(name: "callback", value: callback.pathToken), .init(name: "platform", value: platform),
                          .init(name: "device", value: Self.startDeviceLabel(configuration.deviceLabel))]
        if let provider { url.queryItems?.append(.init(name: "provider", value: provider)) }
        if !current.visible(at: 0) { publish(.init(phase: .signingIn, gate: .closed)) }
        return url.url!
    }
    /// The optional `device=<label ≤64>` of the website's start request (gap 2): the same label the device registration
    /// sends, cut to 64 characters (UTF-16, as the website counts), nothing else added.
    nonisolated static func startDeviceLabel(_ label: String) -> String {
        var cut = String(label.prefix(64))
        while cut.utf16.count > 64 { cut.removeLast() }
        return cut
    }
    /// Is a sign-in that THIS app started still waiting for its return?
    public func hasPendingSignIn() -> Bool { flow.map { $0.expires > clock() } ?? false }
    /// The return link `terminaldeck://cloud/return/<token>?code&state`. Finished only when token AND state are those
    /// of the pending app sign-in, within its lifetime, and only once (the flow is consumed before anything is
    /// awaited). Anything else returns false and changes nothing: no state, no notice, no request.
    public func finishAppReturn(token: String, code: String, state: String) async throws -> Bool {
        guard let pending = flow, pending.callback.isApp, pending.expires > clock(),
              Self.same(pending.callback.pathToken, token), Self.same(pending.state, state),
              !code.isEmpty, code.count <= 256 else { return false }
        // Consumed here, before anything is awaited: a second copy of the same link finds nothing to answer.
        flow = nil
        stage = ""; lastFinishFailure = nil
        await reach("return to app")
        try await finish(pending, code: code)
        return true
    }
    /// Compares without stopping at the first different character.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
    /// The state the app issued for its own pending sign-in, so a link that answers it is recognised (N5).
    public func pendingSignInState() -> String? { flow.flatMap { $0.expires > clock() ? $0.state : nil } }
    /// A link-started attempt that produced no session leaves nothing behind (finding 3a, 23).
    public func abandonSignIn() async {
        flow = nil
        guard (try? await identity.existing()) == nil else { return }
        publish(.signedOut)
        await sessionHook?(.signedOut)
    }
    public func finishSignIn(code: String, state: String, callback: CloudHandoffCallback) async throws {
        stage = ""; lastFinishFailure = nil
        await reach("return to app")
        guard let flow, flow.expires > clock(), flow.state == state, flow.callback == callback, !code.isEmpty else {
            lastFinishFailure = stage; await stageLog?("cloud sign-in: \(stage) failed: \(flow == nil ? "no pending sign-in" : "sign-in does not match")")
            throw CloudFailure.invalidRequest
        }
        self.flow = nil
        try await finish(flow, code: code)
    }
    private func finish(_ flow: Flow, code: String) async throws {
        let callback = flow.callback
        let version = generation
        do {
            await reach("code exchange")
            let exchange = CloudHandoffExchange(code: code, verifier: flow.verifier, callback: callback)
            let response = try await http.send(.init(url: configuration.baseURL.appendingPathComponent("auth/exchange"), method: "POST",
                headers: ["content-type": "application/json"], body: CloudWire.canonical(exchange)))
            let session = try response.decoded(CloudAuthSession.self)
            guard generation == version else { throw CancellationError() }
            await reach("account check")
            // A different website account never replaces the one saved here; the person signs out first (finding 3c).
            if let saved = try await identity.existing(), saved.user.id != session.user.id { throw CloudFailure.idReused }
            guard generation == version else {
                // The server already issued this session; a sign-in this Mac abandoned meanwhile ends it there too (N4).
                await logout(accessToken: session.accessToken)
                throw CancellationError()
            }
            await reach("save sign-in")
            try await identity.install(session)
            do {
                await reach("device keys")
                let registration = try await identity.deviceRegistration()
                await reach("Cloud connection")
                let bound = try await ports()
                await reach("device registration")
                let receipt = try await register(registration, subject: session.user.id, on: bound.transport)
                guard generation == version else { throw CancellationError() }
                guard receipt.deviceId == registration.deviceId, receipt.status == .active else { throw CloudFailure.deviceRevoked }
                await reach("Cloud status")
                refreshStage = ""
                try await refresh()
                await reach("")
            } catch {
                let failed = refreshStage.isEmpty || stage != "Cloud status" ? stage : stage + " (" + refreshStage + ")"
                lastFinishFailure = failed
                await stageLog?("cloud sign-in: \(failed) failed: \(Self.kind(error))")
                // A half-finished sign-in keeps no session (finding 24): the next launch is a no-account launch.
                try? await identity.clear()
                await sessionHook?(.signedOut)
                throw error
            }
            // Signed in, but the server does not allow Cloud for this account: kept, dormant, and the person is told (N7).
            guard current.phase != .dormant else { await stageLog?("cloud sign-in: finished, Cloud not allowed"); throw CloudFailure.gateClosed }
            await stageLog?("cloud sign-in: finished")
        } catch {
            if lastFinishFailure == nil, !stage.isEmpty {
                lastFinishFailure = stage
                await stageLog?("cloud sign-in: \(stage) failed: \(Self.kind(error))")
            }
            guard generation == version else { throw CancellationError() }
            if current.phase != .dormant { publish(.init(phase: .needsSignIn, gate: .closed, problem: "Could not sign in. Try again.")) }
            throw error
        }
    }
    public func resume() async throws {
        Task { await self.sendLeaveNotes() }
        // No saved session (for example a data folder copied from another device) behaves exactly like signed out (finding 1).
        guard let saved = try await identity.existing() else { publish(.signedOut); await sessionHook?(.signedOut); return }
        // 13 Nov: the saved sign-in's name goes with it, so the page says "signed in" while Cloud is being reached.
        if current.phase == .signedOut { publish(.init(phase: .needsSignIn, gate: .closed, displayName: saved.user.displayName)) }
        try await refresh()
    }
    /// Which step of the last status read was running (for the sign-in's stage line); no secret, no payload.
    private var refreshStage = ""
    public func refresh() async throws {
        let version = generation
        var signedInAs: String?
        do {
            refreshStage = "saved sign-in"
            let session = try await identity.credentials()
            signedInAs = session.user.displayName
            refreshStage = "connection"
            let bound = try await ports()
            refreshStage = "status"
            let remote = try await bound.transport.state()
            guard generation == version else { throw CancellationError() }
            // Status-line lane: the room left in the account, as the service counts it (space used per kind).
            storageBytesLeft = remote.budget.bytesLeft
            // G4: only these two shapes are an answer. OPEN: a successful state with "cloud" in features AND
            // storageEntitled == true. CLOSED: a successful state WITHOUT "cloud", or with storageEntitled == false.
            // Anything else (an error status, an undecodable body, "cloud" with no entitlement value) is NO ANSWER.
            let capabilities = remote.capabilities
            guard !capabilities.features.contains("cloud") || capabilities.storageEntitled != nil else { throw CloudFailure.unavailable }
            checkedAt = monotonic(); failures = 0; retrying?.cancel(); retrying = nil
            triedFreshToken = false; triedReRegistration = false; triedClock = false
            // The answer's own time is not compared with this Mac's clock (N3a); the published gate carries none.
            let gate = CloudGate(features: remote.capabilities.features, storageEntitled: remote.capabilities.storageEntitled,
                aiSubscriptionsEnabled: remote.capabilities.aiSubscriptionsEnabled, revision: remote.capabilities.revision, expiresAt: nil)
            guard gate.entitlesCloud else {
                // An explicit "not allowed": DORMANT. Nothing runs; the saved sign-in is kept (N3b).
                try? await bound.outbox.setPaused(true); await bound.transport.stop(); await bound.seal(); lastPorts = nil
                background?.cancel(); background = nil
                publish(.init(phase: .dormant, gate: .closed, displayName: session.user.displayName, problem: "Cloud is not available for this account."))
                await sessionHook?(.dormant)
                return
            }
            refreshStage = "devices"
            let devices = try await bound.transport.devices()
            refreshStage = "sync start"
            let progress = try await bound.outbox.restoreProgress()
            guard generation == version else { throw CancellationError() }
            try await bound.outbox.setPaused(userPaused)
            // What waits for trust and what was refused, as the sync core holds them. Waiting packs are no gap.
            let held = (try? await bound.outbox.heldDevices()) ?? []
            let refused = (try? await bound.outbox.refusedPacks()) ?? []
            let refusedBeyond = (try? await bound.outbox.refusedBeyondList()) ?? 0
            // This Mac's first save can take a while; the page shows how far it is, never a spinner.
            let baseline = try? await bound.outbox.baselineProgress()
            refreshStage = "trusted devices"
            let (rows, trustNotice) = await trustRows(bound, devices: devices.devices, held: held)
            guard generation == version else { throw CancellationError() }
            let wasOpen = current.visible(at: 0)
            // `remote.headSeq` is the newest position of the feed, `progress.brainSeq` how far this Mac has read it:
            // the page says from the two whether this Mac is level with the Cloud or catching up.
            publish(.init(phase: userPaused ? .paused : .signedIn, gate: gate, displayName: session.user.displayName, devices: devices.devices,
                          coverage: progress.coverage, waitingRecords: progress.queued, blockedRecords: progress.blocked, trust: rows,
                          heldChanges: held.reduce(0) { $0 + $1.operations }, refusedPacks: refused.count + refusedBeyond, trustNotice: trustNotice, baseline: baseline,
                          cloudHead: [remote.headSeq, devices.headSeq].compactMap { $0 }.max(), fetched: progress.brainSeq))
            if !wasOpen { await sessionHook?(.signedIn) }
            startBackgroundCheck()
            describeSelfOnce(bound, subject: session.user.id, listed: devices.devices)
        } catch {
            guard generation == version else { throw CancellationError() }
            if let failure = error as? CloudFailure, failure == .gateClosed, (try? await identity.existing()) == nil {
                publish(.signedOut); throw error   // no saved session any more (signed out meanwhile)
            }
            // Cloud's own answers (spec §4.1; worker auth.ts gate()): 401 sign_in_required / token_expired means the
            // session or token is not accepted. First refresh the token once and ask again; a repeat is no answer (MAC-NEXT-12).
            if let failure = error as? CloudFailure, case .remote(let detail) = failure, ["sign_in_required", "token_expired"].contains(detail.code) {
                if !triedFreshToken {
                    triedFreshToken = true
                    do { _ = try await identity.credentials(force: true) } catch {
                        // The Store's refusal is not Cloud saying "this device was removed": the sign-in ends as
                        // before, and this Mac's Cloud keys are NEVER touched (lost-device rule, review 15 Nov).
                        if Self.sessionRefused(error) { try? await clearSignIn() }
                        else {
                            // Round 5 (A1): the fresh token could not even be asked for (no network). That is "no
                            // answer", and no fresh token has been tried yet: the next refusal must try one again
                            // instead of signing this Mac out.
                            triedFreshToken = false
                            noAnswer(problem: "Could not reach Cloud. Your local work is kept; Cloud tries again.")
                        }
                        throw error
                    }
                    return try await refresh()
                }
                // MAC-NEXT-12 (13 Nov): the Store has just issued a fresh token for this session, so the session
                // exists; Cloud refusing it again is Cloud not able to check it (its database was busy: a 401 came
                // from a td-store export), never a revocation. The sign-in is kept and checked again on the timer,
                // with a fresh token. Only the Store's own refusal (sessionRefused) or device_revoked signs out.
                triedFreshToken = false
                noAnswer(problem: "Could not reach Cloud. Your local work is kept; Cloud tries again.")
                throw error
            }
            // 400 clock_skew (lane C b7cbfb49, carries serverTime): the sync transport corrects its signing time from the
            // answer; ask once more. A repeat is "no answer" with a date-and-time message, never a sign-out (round 5).
            if let failure = error as? CloudFailure, case .remote(let detail) = failure, detail.code == "clock_skew" {
                if !triedClock { triedClock = true; return try await refresh() }
                noAnswer(problem: Self.clockProblem); throw error
            }
            // 401 bad_device_proof: register the device once more with its current keys and ask again. A repeat is "no
            // answer" with the same message, never a sign-out that clears the session and device keys; a really removed
            // device is told by 403 device_revoked, handled as a refused session (round 5).
            if let failure = error as? CloudFailure, case .remote(let detail) = failure, detail.code == "bad_device_proof" {
                if !triedReRegistration {
                    triedReRegistration = true
                    let registration = try await identity.deviceRegistration()
                    let receipt = try await ports().transport.registerDevice(registration)
                    guard receipt.deviceId == registration.deviceId else { noAnswer(problem: Self.clockProblem); throw error }
                    // Review 15 Nov finding 4: "revoked" here says nothing about WHO ended it: the sign-in ends as
                    // before, and this Mac's Cloud keys are never removed on this answer.
                    if receipt.status == .revoked { try? await clearSignIn(); throw CloudFailure.deviceRevoked }
                    return try await refresh()
                }
                noAnswer(problem: Self.clockProblem); throw error
            }
            if Self.sessionRefused(error) {
                // The server says the session itself is invalid or revoked: only then is the sign-in cleared (N3b).
                // Only Cloud's explicit device_revoked, seen again on a second call of its own transport, also removes
                // this Mac's Cloud keys; every other refusal leaves them (lost-device rule, review 15 Nov).
                let revoked = await revokedByCloud(error)
                try? await clearSignIn(revokedBy: revoked)
                throw error
            }
            // No answer (offline, timeout, server busy): nothing closes and sending is never paused here (N2).
            failures += 1
            // 13 Nov: a "wait" answer (slow down) is said as such, with the time of the
            // next try; the saved sign-in is kept and named, so the page never looks signed out for it.
            let problem = Self.waitAnswer(error)
                ? Self.waitProblem(at: Date().addingTimeInterval(TimeInterval(Self.retrySeconds(failures))))
                : "Could not reach Cloud. Your local work is kept; Cloud tries again."
            publish(current.carried(phase: current.phase == .signedOut ? .needsSignIn : current.phase, problem: problem).named(signedInAs))
            scheduleRetry()
            throw error
        }
    }
    public func sync(action: String) async throws {
        guard current.visible(at: 0) else { throw CloudFailure.gateClosed }
        let bound = try await ports()
        switch action {
        // Proof 3 (13 Nov): a Pause press did not show on one Mac. The page now says it at once, and a status read that
        // cannot finish afterwards (the service, a busy sync core) no longer undoes what the press already did.
        case "pause", "resume":
            let pause = action == "pause", before = current.phase
            userPaused = pause; publish(current.carried(phase: pause ? .paused : .signedIn, problem: current.problem))
            do { try await bound.outbox.setPaused(pause) } catch {
                userPaused = !pause
                if [.signedIn, .paused].contains(current.phase) { publish(current.carried(phase: before, problem: current.problem)) }
                throw error
            }
            try? await refresh(); return
        case "retry": _ = try await bound.outbox.flush()
        // "Sync now": fetch what Cloud holds, then send what this Mac holds. The same two steps the sync core takes
        // by itself at start, on waking and when the network returns; this only makes them happen at once. A fetch
        // that cannot run this moment (the core is busy with one) is not an error; a failed send is.
        // Status-line lane (14 Nov): a press while a pass runs (twice, or a press and a tool) joins that pass; one
        // pass, one status read, never two.
        case "now":
            try await syncNowGate.run { [weak self] in
                try await bound.outbox.syncNow()
                try await self?.refresh()
            }
            return
        // "Check again": every refused pack is read and judged afresh under this Mac's trusted list. It can only
        // use what a trusted device really signed; it gives no trust.
        case "check": _ = try await bound.outbox.checkRefusedAgain(sequence: nil)
        default: throw CloudFailure.invalidRequest
        }
        try await refresh()
    }
    /// The Devices section: the service's list seen through this Mac's trusted list. This Mac's own identity joins
    /// its list here, at sign-in and at every later start (design 2.3, `how: self`); nothing else is ever added here.
    private func trustRows(_ bound: BackendCloudAccountPorts, devices: [CloudDevice], held: [CloudHeldDevice]) async -> (rows: [CloudDeviceTrustRow], notice: String?) {
        guard let trust = bound.trust else { return ([], nil) }
        let registration = try? await identity.deviceRegistration()
        // Security review M2: nothing is swallowed here. A list that cannot be read, or that would not take this
        // Mac's own identity, is said on the page, and then no device can be trusted from a sheet.
        var list: BackendCloudTrustedList?
        var notice: String?
        // MAC-NEXT-11: when this Mac first met something NEW a device signed (a held or a refused pack): the only proof
        // that lets an entry settled as an earlier one come back.
        var alive: [String: Int64] = [:]
        for device in held { alive[device.deviceId] = max(alive[device.deviceId] ?? 0, device.firstSeenAt) }
        for pack in (try? await bound.outbox.refusedPacks()) ?? [] {
            if let id = pack.deviceId { alive[id] = max(alive[id] ?? 0, pack.firstAt) }
        }
        do {
            if let registration { try await trust.addSelf(registration) }
            // Two-Mac proof (13 Nov): a device the service reports as removed leaves this Mac's trusted list (it is kept
            // there as stopped, so it never comes back by itself) and is no longer shown.
            let removed = Set(devices.filter { $0.status == .revoked }.map(\.deviceId))
            if !removed.isEmpty {
                let stopped = try await trust.stopRemovedByAccount(removed, thisDeviceId: registration?.deviceId)
                if !stopped.isEmpty { await stageLog?("cloud devices: \(stopped.count) removed from the account, no longer trusted here") }
            }
            // 15 Nov (passwords in the browser): browsers removed 30 days ago leave the list (only takes away).
            if let pruned = try? await trust.pruneRemovedBrowsers(), !pruned.isEmpty {
                await stageLog?("cloud devices: \(pruned.count) removed browsers dropped from this Mac's list")
            }
            // 13 Nov leftover: earlier entries of a device that signed in again (this Mac's own included) are never
            // trusted, in either trust mode; the page already does not show them.
            var activeKeys: [String: String] = [:]
            for device in devices where device.status == .active { activeKeys[device.deviceId] = BackendCloudDeviceCode.keyId(device.signPublicJwk) }
            let stale = BackendCloudTrustRows.stale(devices: devices, thisDeviceId: registration?.deviceId, now: clock())
            let settled = try await trust.settleStale(stale, activeKeys: activeKeys, thisDeviceId: registration?.deviceId,
                                                      alive: alive, automatic: trustMode == .account)
            if !settled.stopped.isEmpty { await stageLog?("cloud devices: \(settled.stopped.count) earlier entries of a device that signed in again, no longer trusted here") }
            if !settled.restored.isEmpty { await stageLog?("cloud devices: \(settled.restored.count) earlier entries signed something new, trusted again with their stored key") }
            list = try await trust.list()
        } catch let refusal as BackendCloudTrustRefusal {
            notice = refusal == .unreadable || refusal == .notSaved ? Self.listUnreadable : refusal.words
        } catch { notice = Self.listUnreadable }
        if notice == nil, let trustAlarm { notice = trustAlarm }
        // This Mac's own row comes from the key this Mac holds, never from the key the service lists under its id.
        if notice == nil, BackendCloudTrustRows.serviceShowsAnotherKeyForThisMac(devices: devices, thisDeviceId: registration?.deviceId, thisKey: registration?.signPublicJwk) {
            notice = trustMode == .ask ? Self.anotherKeyForThisMac : Self.anotherKeyForThisMacPlain
        }
        var waiting: [String: Int] = [:]
        for device in held { waiting[device.deviceId, default: 0] += device.operations }
        let automatic = trustMode == .account
        let now = clock()
        var rows = BackendCloudTrustRows.build(devices: devices, list: list, thisDeviceId: registration?.deviceId,
                                               thisKey: registration?.signPublicJwk, listReadable: list != nil, waiting: waiting,
                                               markKeyChanges: automatic, now: now, alive: alive)
        // PASSWORDS-2 review blocker 1: entries stored before the kind of device was kept get it once, only from a row
        // that reports the very key stored here. In either trust mode; it trusts nothing new.
        if notice == nil, list != nil {
            // Gap 1 (14 Nov): the one-time filling is said with its count (no ids).
            if let filled = try? await trust.notePlatforms(rows), !filled.isEmpty {
                await stageLog?(CloudSecretsLog.line("kind of device filled once for \(filled.count) devices on this Mac's list"))
            }
        }
        // Automatic trust (owner, 13 Nov): every device the account lists that this Mac has never listed joins this
        // Mac's list with the key the service reports. Only with a readable list and no alarm about this Mac itself.
        if automatic, notice == nil, list != nil {
            do {
                let added = try await trust.trustByAccount(rows)
                if !added.isEmpty {
                    await stageLog?("cloud sign-in: device trust ok: \(added.count) added")
                    // The sync core releases their waiting changes in their original order (as after a Trust press).
                    _ = try? await bound.outbox.releaseHeld(deviceIds: added)
                    waiting = [:]
                    for device in (try? await bound.outbox.heldDevices()) ?? held { waiting[device.deviceId, default: 0] += device.operations }
                    list = try await trust.list()
                    rows = BackendCloudTrustRows.build(devices: devices, list: list, thisDeviceId: registration?.deviceId,
                                                       thisKey: registration?.signPublicJwk, listReadable: true, waiting: waiting, markKeyChanges: true,
                                                       now: now, alive: alive)
                }
            } catch {
                await stageLog?("cloud sign-in: device trust failed: \(Self.kind(error))")
                notice = (error as? BackendCloudTrustRefusal)?.words ?? Self.listUnreadable
            }
        }
        return (rows, notice)
    }
    /// Set when the sync core found another key on this Mac's list than the one a press had just stored (see
    /// `trustDevices`). Cleared only with the sign-in.
    private var trustAlarm: String?
    static let listNotAsCompared = "This Mac's list of trusted devices was not what you had just compared when it was checked. Compare the code of every device again, on that device, before you rely on it."
    static let listUnreadable = "This Mac cannot read its list of trusted devices; changes from other devices are waiting."
    /// "Ask me for each new device" speaks of codes (the person compares them there); "Automatically, with my
    /// account" never shows a code, so its words say the same without one (owner, 13 Nov).
    static let anotherKeyForThisMac = "Cloud lists a different key for this Mac than the one this Mac holds. Compare codes only with the code this Mac shows here."
    static let anotherKeyForThisMacPlain = "Cloud does not list this Mac the way this Mac knows itself, so your other devices may not take its changes. Sign out and in again if this stays."
    /// The Trust press, from a sheet in this Mac's own window and from nowhere else: no tool action, RPC channel or
    /// settings key reaches this. `captured` is what the sheet showed when it was drawn; that key is the one stored
    /// (R1). The device list read here can only cancel the press. `restore` marks the new-Mac sheet.
    /// Package-level (security review S13): only this package's own window code can name it; no other module can.
    package func trustDevices(_ captured: [BackendCloudTrustCapture], restore: Bool = false) async throws {
        guard current.visible(at: 0) else { throw CloudFailure.gateClosed }
        let bound = try await ports()
        guard let trust = bound.trust else { throw CloudFailure.unavailable }
        // R3 first, while "just now" still means the press: the device list below may take seconds to answer.
        try await trust.requirePress()
        var latest: [CloudDeviceTrustRow]?
        if let fresh = try? await bound.transport.devices() {
            let list = try? await trust.list()
            latest = BackendCloudTrustRows.build(devices: fresh.devices, list: list, thisDeviceId: nil)
        }
        try await trust.trust(captured, restore: restore, latest: latest)
        // Only now, with the entry stored, is the sync core told: it releases the device's waiting packs in their
        // original order, as late arrivals, before it applies anything newer from that device (R6). The key handed
        // over is the captured one. If the core is busy or the call fails, the release starts by itself at the next
        // pull; the trust is stored either way.
        if captured.count == 1, let one = captured.first {
            // Sync trust review S8: `versionChanged` here means this Mac's list did not hold exactly the key the
            // person compared when the sync core asked it. The sync core releases by whatever the LIST holds, so
            // this is an alarm about the list, never proof that nothing was released: it is said on the page and
            // stays there for this run.
            do { _ = try await bound.outbox.trustDevice(deviceId: one.deviceId, signKey: one.signKey) }
            catch CloudFailure.versionChanged { trustAlarm = Self.listNotAsCompared }
            catch {}
        } else {
            _ = try? await bound.outbox.releaseHeld(deviceIds: captured.map { $0.deviceId })
        }
        try? await refresh()
    }
    /// "Remove" on the notice of a device that joined by itself (automatic mode): this Mac stops taking its changes
    /// and never adds it again by itself. A press in this Mac's window only (package-level, like `trustDevices`).
    package func stopTrusting(deviceId: String) async throws {
        guard current.visible(at: 0) else { throw CloudFailure.gateClosed }
        let bound = try await ports()
        guard let trust = bound.trust else { throw CloudFailure.unavailable }
        try await trust.requirePress()
        try await trust.stopTrusting(deviceId: deviceId)
        // The same device loses reach too (while reach is on); a failure there is said, the trust change stays.
        var reachFailure: (any Error)?
        if let reachLink { do { try await reachLink(deviceId) } catch { reachFailure = error } }
        try? await refresh()
        if reachFailure != nil { throw BackendReachLinkFailure() }
    }
    /// "Sign out this device" (Settings → Devices and `devices.remove`, 14 Nov): the Cloud revokes that device and
    /// deletes its sign-in session (`POST /devices/remove`, sent with the vault version read now; one fresh read when
    /// the version moved meanwhile). The device then leaves every device's list, and signing in on it again brings it
    /// back under a new id by itself. Refused, nothing changed: this Mac's own id, a device holding the saved-passwords
    /// key. "not_found" (DEVICE-SIGNOUT-2, security): judged by the account's device list read now: still listed as
    /// active is a failure (thrown); listed revoked is `alreadyGone`; not listed at all is `notAnAccountDevice` (a
    /// browser's reach key; the caller's reach removal is then the sign-out). Not a trust press: the row's 5-second
    /// Undo is its protection, the tool's approval is the tool's. An account without Cloud (dormant here: reach only)
    /// may still call this route but not read `/state`, and the service's version_changed refusal does not carry the
    /// version (common.ts Fault body: code only). It sends the unset "0"; when the account has saved passwords that is
    /// refused with nothing changed, and the refusal is thrown at once (no re-read: the caller says "Could not sign it out").
    @discardableResult
    public func signOutDevice(_ deviceId: String) async throws -> BackendDeviceSignOutOutcome {
        guard [.signedIn, .paused, .dormant].contains(current.phase) else { throw BackendDeviceSignOutRefusal.notSignedIn }
        let bound = try await ports()
        guard let remover = bound.transport as? any BackendCloudDeviceSignOut else { throw BackendDeviceSignOutRefusal.notSignedIn }
        let mine = try await identity.deviceRegistration().deviceId
        guard !deviceId.isEmpty, deviceId != mine else { throw BackendDeviceSignOutRefusal.thisMac }
        let dormant = current.phase == .dormant
        var retried = dormant
        var outcome = BackendDeviceSignOutOutcome.signedOut
        while true {
            let version = dormant ? CloudSequence.zero : try await bound.transport.state().vaultVersion
            do {
                try await remover.removeDevice(deviceId: deviceId, expectedVaultVersion: version)
                if let counted = remover as? any BackendCloudDeviceSignOutBrowsers, await counted.browsersEndedByLastRemoval() > 0 {
                    outcome = .signedOutBrowsersEnded
                }
                break
            } catch CloudFailure.remote(let detail) where detail.code == "rotation_required" {
                throw BackendDeviceSignOutRefusal.holdsSavedPasswordsKey
            } catch CloudFailure.remote(let detail) where detail.code == "version_changed" && !retried {
                retried = true
            } catch let failure as CloudFailure where Self.notFound(failure) {
                let listed = try await bound.transport.devices().devices.filter { $0.deviceId == deviceId }
                if listed.contains(where: { $0.status == .active }) { throw failure }
                outcome = listed.isEmpty ? .notAnAccountDevice : .alreadyGone
                break
            }
        }
        await stageLog?(outcome == .notAnAccountDevice ? "cloud: sign-out of a device the Cloud does not list; reach's removal decides"
                                                       : "cloud: another device of the account signed out from this Mac")
        try? await refresh()
        return outcome
    }
    /// A device's page "Name": `POST /devices/rename` (see `CloudDeviceRename`), then the device list is read again
    /// so every page shows the new name. Throws when the Cloud did not say ok (nothing changed).
    public func renameDevice(_ deviceId: String, name: String) async throws {
        guard [.signedIn, .paused, .dormant].contains(current.phase) else { throw BackendDeviceSignOutRefusal.notSignedIn }
        let bound = try await ports()
        guard let renamer = bound.transport as? any BackendCloudDeviceRename else { throw BackendDeviceSignOutRefusal.notSignedIn }
        try await renamer.renameDevice(deviceId: deviceId, name: name)
        try? await refresh()
    }
    nonisolated static func notFound(_ failure: CloudFailure) -> Bool {
        if case .remote(let detail) = failure { return detail.code == "not_found" }
        return false
    }
    /// "Remove" in Settings › Cloud › Reach: this Mac also stops taking that device's changes (and never trusts it
    /// again by itself). Nothing when Cloud is not open here. Does not call the reach link back.
    package func stopTrustingForReachRemoval(deviceId: String) async throws {
        guard current.visible(at: 0), let bound = try? await ports(), let trust = bound.trust else { return }
        let row = current.trust.first { $0.deviceId == deviceId }
        guard try await trust.stopForReachRemoval(deviceId: deviceId, row: row) else { return }
        try? await refresh()
    }
    /// The one button for a device whose reported key changed (automatic mode). `row` is the row as the page drew it
    /// (R1); a device list read now can only cancel the press. Its waiting and refused changes are then judged again.
    package func trustChangedKey(_ row: CloudDeviceTrustRow) async throws {
        guard current.visible(at: 0) else { throw CloudFailure.gateClosed }
        let bound = try await ports()
        guard let trust = bound.trust else { throw CloudFailure.unavailable }
        try await trust.requirePress()
        if let fresh = try? await bound.transport.devices().devices {
            guard let now = fresh.first(where: { $0.deviceId == row.deviceId }), now.status == .active,
                  BackendCloudDeviceCode.keyId(now.signPublicJwk) == row.keyId else { throw BackendCloudTrustRefusal.listChanged }
        }
        try await trust.trustChangedKey(row)
        if let key = row.signKey { _ = try? await bound.outbox.trustDevice(deviceId: row.deviceId, signKey: key) }
        _ = try? await bound.outbox.checkRefusedAgain(sequence: nil)
        try? await refresh()
    }
    /// R5 (device trust review, round 2), as corrected by the security review (M3, S17): signing out of the LAST Mac
    /// that can open the saved passwords. Decided from what THIS MAC holds, not from the service's word: if this Mac
    /// holds a saved-passwords key, sign-out first requires that the recovery words were confirmed and then warns in
    /// this Mac's window, UNLESS a device list read fresh at this very press proves that another active device is
    /// approved. A list that cannot be read proves nothing. Where saved passwords are not wired (no key can be held)
    /// sign-out simply works. The page and the `cloud.signout` tool both come here.
    public func signOut() async throws {
        if await isLastMacForSavedPasswords() {
            // "Not confirmed" and "could not be asked" are different things to tell the person: the first leads to
            // Saved passwords on the Cloud page, the second only to trying again when Cloud answers.
            let confirmed: Bool
            do { confirmed = try await recoveryWordsConfirmed?() ?? false }
            catch { throw BackendCloudSignOutRefusal.recoveryWordsNotChecked }
            guard confirmed else { throw BackendCloudSignOutRefusal.recoveryWordsNotConfirmed }
            guard let lastSignOutWarning, await lastSignOutWarning() else { throw CancellationError() }
        }
        // Proof 2 (13 Nov): when the removal did not reach Cloud, a note signed by this device's key is kept and sent
        // at the next chance (now, at launch, when the network returns), so the other Macs stop trusting this one.
        let note = await removeThisDevice() ? nil : (try? await identity.leaveNote()) ?? nil
        try await clearSignIn(leaving: note)
        await stageLog?("cloud sign-out: done; this Mac's work stays here")
        if note != nil { await sendLeaveNotes() }
    }
    /// Sends the leave notes this Mac still holds (proof 2). Taken, or the device is already gone: forgotten. A note
    /// Cloud calls wrong (its signature or shape) can never be taken: forgotten too. Otherwise kept for next time.
    public func sendLeaveNotes() async {
        guard let notes = try? await identity.leaveNotes(), !notes.isEmpty else { return }
        for note in notes {
            guard let body = try? CloudWire.canonical(note) else { continue }
            let request = BackendCloudAccountRequest(url: configuration.baseURL.appendingPathComponent("devices/leave"), method: "POST",
                                                     headers: ["content-type": "application/json"], body: body)
            guard let answer = try? await http.send(request) else { await stageLog?("cloud sign-out: leave note kept; Cloud did not answer"); continue }
            let code = (try? CloudWire.decode(CloudValue.self, from: answer.body))?.raw["error"]["code"].string
            if (200...299).contains(answer.status) || answer.status == 404 || ["bad_device_proof", "invalid_request"].contains(code ?? "") {
                try? await identity.dropLeaveNote(deviceId: note.deviceId)
                await stageLog?((200...299).contains(answer.status) ? "cloud sign-out: leave note taken; the old device is removed" : "cloud sign-out: leave note dropped (\(code ?? String(answer.status)))")
            } else {
                await stageLog?("cloud sign-out: leave note kept (\(code ?? String(answer.status)))")
            }
        }
    }
    /// Two-Mac proof (13 Nov): sign-out left this Mac's entry in the account, so after signing in again the Mac listed
    /// itself twice. The person's sign-out first asks the service to remove THIS device (its key is dropped with the
    /// saved sign-in right after). Bounded to a few seconds; a failure (offline, a device that holds the saved-
    /// passwords key) is one log line and the sign-out goes on: the other Macs then tell the old entry apart as stale.
    /// True when Cloud took the removal (or nothing can be removed here: no transport that can).
    private func removeThisDevice() async -> Bool {
        guard current.phase != .signedOut, let bound = lastPorts, let remover = bound.transport as? any BackendCloudDeviceSelfRemoval else { return true }
        // Status reads still under way end quietly instead of reading a device that is about to be removed.
        generation += 1
        do {
            try await Self.within(seconds: 8) {
                // Proof 2: the version is only a courtesy now; a Mac whose saved passwords are locked still leaves.
                let version = try? await bound.transport.state().vaultVersion
                try await remover.removeOwnDevice(expectedVaultVersion: version)
            }
            await stageLog?("cloud sign-out: this device removed from the account")
            return true
        } catch {
            await stageLog?("cloud sign-out: device removal failed: \(Self.kind(error)); a signed leave note is kept and sent when Cloud answers")
            return false
        }
    }
    /// Runs `work`, or throws `CloudFailure.unavailable` once `seconds` have passed.
    static func within(seconds: Int, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await work(); return true }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return false }
            defer { group.cancelAll() }
            guard let first = try await group.next(), first else { throw CloudFailure.unavailable }
        }
    }
    private var recoveryWordsConfirmed: (@Sendable () async throws -> Bool)?
    private var savedPasswordsKeyHeld: (@Sendable () async -> Bool)?
    private var lastSignOutWarning: (@Sendable () async -> Bool)?
    /// Saved passwords' own answer to "were the recovery words confirmed?" (lane V's status).
    public func setRecoveryWordsConfirmed(_ check: @escaping @Sendable () async throws -> Bool) { recoveryWordsConfirmed = check }
    /// Does this Mac hold a saved-passwords key for the signed-in identity right now? Lane V's own state. Without
    /// this hook saved passwords are not wired, nothing can be lost by signing out, and no guard applies.
    public func setSavedPasswordsKeyHeld(_ check: @escaping @Sendable () async -> Bool) { savedPasswordsKeyHeld = check }
    /// The native warning for the last Mac; true only on the person's press of "Sign out".
    public func setLastSignOutWarning(_ warn: @escaping @Sendable () async -> Bool) { lastSignOutWarning = warn }
    private func isLastMacForSavedPasswords() async -> Bool {
        guard current.phase != .signedOut, let savedPasswordsKeyHeld, await savedPasswordsKeyHeld() else { return false }
        // Only a list read NOW, with this Mac's own id known, can show that another Mac still holds the way in.
        guard let mine = try? await identity.deviceRegistration().deviceId,
              let fresh = try? await lastPorts?.transport.devices().devices else { return true }
        return !BackendCloudSignOutGuard.anotherApprovedDevice(in: fresh, thisDeviceId: mine)
    }
    /// Clears the saved sign-in without asking: used when the server says the session itself is gone, and by the
    /// person's sign-out once the guard above has passed.
    /// Lost-device rule (review 15 Nov): THIS device's Cloud keys go ONLY on Cloud's explicit answer that this device was
    /// revoked by the account: `device_revoked` from the Cloud service itself. It is believed only when it comes back
    /// a second time from a call of the Cloud transport (HTTPS to the configured Cloud address, every request signed by
    /// this device's key), so a token refusal from the Store, a 401 of a deploy in progress, a 403 of another kind, a
    /// 5xx, a timeout, an empty answer or no network never removes anything. nil = not explicit.
    func revokedByCloud(_ error: any Error) async -> CloudErrorDetail? {
        // Review 15 Nov finding 4 (final rule): the service also answers a PLAIN device_revoked (no "removed by") when the
        // sign-in session itself ended or does not match; only the form with `removedAt` (set only for a row another
        // device signed out) counts, and it must come again on the second call.
        guard case .remote(let first)? = error as? CloudFailure, first.code == "device_revoked", let transport = lastPorts?.transport else { return nil }
        do { _ = try await transport.devices(); return nil }
        catch CloudFailure.remote(let again) where again.code == "device_revoked" {
            guard let at = again.removedAt, at > 0, let name = again.removedByName,
                  BackendCloudSignedOutElsewhere.plain(name) != nil else { return nil }
            return again
        }
        catch { return nil }
    }
    /// `revokedBy`: Cloud's explicit answer that another device signed this Mac out (see `revokedByCloud`). The outbox is
    /// paused, never emptied: the changes waiting in it go up after he signs in again. Nothing of his on this Mac is removed.
    private func clearSignIn(leaving note: BackendCloudLeaveNote? = nil, revokedBy detail: CloudErrorDetail? = nil) async throws {
        flow = nil; generation += 1; refreshing?.cancel(); retrying?.cancel(); retrying = nil; checkedAt = nil; failures = 0
        background?.cancel(); background = nil
        trustAlarm = nil
        try? await lastPorts?.outbox.setPaused(true)
        await lastPorts?.transport.stop()
        await lastPorts?.seal()
        lastPorts = nil
        let session = try? await identity.existing()
        var told: BackendCloudSignedOutElsewhere?
        if let detail, detail.code == "device_revoked", let session, let deviceId = try? await identity.deviceRegistration().deviceId {
            let at = detail.removedAt ?? clock()
            let name = detail.removedByName.flatMap { BackendCloudSignedOutElsewhere.plain($0) }
            let value = BackendCloudSignedOutElsewhere(sub: session.user.id, deviceId: deviceId, byName: name, at: at, revoked: true)
            lastSignedOutElsewhere = value; told = value
            await signedOutElsewhereHook?(value)
            await stageLog?("cloud sign-out: signed out from another device; this Mac's Cloud keys go, its work stays here")
        }
        // Close every tool/UI gate before protected-store or network work can fail.
        publish(told.map { CloudAccountSnapshot(phase: .signedOut, gate: .closed, problem: $0.line) } ?? .signedOut)
        await sessionHook?(.signedOut)
        var localFailure: (any Error)?
        do { try await identity.clear(leaving: note) } catch { localFailure = error }
        if let session { await logout(accessToken: session.accessToken) }
        if let localFailure {
            publish(.init(phase: .needsSignIn, gate: .closed, problem: "Could not finish signing out. Try again."))
            throw localFailure
        }
    }

    private func logout(accessToken: String) async {
        var headers = ["Authorization": "Bearer " + accessToken]
        if !configuration.publishableKey.isEmpty { headers["apikey"] = configuration.publishableKey }
        _ = try? await http.send(.init(url: configuration.storeAuthURL.appendingPathComponent("logout"), method: "POST", headers: headers, body: Data()))
    }
    /// The service's lengths (13 Nov, proven on TEST): the loopback callback code is 16 random bytes (22 base64url
    /// characters, `cloud/worker/src/auth.ts` `callback`), the sign-in state 32 bytes (43 characters, the website's
    /// `_flow.js`); the PKCE verifier stays 48 bytes (64 characters, within the service's 43...128).
    public static let callbackCodeBytes = 16, stateBytes = 32, verifierBytes = 48
    public static func random(bytes: Int = verifierBytes) -> String {
        var generator = SystemRandomNumberGenerator()
        return BackendCloudAccountIdentity.base64(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }
}

/// R5: is this Mac the only device left that is approved for saved passwords?
public enum BackendCloudSignOutGuard {
    /// Another ACTIVE device that is approved for saved passwords, in a list read fresh at the press.
    public static func anotherApprovedDevice(in devices: [CloudDevice], thisDeviceId: String) -> Bool {
        devices.contains { $0.deviceId != thisDeviceId && $0.status == .active && $0.secretsApproved }
    }
    public static func isLastApproved(devices: [CloudDevice], thisDeviceId: String) -> Bool {
        guard devices.contains(where: { $0.deviceId == thisDeviceId && $0.status == .active && $0.secretsApproved }) else { return false }
        return !devices.contains { $0.deviceId != thisDeviceId && $0.status == .active && $0.secretsApproved }
    }
}
public enum BackendCloudSignOutRefusal: Error, Equatable, Sendable {
    case recoveryWordsNotConfirmed
    /// Saved passwords could not answer just now (Cloud did not answer).
    case recoveryWordsNotChecked
    public var words: String {
        switch self {
        case .recoveryWordsNotConfirmed:
            return "This is the only Mac that can open your saved passwords, and Cloud has not confirmed that your recovery words are set up. Look at Saved passwords in Settings → Cloud, then sign out again. This Mac stays signed in."
        case .recoveryWordsNotChecked:
            return "This is the only Mac that can open the Cloud copy of your saved passwords, and Cloud could not be asked about it just now. Try again when this Mac is online. This Mac stays signed in."
        }
    }
}
