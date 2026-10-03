/**
 * MCP Events: a true push to an AI app that subscribes, which today means ChatGPT.
 *
 * ## What this is
 *
 * The MCP Events extension (the Triggers & Events working group's draft, which
 * ChatGPT ships at protocol revision 2026-07-28) lets a client *subscribe* to
 * things that happen on a server. The client hands over a callback address and
 * a signing secret in `events/subscribe`; the server posts each matching event
 * to that address, signed the Standard Webhooks way, and the client — ChatGPT —
 * wakes the chat that subscribed and does what its user asked for. That is the
 * push the owner asked for: the app is told, it does not ask.
 *
 * Three events, one per kind of news `notify-detect.ts` already produces:
 *
 *  - `session.turn_finished` — a session finished a turn, with the answer;
 *  - `session.needs_input` — it stopped to ask something;
 *  - `session.exited` — it exited or crashed.
 *
 * Each takes one optional argument, `sessionId`, to watch one session instead
 * of all of them. Whose news it is was settled before it got here: an event is
 * offered only for the key `notify-detect.ts` chose, and only to that key's own
 * subscriptions. One app never receives another app's events, exactly as one
 * key's `notifications_list` never shows another key's notifications.
 *
 * ## The rules this follows
 *
 * From OpenAI's MCP Events guide and the draft it implements:
 *
 *  - **Subscribe is an idempotent upsert.** The id is a hash of (key, callback,
 *    event, arguments), so the same subscription refreshed is the same id, and
 *    `events/unsubscribe` finds it without being given one.
 *  - **The callback is verified before anything is sent to it**: a signed
 *    `{"type":"verification","challenge":…}` post, answered 2xx with the same
 *    challenge echoed back, compared in constant time.
 *  - **The secret is `whsec_` + base64 of 24–64 bytes**, and anything else is
 *    refused as invalid. A refresh that brings a new secret signs with both for
 *    a short while, space-separated, so a delivery in flight still verifies.
 *  - **Leases are short.** At most a day, at least a minute, never "forever":
 *    ChatGPT refreshes before `refreshBefore`, and a subscription it forgot
 *    simply lapses instead of posting to it for ever.
 *  - **One event per post**, at most 256 KiB, `webhook-id` the event's id,
 *    `X-MCP-Subscription-Id` the subscription's.
 *  - **2xx is delivered; 410 ends the subscription; 413 is never retried**;
 *    anything else — 429, 5xx, a timeout, a refused connection — is retried
 *    on the same schedule as every other notification: at once, then 5 s, 30 s
 *    and 2 min, then given up. A given-up event is still in
 *    `notifications_list`, because it was queued there first.
 *  - **Access is rechecked on every delivery**: a revoked key, a key whose
 *    owner set "Notify this app" to Off, and — for a subscription made through
 *    the internet — internet reach switched off, all stop deliveries at once.
 *
 * ## What is kept
 *
 * `<userData>/remote/mcp-events.json`, 0600, atomic, through `secret-file.ts`,
 * because it holds the subscribers' signing secrets and events that carry what
 * agents said. Subscriptions and deliveries still owed survive a restart; a
 * lapsed subscription is dropped when it is next looked at.
 *
 * ## The timer
 *
 * One, like the notification queue's: armed for the earliest delivery due and
 * not at all when nothing is owed.
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import { CallbackRefused, callbackUrlProblem, publicHttpsPost, type CallbackPost } from './mcp-events-callback'
import { REAL_CLOCK, RETRY_DELAYS_MS, type HubClock, type NotificationEvent, type NotificationType } from './notify-hub'
import { SECRET_PREFIX, signWebhook } from './notify-webhook'

/* -------------------------------------------------------------- constants -- */

export const EVENTS_FILE = 'mcp-events.json'

/** The header that names the subscription a delivery is for. */
export const SUBSCRIPTION_HEADER = 'X-MCP-Subscription-Id'

/** More than one app could reasonably want, few enough that nobody can fill a disk. */
export const MAX_SUBSCRIPTIONS_PER_KEY = 10

/** A lease asked for with no length, or for "no expiry", gets this — the longest given. */
export const MAX_TTL_MS = 24 * 60 * 60 * 1000

