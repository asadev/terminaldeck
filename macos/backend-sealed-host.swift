// Appended to the existing Swift sealed-channel source by the assembler.
// Kept in the same generated file so the original private primitives stay
// private and the iOS implementation remains the shared source of truth.

extension StaticKeyPair: Sendable {}
extension PendingHandshake: Sendable {}

public enum BackendSealedFailure: Error, Sendable {
    case authentication, length, version, exhausted
}

public struct BackendSealedIdentity: Sendable {
    public let privateKey: Data
    public let publicKey: Data
    public init(privateKey: Data) throws {
        guard let key = StaticKeyPair(privateKey: privateKey) else { throw BackendSealedFailure.authentication }
        self.privateKey = key.privateKey
        self.publicKey = key.publicKey
    }
    public static func generate() -> Self {
        let key = StaticKeyPair.generate()
        return try! Self(privateKey: key.privateKey)
    }
    public var fingerprint: String { sealedFingerprint(publicKey) }
}

/// One actor owns both counters, so concurrent callers cannot reuse a nonce.
public actor BackendSealedTransport {
    private let inner: SealedTransport
    public nonisolated let channelBinding: Data
    fileprivate init(_ inner: sending SealedTransport) {
        self.inner = inner
        channelBinding = inner.channelBinding
    }
    public func send(_ data: Data) throws -> Data {
        do { return try inner.send(data) } catch { throw translated(error) }
    }
    public func receive(_ data: Data) throws -> Data {
        do { return try inner.receive(data) } catch { throw translated(error) }
    }
    private func translated(_ error: Error) -> BackendSealedFailure {
        if error as? SealedError == .exhausted { return .exhausted }
        if error as? SealedError == .length { return .length }
        return .authentication
    }
}

public struct BackendSealedResponse: Sendable {
    public let reply: Data
    public let devicePublicKey: Data
    public let transport: BackendSealedTransport
}

extension SealedHandshake {
    /// The host direction from src/shared/sealed.ts. Approval is checked only
    /// after authenticating the encrypted identity and deriving its static DH.
    static func respond(host: StaticKeyPair, message: Data, known: Set<Data>, permitUnknownPeer: Bool = false, ephemeral: StaticKeyPair) throws -> (Data, Data, SealedTransport) {
        guard message.count == Sealed.noiseMessageBytes else { throw SealedError.length }
        let peerEphemeral = Data(message.prefix(Sealed.keyBytes))
        let encryptedStatic = Data(message.dropFirst(Sealed.keyBytes))
        var (chainingKey, h) = initialState(responderStatic: host.publicKey)
        h = hash(h, peerEphemeral)
        let es = mixKey(chainingKey, try diffieHellman(host.privateKey, peerEphemeral))
        chainingKey = es.chainingKey
        let device = try open(key: es.temp, counter: 0, sealed: encryptedStatic, aad: h)
        h = hash(h, encryptedStatic)
        let ss = mixKey(chainingKey, try diffieHellman(host.privateKey, device))
        chainingKey = ss.chainingKey
        // A live pairing offer may admit a new authenticated static key. This
        // admits only the Noise transport; hello must still spend the one-shot
        // code and human approval must still precede session access.
        guard permitUnknownPeer || known.contains(device) else { throw SealedError.authentication }
        h = hash(h, ephemeral.publicKey)
        let ee = mixKey(chainingKey, try diffieHellman(ephemeral.privateKey, peerEphemeral))
        chainingKey = ee.chainingKey
        let se = mixKey(chainingKey, try diffieHellman(ephemeral.privateKey, device))
        chainingKey = se.chainingKey
        let confirmation = try seal(key: se.temp, counter: 0, plaintext: Data(), aad: h)
        h = hash(h, confirmation)
        let keys = split(chainingKey, h)
        return (ephemeral.publicKey + confirmation, device,
                SealedTransport(sendKey: keys.k2, receiveKey: keys.k1, channelBinding: keys.binding))
    }
}

public enum BackendSealedHost {
    public static func respond(identity: BackendSealedIdentity, message: Data, approvedKeys: Set<Data>, permitUnknownPeer: Bool = false, fixtureEphemeral: Data? = nil) throws -> BackendSealedResponse {
        guard let host = StaticKeyPair(privateKey: identity.privateKey) else { throw BackendSealedFailure.authentication }
        let ephemeral: StaticKeyPair
        if let fixtureEphemeral {
            guard let key = StaticKeyPair(privateKey: fixtureEphemeral) else { throw BackendSealedFailure.authentication }
            ephemeral = key
        } else { ephemeral = .generate() }
        do {
            let (reply, peer, transport) = try SealedHandshake.respond(host: host, message: message, known: approvedKeys, permitUnknownPeer: permitUnknownPeer, ephemeral: ephemeral)
            return BackendSealedResponse(reply: reply, devicePublicKey: peer, transport: BackendSealedTransport(transport))
        } catch {
            if error as? SealedError == .length { throw BackendSealedFailure.length }
            throw BackendSealedFailure.authentication
        }
    }

    public static func respondRelayFrame(identity: BackendSealedIdentity, frame: Data, approvedKeys: Set<Data>, permitUnknownPeer: Bool = false) throws -> BackendSealedResponse {
        guard frame.count == RelayWire.handshakeOpenBytes else { throw BackendSealedFailure.length }
        guard frame.first == RelayWire.sealedVersion else { throw BackendSealedFailure.version }
        let opened = try respond(identity: identity, message: Data(frame.dropFirst()), approvedKeys: approvedKeys, permitUnknownPeer: permitUnknownPeer)
        return BackendSealedResponse(reply: RelayWire.withSealedVersion(opened.reply), devicePublicKey: opened.devicePublicKey, transport: opened.transport)
    }
}

public enum BackendPairingDerivation {
    public static func scrypt(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) throws -> Data {
        try Scrypt.derive(password: password, salt: salt, n: n, r: r, p: p, length: length)
    }
}
