/**
 * Worker profiles as a pool: who is free, how many may run at once, and how
 * long each one waits.
 *
 * ## What this is for
 *
 * Asad runs a real-estate data pipeline against two property platforms. It was
 * not blocked — it was let through and the tooling around it threw the data
 * away. The two numbers this file exists because of are the ones about *shape*
 * rather than about images:
 *
 *  - one profile doing everything in series, so a run that should have been
 *    seven parallel logins was one, and
 *  - "delays" that were configuration rather than mechanism, so nothing waited.
 *
 * His instruction bounds the answer as much as it asks for it:
 *
 *   > *"Don't build a full scraping framework inside a terminal app. The
 *   > browser should expose these capabilities cleanly; the orchestration can
 *   > live outside."*
 *
 * So there is no crawl here, no queue of URLs, no retry policy and no notion of
 * a *job*. There are N workers, a rule about how many may be out at once, and a
 * wait that is **actually waited**. Everything above that lives in whatever
 * script he points at the tools.
 *
 * ## Why this file has no Electron in it
 *
 * A pool is arithmetic over a clock, and arithmetic over a clock is the thing
 * that can be got wrong quietly. `browser-workers.ts` holds the half that needs
 * a `Session` and a directory on disk; everything in here takes its `now` and
 * its randomness as arguments, so the whole of it is driven from a test with a
 * fake clock and no app.
 *
 * That is not a stylistic preference. A previous lesson in this workspace was
 * an agent that "tested" timing by spinning the CPU with `while :; do :; done`
 * and took the machine's load average to 836. The way to test a delay is to
 * lie to it about the time, and the only way to do *that* is to make the time
 * an argument.
 *
 * ## The lease, and why it expires
 *
 * A lease is the answer to "which worker is busy". It is held in memory and it
 * is **never persisted**, because a busy flag that outlives the process that
 * set it is a worker that is busy forever after one crash — a control that
 * looks like it works and does not.
 *
 * It also expires on a deadline rather than on a release, for the same reason
 * one layer down: the holder of a lease is an agent, and an agent can stop
 * existing between one tool call and the next. {@link WorkerPool.renew} is how
 * a long piece of work says it is still alive. Nothing here kills anything —
 * an expired lease just stops counting.
 */

/* ------------------------------------------------------------------ shape -- */

/** One worker, as the pool sees it. The partition lives in `browser-workers.ts`. */
export interface PoolWorker {
  profileId: string
  name: string
}

/**
 * How many at once, and how long each waits.
 *
 * Two numbers and a jitter, and each of them is a different question:
 *
 *  - `maxConcurrent` — how many leases may be out at the same moment. Bounded
 *    by the pool's size in practice, and separately here so that eight minted
 *    workers can be run three at a time without deleting five of them (which
 *    would throw away five earned clearances — see `browser-workers.ts`).
 *  - `minDelayMs` — the floor between one worker finishing and that same worker
 *    starting again. Per worker, not global: the whole point of N workers is
 *    that they are independent, and a global gate would make eight workers
 *    behave like one slow one.
 *  - `jitterMs` — added uniformly on top. A fixed gap is a metronome, and a
 *    metronome is the most recognisable thing a client can be.
 */
export interface PaceSettings {
  maxConcurrent: number
  minDelayMs: number
  jitterMs: number
}

/**
 * The ceiling on `minDelayMs + jitterMs`, and it is not arbitrary.
 *
 * A lease is handed out by a tool call that **awaits the wait** — that is what
 * makes the delay a mechanism rather than a setting. An MCP client gives a tool
 * call sixty seconds, so a pace that could exceed that would turn a correct
 * delay into a timeout, and a timeout reads to a model as a broken tool worth
 * retrying immediately. Thirty seconds is comfortably inside it and far longer
 * than any polite gap.
 *
 * A person who genuinely wants a five-minute gap has an orchestrator outside
 * this app and can sleep in it; what this app must not do is accept the number
 * and then break on it.
 */
export const MAX_PACE_MS = 30_000

/** Nothing above this is a pool, it is a fleet, and it is not what this is. */
export const MAX_WORKERS = 16

export const DEFAULT_PACE: Readonly<PaceSettings> = Object.freeze({
  maxConcurrent: 3,
  minDelayMs: 1_500,
  jitterMs: 1_000,
})

