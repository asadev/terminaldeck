import { randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  CAPABILITY,
  PROTOCOL_VERSION,
  parseClientMessage,
  parseDeviceRow,
  parseServerMessage,
  type ServerMessage,
} from './protocol'
import {
  WS_PATH,
  createRemoteEndpoint,
  type RemoteAuthenticator,
  type RemoteEndpoint,
  type SessionAccess,
} from './server'
import { REMOTE_AUTH_FILE, RemoteAuth, type Device } from './device-auth'
import { DeviceKinds } from './device-kind'
import { createDeviceRoster } from './device-roster'

/**
 * `devices.*` on the wire, end to end.
 *
 * Two halves. The first is the parser: the three frames each direction, narrowed
 * from the same JSON a browser could send, refused when a field is missing. The
 * second is the gate, over real loopback sockets, because the gate lives in the
 * message loop and a test that called a handler by hand would pass against a
 * server that never reads a frame at all — one `mine` device and one `guest`,
 * a change triggered, and the two invariants this feature turns on: a push that
 * reaches only the connection entitled to it, and a verb a guest is refused
 * without a side effect.
 */

/* --------------------------------------------------------------- parser -- */

const DEVICE_A = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'

describe('the devices frames narrow from JSON', () => {
  it('reads devices.list and devices.revoke, and refuses a missing field', () => {
    const list = parseClientMessage(JSON.stringify({ t: 'devices.list', rid: 'dev-1' }))
    expect(list).toEqual({ ok: true, message: { t: 'devices.list', rid: 'dev-1' } })

    const revoke = parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-2', device: DEVICE_A }))
    expect(revoke).toEqual({ ok: true, message: { t: 'devices.revoke', rid: 'dev-2', device: DEVICE_A } })

    expect(parseClientMessage(JSON.stringify({ t: 'devices.list' })).ok).toBe(false)
    expect(parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-3' })).ok).toBe(false)
    // A device id that is not an id is refused rather than passed to the store.
    const bad = parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-4', device: 'no spaces allowed' }))
    expect(bad.ok).toBe(false)
  })

  it('names a device id that leads with the two characters base64url starts with', () => {
    // The hole: `randomBytes(12).toString('base64url')` leads with `-` or `_`
    // 3.1% of the time, and the shared `ID_RE` refuses that leading character.
    // Those devices paired, were approved and signed in — and then this frame,
    // the only one that can take a device away, was refused before it reached the
    // gate. `newDeviceId` stopped minting them; the ones already on disk are what
    // this accepts.
    for (const device of ['-Nx7Qa2bLm9zRt4V', '_Nx7Qa2bLm9zRt4V', 'aNx7Qa2bLm9zRt4V', '9-_-9']) {
      const parsed = parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-5', device }))
      expect(parsed, device).toEqual({ ok: true, message: { t: 'devices.revoke', rid: 'dev-5', device } })
    }
    // Widened to base64url and no further: the alphabet and the 64-character
    // bound are both still checked, so nothing reaches the store that this app
    // could not have minted.
    for (const device of ['', 'a+b', 'a/b', 'a=', 'a.b', 'über', 'x'.repeat(65)]) {
      expect(parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-6', device })).ok, device).toBe(false)
    }
  })

  it('leaves every other id field on the shared rule, leading character included', () => {
    // The blast radius of the fix above, pinned. `ID_RE` guards session, request,
    // tunnel, channel, upload and cursor ids across dozens of fields; the device
    // id got its own rule precisely so relaxing one field could not relax those.
    // `__proto__` is the sharpest case — it is refused today for the sole reason
    // that it begins with `_`, and it must stay refused everywhere a value ends
    // up as a key.
    const refused = [
      { t: 'attach', id: '-session' },
      { t: 'attach', id: '__proto__' },
      { t: 'input', id: '_session', data: 'x' },
      { t: 'resize', id: '__proto__', cols: 80, rows: 24 },
      { t: 'devices.list', rid: '-dev-1' },
      { t: 'devices.revoke', rid: '__proto__', device: 'aNx7Qa2bLm9zRt4V' },
    ]
    for (const frame of refused) {
      expect(parseClientMessage(JSON.stringify(frame)).ok, JSON.stringify(frame)).toBe(false)
    }
    // And the same frames with an ordinary leading character still parse, so the
    // assertions above are about the leading class and not about the frames.
    expect(parseClientMessage(JSON.stringify({ t: 'attach', id: 'session' })).ok).toBe(true)
    expect(parseClientMessage(JSON.stringify({ t: 'devices.list', rid: 'dev-1' })).ok).toBe(true)
  })

  it('never echoes the refused device id into the reason', () => {
    const secret = 'AAAA-injection-marker'
    const result = parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'dev-5', device: `${secret} ` }))
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.reason.includes(secret)).toBe(false)
  })

  it('reads devices.rows, devices.revoked and devices.changed back', () => {
    const row = {
      id: DEVICE_A,
      name: 'iPhone',
      kind: 'mine',
      status: 'approved',
      addedAt: 1_760_000_000_000,
      lastSeenAt: 1_760_000_100_000,
      connected: true,
      fingerprint: 'aa bb cc dd ee ff',
    }
    const rows = parseServerMessage(JSON.stringify({ t: 'devices.rows', rid: 'dev-1', devices: [row] }))
    expect(rows).toEqual({ ok: true, message: { t: 'devices.rows', rid: 'dev-1', devices: [row] } })

    const revoked = parseServerMessage(
      JSON.stringify({ t: 'devices.revoked', rid: 'dev-2', ok: true, message: 'Gone.', devices: [] }),
    )
    expect(revoked).toEqual({
      ok: true,
      message: { t: 'devices.revoked', rid: 'dev-2', ok: true, message: 'Gone.', devices: [] },
    })

    const changed = parseServerMessage(JSON.stringify({ t: 'devices.changed', devices: [] }))
    expect(changed).toEqual({ ok: true, message: { t: 'devices.changed', devices: [] } })
  })

  it('refuses a rows frame with no list, and a changed frame with no list', () => {
    expect(parseServerMessage(JSON.stringify({ t: 'devices.rows', rid: 'dev-1' })).ok).toBe(false)
    expect(parseServerMessage(JSON.stringify({ t: 'devices.changed', devices: 'nope' })).ok).toBe(false)
  })

  it('drops a row with an unrecognised kind or status rather than guessing', () => {
    const base = {
      id: DEVICE_A,
      name: 'iPhone',
      addedAt: 1,
      lastSeenAt: null,
      connected: false,
      fingerprint: null,
    }
    expect(parseDeviceRow({ ...base, kind: 'admin', status: 'approved' })).toBeNull()
    expect(parseDeviceRow({ ...base, kind: 'mine', status: 'revoked' })).toBeNull()
    expect(parseDeviceRow({ ...base, kind: 'guest', status: 'pending' })).not.toBeNull()
  })
})

