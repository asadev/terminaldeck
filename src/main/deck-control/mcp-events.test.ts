import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CallbackRefused, type CallbackAnswer } from './mcp-events-callback'
import {
  EVENTS_ERRORS,
  EVENTS_FILE,
  EventsError,
  MAX_SUBSCRIPTIONS_PER_KEY,
  MAX_TTL_MS,
  McpEvents,
  MIN_TTL_MS,
  ROTATION_GRACE_MS,
  SUBSCRIPTION_HEADER,
  subscriptionId,
} from './mcp-events'
import { NotificationHub, type HubClock, type NotificationEvent } from './notify-hub'
import { verifyWebhook } from './notify-webhook'

/**
 * MCP Events, held to OpenAI's guide and the draft it implements, on a clock the
 * test moves and a callback the test plays.
 *
 * The callback here is a function, not a socket: what is under test is the
 * subscription lifecycle, the signing and the retry schedule. The real poster's
 * address rules are `mcp-events-callback.test.ts`; the whole thing over a real
 * MCP connection and a real HTTP receiver is `mcp-events-server.test.ts`, and
 * through the relay is `src/main/remote/mcp-events-relay.test.ts`.
 */

class ManualClock implements HubClock {
  at = 1_800_000_000_000
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
  advance(ms: number): void {
    const target = this.at + ms
    for (;;) {
      const next = [...this.timers.entries()].filter(([, t]) => t.due <= target).sort((a, b) => a[1].due - b[1].due)[0]
      if (!next) break
      this.at = next[1].due
      this.timers.delete(next[0])
      next[1].run()
    }
    this.at = target
  }
}

interface Posted {
  url: string
  headers: Record<string, string>
  body: string
  at: number
}

/** Plays ChatGPT's receiver: echoes a verification, answers deliveries as told. */
class Receiver {
  posts: Posted[] = []
  /** Status for the next deliveries, in order; the last one repeats. */
  statuses: number[] = [200]
  verification: 'echo' | 'wrong' | number | 'unreachable' = 'echo'
  constructor(private readonly clock: ManualClock) {}
  post = async (url: string, headers: Record<string, string>, body: string): Promise<CallbackAnswer> => {
    this.posts.push({ url, headers, body, at: this.clock.now() })
    const parsed = JSON.parse(body) as { type?: string; challenge?: string }
    if (parsed.type === 'verification') {
      if (this.verification === 'unreachable') throw new CallbackRefused('connection_refused', 'connect ECONNREFUSED')
      if (typeof this.verification === 'number') return { status: this.verification, body: '' }
      const challenge = this.verification === 'echo' ? parsed.challenge : 'something else'
      return { status: 200, body: JSON.stringify({ challenge }) }
    }
    const status = this.statuses.length > 1 ? (this.statuses.shift() as number) : this.statuses[0]
    return { status, body: '' }
  }
  deliveries(): Posted[] {
    return this.posts.filter((post) => (JSON.parse(post.body) as { type?: string }).type !== 'verification')
  }
  verifications(): Posted[] {
    return this.posts.filter((post) => (JSON.parse(post.body) as { type?: string }).type === 'verification')
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

const SECRET = `whsec_${Buffer.alloc(32, 7).toString('base64')}`
const SECRET_2 = `whsec_${Buffer.alloc(32, 9).toString('base64')}`
const URL_A = 'https://callbacks.example.com/mcp/events'

function subscribeParams(extra: Record<string, unknown> = {}, delivery: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: 'session.turn_finished',
    arguments: {},
    delivery: { mode: 'webhook', url: URL_A, secret: SECRET, ...delivery },
    cursor: null,
    ...extra,
  }
}

function event(overrides: Partial<NotificationEvent> = {}): NotificationEvent {
  return {
    id: `n-${Math.random().toString(36).slice(2)}`,
    type: 'finished',
    sessionId: 'started-1',
    sessionName: 'api',
    at: 1_800_000_000_000,
    answer: { text: 'Done: the tests pass.', truncated: false },
    suggestedTool: 'sessions_send',
    note: 'The session finished its turn.',
    ...overrides,
  }
}

let dir = ''
let clock: ManualClock
let receiver: Receiver
let modes: Map<string, 'off' | 'wait' | 'webhook'>
let internet = true
let delivered: Array<[string, string]>
const open: McpEvents[] = []

function hub(
  options: {
    dir?: string | null
    owed?: (keyId: string, eventId: string) => boolean
    onDelivered?: (keyId: string, eventId: string) => void
  } = {},
): McpEvents {
  const events = new McpEvents({
    dir: options.dir === undefined ? null : options.dir,
    access: { mode: (keyId) => modes.get(keyId) ?? null, internet: () => internet },
    clock,
    post: receiver.post,
    onDelivered: (keyId, eventId) => {
      delivered.push([keyId, eventId])
      options.onDelivered?.(keyId, eventId)
    },
    ...(options.owed === undefined ? {} : { owed: options.owed }),
  })
  open.push(events)
  return events
}

async function refusal(work: Promise<unknown> | (() => unknown)): Promise<EventsError> {
  try {
    await (typeof work === 'function' ? work() : work)
  } catch (error) {
    if (error instanceof EventsError) return error
    throw error
  }
  throw new Error('expected a refusal')
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-mcp-events-'))
  clock = new ManualClock()
  receiver = new Receiver(clock)
  modes = new Map([
    ['key-a', 'wait'],
    ['key-b', 'wait'],
  ])
  internet = true
  delivered = []
})

