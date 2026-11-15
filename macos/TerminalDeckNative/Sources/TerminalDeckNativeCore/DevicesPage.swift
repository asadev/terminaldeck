import Foundation

/// The Devices window, decided here so it is tested without a window (owner, 13 Nov: "we don't have pairing thing at
/// all completely. We just see all of our devices when we just log in. Not behind link, not behind any code, nowhere").
///
/// What it shows, top to bottom:
/// 1. ONE setting: "Let my signed-in devices open this Mac" (the reach-by-account switch; on by default), and, only
///    while the account does not have that feature, one sentence saying so.
/// 2. The account's devices: one row per device with its friendly name, what it is, "Added <date>",
///    "Last seen <date, time>"; this Mac is marked "This Mac". Signed out: one sentence and Sign in.
/// 3. Only when any exist: "Connected before accounts", the devices connected the old way, each with "Last seen" and
///    Remove; the ones not seen for 14 days are folded into "Not seen recently (n)" with "Remove all".
/// No codes, ids, QR pictures or fingerprints anywhere; the old way can only be removed from, never added to.
public struct DevicesPage: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case mac = "Mac", pc = "PC", phone = "Phone", browser = "Browser" }

    /// One device of the account, as the account lists it.
    public struct AccountDevice: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        public let isThisMac: Bool
        /// ms since 1970.
        public let addedAtMs: Int64?
        public let lastSeenAtMs: Int64?
        /// The account's handle for Remove; never shown.
        public let deviceId: String?
        /// Signed out by another device (the Cloud's `removedByName` / `removedAt`): both or neither.
        public var signedOutBy: String? = nil
        public var signedOutAtMs: Int64? = nil
        public init(name: String, kind: Kind, isThisMac: Bool, addedAtMs: Int64?, lastSeenAtMs: Int64?, deviceId: String? = nil) {
            self.name = name; self.kind = kind; self.isThisMac = isThisMac; self.addedAtMs = addedAtMs; self.lastSeenAtMs = lastSeenAtMs
            self.deviceId = deviceId
        }
    }

    /// One device connected the old way (before accounts): a phone, browser or computer that reaches this Mac, or a
    /// computer this Mac reaches. `ref` says which record Remove acts on; it is never shown.
    public struct OldDevice: Sendable, Equatable {
        public enum Source: String, Sendable, Equatable { case device, machine }
        public let ref: String
        public let source: Source
        public let name: String
        public let lastSeenAtMs: Double?
        public let connected: Bool
        public init(ref: String, source: Source, name: String, lastSeenAtMs: Double?, connected: Bool) {
            self.ref = ref; self.source = source; self.name = name; self.lastSeenAtMs = lastSeenAtMs; self.connected = connected
        }
    }

    /// Whether a signed-in device can really get in right now (MAC-NEXT-13 A1): the switch alone is not the truth.
    public enum Door: String, Sendable, Equatable { case ready, connecting, notReachable }

    /// One entry of "Last connections": who opened this Mac, when (ms), or that it was turned away.
    public struct Connection: Sendable, Equatable {
        public let name: String
        public let atMs: Double
        public let opened: Bool
        public init(name: String, atMs: Double, opened: Bool) { self.name = name; self.atMs = atMs; self.opened = opened }
    }

    /// The reach-by-account switch as this Mac knows it.
    public struct Reach: Sendable, Equatable {
        /// The switch exists on this Mac now (signed in, the session host up).
        public let available: Bool
        public let on: Bool
        /// nil = not known yet.
        public let entitled: Bool?
        /// The real state of the way in while the switch is on and the account has the feature; nil = not known yet.
        public let door: Door?
        /// Newest first.
        public let connections: [Connection]
        public init(available: Bool, on: Bool, entitled: Bool?, door: Door? = nil, connections: [Connection] = []) {
            self.available = available; self.on = on; self.entitled = entitled; self.door = door; self.connections = connections
        }
        public static let unknown = Reach(available: false, on: true, entitled: nil)
    }

    public struct AccountRow: Sendable, Equatable, Identifiable {
        /// The row's place in the list ("account-1"): stable for one page, never an account id.
        public let id: String
        public let name: String
        public let kind: Kind
        public let isThisMac: Bool
        /// "Added 12 Oct 2026", or nil when the account does not say.
        public let added: String?
        /// "Last seen 13 Nov 2026 at 14:05", "This Mac", or "Not seen yet".
        public let seen: String
        /// The account's handle Remove acts on (never shown); nil for this Mac.
        public let ref: String?
        public var canRemove: Bool { ref != nil && !isThisMac }
        public var detail: String { ([kind.rawValue] + [added].compactMap { $0 } + [seen]).joined(separator: " · ") }
    }

    public struct OldRow: Sendable, Equatable, Identifiable {
        public var id: String { ref }
        public let ref: String
        public let source: OldDevice.Source
        public let name: String
        /// "Connected now", "Last seen 13 Nov 2026 at 14:05" or "Not seen yet".
        public let seen: String
    }

    public static let title = "Devices"
    public static let subtitle = "Everything signed in to your Terminal Deck account."
    public static let signedOutLine = "Sign in to your Terminal Deck account to see all your devices here."
    public static let settingTitle = "Let my signed-in devices open this Mac"
    public static let settingOnDetail = "Your phones, browsers and other computers signed in to your account can open this Mac."
    /// The one line under the switch while it is on: what is really true now (A1).
    public static let doorReady = "Ready: your signed-in devices can open this Mac."
    public static let doorConnecting = "Connecting…"
    public static let doorNotReachable = "Not reachable right now, trying again."
    /// On, but the account does not have the feature yet (A2): nothing claims devices can get in.
    public static let notEntitledDetail = "Opening this Mac from your other devices is not on for your account yet. This starts working by itself once it is."
    public static let lastConnectionsTitle = "Last connections"
    public static let detailsTitle = "Details"
    public static let settingOffDetail = "Off: this Mac is not offered to your phones, browsers and other computers."
    /// The phones' own wording (Devices page on iPhone and Android).
    public static let notSwitchedOn = "Opening your machines from your other devices is not switched on for your account yet."
    public static let noOtherDevice = "No other device has signed in to your account yet. Sign in on your phone, a browser or another computer and it shows here."
    public static let oldTitle = "Connected before accounts"
    public static let oldLine = "These were connected before you signed in. They keep working until you remove them; new devices join by signing in."
    public static let removeTitle = "Remove"
    public static let removeAllTitle = "Remove all"
    /// What every place that used to start the old way now says, the AI tools included.
    public static let joinBySigningIn = "Devices now join by signing in to your Terminal Deck account on that device. There is nothing to set up on this Mac."
    /// Not seen for this long (or never): folded into "Not seen recently".
    public static let quietAfterMs: Double = 14 * 86_400_000
    public static func quietTitle(_ count: Int) -> String { "Not seen recently (\(count))" }

    public let signedIn: Bool
    /// Shown only while signed in and the switch exists.
    public let showsSetting: Bool
    public let settingOn: Bool
    public let settingDetail: String
    /// The door's state shown under the switch, nil when no door line is shown (off, no feature, no switch).
    public let door: Door?
    /// "iPhone opened this Mac · 13 Nov 2026 at 14:05", newest first, at most eight.
    public let lastConnections: [String]
    /// The one sentence under the setting while the account does not have the feature; nil otherwise.
    public let featureNote: String?
    public let accountRows: [AccountRow]
    /// Seen in the last 14 days (or connected now), newest first.
    public let oldRecent: [OldRow]
    /// Not seen for 14 days or more, or never.
    public let oldQuiet: [OldRow]
    public var showsOld: Bool { !oldRecent.isEmpty || !oldQuiet.isEmpty }

    public init(signedIn: Bool, account: [AccountDevice], reach: Reach, old: [OldDevice],
                now: Double = Date().timeIntervalSince1970 * 1000, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.signedIn = signedIn
        showsSetting = signedIn && reach.available
        settingOn = reach.on
        let dates = Dates(timeZone: timeZone, locale: locale)
        if !reach.on {
            door = nil; settingDetail = Self.settingOffDetail
        } else if reach.entitled == false {
            door = nil; settingDetail = Self.notEntitledDetail
        } else {
            // Not known yet counts as connecting: the switch never claims an open door it has not seen.
            let real: Door = reach.entitled == nil ? .connecting : reach.door ?? .connecting
            door = real; settingDetail = Self.doorLine(real)
        }
        // With the switch on screen its own line says it; the separate note only stands in when there is no switch.
        featureNote = signedIn && reach.entitled == false && !showsSetting ? Self.notSwitchedOn : nil
        lastConnections = showsSetting ? reach.connections.sorted { $0.atMs > $1.atMs }.prefix(8).map { c in
            Self.plain(c.name) + (c.opened ? " opened this Mac · " : " was turned away · ") + dates.dayAndTime(c.atMs)
        } : []
        let sorted = signedIn ? account.enumerated().sorted { a, b in
            if a.element.isThisMac != b.element.isThisMac { return a.element.isThisMac }
            let sa = a.element.lastSeenAtMs ?? 0, sb = b.element.lastSeenAtMs ?? 0
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element) : []
        accountRows = sorted.enumerated().map { index, device in
            AccountRow(id: "account-\(index + 1)", name: Self.plain(device.name), kind: device.kind, isThisMac: device.isThisMac,
                       added: device.addedAtMs.map { "Added " + dates.day(Double($0)) },
                       seen: device.isThisMac ? "This Mac" : device.lastSeenAtMs.map { "Last seen " + dates.dayAndTime(Double($0)) } ?? "Not seen yet",
                       ref: device.isThisMac ? nil : device.deviceId)
        }
        let rows = old.sorted { ($0.connected ? .infinity : $0.lastSeenAtMs ?? 0) > ($1.connected ? .infinity : $1.lastSeenAtMs ?? 0) }
        func row(_ device: OldDevice) -> OldRow {
            OldRow(ref: device.ref, source: device.source, name: Self.plain(device.name),
                   seen: device.connected ? "Connected now" : device.lastSeenAtMs.map { "Last seen " + dates.dayAndTime($0) }
                       ?? (device.source == .machine ? "Not connected" : "Not seen yet"))
        }
        func quiet(_ device: OldDevice) -> Bool {
            guard !device.connected else { return false }
            guard let seen = device.lastSeenAtMs else { return true }
            return now - seen >= Self.quietAfterMs
        }
        oldRecent = rows.filter { !quiet($0) }.map(row)
        oldQuiet = rows.filter(quiet).map(row)
    }

    public static func doorLine(_ door: Door) -> String {
        switch door {
        case .ready: doorReady
        case .connecting: doorConnecting
        case .notReachable: doorNotReachable
        }
    }

    /// The door's real state from what this Mac knows (A1). `running`: remote access is up; `published`: the account
    /// lists this Mac now; `relayConnected`: nil when not known. A start or publish that failed, or a connection still
    /// not made after a minute, is said as not reachable (the app keeps trying).
    public static func door(running: Bool, startFailed: Bool, published: Bool, publishFailed: Bool, relayConnected: Bool?,
                            connectingForMs: Double) -> Door {
        if running && published && relayConnected != false { return .ready }
        if startFailed || publishFailed { return .notReachable }
        return connectingForMs >= 60_000 ? .notReachable : .connecting
    }

    /// Whether the app must start remote access by itself now (A1): the switch is on, the account is signed in and has
    /// the feature, and the way in is not running. A Mac whose switch is off is never touched.
    public static func startsDoor(on: Bool, signedIn: Bool, entitled: Bool?, running: Bool?) -> Bool {
        on && signedIn && entitled == true && running == false
    }

    /// A name as a row shows it: never empty.
    public static func plain(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A device" : trimmed
    }

    struct Dates {
        let day: DateFormatter, time: DateFormatter
        init(timeZone: TimeZone, locale: Locale) {
            day = DateFormatter(); day.locale = locale; day.timeZone = timeZone; day.dateStyle = .medium; day.timeStyle = .none
            time = DateFormatter(); time.locale = locale; time.timeZone = timeZone; time.dateStyle = .none; time.timeStyle = .short
        }
        func day(_ ms: Double) -> String { day.string(from: Date(timeIntervalSince1970: ms / 1000)) }
        func dayAndTime(_ ms: Double) -> String {
            let date = Date(timeIntervalSince1970: ms / 1000)
            return day.string(from: date) + " at " + time.string(from: date)
        }
    }

    /// Every sentence the page can put on screen for this state (the no-pairing-word check reads this).
    public var shownText: [String] {
        var text = [Self.title, Self.subtitle]
        if !signedIn { text.append(Self.signedOutLine) }
        if showsSetting { text += [Self.settingTitle, settingDetail] }
        if let featureNote { text.append(featureNote) }
        if signedIn && accountRows.allSatisfy(\.isThisMac) { text.append(Self.noOtherDevice) }
        for row in accountRows { text += [row.name, row.detail] + (row.canRemove ? [Self.removeTitle] : []) }
        if !lastConnections.isEmpty { text += [Self.lastConnectionsTitle] + lastConnections }
        if showsOld {
            text += [Self.oldTitle, Self.oldLine]
            for row in oldRecent + oldQuiet { text += [row.name, row.seen, Self.removeTitle] + (row.source == .device ? [Self.detailsTitle] : []) }
            if !oldQuiet.isEmpty { text += [Self.quietTitle(oldQuiet.count), Self.removeAllTitle] }
        }
        return text
    }

    /// The same rows for the AI tools: the account's devices, then the old ones marked as such. Names and dates; every
    /// row but this Mac's carries `ref`, the only handle the remove tool takes (`account:<id>` signs that device out).
    public static func accountRef(_ deviceId: String) -> String { "account:" + deviceId }
    public var wireValue: NativeRPCValue {
        let account: [NativeRPCValue] = accountRows.map { row in
            .object([.init("name", .string(row.name)), .init("kind", .string(row.kind.rawValue)), .init("thisMac", .bool(row.isThisMac)),
                     .init("added", row.added.map(NativeRPCValue.string) ?? .null), .init("seen", .string(row.seen)),
                     .init("joined", .string("account")), .init("ref", row.ref.map { .string(Self.accountRef($0)) } ?? .null)])
        }
        func old(_ row: OldRow, quiet: Bool) -> NativeRPCValue {
            .object([.init("name", .string(row.name)), .init("seen", .string(row.seen)), .init("joined", .string("before accounts")),
                     .init("notSeenRecently", .bool(quiet)), .init("ref", .string(row.ref))])
        }
        return .object([
            .init("signedIn", .bool(signedIn)),
            .init("setting", showsSetting ? .object([.init("title", .string(Self.settingTitle)), .init("on", .bool(settingOn)),
                                                     .init("state", .string(settingDetail))]) : .null),
            .init("lastConnections", .array(lastConnections.map(NativeRPCValue.string))),
            .init("note", featureNote.map(NativeRPCValue.string) ?? (signedIn ? .null : .string(Self.signedOutLine))),
            .init("devices", .array(account + oldRecent.map { old($0, quiet: false) } + oldQuiet.map { old($0, quiet: true) })),
            .init("howDevicesJoin", .string(Self.joinBySigningIn)),
        ])
    }
}

