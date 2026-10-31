/**
 * Notifications for AI apps outside this one: one queue, every channel fed from it.
 *
 * ## What this is for, in his words
 *
 *   > *"MCP can be connected to the multiple different AI agents… at the same
 *   > time… whatever the new updates session will give in terms of answer to
 *   > them, our terminal deck will send them and push them a notification
 *   > instead of they keep watching… they can have their own separate sessions.
 *   > So I don't want to mix that."*
 *
 * So a notification is **one event, for exactly one access key**: a session that
 * key started (or a turn that key triggered) finished, stopped to ask something,
 * or exited. `notify-detect.ts` decides which key; this file keeps the
 * notification until that key has it, and refuses to show it to any other.
 *
 * ## One queue, four ways out
 *
 *  - **Long-poll** (`notifications.wait`). A parked waiter for the key is handed
 *    the notification the moment it is queued; a waiter that arrives later finds
 *    it waiting. This is the push that works for every agent that can loop, and
 *    through the relay. The Claude Code channel bridge (`notify-channel.ts`) is
 *    a long-poller too: it waits here and turns each notification into a
 *    message in the running Claude Code session.
 *  - **Webhook**, when the owner set one for the key in Settings. Posted as JSON,
 *    signed (`notify-webhook.ts`); a 2xx answer is delivery.
 *  - **MCP Events** (`mcp-events.ts`), when the app itself subscribed — ChatGPT,
 *    on protocol 2026-07-28. Offered from here once queued; a push that lands
 *    comes back as {@link NotificationHub.deliveredBy}.
 *  - **`notifications.list`**, which shows everything not yet acknowledged,
 *    whatever happened to it — the reconnect path.
 *
 * ## Which apps can really be pushed to
 *
 * Checked against each client's documentation and source on 2026-10-03:
 * ChatGPT acts on MCP Events (a subscription and a signed webhook, not a
 * message on the MCP connection); Claude Code acts on "channels", which are
 * stdio-only, hence the bridge. claude.ai, Codex CLI, Gemini CLI and Cursor
 * hand no server-initiated message to their model at all — they get the
 * long-poll. A plain server-to-client notification on the HTTP connection is
 * not sent: this server is stateless, and no client would show it to a model.
 *
 * Whichever delivers first wins and the rest stop trying. While an MCP Events
 * push of a notification is still being tried (`pushing`), it is not handed to
 * a waiter or posted to a webhook as well; once the push gives up, it is. Every notification
 * stays fetchable by `list` until its key **acknowledges it by id**; acking is
 * idempotent, so an app that acks twice, or acks one it got twice, sees one.
 *
 * ## The schedule, and the one timer
 *
 * One attempt as soon as it is queued, then at most three more, after 5 s, 30 s
 * and 2 min. After the last it is marked **undelivered** and timed attempts
 * stop — it is still handed to the next `notifications.wait` and still in
 * `notifications.list`. An attempt is a webhook post for a key with a webhook,
 * and an offer to a parked waiter for one without.
 *
 * There is no timer per notification and none per session. One timer, armed for
 * the earliest attempt that is due, re-armed after each pass, and **not armed at
 * all when nothing is pending** — an empty queue costs nothing. The clock and the
 * timer are injected, so the schedule is tested by moving a fake clock, never by
 * burning CPU.
 *
 * ## What is kept, and for how long
 *
 * `<userData>/remote/notifications.json`, written through `secret-file.ts`
 * (0600, atomic) because it holds what agents said in somebody's sessions. At
 * most {@link MAX_PER_KEY} per key and none older than {@link MAX_AGE_MS}; the
 * oldest go first. A restart of the app loses nothing outstanding: pending ones
 * pick their schedule up where it was.
 *
 * ## One turn, one notification
 *
 * Each id is new per notification, so the id alone cannot stop the same turn
 * being told twice. The detector therefore hands over what the turn *was* — the
 * answer it ended on — and the queue keeps every turn it has taken in the same
 * file, for as long as it keeps notifications. A second notification for a
 * turn already taken is refused, whoever it would go to, and whether or not
 * the first was acknowledged: on 2026-10-04 one answer reached the same app
 * five times over six hours, each time the screen redrew.
 */

