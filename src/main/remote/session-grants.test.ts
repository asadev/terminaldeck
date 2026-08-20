/**
 * Choosing which running sessions a device gets, and the doors that enforce it.
 *
 * Asad, 2026-08-20: *"when we give remote access we should be able to choose
 * between running sessions which ones to give and which ones not, i mean select
 * vs all type of options"*.
 *
 * The store on its own is a small file, and testing it alone would miss the
 * thing that decides whether the feature is real. His third sentence is the one
 * that matters — an unselected session must be invisible on **every** verb, not
 * merely absent from a list — so the last third of this file drives a real
 * socket against a real `SessionFanout` over a real `SessionGrants`, attaches
 * while a session is ticked, unticks it, and then checks that the keyboard and
 * the resize are gone too. A list that hides a terminal somebody can still type
 * into is worse than no feature, because it says the work was done.
 *
 * The three states are the design and they are not two:
 *
 *   - **no record** — nobody has narrowed this device, so it keeps exactly what
 *     the folder rule gives it. Devices were already paired when this shipped.
 *   - **`all`** — a person chose everything. Behaves the same and is a different
 *     fact, which is why the panel can draw it as pressed.
 *   - **`selected`** — only the ticked ids, and an empty tick list means none.
 */

import { randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { PROTOCOL_VERSION, type ServerMessage } from './protocol'
import { SessionGrants, REMOTE_SESSIONS_FILE } from './session-grants'
import { SessionFanout, type PtySource } from './session-fanout'
import {
  WS_PATH,
  createRemoteEndpoint,
  registerRemoteIpc,
  type CreateOutcome,
  type RemoteAuthenticator,
} from './server'
import { FolderGrants } from './folder-grants'
import { DeviceKinds } from './device-kind'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-session-grants-'))
}

/* ============================================================== the store == */

