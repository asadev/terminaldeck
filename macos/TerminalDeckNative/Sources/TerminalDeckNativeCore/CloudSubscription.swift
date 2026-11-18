import Foundation

/// GET /v1/subscription. Dates are Unix milliseconds; a missing date/plan/source is null.
public struct CloudSubscription: Codable, Sendable, Equatable {
    public enum Paywall: String, Codable, Sendable { case off, on }
    public enum State: String, Codable, Sendable { case paid, gift, none, lapsed }
    public enum Plan: String, Codable, Sendable { case monthly, yearly }
    public enum Source: String, Codable, Sendable { case apple, google, gift }
    public let paywall: Paywall
    public let state: State
    public let plan: Plan?
    public let paidUntil: Int64?
    public let source: Source?
    public let includedGb: Int
    public let extraGb: Int
    public let offer: Bool
    public let dataKeptUntil: Int64?

    public init(paywall: Paywall, state: State, plan: Plan? = nil, paidUntil: Int64? = nil, source: Source? = nil,
                includedGb: Int = 100, extraGb: Int = 0, offer: Bool = false, dataKeptUntil: Int64? = nil) {
        self.paywall = paywall; self.state = state; self.plan = plan; self.paidUntil = paidUntil; self.source = source
        self.includedGb = includedGb; self.extraGb = extraGb; self.offer = offer; self.dataKeptUntil = dataKeptUntil
    }
    public var entitled: Bool { state == .paid || state == .gift }
    public var wireValue: NativeRPCValue {
        .object([.init("paywall", .string(paywall.rawValue)), .init("state", .string(state.rawValue)),
                 .init("plan", plan.map { .string($0.rawValue) } ?? .null),
                 .init("paidUntil", paidUntil.map { .number(Double($0)) } ?? .null),
                 .init("source", source.map { .string($0.rawValue) } ?? .null),
                 .init("includedGb", .number(Double(includedGb))), .init("extraGb", .number(Double(extraGb))),
                 .init("offer", .bool(offer)), .init("dataKeptUntil", dataKeptUntil.map { .number(Double($0)) } ?? .null)])
    }
}

/// The Mac's inventory of paid offers. Local files, SSH, local AI-app keys and WhatsApp are deliberately outside it.
/// Keep this list and RESULT.md together: Windows can use the same inventory and rule.
public enum CloudPaidPlace: String, CaseIterable, Sendable {
    case sidebarCloud, settingsCloud, devices, phoneAndWebReach, pairing, otherComputerSessions, sessionMove
    case remoteMachineChoices, fileManager, syncSwitches, savedPasswords, phonesCopy, aiAppsInternet, cloudTools, projectCloudActions, artifactCloudActions
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
    public func offers(_ place: CloudPaidPlace, existing: Bool = true) -> Bool { existing && allowsCloudServices }
    public var showsSubscription: Bool { available && (lastAnswer?.paywall == .on || lastAnswer?.offer == true) }
    public var wireValue: NativeRPCValue {
        .object([.init("available", .bool(available)), .init("allowsCloudServices", .bool(allowsCloudServices)),
                 .init("showsSubscription", .bool(showsSubscription)), .init("lastAnswer", lastAnswer?.wireValue ?? .null)])
    }
}

public enum CloudSubscriptionPage {
    public static let id = "terminal-deck-cloud"
    public static let title = "Terminal Deck Cloud"
    public static let benefit = "Sync and storage, phone and web apps, and access to your computers from another device."
    public static let price = "$8.00 a month or $67.00 a year. 100 GB included."
    public static let subscribe = "Subscribe in the Terminal Deck app on your iPhone or Android phone"
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
    public init() {}
    public func update(_ value: CloudSubscriptionSnapshot) { lock.withLock { snapshot = value } }
    public func showsTool(_ id: String) -> Bool {
        if id == "cloud.subscription" { return lock.withLock { snapshot.showsSubscription } }
        let paid = (id.hasPrefix("cloud.") || id.hasPrefix("machines.") || id.hasPrefix("remote.")
            || id.hasPrefix("phone.") || ["devices.page", "devices.remove", "devices.rename", "ai_apps.internet"].contains(id))
        return !paid || lock.withLock { snapshot.offers(.cloudTools) }
    }
    public func showsCommand(_ id: String) -> Bool {
        let paid = ["app.join", "join-remote", "devices", "cloud", "cloud-page", "settings:cloud", "settings:devices"].contains(id)
            || id.hasPrefix("cloud-session:") || id.hasPrefix("cloud-earlier:")
        return !paid || lock.withLock { snapshot.offers(.pairing) }
    }
}
