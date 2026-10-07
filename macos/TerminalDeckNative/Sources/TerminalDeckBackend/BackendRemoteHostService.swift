import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteHostStatus: Sendable {
    public let running: Bool
    public let directURL: String?
    public let directReason: String?
    public let directDetail: String?
    public let relay: BackendRemoteRelayState?
    public let connections: [BackendRemoteHostConnection]
    public init(running: Bool, directURL: String?, directReason: String?, directDetail: String? = nil,
                relay: BackendRemoteRelayState?, connections: [BackendRemoteHostConnection]) {
        self.running = running; self.directURL = directURL; self.directReason = directReason; self.directDetail = directDetail
        self.relay = relay; self.connections = connections
    }
}

/// Owns direct proxy/listener, relay and temporary pairing rendezvous together.
/// Dependency construction performs no IO; start/stop are explicit operations.
public actor BackendRemoteHostService {
    public typealias ListenerFactory = @Sendable (BackendRemoteHost, [String], URL?) -> any BackendRemoteServeHostServiceListening
    public typealias RelayFactory = @Sendable (String, BackendRemoteHostIdentity, BackendRemoteTrustStore, BackendRemoteHost, BackendRemoteRelayClient.MCPHandler?) throws -> any BackendRemoteServeHostServiceRelaying
    public let endpoint: BackendRemoteHost
    private let ownPorts: BackendDevOwnPorts
    private let relayURL: String?
    private let webRoot: URL?
    private let tailnet: (any BackendRemoteServeHostServiceDirectAccess)?
    private let directPort: UInt16
    private let makeListener: ListenerFactory
    private let makeRelay: RelayFactory
    private let afterEndpointStart: (@Sendable () async throws -> Void)?
    private let hostName: String
    private let mcp: BackendRemoteRelayClient.MCPHandler?
    private var listener: (any BackendRemoteServeHostServiceListening)?
    private var relay: (any BackendRemoteServeHostServiceRelaying)?
    private var relayActivated = false
    private var beacon: BackendRemoteRelayClient?
    private var beaconExpiry: Task<Void, Never>?
    private var directURL: String?
    private var directReason: String?
    private var directDetail: String?
    private var started = false
    private var endpointStarted = false, proxyTouched = false, directPortClaimed = false
    private var generation: UUID?
    private var startFlight: (id: UUID, task: Task<BackendRemoteHostStatus, Error>)?
    private var stopFlight: (id: UUID, task: Task<Void, Never>)?
    public init(endpoint: BackendRemoteHost, ownPorts: BackendDevOwnPorts, relayURL: String?, webRoot: URL?, tailnet: (any BackendRemoteServeHostServiceDirectAccess)?, hostName: String,
                mcp: BackendRemoteRelayClient.MCPHandler? = nil, directPort: UInt16 = 8443,
                afterEndpointStart: (@Sendable () async throws -> Void)? = nil,
                makeListener: @escaping ListenerFactory = { BackendRemoteHostListener(host: $0, allowedHosts: $1, webRoot: $2) },
                makeRelay: @escaping RelayFactory = { try BackendRemoteRelayClient(url: $0, identity: $1, trust: $2, host: $3, mcp: $4) }) {
        self.endpoint = endpoint; self.ownPorts = ownPorts; self.relayURL = relayURL; self.webRoot = webRoot; self.tailnet = tailnet; self.hostName = hostName; self.mcp = mcp
        self.directPort = directPort; self.afterEndpointStart = afterEndpointStart; self.makeListener = makeListener; self.makeRelay = makeRelay
    }
    public func start() async throws -> BackendRemoteHostStatus {
        if let stopping = stopFlight { await stopping.task.value; return try await start() }
        if let pending = startFlight { return try await pending.task.value }
        if started {
            let current = await status()
            if current.running { return current }
            await stop(); return try await start()
        }
        guard directPort > 0 else { throw NativeRPCError.invalidArguments("The direct remote host port must be between 1 and 65535") }
        let id = UUID(); generation = id
        let task = Task { try await self.startOwned(id) }; startFlight = (id, task)
        defer { if startFlight?.id == id { startFlight = nil } }
        return try await task.value
    }
    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
    }
    private func startOwned(_ id: UUID) async throws -> BackendRemoteHostStatus {
        do {
            endpointStarted = true
            try await endpoint.start(); try requireCurrent(id)
            // Assembly can start Registration.Installed after trust opens and
            // before either the direct listener or relay accepts any peer.
            try await afterEndpointStart?(); try requireCurrent(id)
            await endpoint.setPairingSpentHandler { [weak self] in await self?.cancelPairing() }; try requireCurrent(id)
            directURL = nil; directReason = nil; directDetail = nil
            var relayFailure: Error?
            // The relay starts independently before the bounded direct probe.
            if let relayURL {
                do {
                    let identity = try await endpoint.trust.hostIdentity(); try requireCurrent(id)
                    let client = try makeRelay(relayURL, identity, endpoint.trust, endpoint, mcp)
                    relay = client; await client.start(); try requireCurrent(id); relayActivated = true
                } catch { try requireCurrent(id); relayFailure = error }
            }
            if let tailnet {
                do {
                    let plan = try await tailnet.plan(port: directPort); try requireCurrent(id)
                    guard !(await ownPorts.ports()).contains(Int(directPort)) else {
                        throw BackendRemoteServeHostServiceFailure(message: "Port \(directPort) on the tailnet address is already in use by something else on this Mac.")
                    }
                    let directListener = makeListener(endpoint, plan.hosts, webRoot); listener = directListener
                    let bound = try await directListener.start(port: directPort); try requireCurrent(id)
                    guard bound == directPort else { throw BackendRemoteServeHostServiceFailure(message: "The native listener did not bind the requested direct access port.") }
                    // Only release a port this service successfully bound and
                    // claimed; a failed bind cannot erase another owner's mark.
                    directPortClaimed = true; await ownPorts.claim(Int(directPort)); try requireCurrent(id)
                    proxyTouched = true
                    let reportedURL = try await tailnet.serve(port: directPort); try requireCurrent(id)
                    guard !reportedURL.isEmpty else { throw BackendRemoteServeHostServiceFailure(message: "Tailscale accepted the proxy but did not report a URL for it.") }
                    guard (await directListener.state()).listening else { throw BackendRemoteServeHostServiceFailure(message: "The native direct listener stopped before the proxy was ready.") }
                    try requireCurrent(id); directURL = reportedURL
                } catch {
                    try requireCurrent(id)
                    directReason = (error as? BackendRemoteServeHostServiceFailure)?.message ?? error.localizedDescription
                    directDetail = (error as? BackendRemoteServeHostServiceFailure)?.detail
                    await withdrawDirect(); try requireCurrent(id)
                }
            } else { directReason = "No native Tailscale Serve adapter is registered for direct access." }
            if directURL == nil && !relayActivated {
                if let relayFailure { throw relayFailure }
                throw NativeRPCError(code: "remote-unavailable", message: directReason ?? "Neither direct nor relay access is available")
            }
            started = true
            return await status()
        } catch {
            await cleanup()
            if generation == id { generation = nil }
            throw error
        }
    }
    public func status() async -> BackendRemoteHostStatus {
        let direct = await listener?.state()
        let listening = direct?.listening == true && directURL != nil
        return .init(running: listening || relayActivated, directURL: listening ? directURL : nil,
            directReason: directReason ?? (directURL != nil && !listening ? direct?.reason ?? "The direct listener stopped." : nil), directDetail: directDetail,
            relay: await relay?.state(), connections: await endpoint.connections())
    }
    public func stop() async {
        if let stopping = stopFlight { await stopping.task.value; return }
        generation = nil; started = false; relayActivated = false; directURL = nil
        let pending = startFlight?.task; pending?.cancel()
        let binding = listener, dialing = relay, pairing = beacon
        let id = UUID(), task = Task {
            // Cancel an unfinished listener bind before joining startup. Its
            // readiness task is shared and cannot depend on the caller's flag.
            await binding?.stop(); await dialing?.stop(); await pairing?.stop()
            if let pending { _ = await pending.result }
            // Withdraw Serve only after its in-flight call has settled, so a
            // late result cannot re-install a proxy after the final off call.
            await self.cleanup()
        }
        stopFlight = (id, task)
        await task.value
        if stopFlight?.id == id { stopFlight = nil }
    }
    private func withdrawDirect() async {
        let old = listener; listener = nil
        let touched = proxyTouched; proxyTouched = false; directURL = nil
        let claimed = directPortClaimed; directPortClaimed = false
        await old?.stop()
        if touched { await tailnet?.stop(port: directPort) }
        if claimed { await ownPorts.release(Int(directPort)) }
    }
    private func cleanup() async {
        started = false; relayActivated = false
        let oldRelay = relay; relay = nil
        let closeEndpoint = endpointStarted; endpointStarted = false
        await cancelPairing(); await oldRelay?.stop(); await withdrawDirect()
        if closeEndpoint { await endpoint.stop(); await endpoint.setPairingSpentHandler(nil) }
    }
    public func showPairingCode() async throws -> (code: BackendRemotePairingOffer, findable: Bool) {
        guard started, let generation else { throw NativeRPCError(code: "remote-unavailable", message: "Start remote access before pairing a device") }
        await cancelPairing()
        try requireCurrent(generation)
        let code = try await endpoint.trust.createPairingOffer()
        try requireCurrent(generation)
        guard let relayURL else { return (code, false) }
        let hostIdentity = try await endpoint.trust.hostIdentity()
        let offer = NativeRPCValue.object([.init("t", .string("machine")), .init("relayUrl", .string(relayURL)), .init("hostId", .string(hostIdentity.hostID)),
            .init("publicKey", .string(BackendRemoteTrustStorage.base64URL(hostIdentity.keys.publicKey))), .init("name", .string(hostName)), .init("platform", .string("darwin"))])
        let derived = try await Self.rendezvous(code.token)
        try requireCurrent(generation)
        let beacon = try BackendRemoteRelayClient(url: relayURL, identity: derived, beaconOffer: offer.compact)
        self.beacon = beacon
        await beacon.start()
        try requireCurrent(generation)
        let findable = await beacon.ready()
        try requireCurrent(generation)
        if !findable { await beacon.stop(); self.beacon = nil }
        let remaining = max(0, code.expiresAt - Date().timeIntervalSince1970 * 1000)
        beaconExpiry = Task { [weak self] in try? await Task.sleep(for: .milliseconds(Int(remaining))); guard !Task.isCancelled else { return }; await self?.cancelPairing() }
        return (code, findable)
    }
    public func cancelPairing() async {
        beaconExpiry?.cancel(); beaconExpiry = nil
        await beacon?.stop(); beacon = nil
        await endpoint.trust.cancelPairing()
    }
    private static func rendezvous(_ code: String) async throws -> BackendRemoteHostIdentity {
        guard let normalized = BackendRendezvous.normalize(code) else { throw BackendSealedFailure.authentication }
        return try await Task.detached(priority: .utility) {
            let seed = try BackendPairingDerivation.scrypt(password: Data(normalized.utf8), salt: Data("terminaldeck-machine-pairing-v1".utf8), n: 16384, r: 8, p: 1, length: 64)
            return BackendRemoteHostIdentity(hostSecret: Data(seed.prefix(32)), keys: try BackendSealedIdentity(privateKey: Data(seed.suffix(32))))
        }.value
    }
}