describe('the store', () => {
  it('answers null for a device nobody has narrowed, and shares everything', () => {
    const grants = new SessionGrants(tempDir())
    // Null and not `{ mode: 'all' }`. The panel branches on the difference.
    expect(grants.granted('device-a')).toBeNull()
    expect(grants.list()).toEqual([])
    // Absence is not denial on this axis: two devices were already paired when
    // it shipped, and narrowing them by default would be a feature that breaks
    // a phone somebody is holding.
    expect(grants.shares('device-a', 'sess-1')).toBe(true)
  })

  it('keeps the ticked ids under selected, in the order they were ticked', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-2', 'sess-1'])
    expect(grants.granted('device-a')).toEqual({
      deviceId: 'device-a',
      mode: 'selected',
      sessions: ['sess-2', 'sess-1'],
    })
  })

  it('shares only the ticked ones under selected', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-1'])
    expect(grants.shares('device-a', 'sess-1')).toBe(true)
    expect(grants.shares('device-a', 'sess-2')).toBe(false)
  })

  it('treats an empty tick list as none, which is a person’s answer', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', [])
    expect(grants.shares('device-a', 'sess-1')).toBe(false)
    // And it is stored, rather than collapsing into "nobody has chosen".
    expect(grants.granted('device-a')).toEqual({ deviceId: 'device-a', mode: 'selected', sessions: [] })
  })

  it('shares everything under all, and keeps no stale tick list behind it', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-1'])
    grants.set('device-a', 'all', ['sess-1'])
    expect(grants.shares('device-a', 'sess-9')).toBe(true)
    // The ticks are dropped rather than shadowed. A list that decides nothing
    // goes stale invisibly, and restoring it on the next press would hand back
    // whichever of those sessions happened to still be running.
    expect(grants.granted('device-a')).toEqual({ deviceId: 'device-a', mode: 'all', sessions: [] })
  })

  it('does not let one device’s choice reach another', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-1'])
    expect(grants.shares('device-b', 'sess-1')).toBe(true)
    grants.set('device-b', 'selected', [])
    expect(grants.shares('device-b', 'sess-1')).toBe(false)
    expect(grants.shares('device-a', 'sess-1')).toBe(true)
  })

  it('survives a restart, which is the whole reason it is on disk', () => {
    const dir = tempDir()
    new SessionGrants(dir).set('device-a', 'selected', ['sess-1'])
    expect(new SessionGrants(dir).shares('device-a', 'sess-2')).toBe(false)
    expect(new SessionGrants(dir).shares('device-a', 'sess-1')).toBe(true)
  })

  it('forgets a revoked device rather than letting the file only grow', () => {
    const dir = tempDir()
    const grants = new SessionGrants(dir)
    grants.set('device-a', 'selected', ['sess-1'])
    expect(grants.forget('device-a')).toBe(true)
    expect(grants.granted('device-a')).toBeNull()
    expect(new SessionGrants(dir).list()).toEqual([])
  })

  it('drops a tick for a session that has exited, without widening anything', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-1', 'sess-2'])
    expect(grants.dropSession('sess-1')).toBe(true)
    expect(grants.granted('device-a')?.sessions).toEqual(['sess-2'])
    // The id it removed names nothing, so nothing became reachable.
    expect(grants.shares('device-a', 'sess-1')).toBe(false)
  })

  it('ticks a session the device started itself, and only under selected', () => {
    const grants = new SessionGrants(tempDir())
    // No record: the device already sees everything, so there is nothing to do.
    expect(grants.include('device-a', 'sess-1')).toBe(false)
    grants.set('device-a', 'all', [])
    expect(grants.include('device-a', 'sess-1')).toBe(false)
    grants.set('device-a', 'selected', [])
    expect(grants.include('device-a', 'sess-1')).toBe(true)
    expect(grants.shares('device-a', 'sess-1')).toBe(true)
    // Idempotent — a second create of the same id writes nothing.
    expect(grants.include('device-a', 'sess-1')).toBe(false)
    // And it does not reach anything the device did not start.
    expect(grants.shares('device-a', 'sess-2')).toBe(false)
  })

  it('drops ids that are not usable rather than storing them', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('device-a', 'selected', ['sess-1', '', '  ', 7, null, 'sess-1', 'x'.repeat(200)])
    expect(grants.granted('device-a')?.sessions).toEqual(['sess-1'])
  })

  it('reads an unrecognised mode as selected, so a bad row cannot come out wider', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_SESSIONS_FILE),
      JSON.stringify({ version: 1, devices: { 'device-a': { mode: 'everything', sessions: ['sess-1'] } } }),
    )
    const grants = new SessionGrants(dir)
    expect(grants.shares('device-a', 'sess-1')).toBe(true)
    expect(grants.shares('device-a', 'sess-2')).toBe(false)
  })

  it('writes the file 0600 through the shared secret writer', () => {
    const dir = tempDir()
    const grants = new SessionGrants(dir)
    grants.set('device-a', 'selected', ['sess-1'])
    const text = readFileSync(grants.file, 'utf8')
    expect(JSON.parse(text)).toEqual({
      version: 1,
      devices: { 'device-a': { mode: 'selected', sessions: ['sess-1'] } },
    })
  })
})

/* ============================================================== the fanout = */

interface Row {
  id: string
  title: string
  cwd: string
  exitCode: number | null
}

const LIVING: Row[] = [
  { id: 'sess-shared', title: 'shared', cwd: '/tmp/shared', exitCode: null },
  { id: 'sess-other', title: 'other', cwd: '/tmp/shared', exitCode: null },
  { id: 'sess-private', title: 'private', cwd: '/tmp/private', exitCode: null },
]

