import Foundation
import TerminalDeckNativeCore

/// Retained per-connection cleanup for the native_bundle endpoints. Registration
/// only installs a multicast hook; it starts no host, socket or endpoint owner.
public actor BackendRemoteServeConnectionTeardown {
    private enum TunnelOwner: Sendable {
        case facade(BackendRemoteGuestTunnelHost)
        case transport(BackendRemoteServeTransport)
        var identity: ObjectIdentifier {
            switch self {
            case .facade(let service): ObjectIdentifier(service.transport)
            case .transport(let service): ObjectIdentifier(service)
            }
        }
        func close(_ connectionID: UUID) async {
            switch self {
            case .facade(let service): await service.close(connectionID: connectionID)
            case .transport(let service): await service.connectionClosed(connectionID)
            }
        }
        func stop() async {
            switch self {
            case .facade(let service): await service.stop()
            case .transport(let service): await service.stop()
            }
        }
        func list(_ connectionID: UUID) async -> [BackendRemoteServeTransportTunnelInfo] {
            switch self {
            case .facade(let service): await service.list(connectionID: connectionID)
            case .transport(let service): await service.list(connectionID: connectionID)
            }
        }
    }
    private let uploads: BackendUploadReceive?
    private let tunnelOwners: [TunnelOwner]
    private var subscription: NativeRPCSubscription?
    private var rowsSubscription: NativeRPCSubscription?
    private var stopped = false
    private var stopping: Task<Void, Never>?

    private init(uploads: BackendUploadReceive?, tunnelOwners: [TunnelOwner]) {
        self.uploads = uploads; self.tunnelOwners = tunnelOwners
    }

    /// Pass the endpoint instances retained by native_bundle's composition.
    /// A facade and its transferred transport are one owner and are deduplicated.
    public static func join(host: BackendRemoteHost, uploads: BackendUploadReceive? = nil,
                            tunnels: BackendRemoteGuestTunnelHost? = nil,
                            retainedTransport: BackendRemoteServeTransport? = nil) async throws -> BackendRemoteServeConnectionTeardown {
        var owners: [TunnelOwner] = []
        if let tunnels { owners.append(.facade(tunnels)) }
        if let retainedTransport {
            let owner = TunnelOwner.transport(retainedTransport)
            if !owners.contains(where: { $0.identity == owner.identity }) { owners.append(owner) }
        }
        guard uploads != nil || !owners.isEmpty else {
            throw NativeRPCError(code: "unavailable", message: "No native upload or tunnel endpoint was supplied for connection teardown.")
        }
        let owner = BackendRemoteServeConnectionTeardown(uploads: uploads, tunnelOwners: owners)
        let subscription = await host.addConnectionClosedHandler { [weak owner] connectionID in
            guard let owner else { return }
            await owner.connectionClosed(connectionID)
        }
        let rowsSubscription: NativeRPCSubscription?
        if owners.isEmpty { rowsSubscription = nil }
        else {
            rowsSubscription = await host.addConnectionRowsProvider { [weak owner] connectionID in
                guard let owner else { throw NativeRPCError(code: "unavailable", message: "The native tunnel metadata owner stopped.") }
                return try await owner.connectionFields(connectionID)
            }
        }
        await owner.retain(subscription, rows: rowsSubscription)
        return owner
    }

    private func retain(_ subscription: NativeRPCSubscription, rows: NativeRPCSubscription?) {
        self.subscription = subscription; rowsSubscription = rows
    }

    /// Only provider-owned tunnel fields cross this seam; the host keeps the
    /// connection/device/session identity and base row as its own authority.
    private func connectionFields(_ connectionID: UUID) async throws -> [NativeRPCValue.Field] {
        guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The native tunnel metadata owner stopped.") }
        var tunnels: [BackendRemoteServeTransportTunnelInfo] = []
        for owner in tunnelOwners { tunnels += await owner.list(connectionID) }
        guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The native tunnel metadata owner stopped.") }
        return [.init("tunnels", .array(tunnels.sorted { $0.openedAt < $1.openedAt }.map(\.value)))]
    }

    /// UUID comes from the host's actual close event, including unauthenticated
    /// sockets. Cleanup never waits for a device's final connection to disappear.
    private func connectionClosed(_ connectionID: UUID) async {
        guard !stopped else { return }
        await uploads?.close(connectionID: connectionID)
        for owner in tunnelOwners {
            guard !stopped else { return }
            await owner.close(connectionID)
        }
    }

    /// Remove this contribution first, then drain only the endpoints passed to
    /// this adapter. The shared host, machine coordinator and PTY owner stay up.
    public func stop() async {
        if let stopping { await stopping.value; return }
        stopped = true
        let subscription = self.subscription; self.subscription = nil
        let rowsSubscription = self.rowsSubscription; self.rowsSubscription = nil
        let uploads = self.uploads, tunnelOwners = self.tunnelOwners
        let stopping = Task {
            await subscription?.cancelAndWait()
            await rowsSubscription?.cancelAndWait()
            await uploads?.stop()
            for owner in tunnelOwners { await owner.stop() }
        }
        self.stopping = stopping
        await stopping.value
    }
}