/** A lease that is out right now. Memory only — see the header. */
export interface Lease {
  profileId: string
  /** Who holds it: a session id, or `copilot`. Opaque to the pool. */
  holder: string
  takenAt: number
  expiresAt: number
}

/** Why a lease was not granted. Each one is a different sentence to a caller. */
export type LeaseRefusal =
  | 'no-workers'
  | 'at-capacity'
  | 'all-busy'
  | 'busy'
  | 'unknown-worker'

export type LeaseAnswer =
  | { ok: true; lease: Lease; waitMs: number }
  | { ok: false; reason: LeaseRefusal }

/** What a screen — or a tool — is told about one worker. */
export interface WorkerStatus {
  profileId: string
  name: string
  busy: boolean
  /** Who has it, or `''`. */
  holder: string
  /** How long they have had it, in ms, or 0. */
  heldMs: number
  /** When it was last let go, or 0 for never. */
  lastReleasedAt: number
  /** How long this worker would have to wait if leased right now. */
  readyInMs: number
}

/* ------------------------------------------------------------ validation -- */

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(Math.trunc(value), min), max)
}

function num(raw: unknown, fallback: number): number {
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : fallback
}

/**
 * A pace a person typed, or the default, and never a number that would break.
 *
 * Clamped rather than rejected: this is read from a JSON file on disk and from
 * a settings field, and a browser that refuses to open because a number is out
 * of range is worse than one that quietly holds the line at thirty seconds. The
 * clamp is visible — {@link paceNote} is what the panel prints beside the field
 * when the number it stored is not the number that was typed, so nothing is
 * silently different from what the screen says.
 */
export function cleanPace(raw: unknown): PaceSettings {
  const value = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const minDelayMs = clamp(num(value.minDelayMs, DEFAULT_PACE.minDelayMs), 0, MAX_PACE_MS)
  return {
    maxConcurrent: clamp(num(value.maxConcurrent, DEFAULT_PACE.maxConcurrent), 1, MAX_WORKERS),
    minDelayMs,
    // The jitter is bounded by what is left of the ceiling, so the *sum* can
    // never exceed it — which is the number the tool call actually waits.
    jitterMs: clamp(num(value.jitterMs, DEFAULT_PACE.jitterMs), 0, MAX_PACE_MS - minDelayMs),
  }
}

/** The sentence a screen prints when the stored pace is not what was typed. */
export function paceNote(typed: unknown, stored: PaceSettings): string {
  const wanted = typeof typed === 'object' && typed !== null ? (typed as Record<string, unknown>) : {}
  const parts: string[] = []
  if (num(wanted.maxConcurrent, stored.maxConcurrent) !== stored.maxConcurrent) {
    parts.push(`at most ${stored.maxConcurrent} at once`)
  }
  if (num(wanted.minDelayMs, stored.minDelayMs) !== stored.minDelayMs) {
    parts.push(`a wait of ${stored.minDelayMs} ms`)
  }
  if (num(wanted.jitterMs, stored.jitterMs) !== stored.jitterMs) {
    parts.push(`a jitter of ${stored.jitterMs} ms`)
  }
  return parts.length === 0 ? '' : `Held at ${parts.join(', ')}: ${MAX_PACE_MS} ms is the ceiling.`
}

/**
 * The wait for one lease.
 *
 * `random` is an argument so a test can assert both ends of the jitter rather
 * than assert a range and hope. `Math.random()` never returns 1, so the top of
 * the range is `jitterMs` exactly when a test hands it one.
 */
export function jitteredDelay(pace: PaceSettings, random: number): number {
  const spread = pace.jitterMs <= 0 ? 0 : Math.round(Math.min(Math.max(random, 0), 1) * pace.jitterMs)
  return pace.minDelayMs + spread
}

/* --------------------------------------------------------------- the pool -- */

export interface PoolDeps {
  /** Every worker that exists, in a stable order. */
  workers(): readonly PoolWorker[]
  pace(): PaceSettings
  now(): number
  /** 0 ≤ r < 1. An argument so the jitter can be pinned in a test. */
  random(): number
  /**
   * Something observable changed: a lease was taken, let go, or dropped.
   *
   * Optional, and the pool does not care what happens next — it exists because
   * a screen that shows *busy* had no way to hear about it. Until this landed,
   * the Scraping panel's fleet line read *"4 workers · busy not measured"* on a
   * build where the pool knew exactly which of them were busy, because nothing
   * in this process emitted an event and the panel refuses to print a zero it
   * has not been told.
   *
   * **Not called from {@link WorkerPool.status}.** Every method sweeps expired
   * leases first, including `status()`, so a sweep that announced itself would
   * re-enter whatever is building the answer. An expiry noticed while somebody
   * is reading the status is already in the answer they are reading.
   */
  changed?(): void
}

