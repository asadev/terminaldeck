import { slotName, windowsOf } from '../browser-binding'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused } from './surface'

/**
 * The two worker verbs, and — much more importantly — the one that is not here.
 *
 * ## What an agent is given
 *
 * A pool of worker profiles is only useful to something outside the app if that
 * something can ask two questions: *which worker is free*, and *how long must I
 * wait*. Asad's boundary for the whole round is the reason there is nothing
 * else:
 *
 *   > *"Don't build a full scraping framework inside a terminal app. The
 *   > browser should expose these capabilities cleanly; the orchestration can
 *   > live outside."*
 *
 * So: `browser.workers` lists them and `browser.worker` takes and releases one.
 * There is no crawl, no queue, no retry and no notion of a job on this surface.
 *
 * ## What an agent is not given, and why
 *
 * **There is no tool that lifts a session.** Copying a signed-in session out of
 * one profile and into others is the single most dangerous capability in this
 * feature — a tool that does it is a tool that exfiltrates a login — and the
 * whole design turns on it being a **human gesture**: a button in the browser
 * panel, on the page the person is looking at, in `browser-workers-ipc.ts`,
 * behind an `ipcMain` channel that this surface cannot reach.
 *
 * An agent that needs a login **asks**, and it already has the verb for it:
 * `browser.handover` raises a banner over the page with one line of the agent's
 * text on it, hands the baton to the person and shuts the agent out of reads as
 * well as writes while they have it. That is the ask, it surfaces where the
 * person is looking, and it is the thing they answer by signing in and pressing
 * Lift. Adding a `browser.lift` beside it would replace a gesture with a
 * request an agent can make in a retry loop.
 *
 * ## What the list discloses, and why that is the right line
 *
 * `browser.workers` names the worker, says whether it is busy, says which of the
 * caller's own windows is currently showing a page in that worker's jar, and
 * says **which hosts that worker has been signed into during this run**. That
 * last one is a fact about the person's browsing, so it is worth being explicit
 * about why it is here rather than withheld:
 *
 *  - It is the difference between an agent driving eight signed-in pages and an
 *    agent driving eight signed-out ones and reporting the results of neither.
 *    A worker that looks identical whether or not the injection worked is the
 *    dead control this whole round is about.
 *  - It is a host name, never a cookie name and never a value. Nothing on this
 *    surface can read a cookie: `browser-cdp.ts` denies `Network.getCookies`,
 *    `Storage.getCookies` and `Runtime.evaluate` outright, and there is no
 *    Electron path to a jar from here.
 *  - The caller already has the person's word for it. A session only sees a
 *    worker's window if the person attached that window to *this* session, and
 *    a page it can see is a page it can already read.
 */

/* --------------------------------------------------------------- the deps -- */

/**
 * Everything these tools need from the app, handed in.
 *
 * A parameter object rather than imports so the whole surface is driven from a
 * test with no Electron: `index.ts` closes over the real functions in
 * `browser-workers-ipc.ts`. It is the shape `browserTools(drive)` already uses
 * and for the same reason.
 */
export interface WorkerToolDeps {
  list(): {
    profileId: string
    name: string
    partition: string
    busy: boolean
    holder: string
    readyInMs: number
  }[]
  pace(): { maxConcurrent: number; minDelayMs: number; jitterMs: number }
  /** Which worker a live view is showing, or null. */
  workerOfView(viewId: string): { profileId: string; name: string } | null
  /** Hosts a worker has been signed into this run. Never values. */
  injectionsFor(partition: string): { host: string; at: number }[]
  take(input: {
    holder: string
    profileId?: string | null
    holdMs?: number
  }): Promise<{ ok: true; profileId: string; name: string; pacedMs: number; expiresAt: number } | { ok: false; reason: string }>
  release(input: { holder: string; profileId: string }): boolean
  renew(input: { holder: string; profileId: string; holdMs?: number }): boolean
}

/* ------------------------------------------------------------- the callers -- */

