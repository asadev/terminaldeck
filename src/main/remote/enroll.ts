/**
 * Sign-in: the one road that turns an SSH login into a paired device.
 *
 * ## Where this sits
 *
 * `server.ts` calls {@link EnrollAccess.signIn} for an `enroll` frame that
 * arrived over a sealed channel, having already refused one that arrived without
 * a key. This module owns the order the pieces run in and nothing else: the
 * limiter, the concurrency gate, the loopback probe, and the mint. Each piece is
 * somebody else's — `device-auth.ts` holds the trust store and the limiter,
 * `ssh-verify.ts` holds the probe, `device-kind.ts` holds the kind — so this
 * file is a sequence, written down once, that no caller can get out of order.
 *
 * ## The order, and why it is this order
 *
 *  1. **Rate limit first.** `auth.enrollAllowed` is read before anything else,
 *     so a guessing loop is refused without this machine spending a single SSH
 *     probe on it. The probe is a network round-trip to this host's own sshd;
 *     running it before the limiter would make this the amplifier the limiter
 *     exists to prevent.
 *  2. **Concurrency gate.** At most two probes are ever in flight at once. A
 *     third is refused rather than queued: a queue is a place to stack work an
 *     attacker generates for free, and the honest client that lost the race is
 *     one retry away.
 *  3. **Probe.** `verifyLoopbackSsh` against the port sshd is on. Only a refused
 *     login (`auth`) counts against the limiter — a missing sshd or a slow
 *     socket is the host's problem, not a guess, and must not lock anyone out.
 *  4. **Mint.** `auth.enrollDevice` writes a pre-approved row bound to the
 *     handshake's key, and `kinds.claim` records it as one of the owner's own.
 *
 * ## What crosses back, and what never does
 *
 * The failure return carries a `code` and a **static** sentence, never the value
 * that failed. A wrong password and a rate-limited address collapse to the same
 * `unauthorized` sentence, so the wire cannot be used to tell a bad guess from a
 * locked-out one, or to learn that a username exists. The secret is used for the
 * one probe and referenced nowhere after — not stored, not logged, not put on
 * any return.
 *
 * No Electron import: `device-auth`, `device-kind` and `ssh-verify` are all
 * plain Node, so the headless host builds this and a test drives it with a fake
 * verifier and a temp-dir trust store.
 */

import type { RemoteAuth } from './device-auth'
import type { DeviceKinds } from './device-kind'
import { verifyLoopbackSsh } from './ssh-verify'

/**
 * The one verb, and the two shapes of answer.
 *
 * A refusal names a wire error `code` and a sentence; success names the minted
 * device and its credential, returned in plaintext exactly once for the client
 * to store. `peerPublicKey` is **required**: a device with no sealed channel
 * cannot be bound and does not reach this — `server.ts` refuses it before the
 * call, and this type makes that a compile error rather than a runtime one.
 */
export interface EnrollAccess {
  signIn(input: {
    username: string
    secret: string
    method: 'password' | 'key'
    deviceName: string
    address: string
    peerPublicKey: Buffer
  }): Promise<
    | { ok: true; deviceId: string; deviceName: string; credential: string }
    | { ok: false; code: 'unauthorized' | 'unavailable'; message: string }
  >
}

/** OpenSSH's default. Overridable per host through the environment, not a setting. */
const DEFAULT_SSHD_PORT = 22

/**
 * The ceiling on probes in flight at once.
 *
 * Two, not one, so a second person signing in a genuine device is not made to
 * wait behind the first; and not many, because each probe is a real socket to
 * sshd and an unbounded count is a way to spend the machine. The third caller is
 * refused with a "try again" rather than queued — see the header.
 */
const MAX_CONCURRENT_PROBES = 2

/**
 * Said for a refused login and a rate-limited one alike — collapsed on purpose,
 * so the wire cannot tell a bad guess from a lockout. No platform noun, so it
 * reads the same beside a phone's label for any host.
 */
const SIGN_IN_REFUSED = 'That sign-in was refused. Check the username, and the password or key, then try again.'

/** Said when this host has no sshd to sign in against — the remedy is a pairing code. */
const SIGN_IN_UNAVAILABLE = 'Sign-in is not available on this machine. Pair it with a code instead.'

