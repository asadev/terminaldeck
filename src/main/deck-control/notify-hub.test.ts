import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  MAX_AGE_MS,
  MAX_PER_KEY,
  NOTIFICATIONS_FILE,
  NotificationHub,
  RETRY_DELAYS_MS,
  fetchPost,
  type HubClock,
  type KeyNotifySettings,
  type NotificationEvent,
  type WebhookPost,
} from './notify-hub'
import { newWebhookSecret, verifyWebhook } from './notify-webhook'
import { MAX_NOTIFY_WAIT_SECONDS } from './notify-tools'
import { MCP_RELAY_WAIT_MS } from '../../shared/relay-wire'

/**
 * The queue, under a clock that only moves when the test moves it.
 *
 * Never a real wait and never a busy loop: every timer the hub arms is a row in
 * {@link FakeClock}, and `advance` runs the ones that fall due. That is how the
 * retry schedule — immediately, then 5 s, 30 s, 2 min — is checked to the
 * millisecond without the test taking two and a half minutes.
 */

class FakeClock implements HubClock {
  at = 1_000_000
  private seq = 0
  private readonly timers = new Map<number, { due: number; run: () => void }>()

  now(): number {
    return this.at
  }
  setTimeout(run: () => void, ms: number): unknown {
    const id = (this.seq += 1)
    this.timers.set(id, { due: this.at + ms, run })
    return id
  }
  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number)
  }
  /** How many timers are armed. The hub promises one at most, and none when idle. */
  pending(): number {
    return this.timers.size
  }
  async advance(ms: number): Promise<void> {
    const target = this.at + ms
    for (;;) {
      const next = [...this.timers.entries()].filter(([, t]) => t.due <= target).sort((a, b) => a[1].due - b[1].due)[0]
      if (!next) break
      this.at = next[1].due
      this.timers.delete(next[0])
      next[1].run()
      // Let a webhook post's promise chain settle between timers.
      await flush()
    }
    this.at = target
    await flush()
  }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 5; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

let dir = ''
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-notify-hub-'))
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

let seq = 0
function event(sessionId = 's1', over: Partial<NotificationEvent> = {}): NotificationEvent {
  seq += 1
  return {
    id: `n-${seq}`,
    type: 'finished',
    sessionId,
    sessionName: sessionId,
    at: 1_000_000,
    answer: { text: `answer ${seq}`, truncated: false },
    suggestedTool: 'sessions_send',
    note: 'finished',
    ...over,
  }
}

interface Rig {
  hub: NotificationHub
  clock: FakeClock
  settings: Map<string, KeyNotifySettings>
  posts: Array<{ url: string; headers: Record<string, string>; body: string }>
}

function rig(options: { post?: WebhookPost; disk?: boolean; clock?: FakeClock; settings?: Map<string, KeyNotifySettings> } = {}): Rig {
  const clock = options.clock ?? new FakeClock()
  const settings =
    options.settings ??
    new Map<string, KeyNotifySettings>([
      ['A', { mode: 'wait', url: null, secret: null }],
      ['B', { mode: 'wait', url: null, secret: null }],
    ])
  const posts: Rig['posts'] = []
  const hub = new NotificationHub({
    dir: options.disk === false ? null : dir,
    settings: (keyId) => settings.get(keyId) ?? null,
    clock,
    post:
      options.post ??
      (async (url, headers, body) => {
        posts.push({ url, headers, body })
        return 200
      }),
  })
  return { hub, clock, settings, posts }
}

