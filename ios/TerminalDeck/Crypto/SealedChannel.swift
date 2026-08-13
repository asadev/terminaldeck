/**
 * The sealed channel, in Swift. A port of `src/shared/sealed.ts`, byte for byte.
 *
 * Read that file first: it explains why a Noise IK handshake is here at all,
 * why the relay is treated as hostile, and why every public value goes into the
 * transcript hash. This file adds nothing to that reasoning and changes none of
 * it. What follows is only what a *second* implementation of the same handshake
 * has to get right, because the whole value of this code is that its bytes are
 * indistinguishable from the Node ones.
 *
 * ## The four places a port silently diverges
 *
 * Each of these produces code that passes any test written against itself and
 * cannot open a single frame from the Mac. `Tests/SealedChannelTests` asserts
 * all four against vectors generated from the Node implementation.
 *
 *  1. **The nonce layout.** Twelve bytes, counter in the *last eight*,
 *     little-endian, first four left zero. Writing it big-endian, or into the
 *     first eight bytes, is a working AEAD with an incompatible nonce.
 *  2. **The transcript hash.** `h` absorbs the protocol name, the responder's
 *     static key, both ephemerals, the encrypted static and the confirmation,
 *     in that order — and the *ciphertext* is what gets absorbed, never the
 *     plaintext under it, and always after the value it authenticated.
 *  3. **HKDF's argument order.** Noise's `MixKey` uses the chaining key as the
 *     HKDF **salt** and the DH result as the **input key material**. They are
 *     both 32 bytes, so swapping them type-checks and produces a perfectly
 *     good key nobody else derives. `Split` then extracts with an *empty* IKM
 *     and the chaining key as salt again.
 *  4. **Direction.** The initiator sends under `k1` and receives under `k2`;
 *     the responder mirrors. This app is only ever the initiator — a phone does
 *     not answer handshakes — so `k1` is `sendKey` here, always.
 *
 * ## And a fifth, which is not in this file at all
 *
 * Porting `sealed.ts` faithfully is necessary and not sufficient. The bytes this
 * file produces are the *payload*; `src/shared/relay-wire.ts` frames them with a
 * version byte before they cross a relay, so the wire carries 81 and 49 rather
 * than the 80 and 48 below. That framing is `Protocol/RelayWire.swift`, and a
 * client that has this file exactly right and that one missing is a client that
 * hangs. It is worth stating here because everything in this file passed its
 * vectors while the app could not connect to anything.
 *
 * ## Primitives
 *
 * CryptoKit gives all three natively: `Curve25519.KeyAgreement` for X25519,
 * `ChaChaPoly` for the AEAD (RFC 8439, 96-bit nonce, 16-byte tag — the same
 * construction Node calls `chacha20-poly1305`), and `HKDF<SHA256>`. No
 * third-party crypto is linked, and none is written here beyond the composition
 * above.
 *
 * ## Export compliance
 *
 * This file is the reason `ITSAppUsesNonExemptEncryption` is `true` in
 * `Support/Info.plist`. See the note there before shipping a build.
 */

import CryptoKit
import Foundation

enum Sealed {
    /**
     * Noise protocol name, mixed into the initial hash.
     *
     * A domain separator, not a version string: change any primitive and this
     * string changes, so a client built against a different suite fails at the
     * first decrypt rather than negotiating its way down to it.
     */
    static let noiseName = "Noise_IK_25519_ChaChaPoly_SHA256"

    /** Bumped with any change to the framing or key schedule. Matches `SEALED_VERSION`. */
    static let version = 1

    static let keyBytes = 32
    static let nonceBytes = 12
    static let tagBytes = 16

    /// Highest message counter allowed under one key. Far below what the nonce
    /// field could hold; the cap exists so the counter is checked at all, and so
    /// the failure is a closed connection rather than a wrapped nonce.
    static let maxCounter: UInt64 = 1 << 48

    /// The Noise IK message: ephemeral + sealed static. **Not** what goes on the
    /// wire — `RelayWire` puts a version byte in front of it, making 81. These
    /// two constants were once called `handshakeMessageBytes`/`handshakeReplyBytes`
    /// and documented as "bytes on the wire", and that sentence is what produced
    /// a client that could not complete a single handshake.
    static let noiseMessageBytes = keyBytes + keyBytes + tagBytes
    /// The Noise IK reply: ephemeral + an empty confirmation's tag. 48; the wire
    /// carries 49.
    static let noiseReplyBytes = keyBytes + tagBytes
}

