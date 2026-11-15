import Foundation
import TerminalDeckNativeCore

/// While reach by account is ON for this Mac (switch on, signed in, account holds `reach`), pairing is out of the way
/// (owner, 13 Nov: "we don't have pairing ... at all"): no six-digit code can be made and no view offers one or a
/// folder question. Off (the default), pairing is exactly as before. The pairing code itself stays in place.
public enum BackendReachPairingLock {
    public static let refusal = "This Mac is opened by signing in to your Terminal Deck account. Sign in on the other device instead."
}

/// Passes reach notices to whoever shows them (the app's notice), and keeps none.
public final class BackendReachNoticeRelay: BackendReachNoticeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (BackendReachNotice) -> Void)?
    public init() {}
    public func listen(_ handler: (@Sendable (BackendReachNotice) -> Void)?) { lock.withLock { self.handler = handler } }
    public func post(_ notice: BackendReachNotice) async { let h = lock.withLock { handler }; h?(notice) }
}

/// What the page and `cloud.reach.status` show. No keys, tokens or signatures.
public struct BackendReachStatus: Sendable, Equatable {
    public struct Device: Sendable, Equatable {
        public let deviceId: String
        public let label: String
        public let platform: String
        public let connected: Bool
        public let removed: Bool
        /// When it first reached this Mac (ms), nil = never.
        public let addedAtMs: Double?
        /// When it last opened a session here (ms), nil = never.
        public let lastSeenAtMs: Double?
        public init(deviceId: String, label: String, platform: String, connected: Bool, removed: Bool, addedAtMs: Double?, lastSeenAtMs: Double?) {
            self.deviceId = deviceId; self.label = label; self.platform = platform; self.connected = connected; self.removed = removed
            self.addedAtMs = addedAtMs; self.lastSeenAtMs = lastSeenAtMs
        }
    }
    public init(signedIn: Bool, entitled: Bool?, enabled: Bool, presence: BackendReachPresence.Status, tied: Bool, devices: [Device], recent: [BackendReachAccountGate.Connection]) {
        self.signedIn = signedIn; self.entitled = entitled; self.enabled = enabled; self.presence = presence; self.tied = tied
        self.devices = devices; self.recent = recent
    }
    public let signedIn: Bool
    /// nil = not known yet.
    public let entitled: Bool?
    public let enabled: Bool
    public let presence: BackendReachPresence.Status
    public let tied: Bool
    public let devices: [Device]
    public let recent: [BackendReachAccountGate.Connection]

    public var wireValue: NativeRPCValue {
        .object([.init("signedIn", .bool(signedIn)), .init("entitled", entitled.map(NativeRPCValue.bool) ?? .null),
                 .init("enabled", .bool(enabled)), .init("presence", .string(presence.rawValue)), .init("relayTied", .bool(tied)),
                 .init("newDevices", .string(enabled && signedIn && entitled == true ? "join by signing in" : "not let in")),
                 // Names, dates and states only: no ids, keys or codes (owner, 13 Nov).
                 .init("devices", .array(devices.filter { !$0.removed }.map { d in .object([.init("name", .string(d.label)),
                     .init("addedAt", d.addedAtMs.map(NativeRPCValue.number) ?? .null), .init("lastSeenAt", d.lastSeenAtMs.map(NativeRPCValue.number) ?? .null),
                     .init("connected", .bool(d.connected))]) })),
                 .init("lastConnections", .array(recent.map { r in .object([.init("name", .string(r.label)),
                     .init("at", .number(r.atMs)), .init("result", .string(r.refused.map { "refused: " + $0.rawValue } ?? "opened"))]) }))])
    }
}

