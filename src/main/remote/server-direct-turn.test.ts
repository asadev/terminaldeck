import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ServerDirectTurn } from './server-direct-turn'

const STUN = [{ urls: ['stun:stun.cloudflare.com:3478'] }]
const A = 'a'.repeat(32)
const B = 'b'.repeat(32)
const C = 'c'.repeat(32)
const base = 'wss://relay.example.test/host?room=private'

interface Call {
  path: string
  body: { device: string; ttl?: number; login?: string }
  init?: RequestInit
}

function reply(device = 'phone', login = A, expiresAtMs = Date.now() + 3_600_000): Response {
  return Response.json({ ok: true, device, login, expiresAtMs, iceServers: [
    { urls: ['turn:turn.example.test:3478', 'turns:turn.example.test:443?transport=tcp'], username: device, credential: `test-${login}` }
  ] })
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { promise, resolve }
}

function fixture(handler: (call: Call) => Promise<Response> | Response = call => call.path === '/v1/turn' ? reply(call.body.device) : Response.json({ ok: true })) {
  const calls: Call[] = []
  let connected = true
  const request: typeof fetch = async (input, init) => {
    const target = new URL(String(input))
    const call: Call = { path: target.pathname, body: JSON.parse(String(init?.body)) as Call['body'], init }
    calls.push(call)
    expect(target.search).toBe('')
    return handler(call)
  }
  const turn = new ServerDirectTurn(base, Buffer.from('fixture only'), () => connected, { fetch: request })
  return { turn, calls, disconnect: () => { connected = false } }
}

beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(new Date('2026-11-04T12:00:00Z')) })
afterEach(() => { vi.useRealTimers() })

