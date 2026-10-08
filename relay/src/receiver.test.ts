/**
 * Tests for the Receiver's door on the relay.
 *
 * Security first: what gets refused, what gets limited, and that what the relay
 * keeps is unreadable to it and never printed. Then the host side: sync,
 * offline queue, delivery, acknowledgement and redelivery, over a real socket.
 */

import { AddressInfo, connect, type Socket } from 'node:net'
import {
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  type KeyObject,
} from 'node:crypto'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { request as httpRequest } from 'node:http'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createRelayServer, type RelayServer } from './rendezvous'
import {
  RECEIVER_ACK,
  RECEIVER_BODIES,
  RECEIVER_ENVELOPE,
  RECEIVER_MAX_BODY_BYTES,
  RECEIVER_MAX_QUEUED_PER_SOURCE,
  RECEIVER_RATE_PER_SOURCE,
  RECEIVER_RETENTION_MS,
  RECEIVER_SEAL_INFO,
  ReceiverHub,
  clientIpOf,
  encodeFrame,
  hostTagFor,
  parseReceiverPath,
  readHead,
  sealAAD,
  sealTo,
} from './receiver'
import { FrameReader, OPCODE } from '../../src/shared/ws-frame'

/* -------------------------------------------------------------------------- */
/* Keys and sealing, from the Mac's side                                       */
/* -------------------------------------------------------------------------- */

const PKCS8_X25519 = Buffer.from('302e020100300506032b656e04220420', 'hex')
const SPKI_X25519 = Buffer.from('302a300506032b656e032100', 'hex')

interface MacKey {
  privateKey: KeyObject
  publicRaw: Buffer
}

function macKey(): MacKey {
  const pair = generateKeyPairSync('x25519')
  return { privateKey: pair.privateKey, publicRaw: pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(12) }
}

function openSealed(key: MacKey, sealed: Buffer, aad: Buffer): Buffer {
  const ephemeral = sealed.subarray(0, 32)
  const nonce = sealed.subarray(32, 44)
  const tag = sealed.subarray(sealed.length - 16)
  const body = sealed.subarray(44, sealed.length - 16)
  const peer = createPublicKey({ key: Buffer.concat([SPKI_X25519, ephemeral]), format: 'der', type: 'spki' })
  const shared = diffieHellman({ privateKey: key.privateKey, publicKey: peer })
  const symmetric = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeral, key.publicRaw]), RECEIVER_SEAL_INFO, 32))
  const decipher = createDecipheriv('aes-256-gcm', symmetric, nonce)
  decipher.setAAD(aad)
  decipher.setAuthTag(tag)
  return Buffer.concat([decipher.update(body), decipher.final()])
}

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
function sourceId(): string {
  const bytes = randomBytes(26)
  return Array.from(bytes, (b) => ALPHABET[b % 32]).join('')
}
function token(): string {
  return randomBytes(32).toString('base64url')
}
function hashOf(value: string): string {
  return createHash('sha256').update(value).digest('hex')
}

/* -------------------------------------------------------------------------- */
/* A minimal WebSocket host (the same approach as rendezvous.test.ts)          */
/* -------------------------------------------------------------------------- */

