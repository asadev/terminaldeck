/**
 * Add a server: the whole of the sign-in screen except the pixels.
 *
 * ## What was missing, and it was the screen rather than the mechanism
 *
 * `signin.ts` — the client half of `enroll` — has been written and tested since
 * the wire landed, and nothing called it. The reason is stated in its own header
 * and it was a real one: a first connection to a machine this browser has never
 * met is a Noise **IK** handshake, IK needs the responder's static public key
 * before it can send anything, and a host id is a hash of a secret rather than a
 * key. There was no valid thing to put in a form, so there was no form, so the
 * feature asked for most — *sign in to a server from the phone, without walking
 * to a desktop* — shipped as a wire with no door on it.
 *
 * `server-address.ts` is the missing half: the machine prints the three facts,
 * they are pasted, and the endpoint they decode to is exactly the endpoint every
 * paired machine is already stored with. Everything here is what happens between
 * that paste and a connected machine.
 *
 * ## Why the field checks are in this file and not beside the inputs
 *
 * `main.ts` cannot be rendered by this suite — vitest runs here with no DOM — so
 * a rule written next to an `<input>` is a rule nothing checks. The bounds are
 * the host's own (`MAX_ENROLL_USERNAME_LENGTH`, `MAX_ENROLL_SECRET_BYTES`), read
 * from the protocol rather than restated, because a client that lets somebody
 * type a username the host will refuse to parse has spent a round trip and a
 * rate-limiter slot to learn something it already knew.
 *
 * ## Why the exchange is driven here rather than by `Connection`
 *
 * `Connection` says `hello` the moment its socket opens, and it reconnects.
 * Both are wrong for this. The first frame of a sign-in is `enroll`, and a
 * reconnect that re-ran one would mint **a new device row on the host every time
 * the network blinked**. So this is one socket, one exchange, no retry — and
 * when it succeeds the caller starts an ordinary `Connection` with the
 * credential it earned. That second connection presents the same X25519
 * identity the sign-in used, which is what `enrollDevice` bound the new device
 * row to, so it walks in through the ordinary door with nothing special about
 * it.
 */

import { CHANNEL_CLOSE, type SocketLike } from './connection'
import { hostKeyBytes, type RelayEndpoint } from './endpoint'
import {
  MAX_ENROLL_SECRET_BYTES,
  MAX_ENROLL_USERNAME_LENGTH,
  decodeServerMessage,
  encode,
  type DeviceDescriptor,
  type ProtocolErrorCode,
  type ServerMessage,
} from './protocol-client'
import { relaySocket } from './relay-socket'
import { INSTALL_COMMAND, SignIn, type SignInOutcome } from './signin'
import { readServerAddress, type ReadAddress } from './server-address'
import type { StaticKeyPair } from '../../src/shared/sealed'
import { SERVER_ADDRESS_VERSION } from '../../src/shared/server-address'

/** Re-exported so the screen has one import for everything it draws. */
export { INSTALL_COMMAND }

/* ------------------------------------------------------------- the form -- */

/** How a login is proved: a password, or a private key pasted as a PEM. */
export type SignInMethod = 'password' | 'key'

export interface SignInFields {
  address: string
  username: string
  secret: string
  method: SignInMethod
}

/** Which field to point at, and the sentence to point at it with. */
export interface FieldFault {
  field: 'address' | 'username' | 'secret'
  message: string
}

export type CheckedFields =
  | { ok: true; endpoint: RelayEndpoint; username: string; secret: string; method: SignInMethod }
  | { ok: false; problem: FieldFault }

/**
 * The sentence for a paste that did not become an endpoint.
 *
 * A function rather than a lookup table because one of the three refusals has a
 * number in it, and that number is the whole value of the refusal: an address
 * announcing a format this build does not read is not a bad paste, it is two
 * builds that disagree, and the person holding it needs to be told which one to
 * move rather than sent back to their clipboard.
 */
