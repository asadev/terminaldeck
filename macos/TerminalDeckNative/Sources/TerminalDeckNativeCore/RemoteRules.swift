import Foundation

/// Remote access ("Your own devices" on Machines), the native screen's pure half —
/// the Swift reading of `src/renderer/remote/*` (RemoteSection, DeviceApproval,
/// PendingApproval, DeviceFolders, DeviceSessions, DeviceLogins, DeviceWindows),
/// rule for rule and word for word.
///
/// Channels: `remote:status`, `remote:devices`, `remote:kinds`, `remote:start`,
/// `remote:stop`, `remote:pair`, `remote:pair:cancel`, `remote:device:approve`,
/// `remote:device:revoke`, `remote:connection:disconnect`, `remote:tunnel:stop`,
/// the `remote:connections` push, `project:pick`, `remote:folders` / `:set`,
/// `confine:state` / `confine:grant`, `remote:sessions` / `:running` / `:set`,
/// `remote:accounts` / `:set`, `remote:windows` / `:set`.

public enum RemoteDeviceState: String, Sendable, Equatable { case pending, approved, revoked }
public enum RemoteDeviceKind: String, Sendable, Equatable { case mine, guest }
public enum RemoteApprovalStep: String, Sendable, Equatable { case check, kind, folders, accounts, confirm }
/// "All" or "Selected" — for logins and sessions alike (`share-mode.ts`).
public enum RemoteShare: String, Sendable, Equatable, CaseIterable {
    case all, selected
    public var label: String { self == .all ? "All" : "Selected" }
}

public struct RemoteDevice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var state: RemoteDeviceState
    /// Milliseconds since 1970.
    public var addedAt: Double?
    public var lastSeenAt: Double?
    public var fingerprint: String?

    public init(id: String, name: String, state: RemoteDeviceState, addedAt: Double? = nil, lastSeenAt: Double? = nil, fingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.addedAt = addedAt
        self.lastSeenAt = lastSeenAt
        self.fingerprint = fingerprint
    }
}

public struct RemoteTunnel: Equatable, Sendable, Identifiable {
    public var id: String
    public var port: Int
    public var streams: Int
    public var openedAt: Double?

    public init(id: String, port: Int, streams: Int = 0, openedAt: Double? = nil) {
        self.id = id
        self.port = port
        self.streams = streams
        self.openedAt = openedAt
    }
}

public struct RemoteConnection: Equatable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var address: String
    public var connectedAt: Double?
    public var sessionIds: [String]
    public var tunnels: [RemoteTunnel]

    public init(id: String, deviceId: String = "", deviceName: String, platform: String = "", address: String = "",
                connectedAt: Double? = nil, sessionIds: [String] = [], tunnels: [RemoteTunnel] = []) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.address = address
        self.connectedAt = connectedAt
        self.sessionIds = sessionIds
        self.tunnels = tunnels
    }
}

public struct RemoteRelay: Equatable, Sendable {
    public var url: String
    public var fingerprint: String
    public var connected: Bool
    public var channels: Int
    public var reason: String?
    public var retryAt: Double?

    public init(url: String = "", fingerprint: String = "", connected: Bool, channels: Int = 0, reason: String? = nil, retryAt: Double? = nil) {
        self.url = url
        self.fingerprint = fingerprint
        self.connected = connected
        self.channels = channels
        self.reason = reason
        self.retryAt = retryAt
    }
}

public struct RemoteState: Equatable, Sendable {
    public var running: Bool
    public var url: String?
    public var address: String?
    public var reason: String?
    public var relay: RemoteRelay?
    public var devices: [RemoteDevice]
    public var connections: [RemoteConnection]

    public init(running: Bool, url: String? = nil, address: String? = nil, reason: String? = nil, relay: RemoteRelay? = nil,
                devices: [RemoteDevice] = [], connections: [RemoteConnection] = []) {
        self.running = running
        self.url = url
        self.address = address
        self.reason = reason
        self.relay = relay
        self.devices = devices
        self.connections = connections
    }
}

public struct RemotePairing: Equatable, Sendable {
    public var token: String
    public var expiresAt: Double?
    /// Whether the relay could take its place at the rendezvous; nil when not said.
    public var findable: Bool?