function maskedFrame(opcode: number, payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  let header: Buffer
  if (masked.length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | masked.length
  } else if (masked.length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(masked.length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(masked.length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, mask, masked])
}

class Host {
  private readonly reader = new FrameReader(1024 * 1024, 'client')
  private readonly inbox: Buffer[] = []
  private waiting: ((frame: Buffer) => void) | null = null
  private constructor(private readonly socket: Socket) {}

  static async open(port: number, secret: Buffer): Promise<Host> {
    const socket = connect(port, '127.0.0.1')
    const host = new Host(socket)
    await new Promise<void>((resolve, reject) => {
      socket.once('error', reject)
      socket.once('connect', () => resolve())
    })
    socket.write(
      [
        'GET /v1/host HTTP/1.1',
        'Host: 127.0.0.1',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        'Sec-WebSocket-Version: 13',
        `x-deck-host-secret: ${secret.toString('base64url')}`,
        '',
        '',
      ].join('\r\n'),
    )
    await new Promise<void>((resolve) => {
      let buffer = Buffer.alloc(0)
      const onData = (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        const end = buffer.indexOf('\r\n\r\n')
        if (end === -1) return
        socket.off('data', onData)
        const rest = buffer.subarray(end + 4)
        if (rest.length) host.feed(rest)
        socket.on('data', (next: Buffer) => host.feed(next))
        resolve()
      }
      socket.on('data', onData)
    })
    hosts.push(host)
    return host
  }

  private feed(chunk: Buffer): void {
    for (const frame of this.reader.push(chunk).frames) {
      if (frame.opcode === OPCODE.ping) {
        this.socket.write(maskedFrame(OPCODE.pong, frame.payload))
        continue
      }
      if (frame.opcode !== OPCODE.binary) continue
      const waiter = this.waiting
      if (waiter) {
        this.waiting = null
        waiter(frame.payload)
      } else this.inbox.push(frame.payload)
    }
  }

  send(frame: Buffer): void {
    this.socket.write(maskedFrame(OPCODE.binary, frame))
  }

  next(timeoutMs = 2000): Promise<Buffer> {
    const buffered = this.inbox.shift()
    if (buffered) return Promise.resolve(buffered)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timed out waiting for a frame')), timeoutMs)
      this.waiting = (frame) => {
        clearTimeout(timer)
        resolve(frame)
      }
    })
  }

  async quiet(ms = 150): Promise<boolean> {
    try {
      await this.next(ms)
      return false
    } catch {
      return true
    }
  }

  sync(key: MacKey, sources: unknown[]): void {
    const payload = Buffer.from(JSON.stringify({ v: 1, sealKey: key.publicRaw.toString('base64url'), sources }))
    this.send(encodeFrame(RECEIVER_ENVELOPE.sync, Buffer.alloc(16), payload))
  }

  ack(id: Buffer, status: number = RECEIVER_ACK.kept): void {
    this.send(encodeFrame(RECEIVER_ENVELOPE.ack, id, Buffer.from([status])))
  }

  end(): void {
    this.socket.destroy()
  }
}

/* -------------------------------------------------------------------------- */
/* Harness                                                                     */
/* -------------------------------------------------------------------------- */

let running: RelayServer | null = null
const hosts: Host[] = []
const dirs: string[] = []

async function startRelay(options: Parameters<typeof createRelayServer>[0] = {}): Promise<number> {
  running = createRelayServer({ heartbeatMs: 60_000, ...options })
  await new Promise<void>((resolve) => running!.server.listen(0, '127.0.0.1', resolve))
  return (running.server.address() as AddressInfo).port
}

function post(
  port: number,
  path: string,
  body: Buffer | string,
  headers: Record<string, string> = {},
  method = 'POST',
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const data = typeof body === 'string' ? Buffer.from(body) : body
    const req = httpRequest(
      { host: '127.0.0.1', port, path, method, headers: { 'content-type': 'application/json', 'content-length': String(data.length), ...headers } },
      (res) => {
        const chunks: Buffer[] = []
        res.on('data', (c: Buffer) => chunks.push(c))
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }))
      },
    )
    req.on('error', reject)
    req.end(data)
  })
}

async function waitFor(check: () => boolean, ms = 2000): Promise<void> {
  const deadline = Date.now() + ms
  while (!check()) {
    if (Date.now() > deadline) throw new Error('condition not met in time')
    await new Promise((r) => setTimeout(r, 10))
  }
}