afterEach(() => {
  for (const events of open.splice(0)) events.stop()
  rmSync(dir, { recursive: true, force: true })
})

describe('events/list', () => {
  it('offers the three kinds of news, webhook delivery, an optional session filter and the payload', () => {
    const { events } = hub().list()
    expect(events.map((entry) => entry.name)).toEqual(['session.turn_finished', 'session.needs_input', 'session.exited'])
    for (const entry of events) {
      expect(entry.delivery).toEqual(['webhook'])
      expect(entry.inputSchema).toMatchObject({ type: 'object', properties: { sessionId: { type: 'string' } } })
      expect(entry.payloadSchema).toMatchObject({ type: 'object', required: expect.arrayContaining(['sessionId', 'type']) })
      expect(typeof entry.description).toBe('string')
    }
  })
})

describe('events/subscribe: what is refused, with the draft’s codes', () => {
  it('refuses an unknown event, an unknown argument, another delivery mode, and a bad address or secret', async () => {
    const events = hub()
    const cases: Array<[Record<string, unknown>, number, Record<string, unknown> | undefined]> = [
      [subscribeParams({ name: 'session.deleted' }), EVENTS_ERRORS.notFound, { kind: 'event' }],
      [subscribeParams({ arguments: { project: '/work' } }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { mode: 'poll' }), EVENTS_ERRORS.unsupported, { feature: 'delivery', value: 'poll' }],
      [subscribeParams({}, { url: 'http://callbacks.example.com/x' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { url: 'https://127.0.0.1/x' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { url: 'https://192.168.1.10/x' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { url: 'https://printer.local/x' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { url: 'https://user:pw@callbacks.example.com/x' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { secret: 'not-a-secret' }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { secret: `whsec_${Buffer.alloc(8).toString('base64')}` }), EVENTS_ERRORS.invalidParams, undefined],
      [subscribeParams({}, { secret: `whsec_${Buffer.alloc(80).toString('base64')}` }), EVENTS_ERRORS.invalidParams, undefined],
    ]
    for (const [params, code, data] of cases) {
      const error = await refusal(events.subscribe('key-a', 'internet', params))
      expect(error.code, JSON.stringify(params)).toBe(code)
      if (data !== undefined) expect(error.data).toMatchObject(data)
    }
    expect(receiver.posts).toEqual([])
    expect(events.subscriptions()).toEqual([])
  })

  it('refuses an app whose owner set notifications to off, and a key that is gone', async () => {
    const events = hub()
    modes.set('key-a', 'off')
    const off = await refusal(events.subscribe('key-a', 'internet', subscribeParams()))
    expect(off.code).toBe(EVENTS_ERRORS.forbidden)
    expect(off.message).toMatch(/switched notifications off/)
    const gone = await refusal(events.subscribe('key-gone', 'internet', subscribeParams()))
    expect(gone.code).toBe(EVENTS_ERRORS.forbidden)
  })

  it('caps the subscriptions one app can hold', async () => {
    const events = hub()
    for (let i = 0; i < MAX_SUBSCRIPTIONS_PER_KEY; i += 1) {
      await events.subscribe('key-a', 'internet', subscribeParams({ arguments: { sessionId: `s-${i}` } }))
    }
    const full = await refusal(events.subscribe('key-a', 'internet', subscribeParams({ arguments: { sessionId: 'one-more' } })))
    expect(full.code).toBe(EVENTS_ERRORS.resourceExhausted)
    expect(full.data).toMatchObject({ limit: 'subscriptions', max: MAX_SUBSCRIPTIONS_PER_KEY })
    // Another app is not counted against this one.
    await expect(events.subscribe('key-b', 'internet', subscribeParams())).resolves.toMatchObject({ id: expect.any(String) })
  })
})

describe('events/subscribe: the callback is verified before anything is sent to it', () => {
  it('posts a signed challenge naming the subscription, and activates only on the echo', async () => {
    const events = hub()
    const result = await events.subscribe('key-a', 'internet', subscribeParams())
    expect(result).toEqual({
      id: subscriptionId('key-a', URL_A, 'session.turn_finished', null),
      refreshBefore: new Date(clock.now() + MAX_TTL_MS).toISOString(),
      cursor: null,
      truncated: false,
    })
    const [challenge] = receiver.verifications()
    expect(challenge.url).toBe(URL_A)
    expect(challenge.headers[SUBSCRIPTION_HEADER]).toBe(result.id)
    expect(challenge.headers['webhook-id']).toMatch(/^msg_verification_/)
    expect(verifyWebhook(SECRET, challenge.headers, challenge.body, Math.floor(clock.now() / 1000))).toEqual({ ok: true })
    expect(events.subscriptions('key-a')).toHaveLength(1)
  })

  it('refuses, and keeps nothing, when the echo is wrong, the answer is an error, or nothing answers', async () => {
    const events = hub()
    const reasons: Array<[Receiver['verification'], string]> = [
      ['wrong', 'challenge_failed'],
      [404, 'http_4xx'],
      [503, 'http_5xx'],
      ['unreachable', 'connection_refused'],
    ]
    for (const [verification, reason] of reasons) {
      receiver.verification = verification
      const error = await refusal(events.subscribe('key-a', 'internet', subscribeParams()))
      expect(error.code).toBe(EVENTS_ERRORS.callbackEndpoint)
      expect(error.data).toEqual({ reason })
    }
    expect(events.subscriptions()).toEqual([])
  })
})

describe('events/subscribe: an idempotent upsert with a lease', () => {
  it('answers the same id for the same subscription, verifying once, and a new id for a different one', async () => {
    const events = hub()
    const first = await events.subscribe('key-a', 'internet', subscribeParams())
    clock.advance(60_000)
    const again = await events.subscribe('key-a', 'internet', subscribeParams())
    expect(again.id).toBe(first.id)
    expect(Date.parse(again.refreshBefore)).toBe(clock.now() + MAX_TTL_MS)
    expect(receiver.verifications()).toHaveLength(1)
    const other = await events.subscribe('key-a', 'internet', subscribeParams({ name: 'session.needs_input' }))
    expect(other.id).not.toBe(first.id)
    // The same subscription made by another app is that app's own.
    const theirs = await events.subscribe('key-b', 'internet', subscribeParams())
    expect(theirs.id).not.toBe(first.id)
  })

  it('grants at most a day and at least a minute, and lets a lapsed lease go', async () => {
    const events = hub()
    const short = await events.subscribe('key-a', 'internet', subscribeParams({ ttlMs: 10 }))
    expect(Date.parse(short.refreshBefore)).toBe(clock.now() + MIN_TTL_MS)
    const forever = await events.subscribe('key-a', 'internet', subscribeParams({ name: 'session.exited', ttlMs: null }))
    expect(Date.parse(forever.refreshBefore)).toBe(clock.now() + MAX_TTL_MS)
    const three = await events.subscribe('key-a', 'internet', subscribeParams({ name: 'session.needs_input', ttlMs: 3 * 3600_000 }))
    expect(Date.parse(three.refreshBefore)).toBe(clock.now() + 3 * 3600_000)

    clock.advance(MIN_TTL_MS + 1)
    expect(events.offer('key-a', event())).toBe(0)
    expect(events.subscriptions('key-a').map((sub) => sub.event)).toEqual(['session.exited', 'session.needs_input'])
  })

  it('signs with the old and the new secret for a while after a refresh brings a new one', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    await events.subscribe('key-a', 'internet', subscribeParams({}, { secret: SECRET_2 }))
    events.offer('key-a', event())
    await settle()
    const [during] = receiver.deliveries()
    const stamp = Math.floor(clock.now() / 1000)
    expect(during.headers['webhook-signature'].split(' ')).toHaveLength(2)
    expect(verifyWebhook(SECRET, during.headers, during.body, stamp)).toEqual({ ok: true })
    expect(verifyWebhook(SECRET_2, during.headers, during.body, stamp)).toEqual({ ok: true })

    clock.advance(ROTATION_GRACE_MS + 1)
    events.offer('key-a', event())
    await settle()
    const after = receiver.deliveries()[1]
    expect(after.headers['webhook-signature'].split(' ')).toHaveLength(1)
    expect(verifyWebhook(SECRET_2, after.headers, after.body, Math.floor(clock.now() / 1000))).toEqual({ ok: true })
    expect(verifyWebhook(SECRET, after.headers, after.body, Math.floor(clock.now() / 1000))).toEqual({ ok: false, why: 'mismatch' })
  })
})

describe('delivery', () => {
  it('posts one signed event per post, in the draft’s shape, and tells the queue it was delivered', async () => {
    const events = hub()
    const sub = await events.subscribe('key-a', 'internet', subscribeParams())
    const news = event()
    expect(events.offer('key-a', news)).toBe(1)
    await settle()
    const [post] = receiver.deliveries()
    expect(JSON.parse(post.body)).toEqual({
      eventId: news.id,
      name: 'session.turn_finished',
      timestamp: new Date(news.at).toISOString(),
      data: news,
      cursor: null,
    })
    expect(post.headers['webhook-id']).toBe(news.id)
    expect(post.headers[SUBSCRIPTION_HEADER]).toBe(sub.id)
    expect(verifyWebhook(SECRET, post.headers, post.body, Math.floor(clock.now() / 1000))).toEqual({ ok: true })
    expect(delivered).toEqual([['key-a', news.id]])
    expect(events.owed()).toBe(0)
    expect(events.armed()).toBe(false)
  })

  it('sends each kind only to subscriptions for it, honours the session filter, and never crosses keys', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    await events.subscribe('key-a', 'internet', subscribeParams({ name: 'session.needs_input', arguments: { sessionId: 'started-2' } }))
    await events.subscribe('key-b', 'internet', subscribeParams({}, { url: 'https://other.example.com/cb' }))

    expect(events.offer('key-a', event({ type: 'needs-input', sessionId: 'started-1' }))).toBe(0)
    expect(events.offer('key-a', event({ type: 'needs-input', sessionId: 'started-2' }))).toBe(1)
    expect(events.offer('key-a', event({ type: 'exited' }))).toBe(0)
    expect(events.offer('key-a', event({ type: 'finished' }))).toBe(1)
    await settle()
    const urls = receiver.deliveries().map((post) => post.url)
    expect(urls).toEqual([URL_A, URL_A])
    expect(urls).not.toContain('https://other.example.com/cb')
  })

  it('tells only the chat that subscribed to the session, when one did, among chats sharing a key', async () => {
    const events = hub()
    const chatOne = 'https://callbacks.example.com/chat-one'
    const chatTwo = 'https://callbacks.example.com/chat-two'
    const catchAll = 'https://callbacks.example.com/chat-three'
    await events.subscribe('key-a', 'internet', subscribeParams({ arguments: { sessionId: 'started-1' } }, { url: chatOne }))
    await events.subscribe('key-a', 'internet', subscribeParams({ arguments: { sessionId: 'started-2' } }, { url: chatTwo }))
    await events.subscribe('key-a', 'internet', subscribeParams({}, { url: catchAll }))

    expect(events.offer('key-a', event({ sessionId: 'started-1' }))).toBe(1)
    expect(events.offer('key-a', event({ sessionId: 'started-2' }))).toBe(1)
    // A session no chat claimed goes to the catch-all.
    expect(events.offer('key-a', event({ sessionId: 'started-3' }))).toBe(1)
    await settle()
    expect(receiver.deliveries().map((post) => post.url)).toEqual([chatOne, chatTwo, catchAll])
  })

  it('does not post what the queue already delivered another way, before the first try or a retry', async () => {
    const owedIds = new Set<string>()
    const events = hub({ owed: (_keyId, eventId) => owedIds.has(eventId) })
    await events.subscribe('key-a', 'internet', subscribeParams())
    // Taken by a waiter before the push was offered: nothing is posted.
    events.offer('key-a', event())
    await settle()
    expect(receiver.deliveries()).toHaveLength(0)
    expect(events.owed()).toBe(0)

    // Taken by a waiter between the first try and the retry: the retry is not posted.
    receiver.statuses = [503]
    const news = event()
    owedIds.add(news.id)
    events.offer('key-a', news)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
    expect(events.owes('key-a', news.id)).toBe(true)
    owedIds.delete(news.id)
    clock.advance(5_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
    expect(events.owes('key-a', news.id)).toBe(false)
    expect(events.armed()).toBe(false)
  })

  it('wired to the queue, delivers each notification once: by the waiter, or by the push', async () => {
    let live: McpEvents | null = null
    const queue = new NotificationHub({
      dir: null,
      settings: () => ({ mode: 'wait', url: null, secret: null }),
      clock,
      pushing: (keyId, id) => live?.owes(keyId, id) === true,
    })
    const events = hub({
      owed: (keyId, eventId) => queue.owes(keyId, eventId),
      onDelivered: (keyId, eventId) => queue.deliveredBy(keyId, eventId, 'event'),
    })
    live = events
    const enqueue = (news: NotificationEvent): void => {
      if (queue.enqueue('key-a', news)) events.offer('key-a', news)
    }
    await events.subscribe('key-a', 'internet', subscribeParams())

    // A waiter already parked takes it; the push stands down.
    const parked = queue.wait('key-a', 30_000)
    const first = event()
    enqueue(first)
    expect((await parked).map((n) => n.id)).toEqual([first.id])
    await settle()
    expect(receiver.deliveries()).toHaveLength(0)

    // Nobody waiting: the push is tried, and a waiter arriving while it is
    // still being retried is not handed it as well.
    receiver.statuses = [503, 200]
    const second = event()
    enqueue(second)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
    const late = queue.wait('key-a', 60_000)
    clock.advance(5_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(2)
    expect(queue.list('key-a').find((n) => n.id === second.id)).toMatchObject({ delivery: 'delivered', via: 'event' })
    clock.advance(60_000)
    expect(await late).toEqual([])
    queue.stop()
  })

  it('posts an event once even if it is offered twice', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    const news = event()
    events.offer('key-a', news)
    events.offer('key-a', news)
    await settle()
    events.offer('key-a', news)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
  })

  it('retries at once, then after 5 s, 30 s and 2 min, then gives up with no timer left', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    receiver.statuses = [500]
    const start = clock.now()
    events.offer('key-a', event())
    await settle()
    for (const step of [5_000, 30_000, 120_000]) {
      clock.advance(step)
      await settle()
    }
    clock.advance(600_000)
    await settle()
    expect(receiver.deliveries().map((post) => post.at - start)).toEqual([0, 5_000, 35_000, 155_000])
    expect(events.owed()).toBe(0)
    expect(events.armed()).toBe(false)
    expect(delivered).toEqual([])
    expect(events.subscriptions('key-a')[0].lastDelivery).toMatchObject({ ok: false, error: expect.stringMatching(/gave up after 4 tries/) })
  })

  it('stops retrying once one lands', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    receiver.statuses = [503, 429, 200]
    events.offer('key-a', event())
    await settle()
    clock.advance(5_000)
    await settle()
    clock.advance(30_000)
    await settle()
    clock.advance(600_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(3)
    expect(delivered).toHaveLength(1)
    expect(events.armed()).toBe(false)
  })

  it('ends the subscription on 410 and never retries a 413', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    receiver.statuses = [413]
    events.offer('key-a', event())
    await settle()
    clock.advance(600_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
    expect(events.subscriptions('key-a')).toHaveLength(1)

    receiver.statuses = [410]
    events.offer('key-a', event())
    await settle()
    clock.advance(600_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(2)
    expect(events.subscriptions('key-a')).toEqual([])
  })
})

describe('access, rechecked on every delivery', () => {
  it('stops pushing through the internet while internet reach is off, and resumes when it is back', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    internet = false
    expect(events.offer('key-a', event())).toBe(0)
    internet = true
    expect(events.offer('key-a', event())).toBe(1)
  })

  it('a subscription made on this Mac does not depend on internet reach', async () => {
    const events = hub()
    await events.subscribe('key-a', 'this-mac', subscribeParams())
    internet = false
    expect(events.offer('key-a', event())).toBe(1)
  })

  it('drops what belongs to a key set to off or revoked, and a delivery owed to it', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    await events.subscribe('key-b', 'internet', subscribeParams())
    receiver.statuses = [500]
    events.offer('key-a', event())
    await settle()
    expect(events.owed()).toBe(1)
    modes.set('key-a', 'off')
    modes.delete('key-b')
    events.reconcile()
    expect(events.subscriptions()).toEqual([])
    expect(events.owed()).toBe(0)
    clock.advance(600_000)
    await settle()
    expect(receiver.deliveries()).toHaveLength(1)
  })

  it('lets the owner stop one subscription, and only the key’s own', async () => {
    const events = hub()
    const sub = await events.subscribe('key-a', 'internet', subscribeParams())
    expect(events.stopSubscription('key-b', sub.id)).toBe(false)
    expect(events.stopSubscription('key-a', sub.id)).toBe(true)
    expect(events.subscriptions()).toEqual([])
  })
})

describe('events/unsubscribe', () => {
  it('finds the subscription by the same four things, and answers {} every time', async () => {
    const events = hub()
    await events.subscribe('key-a', 'internet', subscribeParams())
    const params = { name: 'session.turn_finished', arguments: {}, delivery: { url: URL_A } }
    // Another app cannot unsubscribe this one: its id is not this key's.
    expect(events.unsubscribe('key-b', params)).toEqual({})
    expect(events.subscriptions('key-a')).toHaveLength(1)
    expect(events.unsubscribe('key-a', params)).toEqual({})
    expect(events.unsubscribe('key-a', params)).toEqual({})
    expect(events.subscriptions()).toEqual([])
  })
})

describe('kept across a restart', () => {
  it('keeps subscriptions and an owed delivery in a 0600 file, and delivers it after the restart', async () => {
    const first = hub({ dir })
    await first.subscribe('key-a', 'internet', subscribeParams())
    receiver.statuses = [500, 200]
    const news = event()
    first.offer('key-a', news)
    await settle()
    first.stop()

    expect(statSync(join(dir, EVENTS_FILE)).mode & 0o777).toBe(0o600)
    const second = hub({ dir })
    expect(second.subscriptions('key-a')).toHaveLength(1)
    expect(second.owed()).toBe(1)
    clock.advance(5_000)
    await settle()
    expect(receiver.deliveries().map((post) => post.headers['webhook-id'])).toEqual([news.id, news.id])
    expect(delivered).toEqual([['key-a', news.id]])
    expect(second.owed()).toBe(0)
  })
})
