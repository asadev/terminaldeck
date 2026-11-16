import Foundation
import TerminalDeckNativeCore

/// TS remote/relay-mcp.ts RelayMcpSwitchboard: the relay's MCP door answers through
/// the core's security server only while the core has installed it; otherwise the
/// shared not-found answer. `facts` is the relay link for the AI-apps page.
public actor BackendCompositionRelaySwitchboard: BackendDeckCoreRelayInstallation {
    private var server: BackendDeckCoreSecurityServer?
    private var link: (@Sendable () async -> BackendRemoteRelayState?)?
    private var watching: (keys: BackendDeckCoreSecurityAccessKeys, id: UUID)?
    private let serving: BackendRelayMCPServing
    public init(serving: BackendRelayMCPServing = .shared) { self.serving = serving }
    /// 15 Nov: installing the core's server also tells the relay clients whether to serve, now and on every switch change.
    public func install(_ server: BackendDeckCoreSecurityServer?) async throws {
        if let old = watching { await old.keys.removeObserver(old.id); watching = nil }
        self.server = server
        if let keys = server?.keys?.keys {
            let serving = self.serving
            watching = (keys, await keys.onChange { Task { await serving.changed() } })
        }
        await serving.changed()
    }
    /// "Let AI apps use this Mac" is on and the key door is open: the relay may forward to this Mac.
    public func isServing() async -> Bool {
        guard let door = server?.keys else { return false }
        return await door.serving()
    }
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
        let answer = await server.answerRelayMarked(authorization: head.authorization, pathKey: head.pathKey,
            userAgent: head.userAgent, protocolVersion: head.protocolVersion, body: body, cancellation: BackendMCPCancellation())
        return .init(status: answer.response.status, contentType: answer.response.headers["content-type"], body: answer.response.body, refused: answer.refused)
    }
}