/**
 * Why something failed, in the two flavours a caller may act on differently.
 *
 * There is deliberately no case for *which* check failed. A frame with a bad
 * tag, a frame arriving out of order and a frame from the wrong direction all
 * produce `.authentication`, because telling the network which one it was is an
 * oracle — the same reasoning as the single error string in `sealed.ts`.
 */
enum SealedError: Error, Equatable {
    /// A DH, an AEAD open, or an identity check refused. Never says which.
    case authentication
    /// A handshake message that was not the length the protocol defines. Safe to
    /// distinguish: the length is visible to anyone watching the wire anyway.
    case length
    /// The counter reached its cap. Reconnect; do not reuse a nonce.
    case exhausted
}

/* -------------------------------------------------------------------------- */
/* Keys                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * A static identity as raw bytes, which is the only shape that crosses the wire
 * or the Keychain.
 *
 * CryptoKit speaks `Curve25519.KeyAgreement.PrivateKey`; Node speaks 32 bytes
 * and so does Android. Converting at this boundary rather than at every call
 * site is what lets the implementations agree.
 */
struct StaticKeyPair: Equatable {
    let publicKey: Data
    let privateKey: Data

    static func generate() -> StaticKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return StaticKeyPair(publicKey: key.publicKey.rawRepresentation,
                             privateKey: key.rawRepresentation)
    }

    /// Rebuild an identity from the private half alone — what loading one out of
    /// the Keychain looks like. The public key is derived rather than stored
    /// beside it, so the two can never be a mismatched pair.
    init?(privateKey: Data) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            return nil
        }
        self.privateKey = key.rawRepresentation
        self.publicKey = key.publicKey.rawRepresentation
    }

    fileprivate init(publicKey: Data, privateKey: Data) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

/**
 * X25519 with the all-zero output rejected.
 *
 * A peer can send a low-order point and force the shared secret to zero on the
 * other side, which would hand an attacker a key they also know. RFC 7748 §6.1
 * says to check. CryptoKit does reject it — `sharedSecretFromKeyAgreement`
 * throws — and the check is kept anyway, because this is one of four
 * implementations of the same handshake and Android's XDH does not throw.
 */
private func diffieHellman(_ privateRaw: Data, _ publicRaw: Data) throws -> Data {
    guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateRaw),
          let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicRaw),
          let shared = try? priv.sharedSecretFromKeyAgreement(with: pub) else {
        throw SealedError.authentication
    }
    let bytes = shared.withUnsafeBytes { Data($0) }
    // Accumulate rather than compare-and-return: the value is not secret once it
    // is zero, but a branch here would be the one timing difference in a file
    // that has none.
    var difference: UInt8 = 0
    for byte in bytes { difference |= byte }
    guard difference != 0 else { throw SealedError.authentication }
    return bytes
}

/* -------------------------------------------------------------------------- */
/* Symmetric state                                                             */
/* -------------------------------------------------------------------------- */

private func hash(_ parts: Data...) -> Data {
    var digest = SHA256()
    for part in parts { digest.update(data: part) }
    return Data(digest.finalize())
}

/**
 * Noise's `MixKey`: fold a fresh DH result into the chaining key.
 *
 * Two outputs from one HKDF — the next chaining key and a key usable now. Note
 * which argument is which: the chaining key is the **salt**, the DH result is
 * the **input key material**. Both are 32 bytes, so the swap compiles.
 */
private func mixKey(_ chainingKey: Data, _ input: Data) -> (chainingKey: Data, temp: Data) {
    let out = expand(inputKeyMaterial: input, salt: chainingKey)
    return (out.prefix(Sealed.keyBytes), out.suffix(Sealed.keyBytes))
}

/// HKDF-SHA256 to exactly two keys' worth of output, with an empty `info`.
private func expand(inputKeyMaterial: Data, salt: Data) -> Data {
    let derived = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
        salt: salt,
        info: Data(),
        outputByteCount: Sealed.keyBytes * 2)
    return derived.withUnsafeBytes { Data($0) }
}

/**
 * Noise's `Split`: two directional keys plus a channel binding.
 *
 * Extracted with an **empty** input key material and the chaining key as salt —
 * which looks like a mistake and is not. The binding is the final transcript
 * hash; it is not secret and encrypts nothing.
 */
private func split(_ chainingKey: Data, _ h: Data) -> (k1: Data, k2: Data, binding: Data) {
    let out = expand(inputKeyMaterial: Data(), salt: chainingKey)
    return (out.prefix(Sealed.keyBytes), out.suffix(Sealed.keyBytes), h)
}