import { randomUUID } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import { webhookHeaders } from './notify-webhook'

/* -------------------------------------------------------------- constants -- */

export const NOTIFICATIONS_FILE = 'notifications.json'

/** Delays before each retry after the first attempt. Three retries, then undelivered. */
export const RETRY_DELAYS_MS: readonly number[] = [5_000, 30_000, 120_000]

/** Most notifications kept per access key. The oldest go first. */
export const MAX_PER_KEY = 200

/** Oldest notification kept, acknowledged or not. Seven days. */
export const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

/** Most notifications one `notifications.wait` hands back at once. */
export const MAX_PER_WAIT = 20

/** How long a webhook post may take before it counts as a failed attempt. */
export const WEBHOOK_TIMEOUT_MS = 10_000

/** Most turns remembered as told, so one answer is never told twice. The oldest go first. */
export const MAX_TURNS_KEPT = 1_000

/* ------------------------------------------------------------------ types -- */

export type NotificationType = 'finished' | 'needs-input' | 'exited'

/** One notification, as an AI app receives it. Everything in it is about one session. */
export interface NotificationEvent {
  /** Stable. What `notifications.ack` takes, and the webhook's `webhook-id`. */
  id: string
  type: NotificationType
  sessionId: string
  sessionName: string
  /** Epoch ms of the event itself. */
  at: number
  /** `finished`: the newest thing the agent said, capped. */
  answer?: { text: string; truncated: boolean }
  /** `needs-input`, or a `finished` session with no transcript: the screen's last lines, capped. */
  screen?: { text: string; truncated: boolean }
  /** `exited`: the code, and whether that is a crash. */
  exitCode?: number
  crashed?: boolean
  /** The tool a caller most likely wants next, by its wire name. */
  suggestedTool: string
  /** One sentence of fact about what happened. Never an instruction. */
  note: string
}

export type DeliveryState = 'pending' | 'delivered' | 'undelivered'
/** How a notification reached its app. `event`: an MCP Events push (`mcp-events.ts`). */
export type DeliveryVia = 'wait' | 'webhook' | 'list' | 'event'

interface Stored {
  event: NotificationEvent
  keyId: string
  state: DeliveryState
  /** Attempts made so far: webhook posts, or offers to a parked waiter. */
  attempts: number
  /** When the next timed attempt is due, or null when none is. */
  nextAt: number | null
  via: DeliveryVia | null
  deliveredAt: number | null
  lastError: string | null
}

/** What Settings shows under a key: how its last notification went. */
export interface LastDelivery {
  state: DeliveryState | 'failed'
  at: number
  via: DeliveryVia | null
  error: string | null
  /** How many of this key's notifications are not yet acknowledged. */
  outstanding: number
}

/** One notification as `notifications.list` shows it: the event, and what became of it. */
export interface ListedNotification extends NotificationEvent {
  delivery: DeliveryState
  via: DeliveryVia | null
}

/** How a key wants to be told. Read per attempt, so a change in Settings lands at once. */
export interface KeyNotifySettings {
  mode: 'off' | 'wait' | 'webhook'
  url: string | null
  secret: string | null
}

/** The clock and the one timer, injected so the schedule can be tested without waiting. */
export interface HubClock {
  now(): number
  setTimeout(run: () => void, ms: number): unknown
  clearTimeout(handle: unknown): void
}

export const REAL_CLOCK: HubClock = {
  now: () => Date.now(),
  setTimeout: (run, ms) => {
    const handle = setTimeout(run, ms)
    handle.unref?.()
    return handle
  },
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
}

/** Posts one webhook. Resolves with the HTTP status; rejects on a network failure or a timeout. */
export type WebhookPost = (url: string, headers: Record<string, string>, body: string) => Promise<number>

/** The real one: `fetch`, no redirects followed, a hard timeout. */
export const fetchPost: WebhookPost = async (url, headers, body) => {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body,
    redirect: 'manual',
    signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
  })
  // Drained so the connection can be reused; nothing in it is read.
  await response.arrayBuffer().catch(() => undefined)
  return response.status
}