/**
 * Who holds a lease.
 *
 * A session's id, or the copilot. It is the key the pool checks on release, so
 * two agents cannot free each other's workers — see
 * `browser-worker-pool.ts`'s `release`.
 */
function holderOf(context: ToolContext): string {
  const caller = context.caller
  if (caller.kind === 'session' && caller.sessionId !== undefined) {
    return `session:${caller.machineId ?? ''}:${caller.sessionId}`
  }
  return 'copilot'
}

function callingSession(context: ToolContext): { sessionId: string; machineId: string } | null {
  const caller = context.caller
  if (caller.kind !== 'session' || caller.sessionId === undefined) return null
  return { sessionId: caller.sessionId, machineId: caller.machineId ?? '' }
}

/**
 * The same refusal `browser-tools.ts` applies, for the same two reasons.
 *
 * A paired device driving this Mac's browser is refused everywhere in this
 * feature, and a routine at 03:00 taking a worker holding his logins is the
 * shape `not-permitted-unattended` exists for. Repeated here rather than
 * imported because these tools are contributed separately and a shared helper
 * that one of them forgot to call would be a gate with a hole in it — the same
 * judgement that file makes about writing `mayDrive` out per tool.
 */
function mayUseWorkers(context: ToolContext, tool: string): void {
  if (callingSession(context) === null && context.caller.kind !== 'local') {
    throw new Refused(
      'not-granted',
      `${tool} only works for the person at this machine. Driving a browser from a paired device is not ` +
        'something this app does. Say what you would have done and let them do it.',
    )
  }
  if (context.attended === false) {
    throw new Refused(
      'not-permitted-unattended',
      `${tool} takes a browser profile that holds the person's logins, and there is nobody at the machine ` +
        'to watch it. Do not retry and do not look for another way. Say in your report what you would have run.',
    )
  }
}

/**
 * Which of the caller's own windows is showing a page in each worker's jar.
 *
 * Only the caller's windows, always — for a session that is `windowsOf(its own
 * id)`, and for the copilot it is nothing, because the copilot's tab is not in
 * anybody's binding. So a session cannot learn that a *different* session has a
 * window in a worker, which is the same line `windowNamed` draws one file over.
 *
 * **Read live, on every call, and it can change underneath the answer.** A
 * window shows one page at a time and the person can switch the tab in it, so
 * `B2` being worker 3 is a fact about this moment. That is stated in the tool's
 * description rather than papered over: an agent that re-reads gets the truth,
 * and an agent that caches the mapping for an hour deserves to be told it might
 * be stale.
 */
function windowsByWorker(deps: WorkerToolDeps, context: ToolContext): Map<string, string> {
  const owner = callingSession(context)
  const out = new Map<string, string>()
  if (owner === null) return out
  for (const window of windowsOf(owner.sessionId, owner.machineId)) {
    if (window.viewId === null) continue
    const worker = deps.workerOfView(window.viewId)
    if (worker === null) continue
    // First one wins: two windows on the same worker is a real arrangement and
    // the lower slot is the one a person says first.
    if (!out.has(worker.profileId)) out.set(worker.profileId, slotName(window.n))
  }
  return out
}

/**
 * What to say to a caller that can see a worker and cannot drive one.
 *
 * Two callers, two different truths, and printing the session's sentence at the
 * copilot would be advice it cannot act on — *"ask the person to attach that
 * window"* means nothing to a caller that has no binding to attach one to. The
 * copilot's own pane is deliberately not a bound window (`openBarePane`), so
 * worker profiles are simply not something it drives, and saying so is better
 * than sending it looking for a door that is not there.
 */
function noWindowLine(context: ToolContext, one: boolean): string {
  if (callingSession(context) === null) {
    return one
      ? 'The hold is yours, but a worker profile is driven from a session’s own browser window and the copilot’s tab is not one. Ask a session to drive it, or say what you would have done.'
      : 'None of these can be driven from here: a worker profile is driven from a session’s own browser window, and the copilot’s tab is not one.'
  }
  return one
    ? 'This worker has no window of yours showing a page in it, so you cannot drive it yet. Ask the person to open a page in it and attach that window; the hold is yours in the meantime.'
    : 'None of these has a window attached to you, so none can be driven yet. Ask the person to open a page in a worker and attach that window.'
}