/// The page's plain states (Settings › Cloud › Reach, and what the Devices page offers), decided here so they are
/// tested without a window.
public struct BackendReachPage: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Signed out or the account has no `reach`: the Reach part is not shown at all.
        case hidden
        /// Shown with the switch off: today's pairing is untouched.
        case off
        /// On: the account's devices with Remove; pairing out of the way.
        case on
    }
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { deviceId }
        public let deviceId: String
        public let title: String
        public let detail: String
        public let canRemove: Bool
    }
    public let mode: Mode
    public let switchTitle = DevicesPage.settingTitle
    /// Said on the page while reach is on (item 4): one Remove means one thing.
    public static let removeMeans = "Remove does both: the device can no longer reach this Mac, and this Mac stops taking its synced changes."
    public let explanation: String
    public let rows: [Row]
    public let recent: [String]
    /// Whether any view may offer a pairing code (Devices page, its sheet, the empty state).
    public var offersPairing: Bool { mode != .on }
    /// Whether any view may ask which folders or logins a device gets (the pairing walk-through's guest steps).
    public var asksFolders: Bool { mode != .on }

    public init(_ status: BackendReachStatus, now: Double = Date().timeIntervalSince1970 * 1000) {
        guard status.signedIn, status.entitled == true else {
            mode = .hidden; explanation = ""; rows = []; recent = []; return
        }
        mode = status.enabled ? .on : .off
        explanation = status.enabled
            ? DevicesPage.settingOnDetail
            : DevicesPage.settingOffDetail
        // A row says the device's name, when it was added and when it was last seen: nothing else (owner, 13 Nov).
        let formatter = RelativeDateTimeFormatter()
        func ago(_ ms: Double) -> String { formatter.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: Date(timeIntervalSince1970: now / 1000)) }
        func day(_ ms: Double) -> String { Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted) }
        rows = status.devices.filter { !$0.removed }.map { d in
            let added = d.addedAtMs.map { "Added " + day($0) } ?? "Not connected yet"
            let seen = d.connected ? "Connected now" : d.lastSeenAtMs.map { "Last seen " + ago($0) }
            return Row(deviceId: d.deviceId, title: d.label, detail: [added, seen].compactMap { $0 }.joined(separator: " · "), canRemove: true)
        }
        recent = status.recent.prefix(8).map { r in
            let when = ago(r.atMs)
            return "\(r.label) · " + (r.refused == nil ? "opened a session" : "was refused") + " · " + when
        }
    }
}

