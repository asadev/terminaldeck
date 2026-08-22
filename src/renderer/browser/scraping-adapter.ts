/**
 * The join between the scraping panel and the engines that were built beside it.
 *
 * ## Why this file exists at all
 *
 * `scraping-bridge.ts` was written as a contract: sixteen optional methods named
 * `browserScraping*`, one group per lane, declared before any lane had landed.
 * Four lanes then landed — worker profiles and the session lift, passive
 * capture, byte-exact assets, and the tools store — and every one of them
 * registered its channels under **its own** names. `grep -c browserScraping
 * src/preload/index.ts` answers `0`. So the panel drew seven sections that were
 * honest and useless: named, correct, and unavailable to a person on a build
 * where the capability was sitting right there.
 *
 * This module is the adapter that closes that. It takes the preload as it
 * actually is and answers in the shape the panel's readers already narrow, so
 * the join is one file rather than a rewrite of a panel whose rendering and
 * whose types were right.
 *
 * ## What it does not do
 *
 * **It invents nothing.** Where an engine counts, the count travels; where no
 * engine counts, the field is `null` and the panel prints *"not measured"*. The
 * pool leases workers and has never counted a worker's requests, so
 * `requests` here is `null` on every row and says so on screen — not `0`, which
 * would be a measurement nobody made. Three sections — Requests, Capture,
 * Assets — and the coverage check have no renderer-reachable engine at all
 * today, so this file deliberately supplies **nothing** for them and they go on
 * drawing as unavailable. A seam filled with a plausible answer is worse than a
 * seam left open, which is the whole argument of the panel it serves.
 *
 * ## And the one rule it is built around
 *
 * The session lift is a human gesture. `browser-worker:lift` is an `ipcMain`
 * channel reachable from this app's own window and from nowhere else, and
 * `deck-control/session-tools.ts` records at length why no tool may call it.
 * Nothing here widens that: {@link adaptScrapingApi} calls it from exactly one
 * place, and that place is reached from one button a person armed and pressed.
 *
 * The ask-inbox seams (`browserScrapingLiftRequests` and its answer) were left
 * unwired here until 2026-08-22, on the argument that a channel behind them
 * would be "the path around the gesture". That defended the wrong thing. An
 * inbox is not a path around a gesture — it is how the gesture stays one when
 * something that is not a person wants it: the agent's ask becomes a row with
 * Approve and Decline, and the lift still runs only in the main process, on
 * the person's armed press (`browser-lift-requests.ts` holds the desk and the
 * whole argument). What the unwired seam actually produced was the panel's
 * approvals branch rendering against methods that could never exist — a
 * control drawn and unable to fire, the exact prohibited shape. So the three
 * seams are wired below, to the real channels.
 */

import type {
  ScrapingApi,
  ScrapingConfigPatch,
  ScrapingOutcome,
  ToolIdentity,
} from './scraping-bridge'
import {
  readInjectAnswer,
  readLiftAnswer,
  readWorkersView,
  resolveWorkersApi,
  type InjectReport,
  type LiftSummary,
  type WorkersApi,
  type WorkersView,
} from './workers-bridge'

/* ----------------------------------------------------------------- context -- */

/**
 * What the adapter needs from the surface around it, and cannot read itself.
 *
 * One thing: the main-process id of the page in front of the person. It is not
 * a convenience — it is what makes the lift a gesture *on a page they are
 * looking at* rather than an action against a profile named in a dropdown. The
 * workspace holds it; a bridge resolved off `window.deck` cannot.
 */
export interface ScrapingHostContext {
  /** The active tab's main-process id, or `''` when no page is open. */
  viewId(): string
}

/* ------------------------------------------------------------------ store -- */

/** The three store methods the preload actually exposes. */
interface StoreApi {
  browserStore?(): Promise<unknown>
  browserStoreInstall?(id: string): Promise<unknown>
  browserStoreRemove?(id: string): Promise<unknown>
}