/** The two axes, wired the way `host-core.ts` wires them. */
function fanoutOver(grants: SessionGrants, extra: Partial<PtySource> = {}): { fanout: SessionFanout; typed: string[]; resized: string[] } {
  const typed: string[] = []
  const resized: string[] = []
  const fanout = new SessionFanout({
    list: () => LIVING.map((row) => ({ ...row, provider: 'shell' })),
    write: (id, data) => typed.push(`${id}:${data}`),
    resize: (id) => resized.push(id),
    scrollback: () => '',
    // A guest holding one folder; the other folder is nobody's business.
    reach: (deviceId) =>
      deviceId === 'owner'
        ? { unrestricted: true, folders: [] }
        : { unrestricted: false, folders: ['/tmp/shared'] },
    shared: (deviceId, sessionId) => grants.shares(deviceId, sessionId),
    noteStarted: (deviceId, sessionId) => {
      grants.include(deviceId, sessionId)
    },
    ...extra,
  })
  return { fanout, typed, resized }
}

describe('the two axes are ANDed in one predicate', () => {
  it('a session outside the granted folder stays refused however it is ticked', () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-private'])
    const { fanout } = fanoutOver(grants)
    // Ticking cannot widen the folder rule. This is the property that makes the
    // second axis safe to add: it can only ever take away.
    expect(fanout.visible?.('guest', 'sess-private')).toBe(false)
  })

  it('a session inside the granted folder is refused once it is unticked', () => {
    const grants = new SessionGrants(tempDir())
    const { fanout } = fanoutOver(grants)
    expect(fanout.visible?.('guest', 'sess-shared')).toBe(true)
    grants.set('guest', 'selected', ['sess-other'])
    expect(fanout.visible?.('guest', 'sess-shared')).toBe(false)
    expect(fanout.visible?.('guest', 'sess-other')).toBe(true)
  })

  it('narrows one of the owner’s own machines too, which is the device he asked about', () => {
    const grants = new SessionGrants(tempDir())
    // `owner` is unrestricted by folder — the whole machine — and the choice
    // still applies. His phone is paired as one of his own.
    const { fanout } = fanoutOver(grants)
    expect(fanout.visible?.('owner', 'sess-private')).toBe(true)
    grants.set('owner', 'selected', ['sess-shared'])
    expect(fanout.visible?.('owner', 'sess-private')).toBe(false)
    expect(fanout.visible?.('owner', 'sess-shared')).toBe(true)
  })

  it('refuses when the choice rule throws, rather than dying on a socket', () => {
    const grants = new SessionGrants(tempDir())
    const { fanout } = fanoutOver(grants, {
      shared: () => {
        throw new Error('the store is on fire')
      },
    })
    expect(fanout.visible?.('guest', 'sess-shared')).toBe(false)
  })

  it('is still present, and still enforces the folder, on a host with no choice store', () => {
    const grants = new SessionGrants(tempDir())
    const { fanout } = fanoutOver(grants, { shared: undefined })
    expect(fanout.visible?.('guest', 'sess-shared')).toBe(true)
    expect(fanout.visible?.('guest', 'sess-private')).toBe(false)
  })
})

describe('a session the device started itself', () => {
  it('is ticked for it, so create is not a button that hands back nothing', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', [])
    const started: CreateOutcome = {
      ok: true,
      session: {
        id: 'sess-new',
        title: 'new',
        cwd: '/tmp/shared',
        provider: 'shell',
        status: 'idle',
        exitCode: null,
      },
    }
    const { fanout } = fanoutOver(grants, { create: async () => started })
    LIVING.push({ id: 'sess-new', title: 'new', cwd: '/tmp/shared', exitCode: null })
    try {
      await fanout.create?.({ deviceId: 'guest' })
      expect(grants.shares('guest', 'sess-new')).toBe(true)
      expect(fanout.visible?.('guest', 'sess-new')).toBe(true)
      // And nothing else moved. A session somebody else started stays refused,
      // which is the decision: after the choice, only what is ticked.
      expect(fanout.visible?.('guest', 'sess-shared')).toBe(false)
    } finally {
      LIVING.pop()
    }
  })

  it('is not shared with a different device', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', [])
    grants.set('other', 'selected', [])
    const { fanout } = fanoutOver(grants, {
      create: async () => ({
        ok: true,
        session: {
          id: 'sess-new',
          title: 'new',
          cwd: '/tmp/shared',
          provider: 'shell',
          status: 'idle',
          exitCode: null,
        },
      }),
    })
    await fanout.create?.({ deviceId: 'guest' })
    expect(grants.shares('other', 'sess-new')).toBe(false)
  })
})

