/**
 * The lift-request inbox: asks an agent files, answers a person gives.
 *
 * ## What this is, and what it is not
 *
 * The session lift — copying a signed-in session out of one profile and into
 * the workers — is the one action in the scraping feature that moves a
 * credential, and it stays a **human gesture**: `browser-worker:lift` is an
 * `ipcMain` channel, no tool calls it, and nothing in this file changes that.
 * What this file adds is the *ask*. An agent that wants a session lifted files
 * a request here; the request is pushed to the panel and drawn as a row with
 * two answers, Approve and Decline; and the lift itself runs only inside the
 * answer handler in `browser-workers-ipc.ts`, on the press of a button the
 * person armed and pressed. The request is a request. There is no path from
 * this file to a cookie.
 *
 * Until 2026-08-22 the panel's inbox existed and this desk did not — the
 * approvals branch in `ScrapingPanel.tsx` rendered against three bridge
 * methods nothing wired, which `scraping-adapter.ts` defended as "unwired on
 * purpose". That defence protected the wrong thing: the gesture was never at
 * risk from an *inbox* — an inbox is how the gesture stays one — and what the
 * unwired seam actually produced was a control drawn in the panel's own source
 * that could never fire, the exact shape his own rules prohibit. So the
 * channel is real now, and the friction the old comment defended is kept
 * where it always belonged: in the answer being a person's armed press.
 *
 * ## The retry-loop objection, answered in the shape of the desk
 *
 * `worker-tools.ts` argued that a request tool is "a request an agent can make
 * in a retry loop". The desk is built so the loop buys nothing:
 *
 *  - an identical open ask (same asker, same source, same targets) is answered
 *    with the *existing* request rather than filed again — asking twice does
 *    not make two rows, and the answer says so;
 *  - the inbox is capped ({@link MAX_OPEN_REQUESTS}); a flood is refused with
 *    the cap in the sentence rather than absorbed;
 *  - nothing an agent does can answer a request. `takeLiftRequest` is called
 *    from the IPC answer handler and from nowhere else.
 *
 * ## No Electron in this file
 *
 * The desk is module state and pure functions, injected with what it needs
 * through {@link configureLiftRequests} — profile and worker lists, and a
 * notifier — so it is testable without a browser and usable from
 * `deck-control` without dragging Electron into the tool catalogue's tests.
 * `registerBrowserWorkerIpc` configures it with the real sources.
 */

import { randomBytes } from 'node:crypto'

/** A profile as the desk needs to name one: the id the stores key on, the name a person reads. */
export interface LiftProfileRef {
  id: string
  name: string
}

/** One ask, exactly the shape `scraping-bridge.ts`'s `readLiftRequests` narrows. */
export interface LiftRequestRow {
  id: string
  /** Who asked, in words a person can recognise. Never invented here. */
  askedBy: string
  fromProfileId: string
  intoProfileIds: string[]
  /** Why, if the asker said. `''` when it did not. */
  reason: string
  at: number
}

/** What the desk reads and tells, handed in at registration. */
export interface LiftRequestSources {
  /** Every profile, the default included — the *source* of a lift can be any of them. */
  profiles(): LiftProfileRef[]
  /** The worker subset — the only legal *targets*. */
  workers(): LiftProfileRef[]
  /** The inbox changed: a request was filed or answered. Pushed to every window. */
  notify(): void
}

/**
 * Eight, because an inbox is a place a person reads. Eight rows of two buttons
 * each is already a screenful of decisions; past that the honest answer to a
 * ninth ask is "the person has not answered the last eight", not a longer
 * list.
 */
export const MAX_OPEN_REQUESTS = 8

/** Enough to say why, not enough to paste a document into a panel row. */
const MAX_REASON_LENGTH = 200

let sources: LiftRequestSources | null = null
const open = new Map<string, LiftRequestRow>()

/** Wire the desk to the app, or to a test. Call with `null` to unwire. */
export function configureLiftRequests(next: LiftRequestSources | null): void {
  sources = next
}

/** Forget everything. For tests, and for nothing else. */
export function resetLiftRequestsForTests(): void {
  open.clear()
  sources = null
}

/**
 * A profile named by the name a person reads, or by its id.
 *
 * The same resolution `worker-tools.ts`'s `findWorker` performs and for the
 * same reason: ids appear on no screen, so making an agent quote one would
 * split the tool's vocabulary from the panel's. Name first, id as the
 * fallback, first match on a duplicate name — what a person pointing at a
 * list would mean.
 */
