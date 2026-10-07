import Foundation
import TerminalDeckNativeCore

/// Minted by the serving trust/session layer, never decoded from tool arguments.
public struct BackendBrowserPrincipal: Sendable {
    public let ownerID: String
    public let sessionID: String?
    public let machineID: String
    public let managesWindows: Bool
    public let evaluatesScripts: Bool
    /// A session launched by a paired device must always serve browser verbs
    /// on that originating device, even if this Mac happens to hold a window.
    public let routesToOriginatingDevice: Bool
    public init(ownerID: String, sessionID: String? = nil, machineID: String = "",
                managesWindows: Bool = false, evaluatesScripts: Bool = false, routesToOriginatingDevice: Bool = false) {
        self.ownerID = ownerID; self.sessionID = sessionID; self.machineID = machineID
        self.managesWindows = managesWindows; self.evaluatesScripts = evaluatesScripts
        self.routesToOriginatingDevice = routesToOriginatingDevice
    }
    public var session: BrowserDriverSession? {
        sessionID.map { BrowserDriverSession(sessionId: $0, machineId: machineID) }
    }
}

public struct BackendBrowserAccess: Sendable {
    public let tool: String
    public let principal: BackendBrowserPrincipal
    public let tabID: String?
    public let profileID: String?
    public let origin: String?
    public let tier: BackendMCPTier
    public let targetSession: BrowserDriverSession?
    public let resourcePath: String?
    public let arguments: NativeRPCValue
    public init(tool: String, principal: BackendBrowserPrincipal, tabID: String? = nil,
                profileID: String? = nil, origin: String? = nil, tier: BackendMCPTier, targetSession: BrowserDriverSession? = nil, resourcePath: String? = nil, arguments: NativeRPCValue = .missing) {
        self.tool = tool; self.principal = principal; self.tabID = tabID
        self.profileID = profileID; self.origin = origin; self.tier = tier
        self.targetSession = targetSession
        self.resourcePath = resourcePath
        self.arguments = arguments
    }
}

/// Only the app process can supply the live WKWebViews. No helper creates a
/// second profile jar or launches a browser behind the person's back.
@MainActor
public protocol BackendBrowserRuntime: BrowserDriverHost {
    func pageState(_ tabID: String) throws -> NativeRPCValue
    func pageCommand(_ tabID: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue
    func frameCommand(_ tabID: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue
    func dataCommand(_ operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue
    func revealScreenshot(_ path: String) throws
    func createProfileTab(url: URL, isolated: Bool, profileID: String) -> String
}

public enum BackendBrowserOrigin {
    public static func exact(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        let safeHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(safeHost):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    public static func isPrivate(_ text: String) -> Bool {
        guard let host = URL(string: text)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || ["::1", "[::1]"].contains(host) { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
}
