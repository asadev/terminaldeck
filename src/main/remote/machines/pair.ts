/**
 * Typing a code into one machine so it can reach another.
 *
 * Two dials, and they are deliberately two rather than one.
 *
 *  1. **The rendezvous.** `rendezvous.ts` explains this at length: the code
 *     names a slot at the relay, the machine showing the code is sitting in it,
 *     and the channel is Noise IK against a responder key both ends derive from
 *     the code. What comes back is an *address* — a relay, a host id and a
 *     public key — and nothing else.
 *  2. **The pairing itself.** With the address in hand this is the identical
 *     path a phone takes: dial the machine, run IK against its real key, and say
 *     `hello` with the code as the token. The far end redeems it in
 *     `device-auth.ts`, mints a credential, sends it back inside `welcome`, and
 *     then refuses the connection because a human still has to approve the
 *     device.
 *
 * Folding those into one would mean the rendezvous channel serving the whole
 * protocol, which means the pairing rules living in two places — and the one
 * thing this feature must not do is grow a second answer to "who may attach".
 *
 * ## Why the refusal at the end is a success
 *
 * `welcome` arrives carrying a credential and is followed immediately by an
 * `error` frame and a closed channel. That is not a failure: it is
 * `authenticatorFor` saying "paired, and deliberately not admitted". The
 * credential has to travel or the pairing was for nothing, and the device stays
 * pending until somebody presses approve on the other machine. So this function
 * resolves on the credential and treats the close that follows as the expected
 * end of the conversation.
 */

import {
  PROTOCOL_VERSION,
  parseServerMessage,
  serialize,
} from '../protocol'
import { normaliseCode } from '../../../shared/short-code'
import { generateStatic, type StaticKeyPair } from '../../../shared/sealed'
import { dialMachine, type DialRequest, type GuestChannel } from './dial'
import { parseOffer, rendezvousIdentity, type MachineOffer } from './rendezvous'
import { describeThisMachine } from './guest'

/**
 * How long each half is given.
 *
 * The code lives sixty seconds and both dials happen inside it, so neither may
 * spend more than a fraction of that: a lookup that waited thirty seconds would
 * leave a pairing that fails on a token that expired while it was waiting, and
 * the sentence a person reads would blame the wrong thing.
 */
export const LOOKUP_TIMEOUT_MS = 12_000
export const PAIR_TIMEOUT_MS = 15_000

export type PairFailure =
  | 'bad-code'
  | 'not-found'
  | 'refused'
  | 'unreachable'

export type PairResult =
  | {
      ok: true
      offer: MachineOffer
      /** `<deviceId>.<secret>`. A bearer secret; it goes straight to the store. */
      credential: string
      deviceId: string
      deviceName: string
      guestKeys: StaticKeyPair
    }
  | { ok: false; reason: PairFailure; message: string }

export interface PairOptions {
  code: string
  /** The relay this machine dials. The far machine names its own in the offer. */
  relayUrl: string
  /** Seams for the tests, so nothing here reaches the public internet. */
  dial?: (request: DialRequest) => Promise<GuestChannel>
  freshKeys?: () => StaticKeyPair
  lookupTimeoutMs?: number
  pairTimeoutMs?: number
}

/**
 * Ask the rendezvous where the machine behind this code is.
 *
 * Exported because it is the half worth testing on its own, and because a
 * caller that wants to show "found <name>" before committing to a pairing has
 * somewhere to get the name from.
 */
