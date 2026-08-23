import { randomBytes } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  MAX_ENROLL_SECRET_BYTES,
  PROTOCOL_VERSION,
  parseClientMessage,
  parseServerFrame,
  serialize,
  type ClientMessage,
  type ProtocolErrorCode,
  type ServerMessage,
} from './protocol'
import {
  authenticatorFor,
  createRemoteEndpoint,
  pairingDesk,
  type RemoteEndpointOptions,
  type RemoteWire,
  type SessionAccess,
  type SessionHandle,
  SIGN_IN_NOT_SERVED,
} from './server'
import { RemoteAuth } from './device-auth'
import { DeviceKinds } from './device-kind'
import { createEnrollAccess, type EnrollAccess } from './enroll'
import type { verifyLoopbackSsh } from './ssh-verify'

const DEVICE = { name: 'Asad’s iPhone', platform: 'iOS 26' }

/* ------------------------------------------------------------- the parser -- */

function accepted(frame: unknown): ClientMessage {
  const result = parseClientMessage(frame)
  if (!result.ok) throw new Error(`expected acceptance, got ${result.code} — ${result.reason}`)
  return result.message
}

function refusedClient(frame: unknown): ProtocolErrorCode {
  const result = parseClientMessage(frame)
  expect(result.ok).toBe(false)
  if (result.ok) throw new Error('unreachable')
  return result.code
}

const validEnroll = () => ({
  t: 'enroll' as const,
  protocol: PROTOCOL_VERSION,
  device: DEVICE,
  username: 'asad',
  secret: 'hunter2',
  method: 'password' as const,
})

describe('parsing an enroll frame', () => {
  it('accepts a password and a key sign-in and round-trips them', () => {
    const password = validEnroll()
    expect(accepted(serialize(password))).toEqual(password)

    const key = {
      t: 'enroll' as const,
      protocol: PROTOCOL_VERSION,
      device: DEVICE,
      username: 'asad',
      // A PEM has real newlines; the secret validator must let them through.
      secret: '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----',
      method: 'key' as const,
      capabilities: ['controls'],
    }
    expect(accepted(serialize(key))).toEqual(key)
  })

  it('refuses a frame missing any required field', () => {
    for (const drop of ['protocol', 'device', 'username', 'secret', 'method'] as const) {
      const frame: Record<string, unknown> = validEnroll()
      delete frame[drop]
      expect(refusedClient(frame), `dropping ${drop}`).toBe('bad-message')
    }
  })

  it('refuses a method that is not one of the two', () => {
    expect(refusedClient({ ...validEnroll(), method: 'agent' })).toBe('bad-message')
    expect(refusedClient({ ...validEnroll(), method: 1 })).toBe('bad-message')
  })

  it('refuses a control character in the username but not in the secret', () => {
    // An interior control character is an injection, not stray padding — refused.
    expect(refusedClient({ ...validEnroll(), username: 'as\nad' })).toBe('bad-message')
    // Trailing whitespace a phone field added is trimmed rather than refused.
    expect(accepted(serialize({ ...validEnroll(), username: 'asad\n' }))).toBeTruthy()
    // A newline in a key secret is legal — see the PEM case above.
    expect(accepted(serialize({ ...validEnroll(), method: 'key', secret: 'a\nb' }))).toBeTruthy()
  })

  it('trims a username rather than refusing padding', () => {
    const parsed = accepted(serialize({ ...validEnroll(), username: '  asad  ' }))
    expect(parsed.t === 'enroll' && parsed.username).toBe('asad')
  })

  it('refuses a secret over the byte cap', () => {
    const tooBig = 'k'.repeat(MAX_ENROLL_SECRET_BYTES + 1)
    expect(refusedClient({ ...validEnroll(), secret: tooBig })).toBe('bad-message')
  })

  it('refuses an empty username or secret', () => {
    expect(refusedClient({ ...validEnroll(), username: '' })).toBe('bad-message')
    expect(refusedClient({ ...validEnroll(), username: '   ' })).toBe('bad-message')
    expect(refusedClient({ ...validEnroll(), secret: '' })).toBe('bad-message')
  })

  it('never quotes the secret in a refusal reason', () => {
    const result = parseClientMessage({ ...validEnroll(), secret: 'x'.repeat(MAX_ENROLL_SECRET_BYTES + 1) })
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.reason).not.toContain('x'.repeat(50))
  })
})

