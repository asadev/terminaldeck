/**
 * Tests for the rendezvous relay.
 *
 * These run against a real `http.Server` on loopback with real WebSocket
 * handshakes and real framing — not a mock — because every bug this component
 * has had so far lived in the parts a mock replaces: the upgrade, the masking,
 * the socket that ends without closing.
 *
 * The last test is the one that matters most. It runs a full Noise handshake
 * between two endpoints *through* the relay and then asserts that everything
 * the relay saw is opaque. If that test ever goes green while the property is
 * false, the entire justification for running this service is gone.
 */

import { AddressInfo } from 'node:net'
import { connect, type Socket } from 'node:net'
import { randomBytes } from 'node:crypto'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ENVELOPE,
  MAX_PAYLOAD_BYTES,
  createRelayServer,
  decodeEnvelope,
  encodeEnvelope,
  hostIdFor,
  isHostId,
  type RelayOptions,
  type RelayServer,
} from './rendezvous'
import { FrameReader, OPCODE, encodeFrame } from '../../src/shared/ws-frame'
import { finishHandshake, generateStatic, respondToHandshake, startHandshake } from '../../src/shared/sealed'

/* -------------------------------------------------------------------------- */
/* A minimal client, because `ws` is not a dependency of this project          */
/* -------------------------------------------------------------------------- */

/** Client frames must be masked (RFC 6455 §5.3), so the test masks them. */
function maskedFrame(opcode: number, payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  const length = masked.length
  let header: Buffer
  if (length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | length
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, mask, masked])
}

class TestClient {
  // Reading what a SERVER sent, so frames arrive unmasked.
  private readonly reader = new FrameReader(MAX_PAYLOAD_BYTES * 2, 'client')
  private readonly inbox: Buffer[] = []
  private waiting: ((frame: Buffer) => void) | null = null
  closed = false
  status = 0

  private constructor(private readonly socket: Socket) {}

  static async open(port: number, path: string, headers: Record<string, string> = {}): Promise<TestClient> {
    const socket = connect(port, '127.0.0.1')
    const client = new TestClient(socket)
    await new Promise<void>((resolve, reject) => {
      socket.once('error', reject)
      socket.once('connect', () => resolve())
    })

    const lines = [
      `GET ${path} HTTP/1.1`,
      'Host: 127.0.0.1',
      'Upgrade: websocket',
      'Connection: Upgrade',
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
      'Sec-WebSocket-Version: 13',
      ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
      '',
      '',
    ]
    socket.write(lines.join('\r\n'))

    // Read exactly the HTTP response, then hand the remainder to the framer.
    const head = await new Promise<Buffer>((resolve) => {
      let buffer = Buffer.alloc(0)
      const onData = (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        const end = buffer.indexOf('\r\n\r\n')
        if (end === -1) return
        socket.off('data', onData)
        const rest = buffer.subarray(end + 4)
        if (rest.length) client.feed(rest)
        socket.on('data', (next: Buffer) => client.feed(next))
        resolve(buffer.subarray(0, end))
      }
      socket.on('data', onData)
      socket.on('close', () => {
        client.closed = true
        resolve(buffer)
      })
    })
    client.status = Number(/HTTP\/1\.1 (\d+)/.exec(head.toString('latin1'))?.[1] ?? 0)
    socket.on('close', () => {
      client.closed = true
    })
    return client
  }

  private feed(chunk: Buffer): void {
    const batch = this.reader.push(chunk)
    for (const frame of batch.frames) {
      if (frame.opcode === OPCODE.close) {
        this.closed = true
        continue
      }
      if (frame.opcode === OPCODE.ping) {
        this.socket.write(maskedFrame(OPCODE.pong, frame.payload))
        continue
      }
      if (frame.opcode !== OPCODE.binary && frame.opcode !== OPCODE.text) continue
      const waiter = this.waiting
      if (waiter) {
        this.waiting = null
        waiter(frame.payload)
      } else {
        this.inbox.push(frame.payload)
      }
    }
  }

  send(payload: Buffer): void {
    this.socket.write(maskedFrame(OPCODE.binary, payload))
  }