export interface NotificationHubOptions {
  /** `<userData>/remote`. Null keeps everything in memory, for tests that do not need a disk. */
  dir: string | null
  /** The key's notify settings, or null when the key no longer exists. */
  settings(keyId: string): KeyNotifySettings | null
  clock?: HubClock
  post?: WebhookPost
  /** Told after anything a Settings page would redraw for. */
  onChange?(): void
  /** Is an MCP Events push of this notification still being tried? `McpEvents.owes`. */
  pushing?(keyId: string, id: string): boolean
}

interface Waiter {
  keyId: string
  max: number
  settle(events: NotificationEvent[]): void
}

/* -------------------------------------------------------------------- hub -- */

export class NotificationHub {
  private items: Stored[] = []
  private last = new Map<string, Omit<LastDelivery, 'outstanding'>>()
  /** Turns already told, by what the detector says the turn was, with when. Oldest first. */
  private turns = new Map<string, number>()
  private readonly waiters = new Set<Waiter>()
  private readonly clock: HubClock
  private readonly post: WebhookPost
  private timer: unknown = null
  private timerAt: number | null = null
  private saveQueued = false
  private stopped = false
  /** Posts in flight, by notification id, so a pass never posts the same one twice at once. */
  private readonly posting = new Set<string>()

  constructor(private readonly options: NotificationHubOptions) {
    this.clock = options.clock ?? REAL_CLOCK
    this.post = options.post ?? fetchPost
    this.load()
    this.prune()
    this.arm()
  }

  /* ------------------------------------------------------------ in -- */

  /**
   * Queue one notification for one key, and try it at once.
   *
   * Nothing is queued for a key that is gone or set to off: off means *do not
   * keep these for me*, and a queue filling up for an app that said so would be
   * a pile of other people's answers on disk for nobody.
   *
   * `turn` names the turn this is about (see "One turn, one notification"); a
   * turn already taken is refused.
   */
  enqueue(keyId: string, event: NotificationEvent, turn?: string): boolean {
    if (this.stopped) return false
    const settings = this.options.settings(keyId)
    if (settings === null || settings.mode === 'off') return false
    if (turn !== undefined) {
      if (this.turns.has(turn)) return false
      this.turns.set(turn, this.clock.now())
    }
    this.items.push({
      event,
      keyId,
      state: 'pending',
      attempts: 0,
      nextAt: this.clock.now(),
      via: null,
      deliveredAt: null,
      lastError: null,
    })
    this.prune()
    this.note(keyId, { state: 'pending', at: this.clock.now(), via: null, error: null })
    this.attempt()
    this.save()
    return true
  }

  /* ----------------------------------------------------------- out -- */

  /**
   * The long-poll: this key's undelivered notifications, now or as soon as one
   * exists, or none when the time runs out or the caller hangs up.
   *
   * Hands back everything not yet delivered — pending, and undelivered after
   * its retries ran out — and marks it delivered by `wait`. What was delivered
   * some other way is not handed again here; `notifications.list` shows it
   * until it is acknowledged.
   */
  wait(keyId: string, timeoutMs: number, signal?: AbortSignal, max = MAX_PER_WAIT): Promise<NotificationEvent[]> {
    const ready = this.take(keyId, max, 'wait')
    if (ready.length > 0 || this.stopped) return Promise.resolve(ready)
    if (signal?.aborted === true) return Promise.resolve([])
    return new Promise((resolve) => {
      let timer: unknown = null
      const waiter: Waiter = {
        keyId,
        max,
        settle: (events) => {
          if (!this.waiters.delete(waiter)) return
          if (timer !== null) this.clock.clearTimeout(timer)
          signal?.removeEventListener('abort', onAbort)
          resolve(events)
        },
      }
      const onAbort = (): void => waiter.settle([])
      this.waiters.add(waiter)
      timer = this.clock.setTimeout(() => waiter.settle([]), Math.max(timeoutMs, 0))
      signal?.addEventListener('abort', onAbort, { once: true })
    })
  }

  /** Everything this key has not acknowledged, oldest first, with what became of each. */
  list(keyId: string): ListedNotification[] {
    this.prune()
    return this.items
      .filter((item) => item.keyId === keyId)
      .map((item) => ({ ...item.event, delivery: item.state, via: item.via }))
  }