const STORE_METHODS = ['browserStore', 'browserStoreInstall', 'browserStoreRemove'] as const

function resolveStoreApi(source: object): StoreApi {
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of STORE_METHODS) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as StoreApi
}

/**
 * One line per grant, mirroring `GRANT_WORDS` in
 * `src/main/browser-store-recipe.ts`.
 *
 * A second copy for the reason `NEW_TAB_LABEL` is one: the renderer's tsconfig
 * does not include `src/main`, so a user-visible string that has to be the same
 * on both sides is duplicated and then **pinned equal by a test that reads the
 * other one off disk**. `scraping-adapter.test.ts` does that pinning.
 *
 * A grant this build has no words for is passed through under its own name
 * rather than dropped. Dropping it would understate what a tool reaches, on the
 * one row in this app whose entire job is to state that before the code lands.
 */
export const GRANT_WORDS: Readonly<Record<string, string>> = Object.freeze({
  'page-read': 'Reads the page you point it at',
})

/** Where a tool says it runs, in a phrase. */
export function originsLine(origins: readonly string[]): string {
  if (origins.length === 0) return ''
  if (origins.includes('*')) return 'Runs on any site'
  return `Runs on ${origins.join(', ')}`
}

/**
 * Everything a store row promises to touch, before it is on disk.
 *
 * Grants first because they are the capability, then where it may use it. Both
 * come off the catalogue entry, which is compiled into the app — see
 * `browser-store-catalogue.ts` for why the table is not fetched.
 */
export function reachOf(grants: readonly string[], origins: readonly string[]): string[] {
  const out = grants.map((grant) => GRANT_WORDS[grant] ?? grant)
  const where = originsLine(origins)
  if (where !== '') out.push(where)
  return out
}

/**
 * Is this the tool it claims to be?
 *
 * The four answers mean four different things and the mapping is the whole of
 * this function's honesty:
 *
 *  - **installed** → `verified`. `browser-store.ts` re-hashes the file on disk
 *    against the digest pinned in this app's own bytes every time it builds the
 *    view. The row is not remembering a check; the check just ran.
 *  - **damaged** → `mismatch`. In all three ways a tool is damaged — the file
 *    would not read, the digest did not match, the recipe would not parse — what
 *    is on disk is not a usable copy of what the listing signed.
 *  - **available with a pinned digest** → `verified`. The signature exists, in
 *    the app's own bytes, and `install()` refuses anything that does not hash to
 *    it before a byte is written. That is what the panel's Install is allowed to
 *    stand on.
 *  - **available with no usable digest** → `unverified`: no signature was
 *    offered. `digestMatches` would refuse it anyway, so an Install drawn here
 *    would be a control that cannot work.
 *
 * `unknown` is left for the orphan rows below — a directory this build has no
 * listing for at all, and therefore nothing to check against.
 */
export function identityOf(state: string, digest: string): ToolIdentity {
  if (state === 'installed' || state === 'outdated') return 'verified'
  if (state === 'damaged') return 'mismatch'
  return /^[0-9a-f]{64}$/i.test(digest) ? 'verified' : 'unverified'
}

function text(record: Record<string, unknown>, key: string): string {
  const value = record[key]
  return typeof value === 'string' ? value : ''
}

function strings(raw: unknown): string[] {
  return Array.isArray(raw) ? raw.filter((one): one is string => typeof one === 'string' && one !== '') : []
}

/**
 * `browser-store:list` as the panel's Store section reads it.
 *
 * Two kinds of row come out of one answer. The catalogue rows are the store;
 * the **orphans** are directories on disk with no listing left in this build —
 * a tool withdrawn between releases — and they are drawn rather than tidied
 * away, because a file this app wrote and can no longer name is a file nobody
 * has any other way to delete. They carry `installed: true` so the row offers
 * Remove, and `unknown` because there is nothing left to check them against.
 */