describe('whose notification is whose', () => {
  it('shows a key only its own, whatever is interleaved, and acks blind to the other key', async () => {
    const { hub } = rig()
    const a1 = event('a-session-1')
    const b1 = event('b-session-1')
    const a2 = event('a-session-2')
    hub.enqueue('A', a1)
    hub.enqueue('B', b1)
    hub.enqueue('A', a2)
    expect(hub.list('A').map((n) => n.id)).toEqual([a1.id, a2.id])
    expect(hub.list('B').map((n) => n.id)).toEqual([b1.id])
    expect((await hub.wait('B', 1_000)).map((n) => n.id)).toEqual([b1.id])
    // B acking A's id is the same as acking nothing: A still has it.
    expect(hub.ack('B', [a1.id])).toEqual({ acked: [], alreadyGone: [a1.id] })
    expect(hub.list('A').map((n) => n.id)).toEqual([a1.id, a2.id])
    // And the answer for "someone else's" is the answer for "never existed".
    expect(hub.ack('B', ['nope'])).toEqual({ acked: [], alreadyGone: ['nope'] })
  })

  it('keeps nothing for a key set to off, or one that is gone', () => {
    const { hub, settings } = rig()
    settings.set('A', { mode: 'off', url: null, secret: null })
    expect(hub.enqueue('A', event())).toBe(false)
    expect(hub.enqueue('Z', event())).toBe(false)
    expect(hub.size()).toBe(0)
  })

  it('drops a revoked key’s queue and answers its parked wait with nothing', async () => {
    const { hub, settings } = rig()
    hub.enqueue('A', event())
    const parked = hub.wait('B', 10_000)
    settings.delete('A')
    settings.delete('B')
    hub.reconcile()
    expect(hub.size('A')).toBe(0)
    expect(await parked).toEqual([])
  })
})

describe('the long-poll', () => {
  it('hands a parked waiter the notification the moment it is queued', async () => {
    const { hub } = rig()
    const parked = hub.wait('A', 30_000)
    const n = event()
    hub.enqueue('A', n)
    expect((await parked).map((e) => e.id)).toEqual([n.id])
    expect(hub.list('A')[0]).toMatchObject({ delivery: 'delivered', via: 'wait' })
  })

  it('times out with nothing, and never takes another key’s', async () => {
    const { hub, clock } = rig()
    const parked = hub.wait('A', 45_000)
    hub.enqueue('B', event())
    await clock.advance(45_000)
    expect(await parked).toEqual([])
  })

  it('stops holding for a caller that hung up', async () => {
    const { hub } = rig()
    const abort = new AbortController()
    const parked = hub.wait('A', 45_000, abort.signal)
    abort.abort()
    expect(await parked).toEqual([])
    // The notification queued after it is still there for the next caller.
    const n = event()
    hub.enqueue('A', n)
    expect((await hub.wait('A', 1)).map((e) => e.id)).toEqual([n.id])
  })

  it('never waits longer than the relay will hold the request', () => {
    expect(MAX_NOTIFY_WAIT_SECONDS * 1000).toBeLessThan(MCP_RELAY_WAIT_MS)
    expect(MCP_RELAY_WAIT_MS - MAX_NOTIFY_WAIT_SECONDS * 1000).toBeGreaterThanOrEqual(20_000)
  })
})

describe('acknowledging', () => {
  it('is by id, idempotent, and the second ack changes nothing', async () => {
    const { hub } = rig()
    const n = event()
    hub.enqueue('A', n)
    const [got] = await hub.wait('A', 1)
    expect(hub.ack('A', [got.id])).toEqual({ acked: [n.id], alreadyGone: [] })
    expect(hub.ack('A', [got.id])).toEqual({ acked: [], alreadyGone: [n.id] })
    expect(hub.list('A')).toEqual([])
  })

  it('does not hand the same notification to a second wait once delivered', async () => {
    const { hub, clock } = rig()
    hub.enqueue('A', event())
    expect(await hub.wait('A', 1)).toHaveLength(1)
    const second = hub.wait('A', 1)
    await clock.advance(1)
    expect(await second).toHaveLength(0)
    // But list still shows it until acknowledged — the catch-up after a lost answer.
    expect(hub.list('A')).toHaveLength(1)
  })

  it('counts an MCP Events push as delivery, for that key only, and does not hand it to a wait again', async () => {
    const { hub, clock } = rig()
    const n = event()
    hub.enqueue('A', n)
    expect(hub.deliveredBy('B', n.id, 'event')).toBe(false)
    expect(hub.deliveredBy('A', n.id, 'event')).toBe(true)
    expect(hub.deliveredBy('A', n.id, 'event')).toBe(false)
    expect(hub.list('A')).toMatchObject([{ id: n.id, delivery: 'delivered', via: 'event' }])
    expect(hub.lastDelivery('A')).toMatchObject({ state: 'delivered', via: 'event' })
    const waiting = hub.wait('A', 1)
    await clock.advance(1)
    expect(await waiting).toHaveLength(0)
    expect(hub.armed()).toBe(false)
  })
})