/* ----------------------------------------------------------- wire harness -- */

interface Frame {
  opcode: number
  payload: Buffer
}

function maskedFrame(opcode: number, payload: Buffer): Buffer {
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
  header[0] = 0x80 | opcode
  return Buffer.concat([header, mask, masked])
}

function readFrames(buffer: Buffer): { frames: Frame[]; rest: Buffer } {
  const frames: Frame[] = []
  let at = 0
  for (;;) {
    if (buffer.length - at < 2) break
    const opcode = buffer[at] & 0x0f
    let length = buffer[at + 1] & 0x7f
    let offset = at + 2
    if (length === 126) {
      if (buffer.length < offset + 2) break
      length = buffer.readUInt16BE(offset)
      offset += 2
    }
    if (buffer.length < offset + length) break
    frames.push({ opcode, payload: buffer.subarray(offset, offset + length) })
    at = offset + length
  }
  return { frames, rest: buffer.subarray(at) }
}

interface Client {
  send(message: unknown): void
  received: ServerMessage[]
  until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage>
  closed: Promise<number>
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
    req.on('response', (res) => fail(new Error(`upgrade refused with ${res.statusCode}`)))
    req.on('error', fail)
    req.on('upgrade', (_res, socket, head) => {
      const received: ServerMessage[] = []
      const waiters: { predicate: (m: ServerMessage) => boolean; settle: (m: ServerMessage) => void }[] = []
      let closeCode = -1
      let resolveClosed: (code: number) => void = () => {}
      const closed = new Promise<number>((done) => {
        resolveClosed = done
      })
      let buffer: Buffer = head
      const consume = (): void => {
        const { frames, rest } = readFrames(buffer)
        buffer = rest
        for (const frame of frames) {
          if (frame.opcode === 0x8) {
            closeCode = frame.payload.length >= 2 ? frame.payload.readUInt16BE(0) : 1005
            continue
          }
          if (frame.opcode !== 0x1) continue
          const message = JSON.parse(frame.payload.toString('utf8')) as ServerMessage
          received.push(message)
          for (const waiter of [...waiters]) {
            if (!waiter.predicate(message)) continue
            waiters.splice(waiters.indexOf(waiter), 1)
            waiter.settle(message)
          }
        }
      }
      consume()
      socket.on('data', (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        consume()
      })
      socket.on('close', () => resolveClosed(closeCode))
      socket.on('error', () => resolveClosed(closeCode))
      settle({
        received,
        send: (message) => (socket as Socket).write(maskedFrame(0x1, Buffer.from(JSON.stringify(message), 'utf8'))),
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
        closed,
      })
    })
    req.end()
  })
}