/* ------------------------------------------------------------- the schemas -- */

const LIST_SCHEMA: JsonSchema = { type: 'object', properties: {}, additionalProperties: false }

const ACTIONS = ['take', 'release', 'renew'] as const
type Action = (typeof ACTIONS)[number]

const WORKER_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: {
      type: 'string',
      enum: [...ACTIONS],
      description:
        'take: hold one worker and serve its wait before answering. release: hand it back. renew: keep it a while longer.',
    },
    worker: {
      type: 'string',
      description:
        'The worker’s name, from browser.workers. Omit on take to be given whichever has been idle longest.',
    },
    holdMs: {
      type: 'number',
      description: 'How long the hold lasts before it lapses on its own. Default 120000, max 600000.',
    },
  },
  required: ['action'],
  additionalProperties: false,
}

function actionOf(args: Record<string, unknown>): Action {
  const raw = args.action
  if (typeof raw !== 'string' || !ACTIONS.includes(raw as Action)) {
    throw new Refused('not-permitted', `action must be one of: ${ACTIONS.join(', ')}`)
  }
  return raw as Action
}

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

/**
 * A worker named by the name a person reads, not by a uuid.
 *
 * The id is a partition uuid that appears on no screen anywhere; making an
 * agent quote one would mean the tool's vocabulary and the panel's were
 * different, which is how *"B2"* and *"the second window"* became two things.
 * Names are unique in practice (`Worker 1`, `Worker 2`) and a duplicate is
 * resolved to the first, which is what a person pointing at a list would mean.
 */
function findWorker(deps: WorkerToolDeps, name: string | null) {
  if (name === null) return null
  const wanted = name.trim().toLowerCase()
  return (
    deps.list().find((worker) => worker.name.toLowerCase() === wanted) ??
    deps.list().find((worker) => worker.profileId === name) ??
    null
  )
}

/* --------------------------------------------------------------- the tools -- */