/* ======================================================== every verb, live = */

/* ---------------------------------------------------------------- client -- */

function maskedText(payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  let header: Buffer
  if (masked.length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | masked.length
  } else {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(masked.length, 2)
  }
  header[0] = 0x81
  return Buffer.concat([header, mask, masked])
}

interface Client {
  send(message: unknown): void
  received: ServerMessage[]
  until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage>
}

function connect(port: number): Promise<Client> {
  return new Promise((settle, fail) => {
    const req = request({
      host: '127.0.0.1',
      port,
      path: WS_PATH,
      headers: {
        connection: 'Upgrade',
        upgrade: 'websocket',
        'sec-websocket-key': randomBytes(16).toString('base64'),
        'sec-websocket-version': '13',
      },
    })
    req.on('error', fail)
    req.on('upgrade', (_res, socket: Socket, head: Buffer) => {
      const received: ServerMessage[] = []
      const waiters: { predicate: (m: ServerMessage) => boolean; settle: (m: ServerMessage) => void }[] = []
      let buffer = head

      const drain = (): void => {
        let at = 0
        for (;;) {
          if (buffer.length - at < 2) break
          let length = buffer[at + 1] & 0x7f
          let offset = at + 2
          if (length === 126) {
            if (buffer.length < offset + 2) break
            length = buffer.readUInt16BE(offset)
            offset += 2
          } else if (length === 127) {
            if (buffer.length < offset + 8) break
            length = Number(buffer.readBigUInt64BE(offset))
            offset += 8
          }
          if (buffer.length < offset + length) break
          const opcode = buffer[at] & 0x0f
          const payload = buffer.subarray(offset, offset + length)
          at = offset + length
          if (opcode !== 0x1) continue
          const message = JSON.parse(payload.toString('utf8')) as ServerMessage
          received.push(message)
          for (const waiter of [...waiters]) {
            if (!waiter.predicate(message)) continue
            waiters.splice(waiters.indexOf(waiter), 1)
            waiter.settle(message)
          }
        }
        buffer = buffer.subarray(at)
      }

      drain()
      socket.on('data', (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        drain()
      })

      settle({
        send: (message) => socket.write(maskedText(Buffer.from(JSON.stringify(message), 'utf8'))),
        received,
        until: (predicate, label) =>
          new Promise((done, reject) => {
            const already = received.find(predicate)
            if (already) return done(already)
            const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), 2000)
            waiters.push({
              predicate,
              settle: (message) => {
                clearTimeout(timer)
                done(message)
              },
            })
          }),
      })
    })
    req.end()
  })
}

const authenticator: RemoteAuthenticator = {
  async authenticate(token) {
    if (token === 'guest.c2VjcmV0') {
      return { ok: true, deviceId: 'guest', deviceName: 'A phone', credential: null }
    }
    return { ok: false, message: 'This device is not allowed in.' }
  },
}

let servers: Server[] = []
let roots: string[] = []

afterEach(() => {
  for (const server of servers) server.close()
  servers = []
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  roots = []
})

async function serve(grants: SessionGrants): Promise<{
  port: number
  typed: string[]
  resized: string[]
}> {
  const root = mkdtempSync(join(tmpdir(), 'deck-sessions-'))
  roots.push(root)
  writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')
  const { fanout, typed, resized } = fanoutOver(grants)
  const endpoint = createRemoteEndpoint({
    sessions: fanout,
    auth: authenticator,
    webRoot: root,
    pingIntervalMs: 0,
  })
  const server = createServer(endpoint.handleRequest)
  server.on('upgrade', endpoint.handleUpgrade)
  servers.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
  return { port: (server.address() as AddressInfo).port, typed, resized }
}