/** Shorter asks are rounded up to this, so a misconfigured client does not hammer. */
export const MIN_TTL_MS = 60 * 1000

/** How long an old secret keeps signing after a refresh brought a new one. */
export const ROTATION_GRACE_MS = 5 * 60 * 1000

/** The spec's ceiling on one delivery's body. */
export const MAX_EVENT_BODY_BYTES = 262_144

/** Delivered events, deduplicated against, per subscription. */
const SEEN_PER_SUBSCRIPTION = 200

/** The three events, and which kind of notification each one is. */
export const EVENT_NAMES: Record<NotificationType, string> = {
  finished: 'session.turn_finished',
  'needs-input': 'session.needs_input',
  exited: 'session.exited',
}

/** JSON-RPC codes the draft assigns. */
export const EVENTS_ERRORS = {
  invalidParams: -32602,
  notFound: -32011,
  forbidden: -32012,
  resourceExhausted: -32013,
  unsupported: -32014,
  callbackEndpoint: -32015,
} as const

/* ------------------------------------------------------------------ types -- */

/** A refusal, in the shape the server turns into a JSON-RPC error. */
export class EventsError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: Record<string, unknown>,
  ) {
    super(message)
    this.name = 'EventsError'
  }
}

/** How a key may be reached, read on every subscribe and every delivery. */
export interface EventsAccess {
  /** The key's "Notify this app" setting, or null when the key no longer exists. */
  mode(keyId: string): 'off' | 'wait' | 'webhook' | null
  /** Is internet reach on? */
  internet(): boolean
}

export type EventsVia = 'this-mac' | 'internet'

export interface McpEventsOptions {
  /** `<userData>/remote`. Null keeps everything in memory, for tests. */
  dir: string | null
  access: EventsAccess
  clock?: HubClock
  post?: CallbackPost
  /** An event reached its subscriber: the queue records it as delivered. */
  onDelivered?(keyId: string, eventId: string): void
  /** Anything a Settings page would redraw for. */
  onChange?(): void
}

interface Secret {
  value: string
  /** Epoch ms after which this one stops signing; null for the current one. */
  until: number | null
}

interface Subscription {
  id: string
  keyId: string
  via: EventsVia
  name: string
  sessionId: string | null
  url: string
  secrets: Secret[]
  createdAt: number
  refreshBefore: number
  lastDelivery: { at: number; ok: boolean; error: string | null } | null
  /** Event ids already delivered here, newest last, so a retry storm posts each once. */
  seen: string[]
}

interface Outgoing {
  subscriptionId: string
  eventId: string
  body: string
  attempts: number
  nextAt: number | null
}

/** One subscription as Settings shows it. No secret, no full address. */
export interface SubscriptionView {
  id: string
  keyId: string
  event: string
  host: string
  sessionId: string | null
  refreshBefore: number
  lastDelivery: { at: number; ok: boolean; error: string | null } | null
}

/** What `events/subscribe` answers. */
export interface SubscribeResult {
  id: string
  refreshBefore: string
  cursor: null
  truncated: false
}

/* ------------------------------------------------------------- catalogue -- */

const PAYLOAD_SCHEMA = {
  type: 'object',
  description: 'One notification about one session, the same object notifications_list returns.',
  properties: {
    id: { type: 'string', description: 'Stable id; also the delivery’s webhook-id.' },
    type: { type: 'string', enum: ['finished', 'needs-input', 'exited'] },
    sessionId: { type: 'string', description: 'Pass to sessions_send, sessions_keys, sessions_screen or sessions_result.' },
    sessionName: { type: 'string' },
    at: { type: 'number', description: 'Epoch milliseconds.' },
    answer: {
      type: 'object',
      description: 'finished: the newest thing the agent said, capped at 2,000 characters.',
      properties: { text: { type: 'string' }, truncated: { type: 'boolean' } },
    },
    screen: {
      type: 'object',
      description: 'needs-input (or finished with no transcript): the last lines of the screen.',
      properties: { text: { type: 'string' }, truncated: { type: 'boolean' } },
    },
    exitCode: { type: 'number' },
    crashed: { type: 'boolean' },
    suggestedTool: { type: 'string', description: 'The tool most likely wanted next.' },
    note: { type: 'string', description: 'One sentence of fact about what happened.' },
  },
  required: ['id', 'type', 'sessionId', 'sessionName', 'at', 'suggestedTool', 'note'],
} as const

