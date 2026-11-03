import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Compatibility facade over the transferred, shared-contract connection
/// hubs. There is one active host transport and one process-wide budget.
public actor BackendRemoteGuestTunnelHost {
    public typealias Push = @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    public nonisolated let transport: BackendRemoteServeTransport
    public init(ownPorts: BackendDevOwnPorts, scan: @escaping @Sendable () async throws -> [BackendDevPort],
                authorize: @escaping @Sendable (Int, BackendRemoteHostContext) async throws -> Bool, push: @escaping Push) {
        transport = BackendRemoteServeTransport(ports: BackendRemoteGuestTunnelPortAdapter(ownPorts: ownPorts, scan: scan, authorize: authorize),
            wire: BackendRemoteServeTransportWireAdapter(send: push))
    }
    public init(ports: any BackendRemoteServeTransportPortSource, wire: any BackendRemoteServeTransportWire,
                sockets: any BackendRemoteServeTransportSocketFactory = BackendRemoteServeTransportTCPFactory(), onChange: @escaping @Sendable () -> Void = {}) {
        transport = BackendRemoteServeTransport(ports: ports, wire: wire, sockets: sockets, onChange: onChange)
    }
    public nonisolated func feature() -> BackendRemoteHostFeature { transport.feature() }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] { try await transport.handle(message, context: context) }
    public func list(connectionID: UUID) async -> [BackendRemoteServeTransportTunnelInfo] { await transport.list(connectionID: connectionID) }
    public func stop(connectionID: UUID, tunnelID: String) async throws -> Bool { try await transport.stop(connectionID: connectionID, tunnelID: tunnelID) }
    public func close(connectionID: UUID) async { await transport.connectionClosed(connectionID) }
    public func stop() async { await transport.stop() }
}

private struct BackendRemoteGuestTunnelPortAdapter: BackendRemoteServeTransportPortSource {
    let ownPorts: BackendDevOwnPorts
    let scan: @Sendable () async throws -> [BackendDevPort]
    let authorize: @Sendable (Int, BackendRemoteHostContext) async throws -> Bool
    func reservedPorts() async -> Set<Int> { Set(await ownPorts.ports()) }
    func permits(port: Int, context: BackendRemoteHostContext) async throws -> Bool {
        let reserved = await reservedPorts()
        guard !reserved.contains(port) else { return false }; return try await authorize(port, context)
    }
    func scan(context: BackendRemoteHostContext) async throws -> [BackendRemoteServeTransportPort] {
        let found = try await scan(); var result: [BackendRemoteServeTransportPort] = []
        for port in found {
            if try await permits(port: port.port, context: context) { result.append(.init(port: port.port, process: port.process, guessed: port.guessed, ipv4: port.ipv4, ipv6: port.ipv6)) }
        }
        return result
    }
}