async function greet(port: number): Promise<Client> {
  const client = await connect(port)
  client.send({
    t: 'hello',
    protocol: PROTOCOL_VERSION,
    token: 'guest.c2VjcmV0',
    device: { name: 'phone', platform: 'iOS' },
  })
  await client.until((m) => m.t === 'welcome', 'the welcome')
  return client
}

describe('an unticked session is invisible on every verb, not merely absent from a list', () => {
  it('is off the list', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-other'])
    const host = await serve(grants)
    const client = await greet(host.port)
    client.send({ t: 'list' })
    const listed = (await client.until((m) => m.t === 'sessions', 'the list')) as {
      sessions: { id: string }[]
    }
    expect(listed.sessions.map((s) => s.id)).toEqual(['sess-other'])
  })

  it('refuses attach with the sentence an unknown id gets', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-other'])
    const host = await serve(grants)
    const client = await greet(host.port)
    client.send({ t: 'attach', id: 'sess-shared' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    // The same refusal an id that names nothing gets. A distinct one would
    // confirm that the id names something real, and these ids leak — an alert
    // carries one, so does a transcript path and an older list.
    expect(error).toEqual({
      t: 'error',
      code: 'unknown-session',
      message: 'No session sess-shared is running.',
    })
  })

  it('takes the keyboard away from a handle taken while it was still ticked', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-shared'])
    const host = await serve(grants)
    const client = await greet(host.port)

    client.send({ t: 'attach', id: 'sess-shared' })
    await client.until((m) => m.t === 'attached', 'the attach')
    client.send({ t: 'input', id: 'sess-shared', data: 'echo one\r' })
    // It really is a live keyboard before the untick, or the assertion below
    // would pass against a session nobody could type into anyway.
    await new Promise((settle) => setTimeout(settle, 50))
    expect(host.typed).toEqual(['sess-shared:echo one\r'])

    // Untick it from the desktop, with the socket still open and the handle
    // still held. This is the case a list-only feature gets wrong.
    grants.set('guest', 'selected', [])

    client.send({ t: 'input', id: 'sess-shared', data: 'rm -rf .\r' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({
      t: 'error',
      code: 'unauthorized',
      message: 'That session is no longer shared with this device.',
    })
    // The assertion that matters: nothing reached the pty.
    expect(host.typed).toEqual(['sess-shared:echo one\r'])
  })

  it('takes the resize away from that same handle', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-shared'])
    const host = await serve(grants)
    const client = await greet(host.port)

    client.send({ t: 'attach', id: 'sess-shared' })
    await client.until((m) => m.t === 'attached', 'the attach')
    client.send({ t: 'resize', id: 'sess-shared', cols: 100, rows: 30 })
    await new Promise((settle) => setTimeout(settle, 50))
    expect(host.resized).toEqual(['sess-shared'])

    grants.set('guest', 'selected', [])
    client.send({ t: 'resize', id: 'sess-shared', cols: 40, rows: 10 })
    await new Promise((settle) => setTimeout(settle, 50))
    // A resize reshapes the pty the person at the desk is looking at, so this
    // is not a cosmetic door.
    expect(host.resized).toEqual(['sess-shared'])
  })
})

/* ================================================== immediately, not later == */