  /**
   * Acknowledge by id. Idempotent, and blind to other keys.
   *
   * An id this key acknowledged before, an id that never existed and an id
   * belonging to another key all land in `alreadyGone` — one bucket, so acking
   * cannot be used to learn whether somebody else has a notification.
   */
  ack(keyId: string, ids: readonly string[]): { acked: string[]; alreadyGone: string[] } {
    const wanted = new Set(ids)
    const acked: string[] = []
    this.items = this.items.filter((item) => {
      if (item.keyId !== keyId || !wanted.has(item.event.id)) return true
      acked.push(item.event.id)
      return false
    })
    const alreadyGone = [...wanted].filter((id) => !acked.includes(id))
    if (acked.length > 0) {
      this.arm()
      this.save()
      this.changed()
    }
    return { acked, alreadyGone }
  }

  /**
   * Post one signed test notification to the key's webhook now, outside the
   * queue, and say what happened. For the Test button in Settings: nothing is
   * kept and nothing is retried.
   */
  async testWebhook(keyId: string): Promise<{ ok: boolean; message: string }> {
    const settings = this.options.settings(keyId)
    if (settings === null || settings.url === null || settings.secret === null) {
      return { ok: false, message: 'Set a webhook address first.' }
    }
    const event: NotificationEvent = {
      id: `test-${randomUUID()}`,
      type: 'finished',
      sessionId: 'test',
      sessionName: 'Test notification',
      at: this.clock.now(),
      answer: { text: 'This is a test from Settings. Nothing happened in any session.', truncated: false },
      suggestedTool: 'notifications_list',
      note: 'A test notification, sent from Settings. It is not kept and needs no acknowledgement.',
    }
    const body = JSON.stringify(event)
    try {
      const status = await this.post(
        settings.url,
        webhookHeaders(settings.secret, event.id, Math.floor(this.clock.now() / 1000), body),
        body,
      )
      return status >= 200 && status < 300
        ? { ok: true, message: `Delivered: the address answered ${status}.` }
        : { ok: false, message: `The address answered ${status}, so a real notification would be retried.` }
    } catch (error) {
      return { ok: false, message: `Could not reach the address: ${error instanceof Error ? error.message : String(error)}` }
    }
  }

  /**
   * An MCP Events subscriber took this notification: it is delivered.
   *
   * The same rule as every other way out — whichever delivers first wins and
   * the rest stop — so an app that subscribed and also parks a
   * `notifications_wait` is not handed the same news twice. Still listed until
   * acknowledged, like everything else.
   */
  deliveredBy(keyId: string, id: string, via: DeliveryVia): boolean {
    const item = this.items.find((entry) => entry.keyId === keyId && entry.event.id === id)
    if (!item || item.state === 'delivered') return false
    this.delivered(item, via)
    this.arm()
    return true
  }

  /** Is this notification still the key's and not yet delivered? What a push asks before each post. */
  owes(keyId: string, id: string): boolean {
    return this.items.some((item) => item.keyId === keyId && item.event.id === id && item.state !== 'delivered')
  }

  /** How the key's last notification went, for Settings. Null when it never had one. */
  lastDelivery(keyId: string): LastDelivery | null {
    const last = this.last.get(keyId)
    if (!last) return null
    return { ...last, outstanding: this.items.filter((item) => item.keyId === keyId).length }
  }

  /** Every key's queue that still exists; anything for a revoked key is dropped. */
  reconcile(): void {
    const before = this.items.length
    this.items = this.items.filter((item) => this.options.settings(item.keyId) !== null)
    for (const keyId of [...this.last.keys()]) if (this.options.settings(keyId) === null) this.last.delete(keyId)
    for (const waiter of [...this.waiters]) if (this.options.settings(waiter.keyId) === null) waiter.settle([])
    if (this.items.length !== before) {
      this.arm()
      this.save()
    }
    // A key switched to a webhook, or back, changes what the next attempt is.
    this.attempt()
  }

  /** Outstanding notifications, per key or in all. For tests and the status line. */
  size(keyId?: string): number {
    return keyId === undefined ? this.items.length : this.items.filter((item) => item.keyId === keyId).length
  }