/**
 * The nonce, and the single easiest thing in this file to get fatally wrong.
 *
 * Noise puts the counter in the last 8 bytes, little-endian, leaving the first
 * 4 zero. Writing it any other way is a silent interop break: every frame
 * encrypts fine and none of them open on the far side.
 */
private func nonce(_ counter: UInt64) -> Data {
    var bytes = Data(repeating: 0, count: Sealed.nonceBytes)
    var little = counter.littleEndian
    withUnsafeBytes(of: &little) { raw in
        bytes.replaceSubrange(4 ..< 12, with: raw)
    }
    return bytes
}

private func seal(key: Data, counter: UInt64, plaintext: Data, aad: Data) throws -> Data {
    guard let box = try? ChaChaPoly.seal(plaintext,
                                         using: SymmetricKey(data: key),
                                         nonce: try ChaChaPoly.Nonce(data: nonce(counter)),
                                         authenticating: aad) else {
        throw SealedError.authentication
    }
    // Node returns ciphertext ‖ tag. CryptoKit's `combined` would prepend the
    // nonce, which the far end is not expecting and would read as 12 bytes of
    // ciphertext.
    return box.ciphertext + box.tag
}

private func open(key: Data, counter: UInt64, sealed: Data, aad: Data) throws -> Data {
    guard sealed.count >= Sealed.tagBytes else { throw SealedError.authentication }
    // `Data` slices keep their parent's indices; `prefix`/`suffix` on a slice
    // that has already been re-based would silently address the wrong bytes.
    let body = Data(sealed.prefix(sealed.count - Sealed.tagBytes))
    let tag = Data(sealed.suffix(Sealed.tagBytes))
    guard let box = try? ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonce(counter)),
                                              ciphertext: body,
                                              tag: tag),
          let plaintext = try? ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad) else {
        throw SealedError.authentication
    }
    return plaintext
}

/* -------------------------------------------------------------------------- */
/* Transport                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * A live sealed channel, after the handshake.
 *
 * Send and receive counters are independent and never shared. `receive` refuses
 * to advance on a failed decrypt, so a forged frame costs an attacker the
 * connection rather than desynchronising the counter.
 *
 * Not thread-safe by design: the counters are the whole security property and
 * two threads sealing at once would reuse a nonce. Everything in this app that
 * touches one is on the main actor.
 */
final class SealedTransport {
    private let sendKey: Data
    private let receiveKey: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    /// The final handshake hash. Both ends have it; a higher layer can use it to
    /// prove two parties are on the same channel without a second handshake.
    let channelBinding: Data

    fileprivate init(sendKey: Data, receiveKey: Data, channelBinding: Data) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.channelBinding = channelBinding
    }

    func send(_ plaintext: Data) throws -> Data {
        guard sendCounter < Sealed.maxCounter else { throw SealedError.exhausted }
        let frame = try seal(key: sendKey, counter: sendCounter, plaintext: plaintext, aad: Data())
        sendCounter += 1
        return frame
    }

    func receive(_ sealed: Data) throws -> Data {
        guard receiveCounter < Sealed.maxCounter else { throw SealedError.exhausted }
        let plaintext = try open(key: receiveKey, counter: receiveCounter, sealed: sealed, aad: Data())
        receiveCounter += 1
        return plaintext
    }

    func send(text: String) throws -> Data {
        try send(Data(text.utf8))
    }

    /// Nil when the far end sent something that is not UTF-8. The protocol above
    /// this is JSON, so that is a peer that is not the desktop rather than a
    /// decoding nicety — and it must not become a crash on a socket callback.
    func receiveText(_ sealed: Data) throws -> String? {
        String(data: try receive(sealed), encoding: .utf8)
    }
}

/* -------------------------------------------------------------------------- */
/* Handshake — initiator (this phone)                                          */
/* -------------------------------------------------------------------------- */

/// Held between the two halves of the handshake. Carries private key material,
/// so it never leaves the transport that made it.
struct PendingHandshake {
    fileprivate let ephemeralPrivate: Data
    fileprivate let chainingKey: Data
    fileprivate let h: Data
    fileprivate let staticPrivate: Data

    /// Exposed for the interop tests, which assert these against the values the
    /// Node implementation recorded at the same point in the handshake.
    var transcript: (chainingKey: Data, h: Data) { (chainingKey, h) }
}

enum SealedHandshake {