function findRef(list: LiftProfileRef[], nameOrId: string): LiftProfileRef | null {
  const wanted = nameOrId.trim().toLowerCase()
  if (wanted === '') return null
  return (
    list.find((ref) => ref.name.toLowerCase() === wanted) ??
    list.find((ref) => ref.id === nameOrId.trim()) ??
    null
  )
}

/** One line of reason, capped, never multi-line: it renders inside a panel row. */
function cleanReason(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  return raw.replace(/\s+/g, ' ').trim().slice(0, MAX_REASON_LENGTH)
}

export type FileLiftAnswer =
  | {
      ok: true
      request: LiftRequestRow
      /** The resolved names, for an asker that must not have to map ids back. */
      fromName: string
      intoNames: string[]
      /** True when this exact ask was already waiting — no second row was made. */
      repeated: boolean
    }
  | { ok: false; reason: string }

/**
 * File one ask. `from` and `into` arrive as names or ids and are resolved
 * against the real lists *now*, so a row in the inbox always names things that
 * existed when it was filed — never a guess the panel has to render as a raw
 * id beside a shrug.
 */
export function fileLiftRequest(input: {
  askedBy: string
  from: string
  into: readonly string[]
  reason?: unknown
}): FileLiftAnswer {
  if (sources === null) {
    return { ok: false, reason: 'nothing in this build can carry a lift request.' }
  }
  const from = findRef(sources.profiles(), input.from)
  if (from === null) {
    return {
      ok: false,
      reason: `there is no profile called ${JSON.stringify(input.from)} on this browser. browser.workers lists the workers; the person can name the others.`,
    }
  }
  const workers = sources.workers()
  const into: LiftProfileRef[] = []
  if (input.into.length === 0) {
    // Naming nothing means every worker — the case the fleet exists for — but
    // never the profile the session would come from.
    into.push(...workers.filter((worker) => worker.id !== from.id))
  } else {
    for (const name of input.into) {
      const worker = findRef(workers, name)
      if (worker === null) {
        return {
          ok: false,
          reason: `${JSON.stringify(name)} is not a worker profile. A lift only ever lands in workers — browser.workers lists them.`,
        }
      }
      if (worker.id !== from.id && !into.some((chosen) => chosen.id === worker.id)) into.push(worker)
    }
  }
  if (into.length === 0) {
    return {
      ok: false,
      reason:
        workers.length === 0
          ? 'there is no worker profile to lift into. The person adds them in the browser’s profile menu, under Workers.'
          : 'the only worker named is the profile the session would come from, which is already signed in.',
    }
  }

  const intoIds = into.map((worker) => worker.id).sort()
  for (const request of open.values()) {
    if (
      request.askedBy === input.askedBy &&
      request.fromProfileId === from.id &&
      request.intoProfileIds.length === intoIds.length &&
      [...request.intoProfileIds].sort().every((id, index) => id === intoIds[index])
    ) {
      // Asking again is not a second row. The loop buys nothing.
      return {
        ok: true,
        request,
        fromName: from.name,
        intoNames: into.map((worker) => worker.name),
        repeated: true,
      }
    }
  }
  if (open.size >= MAX_OPEN_REQUESTS) {
    return {
      ok: false,
      reason: `there are already ${MAX_OPEN_REQUESTS} asks waiting for the person. Do not retry; they answer in the browser’s Scraping panel.`,
    }
  }

  const request: LiftRequestRow = {
    id: randomBytes(9).toString('hex'),
    askedBy: input.askedBy,
    fromProfileId: from.id,
    intoProfileIds: into.map((worker) => worker.id),
    reason: cleanReason(input.reason),
    at: Date.now(),
  }
  open.set(request.id, request)
  sources.notify()
  return {
    ok: true,
    request,
    fromName: from.name,
    intoNames: into.map((worker) => worker.name),
    repeated: false,
  }
}

/** The inbox, oldest first — the order a person answers a queue in. */
export function listLiftRequests(): LiftRequestRow[] {
  return [...open.values()].sort((a, b) => a.at - b.at)
}

/**
 * Remove one request because it was answered. IPC answer handler only — see
 * the header for why nothing an agent reaches may call this.
 */
export function takeLiftRequest(id: string): LiftRequestRow | null {
  const request = open.get(id) ?? null
  if (request !== null) {
    open.delete(id)
    sources?.notify()
  }
  return request
}

/** Read one without answering it — the approve path re-checks before acting. */
export function peekLiftRequest(id: string): LiftRequestRow | null {
  return open.get(id) ?? null
}
