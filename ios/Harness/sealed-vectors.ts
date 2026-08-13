/**
 * Test vectors for the Swift port of the sealed channel.
 *
 * The Swift side of `src/shared/sealed.ts` is a second implementation of a
 * handshake whose entire value is that both ends derive the same bytes. A Swift
 * test that runs the Swift handshake against itself proves the Swift handshake
 * is self-consistent, which is the one property that cannot fail interestingly:
 * an implementation with the nonce counter in the wrong four bytes, or the
 * transcript hash mixed in the wrong order, or k1 and k2 the wrong way round,
 * passes that test and then cannot open a single frame from the Mac.
 *
 * So this file runs the *real* Node implementation — imported, not
 * reimplemented — and writes down what it produced. `Tests/SealedChannelTests`
 * then asserts the Swift code reproduces those bytes exactly and can open what
 * Node sealed. That is the only kind of proof worth having here.
 *
 * ## Why the fixture is committed rather than generated at test time
 *
 * A test that shells out to `node` is a test that fails on a machine without
 * this repository's `node_modules`, in CI containers, and inside Xcode's test
 * sandbox. The bytes are the contract; they belong in the repository next to
 * the test that reads them.
 *
 * ## Regenerating
 *
 *     ios/Harness/run.sh vectors
 *
 * The ephemeral key inside each handshake is chosen by `startHandshake` itself
 * and cannot be injected without editing `sealed.ts` — which would mean the
 * fixture no longer came from the shipping code. It is *recorded* instead
 * (`PendingInitiator.ephemeralPrivate` is part of that module's public shape),
 * so a regenerated fixture has different bytes and proves exactly the same
 * thing. Do not expect `git diff` to be empty after regenerating; expect the
 * Swift test to still pass.
 */

import { createPrivateKey, createPublicKey, createHash } from 'node:crypto'
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import {
    NOISE_NAME,
    SEALED_VERSION,
    fingerprint,
    finishHandshake,
    respondToHandshake,
    startHandshake,
    type StaticKeyPair,
} from '../../src/shared/sealed'
import {
    HANDSHAKE_OPEN_BYTES,
    HANDSHAKE_REPLY_BYTES,
    NOISE_MESSAGE_BYTES,
    NOISE_REPLY_BYTES,
    RELAY_SEALED_VERSION,
    withSealedVersion,
} from '../../src/shared/relay-wire'

/* ------------------------------------------------------------------ keys -- */

const PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')

/**
 * A named, reproducible X25519 identity.
 *
 * Clamped here rather than left to the implementations: X25519 clamps the
 * scalar internally on both sides, so an unclamped private key would still
 * agree — but it would agree for a reason the fixture does not state, and a
 * reader comparing the hex in the JSON against the hex in a debugger deserves
 * the same bytes in both places.
 */
function identity(label: string): StaticKeyPair {
    const seed = createHash('sha256').update(`terminaldeck-ios-vector/${label}`).digest()
    seed[0] &= 248
    seed[31] &= 127
    seed[31] |= 64
    const key = createPrivateKey({
        key: Buffer.concat([PKCS8_PREFIX, seed]),
        format: 'der',
        type: 'pkcs8',
    })
    const publicKey = createPublicKey(key).export({ type: 'spki', format: 'der' }).subarray(-32)
    return { publicKey: Buffer.from(publicKey), privateKey: seed }
}

const hex = (value: Buffer) => value.toString('hex')
const pair = (key: StaticKeyPair) => ({ publicKey: hex(key.publicKey), privateKey: hex(key.privateKey) })

/* --------------------------------------------------------------- vectors -- */

interface Frame {
    plaintext: string
    frame: string
}