describe('server host TURN lifecycle', () => {
  it('shares a pending request for one device and keeps credentials separate across devices', async () => {
    const pending = deferred<Response>()
    const { turn, calls } = fixture(call => call.path === '/v1/turn' && call.body.device === 'phone' ? pending.promise : reply(call.body.device, B))
    const first = turn.servers('phone')
    const same = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(0)
    expect(calls).toHaveLength(1)
    pending.resolve(reply())
    expect(await first).toEqual(await same)
    const other = await turn.servers('tablet')
    expect(other[1].username).toBe('tablet')
    expect(calls.map(call => call.body.device)).toEqual(['phone', 'tablet'])
    const init = calls[0].init
    expect(init?.headers).toEqual({ 'content-type': 'application/json', 'x-deck-host-secret': Buffer.from('fixture only').toString('base64url') })
    expect(init?.redirect).toBe('error')
    expect(calls[0].body).toEqual({ device: 'phone', ttl: 3_600 })
  })

  it('reuses the cached login until only ten minutes remain', async () => {
    let count = 0
    const { turn, calls } = fixture(call => reply(call.body.device, ++count === 1 ? A : B))
    await turn.servers('phone')
    await vi.advanceTimersByTimeAsync(2_999_999)
    await turn.servers('phone')
    expect(calls).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    expect((await turn.servers('phone'))[1].credential).toBe(`test-${B}`)
    expect(calls).toHaveLength(2)
  })

  it('withdraws by name two minutes after the last active connection closes', async () => {
    const { turn, calls } = fixture()
    turn.retain('phone')
    turn.retain('phone')
    await turn.servers('phone')
    await turn.release('phone')
    await vi.advanceTimersByTimeAsync(120_000)
    expect(calls).toHaveLength(1)
    await turn.release('phone')
    await vi.advanceTimersByTimeAsync(119_999)
    expect(calls).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(calls[1].path).toBe('/v1/turn/revoke')
    expect(calls[1].body).toEqual({ device: 'phone', login: A })
  })

  it('keeps a login when its device reconnects during the grace period', async () => {
    const { turn, calls } = fixture()
    turn.retain('phone')
    await turn.servers('phone')
    await turn.release('phone')
    await vi.advanceTimersByTimeAsync(119_000)
    turn.retain('phone')
    await turn.servers('phone')
    await vi.advanceTimersByTimeAsync(2_000)
    expect(calls).toHaveLength(1)
  })

  it('withdraws immediately and unconditionally when access is removed', async () => {
    const { turn, calls } = fixture()
    turn.retain('phone')
    await turn.servers('phone')
    await turn.release('phone', true)
    expect(calls[1].body).toEqual({ device: 'phone' })
    await vi.advanceTimersByTimeAsync(120_000)
    expect(calls).toHaveLength(2)
  })

  it('withdraws an in-flight login by name after access is removed and mints again only after it finishes', async () => {
    const pending = deferred<Response>()
    let minted = 0
    const { turn, calls } = fixture(call => call.path === '/v1/turn/revoke' ? Response.json({ ok: true }) : ++minted === 1 ? pending.promise : reply('phone', B))
    const old = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(0)
    await turn.release('phone', true)
    turn.retain('phone')
    const fresh = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(0)
    expect(minted).toBe(1)
    pending.resolve(reply())
    expect(await old).toEqual(STUN)
    expect((await fresh)[1].credential).toBe(`test-${B}`)
    expect(calls.filter(call => call.path === '/v1/turn/revoke').map(call => call.body)).toEqual([{ device: 'phone' }, { device: 'phone', login: A }])
  })

  it('finishes an unconditional withdrawal before a new login request', async () => {
    const revoke = deferred<Response>()
    const { turn, calls } = fixture(call => call.path === '/v1/turn/revoke' ? revoke.promise : reply())
    await turn.servers('phone')
    const removing = turn.release('phone', true)
    const fresh = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(0)
    expect(calls).toHaveLength(2)
    revoke.resolve(Response.json({ ok: true }))
    await removing
    await fresh
    expect(calls.map(call => call.path)).toEqual(['/v1/turn', '/v1/turn/revoke', '/v1/turn'])
  })

  it('withdraws all cached logins by name before stop returns even if the socket is already closed', async () => {
    const { turn, calls, disconnect } = fixture(call => call.path === '/v1/turn' ? reply(call.body.device, call.body.device === 'phone' ? A : B) : Response.json({ ok: true }))
    await turn.servers('phone')
    await turn.servers('tablet')
    disconnect()
    await turn.stop()
    expect(calls.filter(call => call.path === '/v1/turn/revoke').map(call => call.body)).toEqual([{ device: 'phone', login: A }, { device: 'tablet', login: B }])
    expect(await turn.servers('phone')).toEqual(STUN)
    expect(calls).toHaveLength(4)
  })

  it('withdraws a mint that completes while the host stops', async () => {
    const pending = deferred<Response>()
    const { turn, calls } = fixture(call => call.path === '/v1/turn' ? pending.promise : Response.json({ ok: true }))
    const ask = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(0)
    const stopping = turn.stop()
    pending.resolve(reply())
    await stopping
    expect(await ask).toEqual(STUN)
    expect(calls[1].body).toEqual({ device: 'phone', login: A })
  })

  it('retries failed named withdrawals after 5, 30 and 120 seconds', async () => {
    const { turn, calls } = fixture(call => call.path === '/v1/turn' ? reply() : Response.json({ ok: false }, { status: 502 }))
    await turn.servers('phone')
    await turn.release('phone')
    await vi.advanceTimersByTimeAsync(120_000)
    await vi.advanceTimersByTimeAsync(5_000)
    await vi.advanceTimersByTimeAsync(30_000)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(calls.filter(call => call.path === '/v1/turn/revoke').map(call => call.body)).toEqual(Array.from({ length: 4 }, () => ({ device: 'phone', login: A })))
  })

  it('cancels old withdrawal retries when a new login is issued', async () => {
    let minted = 0
    const { turn, calls } = fixture(call => call.path === '/v1/turn' ? reply('phone', ++minted === 1 ? A : C) : Response.json({ ok: false }, { status: 503 }))
    await turn.servers('phone')
    await turn.release('phone')
    await vi.advanceTimersByTimeAsync(120_000)
    turn.retain('phone')
    await turn.servers('phone')
    await vi.advanceTimersByTimeAsync(200_000)
    expect(calls.filter(call => call.path === '/v1/turn/revoke')).toHaveLength(1)
  })

  it('uses STUN alone for offline, invalid-device and refused requests', async () => {
    const { turn, calls, disconnect } = fixture(() => Response.json({ ok: false }, { status: 403 }))
    expect(await turn.servers('phone')).toEqual(STUN)
    expect(await turn.servers('bad device')).toEqual(STUN)
    disconnect()
    expect(await turn.servers('tablet')).toEqual(STUN)
    expect(calls).toHaveLength(1)
  })

  it('times out asks after three seconds and withdraws a late successful response by name', async () => {
    const pending = deferred<Response>()
    const { turn, calls } = fixture(call => call.path === '/v1/turn' ? pending.promise : Response.json({ ok: true }))
    const ask = turn.servers('phone')
    await vi.advanceTimersByTimeAsync(3_000)
    expect(await ask).toEqual(STUN)
    expect(calls[0].init?.signal?.aborted).toBe(true)
    pending.resolve(reply())
    await vi.advanceTimersByTimeAsync(0)
    expect(calls[1].body).toEqual({ device: 'phone', login: A })
  })

  it('bounds a stop waiting for an unresponsive withdrawal to three seconds', async () => {
    const { turn } = fixture(call => call.path === '/v1/turn' ? reply() : new Promise<Response>(() => {}))
    await turn.servers('phone')
    const stopping = turn.stop()
    await vi.advanceTimersByTimeAsync(3_000)
    await stopping
  })

  it('always includes Cloudflare STUN, filters unsupported URL schemes and isolates callers from the cache', async () => {
    const { turn } = fixture(() => Response.json({ ok: true, device: 'phone', login: A, expiresAtMs: Date.now() + 3_600_000, iceServers: [
      { urls: ['https://example.test', 'turns:turn.example.test:443?transport=tcp'], username: 'phone', credential: 'fixture' }
    ] }))
    const first = await turn.servers('phone')
    expect(first).toEqual([...STUN, { urls: ['turns:turn.example.test:443?transport=tcp'], username: 'phone', credential: 'fixture' }])
    first[1].urls[0] = 'turn:tampered.example.test'
    expect((await turn.servers('phone'))[1].urls[0]).toBe('turns:turn.example.test:443?transport=tcp')
  })

  it('rejects mismatched devices, expired logins and missing login ids', async () => {
    const bodies = [
      { ok: true, device: 'other', login: A, expiresAtMs: Date.now() + 3_600_000, iceServers: STUN },
      { ok: true, device: 'phone', login: A, expiresAtMs: Date.now() - 1, iceServers: STUN },
      { ok: true, device: 'phone', expiresAtMs: Date.now() + 3_600_000, iceServers: STUN }
    ]
    const { turn } = fixture(() => Response.json(bodies.shift()))
    for (let index = 0; index < 3; index += 1) expect(await turn.servers('phone')).toEqual(STUN)
  })

  it('reserves a STUN slot within the eight-server limit', async () => {
    const servers = Array.from({ length: 12 }, (_, index) => ({ urls: [`turn:turn${index}.example.test:3478`], username: 'phone', credential: 'fixture' }))
    const { turn } = fixture(() => Response.json({ ok: true, device: 'phone', login: A, expiresAtMs: Date.now() + 3_600_000, iceServers: servers }))
    const given = await turn.servers('phone')
    expect(given).toHaveLength(8)
    expect(given[0]).toEqual(STUN[0])
    expect(given[7].urls).toEqual(['turn:turn6.example.test:3478'])
  })

  it('stops reading an oversized credential response before buffering the whole stream', async () => {
    let cancelled = false
    const body = new ReadableStream<Uint8Array>({
      pull(controller) { controller.enqueue(new Uint8Array(65_537)) },
      cancel() { cancelled = true }
    })
    const { turn } = fixture(() => new Response(body))
    expect(await turn.servers('phone')).toEqual(STUN)
    expect(cancelled).toBe(true)
  })
})
