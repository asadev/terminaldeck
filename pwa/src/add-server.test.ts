import { describe, expect, it } from 'vitest'
import { parseClientMessage } from '../../src/main/remote/protocol'
import {
  INSTALL_COMMAND,
  NOTHING_ANSWERED,
  SIGN_IN_TIMEOUT_MS,
  checkFields,
  closeFailure,
  runSignIn,
  signInFor,
  type SignInFields,
} from './add-server'
import { CHANNEL_CLOSE, type SocketLike } from './connection'
import type { RelayEndpoint } from './endpoint'
import { MAX_ENROLL_SECRET_BYTES, MAX_ENROLL_USERNAME_LENGTH, type ServerMessage } from './protocol-client'
import { generateStatic } from '../../src/shared/sealed'

/**
 * The Add-server screen's logic, against the real wire on both ends.
 *
 * Every frame this sends is handed to the desktop's own `parseClientMessage`,
 * and every frame it reacts to is written as JSON and read back through the
 * client's real decoder. Nothing here compares strings: a test that hand-rolled
 * the JSON would pass against a screen that cannot talk to a host.
 *
 * The DOM is deliberately not involved. Everything a person can get wrong on
 * this screen — a pasted address, a login, a machine that will not sign anyone
 * in — is decided by a function in `add-server.ts`, precisely so that this suite
 * can ask it. See that file's header.
 */

const RELAY = 'wss://relay.terminaldeck.dev'
const HOST_ID = 'ABCDEFGHJKLMNPQRSTUVWXYZ23'
const KEY = Buffer.from(Array.from({ length: 32 }, (_, at) => at + 1)).toString('base64')
const ADDRESS = JSON.stringify({ kind: 'relay', url: RELAY, hostId: HOST_ID, hostKey: KEY })
const ENDPOINT: RelayEndpoint = { kind: 'relay', url: RELAY, hostId: HOST_ID, hostKey: KEY }

const FIELDS: SignInFields = { address: ADDRESS, username: 'asad', secret: 'hunter2', method: 'password' }

/* ------------------------------------------------------------- the form -- */

describe('what the form will let cross', () => {
  it('accepts a pasted address and a login, and trims the login', () => {
    const checked = checkFields({ ...FIELDS, username: '  asad \n' })
    expect(checked.ok).toBe(true)
    if (!checked.ok) throw new Error('unreachable')
    expect(checked.username).toBe('asad')
    expect(checked.endpoint).toEqual(ENDPOINT)
  })

  it('points at the address when there is not one', () => {
    const empty = checkFields({ ...FIELDS, address: '   ' })
    expect(empty.ok).toBe(false)
    if (empty.ok) throw new Error('unreachable')
    expect(empty.problem.field).toBe('address')
    expect(empty.problem.message).toContain('Paste')

    const junk = checkFields({ ...FIELDS, address: HOST_ID })
    expect(junk.ok).toBe(false)
    if (junk.ok) throw new Error('unreachable')
    // Names the three facts, because a host id alone is the mistake somebody
    // makes here and the sentence has to say what is missing from it.
    expect(junk.problem.message).toContain('key')
  })

  it('points at the login when there is not one', () => {
    const missing = checkFields({ ...FIELDS, username: '   ' })
    expect(missing.ok).toBe(false)
    if (missing.ok) throw new Error('unreachable')
    expect(missing.problem.field).toBe('username')
  })

  it('refuses a login the host would refuse to parse, before spending an attempt', () => {
    const long = checkFields({ ...FIELDS, username: 'a'.repeat(MAX_ENROLL_USERNAME_LENGTH + 1) })
    expect(long.ok).toBe(false)
    if (long.ok) throw new Error('unreachable')
    expect(long.problem.field).toBe('username')

    // Control characters are refused rather than stripped, the same choice
    // `enrollUsername` makes: rewriting a login signs somebody in as an account
    // they did not type.
    const control = checkFields({ ...FIELDS, username: 'as\u0007ad' })
    expect(control.ok).toBe(false)
    if (control.ok) throw new Error('unreachable')
    expect(control.problem.field).toBe('username')
  })

  it('names the missing secret by what it is asking for', () => {
    const password = checkFields({ ...FIELDS, secret: '' })
    expect(password.ok).toBe(false)
    if (password.ok) throw new Error('unreachable')
    expect(password.problem.message).toContain('password')

    const key = checkFields({ ...FIELDS, secret: '', method: 'key' })
    expect(key.ok).toBe(false)
    if (key.ok) throw new Error('unreachable')
    expect(key.problem.message).toContain('PEM')
  })

  it('lets a PEM through with its newlines, which is the whole point of the key method', () => {
    const pem = `-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n`
    const checked = checkFields({ ...FIELDS, secret: pem, method: 'key' })
    expect(checked.ok).toBe(true)
    if (!checked.ok) throw new Error('unreachable')
    // Untrimmed: a PEM's trailing newline is part of the file.
    expect(checked.secret).toBe(pem)
  })

  it('measures the secret in bytes, the way the host does', () => {
    // Half as many code units as the bound, twice as many bytes. A client that
    // counted characters would send this and be refused after the round trip.
    const wide = '☃'.repeat(MAX_ENROLL_SECRET_BYTES / 2)
    const checked = checkFields({ ...FIELDS, secret: wide, method: 'key' })
    expect(checked.ok).toBe(false)
  })
})