extension DevicesPage {
    /// The account's devices from this Mac's account snapshot: one per device the service lists, without entries it
    /// replaced, removed devices or stale earlier entries of this Mac; this Mac is the row the account marks as this Mac.
    public static func accountDevices(_ snapshot: CloudAccountSnapshot) -> [AccountDevice] {
        let stale = Set(snapshot.trust.filter(\.stale).map(\.deviceId))
        let removed = Set(snapshot.trust.filter(\.removed).map(\.deviceId))
        let thisId = snapshot.trust.first { $0.standing == .thisMac && !$0.stale }?.deviceId
        let addedByTrust = Dictionary(snapshot.trust.compactMap { row in row.addedAt.map { (row.deviceId, $0) } }, uniquingKeysWith: max)
        var seen: Set<String> = []
        return snapshot.devices.compactMap { device in
            guard device.status == .active, device.supersededBy == nil, !stale.contains(device.deviceId), !removed.contains(device.deviceId),
                  seen.insert(device.deviceId).inserted else { return nil }
            let lastSeen = max(device.lastSeenAt, device.lastPulledAt ?? 0)
            var row = AccountDevice(name: device.shownName, kind: kind(device.platform), isThisMac: device.deviceId == thisId,
                                    addedAtMs: device.registeredAt ?? addedByTrust[device.deviceId], lastSeenAtMs: lastSeen > 0 ? lastSeen : nil,
                                    deviceId: device.deviceId)
            if let by = device.removedByName?.trimmingCharacters(in: .whitespacesAndNewlines), !by.isEmpty,
               let at = device.removedAt, at > 0 {
                row.signedOutBy = String(by.filter { !$0.isNewline }.prefix(80)); row.signedOutAtMs = at
            }
            return row
        }
    }

    public static func kind(_ platform: CloudPlatform) -> Kind {
        switch platform {
        case .macos: .mac
        case .windows: .pc
        case .ios, .android: .phone
        case .web: .browser
        }
    }

    /// Devices connected the old way that still let themselves in (approved, not revoked), and computers this Mac
    /// still reaches the old way.
    public static func oldDevices(devices: [RemoteDevice], connected: Set<String>, machines: [PairedMachine], online: Set<String>) -> [OldDevice] {
        devices.filter { $0.state == .approved }.map {
            OldDevice(ref: "device:" + $0.id, source: .device, name: $0.name, lastSeenAtMs: $0.lastSeenAt, connected: connected.contains($0.id))
        } + machines.map {
            OldDevice(ref: "machine:" + $0.id, source: .machine, name: $0.name, lastSeenAtMs: nil, connected: online.contains($0.id))
        }
    }

    /// The words the page and its tools must never say (owner, 13 Nov).
    public static let retiredWords = try! NSRegularExpression(pattern: #"\b(pair|pairs|paired|pairing|code|codes|qr)\b"#, options: [.caseInsensitive])
    public static func saysRetiredWord(_ text: String) -> Bool {
        retiredWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
