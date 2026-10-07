import Foundation
import TerminalDeckNativeCore

/// TS remote/relay-mcp.ts RelayMcpSwitchboard: the relay's MCP door answers through
/// the core's security server only while the core has installed it; otherwise the
/// shared not-found answer. `facts` is the relay link for the AI-apps page.
public actor BackendCompositionRelaySwitchboard: BackendDeckCoreRelayInstallation {
    private var server: BackendDeckCoreSecurityServer?
    private var link: (@Sendable () async -> BackendRemoteRelayState?)?
    public init() {}
    public func install(_ server: BackendDeckCoreSecurityServer?) async throws { self.server = server }
    /// TS useLink: the host service's relay state, read per call.
    public func useLink(_ link: (@Sendable () async -> BackendRemoteRelayState?)?) { self.link = link }
    public func facts() async -> BackendDeckCoreEventsRelayFacts? {
        guard let state = await link?() else { return nil }
        return .init(url: state.url, hostId: state.hostID, connected: state.connected, reason: state.reason)
    }
    /// TS answer(): nothing installed → MCP_NOT_FOUND (404, the same JSON-RPC sentence the core uses).
    public func answer(_ head: BackendRelayPacketCodec.MCPRequestHead, body: Data) async -> BackendRemoteRelayMCPReply {
        guard let server else {
            return .init(status: 404, contentType: "application/json", body: Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Nothing answered at this address. The computer may be off or not connected, or this link may have been turned off.\"}}".utf8))
        }
        let answer = await server.answerRelay(authorization: head.authorization, pathKey: head.pathKey,
            userAgent: head.userAgent, protocolVersion: head.protocolVersion, body: body, cancellation: BackendMCPCancellation())
        return .init(status: answer.status, contentType: answer.headers["content-type"], body: answer.body)
    }
}
