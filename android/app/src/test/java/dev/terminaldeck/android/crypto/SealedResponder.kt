package dev.terminaldeck.android.crypto

/**
 * The Mac's half of the handshake, in the test source set only.
 *
 * A phone is never a responder, so this does not belong in the app — shipping it would be an
 * unreachable second entry point into the key schedule. It is here because the initiator alone
 * cannot be checked end to end against a static vector: the responder's reply depends on the
 * responder's ephemeral, and a port that can only *produce* message one has verified half a
 * handshake.
 *
 * Transcribed from `respondToHandshake` in `src/shared/sealed.ts`. It reaches into `Sealed`'s
 * `internal` primitives, which the unit-test source set can see because it compiles into the same
 * module.
 */
class SealedResponderResult(
    val reply: ByteArray,
    val channel: SealedChannel,
    val devicePublicKey: ByteArray,
)

fun respondToHandshake(
    responderStatic: StaticKeyPair,
    message: ByteArray,
    ephemeral: StaticKeyPair = Sealed.generateStatic(),
    isKnownDevice: (ByteArray) -> Boolean = { true },
): SealedResponderResult {
    if (message.size != Sealed.NOISE_MESSAGE_BYTES) {
        throw SealedException("handshake message was the wrong length")
    }
    val initiatorEphemeral = message.copyOfRange(0, Sealed.KEY_BYTES)
    val encryptedStatic = message.copyOfRange(Sealed.KEY_BYTES, message.size)

    val (chain0, h0) = Sealed.initialState(responderStatic.publicKey)
    var h = Sealed.hash(h0, initiatorEphemeral)

    val (chain1, esKey) = Sealed.mixKey(chain0, Sealed.dh(responderStatic.privateKey, initiatorEphemeral))

    val devicePublicKey = try {
        Sealed.open(esKey, 0, encryptedStatic, h)
    } catch (e: SealedException) {
        throw SealedException("handshake failed authentication")
    }
    h = Sealed.hash(h, encryptedStatic)

    val (chain2, _) = Sealed.mixKey(chain1, Sealed.dh(responderStatic.privateKey, devicePublicKey))

    if (!isKnownDevice(devicePublicKey)) throw SealedException("handshake failed authentication")

    h = Sealed.hash(h, ephemeral.publicKey)
    val (chain3, _) = Sealed.mixKey(chain2, Sealed.dh(ephemeral.privateKey, initiatorEphemeral))
    val (chain4, seKey) = Sealed.mixKey(chain3, Sealed.dh(ephemeral.privateKey, devicePublicKey))

    val confirmation = Sealed.seal(seKey, 0, ByteArray(0), h)
    h = Sealed.hash(h, confirmation)

    val (k1, k2, binding) = Sealed.split(chain4, h)
    // Mirrored against the initiator: it sends under k1, so this side receives under k1.
    return SealedResponderResult(
        reply = ephemeral.publicKey + confirmation,
        channel = SealedChannel(k2, k1, binding),
        devicePublicKey = devicePublicKey,
    )
}