export function workerTools(deps: WorkerToolDeps): ToolSpec[] {
  const listTool: ToolSpec = {
    id: 'browser.workers',
    wire: 'browser_workers',
    tier: 'read',
    title: 'List the browser’s worker profiles',
    description:
      'The worker profiles this browser has, each with its own cookie jar: which are free, which of your ' +
      'windows is showing a page in each one right now, which sites each has been signed into this run, ' +
      'and how many may run at once. A worker with no window of yours cannot be driven — the person opens ' +
      'a page in it and attaches the window. Nothing here reads a cookie or a value.',
    inputSchema: LIST_SCHEMA,
    summary: () => 'List the browser’s worker profiles',
    run: async (_args, context): Promise<ToolOutput> => {
      mayUseWorkers(context, 'browser.workers')
      const slots = windowsByWorker(deps, context)
      const holder = holderOf(context)
      const pace = deps.pace()
      const workers = deps.list().map((worker) => ({
        name: worker.name,
        busy: worker.busy,
        yours: worker.busy && worker.holder === holder,
        window: slots.get(worker.profileId) ?? null,
        readyInMs: worker.readyInMs,
        signedInFor: deps.injectionsFor(worker.partition).map((entry) => entry.host),
      }))
      const drivable = workers.filter((worker) => worker.window !== null).length
      return {
        value: {
          workers,
          maxConcurrent: pace.maxConcurrent,
          minDelayMs: pace.minDelayMs,
          jitterMs: pace.jitterMs,
          /*
           * Said in a sentence as well as in the fields, because the state that
           * matters most here — "there are eight workers and you can drive
           * none of them" — is one an agent reads straight past when it is a
           * `window: null` on every row.
           */
          note:
            workers.length === 0
              ? 'There are no worker profiles yet. The person adds them in the browser’s profile menu, under Workers.'
              : drivable === 0
                ? noWindowLine(context, false)
                : `${drivable} of ${workers.length} can be driven from your windows.`,
        },
        summary: { workers: workers.length, drivable },
      }
    },
  }

  const workerTool: ToolSpec = {
    id: 'browser.worker',
    wire: 'browser_worker',
    /*
     * `act` rather than `read`, and it is not a formality.
     *
     * Taking a worker changes what every other agent on this machine sees —
     * it is the thing that stops two of them driving one cookie jar — and
     * `take` blocks for as long as the pace says. A tool that waits and that
     * others can observe is not a read.
     */
    tier: 'act',
    title: 'Take or release a worker profile',
    description:
      'take holds one worker and does not answer until its wait has been served, so the gap between ' +
      'requests is real rather than something you have to remember. release hands it back. renew keeps a ' +
      'long piece of work from lapsing. A hold lapses on its own if you stop renewing it, so a worker is ' +
      'never stuck because an agent went away.',
    inputSchema: WORKER_SCHEMA,
    precheck: (args, context) => {
      mayUseWorkers(context, 'browser.worker')
      const action = actionOf(args)
      if (action !== 'take' && optStr(args, 'worker') === null) {
        throw new Refused('not-permitted', `${action} needs the worker it is about`)
      }
    },
    summary: (args) => {
      const action = actionOf(args)
      const name = optStr(args, 'worker')
      return action === 'take'
        ? `Take ${name ?? 'a free'} browser worker`
        : `${action === 'release' ? 'Release' : 'Renew'} browser worker ${name ?? '?'}`
    },
    run: async (args, context): Promise<ToolOutput> => {
      const action = actionOf(args)
      const holder = holderOf(context)
      const name = optStr(args, 'worker')
      const holdMs = typeof args.holdMs === 'number' ? args.holdMs : undefined

      if (action === 'take') {
        const named = findWorker(deps, name)
        if (name !== null && named === null) {
          throw new Refused('not-permitted', 'there is no worker by that name. browser.workers lists them.')
        }
        const answer = await deps.take({
          holder,
          profileId: named?.profileId ?? null,
          ...(holdMs === undefined ? {} : { holdMs }),
        })
        if (!answer.ok) throw new Refused('not-permitted', answer.reason)
        const slots = windowsByWorker(deps, context)
        const window = slots.get(answer.profileId) ?? null
        return {
          value: {
            worker: answer.name,
            /*
             * The window as it is **now**. A window shows one page at a time
             * and the person can switch it, so this is a fact about this
             * moment rather than a binding. Re-read browser.workers if a page
             * does not look like the one you expected.
             */
            window,
            pacedMs: answer.pacedMs,
            expiresAt: answer.expiresAt,
            signedInFor: deps
              .injectionsFor(deps.list().find((one) => one.profileId === answer.profileId)?.partition ?? '')
              .map((entry) => entry.host),
            note:
              window === null
                ? noWindowLine(context, true)
                : `Drive ${window}. Release the worker when the page is done.`,
          },
          summary: { worker: answer.name, pacedMs: answer.pacedMs, ...(window === null ? {} : { window }) },
        }
      }

      const found = findWorker(deps, name)
      if (found === null) {
        throw new Refused('not-permitted', 'there is no worker by that name. browser.workers lists them.')
      }
      const ok =
        action === 'release'
          ? deps.release({ holder, profileId: found.profileId })
          : deps.renew({ holder, profileId: found.profileId, ...(holdMs === undefined ? {} : { holdMs }) })
      if (!ok) {
        /*
         * One sentence for "you never held it" and for "it lapsed while you
         * were away", because they are the same thing to act on — take it
         * again — and because the difference is not worth a second branch a
         * model has to reason about.
         */
        throw new Refused(
          'not-permitted',
          `${found.name} is not held by you. It may have lapsed while you were away — take it again.`,
        )
      }
      return {
        value: { worker: found.name, [action === 'release' ? 'released' : 'renewed']: true },
        summary: { worker: found.name },
      }
    },
  }

  return [listTool, workerTool]
}
