/**
 * Everything Terminal Deck tells a CRM about its tasks, delivered once each.
 *
 * Three kinds of event, all about one CRM task and all posted to the
 * connection's events address:
 *
 *  - `task.status` — set the task to one of the CRM's own statuses, as one
 *    agent identity;
 *  - `task.comment` — progress, a blocker, a question or the completion, as
 *    one agent identity, on the task the work was first asked for on, in its
 *    thread;
 *  - `task.delegate_requested` — Hoot asks the CRM to create a child task for
 *    one of its agents. The CRM creates it and sends it back; this app never
 *    makes a task of record itself.
 *
 * ## Once each
 *
 * Every event gets its id when it is queued and keeps it through every retry,
 * so a CRM de-duplicating by `webhook-id` applies it once. Signed the Standard
 * Webhooks way with the connection's secret (`notify-webhook.ts`), each retry
 * signed afresh with the same id. A 2xx is delivered; the CRM may answer a
 * comment with `{"externalCommentId": "…"}`, which is remembered as ours so the
 * comment coming back as a webhook is not mistaken for somebody else's.
 *
 * ## The schedule, and the one timer
 *
 * The notification queue's: at once, then 5 s, 30 s and 2 min, then marked
 * undelivered and kept — still listed, and still in the file — until it is a
 * week old. A 4xx other than 408 and 429 is not retried: the CRM has said no,
 * and asking again will not change it. One timer for the whole outbox, armed
 * for the earliest attempt due and not at all when nothing is.
 */

import { randomUUID } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import { REAL_CLOCK, RETRY_DELAYS_MS, WEBHOOK_TIMEOUT_MS, type HubClock } from '../deck-control/notify-hub'
import { webhookHeaders } from '../deck-control/notify-webhook'

export const OUTBOX_FILE = 'task-outbox.json'

/** Delivered and undelivered events are kept this long, for Settings and the record. */
export const OUTBOX_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

export const MAX_OUTBOX = 2_000

export type CommentKind = 'progress' | 'blocker' | 'question' | 'completion'

export interface TaskEventBase {
  externalTaskId: string
  originExternalTaskId: string
  externalThreadId: string | null
  /** The CRM identity this is from. */
  actor: string
}

export type TaskEventBody =
  | (TaskEventBase & { type: 'task.status'; status: string })
  | (TaskEventBase & { type: 'task.comment'; comment: { kind: CommentKind; body: string; inReplyTo: string | null } })
  | (TaskEventBase & {
      type: 'task.delegate_requested'
      delegate: { assignee: string; title: string; instructions: string; project: string }
    })

/** What is posted: the event, with its id, its task's sequence number and when. */
export type TaskEvent = TaskEventBody & { eventId: string; seq: number; at: string }

type DeliveryState = 'pending' | 'delivered' | 'undelivered'

interface Outgoing {
  keyId: string
  event: TaskEvent
  state: DeliveryState
  attempts: number
  nextAt: number | null
  queuedAt: number
  error: string | null
}

export interface PostAnswer {
  status: number
  body: string
}

/** Posts one event. Resolves with the answer; rejects on a network failure or a timeout. */
export type EventPost = (url: string, headers: Record<string, string>, body: string) => Promise<PostAnswer>

export const fetchEventPost: EventPost = async (url, headers, body) => {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body,
    redirect: 'manual',
    signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
  })
  const text = await response.text().catch(() => '')
  return { status: response.status, body: text.slice(0, 8_192) }
}

export interface OutboxTarget {
  url: string
  secret: string
}

export interface TaskOutboxOptions {
  dir: string | null
  /** Where one connection's events go, or null when it has no address or no longer exists. */
  target(keyId: string): OutboxTarget | null
  clock?: HubClock
  post?: EventPost
  /** The CRM gave a comment of ours an id. */
  onCommentId?(keyId: string, externalCommentId: string): void
  onChange?(): void
}

export interface OutboxView {
  eventId: string
  type: TaskEvent['type']
  externalTaskId: string
  state: DeliveryState
  attempts: number
  error: string | null
}

export class TaskOutbox {
  private items: Outgoing[] = []
  private readonly clock: HubClock
  private readonly post: EventPost
  private readonly posting = new Set<Outgoing>()
  private timer: unknown = null
  private timerAt: number | null = null
  private saveQueued = false
  private stopped = false

  constructor(private readonly options: TaskOutboxOptions) {
    this.clock = options.clock ?? REAL_CLOCK
    this.post = options.post ?? fetchEventPost
    this.load()
    this.prune()
    this.arm()
  }

  /** Queue one event and try it at once. Returns the event as it will be posted. */
  send(keyId: string, body: TaskEventBody, seq: number): TaskEvent {
    const event = { ...body, eventId: `tde_${randomUUID()}`, seq, at: new Date(this.clock.now()).toISOString() } as TaskEvent
    if (this.stopped) return event
    this.items.push({ keyId, event, state: 'pending', attempts: 0, nextAt: this.clock.now(), queuedAt: this.clock.now(), error: null })
    this.prune()
    this.attempt()
    this.save()
    return event
  }