afterEach(async () => {
  for (const host of hosts.splice(0)) host.end()
  await running?.close()
  running = null
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

/** One synced host with one token source and one GitHub source. */
async function hostWithSources(port: number) {
  const key = macKey()
  const secret = randomBytes(32)
  const whapi = { id: sourceId(), token: token() }
  const github = { id: sourceId() }
  const json = { id: sourceId() }
  const host = await Host.open(port, secret)
  host.sync(key, [
    { id: whapi.id, auth: 'token', secretHash: hashOf(whapi.token), enabled: true },
    { id: github.id, auth: 'hmac', signatureHeader: 'x-hub-signature-256', enabled: true },
    { id: json.id, auth: 'hmac', signatureHeader: 'x-receiver-signature', enabled: true },
  ])
  const synced = await host.next()
  expect(synced[0]).toBe(RECEIVER_ENVELOPE.synced)
  return { key, secret, host, whapi, github, json, synced: JSON.parse(synced.subarray(17).toString()) }
}

/* -------------------------------------------------------------------------- */
/* Security                                                                    */
/* -------------------------------------------------------------------------- */

describe('the door refuses what it should', () => {
  it('answers 404 for an unknown source, a malformed path and a malformed token, with one constant body', async () => {
    const port = await startRelay()
    for (const path of [`/in/${sourceId()}`, '/in/short', '/in/../etc', `/in/${sourceId()}/bad%20token`, `/in/${sourceId()}/a/b`]) {
      const answer = await post(port, path, '{}')
      expect(answer.status).toBe(404)
      expect(answer.body).toBe(RECEIVER_BODIES.notActive)
    }
  })

  it('takes only POST', async () => {
    const port = await startRelay()
    const { whapi } = await hostWithSources(port)
    const answer = await post(port, `/in/${whapi.id}/${whapi.token}`, '', {}, 'GET')
    expect(answer.status).toBe(405)
  })

  it('checks a token source by hash: right token in path, bearer or header passes; wrong or missing fails', async () => {
    const port = await startRelay()
    const { whapi } = await hostWithSources(port)
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{"a":1}')).status).toBe(202)
    expect((await post(port, `/in/${whapi.id}`, '{"a":1}', { authorization: `Bearer ${whapi.token}` })).status).toBe(202)
    expect((await post(port, `/in/${whapi.id}`, '{"a":1}', { 'x-receiver-secret': whapi.token })).status).toBe(202)
    const wrong = await post(port, `/in/${whapi.id}/${token()}`, '{"a":1}')
    expect(wrong.status).toBe(401)
    expect(wrong.body).toBe(RECEIVER_BODIES.unauthorized)
    expect((await post(port, `/in/${whapi.id}`, '{"a":1}')).status).toBe(401)
  })

  it('needs the configured signature header on an HMAC source; the Mac judges the signature itself', async () => {
    const port = await startRelay()
    const { github } = await hostWithSources(port)
    const body = '{"zen":"hi"}'
    const good = { 'x-hub-signature-256': 'sha256=' + createHmac('sha256', 'anything').update(body).digest('hex') }
    expect((await post(port, `/in/${github.id}`, body, good)).status).toBe(202)
    expect((await post(port, `/in/${github.id}`, body, { 'x-hub-signature-256': 'short' })).status).toBe(401)
    expect((await post(port, `/in/${github.id}`, body, { 'x-other-signature': good['x-hub-signature-256'] })).status).toBe(401)
    expect((await post(port, `/in/${github.id}`, body)).status).toBe(401)
  })

  it('checks basic auth by hash, and lets an address-only source through with no proof', async () => {
    const port = await startRelay()
    const host = await Host.open(port, randomBytes(32))
    const basic = sourceId()
    const open = sourceId()
    host.sync(macKey(), [
      { id: basic, auth: 'basic', secretHash: hashOf('monitor:' + 'p'.repeat(24)) },
      { id: open, auth: 'none' },
    ])
    expect(JSON.parse((await host.next()).subarray(17).toString()).accepted).toEqual([basic, open])
    const good = 'Basic ' + Buffer.from('monitor:' + 'p'.repeat(24)).toString('base64')
    const bad = 'Basic ' + Buffer.from('monitor:wrong').toString('base64')
    expect((await post(port, `/in/${basic}`, '{}', { authorization: good })).status).toBe(202)
    expect((await post(port, `/in/${basic}`, '{}', { authorization: bad })).status).toBe(401)
    expect((await post(port, `/in/${basic}`, '{}')).status).toBe(401)
    expect((await post(port, `/in/${open}`, 'plain text from a cron job', { 'content-type': 'text/plain' })).status).toBe(202)
    expect((await post(port, `/in/${open}`, '{}', {}, 'PUT')).status).toBe(202)
  })

  it('applies an IP allow-list before anything else, trusting the proxy only from a private peer', async () => {
    const port = await startRelay()
    const host = await Host.open(port, randomBytes(32))
    const id = sourceId()
    host.sync(macKey(), [{ id, auth: 'none', ipAllow: ['203.0.113.0/24', '2001:db8::1'] }])
    await host.next()
    // The test client is on loopback, so it stands where the proxy stands.
    expect((await post(port, `/in/${id}`, '{}', { 'x-forwarded-for': '198.51.100.9, 203.0.113.40' })).status).toBe(202)
    expect((await post(port, `/in/${id}`, '{}', { 'x-forwarded-for': '203.0.113.40, 198.51.100.9' })).status).toBe(401)
    expect((await post(port, `/in/${id}`, '{}')).status).toBe(401)
    expect(clientIpOf('::ffff:10.0.1.5', '2001:db8::1')).toBe('2001:db8::1')
    expect(clientIpOf('198.51.100.9', '203.0.113.40')).toBe('198.51.100.9')
    expect(clientIpOf('10.0.0.2', 'not-an-ip')).toBeNull()
  })

  it('refuses declarations that are not exactly right', async () => {
    const port = await startRelay()
    const host = await Host.open(port, randomBytes(32))
    const ids = [sourceId(), sourceId(), sourceId(), sourceId(), sourceId()]
    host.sync(macKey(), [
      { id: ids[0], auth: 'hmac' },
      { id: ids[1], auth: 'token' },
      { id: ids[2], auth: 'none', ipAllow: ['300.1.1.1'] },
      { id: ids[3], auth: 'hmac', signatureHeader: 'cookie' },
      { id: ids[4], auth: 'magic' },
    ])
    const synced = JSON.parse((await host.next()).subarray(17).toString())
    expect(synced.accepted).toEqual([])
    expect(synced.refused.length).toBe(5)
  })

  it('needs a signature header on a signed JSON source', async () => {
    const port = await startRelay()
    const { json } = await hostWithSources(port)
    expect((await post(port, `/in/${json.id}`, '{}')).status).toBe(401)
    const signature = 'sha256=' + createHmac('sha256', 'k').update('{}').digest('hex')
    expect((await post(port, `/in/${json.id}`, '{}', { 'x-receiver-signature': signature })).status).toBe(202)
  })

  it('refuses an oversize body by its declared length and by what actually arrives', async () => {
    const port = await startRelay()
    const { whapi } = await hostWithSources(port)
    const big = Buffer.alloc(RECEIVER_MAX_BODY_BYTES + 1, 0x61)
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, big)).status).toBe(413)
    // Chunked: no declared length, so only the running count can catch it.
    const status = await new Promise<number>((resolve, reject) => {
      const req = httpRequest(
        { host: '127.0.0.1', port, path: `/in/${whapi.id}/${whapi.token}`, method: 'POST', headers: { 'transfer-encoding': 'chunked' } },
        (res) => {
          res.resume()
          resolve(res.statusCode ?? 0)
        },
      )
      req.on('error', () => resolve(413))
      for (let i = 0; i < 12; i += 1) req.write(Buffer.alloc(8 * 1024, 0x62))
      req.end()
      setTimeout(() => reject(new Error('no answer')), 3000)
    })
    expect(status).toBe(413)
  })

  it('limits each source per minute with a sliding window', async () => {
    let now = 1_800_000_000_000
    const port = await startRelay({ now: () => now })
    const { whapi } = await hostWithSources(port)
    for (let i = 0; i < RECEIVER_RATE_PER_SOURCE; i += 1) {
      expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')).status).not.toBe(429)
    }
    const limited = await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')
    expect(limited.status).toBe(429)
    now += 60_001
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')).status).toBe(202)
  })

  it('stops at the per-source queue bound with 503, never dropping what it already accepted', async () => {
    let now = 1_800_000_000_000
    const port = await startRelay({ now: () => now })
    const { whapi, host } = await hostWithSources(port)
    host.end()
    await waitFor(() => running!.rendezvous.stats().hosts === 0)
    for (let i = 0; i < RECEIVER_MAX_QUEUED_PER_SOURCE; i += 1) {
      if (i % RECEIVER_RATE_PER_SOURCE === 0) now += 60_001
      expect((await post(port, `/in/${whapi.id}/${whapi.token}`, `{"n":${i}}`)).status).toBe(202)
    }
    now += 60_001
    const full = await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')
    expect(full.status).toBe(503)
    expect(running!.rendezvous.receiver.stats().queued).toBe(RECEIVER_MAX_QUEUED_PER_SOURCE)
  })

  it('keeps only sealed bytes: no body, token or header text is readable in the queue, yet the Mac opens it', async () => {
    const port = await startRelay()
    const { whapi, host, key } = await hostWithSources(port)
    host.end()
    await waitFor(() => running!.rendezvous.stats().hosts === 0)
    const marker = 'very-private-message-' + randomBytes(8).toString('hex')
    await post(port, `/in/${whapi.id}/${whapi.token}`, JSON.stringify({ text: marker }), { cookie: 'session=abc' })

    // Reach in the way a memory dump would.
    const queue = (running!.rendezvous.receiver as unknown as { queue: Map<string, { sealed: Buffer; id: Buffer; receivedAt: number }> }).queue
    const [entry] = [...queue.values()]
    const raw = entry.sealed.toString('latin1')
    expect(raw).not.toContain(marker)
    expect(raw).not.toContain(whapi.token)

    const plain = readHead(openSealed(key, entry.sealed, sealAAD(whapi.id, entry.id, entry.receivedAt)))!
    expect(plain.head.pathToken).toBe(whapi.token)
    expect(JSON.parse(plain.rest.toString()).text).toBe(marker)
    expect((plain.head.headers as Record<string, string>).cookie).toBeUndefined()

    // The additional data binds the blob to its delivery: another id cannot open it.
    expect(() => openSealed(key, entry.sealed, sealAAD(whapi.id, randomBytes(16), entry.receivedAt))).toThrow()
    // Nor can any other key.
    expect(() => openSealed(macKey(), entry.sealed, sealAAD(whapi.id, entry.id, entry.receivedAt))).toThrow()
  })

  it('never prints anything while handling deliveries, good or bad', async () => {
    const log = vi.spyOn(console, 'log')
    const error = vi.spyOn(console, 'error')
    const warn = vi.spyOn(console, 'warn')
    const port = await startRelay()
    const { whapi, github } = await hostWithSources(port)
    await post(port, `/in/${whapi.id}/${whapi.token}`, '{"text":"hello"}')
    await post(port, `/in/${whapi.id}/${token()}`, '{"text":"hello"}')
    await post(port, `/in/${github.id}`, 'not json', { 'x-hub-signature-256': 'nope' })
    expect(log).not.toHaveBeenCalled()
    expect(error).not.toHaveBeenCalled()
    expect(warn).not.toHaveBeenCalled()
  })

  it('refuses a source id another computer already owns', async () => {
    const port = await startRelay()
    const { whapi } = await hostWithSources(port)
    const thief = await Host.open(port, randomBytes(32))
    thief.sync(macKey(), [{ id: whapi.id, auth: 'token', secretHash: hashOf(token()), enabled: true }])
    const synced = JSON.parse((await thief.next()).subarray(17).toString())
    expect(synced.accepted).toEqual([])
    expect(synced.refused).toEqual([{ id: whapi.id, reason: 'taken' }])
    // The real owner's token still works; the thief's key never sees a delivery.
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')).status).toBe(202)
    expect(await thief.quiet()).toBe(true)
  })

  it('seals every header except the connection, proxy and cookie ones', async () => {
    const port = await startRelay()
    const { whapi, host, key } = await hostWithSources(port)
    await post(port, `/in/${whapi.id}/${whapi.token}`, '{}', {
      cookie: 'session=abc',
      'x-forwarded-proto': 'https',
      'sentry-hook-resource': 'issue',
      'x-custom-event': 'deploy.finished',
    })
    const frame = await host.next()
    const parsed = readHead(frame.subarray(17))!
    const plain = readHead(openSealed(key, parsed.rest, sealAAD(whapi.id, frame.subarray(1, 17), parsed.head.receivedAt as number)))!
    const headers = plain.head.headers as Record<string, string>
    expect(headers.cookie).toBeUndefined()
    expect(headers['x-forwarded-proto']).toBeUndefined()
    expect(headers.host).toBeUndefined()
    expect(headers['sentry-hook-resource']).toBe('issue')
    expect(headers['x-custom-event']).toBe('deploy.finished')
    expect(plain.head.pathToken).toBe(whapi.token)
    expect(plain.head.method).toBe('POST')
    expect(plain.head.clientIp).toBe('127.0.0.1')
  })

  it('ignores a pause: a disabled source answers like an unknown one', async () => {
    const port = await startRelay()
    const host = await Host.open(port, randomBytes(32))
    const id = sourceId()
    const secret = token()
    host.sync(macKey(), [{ id, auth: 'token', secretHash: hashOf(secret), enabled: false }])
    await host.next()
    const answer = await post(port, `/in/${id}/${secret}`, '{}')
    expect(answer.status).toBe(404)
    expect(answer.body).toBe(RECEIVER_BODIES.notActive)
  })
})