export async function lookupMachine(options: PairOptions): Promise<MachineOffer | null> {
  const identity = rendezvousIdentity(options.code)
  if (identity === null) return null
  const dial = options.dial ?? dialMachine

  return new Promise<MachineOffer | null>((resolve) => {
    let settled = false
    let channel: GuestChannel | null = null
    const finish = (offer: MachineOffer | null): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      channel?.close()
      resolve(offer)
    }
    const timer = setTimeout(
      () => finish(null),
      options.lookupTimeoutMs ?? LOOKUP_TIMEOUT_MS,
    )
    timer.unref?.()

    void dial({
      relayUrl: options.relayUrl,
      hostId: identity.hostId,
      hostPublicKey: identity.keys.publicKey,
      // A throwaway identity. The rendezvous authenticates the *responder* — it
      // is the machine showing the code that has to prove it holds the code —
      // and nothing on the far side stores or looks at who dialled. Using the
      // real per-machine guest key here would put it on a channel before there
      // is a machine to associate it with.
      guestKeys: (options.freshKeys ?? generateStatic)(),
      handlers: {
        message: (text) => finish(parseOffer(text)),
        closed: () => finish(null),
      },
      timeoutMs: options.lookupTimeoutMs ?? LOOKUP_TIMEOUT_MS,
    })
      .then((opened) => {
        // The offer can already have arrived and settled this — the handshake
        // resolves the dial and the first frame can be in the same batch — in
        // which case `finish` has closed nothing, because there was nothing yet
        // to close.
        if (settled) opened.close()
        else channel = opened
      })
      .catch(() => finish(null))
  })
}

/** Find the machine behind a typed code and pair with it. */
export async function pairWithCode(options: PairOptions): Promise<PairResult> {
  const canonical = normaliseCode(options.code)
  if (canonical === null) {
    return {
      ok: false,
      reason: 'bad-code',
      message: 'That is not a pairing code. It is six digits, like 123456.',
    }
  }

  const offer = await lookupMachine({ ...options, code: canonical })
  if (offer === null) {
    return {
      ok: false,
      reason: 'not-found',
      message:
        'No machine is showing that code. Check the digits, and that the code on the other ' +
        'machine has not run out — they last a minute.',
    }
  }

  const dial = options.dial ?? dialMachine
  const guestKeys = (options.freshKeys ?? generateStatic)()

  return new Promise<PairResult>((resolve) => {
    let settled = false
    let channel: GuestChannel | null = null
    const finish = (result: PairResult): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      channel?.close()
      resolve(result)
    }
    const timer = setTimeout(
      () =>
        finish({
          ok: false,
          reason: 'unreachable',
          message: 'That machine stopped answering part-way through pairing. Try the code again.',
        }),
      options.pairTimeoutMs ?? PAIR_TIMEOUT_MS,
    )
    timer.unref?.()

    void dial({
      relayUrl: offer.relayUrl,
      hostId: offer.hostId,
      hostPublicKey: Buffer.from(offer.publicKey, 'base64'),
      guestKeys,
      handlers: {
        message: (text) => {
          const parsed = parseServerMessage(text)
          if (!parsed.ok) return
          const message = parsed.message
          if (message.t === 'welcome') {
            if (message.token === null || message.token === '') {
              // A welcome with no token on a connection that presented a
              // pairing code means the far end let this device straight in
              // without minting one, which no build of `server.ts` does. Refuse
              // rather than store a machine with nothing to reconnect with.
              finish({
                ok: false,
                reason: 'refused',
                message: 'That machine answered without a credential, so there is nothing to save.',
              })
              return
            }
            finish({
              ok: true,
              offer,
              credential: message.token,
              deviceId: message.deviceId,
              deviceName: message.deviceName,
              guestKeys,
            })
            return
          }
          if (message.t === 'error') {
            finish({
              ok: false,
              reason: 'refused',
              // The far machine's own sentence. It knows why it said no and
              // this end does not, and rewriting it here would replace
              // something specific with something vague.
              message: message.message === '' ? 'That machine refused the code.' : message.message,
            })
          }
        },
        closed: (reason) =>
          finish({ ok: false, reason: 'unreachable', message: reason }),
      },
      timeoutMs: options.pairTimeoutMs ?? PAIR_TIMEOUT_MS,
    })
      .then((opened) => {
        if (settled) {
          opened.close()
          return
        }
        channel = opened
        opened.send(
          serialize({
            t: 'hello',
            protocol: PROTOCOL_VERSION,
            token: canonical,
            device: describeThisMachine(),
          }),
        )
      })
      .catch((error: unknown) =>
        finish({
          ok: false,
          reason: 'unreachable',
          message: error instanceof Error ? error.message : String(error),
        }),
      )
  })
}