/**
 * How long a lease lives without being renewed.
 *
 * Long enough for a page to load, be read and be stepped through several times;
 * short enough that an agent that died mid-turn frees its worker before a
 * person notices. Renewing is one call.
 */
export const DEFAULT_HOLD_MS = 120_000
export const MAX_HOLD_MS = 600_000

export interface WorkerPool {
  status(): WorkerStatus[]
  /** How many leases are out right now, after expiry has been swept. */
  outstanding(): number
  lease(input: { holder: string; profileId?: string | null; holdMs?: number }): LeaseAnswer
  release(input: { holder: string; profileId: string }): boolean
  renew(input: { holder: string; profileId: string; holdMs?: number }): boolean
  /** Every lease this holder has, let go at once. For a session that ended. */
  releaseAll(holder: string): number
  /**
   * Drop everything the pool remembers about one worker, whoever holds it.
   *
   * The one place a lease is taken away without its holder's say-so, and it is
   * not a force-release: it is for a worker that has **left the pool**. Without
   * it, unregistering a busy worker would leave a lease in the table that no
   * longer appears in {@link WorkerPool.status} — invisible, and still counting
   * against `maxConcurrent` forever. A limit that silently shrinks by one every
   * time a row is removed is the kind of fault that gets diagnosed as "the app
   * is slow" months later.
   */
  forget(profileId: string): void
  /** For tests, and for a profile store that was reloaded from disk. */
  reset(): void
}

