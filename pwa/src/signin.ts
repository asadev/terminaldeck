/**
 * Sign-in: the client half of `enroll`, and the one screen a browser can show
 * for a server it cannot SSH into.
 *
 * ## What this is
 *
 * The pairing flow trades six typed digits for a credential; this trades a login
 * this machine already trusts. Over a sealed channel the client sends `enroll`
 * with a username and a password-or-key, the host verifies it against its own
 * sshd and answers `enrolled` with a credential, and the client then says a
 * normal `hello` with that credential **on the same socket**. The end state is
 * identical to pairing: a `StoredCredential` for a machine, saved the same way,
 * reconnected the same way. "The server is the machine, every app is a client of
 * it" — this is the door that does not need a person standing at the desktop.
 *
 * ## Why this module is transport-agnostic
 *
 * It takes a `send` and is fed decoded frames, exactly as the pairing code path
 * hands `helloMessage` to whatever is holding the socket. It does not open the
 * socket, and it deliberately does not know how the sealed channel to a
 * first-contact host was established — that is the relay/rendezvous layer's
 * problem, and a real one for a browser (see the note in the handoff). Keeping
 * the frame sequence here, pure and driven, is what lets it be tested against
 * the real `encode`/`decodeServerMessage` with no socket and no DOM.
 *
 * No `localStorage` and no `location` at module scope: the outcome is handed
 * back and the caller writes the credential, the same split `pair.ts` keeps.
 */

import {
  CLAIMED_CAPABILITIES,
  PROTOCOL_VERSION,
  encode,
  helloMessage,
  type ClientMessage,
  type DeviceDescriptor,
  type ServerMessage,
} from './protocol-client'

/**
 * The one-line install for a bare server, from `HEADLESS.md`.
 *
 * A browser cannot SSH, so it cannot install a host itself the way the native
 * clients do — it shows this command for a person to run on the machine, and
 * then sign in. Copied rather than derived: the domain is the marketing site's,
 * not the app's `BRAND`, and `HEADLESS.md` is the source that ships it.
 */
export const INSTALL_COMMAND = 'curl -fsSL https://terminaldeck.dev/install.sh | sh'

export interface SignInInput {
  username: string
  secret: string
  method: 'password' | 'key'
  device: DeviceDescriptor
}

/**
 * The frame a sign-in opens with.
 *
 * `capabilities` carries `CLAIMED_CAPABILITIES` for the same reason
 * {@link helloMessage} does: the follow-up hello need not renegotiate, and a
 * desktop that never sees `credential` here would answer a push in milliseconds
 * with "your device isn't reachable". Exported so a caller can send it without
 * the driver when it is holding the socket itself.
 */
export function enrollMessage(input: SignInInput): ClientMessage {
  return {
    t: 'enroll',
    protocol: PROTOCOL_VERSION,
    device: input.device,
    username: input.username,
    secret: input.secret,
    method: input.method,
    capabilities: CLAIMED_CAPABILITIES,
  }
}

export type SignInOutcome =
  | {
      ok: true
      /** The minted credential, `<id>.<secret>` — save this the way pairing saves its own. */
      token: string
      deviceId: string
      deviceName: string
      /** The welcome the follow-up hello earned, so the caller can read its host facts. */
      welcome: Extract<ServerMessage, { t: 'welcome' }>
    }
  | { ok: false; message: string }

/**
 * Drives one sign-in across a socket somebody else is holding.
 *
 * `start` sends `enroll` and returns a promise that settles once the exchange
 * is over; every inbound frame is handed to `receive`. The sequence is fixed:
 * `enroll` → `enrolled` → `hello` (with the new credential) → `welcome`, and a
 * refusal is the `error` frame at either step. Anything else that arrives before
 * the welcome is ignored, not acted on — a sign-in in flight is not a session
 * yet.
 */
export class SignIn {
  private stage: 'idle' | 'enrolling' | 'saying-hello' | 'done' = 'idle'
  private device: DeviceDescriptor | null = null
  private token = ''
  private deviceId = ''
  private deviceName = ''
  private settle: ((outcome: SignInOutcome) => void) | null = null

  constructor(private readonly send: (frame: ClientMessage) => void) {}

  start(input: SignInInput): Promise<SignInOutcome> {
    if (this.stage !== 'idle') throw new Error('sign-in already started')
    this.stage = 'enrolling'
    this.device = input.device
    this.send(enrollMessage(input))
    return new Promise((resolve) => {
      this.settle = resolve
    })
  }

  receive(message: ServerMessage): void {
    if (this.stage === 'done') return

    // A refusal at any step ends it, in the host's own words. `enroll`'s failure
    // is a plain `error` frame — `unauthorized` for a bad login (collapsed with a
    // rate-limited one) or `unavailable` when the host cannot offer sign-in.
    if (message.t === 'error') {
      this.finish({ ok: false, message: message.message })
      return
    }

    if (this.stage === 'enrolling' && message.t === 'enrolled') {
      this.token = message.credential
      this.deviceId = message.deviceId
      this.deviceName = message.deviceName
      this.stage = 'saying-hello'
      // The credential becomes an ordinary hello, on the same socket. The host
      // does not special-case it — the device row is already approved and bound
      // to this connection's key, so it authenticates through the normal door.
      // `device` was set by `start` before any frame could arrive; the fallback
      // is defensive and never taken.
      const device: DeviceDescriptor = this.device ?? { name: message.deviceName, platform: 'unknown' }
      this.send(helloMessage(message.credential, device))
      return
    }

    if (this.stage === 'saying-hello' && message.t === 'welcome') {
      this.finish({
        ok: true,
        token: this.token,
        deviceId: this.deviceId,
        deviceName: this.deviceName,
        welcome: message,
      })
      return
    }
    // Every other frame before the welcome is dropped: nothing this exchange
    // asked for can legitimately arrive first, and acting on one would be acting
    // on an unauthenticated socket.
  }

  /** Serialize the opening frame, for a caller that wants the bytes rather than a send. */
  static openingFrame(input: SignInInput): string {
    return encode(enrollMessage(input))
  }

  private finish(outcome: SignInOutcome): void {
    this.stage = 'done'
    const settle = this.settle
    this.settle = null
    settle?.(outcome)
  }
}