describe('parsing an enrolled frame', () => {
  it('reads a whole frame back', () => {
    const frame = parseServerFrame({ t: 'enrolled', deviceId: 'dev-1', deviceName: 'iPhone', credential: 'dev-1.abc' })
    expect(frame).toEqual({ ok: true, message: { t: 'enrolled', deviceId: 'dev-1', deviceName: 'iPhone', credential: 'dev-1.abc' } })
  })

  it('refuses one missing any field', () => {
    expect(parseServerFrame({ t: 'enrolled', deviceName: 'iPhone', credential: 'c' }).ok).toBe(false)
    expect(parseServerFrame({ t: 'enrolled', deviceId: 'd', credential: 'c' }).ok).toBe(false)
    expect(parseServerFrame({ t: 'enrolled', deviceId: 'd', deviceName: 'iPhone' }).ok).toBe(false)
  })

  it('refuses an oversized credential', () => {
    const huge = 'c'.repeat(1000)
    expect(parseServerFrame({ t: 'enrolled', deviceId: 'd', deviceName: 'iPhone', credential: huge }).ok).toBe(false)
  })
})

/* --------------------------------------------------------- serving enroll -- */

const ROOT = join(__dirname, '..', '..', '..')

function fakeSessions(): SessionAccess {
  return {
    list: () => [],
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
  }
}

/** A device on the far end of the transport seam, with an optional handshake key. */
interface Peer {
  received: ServerMessage[]
  send(message: ClientMessage): void
}

function connect(endpoint: ReturnType<typeof createRemoteEndpoint>, peerPublicKey?: Buffer): Peer {
  const received: ServerMessage[] = []
  let deliver: ((text: string) => void) | null = null
  endpoint.attachTransport(
    '100.64.0.2',
    (handlers) => {
      deliver = handlers.message
      const wire: RemoteWire = {
        send(text: string) {
          received.push(JSON.parse(text))
        },
        close() {
          handlers.closed()
        },
      }
      return wire
    },
    peerPublicKey,
  )
  return {
    received,
    send(message) {
      deliver?.(serialize(message))
    },
  }
}

async function waitFor<T extends ServerMessage['t']>(peer: Peer, t: T): Promise<Extract<ServerMessage, { t: T }>> {
  for (let i = 0; i < 200; i += 1) {
    const found = peer.received.find((m) => m.t === t)
    if (found) return found as Extract<ServerMessage, { t: T }>
    await new Promise((done) => setTimeout(done, 5))
  }
  throw new Error(`no ${t} arrived; saw ${peer.received.map((m) => m.t).join(', ') || 'nothing'}`)
}

/** An auth that admits nobody by credential — the enroll tests never say hello. */
const rejectAll: RemoteEndpointOptions['auth'] = {
  authenticate: async () => ({ ok: false, message: 'no' }),
}

function serve(over: Partial<RemoteEndpointOptions> = {}): ReturnType<typeof createRemoteEndpoint> {
  return createRemoteEndpoint({
    sessions: fakeSessions(),
    auth: rejectAll,
    webRoot: join(ROOT, 'nowhere'),
    pingIntervalMs: 0,
    ...over,
  })
}

/** A stand-in EnrollAccess that records whether it ran and answers as programmed. */
function fakeEnroll(
  answer:
    | Awaited<ReturnType<EnrollAccess['signIn']>>
    | (() => Promise<Awaited<ReturnType<EnrollAccess['signIn']>>>),
): EnrollAccess & { calls: number } {
  const access = {
    calls: 0,
    async signIn() {
      access.calls += 1
      return typeof answer === 'function' ? answer() : answer
    },
  }
  return access
}

const enrollFrame = (): ClientMessage => ({
  t: 'enroll',
  protocol: PROTOCOL_VERSION,
  device: DEVICE,
  username: 'asad',
  secret: 'hunter2',
  method: 'password',
})

describe('the pre-auth surface is exactly {hello, enroll}', () => {
  it('refuses any other first frame as unauthenticated', async () => {
    const peer = connect(serve())
    peer.send({ t: 'list' })
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('unauthenticated')
  })

  it('refuses an enroll once the socket is already signed in', async () => {
    // A connection that authenticated by credential, then tries to enroll.
    const auth: RemoteEndpointOptions['auth'] = {
      authenticate: async () => ({ ok: true, deviceId: 'dev-1', deviceName: 'iPhone', credential: null }),
    }
    const peer = connect(serve({ auth, enroll: fakeEnroll({ ok: false, code: 'unavailable', message: 'no' }) }))
    peer.send({ t: 'hello', protocol: PROTOCOL_VERSION, token: 'dev-1.secret', device: DEVICE })
    await waitFor(peer, 'welcome')
    peer.send(enrollFrame())
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('bad-message')
    expect(error.message).toBe('Already signed in.')
  })
})

describe('enroll on a host that does not serve it', () => {
  it('is refused unavailable, in the one sentence that means exactly that', async () => {
    const peer = connect(serve(), randomBytes(32))
    peer.send(enrollFrame())
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('unavailable')
    // Pinned to the constant rather than to a word in it. Every client turns
    // this exact pair — `unavailable` plus this sentence — into "that machine
    // does not offer sign-in", so it has to be reachable from here and from
    // nowhere else. `enroll-sentences.test.ts` holds the other end.
    expect(error.message).toBe(SIGN_IN_NOT_SERVED)
  })
})