/* -------------------------------------------------------------------------- */
/* Delivery to the Mac                                                         */
/* -------------------------------------------------------------------------- */

describe('delivery over the host socket', () => {
  it('hands a live host its delivery at once, and forgets it on acknowledgement', async () => {
    const port = await startRelay()
    const { whapi, host, key } = await hostWithSources(port)
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{"text":"now"}')).status).toBe(202)
    const frame = await host.next()
    expect(frame[0]).toBe(RECEIVER_ENVELOPE.deliver)
    const id = frame.subarray(1, 17)
    const parsed = readHead(frame.subarray(17))!
    expect(parsed.head.sourceId).toBe(whapi.id)
    const plain = readHead(openSealed(key, parsed.rest, sealAAD(whapi.id, id, parsed.head.receivedAt as number)))!
    expect(JSON.parse(plain.rest.toString()).text).toBe('now')
    host.ack(id)
    await waitFor(() => running!.rendezvous.receiver.stats().queued === 0)
  })

  it('keeps deliveries while the Mac is away and sends them after it syncs again', async () => {
    const port = await startRelay()
    const { whapi, host, key, secret } = await hostWithSources(port)
    host.end()
    await waitFor(() => running!.rendezvous.stats().hosts === 0)
    for (const n of [1, 2, 3]) await post(port, `/in/${whapi.id}/${whapi.token}`, `{"n":${n}}`)

    const back = await Host.open(port, secret)
    // Before sync: nothing. An old Mac never syncs and so is never sent these frames.
    expect(await back.quiet()).toBe(true)
    back.sync(key, [{ id: whapi.id, auth: 'token', secretHash: hashOf(whapi.token), enabled: true }])
    const synced = JSON.parse((await back.next()).subarray(17).toString())
    expect(synced.queued).toBe(3)
    const ns: number[] = []
    for (let i = 0; i < 3; i += 1) {
      const frame = await back.next()
      const parsed = readHead(frame.subarray(17))!
      const plain = readHead(openSealed(key, parsed.rest, sealAAD(whapi.id, frame.subarray(1, 17), parsed.head.receivedAt as number)))!
      ns.push(JSON.parse(plain.rest.toString()).n)
    }
    expect(ns).toEqual([1, 2, 3])
  })

  it('sends an unacknowledged delivery again after a reconnect', async () => {
    const port = await startRelay()
    const { whapi, host, key, secret } = await hostWithSources(port)
    await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')
    const first = await host.next()
    host.end()
    await waitFor(() => running!.rendezvous.stats().hosts === 0)
    const back = await Host.open(port, secret)
    back.sync(key, [{ id: whapi.id, auth: 'token', secretHash: hashOf(whapi.token), enabled: true }])
    await back.next()
    const again = await back.next()
    expect(again.subarray(1, 17).equals(first.subarray(1, 17))).toBe(true)
  })

  it('drops a source and its queue when the Mac stops listing it', async () => {
    const port = await startRelay()
    const { whapi, github, host, key } = await hostWithSources(port)
    await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')
    await host.next()
    host.sync(key, [{ id: github.id, auth: 'hmac', signatureHeader: 'x-hub-signature-256', enabled: true }])
    await host.next()
    expect(running!.rendezvous.receiver.stats().queued).toBe(0)
    expect((await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')).status).toBe(404)
  })

  it('ignores an acknowledgement from a different computer', async () => {
    const port = await startRelay()
    const { whapi, host } = await hostWithSources(port)
    await post(port, `/in/${whapi.id}/${whapi.token}`, '{}')
    const frame = await host.next()
    const other = await Host.open(port, randomBytes(32))
    other.sync(macKey(), [])
    await other.next()
    other.ack(frame.subarray(1, 17))
    await new Promise((r) => setTimeout(r, 100))
    expect(running!.rendezvous.receiver.stats().queued).toBe(1)
  })

  it('leaves phones and the MCP route exactly as they were', async () => {
    const port = await startRelay()
    const answer = await post(port, '/mcp/AAAAAAAAAAAAAAAAAAAAAAAAAA', '{"jsonrpc":"2.0","id":1,"method":"ping"}')
    expect(answer.body).toContain('Nothing answered at this address')
    const health = await post(port, '/healthz', '', {}, 'GET')
    expect(JSON.parse(health.body)).toEqual({ ok: true, hosts: 0, guests: 0 })
  })
})

/* -------------------------------------------------------------------------- */
/* Restarts and retention                                                      */
/* -------------------------------------------------------------------------- */

describe('surviving a restart, when a folder is given', () => {
  function folder(): string {
    const dir = mkdtempSync(join(tmpdir(), 'rcv-relay-'))
    dirs.push(dir)
    return dir
  }

  function declare(hub: ReceiverHub, hostId: string, key: MacKey, sources: unknown[]): Buffer[] {
    const sent: Buffer[] = []
    const connection = { send: (f: Buffer) => sent.push(f) }
    hub.hostJoined(hostId, connection)
    hub.fromHost(hostId, connection, encodeFrame(RECEIVER_ENVELOPE.sync, Buffer.alloc(16),
      Buffer.from(JSON.stringify({ v: 1, sealKey: key.publicRaw.toString('base64url'), sources }))))
    return sent
  }

  it('keeps the source list and the sealed queue, and the files on disk are sealed too', async () => {
    const dir = folder()
    const key = macKey()
    const id = sourceId()
    const secret = token()
    const hostId = 'A'.repeat(26)
    const first = new ReceiverHub({ dir })
    const sent = declare(first, hostId, key, [{ id, auth: 'token', secretHash: hashOf(secret), enabled: true }])
    first.hostLeft(hostId, { send: () => {} }) // a stranger's connection: ignored
    expect(sent.length).toBe(1)
    expect(first.admit(id)).toBe('ok')
    expect(first.accept(id, { method: 'POST', headers: {}, body: Buffer.from('{"text":"kept-across-restart"}'), pathToken: secret, clientIp: null })).toBe('ok')

    const files = readdirSync(join(dir, 'spool'))
    expect(files.length).toBe(1)
    const onDisk = readFileSync(join(dir, 'spool', files[0])).toString('latin1') + readFileSync(join(dir, 'receiver-sources.json'), 'utf8')
    expect(onDisk).not.toContain('kept-across-restart')
    expect(onDisk).not.toContain(secret)
    expect(onDisk).not.toContain(hostId)
    expect(onDisk).toContain(hostTagFor(hostId))

    const second = new ReceiverHub({ dir })
    expect(second.stats()).toMatchObject({ sources: 1, queued: 1 })
    const frames: Buffer[] = []
    const connection = { send: (f: Buffer) => frames.push(f) }
    second.hostJoined(hostId, connection)
    second.fromHost(hostId, connection, encodeFrame(RECEIVER_ENVELOPE.sync, Buffer.alloc(16),
      Buffer.from(JSON.stringify({ v: 1, sealKey: key.publicRaw.toString('base64url'), sources: [{ id, auth: 'token', secretHash: hashOf(secret) }] }))))
    const delivery = frames.find((f) => f[0] === RECEIVER_ENVELOPE.deliver)!
    const parsed = readHead(delivery.subarray(17))!
    const plain = readHead(openSealed(key, parsed.rest, sealAAD(id, delivery.subarray(1, 17), parsed.head.receivedAt as number)))!
    expect(plain.rest.toString()).toContain('kept-across-restart')

    second.fromHost(hostId, connection, encodeFrame(RECEIVER_ENVELOPE.ack, delivery.subarray(1, 17), Buffer.from([RECEIVER_ACK.kept])))
    expect(readdirSync(join(dir, 'spool')).length).toBe(0)
  })

  it('removes unreadable or foreign spool files rather than trusting them', () => {
    const dir = folder()
    const first = new ReceiverHub({ dir })
    expect(first.stats().queued).toBe(0)
    writeFileSync(join(dir, 'spool', `${'ab'.repeat(16)}.bin`), Buffer.from('garbage'))
    writeFileSync(join(dir, 'spool', 'note.txt'), 'x')
    const second = new ReceiverHub({ dir })
    expect(second.stats().queued).toBe(0)
    expect(readdirSync(join(dir, 'spool'))).toEqual([])
  })

  it('lets deliveries expire after the retention period, checked on the next arrival', () => {
    let now = 1_800_000_000_000
    const key = macKey()
    const id = sourceId()
    const secret = token()
    const hub = new ReceiverHub({ now: () => now })
    declare(hub, 'B'.repeat(26), key, [{ id, auth: 'token', secretHash: hashOf(secret) }])
    hub.hostLeft('B'.repeat(26), { send: () => {} })
    hub.accept(id, { method: 'POST', headers: {}, body: Buffer.from('{}'), pathToken: secret, clientIp: null })
    expect(hub.stats().queued).toBe(1)
    now += RECEIVER_RETENTION_MS + 1
    expect(hub.admit(id)).toBe('ok')
    expect(hub.stats().queued).toBe(0)
  })
})

describe('paths and the cross-language seal', () => {
  it('parses only the two address forms', () => {
    const id = sourceId()
    const t = token()
    expect(parseReceiverPath(`/in/${id}`)).toEqual({ sourceId: id, pathToken: null })
    expect(parseReceiverPath(`/in/${id}/`)).toEqual({ sourceId: id, pathToken: null })
    expect(parseReceiverPath(`/in/${id}/${t}`)).toEqual({ sourceId: id, pathToken: t })
    expect(parseReceiverPath(`/in/${id.toLowerCase()}`)).toBeNull()
    expect(parseReceiverPath(`/in/${id}/${t}/x`)).toBeNull()
  })

  /*
   * The fixed vector the Swift side opens in RCVSecurityTests.swift. If either
   * side changes the construction, one of the two suites goes red.
   */
  it('opens the fixed vector shared with the Mac', () => {
    const privateRaw = Buffer.from('a8abababababababababababababababababababababababababababababab6b', 'hex')
    const privateKey = createPrivateKey({ key: Buffer.concat([PKCS8_X25519, privateRaw]), format: 'der', type: 'pkcs8' })
    const publicRaw = createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(12)
    const sealed = Buffer.from(SHARED_VECTOR.sealed, 'base64')
    const plain = openSealed({ privateKey, publicRaw }, sealed, Buffer.from(SHARED_VECTOR.aad))
    expect(plain.toString('utf8')).toBe(SHARED_VECTOR.plain)
    // And a fresh seal to the same key opens the same way.
    const fresh = sealTo(publicRaw, Buffer.from('again'), Buffer.from('aad'))
    expect(openSealed({ privateKey, publicRaw }, fresh, Buffer.from('aad')).toString()).toBe('again')
  })
})

const SHARED_VECTOR = {
  aad: 'AAAAAAAAAAAAAAAAAAAAAAAAAA.00112233445566778899aabbccddeeff.1800000000000',
  plain: '{"hello":"receiver"}',
  sealed: 'YMB8fiXuuaE4bGh+x/v6JqIwI4gB/bqTGxmC5rHvv2dIgoObvJcBG2qNQnBb3Bo97xUhup7a25YuFWsL4SeYY7Oaw3Kw2k/ouEizu0+r9zI=',
}
