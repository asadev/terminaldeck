/**
 * Verify a username and a password-or-key against **this machine's own sshd**,
 * over the loopback interface, and then hang up.
 *
 * ## What this is, and what it is deliberately not
 *
 * This is the second factor behind sign-in: a device proves it may become one of
 * the owner's own by proving it can log in to this computer the ordinary way —
 * `ssh you@localhost`. Whoever can do that already has a shell here, so admitting
 * them as a paired device grants no authority they did not have; the sign-in is
 * a convenience over pairing, not a new hole. That is the whole argument, and it
 * only holds while the target is *this machine*: `127.0.0.1` is not a parameter
 * here, it is a constant. A function that took a host would be a general-purpose
 * SSH client with the owner's credentials, pointed anywhere a caller named.
 *
 * It connects, authenticates, and disconnects. It opens no shell, requests no
 * PTY and runs no command — the answer it wants is "did the handshake
 * authenticate", which ssh2 tells it with the `ready` event, and there is
 * nothing to run once it has that. Running anything would turn a login check
 * into a login.
 *
 * The secret's lifetime is this call. It is handed to ssh2 for the one
 * handshake, held nowhere, and gone when the promise settles.
 *
 * ## Why the reasons are only these three
 *
 * `auth` is the one that counts against the rate limiter and the one that must
 * never be guessed at — ssh2 cannot say whether the username or the secret was
 * wrong, and neither will this. `no-sshd` folds together every way the address
 * answered with something that is not a login we can complete (nothing
 * listening, something that is not an SSH server, a handshake with no algorithm
 * in common): all of them mean "this machine cannot offer sign-in", whose remedy
 * is a pairing code, not another password. `timeout` is the socket that neither
 * readied nor errored, kept separate because its remedy is "try again", not
 * "give up on sign-in".
 *
 * No Electron import and no app object: `ssh2` is a plain Node dependency (the
 * desktop connector in `servers/connection.ts` is the only other file that
 * imports it) and the client factory is injectable, so the whole thing runs
 * under vitest against a stand-in socket with nothing real listening.
 */

import { Client } from 'ssh2'

export type SshVerifyFailure = 'auth' | 'no-sshd' | 'timeout'

/** The one address this ever dials. Not a parameter — see the header. */
const LOOPBACK = '127.0.0.1'

/**
 * The outer deadline, over ssh2's own `readyTimeout`.
 *
 * A loopback handshake to a live sshd settles in well under a second; this
 * covers the case ssh2's own timeout does not — a socket that opened and then
 * neither readied nor errored, which something that is not an SSH server can
 * produce. It is longer than `readyTimeout` on purpose, so the library's own
 * timeout wins first and reports as a timeout there rather than being pre-empted.
 */
const DEFAULT_TIMEOUT_MS = 10_000

/**
 * Turn ssh2's own error signals into one of the three reasons.
 *
 * The signals are the library's own, the same ones `servers/connection.ts`
 * reads: `err.level` is `client-authentication`, `client-timeout`,
 * `client-socket`, `protocol` or `handshake`, and `err.code` carries the
 * socket's `ECONNREFUSED` / `ETIMEDOUT`. Only `client-authentication` is read as
 * `auth`; everything that is not clearly a timeout collapses to `no-sshd`,
 * because the expensive direction to be wrong in is calling a working password
 * refused — that sends someone to change a credential that was right — and
 * because a wrong guess of `auth` is the only one that spends a rate-limiter
 * slot.
 */
function classify(error: unknown): SshVerifyFailure {
  const err = (error ?? {}) as { level?: string; code?: string; message?: string }
  const code = typeof err.code === 'string' ? err.code : ''
  const level = typeof err.level === 'string' ? err.level : ''
  const said = typeof err.message === 'string' ? err.message.toLowerCase() : ''

  if (level === 'client-authentication' || said.includes('authentication methods failed')) {
    return 'auth'
  }
  if (level === 'client-timeout' || code === 'ETIMEDOUT' || said.includes('timed out while')) {
    return 'timeout'
  }
  // ECONNREFUSED (nothing listening), a banner-less close ("before handshake"),
  // a protocol mismatch (not an SSH server), or no algorithm in common — all of
  // them are "this machine cannot complete a login for us", whose remedy is a
  // pairing code rather than another password.
  return 'no-sshd'
}