describe('the retry schedule, on a fake clock', () => {
  it('tries at once, then after 5 s, 30 s and 2 min, then marks it undelivered and stops', async () => {
    const attempts: number[] = []
    const { hub, clock } = rig({
      post: async () => {
        attempts.push(clock.now())
        return 503
      },
      settings: new Map([['A', { mode: 'webhook', url: 'https://hooks.example/x', secret: newWebhookSecret() }]]),
    })
    const start = clock.now()
    hub.enqueue('A', event())
    await flush()
    await clock.advance(10 * 60_000)
    expect(attempts.map((at) => at - start)).toEqual([
      0,
      RETRY_DELAYS_MS[0],
      RETRY_DELAYS_MS[0] + RETRY_DELAYS_MS[1],
      RETRY_DELAYS_MS[0] + RETRY_DELAYS_MS[1] + RETRY_DELAYS_MS[2],
    ])
    expect(RETRY_DELAYS_MS).toEqual([5_000, 30_000, 120_000])
    expect(hub.list('A')[0]).toMatchObject({ delivery: 'undelivered' })
    expect(hub.lastDelivery('A')).toMatchObject({ state: 'undelivered', outstanding: 1 })
    // No more timed attempts, and no timer left armed.
    expect(clock.pending()).toBe(0)
    // Still fetchable by the next wait.
    expect(await hub.wait('A', 1)).toHaveLength(1)
  })

  it('stops retrying the moment one attempt succeeds', async () => {
    let calls = 0
    const { hub, clock } = rig({
      post: async () => {
        calls += 1
        return calls < 2 ? 500 : 204
      },
      settings: new Map([['A', { mode: 'webhook', url: 'https://hooks.example/x', secret: newWebhookSecret() }]]),
    })
    hub.enqueue('A', event())
    await flush()
    await clock.advance(10 * 60_000)
    expect(calls).toBe(2)
    expect(hub.list('A')[0]).toMatchObject({ delivery: 'delivered', via: 'webhook' })
  })

  it('arms no timer at all when nothing is pending', async () => {
    const { hub, clock } = rig()
    expect(hub.armed()).toBe(false)
    hub.enqueue('A', event())
    // Nobody waiting: one retry armed — one timer, however many are queued.
    hub.enqueue('A', event())
    hub.enqueue('B', event())
    expect(clock.pending()).toBe(1)
    await hub.wait('A', 1)
    await hub.wait('B', 1)
    expect(hub.armed()).toBe(false)
  })
})

describe('keeping it across a restart', () => {
  it('loses nothing outstanding, and resumes a pending one’s schedule', async () => {
    const first = rig()
    const kept = event()
    const delivered = event()
    first.hub.enqueue('A', kept)
    first.hub.enqueue('B', delivered)
    await first.hub.wait('B', 1)
    first.hub.stop()
    expect(statSync(join(dir, NOTIFICATIONS_FILE)).mode & 0o777).toBe(0o600)

    const second = rig({ settings: first.settings })
    expect(second.hub.list('A').map((n) => n.id)).toEqual([kept.id])
    expect(second.hub.list('B')[0]).toMatchObject({ id: delivered.id, delivery: 'delivered' })
    // The pending one is still handed to the next wait.
    expect((await second.hub.wait('A', 1)).map((n) => n.id)).toEqual([kept.id])
    second.hub.stop()
  })

  it('takes one turn once, for any key, until it is older than anything kept', async () => {
    const first = rig()
    expect(first.hub.enqueue('A', event('s'), 'answer:1:abc')).toBe(true)
    expect(first.hub.enqueue('A', event('s'), 'answer:1:abc')).toBe(false)
    // Another app is never told a turn somebody was already told.
    expect(first.hub.enqueue('B', event('s'), 'answer:1:abc')).toBe(false)
    expect(first.hub.enqueue('A', event('s'), 'answer:2:def')).toBe(true)
    first.hub.ack('A', first.hub.list('A').map((n) => n.id))
    first.hub.stop()

    const second = rig({ settings: first.settings, clock: first.clock })
    expect(second.hub.enqueue('A', event('s'), 'answer:1:abc')).toBe(false)
    second.hub.stop()

    // Seven days on, the turn is forgotten with everything else that old.
    first.clock.at += MAX_AGE_MS + 1
    const third = rig({ settings: first.settings, clock: first.clock })
    expect(third.hub.enqueue('A', event('s', { at: first.clock.now() }), 'answer:1:abc')).toBe(true)
    third.hub.stop()
  })

  it('holds each key to its caps, oldest first', () => {
    const { hub, clock } = rig({ disk: false })
    for (let i = 0; i < MAX_PER_KEY + 5; i += 1) hub.enqueue('A', event('s', { at: clock.now() }))
    expect(hub.size('A')).toBe(MAX_PER_KEY)
    expect(hub.list('A')[0].id).not.toBe('n-1')
    const old = event('s', { at: clock.now() - MAX_AGE_MS - 1 })
    hub.enqueue('B', old)
    expect(hub.size('B')).toBe(0)
  })
})