/// Reach by account on this Mac: one owner for the gate, the door, presence and the cut-offs. Built by the app when
/// the in-app session host runs (the boot helper never builds one, so before the app runs, only paired devices reach
/// this Mac). Nothing here publishes or lets anyone in while the switch is off.
public actor BackendReachAccountCoordinator {
    public let gate: BackendReachAccountGate
    public let presence: BackendReachPresence
    private let service: any BackendReachAccountService
    private let link: BackendReachRelayLink
    private let host: BackendRemoteHost?
    private var ticker: Task<Void, Never>?
    /// This coordinator's hold on the session host's reach judgement (a later coordinator's is never undone by this one).
    private let judgeOwner = UUID()

    public init(directory: URL, service: any BackendReachAccountService, notices: any BackendReachNoticeSink,
                host: BackendRemoteHost?, card: @escaping @Sendable () async -> BackendReachPresence.HostCard?,
                link: BackendReachRelayLink = .shared, inputGuard: BackendRemoteInputGuard = .system,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                steady: @escaping @Sendable () -> Double = BackendReachAccountGate.steadyNowMs) {
        let gate = BackendReachAccountGate(directory: directory, service: service, notices: notices, inputGuard: inputGuard,
                                           now: now, steady: steady)
        self.gate = gate; self.service = service; self.link = link; self.host = host
        self.presence = BackendReachPresence(gate: gate, service: service, relay: link, host: card, now: now)
    }

    /// Wires the door into this process's relay clients and keeps presence fresh every 60 seconds.
    public func start() async {
        // The session host asks the gate again at every account device's hello: a door admission that raced a removal,
        // the switch going off or a sign-out never gets a welcome.
        await host?.setReachJudge(owner: judgeOwner) { [gate] deviceId in await gate.stillAdmitted(deviceId: deviceId) }
        link.setDoor(BackendReachAccountDoor(gate: gate))
        await sync()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    public func stop() async {
        ticker?.cancel(); ticker = nil
        await presence.withdraw()
        // The hello check is off first, as in `signedOut()`: nothing is welcomed while the cut runs.
        await host?.endReachJudge(owner: judgeOwner)
        await cut(nil)
        link.setDoor(nil)
        await host?.trust.setPairingLockedByReach(false)
    }

    /// Presence, the relay room and the pairing lock follow the switch, the sign-in and the entitlement.
    @discardableResult
    public func sync() async -> BackendReachPresence.Status {
        let status = await presence.sync()
        // A passing service failure keeps pairing out of the way while the switch is on and the account entitled.
        var live = status == .published
        if status == .failed, await gate.settings().enabled { live = await gate.entitledNow() == true }
        await host?.trust.setPairingLockedByReach(live)
        if status == .off || status == .signedOut || status == .notEntitled { await cut(nil) }
        else { await rejudge() }
        return status
    }

    /// The switch. On is a trust press (refused within 2 s of remote input); off ends every account channel now.
    public func setEnabled(_ on: Bool, pressedAt: UInt64? = nil) async throws {
        try await gate.setEnabled(on, pressedAt: pressedAt)
        await sync()
    }

    /// One Remove means one thing (item 4, 13 Nov): the app links this Mac's trusted-device list here, so "Remove"
    /// also stops this Mac taking the device's synced changes.
    private var trustLink: (@Sendable (String) async throws -> Void)?
    public func setTrustLink(_ link: (@Sendable (String) async throws -> Void)?) { trustLink = link }

    /// "Remove": refused here at once, its live channels end, this Mac stops trusting it for synced data, and the
    /// service is told (final for that device). A trust failure is thrown after the rest is done.
    public func remove(deviceId: String) async throws {
        try await gate.remove(deviceId: deviceId)
        await cut([deviceId])
        var trustFailure: (any Error)?
        if let trustLink { do { try await trustLink(deviceId) } catch { trustFailure = error } }
        try await service.removeDevice(deviceId)
        await gate.rosterChanged()
        if let trustFailure { throw trustFailure }
    }

    /// "Sign out this device" (DEVICE-SIGNOUT-2, security): this Mac's block first (held in memory when its file
    /// cannot be written), its live channels end, this Mac stops trusting it (best effort), and the service is told.
    /// Throws only when the service was not told: for a browser that removal IS the sign-out, so the caller says so.
    public func signOut(deviceId: String) async throws {
        await gate.removeKeepingInMemory(deviceId: deviceId)
        await cut([deviceId])
        if let trustLink { try? await trustLink(deviceId) }
        try await service.removeDevice(deviceId)
        await gate.rosterChanged()
    }

    /// The other direction: "Remove" on a device trusted by the account (Cloud page) also takes its reach away, but
    /// only while reach's switch is on (off, nobody reaches this Mac by account anyway). Never calls the trust link
    /// back. Returns whether reach was removed.
    @discardableResult
    public func removeIfOn(deviceId: String) async throws -> Bool {
        guard await gate.settings().enabled else { return false }
        try await gate.remove(deviceId: deviceId)
        await cut([deviceId])
        try await service.removeDevice(deviceId)
        await gate.rosterChanged()
        return true
    }

    /// The account's event socket. `devices`: the roster changed; `reachRemoved` ids are cut off at once, then every
    /// live account device is judged again against the fresh list. `gate`: the entitlement changed.
    public func event(type: String, payload: NativeRPCValue) async {
        switch type {
        case "devices":
            // Removed ids first, everything they hold on this Mac at once (relay channel, direct link, streams,
            // its sign-in here), before any network: the roster below may take a while or fail.
            let removed = await gate.devicesRemoved(BackendReachWire.removedIds(payload), version: payload["devicesVersion"].string)
            if !removed.isEmpty { await cut(Set(removed)) }
            _ = await gate.refreshRoster()
            await rejudge()
        case "gate", "hello": await sync()
        default: break
        }
    }

    /// Signed out on this Mac: nothing of reach stays reachable.
    public func signedOut() async {
        await presence.withdraw()
        await host?.endReachJudge(owner: judgeOwner)
        await cut(nil)
        await gate.signedOut()
        await host?.trust.setPairingLockedByReach(false)
    }

    public func status() async -> BackendReachStatus {
        let account = await service.signedInAccount()
        let machine = await service.machineDeviceId()
        let devices = await gate.refreshRoster()?.filter { $0.deviceId != machine } ?? []
        let snapshot = await gate.snapshot(machineDeviceId: machine)
        let connected = await host?.reachConnectedDeviceIds() ?? []
        return .init(signedIn: account != nil, entitled: account == nil ? nil : await gate.entitledNow(),
                     enabled: snapshot.settings.enabled, presence: await presence.last, tied: await link.tied(),
                     devices: devices.map { d in .init(deviceId: d.deviceId, label: d.label, platform: d.platform, connected: connected.contains(d.deviceId),
                                                  removed: d.removed || !d.active || snapshot.removedHere.contains(d.deviceId),
                                                  addedAtMs: snapshot.firstSeen[d.deviceId],
                                                  lastSeenAtMs: snapshot.recent.first { $0.deviceId == d.deviceId && $0.refused == nil }?.atMs) },
                     recent: snapshot.recent)
    }

    /// Every account device connected now is judged again against the account's list: one that left the list, was
    /// signed out or whose sign-in ended is cut. A failed fetch judges on the last good list (its expiry times still
    /// cut); with no good list for 10 minutes every account device is cut (the gate's `listMissingCutMs`) and comes
    /// back by itself once a fetch succeeds (its next handshake fetches the list first).
    /// Runs on every `devices` push and every sync (the 60-second tick), so a device that drops off the list without
    /// a push is cut at the first tick after the cached list ages out (two minutes at most). A device found gone on a
    /// cached list is judged again on a list fetched now, so a browser whose sign-in was just renewed is never cut by
    /// an old expiry.
    private func rejudge() async {
        guard let host else { return }
        let connected = await host.reachConnectedDeviceIds()
        guard !connected.isEmpty else { return }
        _ = await gate.refreshRoster()
        var gone = await notAdmitted(connected)
        if !gone.isEmpty { _ = await gate.refreshRosterNow(); gone = await notAdmitted(gone) }
        if !gone.isEmpty { await cut(gone) }
    }
    private func notAdmitted(_ ids: Set<String>) async -> Set<String> {
        var gone: Set<String> = []
        for id in ids where !(await gate.stillAdmitted(deviceId: id)) { gone.insert(id) }
        return gone
    }

    private func cut(_ ids: Set<String>?) async {
        await link.closeAccountChannels(ids)
        await host?.dropReachDevices(ids)
    }
}

/// The agent tool: READ the reach state only. Nothing switches reach on or removes a device (those stay the
/// person's own presses on this Mac).
public enum BackendReachAccountTools {
    public static let owner = "cloud-reach"
    public static let ids = ["cloud.reach.status"]
    public static func definitions() throws -> [BackendMCPTool] {
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([])),
                                            .init("required", .array([])), .init("additionalProperties", .bool(false))])
        return [try .init(id: "cloud.reach.status", wireName: "cloud_reach_status",
            description: "Read whether devices signed in to this Mac's account may reach it (the switch \"Let my signed-in devices open this Mac\", whether the account has the feature), the devices that may reach it by name with when each was added and last seen, and the last connections. Read only: it never switches reach on or removes a device, and returns no keys or tokens.",
            inputSchema: schema, tier: .read)]
    }
    public static func registrations(status: @escaping @Sendable () async -> BackendReachStatus?) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        try definitions().map { spec in
            (spec, { _, _ in
                guard let value = await status() else { return .value(.object([.init("available", .bool(false))])) }
                return .value(value.wireValue)
            })
        }
    }
}