/* ---------------------------------------------------------- the sentences -- */

describe('what a failure offers to do about itself', () => {
  it('offers an install only where a missing server is the explanation', () => {
    // A machine that says it has no sign-in, and a machine that says nothing at
    // all: in both, what stands in the way is what is running on that box.
    expect(signInFor('unavailable', 'Sign-in is not available on this machine.').install).toBe(true)
    expect(closeFailure(CHANNEL_CLOSE.relayUnreached).install).toBe(true)

    // A wrong password is not that, and a browser suggesting a reinstall over
    // one would be advice to break a working server.
    expect(signInFor('unauthorized', 'That sign-in was refused.').install).toBe(false)
    expect(signInFor('version', 'Update whichever is older.').install).toBe(false)
    expect(closeFailure(CHANNEL_CLOSE.sealedRefused).install).toBe(false)
    expect(closeFailure(CHANNEL_CLOSE.sealedFault).install).toBe(false)
  })

  it('keeps the host words for a refusal, because it knows what this client cannot', () => {
    const said = 'That sign-in was refused. Check the username, and the password or key, then try again.'
    expect(signInFor('unauthorized', said)).toEqual({ ok: false, kind: 'refused', message: said, install: false })
  })

  it('reads a channel that closed with no answer as a machine that may not be there', () => {
    // The old-host signature: a host that predates sign-in refuses a handshake
    // from a device key it has never seen, so nothing of the protocol crosses.
    expect(closeFailure(CHANNEL_CLOSE.relayUnreached).message).toBe(NOTHING_ANSWERED)
    expect(closeFailure(1006).message).toBe(NOTHING_ANSWERED)
  })

  it('says a wrong key is a wrong machine rather than a wrong login', () => {
    expect(closeFailure(CHANNEL_CLOSE.sealedRefused).message).toContain('is not the one the address names')
  })

  it('offers a command a person can actually run on the machine', () => {
    expect(INSTALL_COMMAND).toContain('install.sh')
    expect(INSTALL_COMMAND).toContain('| sh')
  })
})

/* -------------------------------------------------------- the exchange -- */

/** A socket the test drives by hand, standing where the sealed channel stands. */
function fakeSocket(): SocketLike & { sent: string[]; closes: number[] } {
  const socket: SocketLike & { sent: string[]; closes: number[] } = {
    sent: [],
    closes: [],
    send: (data) => socket.sent.push(data),
    close: (code) => socket.closes.push(code ?? 0),
    onopen: null,
    onmessage: null,
    onclose: null,
    onerror: null,
  }
  return socket
}

const DEVICE = { name: 'Chrome on Mac', platform: 'macOS' }

function run(socket: SocketLike, options: { after?: (ms: number, fn: () => void) => () => void } = {}) {
  return runSignIn({
    endpoint: ENDPOINT,
    username: 'asad',
    secret: 'hunter2',
    method: 'password',
    device: DEVICE,
    deviceKeys: generateStatic(),
    open: () => socket,
    after: options.after,
  })
}

/** A server frame as it really crosses: JSON on the wire, decoded by the client. */
function say(socket: SocketLike, message: ServerMessage): void {
  socket.onmessage?.({ data: JSON.stringify(message) })
}

const WELCOME: ServerMessage = {
  t: 'welcome',
  protocol: 1,
  deviceId: 'dev-9',
  deviceName: 'Chrome on Mac',
  token: null,
  sessions: [],
  capabilities: [],
  hostPlatform: 'linux',
  hostName: 'basil',
}