function addressSentence(read: Extract<ReadAddress, { ok: false }>): string {
  switch (read.fault) {
    case 'empty':
      return 'Paste the server address that machine printed.'
    // Names the three facts rather than the encoding: the encoding is not
    // something a person pasting can act on, and a missing fact is.
    case 'unreadable':
      return 'That is not a server address. It is the block a machine prints for itself — the relay, its host id and its key, all three.'
    case 'version':
      // Both directions, because the sentence has to name the half that is
      // behind. Only one of them can happen today — version 1 is the first
      // there has been — and writing the pair costs a clause and means the
      // wrong one can never be printed the day there is a second.
      return read.version > SERVER_ADDRESS_VERSION
        ? `That address is version ${read.version} and this app reads version ${SERVER_ADDRESS_VERSION}, so this app is older than that server. Update this app — reload the page — and paste the address again.`
        : `That address is version ${read.version} and this app reads version ${SERVER_ADDRESS_VERSION}, so that server is older than this app. Update the server, then copy its address again.`
  }
}

/** Control characters and delete, which a login may not contain. See below. */
const CONTROL = /[\u0000-\u001f\u007f]/

/**
 * The form, checked exactly as far as this side can check it.
 *
 * A username is trimmed here because it is trimmed on the host, and a field that
 * kept a trailing space would send a login this browser had already decided was
 * fine — spending one of five attempts against the host's rate limiter on a
 * space somebody's keyboard added.
 *
 * The secret is **not** trimmed and control characters in it are **not**
 * refused, which is the one deliberate asymmetry in here and it is the host's
 * too: a `key` sign-in carries a PEM, a PEM is base64 wrapped at real newlines,
 * and the rule that makes a username safe would reject every key there is.
 */
export function checkFields(fields: SignInFields): CheckedFields {
  const address = readServerAddress(fields.address)
  if (!address.ok) {
    return { ok: false, problem: { field: 'address', message: addressSentence(address) } }
  }

  const username = fields.username.trim()
  if (username === '') {
    return {
      ok: false,
      problem: { field: 'username', message: 'Which login on that machine? The same one you would use over SSH.' },
    }
  }
  if (username.length > MAX_ENROLL_USERNAME_LENGTH) {
    return {
      ok: false,
      problem: {
        field: 'username',
        message: `That username is longer than ${MAX_ENROLL_USERNAME_LENGTH} characters, so no machine would accept it.`,
      },
    }
  }
  // Refused rather than stripped, the same choice `enrollUsername` makes on the
  // host: a login is not display text, and quietly rewriting one would sign
  // somebody in as an account they did not type.
  if (CONTROL.test(username)) {
    return {
      ok: false,
      problem: { field: 'username', message: 'That username has control characters in it. Paste the plain login name.' },
    }
  }

  if (fields.secret === '') {
    return {
      ok: false,
      problem: {
        field: 'secret',
        message:
          fields.method === 'password'
            ? 'The password for that login on that machine.'
            : 'Paste the private key — the whole PEM, both BEGIN and END lines.',
      },
    }
  }
  // Bytes, not characters, because the host measures a PEM in bytes and a client
  // that measured code units would send a key it thought was inside the bound.
  if (new TextEncoder().encode(fields.secret).length > MAX_ENROLL_SECRET_BYTES) {
    return {
      ok: false,
      problem: { field: 'secret', message: 'That is larger than any machine will accept as a login.' },
    }
  }

  return { ok: true, endpoint: address.endpoint, username, secret: fields.secret, method: fields.method }
}

/* -------------------------------------------------------- the exchange -- */

/**
 * How long one sign-in may take before this gives up on it.
 *
 * Longer than a connection's handshake timeout, and the difference is the SSH
 * probe: the host runs a real login against its own sshd in the middle of this,
 * re-arming its own no-hello timer around it precisely because the work outlasts
 * a hello's scrypt. Thirty seconds is generously past a slow probe and well
 * short of a person deciding the button is broken.
 */
export const SIGN_IN_TIMEOUT_MS = 30_000

export interface SignInRun {
  endpoint: RelayEndpoint
  username: string
  secret: string
  method: SignInMethod
  /** What this browser calls itself in the machine's device list. */
  device: DeviceDescriptor
  /** This browser's durable X25519 identity — the key the new device row is bound to. */
  deviceKeys: StaticKeyPair
  /** Seam for the suite and the live harness. Defaults to a sealed relay channel. */
  open?: () => SocketLike
  timeoutMs?: number
  /** Seam for the suite's clock, matching `connection.ts`'s. Returns the cancel. */
  after?: (ms: number, fn: () => void) => () => void
}

