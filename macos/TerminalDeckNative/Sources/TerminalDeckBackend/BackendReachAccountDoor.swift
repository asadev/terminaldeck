import Foundation

/// The machine's answer to a reach device's first sealed frame (design section 2, "End-to-end key"). Same Noise IK
/// handshake as a paired device today (`BackendSealedHost`), so the relay sees nothing of the session; the only
/// difference is WHICH keys are accepted: the account roster's, judged by `BackendReachAccountGate`. The reply is
/// handed back only after the gate admits the device, so a refused device never gets a working channel.
///
/// `BackendRemoteRelayClient.channelData` calls this ONLY for a channel the relay marked as an account channel
/// (R2 decision 1); an unmarked channel never reaches it, and a marked one never reaches the paired-key path.
public struct BackendReachAccountDoor: Sendable {
    public let gate: BackendReachAccountGate
    public init(gate: BackendReachAccountGate) { self.gate = gate }

    public struct Opened: Sendable {
        /// Send this back on the channel (already carries the sealed version byte).
        public let reply: Data
        public let transport: BackendSealedTransport
        public let admission: BackendReachAdmission
    }

    /// Throws `BackendReachFailure.refused` for every refusal; the caller closes the channel and says nothing more.
    /// `marked`: the device id from the relay's open mark; the key that finished the handshake must be that device's.
    public func answer(identity: BackendSealedIdentity, frame: Data, marked: String? = nil) async throws -> Opened {
        guard await gate.settings().enabled else { throw BackendReachFailure.refused(.switchOff) }
        let keys = await gate.candidateKeys()
        guard !keys.isEmpty else { throw BackendReachFailure.refused(.unknownDevice) }
        let response: BackendSealedResponse
        do {
            response = try BackendSealedHost.respondRelayFrame(identity: identity, frame: frame, approvedKeys: keys, permitUnknownPeer: false)
        } catch {
            throw BackendReachFailure.refused(.unknownDevice)
        }
        switch await gate.admit(key: response.devicePublicKey, marked: marked) {
        case .refused(let why): throw BackendReachFailure.refused(why)
        case .admitted(let admission): return Opened(reply: response.reply, transport: response.transport, admission: admission)
        }
    }
}

/// Publishes this machine for its account while reach is on, and withdraws it when it is not (design section 1:
/// a machine appears only while signed in, entitled, running and switched on). The coordinator calls `sync()` every
/// 60 seconds, on sign-in/out and when the switch changes. The relay room is tied with a relay token only while
/// published; the token is renewed when less than five minutes of it are left.
public actor BackendReachPresence {
    public enum Status: String, Sendable, Equatable { case off, signedOut, notEntitled, notRegistered, published, failed }
    public struct HostCard: Sendable { public let hostId: String; public let hostKey: String; public let name: String
        public init(hostId: String, hostKey: String, name: String) { self.hostId = hostId; self.hostKey = hostKey; self.name = name } }
    static let tokenRenewMs = 300_000.0

    private let gate: BackendReachAccountGate
    private let service: any BackendReachAccountService
    private let relay: any BackendReachRelayDoor
    private let host: @Sendable () async -> HostCard?
    private let now: @Sendable () -> Double
    private var publishedAs: String?
    private var token: BackendReachRelayToken?
    public private(set) var last: Status = .off

    public init(gate: BackendReachAccountGate, service: any BackendReachAccountService, relay: any BackendReachRelayDoor,
                host: @escaping @Sendable () async -> HostCard?,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }) {
        self.gate = gate; self.service = service; self.relay = relay; self.host = host; self.now = now
    }

    @discardableResult
    public func sync() async -> Status {
        last = await decide()
        return last
    }

    private func decide() async -> Status {
        let settings = await gate.settings()
        guard settings.enabled else { await withdraw(); return .off }
        guard await service.signedInAccount() != nil else { await withdraw(); return .signedOut }
        guard await gate.entitledNow() == true else { await withdraw(); return .notEntitled }
        guard let deviceId = await service.machineDeviceId(), let card = await host() else { await withdraw(); return .notRegistered }
        do {
            if token == nil || token!.expiresAtMs - now() < Self.tokenRenewMs {
                let fresh = try await service.relayToken()
                token = fresh
                try await relay.attachAccount(fresh)
            }
            publishedAs = deviceId   // from here a later withdraw also unties the relay room
            try await service.publish(.init(deviceId: deviceId, hostId: card.hostId, hostKey: card.hostKey, name: card.name, policy: settings.policy))
            return .published
        } catch {
            return .failed
        }
    }

    /// Off, signed out, not entitled or the app quitting: the record goes and the relay room is untied.
    public func withdraw() async {
        token = nil
        guard let deviceId = publishedAs else { return }
        publishedAs = nil
        await relay.detachAccount()
        try? await service.withdraw(deviceId: deviceId)
    }
}