    public init(token: String, expiresAt: Double? = nil, findable: Bool? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.findable = findable
    }
}

/// An approval in progress.
public struct RemoteApproval: Equatable, Sendable {
    public var device: RemoteDevice
    public var step: RemoteApprovalStep
    public var kind: RemoteDeviceKind?
    public var folders: [String]
    public var accountMode: RemoteShare
    public var accounts: [String]

    public init(device: RemoteDevice) {
        self.device = device
        step = .check
        kind = nil
        folders = []
        accountMode = .all
        accounts = []
    }

    /// Picking whose it is moves on, and "mine" clears what a guest would be given.
    public mutating func pick(_ kind: RemoteDeviceKind) {
        self.kind = kind
        step = RemoteRules.nextStep(.kind, kind: kind)
        if kind == .mine {
            folders = []
            accountMode = .all
            accounts = []
        }
    }

    public mutating func addFolder(_ path: String) {
        if !folders.contains(path) { folders.append(path) }
    }

    public mutating func removeFolder(_ path: String) { folders.removeAll { $0 == path } }

    public mutating func setAccountMode(_ mode: RemoteShare) {
        accountMode = mode
        if mode == .all { accounts = [] }
    }

    public mutating func toggleAccount(_ id: String, on: Bool) {
        accountMode = .selected
        if on { if !accounts.contains(id) { accounts.append(id) } } else { accounts.removeAll { $0 == id } }
    }
}

// MARK: - Reading the engine's answers