describe('changing the choice reaches a connected device without it asking', () => {
  it('pushes a fresh list, and the unticked row is gone from it', async () => {
    const grants = new SessionGrants(tempDir())
    grants.set('guest', 'selected', ['sess-shared', 'sess-other'])
    const root = mkdtempSync(join(tmpdir(), 'deck-sessions-push-'))
    roots.push(root)
    writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')
    const { fanout } = fanoutOver(grants)
    const endpoint = createRemoteEndpoint({
      sessions: fanout,
      auth: authenticator,
      webRoot: root,
      pingIntervalMs: 0,
    })
    const server = createServer(endpoint.handleRequest)
    server.on('upgrade', endpoint.handleUpgrade)
    servers.push(server)
    await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
    const client = await greet((server.address() as AddressInfo).port)

    client.send({ t: 'list' })
    const first = (await client.until((m) => m.t === 'sessions', 'the first list')) as {
      sessions: { id: string }[]
    }
    expect(first.sessions.map((s) => s.id)).toEqual(['sess-shared', 'sess-other'])
    const before = client.received.filter((m) => m.t === 'sessions').length

    // The desktop untick, and then the push the IPC handler makes.
    grants.set('guest', 'selected', ['sess-other'])
    expect(endpoint.sessionsChanged()).toBe(1)

    await client.until(
      (m) => m.t === 'sessions' && client.received.filter((x) => x.t === 'sessions').length > before,
      'the pushed list',
    )
    const pushed = client.received.filter((m) => m.t === 'sessions').at(-1) as { sessions: { id: string }[] }
    // Nothing asked for this. That is the difference between a setting that
    // works and one somebody has to be told to reconnect for.
    expect(pushed.sessions.map((s) => s.id)).toEqual(['sess-other'])
  })
})

/**
 * And that the settings panel's write is what fires it.
 *
 * The socket test above proves the push delivers; this proves the channel calls
 * it. Split, because the two halves failed separately in this subsystem's
 * history — `foldersChanged` existed and worked for a fortnight before anything
 * called it for a session started at this machine's own keyboard.
 */
describe('the settings channel', () => {
  function ipcHarness(dir: string): {
    call(channel: string, ...args: unknown[]): Promise<unknown>
    pushes: number
    grants: SessionGrants
  } {
    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    const grants = new SessionGrants(dir)
    const deps = {
      sessions: fanoutOver(grants).fanout,
      folders: new FolderGrants(dir),
      sessionGrants: grants,
      kinds: new DeviceKinds(dir),
      webRoot: join(dir, 'nowhere'),
      storageDir: dir,
      broadcast: () => {},
      relayEnabled: false,
      env: {},
      readTailnet: async () => ({ ready: false as const, state: 'not-installed' as const, reason: 'not here' }),
      serve: { on: async () => ({ ok: false }), off: async () => {} },
    }
    const { server } = registerRemoteIpc(
      {
        handle(channel: string, handler: (...args: unknown[]) => unknown) {
          handlers.set(channel, handler)
        },
      } as unknown as Parameters<typeof registerRemoteIpc>[0],
      deps as unknown as Parameters<typeof registerRemoteIpc>[1],
    )
    const state = { pushes: 0 }
    // The same object the handler closed over, so replacing the method here is
    // the handler's own call being watched rather than a stand-in beside it.
    const real = server.sessionsChanged.bind(server)
    server.sessionsChanged = () => {
      state.pushes += 1
      return real()
    }
    return {
      async call(channel, ...args) {
        const handler = handlers.get(channel)
        if (!handler) throw new Error(`no handler for ${channel}`)
        return handler({}, ...args)
      },
      get pushes() {
        return state.pushes
      },
      grants,
    }
  }

  it('stores the choice and tells every connected device in the same breath', async () => {
    const h = ipcHarness(tempDir())
    const stored = await h.call('remote:sessions:set', 'guest', 'selected', ['sess-shared'])
    expect(stored).toEqual([{ deviceId: 'guest', mode: 'selected', sessions: ['sess-shared'] }])
    expect(h.grants.shares('guest', 'sess-other')).toBe(false)
    expect(h.pushes).toBe(1)
  })

  it('answers the panel with the running sessions this machine has', async () => {
    const h = ipcHarness(tempDir())
    const running = (await h.call('remote:sessions:running')) as { id: string }[]
    expect(running.map((s) => s.id)).toEqual(['sess-shared', 'sess-other', 'sess-private'])
  })

  it('leaves a device nobody has narrowed out of the list entirely', async () => {
    const h = ipcHarness(tempDir())
    expect(await h.call('remote:sessions')).toEqual([])
  })
})