export function createWorkerPool(deps: PoolDeps): WorkerPool {
  /** profileId → lease. Memory only. */
  const leases = new Map<string, Lease>()
  /** profileId → when it was last let go, so the pace can be per worker. */
  const released = new Map<string, number>()

  /**
   * Drop every lease whose deadline has passed.
   *
   * Called at the top of every method rather than on a timer, because a timer
   * that fires in a process nobody is asking questions of has changed nothing
   * anybody can observe — and a timer is one more thing that can hold the
   * process open at quit. The observable behaviour is identical and there is
   * nothing to unref.
   */
  function sweep(): void {
    const now = deps.now()
    for (const [profileId, lease] of leases) {
      if (lease.expiresAt <= now) {
        leases.delete(profileId)
        // An expired lease still counts as a release for pacing. The worker did
        // its work; what failed was the holder saying so.
        released.set(profileId, now)
      }
    }
  }

  function readyIn(profileId: string, now: number): number {
    const last = released.get(profileId)
    if (last === undefined) return 0
    // The *floor* here, not the jitter: this is what a screen shows, and a
    // number that changed every time it was read would be unreadable. The
    // jitter is added at the moment a lease is actually granted.
    return Math.max(0, last + deps.pace().minDelayMs - now)
  }

  return {
    status(): WorkerStatus[] {
      sweep()
      const now = deps.now()
      return deps.workers().map((worker) => {
        const lease = leases.get(worker.profileId)
        return {
          profileId: worker.profileId,
          name: worker.name,
          busy: lease !== undefined,
          holder: lease?.holder ?? '',
          heldMs: lease === undefined ? 0 : Math.max(0, now - lease.takenAt),
          lastReleasedAt: released.get(worker.profileId) ?? 0,
          readyInMs: readyIn(worker.profileId, now),
        }
      })
    },

    outstanding(): number {
      sweep()
      return leases.size
    },

    /**
     * Take a worker, or say exactly why not.
     *
     * The order of the refusals is the order a caller can act on:
     *
     *  1. there are no workers at all — mint some;
     *  2. the concurrency limit is reached — wait, or raise it;
     *  3. a *named* worker is taken — wait, or do not name one;
     *  4. every worker is taken — wait.
     *
     * Collapsing (2) and (4) would be the more compact code and the worse
     * answer: "raise the limit" and "wait" are different actions, and a caller
     * told the wrong one either spins or edits a setting that was not the
     * problem.
     *
     * The wait comes back with the lease rather than being enforced here,
     * because this function is synchronous and a delay that a caller may skip
     * is not a delay. `browser-workers.ts` is where it is awaited.
     */
    lease(input): LeaseAnswer {
      sweep()
      const workers = deps.workers()
      if (workers.length === 0) return { ok: false, reason: 'no-workers' }

      const pace = deps.pace()
      if (leases.size >= pace.maxConcurrent) return { ok: false, reason: 'at-capacity' }

      let chosen: PoolWorker | undefined
      if (input.profileId) {
        chosen = workers.find((worker) => worker.profileId === input.profileId)
        if (!chosen) return { ok: false, reason: 'unknown-worker' }
        if (leases.has(chosen.profileId)) return { ok: false, reason: 'busy' }
      } else {
        /*
         * The one that has been idle longest, not the first free one.
         *
         * Round-robin is the whole reason a pool beats a profile: taking the
         * lowest-numbered free worker every time means worker 1 does most of
         * the traffic and workers 5 to 8 are cold, which is both slower and a
         * more recognisable pattern than spreading it.
         */
        const free = workers.filter((worker) => !leases.has(worker.profileId))
        if (free.length === 0) return { ok: false, reason: 'all-busy' }
        chosen = free.reduce((best, worker) =>
          (released.get(worker.profileId) ?? 0) < (released.get(best.profileId) ?? 0) ? worker : best,
        )
      }

      const now = deps.now()
      const holdMs = clamp(num(input.holdMs, DEFAULT_HOLD_MS), 1_000, MAX_HOLD_MS)
      const lease: Lease = {
        profileId: chosen.profileId,
        holder: input.holder,
        takenAt: now,
        expiresAt: now + holdMs,
      }
      leases.set(chosen.profileId, lease)
      deps.changed?.()

      const last = released.get(chosen.profileId)
      const waitMs =
        last === undefined
          ? 0
          : Math.max(0, last + jitteredDelay(pace, deps.random()) - now)
      return { ok: true, lease, waitMs }
    },

    /**
     * Let a worker go. False when this holder was not the one holding it.
     *
     * The holder is checked rather than trusted, and the check is what makes a
     * pool shared between several agents safe to hand out: without it, agent B
     * releasing `worker-3` would free a worker agent A is mid-page on, and the
     * two would then be driving the same cookie jar. There is no force-release
     * on this interface at all; the deadline is the only thing that takes a
     * worker away from a holder that has not let go.
     */
    release(input): boolean {
      sweep()
      const lease = leases.get(input.profileId)
      if (!lease || lease.holder !== input.holder) return false
      leases.delete(input.profileId)
      released.set(input.profileId, deps.now())
      deps.changed?.()
      return true
    },

    renew(input): boolean {
      sweep()
      const lease = leases.get(input.profileId)
      if (!lease || lease.holder !== input.holder) return false
      const holdMs = clamp(num(input.holdMs, DEFAULT_HOLD_MS), 1_000, MAX_HOLD_MS)
      lease.expiresAt = deps.now() + holdMs
      return true
    },

    releaseAll(holder): number {
      sweep()
      let count = 0
      const now = deps.now()
      for (const [profileId, lease] of leases) {
        if (lease.holder !== holder) continue
        leases.delete(profileId)
        released.set(profileId, now)
        count += 1
      }
      if (count > 0) deps.changed?.()
      return count
    },

    forget(profileId): void {
      const held = leases.delete(profileId)
      const paced = released.delete(profileId)
      if (held || paced) deps.changed?.()
    },

    reset(): void {
      const had = leases.size > 0 || released.size > 0
      leases.clear()
      released.clear()
      if (had) deps.changed?.()
    },
  }
}

/* ------------------------------------------------------------ the refusal -- */

/**
 * The sentence a refusal becomes.
 *
 * Written here rather than at the two call sites so the panel and the tool say
 * the same thing about the same state — two spellings of one refusal is how one
 * of them comes to describe a rule that changed.
 */
export function leaseRefusalLine(reason: LeaseRefusal, pace: PaceSettings): string {
  switch (reason) {
    case 'no-workers':
      return 'there are no worker profiles yet. Open the browser’s profile menu and add some in Workers.'
    case 'at-capacity':
      return `${pace.maxConcurrent} workers are already out, which is the limit this browser is set to. Release one, or raise the limit in Workers.`
    case 'all-busy':
      return 'every worker is out. Release one when its page is done.'
    case 'busy':
      return 'that worker is out with somebody else. Ask for any worker instead of naming one.'
    case 'unknown-worker':
      return 'there is no worker by that name.'
  }
}