const INPUT_SCHEMA = {
  type: 'object',
  properties: {
    sessionId: {
      type: 'string',
      description: 'Only this session. Leave it out for every session this app started or sent a message to.',
    },
  },
  additionalProperties: false,
} as const

const DESCRIPTIONS: Record<NotificationType, string> = {
  finished:
    'A coding session this app started, or sent the last message to, finished its turn. Carries the agent’s answer.',
  'needs-input':
    'A coding session this app started, or sent the last message to, stopped to ask something: a permission prompt, a menu or a question. Answer it with sessions_keys or sessions_send.',
  exited: 'A coding session this app started exited, or crashed.',
}

export function eventCatalogue(): Array<Record<string, unknown>> {
  return (Object.keys(EVENT_NAMES) as NotificationType[]).map((type) => ({
    name: EVENT_NAMES[type],
    description: DESCRIPTIONS[type],
    delivery: ['webhook'],
    inputSchema: INPUT_SCHEMA,
    payloadSchema: PAYLOAD_SCHEMA,
  }))
}

const TYPE_OF_NAME = new Map<string, NotificationType>(
  (Object.entries(EVENT_NAMES) as Array<[NotificationType, string]>).map(([type, name]) => [name, type]),
)

/* ---------------------------------------------------------------- checks -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function invalid(message: string): EventsError {
  return new EventsError(EVENTS_ERRORS.invalidParams, message)
}

/** The event name and its one optional argument, or a refusal. */
function eventAndArguments(params: Record<string, unknown>): { name: string; sessionId: string | null } {
  const name = params.name
  if (typeof name !== 'string' || name === '') throw invalid('name is required.')
  if (!TYPE_OF_NAME.has(name)) {
    throw new EventsError(EVENTS_ERRORS.notFound, `There is no event called ${name.slice(0, 80)}.`, { kind: 'event' })
  }
  const args = params.arguments === undefined || params.arguments === null ? {} : record(params.arguments)
  if (args === null) throw invalid('arguments has to be an object.')
  for (const key of Object.keys(args)) {
    if (key !== 'sessionId') throw invalid(`Unknown argument ${key.slice(0, 40)}. The only one is sessionId.`)
  }
  if (args.sessionId === undefined) return { name, sessionId: null }
  if (typeof args.sessionId !== 'string' || args.sessionId === '' || args.sessionId.length > 200) {
    throw invalid('sessionId has to be a session id.')
  }
  return { name, sessionId: args.sessionId }
}

/** `whsec_` + base64 of 24–64 bytes, or a refusal. */
export function secretProblem(secret: unknown): string | null {
  if (typeof secret !== 'string' || !secret.startsWith(SECRET_PREFIX)) {
    return `The signing secret has to start with ${SECRET_PREFIX}.`
  }
  const encoded = secret.slice(SECRET_PREFIX.length)
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length % 4 !== 0) {
    return 'The signing secret is not base64.'
  }
  const bytes = Buffer.from(encoded, 'base64').length
  if (bytes < 24 || bytes > 64) return 'The signing secret has to be 24 to 64 bytes.'
  return null
}

/** The draft's deterministic id: a hash over who, where, what and which. */
export function subscriptionId(keyId: string, url: string, name: string, sessionId: string | null): string {
  const canonical = JSON.stringify([keyId, url, name, sessionId === null ? {} : { sessionId }])
  return `sub_${createHash('sha256').update(canonical).digest('base64url').slice(0, 32)}`
}

function hostOf(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return url
  }
}

/* ------------------------------------------------------------------- hub -- */

export class McpEvents {
  private subs = new Map<string, Subscription>()
  private outbox: Outgoing[] = []
  private readonly clock: HubClock
  private readonly post: CallbackPost
  private readonly posting = new Set<Outgoing>()
  private readonly verifying = new Map<string, Promise<void>>()
  private timer: unknown = null
  private timerAt: number | null = null
  private saveQueued = false
  private stopped = false