const noSessions: SessionAccess = {
  list: () => [],
  attach: () => null,
  write: () => {},
  resize: () => {},
  detach: () => {},
}

const dirs: string[] = []
let servers: Server[] = []

afterEach(async () => {
  for (const server of servers) server.close()
  servers = []
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}

async function paired(auth: RemoteAuth, name: string): Promise<{ device: Device; credential: string }> {
  const { token } = auth.createPairingToken()
  const result = await auth.redeemPairingToken(token, name)
  if (!result.ok) throw new Error(`pairing failed: ${result.reason}`)
  expect(auth.approveDevice(result.device.id)).toBe(true)
  return { device: result.device, credential: result.credential }
}

interface RosterHarness {
  port: number
  endpoint: RemoteEndpoint
  auth: RemoteAuth
  kinds: DeviceKinds
  forget: ReturnType<typeof vi.fn>
  mine: { device: Device; credential: string }
  guest: { device: Device; credential: string }
  /** Only with `{ stuck: true }`. See {@link serveRoster}. */
  stuck: { device: Device; credential: string } | null
}

/**
 * Rewrite one paired device's id on disk to the shape 3% of real ones have.
 *
 * A device minted before `newDeviceId` resampled leads with `-` or `_`, and the
 * only way to have one in a test is to make one: the record is written by a real
 * pairing and then its `id` is edited in `remote-auth.json`, which is exactly the
 * row a 0.9.x pairing left behind. The credential survives the edit because it is
 * `<id>.<secret>` and only the secret half is hashed — so the returned credential
 * still signs this device in, under the rewritten id.
 */
function stick(dir: string, seeded: { device: Device; credential: string }): { device: Device; credential: string } {
  const id = `-${seeded.device.id.slice(1)}`
  const file = join(dir, REMOTE_AUTH_FILE)
  const state = JSON.parse(readFileSync(file, 'utf8')) as { devices: { id: string }[] }
  const row = state.devices.find((device) => device.id === seeded.device.id)
  if (!row) throw new Error('the seeded device is not in the trust file')
  row.id = id
  writeFileSync(file, JSON.stringify(state))
  return {
    device: { ...seeded.device, id },
    credential: `${id}.${seeded.credential.slice(seeded.credential.indexOf('.') + 1)}`,
  }
}

/**
 * An endpoint serving `devices`, with one device claimed `mine` and one left a
 * guest. The authenticator maps each device's real credential to its id, so the
 * roster the endpoint lists and the device a hello admits are the same device.
 *
 * With `{ stuck: true }` a third device is paired and its stored id is rewritten
 * to lead with `-` — the class of id that could be paired, approved and signed in
 * and then never revoked. The trust store is re-read from disk afterwards, so the
 * roster below serves the rewritten row rather than the one this process minted.
 */
async function serveRoster(options: { stuck?: boolean } = {}): Promise<RosterHarness> {
  const authDir = tempDir('td-wire-auth-')
  const minted = new RemoteAuth(authDir)
  const mine = await paired(minted, 'My phone')
  const guest = await paired(minted, 'Guest phone')
  const seeded = options.stuck === true ? await paired(minted, 'Old phone') : null
  const stuck = seeded === null ? null : stick(authDir, seeded)
  const auth = new RemoteAuth(authDir)
  const kinds = new DeviceKinds(tempDir('td-wire-kinds-'))
  kinds.claim(mine.device.id, 'mine')
  kinds.claim(guest.device.id, 'guest')
  if (stuck !== null) kinds.claim(stuck.device.id, 'guest')

  const forget = vi.fn()
  let endpoint: RemoteEndpoint | null = null
  const roster = createDeviceRoster({
    auth,
    kinds,
    drop: (id) => endpoint?.dropDevice(id) ?? 0,
    forget,
    connectedIds: () => new Set((endpoint?.connections() ?? []).map((connection) => connection.deviceId)),
    // The push is the effect the wire tests watch; the window broadcast the real
    // `announceRemoteChange` also does is not on this socket.
    announce: () => {
      endpoint?.rosterChanged()
    },
  })

  const authenticator: RemoteAuthenticator = {
    async authenticate(token) {
      if (token === mine.credential) {
        return { ok: true, deviceId: mine.device.id, deviceName: mine.device.name, credential: null }
      }
      if (token === guest.credential) {
        return { ok: true, deviceId: guest.device.id, deviceName: guest.device.name, credential: null }
      }
      if (stuck !== null && token === stuck.credential) {
        return { ok: true, deviceId: stuck.device.id, deviceName: stuck.device.name, credential: null }
      }
      return { ok: false, message: 'This device is not allowed in.' }
    },
  }

  const root = tempDir('td-wire-pwa-')
  writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')
  endpoint = createRemoteEndpoint({
    sessions: noSessions,
    auth: authenticator,
    webRoot: root,
    roster,
    ownDevice: (id) => kinds.kindOf(id) === 'mine',
    pingIntervalMs: 0,
  })

  const server = createServer(endpoint.handleRequest)
  server.on('upgrade', endpoint.handleUpgrade)
  servers.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
  return {
    port: (server.address() as AddressInfo).port,
    endpoint,
    auth,
    kinds,
    forget,
    mine,
    guest,
    stuck,
  }
}

function hello(token: string, capabilities: string[]): Record<string, unknown> {
  return { t: 'hello', protocol: PROTOCOL_VERSION, token, device: { name: 'x', platform: 'iOS' }, capabilities }
}

async function greet(port: number, token: string, capabilities: string[]): Promise<Client> {
  const client = await connect(port)
  client.send(hello(token, capabilities))
  await client.until((m) => m.t === 'welcome', 'the welcome')
  return client
}

/* -------------------------------------------------------------- the gate -- */

describe('devices over the wire', () => {
  it('advertises the capability to a mine device and withholds it from a guest', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    const guest = await greet(h.port, h.guest.credential, [CAPABILITY.devices])

    const mineWelcome = mine.received.find((m) => m.t === 'welcome')
    const guestWelcome = guest.received.find((m) => m.t === 'welcome')
    expect(mineWelcome?.t === 'welcome' && mineWelcome.capabilities.includes(CAPABILITY.devices)).toBe(true)
    expect(guestWelcome?.t === 'welcome' && guestWelcome.capabilities.includes(CAPABILITY.devices)).toBe(false)
  })

  it('answers a mine device its full roster', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    mine.send({ t: 'devices.list', rid: 'r1' })
    const rows = await mine.until((m) => m.t === 'devices.rows', 'the roster')
    if (rows.t !== 'devices.rows') throw new Error('wrong frame')
    expect(rows.rid).toBe('r1')
    expect(new Set(rows.devices.map((d) => d.id))).toEqual(new Set([h.mine.device.id, h.guest.device.id]))
    // The mine row's kind and connected flag are the live answers.
    expect(rows.devices.find((d) => d.id === h.mine.device.id)).toMatchObject({ kind: 'mine', connected: true })
  })

  it('refuses a guest devices.list, with no roster leaked', async () => {
    const h = await serveRoster()
    const guest = await greet(h.port, h.guest.credential, [CAPABILITY.devices])
    guest.send({ t: 'devices.list', rid: 'g1' })
    // Specific to the refusal: an `error` frame carries no `rid`, so the only
    // way to be sure this is the gate's answer and not some earlier or transient
    // error on the socket is its `code`. Waiting on the bare `t === 'error'`
    // grabbed whatever error arrived first.
    const error = await guest.until((m) => m.t === 'error' && m.code === 'unauthorized', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
    // No roster came back on the guest socket.
    expect(guest.received.some((m) => m.t === 'devices.rows')).toBe(false)
  })

  it('refuses a guest devices.revoke and takes nothing away', async () => {
    const h = await serveRoster()
    const guest = await greet(h.port, h.guest.credential, [CAPABILITY.devices])
    guest.send({ t: 'devices.revoke', rid: 'g2', device: h.mine.device.id })
    // By `code`, not the bare `t === 'error'`: error frames carry no `rid`, so a
    // wait on any error would settle on an earlier or transient one. This once
    // masked a real bug — a device id leading with `-`/`_` was refused as
    // "without a device id" before the gate ran, and `newDeviceId` now prevents
    // that class of id — but the specific wait is correct on its own terms.
    const error = await guest.until((m) => m.t === 'error' && m.code === 'unauthorized', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
    // The cascade never ran: nothing was forgotten and the target is still here.
    expect(h.forget).not.toHaveBeenCalled()
    expect(h.auth.listDevices().find((d) => d.id === h.mine.device.id)?.revoked).toBe(false)
    expect(guest.received.some((m) => m.t === 'devices.revoked')).toBe(false)
  })

  it('pushes devices.changed only to a mine device that named the capability', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    const guest = await greet(h.port, h.guest.credential, [CAPABILITY.devices])
    // A second mine connection that did NOT name devices in its hello.
    const silentMine = await greet(h.port, h.mine.credential, [])

    const told = h.endpoint.rosterChanged()
    // Exactly one connection is entitled: mine, with the capability named.
    expect(told).toBe(1)
    await mine.until((m) => m.t === 'devices.changed', 'the push')
    // The guest (wrong kind) and the capability-less mine (right kind, no hello)
    // both hear nothing.
    expect(guest.received.some((m) => m.t === 'devices.changed')).toBe(false)
    expect(silentMine.received.some((m) => m.t === 'devices.changed')).toBe(false)
  })

  it('recomputes the gate at send time: a device demoted before the push hears nothing', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    // Demote it between the trigger's cause and the push itself. `claim` refuses
    // to change a decided kind — that is the file's own rule — so the real way a
    // kind stops being `mine` is `forget`, which is exactly what a revoke runs;
    // after it, `kindOf` folds the device back into `guest`.
    h.kinds.forget(h.mine.device.id)
    expect(h.endpoint.rosterChanged()).toBe(0)
    expect(mine.received.some((m) => m.t === 'devices.changed')).toBe(false)
  })

  it('removes the row and drops the target socket when a mine device revokes a guest', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    const guest = await greet(h.port, h.guest.credential, [CAPABILITY.devices])

    mine.send({ t: 'devices.revoke', rid: 'r9', device: h.guest.device.id })
    const answer = await mine.until((m) => m.t === 'devices.revoked', 'the answer')
    if (answer.t !== 'devices.revoked') throw new Error('wrong frame')
    expect(answer.ok).toBe(true)
    // The revoked device is gone from the list the answer carries.
    expect(answer.devices.some((d) => d.id === h.guest.device.id)).toBe(false)
    // The cascade ran and the guest's own socket was dropped.
    expect(h.forget).toHaveBeenCalledWith(h.guest.device.id)
    await expect(guest.closed).resolves.toBeGreaterThan(0)
  })

  it('revokes a device already on disk with an id that leads with `-`', async () => {
    const h = await serveRoster({ stuck: true })
    const stuck = h.stuck
    if (stuck === null) throw new Error('the harness seeded no stuck device')
    // It is a real device, not a row: it signs in and holds a socket on this
    // desktop. That is what made this a security hole rather than a cosmetic
    // one — the person whose phone this is cannot be cut off.
    const old = await greet(h.port, stuck.credential, [])
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    mine.send({ t: 'devices.list', rid: 'stuck-1' })
    const rows = await mine.until((m) => m.t === 'devices.rows', 'the roster')
    if (rows.t !== 'devices.rows') throw new Error('wrong frame')
    // Listed with a Remove beside it — the roster never checked the id's shape,
    // which is why the button looked like it worked.
    expect(rows.devices.find((d) => d.id === stuck.device.id)).toMatchObject({ connected: true })

    mine.send({ t: 'devices.revoke', rid: 'stuck-2', device: stuck.device.id })
    // Before the fix this never arrived: the frame was refused at the parser and
    // the *asking* socket was closed with a protocol error, so Remove knocked
    // this phone off and left the other one signed in.
    const answer = await mine.until((m) => m.t === 'devices.revoked', 'the answer')
    if (answer.t !== 'devices.revoked') throw new Error('wrong frame')
    expect(answer.ok).toBe(true)
    expect(answer.devices.some((d) => d.id === stuck.device.id)).toBe(false)
    // The whole cascade ran: stores forgotten, live socket dropped, record out.
    expect(h.forget).toHaveBeenCalledWith(stuck.device.id)
    await expect(old.closed).resolves.toBeGreaterThan(0)
    expect(h.auth.listDevices().find((d) => d.id === stuck.device.id)?.revoked).toBe(true)
    // And the credential that phone is holding opens nothing from now on. It is
    // told `revoked` rather than `denied`, which is the store confirming it
    // matched the secret — proof the record was reached by its rewritten id and
    // not merely absent.
    await expect(h.auth.verifyCredential(stuck.credential, '203.0.113.9')).resolves.toMatchObject({
      ok: false,
      reason: 'revoked',
    })
  })

  it('offers Remove on nothing it cannot remove: every listed row is nameable', async () => {
    // The invariant behind the fix, stated once against the real roster: if a
    // device is on this list it has a working Remove, whatever its id looks like.
    // A roster row that could not be named in the frame is a button that lies.
    const h = await serveRoster({ stuck: true })
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])
    mine.send({ t: 'devices.list', rid: 'every-1' })
    const rows = await mine.until((m) => m.t === 'devices.rows', 'the roster')
    if (rows.t !== 'devices.rows') throw new Error('wrong frame')
    expect(rows.devices.length).toBe(3)
    for (const row of rows.devices) {
      const frame = parseClientMessage(JSON.stringify({ t: 'devices.revoke', rid: 'every-2', device: row.id }))
      expect(frame.ok, row.id).toBe(true)
    }
  })

  it('treats self-revoke as sign-out: the asker loses its own socket', async () => {
    const h = await serveRoster()
    const mine = await greet(h.port, h.mine.credential, [CAPABILITY.devices])

    mine.send({ t: 'devices.revoke', rid: 'self', device: h.mine.device.id })
    // No devices.revoked comes back — the socket the answer would ride is the one
    // the cascade just closed, and the close is the confirmation.
    await expect(mine.closed).resolves.toBeGreaterThan(0)
    expect(mine.received.some((m) => m.t === 'devices.revoked')).toBe(false)
    expect(h.auth.listDevices().find((d) => d.id === h.mine.device.id)?.revoked).toBe(true)
  })
})
