import Foundation
import TerminalDeckNativeCore

public struct BackendCloudAccountPorts: Sendable {
    public let transport: any CloudTransportPort
    public let outbox: any CloudOutboxPort
    public let seal: @Sendable () async -> Void
    /// This Mac's trusted-device list for the signed-in account (lean scope item 4). nil only where a fixture has none.
    public let trust: BackendCloudTrustStore?
    public init(transport: any CloudTransportPort, outbox: any CloudOutboxPort, trust: BackendCloudTrustStore? = nil,
                seal: @escaping @Sendable () async -> Void = {}) {
        self.transport = transport; self.outbox = outbox; self.trust = trust; self.seal = seal
    }
}

/// Auth must exist before subject-scoped SYNC storage. This binds the real SYNC ports
/// after exchange; it is neither a transport implementation nor another data writer.
public actor BackendCloudAccountBinding {
    private let identity: BackendCloudAccountIdentity
    private let make: @Sendable (CloudAuthSession, CloudDeviceRegistration) async throws -> BackendCloudAccountPorts
    private var bound: (subject: String, device: String, ports: BackendCloudAccountPorts)?
    private var creating: Task<BackendCloudAccountPorts, Error>?
    public init(identity: BackendCloudAccountIdentity,
                make: @escaping @Sendable (CloudAuthSession, CloudDeviceRegistration) async throws -> BackendCloudAccountPorts) {
        self.identity = identity; self.make = make
    }
    public func resolve() async throws -> BackendCloudAccountPorts {
        let session = try await identity.credentials(), device = try await identity.deviceRegistration()
        if let bound, bound.subject == session.user.id, bound.device == device.deviceId { return bound.ports }
        if let creating { return try await creating.value }
        if let bound { try? await bound.ports.outbox.setPaused(true); await bound.ports.transport.stop(); await bound.ports.seal(); self.bound = nil }
        let task = Task {
            let ports = try await make(session, device)
            return try await self.finish(ports, session: session, device: device)
        }
        creating = task
        defer { creating = nil }
        return try await task.value
    }
    private func finish(_ ports: BackendCloudAccountPorts, session: CloudAuthSession, device: CloudDeviceRegistration) async throws -> BackendCloudAccountPorts {
        let current = try await identity.credentials(), currentDevice = try await identity.deviceRegistration()
        guard current.user.id == session.user.id, currentDevice.deviceId == device.deviceId else {
            try? await ports.outbox.setPaused(true); await ports.transport.stop(); await ports.seal()
            throw CloudFailure.gateClosed
        }
        bound = (session.user.id, device.deviceId, ports)
        return ports
    }
}