  /** Raw write, for the tests that deliberately break the rules. */
  sendRaw(frame: Buffer): void {
    this.socket.write(frame)
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

  async closedSoon(timeoutMs = 2000): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (this.closed) return true
      await new Promise((r) => setTimeout(r, 10))
    }
    return this.closed
  }

  end(): void {
    this.socket.destroy()
  }
}

/* -------------------------------------------------------------------------- */
/* Harness                                                                     */
/* -------------------------------------------------------------------------- */

let running: RelayServer | null = null
const clients: TestClient[] = []

async function startRelay(options: RelayOptions = {}): Promise<{ port: number; relay: RelayServer }> {
  const relay = createRelayServer({ heartbeatMs: 60_000, ...options })
  await new Promise<void>((resolve) => relay.server.listen(0, '127.0.0.1', resolve))
  running = relay
  return { port: (relay.server.address() as AddressInfo).port, relay }
}

async function openHost(port: number, secret: Buffer): Promise<TestClient> {
  const client = await TestClient.open(port, '/v1/host', {
    'x-deck-host-secret': secret.toString('base64url'),
  })
  clients.push(client)
  return client
}

async function openGuest(port: number, hostId: string): Promise<TestClient> {
  const client = await TestClient.open(port, `/v1/join?host=${hostId}`)
  clients.push(client)
  return client
}

afterEach(async () => {
  for (const client of clients.splice(0)) client.end()
  await running?.close()
  running = null
})

/* -------------------------------------------------------------------------- */
/* Tests                                                                       */
/* -------------------------------------------------------------------------- */

describe('host names', () => {
  it('derives a stable 26-character id from a secret', () => {
    const secret = randomBytes(32)
    expect(hostIdFor(secret)).toBe(hostIdFor(secret))
    expect(hostIdFor(secret)).toHaveLength(26)
    expect(isHostId(hostIdFor(secret))).toBe(true)
  })

  it('gives different secrets different ids', () => {
    const ids = new Set(Array.from({ length: 200 }, () => hostIdFor(randomBytes(32))))
    expect(ids.size).toBe(200)
  })

  it('uses no character anyone misreads', () => {
    for (let i = 0; i < 50; i += 1) expect(hostIdFor(randomBytes(32))).not.toMatch(/[01OI]/)
  })

  it('rejects anything that is not a host id', () => {
    expect(isHostId('')).toBe(false)
    expect(isHostId('lowercaseaaaaaaaaaaaaaaaaa')).toBe(false)
    expect(isHostId('A'.repeat(25))).toBe(false)
    expect(isHostId('A'.repeat(27))).toBe(false)
    expect(isHostId(`${'A'.repeat(25)}0`)).toBe(false)
  })
})

describe('envelope', () => {
  it('round-trips', () => {
    const channel = randomBytes(16)
    const decoded = decodeEnvelope(encodeEnvelope(ENVELOPE.data, channel, Buffer.from('hi')))
    expect(decoded?.type).toBe(ENVELOPE.data)
    expect(decoded?.channel.equals(channel)).toBe(true)
    expect(decoded?.payload.toString()).toBe('hi')
  })

  it('refuses a short frame and an unknown type', () => {
    expect(decodeEnvelope(Buffer.alloc(5))).toBeNull()
    expect(decodeEnvelope(Buffer.concat([Buffer.from([0x7f]), randomBytes(16)]))).toBeNull()
  })

  it('refuses a channel id of the wrong size', () => {
    expect(() => encodeEnvelope(ENVELOPE.data, randomBytes(8), Buffer.alloc(0))).toThrow(/16 bytes/)
  })
})

