extension RendezvousIdentity: Sendable {}

public struct BackendRendezvousIdentity: Sendable {
    public let hostID: String
    public let keys: BackendSealedIdentity
}

public enum BackendRendezvous {
    public static func derive(_ typedCode: String) async throws -> BackendRendezvousIdentity {
        guard let identity = await Rendezvous.identity(for: typedCode) else { throw BackendSealedFailure.authentication }
        return BackendRendezvousIdentity(hostID: identity.hostId, keys: try BackendSealedIdentity(privateKey: identity.keys.privateKey))
    }
    public static func normalize(_ value: String) -> String? { PairingCodeParser.normalise(value) }
}