/**
 * Authenticate to this machine's sshd on loopback, then disconnect.
 *
 * `newClient` is injected only so a test can stand in for a real socket — the
 * same seam `servers/connection.ts` carries — and defaults to a real ssh2
 * client. Nothing else about the dial is a parameter: the host is loopback, the
 * only variables are which port sshd is on and the login being checked.
 */
export function verifyLoopbackSsh(
  input: { username: string; secret: string; method: 'password' | 'key'; port: number; timeoutMs?: number },
  newClient: () => Client = () => new Client(),
): Promise<{ ok: true } | { ok: false; reason: SshVerifyFailure }> {
  const timeoutMs = input.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const client = newClient()

  return new Promise((resolve) => {
    let settled = false
    const finish = (value: { ok: true } | { ok: false; reason: SshVerifyFailure }): void => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      // The listeners are deliberately NOT removed. `end`/`destroy` below make
      // ssh2 emit a late `close`, and on some paths a late `error`; an emitter
      // with no `error` listener throws, so the handlers stay attached and the
      // `settled` guard turns every late event into a no-op instead. Removing
      // them would trade a clean second-settle for an uncaught exception.
      //
      // `end` is the graceful disconnect; `destroy` is the certain one. On a
      // successful auth we have what we came for and want the socket gone either
      // way, so both are called and the second is a no-op if the first took.
      try {
        client.end()
      } catch {
        // A client that never connected has nothing to end; ignore.
      }
      try {
        client.destroy()
      } catch {
        // Likewise — the socket may already be gone.
      }
      resolve(value)
    }

    const deadline = setTimeout(() => finish({ ok: false, reason: 'timeout' }), timeoutMs)
    deadline.unref?.()

    // Authenticated. Nothing is run — see the header — the handshake completing
    // is the whole answer.
    client.on('ready', () => finish({ ok: true }))
    client.on('error', (error) => finish({ ok: false, reason: classify(error) }))
    // A close with no error is not a login we completed. ssh2 emits `error`
    // before `close` on every real failure, so this only fires for the odd path
    // that closed silently, and reading it as "no sign-in here" is the safe one.
    client.on('close', () => finish({ ok: false, reason: 'no-sshd' }))

    if (input.method === 'password') {
      // Some sshd setups answer a password through the keyboard-interactive
      // challenge rather than the password method; the same string answers
      // either, and offering both is what stops a correct password reading as
      // refused. The mirror of `servers/connection.ts`.
      client.on('keyboard-interactive', (_name, _instructions, _lang, prompts, respond) => {
        respond(prompts.map(() => input.secret))
      })
    }

    try {
      client.connect({
        host: LOOPBACK,
        port: input.port,
        username: input.username,
        readyTimeout: timeoutMs,
        // No keep-alive and not this computer's ssh-agent — a login check wants
        // exactly the credential it was handed and nothing the environment adds.
        keepaliveInterval: 0,
        agent: false,
        ...(input.method === 'password'
          ? { password: input.secret, tryKeyboard: true }
          : { privateKey: input.secret }),
        // It is our own machine on loopback; we are checking that *we* can log
        // in, not who is answering, so the host key is accepted without a
        // comparison. ssh2 requires the callback to exist at all.
        hostVerifier: () => true,
      })
    } catch {
      // `connect` throws synchronously on an unreadable private key or a bad
      // config rather than emitting `error`. An unreadable key is not a login we
      // can complete here — same bucket as no sshd.
      finish({ ok: false, reason: 'no-sshd' })
    }
  })
}
