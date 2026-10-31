import Foundation
import TerminalDeckNativeCore

// Accounts at every level (ACCOUNTS-SPEC.md, Asad 11 Oct): Whole Terminal Deck → Project →
// Seat → one Session. Each level is "Same as above" (nothing stored) or a named account, per
// AI. The lowest level that names one wins. Only account ids live here; logins stay in the vault.

/// One of the three levels that can be set (the fourth, a session, is the session's own choice).
public enum BackendAccountLevel: Equatable, Hashable, Sendable {
    case app
    /// A project's folder (canonical path). A session in or below it belongs to it.
    case project(path: String)
    /// A seat's stable key (`AGTSeat.key`: `orchestrator`, `lead:<project>`, `role:<project>/<role>`).
    case seat(key: String)

    public init?(wire: NativeRPCValue) {
        switch wire["kind"].string {
        case "app": self = .app
        case "project":
            guard let path = wire["path"].string, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
            self = .project(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        case "seat":
            guard let key = wire["key"].string, BackendAccountLevel.validSeatKey(key) else { return nil }
            self = .seat(key: key)
        default: return nil
        }
    }
    public var wire: NativeRPCValue {
        switch self {
        case .app: .object([.init("kind", .string("app"))])
        case .project(let path): .object([.init("kind", .string("project")), .init("path", .string(path))])
        case .seat(let key): .object([.init("kind", .string("seat")), .init("key", .string(key))])
        }
    }
    public static func validSeatKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 300 && !key.contains("\0") && !key.contains("\n")
            && (key == "orchestrator" || key.hasPrefix("lead:") || key.hasPrefix("role:"))
    }
}

/// Where the account a session uses comes from.
public enum BackendAccountSource: String, Sendable, Equatable {
    /// Chosen for this one session.
    case session
    case seat, project, app
    /// Nothing is set anywhere: the AI's own login on this Mac.
    case system
}

public struct BackendAccountEffective: Sendable, Equatable {
    public let profile: BackendAccountProfile
    public let source: BackendAccountSource
    /// The project folder or the seat key the choice was made on (nil for app / session / system).
    public let sourceKey: String?
    public var wire: NativeRPCValue {
        .object([.init("accountId", .string(profile.id)), .init("name", .string(profile.name)), .init("provider", .string(profile.provider)),
                 .init("source", .string(source.rawValue)), .init("sourceKey", sourceKey.map(NativeRPCValue.string) ?? .null)])
    }
}

/// Every stored choice, for the Settings page: provider → account id at each level.
public struct BackendAccountLevelsSnapshot: Sendable, Equatable {
    public var app: [String: String] = [:]
    public var projects: [String: [String: String]] = [:]
    public var seats: [String: [String: String]] = [:]
    public init(app: [String: String] = [:], projects: [String: [String: String]] = [:], seats: [String: [String: String]] = [:]) {
        self.app = app; self.projects = projects; self.seats = seats
    }
    private static func object(_ map: [String: String]) -> NativeRPCValue {
        .object(map.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) })
    }
    private static func nested(_ map: [String: [String: String]]) -> NativeRPCValue {
        .object(map.sorted { $0.key < $1.key }.map { .init($0.key, object($0.value)) })
    }
    public var wire: NativeRPCValue {
        .object([.init("app", Self.object(app)), .init("projects", Self.nested(projects)), .init("seats", Self.nested(seats))])
    }

    /// The longest project folder that contains `path` and names an account for `provider`.
    public func project(containing path: String?, provider: String) -> (path: String, id: String)? {
        guard let path, path.hasPrefix("/") else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: (path: String, id: String)?
        for (folder, choices) in projects {
            guard let id = choices[provider] else { continue }
            let prefix = folder == "/" ? "/" : folder + "/"
            guard target == folder || target.hasPrefix(prefix) else { continue }
            if best == nil || folder.count > best!.path.count { best = (folder, id) }
        }
        return best
    }
}

/// The live Claude model list, fetched with a login Terminal Deck keeps itself (ACCOUNTS-SPEC 3:
/// "the app holds the logins, not the Mac"). The app installs the asker; the answer carries only
/// Anthropic's public list, never a login.
public enum BackendAccountModelList {
    public enum Answer: Sendable {
        /// This Mac's own Claude Code login is the account in effect (or the app keeps no Claude
        /// login at all): there is no list. That login is Claude Code's own and is never read.
        case system
        /// The list, fetched beside the app's own store with a login kept there.
        case body(Data)
        /// The app keeps Claude logins and the list could not be fetched with one of them. Never
        /// a reason to use this Mac's login instead.
        case failure(String)
    }
    public typealias Asker = @Sendable () async -> Answer
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asker: Asker?

    public static func install(_ next: @escaping Asker) {
        lock.lock(); defer { lock.unlock() }
        asker = next
    }
    private static func current() -> Asker? { lock.lock(); defer { lock.unlock() }; return asker }
    /// nil when nothing is installed (tests, tools outside the app): the caller behaves as before.
    public static func ask() async -> Answer? { await current()?() }
}