describe('the webhook, for real, over HTTP', () => {
  let server: Server | null = null
  afterEach(async () => {
    await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()))
    server = null
  })

  async function receiver(status: number): Promise<{ url: string; got: Array<{ headers: IncomingMessage['headers']; body: string }> }> {
    const got: Array<{ headers: IncomingMessage['headers']; body: string }> = []
    server = createServer((req, res) => {
      let body = ''
      req.on('data', (chunk: Buffer) => (body += chunk.toString('utf8')))
      req.on('end', () => {
        got.push({ headers: req.headers, body })
        res.writeHead(status)
        res.end()
      })
    })
    await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve))
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}/hook`, got }
  }

  it('posts JSON signed so the receiver can verify it, and a 2xx is delivery', async () => {
    const { url, got } = await receiver(200)
    const secret = newWebhookSecret()
    const { hub, clock } = rig({
      post: fetchPost,
      settings: new Map([['A', { mode: 'webhook', url, secret }]]),
    })
    const n = event()
    hub.enqueue('A', n)
    for (let i = 0; i < 50 && got.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10))
    for (let i = 0; i < 50 && hub.list('A')[0]?.delivery !== 'delivered'; i += 1) await new Promise((resolve) => setTimeout(resolve, 10))
    expect(got).toHaveLength(1)
    const headers = Object.fromEntries(Object.entries(got[0].headers).map(([k, v]) => [k, String(v)]))
    // Verified against the hub's own clock, which signed it.
    expect(verifyWebhook(secret, headers, got[0].body, Math.floor(clock.now() / 1000))).toEqual({ ok: true })
    expect(JSON.parse(got[0].body)).toMatchObject({ id: n.id, type: 'finished', sessionId: n.sessionId })
    expect(headers['webhook-id']).toBe(n.id)
    expect(hub.list('A')[0]).toMatchObject({ delivery: 'delivered', via: 'webhook' })
  })

  it('a signature does not verify with another secret, a changed body, or an old timestamp', async () => {
    const { url, got } = await receiver(200)
    const secret = newWebhookSecret()
    const { hub } = rig({ post: fetchPost, settings: new Map([['A', { mode: 'webhook', url, secret }]]) })
    hub.enqueue('A', event())
    for (let i = 0; i < 50 && got.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10))
    const headers = Object.fromEntries(Object.entries(got[0].headers).map(([k, v]) => [k, String(v)]))
    const stamp = Number(headers['webhook-timestamp'])
    expect(verifyWebhook(secret, headers, got[0].body, stamp)).toEqual({ ok: true })
    expect(verifyWebhook(newWebhookSecret(), headers, got[0].body, stamp)).toEqual({ ok: false, why: 'mismatch' })
    expect(verifyWebhook(secret, headers, `${got[0].body} `, stamp)).toEqual({ ok: false, why: 'mismatch' })
    // A replay outside the five-minute window is refused before the MAC is even checked.
    expect(verifyWebhook(secret, headers, got[0].body, stamp + 301)).toEqual({ ok: false, why: 'stale' })
    expect(verifyWebhook(secret, { ...headers, 'webhook-signature': undefined }, got[0].body, stamp)).toEqual({
      ok: false,
      why: 'missing',
    })
  })

  it('the Settings test posts once, signed, keeps nothing, and says what the address answered', async () => {
    const { url, got } = await receiver(500)
    const secret = newWebhookSecret()
    const { hub } = rig({ post: fetchPost, settings: new Map([['A', { mode: 'webhook', url, secret }]]) })
    const result = await hub.testWebhook('A')
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/answered 500/)
    expect(got).toHaveLength(1)
    expect(hub.size()).toBe(0)
  })
})
