import TerminalDeckNativeCore

/// Concrete registration join over the authoritative endpoint. The endpoint
/// retains all connections, attachments, feature leases and permission state.
/// Construction is inert; installation and teardown remain explicit host calls.
public struct BackendRemoteServeRegistrationHostAdapter: BackendRemoteServeRegistrationHost {
    public let endpoint: BackendRemoteHost

    public init(endpoint: BackendRemoteHost) { self.endpoint = endpoint }

    public func install(ownerID: String, features: [BackendRemoteHostFeature],
                        suppliers: BackendRemoteServeRegistration.Suppliers,
                        hooks: BackendRemoteServeRegistration.Hooks) async throws -> NativeRPCSubscription {
        try await endpoint.installRemoteServe(ownerID: ownerID, features: features, suppliers: suppliers, hooks: hooks)
    }

    public func connectedDeviceIDs() async -> Set<String> {
        await endpoint.remoteServeConnectedDeviceIDs()
    }

    public func connectionRows() async -> [NativeRPCValue] {
        await endpoint.remoteServeConnectionRows()
    }

    public func dropDevice(_ deviceID: String) async {
        await endpoint.remoteServeDropDevice(deviceID)
    }

    public func foldersChanged(_ deviceID: String) async {
        await endpoint.remoteServeFoldersChanged(deviceID)
    }

    public func askWindows(deviceID: String, message: BackendRemoteServerMessage) async throws -> Int {
        try await endpoint.remoteServeAskWindows(deviceID: deviceID, message: message)
    }

    public func reachesWindows(_ deviceID: String) async -> Bool {
        await endpoint.remoteServeReachesWindows(deviceID)
    }

    public func pushToOwnDevices(_ message: BackendRemoteServerMessage, claiming capability: String) async throws {
        try await endpoint.remoteServePushToOwnDevices(message: message, claiming: capability)
    }
}
