import Foundation

/// GET /v1/subscription. Dates are Unix milliseconds; a missing date/plan/source is null.
public struct CloudSubscription: Codable, Sendable, Equatable {
    public enum Paywall: String, Codable, Sendable { case off, on }
    public enum State: String, Codable, Sendable { case paid, gift, none, lapsed }
    public enum Plan: String, Codable, Sendable { case monthly, yearly }
    public enum Source: String, Codable, Sendable { case apple, google, gift }
    /// 19 Nov free plan: "paid" for state paid or gift, else "free". Nil from an older service (read from `state`).
    public enum Tier: String, Codable, Sendable { case free, paid }
    public let paywall: Paywall
    public let state: State
    public let plan: Plan?
    public let paidUntil: Int64?
    public let source: Source?
    public let includedGb: Int
    public let extraGb: Int
    public let offer: Bool
    public let dataKeptUntil: Int64?
    public let tier: Tier?
    public let canBuyStorage: Bool?

    public init(paywall: Paywall, state: State, plan: Plan? = nil, paidUntil: Int64? = nil, source: Source? = nil,
                includedGb: Int = 100, extraGb: Int = 0, offer: Bool = false, dataKeptUntil: Int64? = nil,
                tier: Tier? = nil, canBuyStorage: Bool? = nil) {
        self.paywall = paywall; self.state = state; self.plan = plan; self.paidUntil = paidUntil; self.source = source
        self.includedGb = includedGb; self.extraGb = extraGb; self.offer = offer; self.dataKeptUntil = dataKeptUntil
        self.tier = tier; self.canBuyStorage = canBuyStorage
    }
    public var entitled: Bool { state == .paid || state == .gift }
    /// The account's own tier, the paywall on or off: the service's `tier`, or from `state` on an older service.
    public var accountTier: Tier { tier ?? (entitled ? .paid : .free) }
    /// Asad, 19 Nov: a FREE account (paywall on, tier free) reaches its computers' sessions from its other devices and
    /// nothing more. This computer then serves another device sessions only (`BackendRemoteFreePlan`), and Cloud sync
    /// does not run. Restricted ONLY when `paywall == on && tier == free` (Cloud API note, 20 Nov).
    public var limitsRemoteToSessions: Bool { paywall == .on && accountTier == .free }
    public var wireValue: NativeRPCValue {
        .object([.init("paywall", .string(paywall.rawValue)), .init("state", .string(state.rawValue)),
                 .init("plan", plan.map { .string($0.rawValue) } ?? .null),
                 .init("paidUntil", paidUntil.map { .number(Double($0)) } ?? .null),
                 .init("source", source.map { .string($0.rawValue) } ?? .null),
                 .init("includedGb", .number(Double(includedGb))), .init("extraGb", .number(Double(extraGb))),
                 .init("offer", .bool(offer)), .init("dataKeptUntil", dataKeptUntil.map { .number(Double($0)) } ?? .null),
                 .init("tier", .string(accountTier.rawValue)), .init("canBuyStorage", .bool(canBuyStorage ?? (accountTier == .paid)))])
    }
}

/// The Mac's inventory of paid offers. Local files, SSH, local AI-app keys and WhatsApp are deliberately outside it.
/// Keep this list and RESULT.md together: Windows can use the same inventory and rule.
public enum CloudPaidPlace: String, CaseIterable, Sendable {
    case sidebarCloud, settingsCloud, devices, phoneAndWebReach, pairing, otherComputerSessions, sessionMove
    case remoteMachineChoices, fileManager, syncSwitches, savedPasswords, phonesCopy, aiAppsInternet, cloudTools, projectCloudActions, artifactCloudActions
    /// 19 Nov free plan (Decker, 20 Nov: "He started in Windows. He can see and control from Mac"): what a FREE account
    /// keeps on a computer: its devices (the Devices page and its switch) and its other computers' sessions (live through
    /// the relay, open, control, continue, start). Everything else here stays paid, the other Macs' screens
    /// (`remoteMachineChoices`) and the sign-in screen settings (`phoneAndWebReach`) included.
    public static let freeAccountPlaces: Set<CloudPaidPlace> = [.devices, .otherComputerSessions]
}