describe('connecting', () => {
  it('accepts a host and reports it in health', async () => {
    const { port, relay } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    expect(host.status).toBe(101)
    await new Promise((r) => setTimeout(r, 50))
    expect(relay.rendezvous.stats().hosts).toBe(1)
    expect(relay.rendezvous.has(hostIdFor(secret))).toBe(true)
  })

  it('refuses a host with no secret', async () => {
    const { port } = await startRelay()
    const client = await TestClient.open(port, '/v1/host')
    clients.push(client)
    expect(client.status).toBe(401)
  })

  it('refuses a host secret of the wrong length', async () => {
    const { port } = await startRelay()
    const client = await TestClient.open(port, '/v1/host', {
      'x-deck-host-secret': randomBytes(8).toString('base64url'),
    })
    clients.push(client)
    expect(client.status).toBe(401)
  })

  it('refuses a malformed host id on join', async () => {
    const { port } = await startRelay()
    const client = await TestClient.open(port, '/v1/join?host=nope')
    clients.push(client)
    expect(client.status).toBe(400)
  })

  it('does not reveal whether an absent host exists', async () => {
    const { port } = await startRelay()
    const absent = hostIdFor(randomBytes(32))
    const client = await openGuest(port, absent)
    // Upgraded first, closed after — identical to the response a real host
    // would produce up to the point the socket ends.
    expect(client.status).toBe(101)
    expect(await client.closedSoon()).toBe(true)
  })

  it('answers health without naming anyone', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    await openHost(port, secret)
    await new Promise((r) => setTimeout(r, 50))
    const response = await fetch(`http://127.0.0.1:${port}/healthz`)
    const body = await response.json()
    expect(body).toEqual({ ok: true, hosts: 1, guests: 0 })
    expect(JSON.stringify(body)).not.toContain(hostIdFor(secret))
  })
})

describe('relaying', () => {
  it('tells the host when a guest arrives, with a channel id', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    await openGuest(port, hostIdFor(secret))

    const opened = decodeEnvelope(await host.next())
    expect(opened?.type).toBe(ENVELOPE.open)
    expect(opened?.channel).toHaveLength(16)
  })

  it('carries bytes from guest to host and back', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const guest = await openGuest(port, hostIdFor(secret))

    const channel = decodeEnvelope(await host.next())!.channel
    guest.send(Buffer.from('up'))
    const arrived = decodeEnvelope(await host.next())
    expect(arrived?.type).toBe(ENVELOPE.data)
    expect(arrived?.channel.equals(channel)).toBe(true)
    expect(arrived?.payload.toString()).toBe('up')

    host.send(encodeEnvelope(ENVELOPE.data, channel, Buffer.from('down')))
    expect((await guest.next()).toString()).toBe('down')
  })

  it('keeps two guests on separate channels', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const first = await openGuest(port, hostIdFor(secret))
    const channelA = decodeEnvelope(await host.next())!.channel
    const second = await openGuest(port, hostIdFor(secret))
    const channelB = decodeEnvelope(await host.next())!.channel

    expect(channelA.equals(channelB)).toBe(false)

    host.send(encodeEnvelope(ENVELOPE.data, channelA, Buffer.from('for A')))
    host.send(encodeEnvelope(ENVELOPE.data, channelB, Buffer.from('for B')))
    expect((await first.next()).toString()).toBe('for A')
    expect((await second.next()).toString()).toBe('for B')
  })

  it('does not deliver to a channel that is not this host\'s', async () => {
    const { port } = await startRelay()
    const secretA = randomBytes(32)
    const secretB = randomBytes(32)
    const hostA = await openHost(port, secretA)
    const hostB = await openHost(port, secretB)
    const guestB = await openGuest(port, hostIdFor(secretB))
    const channelB = decodeEnvelope(await hostB.next())!.channel

    // Host A names host B's channel. It must go nowhere.
    hostA.send(encodeEnvelope(ENVELOPE.data, channelB, Buffer.from('stolen')))
    await expect(guestB.next(300)).rejects.toThrow(/timed out/)
  })

  it('tells the host when a guest leaves', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const guest = await openGuest(port, hostIdFor(secret))
    const channel = decodeEnvelope(await host.next())!.channel

    guest.end()
    const closed = decodeEnvelope(await host.next())
    expect(closed?.type).toBe(ENVELOPE.close)
    expect(closed?.channel.equals(channel)).toBe(true)
  })

  it('cuts the guests when the host disappears', async () => {
    const { port, relay } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const guest = await openGuest(port, hostIdFor(secret))
    await host.next()

    host.end()
    expect(await guest.closedSoon()).toBe(true)
    expect(relay.rendezvous.stats().hosts).toBe(0)
  })

  it('lets a reconnecting host replace itself and drops the stale one', async () => {
    const { port, relay } = await startRelay()
    const secret = randomBytes(32)
    const first = await openHost(port, secret)
    await new Promise((r) => setTimeout(r, 50))
    const second = await openHost(port, secret)
    await new Promise((r) => setTimeout(r, 100))

    expect(await first.closedSoon()).toBe(true)
    expect(second.closed).toBe(false)
    // The live entry must survive the dead one's cleanup.
    expect(relay.rendezvous.has(hostIdFor(secret))).toBe(true)
    expect(relay.rendezvous.stats().hosts).toBe(1)
  })

  it('caps the guests one host may hold', async () => {
    // Its own relay, registered with the harness like any other, so `afterEach`
    // closes it. An earlier version started a second relay behind the first and
    // leaked the listener, which is why this test used to hang rather than fail.
    const { port } = await startRelay({ maxGuestsPerHost: 2 })
    const secret = randomBytes(32)
    await openHost(port, secret)

    const a = await openGuest(port, hostIdFor(secret))
    const b = await openGuest(port, hostIdFor(secret))
    const c = await openGuest(port, hostIdFor(secret))

    expect(await c.closedSoon()).toBe(true)
    expect(a.closed).toBe(false)
    expect(b.closed).toBe(false)
  })

  it('closes a guest that sends more than the cap', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const guest = await openGuest(port, hostIdFor(secret))
    await host.next()

    // Declared larger than the framer will accept, so the socket dies at the
    // frame layer before anything is buffered.
    guest.sendRaw(encodeFrame(OPCODE.binary, Buffer.alloc(MAX_PAYLOAD_BYTES * 3)))
    expect(await guest.closedSoon()).toBe(true)
  })
})

