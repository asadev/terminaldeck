/**
 * How six typed digits find a Mac.
 *
 * ## Why a code cannot simply be dialled
 *
 * Reaching a machine takes three facts: a relay address, a 26-character host id
 * and the machine's 32-byte X25519 public key. Together they are the *address*,
 * and they are what makes the handshake Noise IK rather than trust-on-first-use.
 * None of them is secret. They are simply large — 130 bits of host id and 256 of
 * key — and six digits cannot carry four hundred bits.
 *
 * This app used to get all of it from a QR code, inside a
 * `terminaldeck://pair?v=1&r=…&h=…&k=…&t=…` link. The QR did not work and the
 * link was a live bearer secret with a route through a chat app attached, so
 * both are gone and this file is what replaces them.
 *
 * ## The mechanism, which is the desktop's and is not restated here
 *
 * `src/main/remote/machines/rendezvous.ts` carries the full argument and is
 * worth reading there rather than summarised badly. In one paragraph: the
 * machine showing a code claims a relay slot named by that code, and answers on
 * it with its real address. Both ends derive the slot's secret **and the
 * responder's static key pair** from the code, so the offer channel is an
 * ordinary sealed channel whose responder identity only somebody holding the
 * code can produce. A relay that substitutes itself fails `es` and this client's
 * handshake refuses it. Nothing was added to the relay and nothing is stored
 * anywhere; the slot exists for exactly as long as the code is on screen.
 *
 * ## Why the derivation is scrypt and must stay scrypt
 *
 * There are 10^6 codes. A slot lookup answers a yes/no question about a
 * candidate code, over a relay with no per-source rate limit anywhere in the
 * path. If the slot were named by a hash, an attacker would sweep the million in
 * seconds, learn the live code exactly, and redeem it on the first try — and the
 * five-guess budget the desktop enforces would be worth nothing, because they
 * would never need a second guess.
 *
 * At N=16384, r=8, p=1 a guess costs 16 MiB and tens of milliseconds. The whole
 * space is about ten CPU-hours, inside a sixty-second window. `Scrypt.swift`
 * says why there is a hand-written scrypt in this app at all.
 *
 * ## What is shared with the desktop, and what is restated
 *
 * Restated, because Swift cannot import TypeScript: the salt, the parameters,
 * the seed split, and the host-id alphabet. Two implementations of one
 * derivation drift silently — nothing throws, nothing logs, and a code typed
 * correctly simply finds nothing — so `RendezvousTests` pins the output against
 * vectors produced by *running* the desktop's own module. That test is what
 * makes this file safe to have.
 */

import CryptoKit
import Foundation

/// The identity both ends derive from one code.
struct RendezvousIdentity: Equatable {
    /// The relay slot's public name, `BASE32(SHA-256(hostSecret))`.
    let hostId: String
    /// The responder key pair. Only somebody holding the code can produce it.
    let keys: StaticKeyPair
}

enum Rendezvous {

    /**
     * The domain separator, mixed in as the scrypt salt.
     *
     * Versioned because it pins the whole derivation: change the parameters
     * below and this string changes with them, so two builds that disagree fail
     * to find each other at the relay rather than half-completing a handshake
     * with mismatched keys. There is nothing to negotiate and no fallback.
     *
     * It must equal `RENDEZVOUS_SALT` in the desktop's module, byte for byte.
     */
    static let salt = "terminaldeck-machine-pairing-v1"

    /// The desktop's parameters, and they must stay the desktop's parameters.
    static let scryptN = 16384
    static let scryptR = 8
    static let scryptP = 1

    /// 32 bytes to name the slot with, then 32 to be the responder identity.
    static let seedBytes = 64

    /**
     * How long a lookup waits.
     *
     * The code lives sixty seconds and both halves of pairing — this lookup and
     * the real connection that follows — have to fit inside it. A lookup that
     * waited thirty seconds would leave a pairing that fails on a token which
     * expired while it was waiting, and the sentence the person reads would
     * blame the wrong thing.
     */
    static let lookupTimeout: TimeInterval = 12