export function readStoreListings(raw: unknown): unknown[] {
  if (typeof raw !== 'object' || raw === null) return []
  const answer = raw as Record<string, unknown>
  const view = typeof answer.view === 'object' && answer.view !== null
    ? (answer.view as Record<string, unknown>)
    : {}
  const out: unknown[] = []
  for (const entry of Array.isArray(view.tools) ? view.tools : []) {
    if (typeof entry !== 'object' || entry === null) continue
    const tool = entry as Record<string, unknown>
    const id = text(tool, 'id')
    if (id === '') continue
    const state = text(tool, 'state')
    const digest = text(tool, 'sha256')
    out.push({
      id,
      name: text(tool, 'name'),
      version: text(tool, 'version'),
      /*
       * The catalogue names no publisher, so this one does not either. Putting
       * the homepage's host here would read as "who wrote this" on a row whose
       * whole purpose is that nothing on it is the app's own opinion.
       */
      publisher: '',
      reach: reachOf(strings(tool.grants), strings(tool.origins)),
      installed: state !== '' && state !== 'available',
      identity: identityOf(state, digest),
      digest,
    })
  }
  for (const id of strings(answer.orphans)) {
    out.push({
      id,
      name: id,
      version: '',
      publisher: '',
      reach: [],
      installed: true,
      identity: 'unknown',
      digest: '',
    })
  }
  return out
}

/* ---------------------------------------------------------------- workers -- */

/**
 * The fleet, as a scraping configuration.
 *
 * Only `fleet` is filled. The other four groups are absent rather than empty
 * objects, which is what makes `readScrapingConfig` leave them `null` and the
 * panel draw Requests, Capture, Assets and Checks as unavailable — the true
 * answer on this build, and the one those sections are written to give.
 *
 * The pace is browser-wide, which is why the Workers head already says "This
 * browser": a list of profiles cannot itself be per profile.
 */
export function configOf(view: WorkersView): unknown {
  return {
    fleet: {
      profileIds: view.workers.map((worker) => worker.profileId),
      concurrency: view.pace.maxConcurrent,
      delayMs: view.pace.minDelayMs,
    },
  }
}

/**
 * The fleet, as measured state.
 *
 * `requests` is `null` on every row and that is not an oversight: the pool in
 * `browser-worker-pool.ts` counts leases and waits, and has never counted a
 * worker's requests. `0` there would be a number nobody measured printed beside
 * a worker that has been hammering a site all morning, which is the exact shape
 * of report this panel exists to refuse.
 *
 * `busy` becomes `idle` rather than `starting`: a worker profile is a partition
 * on disk, so "not busy" means free to be leased right now, which is a fact and
 * not a claim about a process.
 */
export function statusOf(view: WorkersView): unknown {
  return {
    workers: view.workers.map((worker) => ({
      id: worker.partition,
      profileId: worker.profileId,
      state: worker.busy ? 'busy' : 'idle',
      requests: null,
      lastAt: worker.lastReleasedAt > 0 ? worker.lastReleasedAt : null,
    })),
  }
}

/** A sentence from an engine, with its first letter raised. */
function sentence(raw: string): string {
  const line = raw.trim()
  if (line === '') return ''
  return `${line.charAt(0).toUpperCase()}${line.slice(1)}${/[.!?]$/.test(line) ? '' : '.'}`
}

/**
 * What a finished lift says, beyond the count the panel prints itself.
 *
 * Deliberately no cookie count in here — the panel prints one from
 * {@link ScrapingOutcome.count} and two of them in one sentence read as two
 * different measurements. What this adds is the part a count cannot carry: the
 * site and the account it came from, and every note the injection made about
 * something that did **not** land — keys queued rather than written, cookies
 * Chromium refused. `injectLift` writes those notes precisely so a worker that
 * looks signed in and is not cannot pass silently.
 */