  constructor(private readonly options: McpEventsOptions) {
    this.clock = options.clock ?? REAL_CLOCK
    this.post = options.post ?? publicHttpsPost
    this.load()
    this.expire()
    this.arm()
  }

  /* --------------------------------------------------- the three methods -- */

  /** `events/list`. The same three for every key. */
  list(): { events: Array<Record<string, unknown>> } {
    return { events: eventCatalogue() }
  }

  /** `events/subscribe`: validate, verify the callback once, then upsert. */
  async subscribe(keyId: string, via: EventsVia, raw: unknown): Promise<SubscribeResult> {
    if (this.stopped) throw new EventsError(EVENTS_ERRORS.forbidden, 'The app is shutting down.')
    const params = record(raw)
    if (params === null) throw invalid('params has to be an object.')
    const { name, sessionId } = eventAndArguments(params)

    const delivery = record(params.delivery)
    if (delivery === null) throw invalid('delivery is required.')
    if (delivery.mode !== 'webhook') {
      throw new EventsError(EVENTS_ERRORS.unsupported, 'Only webhook delivery is offered.', {
        feature: 'delivery',
        value: typeof delivery.mode === 'string' ? delivery.mode.slice(0, 40) : null,
      })
    }
    if (typeof delivery.url !== 'string') throw invalid('delivery.url is required.')
    const url = delivery.url
    const urlProblem = callbackUrlProblem(url)
    if (urlProblem !== null) throw invalid(urlProblem)
    const problem = secretProblem(delivery.secret)
    if (problem !== null) throw invalid(problem)
    const secret = delivery.secret as string

    const mode = this.options.access.mode(keyId)
    if (mode === null) throw new EventsError(EVENTS_ERRORS.forbidden, 'This access key no longer exists.')
    if (mode === 'off') {
      throw new EventsError(
        EVENTS_ERRORS.forbidden,
        'The owner switched notifications off for this app. They can turn them back on in Settings, under Connect an AI app.',
      )
    }

    const ttl = params.ttlMs
    const lease =
      typeof ttl === 'number' && Number.isFinite(ttl) ? Math.min(Math.max(ttl, MIN_TTL_MS), MAX_TTL_MS) : MAX_TTL_MS
    const id = subscriptionId(keyId, url, name, sessionId)
    const now = this.clock.now()

    const existing = this.subs.get(id)
    if (existing) {
      // A refresh: the lease moves, and a new secret takes over with the old one
      // still signing for a little while.
      existing.refreshBefore = now + lease
      if (existing.secrets[0]?.value !== secret) {
        existing.secrets = [
          { value: secret, until: null },
          ...existing.secrets.slice(0, 1).map((old) => ({ value: old.value, until: now + ROTATION_GRACE_MS })),
        ]
      }
      existing.via = via
      this.changed()
      return this.answer(existing)
    }

    const count = [...this.subs.values()].filter((sub) => sub.keyId === keyId).length
    if (count >= MAX_SUBSCRIPTIONS_PER_KEY) {
      throw new EventsError(
        EVENTS_ERRORS.resourceExhausted,
        `This app already has ${MAX_SUBSCRIPTIONS_PER_KEY} subscriptions. Unsubscribe from one first.`,
        { limit: 'subscriptions', max: MAX_SUBSCRIPTIONS_PER_KEY },
      )
    }

    // Two identical subscribes at once verify once.
    let verifying = this.verifying.get(id)
    if (!verifying) {
      verifying = this.verify(id, url, secret).finally(() => this.verifying.delete(id))
      this.verifying.set(id, verifying)
    }
    await verifying
    if (this.stopped) throw new EventsError(EVENTS_ERRORS.forbidden, 'The app is shutting down.')

    const already = this.subs.get(id)
    if (already) return this.answer(already)
    const sub: Subscription = {
      id,
      keyId,
      via,
      name,
      sessionId,
      url,
      secrets: [{ value: secret, until: null }],
      createdAt: now,
      refreshBefore: now + lease,
      lastDelivery: null,
      seen: [],
    }
    this.subs.set(id, sub)
    this.changed()
    return this.answer(sub)
  }