    /**
     * The identity a code derives, or nil for a string that is not a code.
     *
     * `async`, and off the main actor, for one reason: the derivation is
     * deliberately expensive. Sixteen mebibytes and tens of milliseconds on a
     * Mac is a good deal longer on a phone, and doing it on the main thread
     * freezes the one screen where somebody is watching to see whether their
     * code worked.
     *
     * Normalised first, so both ends derive from the same string however each
     * was typed or printed. `482913`, ` 482 913 ` and `482-913` — the shape a
     * code comes back in after a round trip through a messaging app — all have to
     * land on one seed.
     */
    static func identity(for typed: String) async -> RendezvousIdentity? {
        guard let code = PairingCodeParser.normalise(typed) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> RendezvousIdentity? in
            guard let seed = try? Scrypt.derive(
                password: Data(code.utf8),
                salt: Data(Rendezvous.salt.utf8),
                n: Rendezvous.scryptN,
                r: Rendezvous.scryptR,
                p: Rendezvous.scryptP,
                length: Rendezvous.seedBytes
            ) else { return nil }

            let hostSecret = seed.prefix(32)
            guard let keys = StaticKeyPair(privateKey: Data(seed.suffix(32))) else { return nil }
            return RendezvousIdentity(hostId: slotName(for: Data(hostSecret)), keys: keys)
        }.value
    }

    /**
     * `BASE32(SHA-256(secret))`, 26 characters.
     *
     * The relay's own alphabet: A–Z without `I` or `O`, then 2–9, so a host id
     * printed on a screen has no character anybody misreads. `hostIdFor` in
     * `src/shared/relay-wire.ts` is the definition; this is the same function in
     * Swift and `RendezvousTests` cross-checks the two.
     */
    static func slotName(for secret: Data) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let digest = Data(SHA256.hash(data: secret))
        var bits = 0
        var value = 0
        var out = ""
        for byte in digest {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(value >> bits) & 31])
                if out.count == 26 { return out }
            }
        }
        return out
    }
}

/* -------------------------------------------------------------------------- */
/* The lookup                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * What the machine showing a code says about itself: an address, and nothing
 * else.
 *
 * Every field is public — the relay URL, the host id, the X25519 public key.
 * There is deliberately no secret in here. The channel it arrives on is sealed,
 * but a payload that relied on that would be one bad refactor away from being
 * sent in the clear, and this one is not.
 */
struct MachineOffer: Equatable {
    let relayURL: URL
    let hostId: String
    let hostKey: Data

    var endpoint: DeckEndpoint { .relay(url: relayURL, hostId: hostId, hostKey: hostKey) }
}

extension Rendezvous {

    /** Bounded so a hostile answer cannot make this app hold a large string. */
    static let maxOfferBytes = 4 * 1024

    /**
     * Read an offer, or nil.
     *
     * Narrowed field by field rather than decoded into a struct with a
     * `try?`, and it is the second of two locks rather than the only one: nobody
     * without the code can produce this frame at all, because the channel it
     * arrives on is sealed against a key derived from the code. It is here
     * because a frame that is authenticated is still not a frame that is
     * well-formed — and what comes out of this function is dialled and then
     * handed a pairing code.
     *
     * The key is **decoded, not shape-checked**. An offer carries 32 bytes as
     * standard base64, because `machines/ipc.ts` re-encodes them that way, and
     * standard base64 of 32 random bytes contains a `+` or a `/` most of the
     * time. A validator written for the base64url form the old pairing link
     * carried would refuse most real machines, intermittently, in a way that
     * reads on screen as a code that had expired.
     */
    static func parseOffer(_ raw: String) -> MachineOffer? {
        guard raw.utf8.count <= maxOfferBytes else { return nil }
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return nil }
        guard object["t"] as? String == "machine" else { return nil }

