import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  createRemoteEndpoint,
  type RemoteEndpointOptions,
  type RemoteWire,
  type SessionAccess,
  type SessionHandle,
} from './server'
import type { CredentialMessage, CredentialProxy, DevicePost } from './credentials'
import { CAPABILITY, PROTOCOL_VERSION, serialize, type ClientMessage, type ServerMessage } from './protocol'

/**
 * The seam between the sockets and the credential desk, and the fact that
 * nobody has to press anything to get it.
 *
 * The bug class this repository cares most about is a feature wired to a button
 * and never wired to boot. This one has no button at all, which makes it *more*
 * exposed to that failure rather than less: the desk could be built, tested and
 * correct while `index.ts` never handed it to the server, and everything would
 * still compile, every unit test would still pass, and every push from a phone
 * would fail with "your device isn't reachable" about a device that was sitting
 * right there. So the last section of this file reads `index.ts` as text and
 * asserts the three joins exist.
 *
 * The rest exercises the routing through `attachTransport`, which is the
 * documented way to bring a connection into being over something that is not an
 * HTTP upgrade — the same door the relay uses. A WebSocket would test the
 * framing, which `server.test.ts` already does at length, and would say nothing
 * more about the thing being checked here.
 */

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

/** A desk that records what it is told rather than doing anything about it. */
function recordingProxy(): CredentialProxy & {
  post: DevicePost | null
  answered: Array<{ deviceId: string; message: CredentialMessage }>
  closed: string[]
  forgotten: string[]
} {
  const state = {
    post: null as DevicePost | null,
    answered: [] as Array<{ deviceId: string; message: CredentialMessage }>,
    closed: [] as string[],
    forgotten: [] as string[],
  }
  return {
    ...state,
    serve(post: DevicePost) {
      this.post = post
    },
    handle(deviceId: string, message: CredentialMessage) {
      this.answered.push({ deviceId, message })
    },
    connectionClosed(deviceId: string) {
      this.closed.push(deviceId)
    },
    forget(deviceId: string) {
      this.forgotten.push(deviceId)
    },
    openGuestSession: async () => {
      throw new Error('not used here')
    },
    sessionEnded: () => {},
    address: () => null,
    stop: async () => {},
  }
}

interface Peer {
  received: ServerMessage[]
  send(message: ClientMessage): void
  hangUp(): void
}

/** One connected client, over the transport seam rather than over a socket. */
function connect(
  endpoint: ReturnType<typeof createRemoteEndpoint>,
  capabilities?: string[],
  deviceName = 'iPhone',
): Peer {
  const received: ServerMessage[] = []
  let deliver: ((text: string) => void) | null = null
  let hangUp: (() => void) | null = null

  endpoint.attachTransport('100.64.0.2', (handlers) => {
    deliver = handlers.message
    hangUp = handlers.closed
    const wire: RemoteWire = {
      send(text: string) {
        received.push(JSON.parse(text))
      },
      close() {
        handlers.closed()
      },
    }
    return wire
  })

  const peer: Peer = {
    received,
    send(message) {
      deliver?.(serialize(message))
    },
    hangUp() {
      hangUp?.()
    },
  }

  peer.send({
    t: 'hello',
    protocol: PROTOCOL_VERSION,
    token: 'device-1.secret',
    device: { name: deviceName, platform: 'iOS' },
    ...(capabilities ? { capabilities } : {}),
  })
  return peer
}

/** Authentication is not what this file is about; every hello is device-1. */
const auth: RemoteEndpointOptions['auth'] = {
  authenticate: async () => ({ ok: true, deviceId: 'device-1', deviceName: 'iPhone', credential: null }),
}

function serve(credentials?: CredentialProxy): ReturnType<typeof createRemoteEndpoint> {
  return createRemoteEndpoint({
    sessions: fakeSessions(),
    auth,
    webRoot: join(ROOT, 'nowhere'),
    pingIntervalMs: 0,
    ...(credentials ? { credentials } : {}),
  })
}

/** The welcome, once the asynchronous authentication has landed. */
async function welcome(peer: Peer): Promise<Extract<ServerMessage, { t: 'welcome' }>> {
  for (let i = 0; i < 100; i += 1) {
    const found = peer.received.find((message) => message.t === 'welcome')
    if (found && found.t === 'welcome') return found
    await new Promise((done) => setTimeout(done, 5))
  }
  throw new Error('no welcome arrived')
}

describe('what a host says it can do', () => {
  it('offers the capability only when there is a proxy behind it', async () => {
    expect((await welcome(connect(serve()))).capabilities).not.toContain(CAPABILITY.credential)
    expect((await welcome(connect(serve(recordingProxy())))).capabilities).toContain(CAPABILITY.credential)
  })
})