  /** `events/unsubscribe`: found by the same four things, idempotent, `{}` either way. */
  unsubscribe(keyId: string, raw: unknown): Record<string, never> {
    const params = record(raw)
    if (params === null) throw invalid('params has to be an object.')
    const { name, sessionId } = eventAndArguments(params)
    const delivery = record(params.delivery)
    if (delivery === null || typeof delivery.url !== 'string') throw invalid('delivery.url is required.')
    this.remove(subscriptionId(keyId, delivery.url, name, sessionId))
    return {}
  }

  /* ---------------------------------------------------------------- in -- */

  /**
   * A notification was queued for this key: post it to every subscription of
   * the key's that wants it.
   */
  offer(keyId: string, event: NotificationEvent): number {
    if (this.stopped) return 0
    this.expire()
    const name = EVENT_NAMES[event.type]
    let offered = 0
    for (const sub of this.subs.values()) {
      if (sub.keyId !== keyId || sub.name !== name) continue
      if (sub.sessionId !== null && sub.sessionId !== event.sessionId) continue
      if (!this.allowed(sub)) continue
      if (sub.seen.includes(event.id)) continue
      if (this.outbox.some((item) => item.subscriptionId === sub.id && item.eventId === event.id)) continue
      const body = JSON.stringify({
        eventId: event.id,
        name,
        timestamp: new Date(event.at).toISOString(),
        data: event,
        cursor: null,
      })
      if (Buffer.byteLength(body) > MAX_EVENT_BODY_BYTES) continue
      this.outbox.push({ subscriptionId: sub.id, eventId: event.id, body, attempts: 0, nextAt: this.clock.now() })
      offered += 1
    }
    if (offered > 0) {
      this.attempt()
      this.save()
    }
    return offered
  }

  /* ------------------------------------------------------------ owner -- */

  /** Every live subscription, for Settings. */
  subscriptions(keyId?: string): SubscriptionView[] {
    this.expire()
    return [...this.subs.values()]
      .filter((sub) => keyId === undefined || sub.keyId === keyId)
      .map((sub) => ({
        id: sub.id,
        keyId: sub.keyId,
        event: sub.name,
        host: hostOf(sub.url),
        sessionId: sub.sessionId,
        refreshBefore: sub.refreshBefore,
        lastDelivery: sub.lastDelivery,
      }))
  }

  /** The owner's Stop button. True when there was one to stop. */
  stopSubscription(keyId: string, id: string): boolean {
    const sub = this.subs.get(id)
    if (!sub || sub.keyId !== keyId) return false
    this.remove(id)
    return true
  }

  /** Keys changed in Settings: drop what belongs to a key that is gone or set to off. */
  reconcile(): void {
    let changed = false
    for (const sub of [...this.subs.values()]) {
      const mode = this.options.access.mode(sub.keyId)
      if (mode === null || mode === 'off') {
        this.drop(sub.id)
        changed = true
      }
    }
    if (changed) this.changed()
  }

  stop(): void {
    this.stopped = true
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = null
    if (this.saveQueued) this.flush()
  }

  /** Is the one timer armed? For the test that says nothing owed costs nothing. */
  armed(): boolean {
    return this.timer !== null
  }

  /** Deliveries still owed. For the tests and the status line. */
  owed(): number {
    return this.outbox.length
  }

  /* ------------------------------------------------------------ verify -- */

