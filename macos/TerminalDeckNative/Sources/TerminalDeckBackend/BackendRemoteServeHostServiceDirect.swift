import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteServeHostServiceDirectPlan: Sendable {
    public let hosts: [String], url: String, address: String
    public init(hosts: [String], url: String, address: String) { self.hosts = hosts; self.url = url; self.address = address }
}
public struct BackendRemoteServeHostServiceFailure: LocalizedError, Sendable {
    public let message: String
    public let detail: String?
    public init(message: String, detail: String? = nil) { self.message = message; self.detail = detail }
    public var errorDescription: String? { message }
}
public protocol BackendRemoteServeHostServiceDirectAccess: Sendable {
    func plan(port: UInt16) async throws -> BackendRemoteServeHostServiceDirectPlan
    /// The reported URL is authoritative; never rebuild it from a hostname.
    func serve(port: UInt16) async throws -> String
    func stop(port: UInt16) async
}

/// One shared tailnet status/cache/command owner, and the complete Serve parser.
/// Constructing this adapter performs no status query, command or listener bind.
public struct BackendRemoteServeHostServiceDirect: BackendRemoteServeHostServiceDirectAccess {
    private let tailnet: BackendRemoteServeTailnet
    private let serving: BackendRemoteServeTailscale
    public init(tailnet: BackendRemoteServeTailnet) { self.tailnet = tailnet; serving = .init(tailnet: tailnet) }
    public func plan(port: UInt16) async throws -> BackendRemoteServeHostServiceDirectPlan {
        let status = await tailnet.status(force: true)
        let plan = BackendRemoteServeTailnet.directPlan(status, port: Int(port))
        guard plan["ok"].bool == true else {
            throw BackendRemoteServeHostServiceFailure(message: plan["reason"].string ?? "Tailscale did not supply a direct access plan.", detail: status["detail"].string)
        }
        guard let hosts = plan["hosts"].elements?.compactMap(\.string), !hosts.isEmpty, hosts.allSatisfy({ !$0.isEmpty }),
              let url = plan["url"].string, !url.isEmpty, let address = plan["address"].string, !address.isEmpty else {
            throw BackendRemoteServeHostServiceFailure(message: "Tailscale returned an incomplete direct access plan.")
        }
        return .init(hosts: hosts, url: url, address: address)
    }
    public func serve(port: UInt16) async throws -> String {
        let result = await serving.serveOn(httpsPort: Int(port), localPort: Int(port))
        guard result["ok"].bool == true else {
            throw BackendRemoteServeHostServiceFailure(message: result["message"].string ?? "Tailscale did not report the direct proxy's outcome.", detail: result["detail"].string)
        }
        guard let url = result["url"].string, !url.isEmpty else {
            throw BackendRemoteServeHostServiceFailure(message: "Tailscale accepted the proxy but did not report a URL for it.")
        }
        return url
    }
    public func stop(port: UInt16) async { await serving.serveOff(httpsPort: Int(port)) }
}
extension BackendRemoteServeTailnet: BackendRemoteServeHostServiceDirectAccess {
    public func plan(port: UInt16) async throws -> BackendRemoteServeHostServiceDirectPlan { try await BackendRemoteServeHostServiceDirect(tailnet: self).plan(port: port) }
    public func serve(port: UInt16) async throws -> String { try await BackendRemoteServeHostServiceDirect(tailnet: self).serve(port: port) }
    public func stop(port: UInt16) async { await BackendRemoteServeHostServiceDirect(tailnet: self).stop(port: port) }
}

/// Compatibility type name now denotes the complete adapter. Its old merged
/// PTY command initializer is retired; use the shared native Tailnet actor.
public typealias BackendRemoteHostTailnet = BackendRemoteServeHostServiceDirect

public struct BackendRemoteServeHostServiceListenerState: Sendable {
    public let listening: Bool
    public let reason: String?
    public init(listening: Bool, reason: String? = nil) { self.listening = listening; self.reason = reason }
}
public protocol BackendRemoteServeHostServiceListening: Sendable {
    func start(port: UInt16) async throws -> UInt16
    func state() async -> BackendRemoteServeHostServiceListenerState
    func stop() async
}
extension BackendRemoteHostListener: BackendRemoteServeHostServiceListening {}

public protocol BackendRemoteServeHostServiceRelaying: Sendable {
    func start() async
    func state() async -> BackendRemoteRelayState
    func stop() async
}
extension BackendRemoteRelayClient: BackendRemoteServeHostServiceRelaying {}