describe('the relay cannot read what it carries', () => {
  it('sees only ciphertext for a full sealed session', async () => {
    const { port } = await startRelay()
    const secret = randomBytes(32)
    const host = await openHost(port, secret)
    const guest = await openGuest(port, hostIdFor(secret))
    const channel = decodeEnvelope(await host.next())!.channel

    // Everything the relay process handled, recorded as it passed through.
    const seen: Buffer[] = []

    const mac = generateStatic()
    const phone = generateStatic()

    // Phone opens the sealed channel through the relay.
    const started = startHandshake(phone, mac.publicKey)
    guest.send(started.message)
    const atHost = decodeEnvelope(await host.next())!
    seen.push(atHost.payload)

    const answered = respondToHandshake(mac, atHost.payload, (key) => key.equals(phone.publicKey))
    host.send(encodeEnvelope(ENVELOPE.data, channel, answered.reply))
    const atGuest = await guest.next()
    seen.push(atGuest)
    const client = finishHandshake(started.pending, atGuest)

    // A real exchange over the sealed channel.
    const command = 'cat ~/.ssh/id_ed25519'
    guest.send(client.send(Buffer.from(command, 'utf8')))
    const sealedUp = decodeEnvelope(await host.next())!
    seen.push(sealedUp.payload)
    expect(answered.transport.receive(sealedUp.payload).toString('utf8')).toBe(command)

    const reply = 'permission denied'
    host.send(encodeEnvelope(ENVELOPE.data, channel, answered.transport.send(Buffer.from(reply))))
    const sealedDown = await guest.next()
    seen.push(sealedDown)
    expect(client.receive(sealedDown).toString('utf8')).toBe(reply)

    // Now the actual assertion: nothing readable ever crossed the relay.
    const everything = Buffer.concat(seen).toString('latin1')
    expect(everything).not.toContain(command)
    expect(everything).not.toContain(reply)
    expect(everything).not.toContain('ssh')
    expect(everything).not.toContain('denied')
    // Nor were the identities visible — IK encrypts the initiator's static key.
    expect(everything).not.toContain(phone.publicKey.toString('latin1'))
  })
})