  /** Quit: waiters are answered with nothing, the timer goes, the file is written. */
  stop(): void {
    this.stopped = true
    for (const waiter of [...this.waiters]) waiter.settle([])
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = null
    this.flush()
  }

  /* ------------------------------------------------------- delivery -- */

  /**
   * One pass over everything due: hand it to a waiter or a stream, or post it.
   *
   * A notification for a key in `wait` mode is delivered by being taken; this
   * pass offers it to a parked waiter. One for a key with a webhook is posted. Either way a miss costs one attempt and schedules the
   * next, until the schedule runs out.
   */
  private attempt(): void {
    if (this.stopped) return
    const now = this.clock.now()
    for (const item of this.items) {
      if (item.state !== 'pending' || item.nextAt === null || item.nextAt > now) continue
      if (this.posting.has(item.event.id)) continue
      const settings = this.options.settings(item.keyId)
      if (settings === null || settings.mode === 'off') continue
      if (this.isPushing(item)) {
        this.missed(item, 'its push to the app is still being tried')
        continue
      }
      // A parked waiter takes it first, whatever the mode: the app is listening
      // right now, and that is the fastest delivery there is.
      if (this.offer(item)) continue
      if (settings.mode === 'webhook' && settings.url !== null && settings.secret !== null) {
        this.postOne(item, settings.url, settings.secret)
        continue
      }
      this.missed(item, 'nobody was waiting for it')
    }
    this.arm()
  }

  /** Offer one notification to a parked waiter for its key. */
  private offer(item: Stored): boolean {
    for (const waiter of this.waiters) {
      if (waiter.keyId !== item.keyId) continue
      // The waiter takes everything ready for its key, not only this one.
      const events = this.take(item.keyId, waiter.max, 'wait')
      if (events.length === 0) continue
      waiter.settle(events)
      return true
    }
    return false
  }

  private postOne(item: Stored, url: string, secret: string): void {
    this.posting.add(item.event.id)
    item.attempts += 1
    const body = JSON.stringify(item.event)
    const headers = webhookHeaders(secret, item.event.id, Math.floor(this.clock.now() / 1000), body)
    void this.post(url, headers, body)
      .then(
        (status) => (status >= 200 && status < 300 ? null : `the webhook answered ${status}`),
        (error: unknown) => `the webhook could not be reached: ${error instanceof Error ? error.message : String(error)}`,
      )
      .then((problem) => {
        this.posting.delete(item.event.id)
        // Acknowledged, taken by a waiter, or dropped while the post was out.
        if (!this.items.includes(item) || item.state !== 'pending') return
        if (problem === null) this.delivered(item, 'webhook')
        else this.failed(item, problem)
        this.arm()
        this.save()
      })
  }

  /** An attempt that found nobody to take it. Counts against the schedule. */
  private missed(item: Stored, why: string): void {
    item.attempts += 1
    this.failed(item, why)
  }

  private failed(item: Stored, why: string): void {
    item.lastError = why
    const retry = RETRY_DELAYS_MS[item.attempts - 1]
    if (retry === undefined) {
      item.state = 'undelivered'
      item.nextAt = null
      this.note(item.keyId, { state: 'undelivered', at: this.clock.now(), via: null, error: why })
    } else {
      item.nextAt = this.clock.now() + retry
      this.note(item.keyId, { state: 'failed', at: this.clock.now(), via: null, error: why })
    }
    this.save()
  }

  private delivered(item: Stored, via: DeliveryVia): void {
    item.state = 'delivered'
    item.via = via
    item.nextAt = null
    item.deliveredAt = this.clock.now()
    item.lastError = null
    this.note(item.keyId, { state: 'delivered', at: item.deliveredAt, via, error: null })
    this.save()
  }

  /** Take up to `max` not-yet-delivered notifications for a key, marking them delivered. */
  private take(keyId: string, max: number, via: DeliveryVia): NotificationEvent[] {
    const out: NotificationEvent[] = []
    for (const item of this.items) {
      if (out.length >= max) break
      if (item.keyId !== keyId || item.state === 'delivered' || this.isPushing(item)) continue
      this.delivered(item, via)
      out.push(item.event)
    }
    if (out.length > 0) this.arm()
    return out
  }