        guard let relay = object["relayUrl"] as? String,
              let url = URL(string: relay),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host != nil else { return nil }
        guard let hostId = object["hostId"] as? String, PairingCodeParser.isHostId(hostId) else { return nil }
        guard let key = object["publicKey"] as? String,
              let bytes = Data(base64Encoded: key),
              bytes.count == Sealed.keyBytes else { return nil }

        return MachineOffer(relayURL: url, hostId: hostId, hostKey: bytes)
    }
}

/**
 * Ask the rendezvous where the machine behind a code is.
 *
 * Nothing is sent. The machine showing the code answers as soon as the sealed
 * channel is up, and the whole conversation is that one frame — so this opens a
 * channel, takes the first thing that arrives, and hangs up.
 *
 * A **throwaway** key pair is used rather than this phone's own, matching the
 * desktop and the browser client: the rendezvous authenticates the *responder* —
 * it is the machine showing the code that has to prove it holds the code — and
 * nothing on the far side stores or looks at who dialled. Putting the durable
 * device key on a channel before there is a machine to associate it with would be
 * spending it for nothing.
 *
 * Nil covers every failure — a code nobody is showing, a relay that will not
 * answer, an offer that does not parse — because the caller's next sentence is
 * the same in all of them, and telling them apart would mean describing the
 * relay's behaviour to somebody who cannot act on it.
 */
@MainActor
final class RendezvousLookup {

    /// The relay this phone dials. The far machine names its own in the offer.
    static let defaultRelay = URL(string: "wss://relay.terminaldeck.dev")!

    private var carrier: Carrier?
    private var finished = false

    /**
     * `makeCarrier` is a seam for the tests and for the live harness. It is the
     * only reason this is a class rather than a function: a unit test that
     * called the real one would open a WebSocket to the public relay from
     * whatever machine it ran on.
     */
    private let makeCarrier: @MainActor (URL, Data, StaticKeyPair) -> Carrier

    // `@MainActor` on the closure type, not merely on the class: `RelayCarrier`
    // is main-actor isolated, so a plain `(URL, …) -> Carrier` cannot construct
    // one, and a default argument is evaluated in the caller's isolation rather
    // than in this initialiser's.
    init(makeCarrier: @escaping @MainActor (URL, Data, StaticKeyPair) -> Carrier = { url, key, keys in
        RelayCarrier(url: url, hostKey: key, deviceKeys: keys)
    }) {
        self.makeCarrier = makeCarrier
    }

    func find(
        code: String,
        relay: URL = RendezvousLookup.defaultRelay,
        timeout: TimeInterval = Rendezvous.lookupTimeout
    ) async -> MachineOffer? {
        guard let identity = await Rendezvous.identity(for: code) else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<MachineOffer?, Never>) in
            let settle: (MachineOffer?) -> Void = { [weak self] offer in
                guard let self, !finished else { return }
                finished = true
                carrier?.onEvent = nil
                carrier?.close()
                carrier = nil
                continuation.resume(returning: offer)
            }

            // The slot's address, built exactly the way a real relay endpoint is
            // — `/v1/join?host=<id>` — by the same type that builds it for a
            // paired machine, so the two cannot disagree about the path.
            let slot = DeckEndpoint.relay(url: relay, hostId: identity.hostId, hostKey: identity.keys.publicKey)
            let pipe = makeCarrier(slot.socketURL, identity.keys.publicKey, StaticKeyPair.generate())
            carrier = pipe
            pipe.onEvent = { event in
                switch event {
                case .ready:
                    // Nothing is sent. There is no protocol on this channel; the
                    // offer is the entire conversation and the far end speaks
                    // first.
                    break
                case let .text(payload):
                    settle(Rendezvous.parseOffer(payload))
                case .closed:
                    settle(nil)
                }
            }
            pipe.open()

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                settle(nil)
            }
        }
    }
}