/** Said when the probe neither succeeded nor clearly failed in time. */
const SIGN_IN_SLOW = 'The server did not answer its own sign-in in time. Try again in a moment.'

/** Said when the two-probe gate is full — an honest client that lost the race retries. */
const SIGN_IN_BUSY = 'The server is busy checking another sign-in. Try again in a moment.'

/**
 * Which port sshd is on, from the environment or the standard 22.
 *
 * An environment variable rather than a setting, matching `RELAY_URL_ENV`: the
 * one host that needs a non-standard port is a box someone set up by hand, and a
 * setting for it would be a control almost nobody should touch sitting in front
 * of everybody. A value that is not a whole port number is ignored rather than
 * trusted — a typo must not point the probe somewhere odd.
 */
function sshdPort(env: NodeJS.ProcessEnv): number {
  const raw = env.TERMINALDECK_SSHD_PORT
  if (typeof raw !== 'string' || raw.trim() === '') return DEFAULT_SSHD_PORT
  const port = Number(raw)
  return Number.isInteger(port) && port > 0 && port <= 65535 ? port : DEFAULT_SSHD_PORT
}

/**
 * Build the sign-in road.
 *
 * `verify` is injectable only so a test can stand in for the real loopback probe
 * — the seam `ssh-verify.ts` carries for the same reason — and defaults to it.
 * The concurrency counter lives in this closure, so it is one per host, which is
 * what makes "two probes globally" true.
 */
export function createEnrollAccess(deps: {
  auth: RemoteAuth
  kinds: DeviceKinds
  env?: NodeJS.ProcessEnv
  verify?: typeof verifyLoopbackSsh
}): EnrollAccess {
  const env = deps.env ?? process.env
  const verify = deps.verify ?? verifyLoopbackSsh
  let probesInFlight = 0

  return {
    async signIn(input) {
      // 1. Rate limit, before a probe is spent on this address.
      if (!deps.auth.enrollAllowed(input.address).ok) {
        return { ok: false, code: 'unauthorized', message: SIGN_IN_REFUSED }
      }

      // 2. Concurrency gate. A third probe is refused, never stacked.
      if (probesInFlight >= MAX_CONCURRENT_PROBES) {
        return { ok: false, code: 'unavailable', message: SIGN_IN_BUSY }
      }

      // 3. The loopback probe against this machine's own sshd.
      probesInFlight += 1
      let probe: Awaited<ReturnType<typeof verifyLoopbackSsh>>
      try {
        probe = await verify({
          username: input.username,
          secret: input.secret,
          method: input.method,
          port: sshdPort(env),
        })
      } finally {
        probesInFlight -= 1
      }

      if (!probe.ok) {
        if (probe.reason === 'auth') {
          // The only failure that counts against the limiter and the only one
          // collapsed to the refused sentence — a missing sshd is not a guess.
          deps.auth.noteEnrollFailure(input.address)
          return { ok: false, code: 'unauthorized', message: SIGN_IN_REFUSED }
        }
        return {
          ok: false,
          code: 'unavailable',
          message: probe.reason === 'timeout' ? SIGN_IN_SLOW : SIGN_IN_UNAVAILABLE,
        }
      }

      // 4. Mint the pre-approved device, bound to the handshake's key.
      const minted = await deps.auth.enrollDevice(input.deviceName, input.address, input.peerPublicKey)
      if (!minted.ok) {
        // A host that is out of device slots or could not write is unavailable,
        // not a refused login; a malformed key or name should never reach here
        // (the frame was parsed and the key length checked) and collapses to the
        // refused sentence if it somehow does.
        return minted.reason === 'too-many-devices' || minted.reason === 'storage'
          ? { ok: false, code: 'unavailable', message: SIGN_IN_UNAVAILABLE }
          : { ok: false, code: 'unauthorized', message: SIGN_IN_REFUSED }
      }

      // 5. Record what it is: the sign-in proof is this machine's own login, so
      // the device is one of the owner's own — "it's you at another keyboard".
      deps.kinds.claim(minted.device.id, 'mine')

      return {
        ok: true,
        deviceId: minted.device.id,
        deviceName: minted.device.name,
        credential: minted.credential,
      }
    },
  }
}