export function liftMessage(summary: LiftSummary, reports: readonly InjectReport[]): string {
  const head = `${summary.host}, from ${summary.sourceProfileName}.`
  const notes: string[] = []
  for (const report of reports) {
    const note = sentence(report.note)
    if (note !== '' && !notes.includes(note)) notes.push(note)
  }
  return notes.length === 0 ? head : `${head} ${notes.join(' ')}`
}

function refusal(message: string): ScrapingOutcome {
  return { ok: false, message, count: null }
}

/* ---------------------------------------------------------------- the join -- */

/**
 * Everything the panel asks for that this build can actually answer.
 *
 * Returned as a partial rather than a whole `ScrapingApi`, because what is
 * missing from it is the point: `resolveScrapingApi` lays these under any real
 * `browserScraping*` the preload grows later, and the availability predicates
 * in `scraping-bridge.ts` then turn each absence into a named, unavailable
 * section instead of a control that does nothing.
 */
export function adaptScrapingApi(source: object, context?: ScrapingHostContext): Partial<ScrapingApi> {
  const workers: WorkersApi = resolveWorkersApi(source)
  const store = resolveStoreApi(source)
  const api: Partial<ScrapingApi> = {}

  const list = workers.browserWorkers
  const pace = workers.browserWorkerPace
  const register = workers.browserWorkerRegister
  const unregister = workers.browserWorkerUnregister
  const ensure = workers.browserWorkersEnsure
  const lift = workers.browserWorkerLift
  const inject = workers.browserWorkerInject
  const forget = workers.browserWorkerForgetLift

  /* -- the configuration: the fleet, and nothing else this build stores --- */

  if (list && pace) {
    api.browserScrapingConfig = async (): Promise<unknown> => {
      const view = readWorkersView(await list())
      return view === null ? null : configOf(view)
    }

    api.browserScrapingConfigSet = async (
      _profileId: string,
      patch: ScrapingConfigPatch,
    ): Promise<unknown> => {
      const fleet = patch.fleet
      // Anything but the fleet is a group nothing here stores. Answering `null`
      // makes the panel say the change was not confirmed rather than draw it as
      // stored — and those sections are unavailable, so no such patch can
      // legitimately arrive at all.
      if (!fleet) return null
      if (fleet.concurrency === undefined && fleet.delayMs === undefined) return null
      const current = readWorkersView(await list())
      if (current === null) return null
      const stored = readWorkersView(
        await pace({
          maxConcurrent: fleet.concurrency ?? current.pace.maxConcurrent,
          minDelayMs: fleet.delayMs ?? current.pace.minDelayMs,
          // Untouched: the panel has no jitter field, and sending a zero for a
          // number it never showed would silently wipe a stored setting.
          jitterMs: current.pace.jitterMs,
        }),
      )
      // The clamp travels: `browser-worker:pace` answers with what it *stored*,
      // so a number held at the ceiling comes back held and the field shows it.
      return stored === null ? null : configOf(stored)
    }
  }

  /*
   * The pull, and deliberately no push.
   *
   * `scrapingStatusAvailable` wants both, and nothing in the main process emits
   * a worker event — the pool changes when this panel asks it to, and there is
   * no honest channel to subscribe to. So this build reports `busy` as
   * "not measured" on the fleet line while each row still shows what the last
   * read said. A fabricated push, or a timer pretending to be one, would make
   * every number on the screen as old as the poll and say otherwise.
   */
  if (list) {
    api.browserScrapingStatus = async (): Promise<unknown> => {
      const view = readWorkersView(await list())
      return view === null ? null : statusOf(view)
    }
  }

  /* -- enrolling and retiring, both or neither ---------------------------- */

  if (register && unregister) {
    api.browserScrapingWorkerAdd = async (profileId: string): Promise<unknown> => {
      const view = readWorkersView(await register(profileId))
      return view === null ? null : configOf(view)
    }
    api.browserScrapingWorkerRemove = async (profileId: string): Promise<unknown> => {
      const view = readWorkersView(await unregister(profileId))
      return view === null ? null : configOf(view)
    }
  }

  if (ensure) {
    api.browserScrapingWorkerMint = async (total: number): Promise<unknown> => {
      const view = readWorkersView(await ensure(total))
      return view === null ? null : configOf(view)
    }
  }

  /* -- the lift, which is one gesture made of three calls ----------------- */

  if (lift && inject && context) {
    /**
     * Take the session off the page in front, put it in the named workers, and
     * forget it.
     *
     * Three engine calls behind one press, and each step is a refusal rather
     * than a guess:
     *
     *  - no page open → nothing to take, said in a sentence;
     *  - the page is not signed in as the profile the panel named → the lift is
     *    **discarded and nothing is copied**. This is the one that matters. The
     *    engine lifts from the page, the panel offers a profile picker, and the
     *    two can disagree; copying the wrong account's session into eight
     *    profiles and reporting the one that was asked for would be a lie about
     *    a credential;
     *  - the lift is forgotten as soon as it has been used, so a live session
     *    does not sit in the main process's vault for fifteen minutes after a
     *    gesture that is finished.
     */
    api.browserScrapingLift = async (
      fromProfileId: string,
      intoProfileIds: readonly string[],
    ): Promise<unknown> => {
      const viewId = context.viewId()
      if (viewId === '') {
        return refusal(
          'There is no page open to take a session from. Open the site in this window, sign in, and press this again.',
        )
      }
      const taken = readLiftAnswer(await lift({ viewId }))
      if (!taken.ok) return refusal(sentence(taken.reason))
      const summary = taken.summary
      if (fromProfileId !== '' && summary.sourceProfileId !== fromProfileId) {
        await forget?.(summary.id)
        return refusal(
          `The page in front of you is signed in as ${summary.sourceProfileName}, not the profile chosen here. Nothing was copied — open a page in that profile and press this again.`,
        )
      }
      const put = readInjectAnswer(
        await inject({ liftId: summary.id, profileIds: [...intoProfileIds] }),
      )
      await forget?.(summary.id)
      if (!put.ok) return refusal(sentence(put.reason))
      if (put.reports.length === 0) {
        // "It worked" with no worker named is the shape of success this panel
        // refuses: nothing counted, so nothing here claims one was signed in.
        return refusal('Nothing said which workers it went into, so nothing here claims one was signed in.')
      }
      const count = put.reports.reduce((sum, report) => sum + report.cookiesSet, 0)
      return { ok: true, message: liftMessage(summary, put.reports), count } satisfies ScrapingOutcome
    }
  }

  /* -- the ask inbox ------------------------------------------------------ */

  /*
   * All three or none, because the panel's `liftRequestsAvailable` asks for all
   * three: a list nobody can answer, or an answer with no list to pick from,
   * is half an inbox — and half an inbox is the drawn-but-dead branch this
   * wiring exists to end.
   */
  const asks = workers.browserWorkerLiftRequests
  const answer = workers.browserWorkerLiftAnswer
  const onAsk = workers.onBrowserWorkerLiftRequest
  if (asks && answer && onAsk) {
    api.browserScrapingLiftRequests = async (): Promise<unknown> => asks()
    api.browserScrapingLiftAnswer = async (requestId: string, approve: boolean): Promise<unknown> =>
      answer(requestId, approve)
    api.onBrowserScrapingLiftRequest = (cb: (request: unknown) => void): (() => void) => onAsk(cb)
  }

  /* -- the store ---------------------------------------------------------- */

  if (store.browserStore && store.browserStoreInstall && store.browserStoreRemove) {
    const listTools = store.browserStore
    const install = store.browserStoreInstall
    const remove = store.browserStoreRemove
    api.browserScrapingTools = async (): Promise<unknown> => readStoreListings(await listTools())
    api.browserScrapingToolInstall = async (toolId: string): Promise<unknown> => install(toolId)
    api.browserScrapingToolRemove = async (toolId: string): Promise<unknown> => remove(toolId)
  }

  return api
}