describe('one sign-in over one socket', () => {
  it('enrolls, says hello with what it earned, and reports the welcome', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()

    // The first frame is an enroll the desktop's own parser accepts.
    expect(socket.sent).toHaveLength(1)
    const enroll = parseClientMessage(socket.sent[0] as string)
    expect(enroll.ok).toBe(true)
    if (!enroll.ok || enroll.message.t !== 'enroll') throw new Error('not an enroll')
    expect(enroll.message.username).toBe('asad')
    expect(enroll.message.method).toBe('password')

    say(socket, { t: 'enrolled', deviceId: 'dev-9', deviceName: 'Chrome on Mac', credential: 'dev-9.mint' })

    // The credential becomes an ordinary hello on the same socket.
    expect(socket.sent).toHaveLength(2)
    const hello = parseClientMessage(socket.sent[1] as string)
    if (!hello.ok || hello.message.t !== 'hello') throw new Error('not a hello')
    expect(hello.message.token).toBe('dev-9.mint')

    say(socket, WELCOME)

    const result = await done
    expect(result.ok).toBe(true)
    if (!result.ok) throw new Error('unreachable')
    expect(result.token).toBe('dev-9.mint')
    expect(result.deviceId).toBe('dev-9')
    // The welcome rides back so the caller can name the machine without a
    // second round trip.
    expect(result.welcome.hostName).toBe('basil')
    expect(result.welcome.hostPlatform).toBe('linux')
    // And the socket is let go: this connection was for the exchange, not for
    // the session that follows it.
    expect(socket.closes).toHaveLength(1)
  })

  it('reports a refused login in the host own words, with no install under it', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    const said = 'That sign-in was refused. Check the username, and the password or key, then try again.'
    say(socket, { t: 'error', code: 'unauthorized', message: said })
    // The host closes behind its refusal, and the refusal must still be what is
    // reported — not the close.
    socket.onclose?.({ code: 1008, reason: 'policy' })

    const result = await done
    expect(result).toEqual({ ok: false, kind: 'refused', message: said, install: false })
  })

  it('reports a machine that serves no sign-in, and offers the install', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    const said = 'Sign-in is not available on this machine. Pair it with a code instead.'
    say(socket, { t: 'error', code: 'unavailable', message: said })

    const result = await done
    expect(result).toEqual({ ok: false, kind: 'unavailable', message: said, install: true })
  })

  it('reads a channel that closed before answering as an older host, or none', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    socket.onclose?.({ code: CHANNEL_CLOSE.relayUnreached, reason: 'gone' })

    const result = await done
    expect(result).toEqual({ ok: false, kind: 'unreachable', message: NOTHING_ANSWERED, install: true })
  })

  it('gives up on a machine that never finishes checking, on the clock it is given', async () => {
    const socket = fakeSocket()
    let fire: (() => void) | null = null
    let waited = 0
    const done = run(socket, {
      after: (ms, fn) => {
        waited = ms
        fire = fn
        return () => {
          fire = null
        }
      },
    })
    socket.onopen?.()
    expect(waited).toBe(SIGN_IN_TIMEOUT_MS)
    expect(fire).not.toBeNull()
    ;(fire as unknown as () => void)()

    const result = await done
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.kind).toBe('unreachable')
    expect(result.install).toBe(false)
  })

  it('settles once, whatever arrives afterwards', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    say(socket, { t: 'enrolled', deviceId: 'dev-9', deviceName: 'Chrome on Mac', credential: 'dev-9.mint' })
    say(socket, WELCOME)
    const result = await done
    expect(result.ok).toBe(true)

    // Everything is unhooked at the settle, so a late close cannot resolve a
    // second time or send a second frame.
    expect(socket.onclose).toBeNull()
    expect(socket.onmessage).toBeNull()
    expect(socket.sent).toHaveLength(2)
  })

  it('ignores a frame it cannot read rather than failing the sign-in on it', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    // A frame from a newer host. Dropped, exactly as `connection.ts` drops one.
    socket.onmessage?.({ data: '{"t":"something-new"}' })
    say(socket, { t: 'enrolled', deviceId: 'dev-9', deviceName: 'Chrome on Mac', credential: 'dev-9.mint' })
    say(socket, WELCOME)
    expect((await done).ok).toBe(true)
  })

  it('refuses a binary answer, which is not this protocol', async () => {
    const socket = fakeSocket()
    const done = run(socket)
    socket.onopen?.()
    socket.onmessage?.({ data: new Uint8Array([1, 2, 3]) })
    const result = await done
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.message).toContain('Something other than')
  })

  it('says an address the browser will not open cannot be opened', async () => {
    const result = await runSignIn({
      endpoint: ENDPOINT,
      username: 'asad',
      secret: 'hunter2',
      method: 'password',
      device: DEVICE,
      deviceKeys: generateStatic(),
      open: () => {
        throw new Error('mixed content')
      },
    })
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.kind).toBe('unreachable')
    expect(result.install).toBe(false)
  })
})