describe('putting the question to a device', () => {
  it('asks a client that said it can answer', async () => {
    const proxy = recordingProxy()
    const endpoint = serve(proxy)
    const peer = connect(endpoint, [CAPABILITY.credential])
    await welcome(peer)

    expect(proxy.post?.reachable('device-1')).toBe(true)
    const heard = proxy.post?.ask('device-1', {
      t: 'credential.request',
      id: 'req-1',
      host: 'github.com',
      repo: 'asadev/terminaldeck',
      operation: 'write',
      prompt: true,
    })
    expect(heard).toBe(1)
    expect(peer.received.some((message) => message.t === 'credential.request')).toBe(true)
  })

  it('treats a client that never claimed it as not there', async () => {
    // The failure this closes is the one the whole feature is judged on. A phone
    // running an older build has an open socket and no code for the frame, so
    // sending it one would produce a push that waits out a deadline instead of a
    // refusal in milliseconds.
    const proxy = recordingProxy()
    const peer = connect(serve(proxy), [])
    await welcome(peer)

    expect(proxy.post?.reachable('device-1')).toBe(false)
    expect(proxy.post?.ask('device-1', {
      t: 'credential.request',
      id: 'req-1',
      host: 'github.com',
      repo: null,
      operation: 'write',
      prompt: true,
    })).toBe(0)
  })

  it('counts a client that sent no capability list at all as not there', async () => {
    // Absent is what every build before the field sends, and it means the same
    // thing as an empty list: nothing past version one.
    const proxy = recordingProxy()
    await welcome(connect(serve(proxy)))
    expect(proxy.post?.reachable('device-1')).toBe(false)
  })

  it('asks both of a person’s devices, and counts them', async () => {
    const proxy = recordingProxy()
    const endpoint = serve(proxy)
    await welcome(connect(endpoint, [CAPABILITY.credential], 'iPhone'))
    await welcome(connect(endpoint, [CAPABILITY.credential], 'iPad'))

    // One question, several places it can be seen — the same shape as the
    // prompt. Whichever answers first wins and the desk drops the rest.
    expect(
      proxy.post?.ask('device-1', {
        t: 'credential.request',
        id: 'req-1',
        host: 'github.com',
        repo: 'asadev/terminaldeck',
        operation: 'write',
        prompt: true,
      }),
    ).toBe(2)
  })
})

describe('routing an answer back', () => {
  it('hands it to the desk with the device the socket proved it is', async () => {
    const proxy = recordingProxy()
    const peer = connect(serve(proxy), [CAPABILITY.credential])
    await welcome(peer)

    peer.send({ t: 'credential.ack', id: 'req-1' })
    peer.send({ t: 'credential.answer', id: 'req-1', username: 'octocat', password: 'ghp_x', remember: true })
    peer.send({ t: 'credential.deny', id: 'req-2', reason: 'no-account' })

    expect(proxy.answered.map((entry) => entry.deviceId)).toEqual(['device-1', 'device-1', 'device-1'])
    expect(proxy.answered.map((entry) => entry.message.t)).toEqual([
      'credential.ack',
      'credential.answer',
      'credential.deny',
    ])
  })

  it('refuses an answer on a host that never asked anything', async () => {
    const peer = connect(serve(), [CAPABILITY.credential])
    await welcome(peer)
    peer.send({ t: 'credential.answer', id: 'req-1', username: 'octocat', password: 'ghp_x' })

    const error = peer.received.find((message) => message.t === 'error')
    expect(error).toMatchObject({ code: 'unauthorized', message: 'Nothing here asked this device for a login.' })
  })

  it('tells the desk when the last socket goes, so a push is not left waiting', async () => {
    const proxy = recordingProxy()
    const peer = connect(serve(proxy), [CAPABILITY.credential])
    await welcome(peer)
    peer.hangUp()
    expect(proxy.closed).toEqual(['device-1'])
  })

  it('tells the desk to forget a device that was revoked', async () => {
    const proxy = recordingProxy()
    const endpoint = serve(proxy)
    await welcome(connect(endpoint, [CAPABILITY.credential]))
    endpoint.dropDevice('device-1')
    // Before the sockets go, so anything in flight is answered with "no longer
    // allowed" rather than with "not reachable" — two different facts, and the
    // person at the terminal is owed the right one.
    expect(proxy.forgotten).toEqual(['device-1'])
  })
})

describe('nobody has to press anything', () => {
  const index = readFileSync(join(ROOT, 'src', 'main', 'index.ts'), 'utf8')

  it('builds the proxy at launch and hands it to the server', () => {
    expect(index).toContain('createCredentialProxy')
    // The join that makes the sockets and the desk the same feature. Without it
    // every push is refused as unreachable and nothing anywhere says why.
    expect(index).toMatch(/credentials:\s*credentialProxy\(\)/)
  })

  it('gives every session started for a device its own git', () => {
    // And the other join: without this the desk exists, the sockets route to it,
    // and no session ever has a key — so `git push` in a granted folder falls
    // through to the machine owner's credential helper, which is the hole all
    // of this exists to close.
    expect(index).toMatch(/openGuestSession\(input\.deviceId\)/)
    expect(index).toContain('guest.started(meta.id)')
    expect(index).toContain('guest.close()')
  })

  it('closes a session’s key when the session exits', () => {
    expect(index).toMatch(/credentialProxyIfMade\(\)\?\.sessionEnded\(id\)/)
  })

  it('actually applies the removals, which a spread cannot express', () => {
    const pty = readFileSync(join(ROOT, 'src', 'main', 'pty-manager.ts'), 'utf8')
    // `SSH_AUTH_SOCK` blank is not `SSH_AUTH_SOCK` gone, and the difference is a
    // guest session with the machine owner's ssh agent still attached to it.
    expect(pty).toContain('removeEnv')
    expect(pty).toMatch(/delete env\[/)
  })
})