  private async verify(id: string, url: string, secret: string): Promise<void> {
    const challenge = randomBytes(24).toString('base64url')
    const body = JSON.stringify({ type: 'verification', challenge })
    const messageId = `msg_verification_${randomBytes(12).toString('base64url')}`
    const headers = this.signed([{ value: secret, until: null }], messageId, body, id)
    let answer: { status: number; body: string }
    try {
      answer = await this.post(url, headers, body)
    } catch (error) {
      const refused = error instanceof CallbackRefused ? error : null
      if (refused?.reason === 'not_public') throw invalid(refused.message)
      throw new EventsError(EVENTS_ERRORS.callbackEndpoint, 'The callback could not be reached to verify it.', {
        reason: refused?.reason ?? 'connection_refused',
      })
    }
    if (answer.status < 200 || answer.status >= 300) {
      throw new EventsError(EVENTS_ERRORS.callbackEndpoint, `The callback answered ${answer.status} to verification.`, {
        reason: answer.status >= 500 ? 'http_5xx' : 'http_4xx',
      })
    }
    let echoed: unknown = null
    try {
      echoed = (JSON.parse(answer.body) as { challenge?: unknown }).challenge
    } catch {
      echoed = null
    }
    const expected = Buffer.from(challenge)
    const got = Buffer.from(typeof echoed === 'string' ? echoed : '')
    if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
      throw new EventsError(EVENTS_ERRORS.callbackEndpoint, 'The callback did not echo the verification challenge.', {
        reason: 'challenge_failed',
      })
    }
  }

  /* ---------------------------------------------------------- delivery -- */

  private attempt(): void {
    if (this.stopped) return
    const now = this.clock.now()
    for (const item of [...this.outbox]) {
      if (item.nextAt === null || item.nextAt > now || this.posting.has(item)) continue
      const sub = this.subs.get(item.subscriptionId)
      if (!sub || sub.refreshBefore <= now || !this.allowed(sub)) {
        this.discard(item)
        continue
      }
      this.postOne(item, sub)
    }
    this.arm()
  }

  private postOne(item: Outgoing, sub: Subscription): void {
    this.posting.add(item)
    item.attempts += 1
    const headers = this.signed(sub.secrets, item.eventId, item.body, sub.id)
    void this.post(sub.url, headers, item.body)
      .then(
        (answer) => answer.status,
        (error: unknown) => (error instanceof Error ? error.message : String(error)),
      )
      .then((outcome) => {
        this.posting.delete(item)
        if (this.stopped || !this.outbox.includes(item)) return
        const live = this.subs.get(sub.id)
        if (typeof outcome === 'number' && outcome >= 200 && outcome < 300) {
          this.discard(item)
          if (live) {
            live.lastDelivery = { at: this.clock.now(), ok: true, error: null }
            live.seen = [...live.seen, item.eventId].slice(-SEEN_PER_SUBSCRIPTION)
          }
          try {
            this.options.onDelivered?.(sub.keyId, item.eventId)
          } catch (error) {
            console.error('[mcp-events] the delivered listener threw:', error)
          }
        } else if (outcome === 410) {
          // The subscriber says this subscription is gone: so is everything owed to it.
          this.drop(sub.id)
        } else if (outcome === 413) {
          this.discard(item)
          if (live) live.lastDelivery = { at: this.clock.now(), ok: false, error: 'the callback refused the size (413)' }
        } else {
          const why = typeof outcome === 'number' ? `the callback answered ${outcome}` : outcome
          const retry = RETRY_DELAYS_MS[item.attempts - 1]
          if (retry === undefined) {
            this.discard(item)
            if (live) live.lastDelivery = { at: this.clock.now(), ok: false, error: `${why}; gave up after ${item.attempts} tries` }
          } else {
            item.nextAt = this.clock.now() + retry
            if (live) live.lastDelivery = { at: this.clock.now(), ok: false, error: why }
          }
        }
        this.changed()
        this.arm()
      })
  }

  /** Standard Webhooks headers, one signature per secret still signing, plus the subscription id. */
  private signed(secrets: Secret[], messageId: string, body: string, subscription: string): Record<string, string> {
    const timestamp = Math.floor(this.clock.now() / 1000)
    const now = this.clock.now()
    const live = secrets.filter((secret) => secret.until === null || secret.until > now)
    return {
      'webhook-id': messageId,
      'webhook-timestamp': String(timestamp),
      'webhook-signature': live.map((secret) => signWebhook(secret.value, messageId, timestamp, body)).join(' '),
      [SUBSCRIPTION_HEADER]: subscription,
    }
  }

  /** Is the subscription's key still allowed to be told, the way it subscribed? */
  private allowed(sub: Subscription): boolean {
    const mode = this.options.access.mode(sub.keyId)
    if (mode === null || mode === 'off') return false
    return sub.via !== 'internet' || this.options.access.internet()
  }

  private answer(sub: Subscription): SubscribeResult {
    return { id: sub.id, refreshBefore: new Date(sub.refreshBefore).toISOString(), cursor: null, truncated: false }
  }

  /* ------------------------------------------------------------ keeping -- */

  private discard(item: Outgoing): void {
    this.outbox = this.outbox.filter((other) => other !== item)
    this.save()
  }

  private drop(id: string): void {
    this.subs.delete(id)
    this.outbox = this.outbox.filter((item) => item.subscriptionId !== id)
    this.save()
  }

  private remove(id: string): void {
    if (!this.subs.has(id)) return
    this.drop(id)
    this.changed()
  }

  /** Lapsed leases and secrets past their grace are let go. */
  private expire(): void {
    const now = this.clock.now()
    let changed = false
    for (const sub of [...this.subs.values()]) {
      if (sub.refreshBefore <= now) {
        this.drop(sub.id)
        changed = true
        continue
      }
      const kept = sub.secrets.filter((secret) => secret.until === null || secret.until > now)
      if (kept.length !== sub.secrets.length) {
        sub.secrets = kept
        this.save()
      }
    }
    if (changed) this.changed()
  }

  private arm(): void {
    if (this.stopped) return
    let next: number | null = null
    for (const item of this.outbox) {
      if (item.nextAt === null || this.posting.has(item)) continue
      if (next === null || item.nextAt < next) next = item.nextAt
    }
    if (next === this.timerAt) return
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = next
    if (next === null) return
    this.timer = this.clock.setTimeout(() => {
      this.timer = null
      this.timerAt = null
      this.attempt()
    }, Math.max(next - this.clock.now(), 0))
  }

  private changed(): void {
    this.save()
    try {
      this.options.onChange?.()
    } catch (error) {
      console.error('[mcp-events] a change listener threw:', error)
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, EVENTS_FILE)
  }

  private save(): void {
    if (this.file() === null || this.saveQueued) return
    this.saveQueued = true
    queueMicrotask(() => this.flush())
  }

  private flush(): void {
    this.saveQueued = false
    const file = this.file()
    if (file === null || this.options.dir === null) return
    try {
      const state = { v: 1, subscriptions: [...this.subs.values()], outbox: this.outbox }
      writeSecretFile(this.options.dir, file, `${JSON.stringify(state)}\n`)
    } catch (error) {
      console.error('[mcp-events] could not save the subscriptions:', error)
    }
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as { v?: unknown; subscriptions?: unknown; outbox?: unknown }
      if (raw.v !== 1 || !Array.isArray(raw.subscriptions)) return
      for (const sub of raw.subscriptions.filter(isSubscription)) this.subs.set(sub.id, sub)
      const outbox = Array.isArray(raw.outbox) ? raw.outbox.filter(isOutgoing) : []
      // A post that was in the air when the app stopped is tried again, not lost.
      this.outbox = outbox
        .filter((item) => this.subs.has(item.subscriptionId))
        .map((item) => (item.nextAt === null ? { ...item, nextAt: this.clock.now() } : item))
    } catch (error) {
      console.error('[mcp-events] could not read the subscriptions; starting with none:', error)
      this.subs.clear()
      this.outbox = []
    }
  }
}

function isSubscription(value: unknown): value is Subscription {
  const sub = record(value)
  return (
    sub !== null &&
    typeof sub.id === 'string' &&
    typeof sub.keyId === 'string' &&
    (sub.via === 'this-mac' || sub.via === 'internet') &&
    typeof sub.name === 'string' &&
    TYPE_OF_NAME.has(sub.name) &&
    (sub.sessionId === null || typeof sub.sessionId === 'string') &&
    typeof sub.url === 'string' &&
    Array.isArray(sub.secrets) &&
    sub.secrets.every((secret) => typeof record(secret)?.value === 'string') &&
    typeof sub.createdAt === 'number' &&
    typeof sub.refreshBefore === 'number' &&
    Array.isArray(sub.seen)
  )
}

function isOutgoing(value: unknown): value is Outgoing {
  const item = record(value)
  return (
    item !== null &&
    typeof item.subscriptionId === 'string' &&
    typeof item.eventId === 'string' &&
    typeof item.body === 'string' &&
    typeof item.attempts === 'number' &&
    (item.nextAt === null || typeof item.nextAt === 'number')
  )
}