function session(label: string, mac: StaticKeyPair, device: StaticKeyPair, payloads: Buffer[]) {
    const started = startHandshake(device, mac.publicKey)
    const answered = respondToHandshake(mac, started.message, (key) => key.equals(device.publicKey))
    const client = finishHandshake(started.pending, answered.reply)

    // Both directions, interleaved the way a real session runs them, so the
    // counters in the fixture are not both zero-based sequences that happen to
    // line up.
    const initiatorToResponder: Frame[] = []
    const responderToInitiator: Frame[] = []
    for (const payload of payloads) {
        initiatorToResponder.push({ plaintext: hex(payload), frame: hex(client.send(payload)) })
        const back = Buffer.concat([Buffer.from('echo:'), payload])
        responderToInitiator.push({ plaintext: hex(back), frame: hex(answered.transport.send(back)) })
    }

    return {
        label,
        mac: pair(mac),
        device: pair(device),
        // Recorded, not chosen — see the header.
        ephemeralPrivate: hex(started.pending.ephemeralPrivate),
        handshakeMessage: hex(started.message),
        pendingChainingKey: hex(started.pending.chainingKey),
        pendingH: hex(started.pending.h),
        reply: hex(answered.reply),
        // The same two messages as they actually cross a relay: `sealed.ts`'s
        // bytes behind `relay-wire.ts`'s version byte. Recorded separately from
        // the unframed pair above so a Swift test can assert both the Noise
        // sizes and the wire sizes and cannot satisfy one by breaking the other.
        framedHandshakeMessage: hex(withSealedVersion(started.message)),
        framedReply: hex(withSealedVersion(answered.reply)),
        channelBinding: hex(client.channelBinding),
        devicePublicKey: hex(answered.devicePublicKey),
        initiatorToResponder,
        responderToInitiator,
    }
}

const mac = identity('mac')
const device = identity('device')
const second = identity('device-two')

const payloads = [
    Buffer.from('{"t":"hello","protocol":1}', 'utf8'),
    Buffer.alloc(0),
    Buffer.from('☃ multi-byte ☃ — em dash, emoji 🧨', 'utf8'),
    // One frame past the point where a WebSocket length field grows, because a
    // Swift implementation that quietly truncates would still pass on short ones.
    Buffer.from(Array.from({ length: 70_000 }, (_, i) => i & 0xff)),
]

const vectors = {
    note: 'Generated by ios/Harness/sealed-vectors.ts from src/shared/sealed.ts and '
        + 'src/shared/relay-wire.ts. Do not hand-edit.',
    noiseName: NOISE_NAME,
    sealedVersion: SEALED_VERSION,
    /**
     * The framing the phone had no counterpart for.
     *
     * Read off `relay-wire.ts` rather than written down, so that changing the
     * contract fails `RelayWireTests` on the next regeneration instead of
     * leaving a client one byte short in silence for a fortnight.
     */
    relayWire: {
        sealedVersion: RELAY_SEALED_VERSION,
        noiseMessageBytes: NOISE_MESSAGE_BYTES,
        noiseReplyBytes: NOISE_REPLY_BYTES,
        handshakeOpenBytes: HANDSHAKE_OPEN_BYTES,
        handshakeReplyBytes: HANDSHAKE_REPLY_BYTES,
    },
    sessions: [
        session('primary', mac, device, payloads),
        session('second-device', mac, second, [Buffer.from('ls -la', 'utf8')]),
    ],
    fingerprints: [mac, device, second].map((key) => ({
        publicKey: hex(key.publicKey),
        fingerprint: fingerprint(key.publicKey),
    })),
}

// `run.sh` exports this. `import.meta.dirname` would point at the bundle in
// `.build/`, which is how the first run of this script wrote the fixture into
// a directory that does not exist in the Xcode project.
const iosDir = process.env.TD_IOS_DIR
if (!iosDir) throw new Error('TD_IOS_DIR is not set — run this through ios/Harness/run.sh')

const out = resolve(iosDir, 'Tests/Fixtures/sealed-vectors.json')
mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, `${JSON.stringify(vectors, null, 2)}\n`)
process.stdout.write(`wrote ${out}\n`)