  private isPushing(item: Stored): boolean {
    return this.options.pushing?.(item.keyId, item.event.id) === true
  }

  /** The one timer, at the earliest attempt due — or none when nothing is. */
  private arm(): void {
    if (this.stopped) return
    let next: number | null = null
    for (const item of this.items) {
      if (item.state !== 'pending' || item.nextAt === null || this.posting.has(item.event.id)) continue
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

  /** Is the one timer armed right now? For the test that says an empty queue costs nothing. */
  armed(): boolean {
    return this.timer !== null
  }

  /* --------------------------------------------------------- keeping -- */

  private prune(): void {
    const cutoff = this.clock.now() - MAX_AGE_MS
    const kept = this.items.filter((item) => item.event.at >= cutoff)
    const perKey = new Map<string, Stored[]>()
    for (const item of kept) {
      const run = perKey.get(item.keyId) ?? []
      run.push(item)
      perKey.set(item.keyId, run)
    }
    const drop = new Set<Stored>()
    for (const run of perKey.values()) {
      if (run.length <= MAX_PER_KEY) continue
      for (const item of run.slice(0, run.length - MAX_PER_KEY)) drop.add(item)
    }
    this.items = kept.filter((item) => !drop.has(item))
    for (const [turn, at] of this.turns) {
      if (at >= cutoff && this.turns.size <= MAX_TURNS_KEPT) break
      this.turns.delete(turn)
    }
  }

  private note(keyId: string, last: Omit<LastDelivery, 'outstanding'>): void {
    this.last.set(keyId, last)
    this.changed()
  }

  private changed(): void {
    try {
      this.options.onChange?.()
    } catch (error) {
      console.error('[notify] a change listener threw:', error)
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, NOTIFICATIONS_FILE)
  }

  /** Coalesced: many changes in one turn of the event loop are one write. */
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
      const state = { v: 1, items: this.items, last: Object.fromEntries(this.last), turns: [...this.turns] }
      writeSecretFile(this.options.dir, file, `${JSON.stringify(state)}\n`)
    } catch (error) {
      console.error('[notify] could not save the notification queue:', error)
    }
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as { v?: unknown; items?: unknown; last?: unknown; turns?: unknown }
      if (raw.v !== 1 || !Array.isArray(raw.items)) return
      this.items = raw.items.filter(isStored).map((item) =>
        // A post that was in the air when the app stopped is retried, not lost.
        item.state === 'pending' && item.nextAt === null ? { ...item, nextAt: this.clock.now() } : item,
      )
      if (typeof raw.last === 'object' && raw.last !== null) {
        for (const [keyId, value] of Object.entries(raw.last as Record<string, unknown>)) {
          if (isLast(value)) this.last.set(keyId, value)
        }
      }
      // Absent in a file written before turns were kept: nothing told yet, then.
      if (Array.isArray(raw.turns)) {
        for (const entry of raw.turns) {
          if (Array.isArray(entry) && typeof entry[0] === 'string' && typeof entry[1] === 'number') {
            this.turns.set(entry[0], entry[1])
          }
        }
      }
    } catch (error) {
      console.error('[notify] could not read the notification queue; starting empty:', error)
      this.items = []
    }
  }
}

function isStored(value: unknown): value is Stored {
  if (typeof value !== 'object' || value === null) return false
  const item = value as Partial<Stored>
  const event = item.event as Partial<NotificationEvent> | undefined
  return (
    typeof item.keyId === 'string' &&
    (item.state === 'pending' || item.state === 'delivered' || item.state === 'undelivered') &&
    typeof item.attempts === 'number' &&
    typeof event === 'object' &&
    event !== null &&
    typeof event.id === 'string' &&
    typeof event.sessionId === 'string' &&
    typeof event.at === 'number' &&
    (event.type === 'finished' || event.type === 'needs-input' || event.type === 'exited')
  )
}

function isLast(value: unknown): value is Omit<LastDelivery, 'outstanding'> {
  if (typeof value !== 'object' || value === null) return false
  const last = value as Partial<LastDelivery>
  return typeof last.at === 'number' && typeof last.state === 'string'
}