/**
 * Why a sign-in did not end in a machine.
 *
 * `kind` exists so the screen can decide what to *offer* rather than only what
 * to say. Two of these are states an install command is any answer to; putting
 * one under a mistyped password would be advising somebody to reinstall a server
 * that is working perfectly.
 */
export interface SignInFailure {
  ok: false
  kind: 'refused' | 'unavailable' | 'unreachable' | 'version' | 'fault'
  message: string
  /** Whether that machine might have no server on it at all. */
  install: boolean
}

export type SignInResult =
  | {
      ok: true
      /** The minted credential, `<id>.<secret>` — stored the way a pairing's own is. */
      token: string
      deviceId: string
      deviceName: string
      /** The welcome the follow-up hello earned, for the host facts on it. */
      welcome: Extract<ServerMessage, { t: 'welcome' }>
    }
  | SignInFailure

/** Nothing at that address answered a sign-in at all. See {@link closeFailure}. */
export const NOTHING_ANSWERED =
  'Nothing at that address answered a sign-in. Either that machine is not running, or it is a version that has none.'

const KEY_MISMATCH =
  'The machine answering at that address is not the one the address names. Take the address off the machine again.'

const NOT_US = 'Something other than a Terminal Deck server answered at that address.'

const CRYPTO_FAULT = 'This browser could not run the sealed handshake, so nothing was sent.'

const SLOW = 'That machine did not finish checking the login in time. Try again in a moment.'

const UNOPENABLE = 'That address cannot be opened from this page.'

/**
 * A refusal the host actually sent, in the host's own words.
 *
 * The words stay the host's because it knows things this client does not — which
 * of `unauthorized`'s several causes it hit, whether sign-in is switched off at
 * all, what version it speaks — and because `enroll.ts` deliberately collapses a
 * wrong password and a rate-limited address into one sentence. Rewriting it here
 * would either lose that collapse or invent a distinction the wire refuses to
 * make.
 *
 * `unavailable` is the one refusal that offers an install, and the reason is
 * narrow: a machine that answers *"sign-in is not available here"* is a machine
 * where the thing standing between this person and a session is what is running
 * on that box — and a browser cannot go and change it, because a browser has no
 * SSH. A wrong password is not that, and gets no command under it.
 */
export function signInFor(code: ProtocolErrorCode | null, message: string): SignInFailure {
  if (code === 'unavailable') return { ok: false, kind: 'unavailable', message, install: true }
  if (code === 'version') return { ok: false, kind: 'version', message, install: false }
  return { ok: false, kind: 'refused', message, install: false }
}

/**
 * A close with no answer on it, read as a sentence.
 *
 * The interesting case is {@link CHANNEL_CLOSE.relayUnreached} — the default
 * below — because it is what an *older host* produces and that is not obvious
 * from the name. A host that predates sign-in refuses a handshake from a device
 * key it has never seen; `isKnownDevice` is what lets an unknown key through and
 * it only says yes on a host that serves enroll. So the channel closes before a
 * single frame of the protocol crosses, and from this side that is
 * indistinguishable from a machine that is asleep. The sentence names both and
 * the install command goes under it.
 */
export function closeFailure(code: number): SignInFailure {
  switch (code) {
    case CHANNEL_CLOSE.sealedRefused:
      return { ok: false, kind: 'unreachable', message: KEY_MISMATCH, install: false }
    case CHANNEL_CLOSE.sealedFault:
      return { ok: false, kind: 'fault', message: CRYPTO_FAULT, install: false }
    case CHANNEL_CLOSE.sealedVersion:
      return {
        ok: false,
        kind: 'version',
        message: 'That machine speaks a different version of the sealed channel. Update whichever build is older.',
        install: false,
      }
    case CHANNEL_CLOSE.malformed:
      return { ok: false, kind: 'unreachable', message: NOT_US, install: false }
    default:
      return { ok: false, kind: 'unreachable', message: NOTHING_ANSWERED, install: true }
  }
}

/** The sealed channel a sign-in runs over, when the caller has not supplied one. */
function sealedChannel(run: SignInRun): SocketLike {
  const hostPublicKey = hostKeyBytes(run.endpoint.hostKey)
  // Unreachable through `checkFields`, which will not call an address valid
  // until `asEndpoint` has decoded the key. Thrown rather than asserted, so a
  // future caller that skips the check gets a refusal instead of a handshake
  // built on thirty-one bytes.
  if (hostPublicKey === null) throw new Error('the address carries no usable key')
  return relaySocket({
    relayUrl: run.endpoint.url,
    hostId: run.endpoint.hostId,
    hostPublicKey,
    deviceKeys: run.deviceKeys,
  })
}