  list(keyId?: string): OutboxView[] {
    return this.items
      .filter((item) => keyId === undefined || item.keyId === keyId)
      .map((item) => ({
        eventId: item.event.eventId,
        type: item.event.type,
        externalTaskId: item.event.externalTaskId,
        state: item.state,
        attempts: item.attempts,
        error: item.error,
      }))
  }

  /** Events not yet delivered, for tests and the status line. */
  pending(): number {
    return this.items.filter((item) => item.state === 'pending').length
  }

  armed(): boolean {
    return this.timer !== null
  }

  stop(): void {
    this.stopped = true
    if (this.timer !== null) this.clock.clearTimeout(this.timer)
    this.timer = null
    this.timerAt = null
    this.flush()
  }

  /* ------------------------------------------------------- delivery -- */

  private attempt(): void {
    if (this.stopped) return
    const now = this.clock.now()
    for (const item of this.items) {
      if (item.state !== 'pending' || item.nextAt === null || item.nextAt > now || this.posting.has(item)) continue
      const target = this.options.target(item.keyId)
      if (target === null) {
        this.failed(item, 'the connection has no events address', false)
        continue
      }
      this.postOne(item, target)
    }
    this.arm()
  }

  private postOne(item: Outgoing, target: OutboxTarget): void {
    this.posting.add(item)
    item.attempts += 1
    const body = JSON.stringify(item.event)
    const headers = webhookHeaders(target.secret, item.event.eventId, Math.floor(this.clock.now() / 1000), body)
    void this.post(target.url, headers, body)
      .then(
        (answer) => answer,
        (error: unknown) => `the CRM could not be reached: ${error instanceof Error ? error.message : String(error)}`,
      )
      .then((outcome) => {
        this.posting.delete(item)
        if (this.stopped || !this.items.includes(item) || item.state !== 'pending') return
        if (typeof outcome !== 'string' && outcome.status >= 200 && outcome.status < 300) {
          item.state = 'delivered'
          item.nextAt = null
          item.error = null
          this.commentIdOf(item, outcome.body)
        } else if (typeof outcome === 'string') {
          this.failed(item, outcome, true)
        } else {
          const retry = outcome.status === 408 || outcome.status === 429 || outcome.status >= 500
          this.failed(item, `the CRM answered ${outcome.status}`, retry)
        }
        this.changed()
        this.arm()
      })
  }

  private failed(item: Outgoing, why: string, retry: boolean): void {
    item.error = why
    const delay = retry ? RETRY_DELAYS_MS[item.attempts - 1] : undefined
    if (delay === undefined) {
      item.state = 'undelivered'
      item.nextAt = null
    } else {
      item.nextAt = this.clock.now() + delay
    }
    this.save()
  }

  private commentIdOf(item: Outgoing, body: string): void {
    if (item.event.type !== 'task.comment' || body === '') return
    try {
      const id = (JSON.parse(body) as { externalCommentId?: unknown }).externalCommentId
      if (typeof id === 'string' && id !== '' && id.length <= 200) this.options.onCommentId?.(item.keyId, id)
    } catch {
      // An answer that is not JSON still delivered the comment.
    }
  }

  private arm(): void {
    if (this.stopped) return
    let next: number | null = null
    for (const item of this.items) {
      if (item.state !== 'pending' || item.nextAt === null || this.posting.has(item)) continue
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

  /* --------------------------------------------------------- keeping -- */

  private prune(): void {
    const cutoff = this.clock.now() - OUTBOX_MAX_AGE_MS
    this.items = this.items.filter((item) => item.state === 'pending' || item.queuedAt >= cutoff)
    if (this.items.length > MAX_OUTBOX) {
      const settled = this.items.filter((item) => item.state !== 'pending')
      const drop = new Set(settled.slice(0, this.items.length - MAX_OUTBOX))
      this.items = this.items.filter((item) => !drop.has(item))
    }
  }

  private changed(): void {
    this.save()
    try {
      this.options.onChange?.()
    } catch (error) {
      console.error('[tasks] an outbox listener threw:', error)
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, OUTBOX_FILE)
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
      writeSecretFile(this.options.dir, file, `${JSON.stringify({ v: 1, items: this.items })}\n`)
    } catch (error) {
      console.error('[tasks] could not save the outbox:', error)
    }
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as { v?: unknown; items?: unknown }
      if (raw.v !== 1 || !Array.isArray(raw.items)) return
      this.items = (raw.items as Outgoing[])
        .filter((item) => typeof item?.keyId === 'string' && typeof item.event?.eventId === 'string')
        // A post in the air when the app stopped is tried again, with the same id.
        .map((item) => (item.state === 'pending' && item.nextAt === null ? { ...item, nextAt: this.clock.now() } : item))
    } catch (error) {
      console.error('[tasks] could not read the outbox; starting empty:', error)
    }
  }
}