describe('enroll with no sealed channel', () => {
  it('is refused unauthorized, and the sign-in layer is never asked', async () => {
    const enroll = fakeEnroll({ ok: true, deviceId: 'd', deviceName: 'iPhone', credential: 'd.x' })
    const peer = connect(serve({ enroll })) // no peerPublicKey → unsealed
    peer.send(enrollFrame())
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('unauthorized')
    // The probe is behind signIn; it must never run for an unsealed connection.
    expect(enroll.calls).toBe(0)
  })
})

describe('enroll single-flight', () => {
  it('refuses a second enroll while the first is still being answered', async () => {
    let resolveFirst: () => void = () => {}
    const enroll = fakeEnroll(
      () =>
        new Promise((resolve) => {
          resolveFirst = () => resolve({ ok: true, deviceId: 'd', deviceName: 'iPhone', credential: 'd.x' })
        }),
    )
    const peer = connect(serve({ enroll }), randomBytes(32))
    peer.send(enrollFrame())
    await new Promise((done) => setTimeout(done, 5))
    peer.send(enrollFrame())
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('bad-message')
    resolveFirst()
  })
})

describe('a good enroll over the seam', () => {
  it('answers enrolled with the minted credential', async () => {
    const enroll = fakeEnroll({ ok: true, deviceId: 'dev-9', deviceName: 'Asad’s iPhone', credential: 'dev-9.mintedsecret' })
    const peer = connect(serve({ enroll }), randomBytes(32))
    peer.send(enrollFrame())
    const frame = await waitFor(peer, 'enrolled')
    expect(frame).toEqual({ t: 'enrolled', deviceId: 'dev-9', deviceName: 'Asad’s iPhone', credential: 'dev-9.mintedsecret' })
  })
})

/* ------------------------------------------------ the whole road, for real -- */

const dirs: string[] = []
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

function realHost(verify: typeof verifyLoopbackSsh): {
  endpoint: ReturnType<typeof createRemoteEndpoint>
  auth: RemoteAuth
} {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-enroll-wire-'))
  dirs.push(dir)
  const auth = new RemoteAuth(dir)
  const kinds = new DeviceKinds(dir)
  const desk = pairingDesk(auth)
  const endpoint = createRemoteEndpoint({
    sessions: fakeSessions(),
    auth: authenticatorFor(auth, desk),
    enroll: createEnrollAccess({ auth, kinds, env: {}, verify }),
    webRoot: join(ROOT, 'nowhere'),
    pingIntervalMs: 0,
  })
  return { endpoint, auth }
}

describe('a wrong credential, end to end through the real parser and mint', () => {
  it('collapses to unauthorized and never echoes the secret', async () => {
    const verify: typeof verifyLoopbackSsh = async () => ({ ok: false, reason: 'auth' })
    const { endpoint } = realHost(verify)
    const peer = connect(endpoint, randomBytes(32))
    const secret = 'do-not-echo-this-7b2a'
    peer.send({ t: 'enroll', protocol: PROTOCOL_VERSION, device: DEVICE, username: 'asad', secret, method: 'password' })
    const error = await waitFor(peer, 'error')
    expect(error.code).toBe('unauthorized')
    expect(error.message).not.toContain(secret)
  })
})

describe('a real sign-in, then hello on the same socket', () => {
  it('mints a credential the follow-up hello authenticates with', async () => {
    const verify: typeof verifyLoopbackSsh = async () => ({ ok: true })
    const { endpoint } = realHost(verify)
    const key = randomBytes(32)
    const peer = connect(endpoint, key)

    peer.send({ t: 'enroll', protocol: PROTOCOL_VERSION, device: DEVICE, username: 'asad', secret: 'right', method: 'password' })
    const enrolled = await waitFor(peer, 'enrolled')
    expect(enrolled.credential).toContain('.')

    // The client stores the credential and says hello with it on the same socket.
    peer.send({ t: 'hello', protocol: PROTOCOL_VERSION, token: enrolled.credential, device: DEVICE })
    const welcome = await waitFor(peer, 'welcome')
    expect(welcome.deviceId).toBe(enrolled.deviceId)
    // Signed straight in: no pending, no second approval.
    expect(welcome.token).toBeNull()
  })

  it('refuses that credential from a different handshake key', async () => {
    const verify: typeof verifyLoopbackSsh = async () => ({ ok: true })
    const { endpoint } = realHost(verify)
    const enroller = connect(endpoint, randomBytes(32))
    enroller.send({ t: 'enroll', protocol: PROTOCOL_VERSION, device: DEVICE, username: 'asad', secret: 'right', method: 'password' })
    const enrolled = await waitFor(enroller, 'enrolled')

    // A second connection with a DIFFERENT key presents the stolen credential.
    const thief = connect(endpoint, randomBytes(32))
    thief.send({ t: 'hello', protocol: PROTOCOL_VERSION, token: enrolled.credential, device: DEVICE })
    const error = await waitFor(thief, 'error')
    expect(error.code).toBe('unauthorized')
  })
})