/**
 * One sign-in, start to finish, over one socket.
 *
 * Three things can end it and each ends it exactly once: the exchange settling,
 * the socket closing, and the timeout. A refusal that arrived as a *frame* beats
 * the close that follows it — the host sends its `error` and then closes, and
 * the host's own sentence is worth more than "nothing answered" — which is why
 * the recorded refusal is consulted from `onclose` as well as from the driver.
 *
 * Nothing is stored here and nothing is connected here. The credential is handed
 * back for the caller to write where the person said it may be written, which is
 * the same split `pair.ts` keeps and for the same reason.
 */
export function runSignIn(run: SignInRun): Promise<SignInResult> {
  return new Promise<SignInResult>((resolve) => {
    let socket: SocketLike
    try {
      socket = (run.open ?? (() => sealedChannel(run)))()
    } catch {
      // `new WebSocket` throws synchronously on an address the browser will not
      // accept — a `ws://` relay from an `https:` page, most likely.
      resolve({ ok: false, kind: 'unreachable', message: UNOPENABLE, install: false })
      return
    }

    let settled = false
    let refusal: { code: ProtocolErrorCode; message: string } | null = null
    let cancelTimeout: (() => void) | null = null

    const finish = (result: SignInResult): void => {
      if (settled) return
      settled = true
      cancelTimeout?.()
      socket.onopen = null
      socket.onmessage = null
      socket.onclose = null
      socket.onerror = null
      try {
        socket.close(1000, 'sign-in finished')
      } catch {
        // Already gone. Nothing left to close and nothing to report.
      }
      resolve(result)
    }

    const after =
      run.after ??
      ((ms: number, fn: () => void) => {
        const handle = setTimeout(fn, ms)
        return () => clearTimeout(handle)
      })
    cancelTimeout = after(run.timeoutMs ?? SIGN_IN_TIMEOUT_MS, () =>
      finish({ ok: false, kind: 'unreachable', message: SLOW, install: false }),
    )

    const signIn = new SignIn((frame) => socket.send(encode(frame)))

    socket.onopen = () => {
      let running: Promise<SignInOutcome>
      try {
        running = signIn.start({
          username: run.username,
          secret: run.secret,
          method: run.method,
          device: run.device,
        })
      } catch {
        // The channel said it was open and then refused the write, so nothing
        // crossed. Read as a machine that did not answer, which is what it is.
        finish({ ok: false, kind: 'unreachable', message: NOTHING_ANSWERED, install: true })
        return
      }
      void running.then((outcome) => {
        if (outcome.ok) {
          finish({
            ok: true,
            token: outcome.token,
            deviceId: outcome.deviceId,
            deviceName: outcome.deviceName,
            welcome: outcome.welcome,
          })
          return
        }
        finish(signInFor(refusal?.code ?? null, refusal?.message ?? outcome.message))
      })
    }

    socket.onmessage = (event) => {
      if (typeof event.data !== 'string') {
        // The protocol is JSON text. A binary frame here is something that is
        // not this product on the other end.
        finish({ ok: false, kind: 'unreachable', message: NOT_US, install: false })
        return
      }
      const decoded = decodeServerMessage(event.data)
      // A frame this build cannot read is dropped rather than fatal, matching
      // `connection.ts`: a message type added on the host side arrives as
      // garbage until this client is updated, and that is not a failed sign-in.
      if (!decoded.ok) return
      const message = decoded.message
      // Recorded before it is acted on, because `SignIn` collapses every refusal
      // to its sentence and the *code* is what decides whether an install
      // command is any help.
      if (message.t === 'error') refusal = { code: message.code, message: message.message }
      signIn.receive(message)
    }

    socket.onclose = (event) => {
      // The host's own words win over a close code every time it sent any.
      if (refusal !== null) {
        finish(signInFor(refusal.code, refusal.message))
        return
      }
      finish(closeFailure(event.code))
    }

    socket.onerror = () => {
      // Browsers give no detail here on purpose; the close that follows carries
      // whatever there is to carry.
    }
  })
}
