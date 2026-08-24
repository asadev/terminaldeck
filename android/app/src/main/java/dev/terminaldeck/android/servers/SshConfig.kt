package dev.terminaldeck.android.servers

import android.util.Log
import net.schmizz.sshj.DefaultSecurityProviderConfig

/**
 * The sshj configuration this phone dials with, and the two decisions in it that were measured
 * rather than guessed.
 *
 * ## Why not `AndroidConfig`, the one named for this platform
 *
 * Because of what is in it. Read out of the 0.39.0 jar: `AndroidConfig.initKeyAlgorithms` sets
 * exactly three — `ssh-ed25519`, `ssh-rsa` and `ssh-dss` — and its static initialiser tries to
 * register **Spongy** Castle, a repackaging of BouncyCastle that this app does not ship, so that
 * line is a no-op. Two consequences, and both would arrive as a refused login with the wrong
 * sentence on it:
 *
 *  - **No ECDSA at all.** An `ecdsa-sha2-nistp256` key — what `ssh-keygen -t ecdsa` writes, and
 *    what several hosting companies hand out — could not be offered, and the server would answer
 *    the way it answers a wrong password.
 *  - **RSA only as `ssh-rsa`**, the SHA-1 signature algorithm. OpenSSH 8.8 removed that from its
 *    defaults in 2021. Measured against the real server this lane verifies on: its
 *    `pubkeyacceptedalgorithms` lists `rsa-sha2-512` and `rsa-sha2-256` and does **not** list
 *    `ssh-rsa`. So every RSA key on a current server would be refused, by a client that had one.
 *
 * `DefaultSecurityProviderConfig` is `DefaultConfig` with one thing changed — it does not try to
 * register BouncyCastle as a JCA provider — and that is the half of `AndroidConfig` worth keeping.
 * Registering it is the classic way to break sshj on Android: the platform already ships a
 * stripped provider **named `BC`**, `Security.addProvider` will not replace a name that is taken,
 * and sshj then asks that cut-down provider for algorithms it does not have. This app's own
 * BouncyCastle is used the way `crypto/Sealed.kt` uses it — as classes, never as a provider — and
 * that stays true here.
 *
 * ## Why the key exchanges are pruned, and why by *building* them
 *
 * `DefaultConfig.initKeyExchangeFactories` lists `curve25519-sha256` **first**, unconditionally,
 * and sshj implements it over the JCA: `Curve25519DH` asks for a `KeyPairGenerator` and a
 * `KeyAgreement` named `X25519`. Android has no such thing before API 33, and `minSdk` here is 26.
 *
 * That is not a graceful degradation. SSH negotiation settles on the first algorithm both ends
 * name, and every current OpenSSH names curve25519 — so the two agree on it and *then* the client
 * throws mid-handshake. Measured against the real Hetzner box on an API 31 emulator, before this
 * pruning existed:
 *
 * ```
 * TransportException: X25519 KeyPairGenerator not available
 *   at Curve25519DH.<init>(Curve25519DH.java:47)
 *   at KeyExchanger.gotKexInit(KeyExchanger.java:274)
 * ```
 *
 * and what a person saw for it was *"That answered, but not as a server"* about a perfectly good
 * server answering perfectly well on port 22.
 *
 * ## Why not a version check, and why not a named probe either
 *
 * Both were tried and the second is the interesting failure. Asking `Build.VERSION` is a claim
 * about the platform's headline rather than about what its providers actually hold — an OEM image
 * or an app that installed Conscrypt differs from it in both directions. So the first attempt
 * probed for the algorithm by name, `KeyAgreement.getInstance("XDH")`, and **that answered yes on
 * an API 31 emulator that then failed on `KeyPairGenerator.getInstance("X25519")`**. One name is
 * not the other, a key exchange needs both, and a probe that asks about one of the things a
 * factory needs is a probe that can be wrong.
 *
 * So nothing is asked *about* the factories: each one is **built**, and the ones that throw are
 * dropped. Whatever a factory needs, if this device cannot supply it, the factory is not offered —
 * and the two ends fall through to `ecdh-sha2-nistp256`, which the platform has always had and
 * which that same server offers. It is exactly what sshj already does for ciphers in
 * `initCipherFactories`, applied to the list it forgot to do it for.
 *
 * Note what is **not** duplicated here: the ciphers and MACs. sshj prunes those itself, so a phone
 * with no ChaCha20 simply does not offer `chacha20-poly1305@openssh.com`, and a second list here
 * would be one more thing to keep in step with theirs.
 */
class AndroidSshConfig : DefaultSecurityProviderConfig() {

    init {
        val usable = keyExchangeFactories.filter { factory ->
            try {
                factory.create()
                true
            } catch (e: Throwable) {
                // Once per name, at debug level: this is a fact about the device rather than about
                // the server, and it is the first thing worth knowing when a handshake picks
                // something unexpected.
                Log.d(TAG, "key exchange ${factory.name} is not available on this device: ${e.message}")
                false
            }
        }
        // Never empty. A config with no key exchange in it cannot open anything at all, and the
        // honest failure for a device that really can do none of them is the server's own
        // "nothing in common" rather than a client that refuses to try.
        if (usable.isNotEmpty()) keyExchangeFactories = usable
    }

    private companion object {
        const val TAG = "TerminalDeck"
    }
}