    private static func initialState(responderStatic: Data) -> (chainingKey: Data, h: Data) {
        // The name is hashed rather than zero-padded. Worth stating because the
        // Noise spec pads a name of 32 bytes or fewer, this one is exactly 32,
        // and a port that followed the spec here instead of the implementation
        // would derive different keys for every session and pass its own tests.
        let h0 = hash(Data(Sealed.noiseName.utf8))
        // Then the responder's static public key, as the pre-message. This is
        // what makes the pattern IK rather than XX.
        return (h0, hash(h0, responderStatic))
    }

    /**
     * First handshake message, from a device that already knows this Mac's key.
     *
     * The device's own static public key is sent *encrypted*, under a key
     * derived from `es`. That is the point of IK: a passive observer — the relay
     * included — cannot tell which device is connecting, only that one is.
     *
     * `ephemeral` exists for the interop test, which replays an ephemeral key
     * the Node implementation generated and asserts this function produces the
     * identical message. Production callers never pass it.
     */
    static func start(deviceStatic: StaticKeyPair,
                      responderStaticPublic: Data,
                      ephemeral: StaticKeyPair = .generate())
        throws -> (message: Data, pending: PendingHandshake) {

        guard responderStaticPublic.count == Sealed.keyBytes else { throw SealedError.length }

        var (chainingKey, h) = initialState(responderStatic: responderStaticPublic)

        h = hash(h, ephemeral.publicKey)
        let es = mixKey(chainingKey, try diffieHellman(ephemeral.privateKey, responderStaticPublic))
        chainingKey = es.chainingKey

        let encryptedStatic = try seal(key: es.temp, counter: 0,
                                       plaintext: deviceStatic.publicKey, aad: h)
        h = hash(h, encryptedStatic)

        let ss = mixKey(chainingKey, try diffieHellman(deviceStatic.privateKey, responderStaticPublic))
        chainingKey = ss.chainingKey

        return (ephemeral.publicKey + encryptedStatic,
                PendingHandshake(ephemeralPrivate: ephemeral.privateKey,
                                 chainingKey: chainingKey,
                                 h: h,
                                 staticPrivate: deviceStatic.privateKey))
    }

    /// Completes this side once the responder's reply arrives.
    static func finish(pending: PendingHandshake, reply: Data) throws -> SealedTransport {
        guard reply.count == Sealed.noiseReplyBytes else { throw SealedError.length }
        let responderEphemeral = Data(reply.prefix(Sealed.keyBytes))
        let confirmation = Data(reply.suffix(Sealed.tagBytes))

        var chainingKey = pending.chainingKey
        var h = hash(pending.h, responderEphemeral)

        let ee = mixKey(chainingKey, try diffieHellman(pending.ephemeralPrivate, responderEphemeral))
        chainingKey = ee.chainingKey
        let se = mixKey(chainingKey, try diffieHellman(pending.staticPrivate, responderEphemeral))
        chainingKey = se.chainingKey

        // An empty payload whose only job is to prove the responder derived the
        // same keys. If this opens, the far end holds the Mac's static private
        // key — which is the entire authentication of the desktop.
        _ = try open(key: se.temp, counter: 0, sealed: confirmation, aad: h)
        h = hash(h, confirmation)

        let keys = split(chainingKey, h)
        // The initiator sends under k1 and receives under k2. The responder
        // mirrors; this app is never the responder.
        return SealedTransport(sendKey: keys.k1, receiveKey: keys.k2, channelBinding: keys.binding)
    }
}

/* -------------------------------------------------------------------------- */
/* Fingerprints                                                                */
/* -------------------------------------------------------------------------- */

/**
 * A short, human-comparable form of a public key.
 *
 * Shown on the Mac and on the phone during pairing so a person can see the same
 * six groups in both places. Not a security boundary on its own — the pairing
 * token and the approval step are — but it is what turns "trust this device"
 * from a dialog you dismiss into one you can actually check.
 *
 * Base32 in an alphabet with no `0`/`O` or `1`/`I`, in groups of four, so it can
 * be read down a phone line. Exactly 32 symbols: A–Z without `I` or `O`, then
 * 2–9 — dropping both the letters and the digits they are confused with is what
 * makes the count come out right.
 */
func sealedFingerprint(_ publicKey: Data) -> String {
    let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    let digest = hash(Data("terminaldeck-fingerprint".utf8), publicKey)
    var bits = 0
    var value = 0
    var out = ""
    for byte in digest.prefix(15) {
        value = (value << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            out.append(alphabet[(value >> bits) & 31])
        }
    }
    return stride(from: 0, to: out.count, by: 4).map { offset -> String in
        let start = out.index(out.startIndex, offsetBy: offset)
        let end = out.index(start, offsetBy: min(4, out.count - offset))
        return String(out[start ..< end])
    }.joined(separator: "-")
}