/// Keeps the last good answer in memory for this sign-in, including through an outage. A failed/missing/old endpoint
/// disables only enforcement; it never discards that answer or guesses a lapse from this computer's clock.
public struct CloudSubscriptionSnapshot: Sendable, Equatable {
    public private(set) var lastAnswer: CloudSubscription?
    public private(set) var available: Bool
    public init(lastAnswer: CloudSubscription? = nil, available: Bool = false) {
        self.lastAnswer = lastAnswer; self.available = available
    }
    public mutating func received(_ answer: CloudSubscription?) {
        available = answer != nil
        if let answer { lastAnswer = answer }
    }
    /// The ONE payment rule. It adds no capability: existing sign-in and capability checks still decide access.
    public var allowsCloudServices: Bool {
        !available || lastAnswer?.paywall != .on || lastAnswer?.entitled == true
    }
    public func offers(_ place: CloudPaidPlace, existing: Bool = true) -> Bool {
        existing && (allowsCloudServices || limitsRemoteToSessions && CloudPaidPlace.freeAccountPlaces.contains(place))
    }
    /// The "Terminal Deck Cloud" row: the paywall is on, a preview account, or (19 Nov) a gift, which shows its plan
    /// with the paywall off too. Nothing else is new while the paywall is off.
    public var showsSubscription: Bool {
        available && (lastAnswer?.paywall == .on || lastAnswer?.offer == true || lastAnswer?.state == .gift)
    }
    /// The free plan's limit on what this computer serves another device (`CloudSubscription.limitsRemoteToSessions`).
    /// Like every payment rule here it holds only on a known answer: no answer, a failed read or an older service
    /// leave everything served as before.
    public var limitsRemoteToSessions: Bool { available && lastAnswer?.limitsRemoteToSessions == true }
    public var wireValue: NativeRPCValue {
        .object([.init("available", .bool(available)), .init("allowsCloudServices", .bool(allowsCloudServices)),
                 .init("showsSubscription", .bool(showsSubscription)), .init("limitsRemoteToSessions", .bool(limitsRemoteToSessions)),
                 .init("lastAnswer", lastAnswer?.wireValue ?? .null)])
    }
}

public enum CloudSubscriptionPage {
    public static let id = "terminal-deck-cloud"
    public static let title = "Terminal Deck Cloud"
    /// What the plan adds to a free account, whose sessions on its computers are free already (19 Nov; the phones' lines).
    public static let benefit = "Browser, simulators and screen sharing, Cloud sync and tasks on every device, and 100 GB of Cloud storage."
    public static let price = "$8.00 a month or $67.00 a year. 100 GB included."
    public static let subscribe = "Subscribe in the Terminal Deck app on your phone"
    public static func rowValue(_ value: CloudSubscription) -> String {
        let plan = value.plan?.rawValue.capitalized ?? (value.state == .none ? "Not subscribed" : value.state.rawValue.capitalized)
        guard let until = value.paidUntil else { return plan }
        return plan + " · " + Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
}

/// Both MCP doors and static navigation read the same per-process offer projection. A no-account launch starts off.
/// Updating it changes discovery only; no transport, session, file, trust or sync setting is touched.
public final class CloudSubscriptionOffers: @unchecked Sendable {
    public static let shared = CloudSubscriptionOffers()
    private let lock = NSLock()
    private var snapshot: CloudSubscriptionSnapshot = .init()
    private var limitWatchers: [String: @Sendable (Bool) -> Void] = [:]
    public init() {}
    public func update(_ value: CloudSubscriptionSnapshot) {
        let (was, now, watchers) = lock.withLock { () -> (Bool, Bool, [@Sendable (Bool) -> Void]) in
            let was = snapshot.limitsRemoteToSessions
            snapshot = value
            return (was, value.limitsRemoteToSessions, Array(limitWatchers.values))
        }
        // Told outside the lock, and only on a change: the plan read that made it free (or paid again).
        if was != now { for watcher in watchers { watcher(now) } }
    }
    /// 19 Nov free plan: `handler` hears each change of `limitsRemoteToSessions` (true: the plan became free). One
    /// watcher per owner; a later one replaces it, nil removes it.
    public func watchRemoteLimit(owner: String, _ handler: (@Sendable (Bool) -> Void)?) {
        lock.withLock { limitWatchers[owner] = handler }
    }
    /// 19 Nov free plan: the tools for other computers' sessions (look, start, send, Hoot there, a file into a session
    /// there) stay with a free account, as its sessions do. Ports, managing machines and the rest stay paid.
    public static let freeAccountTools: Set<String> = ["machines.look", "machines.session", "machines.copilot", "machines.upload"]
    public func showsTool(_ id: String) -> Bool {
        if id == "cloud.subscription" { return lock.withLock { snapshot.showsSubscription } }
        let paid = (id.hasPrefix("cloud.") || id.hasPrefix("machines.") || id.hasPrefix("remote.")
            || id.hasPrefix("phone.") || ["devices.page", "devices.remove", "devices.rename", "ai_apps.internet"].contains(id))
        guard paid else { return true }
        return lock.withLock {
            snapshot.offers(.cloudTools) || Self.freeAccountTools.contains(id) && snapshot.offers(.otherComputerSessions)
        }
    }
    /// 19 Nov free plan: this computer serves another device sessions only (`BackendRemoteFreePlan`). False while the
    /// answer is not known and in a process that never reads it (the session host's sign-in screen helper).
    public var limitsRemoteToSessions: Bool { lock.withLock { snapshot.limitsRemoteToSessions } }
    public func showsCommand(_ id: String) -> Bool {
        // The Devices page stays with a free account (19 Nov free plan); joining by code stays paid.
        if ["devices", "settings:devices"].contains(id) { return lock.withLock { snapshot.offers(.devices) } }
        let paid = ["app.join", "join-remote", "cloud", "cloud-page", "settings:cloud"].contains(id)
            || id.hasPrefix("cloud-session:") || id.hasPrefix("cloud-earlier:")
        return !paid || lock.withLock { snapshot.offers(.pairing) }
    }
}
