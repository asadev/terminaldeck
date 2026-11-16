import Foundation

public struct CloudBrowserCookie: Codable, Equatable, Sendable {
    public enum SameSite: String, Codable, Sendable { case unspecified, lax, strict, none }
    public let profileId: String
    public let domain: String
    public let path: String
    public let name: String
    public let value: String
    public let partitionKey: String?
    public let hostOnly: Bool
    public let httpOnly: Bool
    public let secure: Bool
    public let sameSite: SameSite
    public let expires: Double?
    public let session: Bool
    public init(profileId: String, domain: String, path: String, name: String, value: String, partitionKey: String? = nil,
                hostOnly: Bool, httpOnly: Bool, secure: Bool, sameSite: SameSite, expires: Double?, session: Bool) {
        self.profileId = profileId; self.domain = domain; self.path = path; self.name = name; self.value = value
        self.partitionKey = partitionKey; self.hostOnly = hostOnly; self.httpOnly = httpOnly; self.secure = secure
        self.sameSite = sameSite; self.expires = expires; self.session = session
    }
    public var host: String { String(domain.lowercased().drop(while: { $0 == "." })) }
    /// Match existing migration: a host-only/domain-only difference is a conflict,
    /// never permission to replace the destination's signed-in cookie.
    public var identity: String {
        let fields = [profileId, host, path, name, partitionKey ?? ""]
        return CloudSecretsCrypto.hash(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
    public func validate() throws {
        guard !profileId.isEmpty, !host.isEmpty, path.hasPrefix("/"), hostOnly == !domain.hasPrefix("."),
              !name.contains(where: { $0.isNewline || $0 == ";" || $0 == "=" }), !value.contains(where: { $0.isNewline || $0 == ";" }),
              !host.contains(where: { $0.isWhitespace || "/:@?#\\".contains($0) }),
              expires?.isFinite != false, session == (expires == nil), sameSite != .none || secure,
              !name.hasPrefix("__Secure-") || secure,
              !name.hasPrefix("__Host-") || secure && hostOnly && path == "/" else { throw CloudFailure.invalidRequest }
    }
    public func sameAttributes(as other: Self) -> Bool {
        profileId == other.profileId && domain.lowercased() == other.domain.lowercased() && path == other.path && name == other.name
            && value == other.value && partitionKey == other.partitionKey && hostOnly == other.hostOnly && httpOnly == other.httpOnly
            && secure == other.secure && sameSite == other.sameSite && session == other.session
            && ((expires == nil && other.expires == nil) || (expires != nil && other.expires != nil && abs(expires! - other.expires!) < 1))
    }
}
public extension TerminalDeckCookieMigration.Cookie {
    init(cloud: CloudBrowserCookie) throws {
        try cloud.validate()
        guard cloud.partitionKey == nil, let site = TerminalDeckCookieMigration.SameSite(rawValue: cloud.sameSite.rawValue) else { throw CloudFailure.unsupportedFormat }
        self.init(host: cloud.host, domainCookie: !cloud.hostOnly, name: cloud.name, value: cloud.value, path: cloud.path,
                  expires: cloud.expires.map(Date.init(timeIntervalSince1970:)), secure: cloud.secure, httpOnly: cloud.httpOnly, sameSite: site)
    }
}
public struct CloudBrowserCoverage: Codable, Equatable, Sendable {
    /// Shown wherever browser sign-ins are switched on or listed: sharing a
    /// site's cookies means two Macs hold the same sign-in.
    public static let renewalNotice = "A site that renews its sign-in can sign one of your devices out."
    public let cookies: Int
    public let passwords: Int
    public let needsSignIn: Int
    public let expired: Int
    public let conflicts: Int
    public init(cookies: Int, passwords: Int, needsSignIn: Int, expired: Int, conflicts: Int) {
        self.cookies = cookies; self.passwords = passwords; self.needsSignIn = needsSignIn; self.expired = expired; self.conflicts = conflicts
    }
}
public protocol CloudBrowserCookiePort: Sendable {
    func cookies(profileId: String) async throws -> [CloudBrowserCookie]
    /// Existing owner serializes with navigation and rejects writes to active profiles.
    func insertKeepingLocal(_ cookie: CloudBrowserCookie) async throws -> CloudApplyStatus
    func needsSignInSites(profileId: String) async throws -> Set<String>
}
public actor CloudBrowserCookieStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I22"
    public nonisolated let domain = CloudSecretsDomain.browserCookies
    private let profileId: String
    private let store: any CloudBrowserCookiePort
    private let now: @Sendable () -> Double
    private var expired = 0, conflicts = 0
    public init(sourceId: String, profileId: String, store: any CloudBrowserCookiePort,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.sourceId = sourceId; self.profileId = profileId; self.store = store; self.now = now
    }
    public func capture() async throws -> [CloudSecretRecord] {
        try await store.cookies(profileId: profileId).filter { $0.expires.map { $0 > now() } ?? true }.map { cookie in
            try cookie.validate()
            guard cookie.profileId == profileId else { throw CloudFailure.invalidRequest }
            return .init(sourceId: sourceId, recordId: cookie.identity, domain: domain.rawValue,
                         payload: .init(try NativeRPCValue.parseJSON(JSONEncoder().encode(cookie))))
        }
    }
    private func cookie(_ record: CloudSecretRecord) throws -> CloudBrowserCookie {
        guard record.sourceId == sourceId, record.domain == domain.rawValue else { throw CloudFailure.invalidRequest }
        let cookie = try CloudWire.decode(CloudBrowserCookie.self, from: CloudSecretsCanonical.encode(record.payload))
        guard cookie.profileId == profileId, cookie.identity == record.recordId,
              try CloudSecretsCanonical.encode(cookie) == CloudSecretsCanonical.encode(record.payload) else { throw CloudFailure.invalidRequest }
        try cookie.validate()
        return cookie
    }
    public func validate(_ record: CloudSecretRecord) async throws {
        guard try cookie(record).partitionKey == nil else { throw CloudFailure.unsupportedFormat }
    }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let cookie = try cookie(record)
        if cookie.expires.map({ $0 <= now() }) == true { expired += 1; return .alreadyPresent }
        let outcome = try await store.insertKeepingLocal(cookie)
        if outcome == .keptBoth { conflicts += 1 }
        return outcome
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let cookie = try cookie(record)
        if cookie.expires.map({ $0 <= now() }) == true { return true }
        if outcome == .keptBoth { return true } // incoming ciphertext is kept by SYNC's durable prepare journal
        return try await store.cookies(profileId: profileId).contains { $0.sameAttributes(as: cookie) }
    }
    public func coverage() async throws -> CloudBrowserCoverage {
        .init(cookies: try await store.cookies(profileId: profileId).count, passwords: 0,
              needsSignIn: try await store.needsSignInSites(profileId: profileId).count, expired: expired, conflicts: conflicts)
    }
}