public enum RemoteRead {
    static func record(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func string(_ value: Any?) -> String { value as? String ?? "" }
    static func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static func time(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
    static func whole(_ value: Any?) -> Int? {
        guard let double = time(value), double >= 0, double == double.rounded() else { return nil }
        return Int(double)
    }

    /// A device's name as people say it: no underscores, the emulator called one.
    public static func deviceLabel(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Unnamed device" }
        if name.range(of: #"^(google\s+)?sdk_gphone"#, options: [.regularExpression, .caseInsensitive]) != nil { return "Android emulator" }
        return name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func kinds(_ raw: Any?) -> [String: RemoteDeviceKind] {
        var out: [String: RemoteDeviceKind] = [:]
        for case let row as [String: Any] in raw as? [Any] ?? [] {
            guard let id = row["deviceId"] as? String, !id.isEmpty,
                  let kind = RemoteDeviceKind(rawValue: row["kind"] as? String ?? "") else { continue }
            out[id] = kind
        }
        return out
    }

    public static func devices(_ raw: Any?) -> [RemoteDevice] {
        (raw as? [Any] ?? []).compactMap { entry in
            guard let device = record(entry), let id = device["id"] as? String else { return nil }
            let state = RemoteDeviceState(rawValue: string(device["status"]))
                ?? (device["revoked"] as? Bool == true ? .revoked : device["approved"] as? Bool == true ? .approved : .pending)
            return RemoteDevice(id: id, name: deviceLabel(device["name"] as? String ?? id), state: state,
                                addedAt: time(device["addedAt"]), lastSeenAt: time(device["lastSeenAt"]),
                                fingerprint: text(device["fingerprint"]))
        }
    }

    static func tunnels(_ raw: Any?) -> [RemoteTunnel] {
        (raw as? [Any] ?? []).compactMap { entry in
            guard let tunnel = record(entry), let id = tunnel["id"] as? String, let port = whole(tunnel["port"]) else { return nil }
            return RemoteTunnel(id: id, port: port, streams: whole(tunnel["streams"]) ?? 0, openedAt: time(tunnel["openedAt"]))
        }
    }

    static func connections(_ raw: Any?, devices: [RemoteDevice]) -> [RemoteConnection] {
        (raw as? [Any] ?? []).compactMap { entry in
            guard let connection = record(entry), let id = connection["id"] as? String else { return nil }
            let deviceId = string(connection["deviceId"])
            let fallback = devices.first { $0.id == deviceId }?.name ?? "Unnamed device"
            return RemoteConnection(id: id, deviceId: deviceId, deviceName: deviceLabel(connection["deviceName"] as? String ?? fallback),
                                    platform: string(connection["platform"]), address: string(connection["address"]),
                                    connectedAt: time(connection["connectedAt"]),
                                    sessionIds: (connection["sessionIds"] as? [Any] ?? []).compactMap { $0 as? String },
                                    tunnels: tunnels(connection["tunnels"]))
        }
    }

    static func relay(_ raw: Any?) -> RemoteRelay? {
        guard let row = record(raw) else { return nil }
        return RemoteRelay(url: string(row["url"]), fingerprint: string(row["fingerprint"]), connected: row["connected"] as? Bool == true,
                           channels: Int(time(row["channels"]) ?? 0), reason: text(row["reason"]), retryAt: time(row["retryAt"]))
    }

    /// `remote:status` with `remote:devices` folded in; nil when the status is unreadable.
    public static func state(status: Any?, devices deviceList: Any?) -> RemoteState? {
        guard let row = record(status) else { return nil }
        let devices = devices(deviceList)
        return RemoteState(running: row["running"] as? Bool == true, url: text(row["url"]), address: text(row["address"]),
                           reason: text(row["reason"]), relay: relay(row["relay"]), devices: devices,
                           connections: connections(row["connections"], devices: devices))
    }

    public static func pairing(_ raw: Any?) -> RemotePairing? {
        let row = record(raw)
        let token = string(row?["token"])
        guard !token.isEmpty else { return nil }
        return RemotePairing(token: token, expiresAt: time(row?["expiresAt"]), findable: row?["findable"] as? Bool)
    }

    /// What a device is listed as after a write, or nil when the answer does not list it.
    public static func stateAfter(_ answer: Any?, id: String) -> RemoteDeviceState? {
        devices(answer).first { $0.id == id }?.state
    }
}

// MARK: - The words and the rules

public enum RemoteRules {
    public static let pairingWindowSeconds = 60
    public static let readDeadlineSeconds = 8.0
    public static let unsettledSeconds = 1.0
    public static let retryGraceSeconds = 0.75

    public static func stateLabel(_ state: RemoteDeviceState) -> String {
        switch state {
        case .pending: "Waiting for you"
        case .approved: "Approved"
        case .revoked: "Revoked"
        }
    }

    /// `PC`, `Mac`, `computer` — this native app always runs on a Mac.
    public static let machineNoun = "Mac"
    public static let thisMachine = "this Mac"

    /// JavaScript's `Math.round`: halves go up.
    static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }

    public static func retryNote(_ retryAt: Double?, now: Double) -> String? {
        guard let retryAt else { return nil }
        let seconds = Int(jsRound((retryAt - now) / 1000))
        if seconds <= 0 { return "Trying again now." }
        if seconds < 60 { return "Trying again in \(seconds)s." }
        let minutes = Int(jsRound(Double(seconds) / 60))
        return "Trying again in \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    public static func whenSeen(_ at: Double?, now: Double) -> String {
        guard let at else { return "never" }
        let minutes = Int(jsRound((now - at) / 60_000))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = Int(jsRound(Double(minutes) / 60))
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = Int(jsRound(Double(hours) / 24))
        if days <= 30 { return "\(days) day\(days == 1 ? "" : "s") ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }

    public static func attachedFor(since: Double, now: Double) -> String {
        let minutes = Int(((now - since) / 60_000).rounded(.down))
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Int(jsRound(Double(minutes) / 60))
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// `attached for 5 minutes · iOS · 100.64.0.2 · 1 session open`
    public static func connectionNote(_ connection: RemoteConnection, now: Double) -> String {
        var parts = [connection.connectedAt.map { "attached for \(attachedFor(since: $0, now: now))" } ?? "attached"]
        if !connection.platform.isEmpty { parts.append(connection.platform) }
        if !connection.address.isEmpty { parts.append(connection.address) }
        let count = connection.sessionIds.count
        parts.append(count == 0 ? "no session open" : "\(count) session\(count == 1 ? "" : "s") open")
        return parts.joined(separator: " · ")
    }

    public static func tunnelNote(_ tunnel: RemoteTunnel, now: Double) -> String {
        var parts = [tunnel.openedAt.map { "open for \(attachedFor(since: $0, now: now))" } ?? "open"]
        if tunnel.streams > 0 { parts.append("carrying \(tunnel.streams) socket\(tunnel.streams == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: When the screen next has to change

    static let second = 1000.0, minute = 60_000.0, hour = 3_600_000.0, day = 86_400_000.0
    static let minStep = 250.0

    static func nextFloorStep(_ since: Double, _ now: Double, _ step: Double) -> Double {
        since + step * (((now - since) / step).rounded(.down) + 1)
    }

    static func nextRoundStep(_ since: Double, _ now: Double, _ step: Double) -> Double {
        since + jsRound((((now - since) / step + 0.5).rounded(.down) + 0.5) * step)
    }

    static func nextWhenSeenStep(_ at: Double?, _ now: Double) -> Double? {
        guard let at else { return nil }
        let elapsed = now - at
        if elapsed >= 31 * day { return nil }
        return nextRoundStep(at, now, elapsed >= day ? day : elapsed >= hour ? hour : minute)
    }

    static func nextRetryNoteStep(_ retryAt: Double, _ now: Double) -> Double? {
        let remaining = retryAt - now
        if remaining <= 0 { return nil }
        let seconds = jsRound(remaining / second)
        if seconds <= 0 { return nil }
        let target = seconds < 60 ? seconds - 1 : max(59, 60 * jsRound(seconds / 60) - 31)
        return retryAt - jsRound((target + 0.5) * second) + 1
    }

    /// The next moment something on screen reads differently, or nil when nothing moves.
    public static func nextClockChange(_ state: RemoteState?, _ pairing: RemotePairing?, now: Double) -> Double? {
        var soonest = Double.infinity
        func consider(_ when: Double?) { if let when, when < soonest { soonest = when } }
        if let expiresAt = pairing?.expiresAt {
            let left = ((expiresAt - now) / second).rounded(.up)
            if left > 0 { consider(expiresAt - (left - 1) * second) }
        }
        if let retryAt = state?.relay?.retryAt { consider(nextRetryNoteStep(retryAt, now)) }
        for device in state?.devices ?? [] {
            consider(nextWhenSeenStep(device.lastSeenAt, now))
            consider(nextWhenSeenStep(device.addedAt, now))
        }
        for connection in state?.connections ?? [] {
            if let since = connection.connectedAt {
                consider(nextFloorStep(since, now, now - since >= hour ? hour : minute))
            }
            for tunnel in connection.tunnels {
                guard let opened = tunnel.openedAt else { continue }
                consider(nextFloorStep(opened, now, now - opened >= hour ? hour : minute))
            }
        }
        guard soonest.isFinite else { return nil }
        return max(soonest, now + minStep)
    }

    /// A code on screen, or a relay still finding its feet: read again every second.
    public static func unsettled(_ state: RemoteState?, _ pairing: RemotePairing?) -> Bool {
        if pairing != nil { return true }
        guard let relay = state?.relay else { return false }
        return state?.running == true && !relay.connected && relay.retryAt == nil
    }

    public static func codeSecondsLeft(expiresAt: Double, now: Double) -> Int {
        max(0, Int(((expiresAt - now) / 1000).rounded(.up)))
    }

    /// The code as the main process minted it, six digits.
    public static func codeShown(_ token: String) -> String {
        var digits = ""
        for character in token.prefix(256) {
            if character.isASCII, character.isNumber {
                digits.append(character)
                if digits.count > 6 { return token }
                continue
            }
            if character.isASCII, character.isLetter { return token }
        }
        return digits.count == 6 ? digits : token
    }

    /// A code can be minted only while something is up for it to point at.
    public static func canMintCode(_ state: RemoteState?) -> Bool {
        guard let state, state.running else { return false }
        return state.relay?.connected == true || state.url != nil
    }

    // MARK: Approval

    public static func steps(_ kind: RemoteDeviceKind?) -> [RemoteApprovalStep] {
        kind == .mine ? [.check, .kind, .confirm] : [.check, .kind, .folders, .accounts, .confirm]
    }

    public static func nextStep(_ step: RemoteApprovalStep, kind: RemoteDeviceKind?) -> RemoteApprovalStep {
        let order = steps(kind)
        guard let at = order.firstIndex(of: step) else { return order.first ?? step }
        return order[min(at + 1, order.count - 1)]
    }

    public static func previousStep(_ step: RemoteApprovalStep, kind: RemoteDeviceKind?) -> RemoteApprovalStep? {
        let order = steps(kind)
        guard let at = order.firstIndex(of: step), at > 0 else { return nil }
        return order[at - 1]
    }

    /// What the page says once a device is let in.
    public static func approvedNotice(_ name: String, kind: RemoteDeviceKind, folders: Int, accountMode: RemoteShare, accounts: Int) -> String {
        if kind == .mine { return "\(name) has full access." }
        if folders == 0 { return "\(name) is in, and can open nothing until you choose a folder for it." }
        let what = folders == 1 ? "one folder" : "\(folders) folders"
        let logins = accountMode == .all ? "" : accounts == 0 ? ", with none of your logins"
            : ", with \(accounts == 1 ? "one of your logins" : "\(accounts) of your logins")"
        return "\(name) can open \(what)\(logins)."
    }

    /// The confirm step's lede.
    public static func confirmLede(_ name: String, kind: RemoteDeviceKind?, folders: Int) -> String {
        if kind == .mine { return "\(name) will have full access to \(thisMachine)." }
        if folders == 0 { return "\(name) will be let in and will be able to open nothing yet." }
        return "\(name) will be able to open \(folders == 1 ? "one folder" : "\(folders) folders")."
    }

    public static func confirmLogins(mode: RemoteShare, accounts: Int) -> String {
        if mode == .all { return "It can use any login on \(thisMachine)." }
        if accounts == 0 { return "It gets none of your logins, and no account chip at all." }
        return "It can use \(accounts == 1 ? "one login" : "\(accounts) logins")."
    }

    /// Why a device in the Alerts approval cannot be let in any more, or nil when it can.
    public static func goneBecause(_ device: RemoteDevice?) -> String? {
        guard let device else {
            return "That device is not in the list any more. If it is still waiting, pair it again from Settings → Remote."
        }
        switch device.state {
        case .approved: return "\(device.name) has already been let in — nothing left to do here."
        case .revoked: return "\(device.name) was refused. A refused device cannot be let in later; pair it again if that was a slip."
        case .pending: return nil
        }
    }

    /// The approval's answer: landed, or why not.
    public static func approvalFailure(_ answer: Any?, device: RemoteDevice) -> String? {
        let after = RemoteRead.stateAfter(answer, id: device.id)
        if after == nil || after == .approved { return nil }
        return after == .revoked
            ? "\(device.name) has been refused, so it cannot be let in. Pair it again if that was a slip."
            : "\(device.name) is still waiting, so that did not take. Try again from Settings → Remote."
    }

    /// A write that left the device in the wrong state.
    public static func didNotTake(_ device: RemoteDevice, after: RemoteDeviceState) -> String {
        "\(device.name) is still listed as \(stateLabel(after).lowercased()), so that did not take."
    }

    public static func missingChannel(_ name: String) -> String {
        "This build has no \(name) channel, so nothing happened. Remote access is only half wired into it."
    }

    // MARK: Who the per-device lists are for

    /// Approved guests (and, before kinds are known, every approved device).
    public static func grantable(_ devices: [RemoteDevice], kinds: [String: RemoteDeviceKind]?) -> [RemoteDevice] {
        devices.filter { $0.state == .approved && (kinds == nil || kinds?[$0.id] != .mine) }
    }

    public static func sessionDevices(_ devices: [RemoteDevice]) -> [RemoteDevice] {
        devices.filter { $0.state == .approved }
    }

    /// The line under an approved device saying what it is.
    public static func kindNote(_ kind: RemoteDeviceKind?, assistant: String = "Hoot") -> String {
        switch kind {
        case .mine: "Your device — full access, \(assistant) included."
        case .guest: "Guest — only the folders you chose. Never \(assistant)."
        case nil: "Paired before folder approval existed, so it is treated as a guest and can open nothing. Revoke it and pair it again to choose."
        }
    }
}

// MARK: - The per-device lists

public enum RemoteGrants {
    /// `remote:folders`: each device's folders. A device missing from the answer was approved before folders existed.
    public static func folders(_ raw: Any?) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for case let row as [String: Any] in raw as? [Any] ?? [] {
            guard let id = row["deviceId"] as? String, !id.isEmpty, let list = row["folders"] as? [Any] else { continue }
            out[id] = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        return out
    }

    public static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    public static func folderSummary(_ chosen: [String]?, loaded: Bool) -> String {
        guard loaded else { return "Reading…" }
        guard let chosen else { return "Approved before this existed — can open nothing" }
        if chosen.isEmpty { return "No folders. This device cannot start a session." }
        return chosen.count == 1 ? "1 folder" : "\(chosen.count) folders"
    }

    public struct Confine: Equatable, Sendable {
        public var confining: Bool
        public var canGrant: Bool
        public var folders: [String]
        public var note: String

        public init(confining: Bool, canGrant: Bool = false, folders: [String] = [], note: String = "") {
            self.confining = confining
            self.canGrant = canGrant
            self.folders = folders
            self.note = note
        }

        public init?(json: Any?) {
            guard let row = json as? [String: Any] else { return nil }
            self.init(confining: row["confining"] as? Bool == true, canGrant: row["canGrant"] as? Bool == true,
                      folders: (row["folders"] as? [Any] ?? []).compactMap { $0 as? String }, note: row["note"] as? String ?? "")
        }
    }

    /// Whether a session from a device is held inside its folders here. Unknown on a Mac means yes.
    public static func holdsSessions(_ confine: Confine?) -> Bool { confine?.confining ?? true }

    /// The "i" beside the one-time permission.
    public static func grantNote(_ confine: Confine) -> String {
        var text = "The permission is on the folders holding node, git and the agent tools."
        if !confine.folders.isEmpty {
            text += " It would cover \(confine.folders.count == 1 ? "this folder" : "these folders"): \(confine.folders.joined(separator: ", ")). Nothing else on the disk is touched."
        }
        if !confine.note.isEmpty { text += " \(confine.note)" }
        return text
    }

    /// `confine:grant`'s answer: the new state, and the sentence when it did not go through.
    public static func grantOutcome(_ raw: Any?) -> (state: Confine?, problem: String?) {
        let row = raw as? [String: Any]
        let result = row?["result"] as? [String: Any]
        var problem: String?
        if result?["ok"] as? Bool == false {
            let detail = result?["detail"] as? String ?? ""
            problem = detail.isEmpty ? "That did not go through, and this machine did not say why." : "That did not go through: \(detail)"
        }
        return (Confine(json: row?["state"]), problem)
    }

    public struct Choice: Equatable, Sendable {
        public var mode: RemoteShare
        public var ids: [String]
        public init(mode: RemoteShare, ids: [String] = []) {
            self.mode = mode
            self.ids = mode == .all ? [] : ids
        }
        public static let all = Choice(mode: .all)
    }

    /// `remote:sessions` / `remote:accounts`: each device's All or Selected, and the ticks.
    public static func choices(_ raw: Any?, listKey: String) -> [String: Choice] {
        var out: [String: Choice] = [:]
        for case let row as [String: Any] in raw as? [Any] ?? [] {
            guard let id = row["deviceId"] as? String, !id.isEmpty else { continue }
            let mode: RemoteShare = row["mode"] as? String == "all" ? .all : .selected
            out[id] = Choice(mode: mode, ids: (row[listKey] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty })
        }
        return out
    }

    /// The write after a tick: Selected, with the id added or taken away.
    public static func toggled(_ current: Choice, id: String, on: Bool) -> [String] {
        var ids = current.ids
        if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        return ids
    }

    public struct Running: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var cwd: String
    }

    /// `remote:sessions:running`: live sessions only.
    public static func running(_ raw: Any?) -> [Running] {
        (raw as? [Any] ?? []).compactMap { entry in
            guard let row = entry as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
            if let exit = row["exitCode"], !(exit is NSNull) { return nil }
            let title = row["title"] as? String ?? ""
            return Running(id: id, title: title.isEmpty ? id : title, cwd: row["cwd"] as? String ?? "")
        }
    }

    /// `remote:windows`: the devices that may act on browser windows.
    public static func windows(_ raw: Any?) -> Set<String> {
        Set((raw as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty })
    }
}
