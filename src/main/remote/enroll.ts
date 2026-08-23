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
 * The failure return carries a `code` and a sentence, never the value that
 * failed. A wrong password and a rate-limited address collapse to the same
 * `unauthorized` sentence, so the wire cannot be used to tell a bad guess from a
 * locked-out one, or to learn that a username exists. The secret is used for the
 * one probe and referenced nowhere after — not stored, not logged, not put on
 * any return.
 *
 * ## Every refusal says which of them it is, since 2026-08-23
 *
 * There used to be one sentence for four different failures, and it was
 * *`server.ts`'s* sentence — the one a host with sign-in switched off sends,
 * which is the only one of the four that means "this machine does not do
 * sign-in". A phone reads `code: 'unavailable'` and prints "that server does not
 * offer sign-in", so a server whose sshd is on a non-standard port told its
 * owner, in the host's own words, that the feature was not built into it. That
 * cost an evening. The collapse above is *only* between the refusals a remote
 * caller must not be able to tell apart — a bad guess and a lockout. Everything
 * else here is the host describing its own configuration to the person who owns
 * it, and it names the port and the variable that fixes it, because the
 * alternative is what happened.
 *
 * These are exported so a test can hold them against {@link SIGN_IN_NOT_SERVED}
 * and fail if any of them ever collides with it again.
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
export const SIGN_IN_REFUSED =
  'That sign-in was refused. Check the username, and the password or key, then try again.'

/**
 * Said when nothing answered SSH on the port this host probed.
 *
 * It names the port and the variable, and that is the whole point of it. The
 * server this was written for was running, relayed, and serving sign-in
 * perfectly; its sshd was on 2222 and the probe was dialling it. The old
 * sentence — "sign-in is not available on this machine, pair it with a code
 * instead" — was true of a demo box and of nothing else that has ever sent it,
 * and it sent its owner to the pairing screen instead of to one line of
 * configuration.
 *
 * The port is not a secret worth protecting here. A caller who can reach this
 * function has already completed a sealed handshake against this host's static
 * key, which means they were shown its pairing QR, and what they learn is a
 * number about a service that either answered them or did not. Against that: an
 * hour of the owner's evening, every time.
 *
 * `127.0.0.1` is named because the probe's constraint is not merely "sshd is
 * running" — it is `ssh you@127.0.0.1`, so an sshd bound to one interface and
 * not to loopback fails here while `ssh` from anywhere else on the network
 * works. That is the second half of the trap and it is invisible without this.
 */
export const signInNoSshd = (port: number): string =>
  `Sign-in could not be checked here: nothing answered SSH on 127.0.0.1 port ${port}. ` +
  `If this machine's SSH is on another port, set TERMINALDECK_SSHD_PORT to it and restart, ` +
  `then try again — or pair with a code instead.`

/**
 * Said when the private key that was sent could not be read at all.
 *
 * Its own sentence because the remedy is on the phone rather than on the server,
 * and because the overwhelmingly common cause is a key with a passphrase: there
 * is nowhere to type one on a sign-in form, and there deliberately never will
 * be, since the passphrase would then be a second secret crossing the wire.
 */
export const SIGN_IN_BAD_KEY =
  'That private key could not be read. If it has a passphrase, sign in with the account password instead.'

/** Said when the probe neither succeeded nor clearly failed in time. */
export const SIGN_IN_SLOW = 'The server did not answer its own sign-in in time. Try again in a moment.'

/** Said when the two-probe gate is full — an honest client that lost the race retries. */
export const SIGN_IN_BUSY = 'The server is busy checking another sign-in. Try again in a moment.'

/**
 * Said when the login was good and the device row could not be added anyway.
 *
 * Separated from the probe's refusals because it is the one failure here that
 * happens *after* the sign-in succeeded, and the person reading it has just
 * typed a correct password. Telling them their sign-in was unavailable, in the
 * sentence a host with no sign-in sends, is three wrong things at once.
 */
export const SIGN_IN_NO_ROOM =
  'That login was accepted, but this machine is already holding as many devices as it can. Remove one from its device list, then try again.'

/** The same, for a device row that could not be written to disk. */
export const SIGN_IN_NOT_SAVED =
  'That login was accepted, but this machine could not save the new device. Check that its state folder is writable, then try again.'

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
      //
      // Read once and held, so the refusal below names the port that was
      // actually dialled rather than re-reading an environment that could have
      // been changed underneath it between the two lines.
      const port = sshdPort(env)
      probesInFlight += 1
      let probe: Awaited<ReturnType<typeof verifyLoopbackSsh>>
      try {
        probe = await verify({
          username: input.username,
          secret: input.secret,
          method: input.method,
          port,
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
        // A key nobody could read is a bad credential, so it reads as
        // `unauthorized` — the code a phone puts under "that sign-in was
        // refused" — and it does not count against the limiter, because no
        // socket was opened and nothing was guessed at.
        if (probe.reason === 'bad-key') {
          return { ok: false, code: 'unauthorized', message: SIGN_IN_BAD_KEY }
        }
        /*
         * And it is said on the host too, not only to the phone.
         *
         * The evening this was written after was spent with a shell open on the
         * server, and the server's own log had nothing in it: every sign-in
         * refusal was silent here and misleading there. One line naming the
         * port turns `journalctl --user -u terminaldeck` into the answer.
         *
         * The port and nothing else. Not the username, which would put a real
         * account name in a log that gets pasted into issues, and certainly not
         * the secret — see the header.
         */
        if (probe.reason === 'no-sshd') {
          console.warn(
            `[enroll] a sign-in was refused: nothing answered SSH on 127.0.0.1:${port}. ` +
              'Set TERMINALDECK_SSHD_PORT if this machine’s sshd is on another port, and check that it binds loopback.',
          )
        }
        return {
          ok: false,
          code: 'unavailable',
          message: probe.reason === 'timeout' ? SIGN_IN_SLOW : signInNoSshd(port),
        }
      }

      // 4. Mint the pre-approved device, bound to the handshake's key.
      const minted = await deps.auth.enrollDevice(input.deviceName, input.address, input.peerPublicKey)
      if (!minted.ok) {
        // A host that is out of device slots or could not write is unavailable,
        // not a refused login; a malformed key or name should never reach here
        // (the frame was parsed and the key length checked) and collapses to the
        // refused sentence if it somehow does.
        if (minted.reason === 'too-many-devices') {
          return { ok: false, code: 'unavailable', message: SIGN_IN_NO_ROOM }
        }
        if (minted.reason === 'storage') {
          return { ok: false, code: 'unavailable', message: SIGN_IN_NOT_SAVED }
        }
        return { ok: false, code: 'unauthorized', message: SIGN_IN_REFUSED }
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
