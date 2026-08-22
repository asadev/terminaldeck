import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { attach, resetForTests } from '../browser-binding'
import { ActionLog } from './action-log'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { SESSION_TOOLS } from './session-tools'
import { ALL_TIERS as ALL, type Caller, type DeckSurface } from './surface'
import { workerTools, type WorkerToolDeps } from './worker-tools'

/**
 * The worker surface, and the tool that is deliberately absent from it.
 *
 * Everything interesting about a worker profile is a fact about Chromium — a
 * partition, a cookie jar — and none of that is here. What is tested is the
 * layer above: who may call these at all, what a caller may learn about another
 * caller's windows, that the wait is served inside the call, and that nothing
 * on this surface can lift a login.
 */

const NOW = 1_800_000_000_000

interface Fake extends WorkerToolDeps {
  taken: unknown[]
  released: unknown[]
  paced: number
  views: Map<string, { profileId: string; name: string }>
}

function fakeDeps(over: Partial<WorkerToolDeps> = {}): Fake {
  const workers = [
    { profileId: 'w1', name: 'Worker 1', partition: 'persist:w1', busy: false, holder: '', readyInMs: 0 },
    { profileId: 'w2', name: 'Worker 2', partition: 'persist:w2', busy: false, holder: '', readyInMs: 0 },
  ]
  const taken: unknown[] = []
  const released: unknown[] = []
  const views = new Map<string, { profileId: string; name: string }>()
  const held = new Map<string, string>()
  const deps: Fake = {
    taken,
    released,
    paced: 1_250,
    views,
    list: () => workers,
    pace: () => ({ maxConcurrent: 2, minDelayMs: 1_000, jitterMs: 500 }),
    workerOfView: (viewId) => views.get(viewId) ?? null,
    injectionsFor: (partition) =>
      partition === 'persist:w1' ? [{ host: 'shop.example.com', at: NOW }] : [],
    take: async (input) => {
      taken.push(input)
      const chosen = input.profileId ?? 'w1'
      held.set(chosen, input.holder)
      const worker = workers.find((one) => one.profileId === chosen)
      if (!worker) return { ok: false, reason: 'there is no worker by that name.' }
      worker.busy = true
      worker.holder = input.holder
      return {
        ok: true,
        profileId: worker.profileId,
        name: worker.name,
        pacedMs: deps.paced,
        expiresAt: NOW + 120_000,
      }
    },
    release: (input) => {
      released.push(input)
      if (held.get(input.profileId) !== input.holder) return false
      held.delete(input.profileId)
      return true
    },
    renew: (input) => held.get(input.profileId) === input.holder,
    ...over,
  }
  return deps
}

function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(deps: WorkerToolDeps, logDir: string): DeckControl {
  return new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: workerTools(deps),
  })
}

const session: Caller = { kind: 'session', sessionId: 's1', machineId: '', tiers: ALL }
const other: Caller = { kind: 'session', sessionId: 's2', machineId: '', tiers: ALL }
const phone: Caller = { kind: 'remote', deviceId: 'd1', tiers: ALL }

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-worker-tools-'))
  resetForTests()
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the tool that is not here', () => {
  it('is the one that copies a login, and the allow-list does not name it', () => {
    /*
     * The most important assertion in this lane.
     *
     * Copying a signed-in session between profiles is the one action in this
     * feature that moves a credential, and the whole design rests on it being a
     * human gesture — a button on the page the person is looking at, behind an
     * `ipcMain` channel this surface cannot reach. A tool beside it would turn
     * that gesture into a request an agent can make in a retry loop.
     */
    for (const id of ['browser.lift', 'browser_lift', 'browser.inject', 'browser_inject']) {
      expect(SESSION_TOOLS.has(id)).toBe(false)
    }
    const ids = workerTools(fakeDeps()).map((tool) => tool.id)
    // `browser.lift_request` is the ask, not the act — it files a row in the
    // person's inbox and moves nothing. The two names above stay forbidden;
    // the ask tool's own suite (lift-ask-tool.test.ts) pins that its run calls
    // only the request desk.
    expect(ids).toEqual(['browser.workers', 'browser.worker', 'browser.lift_request'])
    const source = readFileSync(new URL('./worker-tools.ts', import.meta.url), 'utf8')
    expect(source).not.toContain('liftFromPage')
    expect(source).not.toContain('injectLift')
    // And the ask tool's file touches neither engine either: no lift, no jar.
    const ask = readFileSync(new URL('./lift-ask-tool.ts', import.meta.url), 'utf8')
    expect(ask).not.toContain('liftFromPage')
    expect(ask).not.toContain('injectLift')
    expect(ask).not.toContain('sessionForPartition')
  })

  it('names both spellings of the three that are, so neither is a way round the list', () => {
    for (const id of ['browser.workers', 'browser.worker', 'browser.lift_request']) {
      expect(SESSION_TOOLS.has(id)).toBe(true)
      expect(SESSION_TOOLS.has(id.replace('.', '_'))).toBe(true)
    }
  })
})

/** The smallest call each tool accepts, so a gate is what refuses rather than a schema. */
const ARGS: Record<string, Record<string, unknown>> = {
  browser_workers: {},
  browser_worker: { action: 'take' },
}

describe('who may use a worker at all', () => {
  it.each(['browser_workers', 'browser_worker'])('refuses %s from a paired device', async (tool) => {
    // The same refusal `browser-tools.ts` applies at every one of its five, and
    // for the same reason: a phone that can make this Mac drive a browser
    // holding his logins is a remote primitive with the best possible disguise.
    const deck = control(fakeDeps(), dir)
    const result = await deck.call(tool, ARGS[tool], { caller: phone })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
  })

  it.each(['browser_workers', 'browser_worker'])(
    'refuses %s when nobody is at the machine',
    async (tool) => {
      const deck = control(fakeDeps(), dir)
      const result = await deck.call(tool, ARGS[tool], { attended: false })
      expect(result.ok).toBe(false)
      expect(result.refusal).toBe('not-permitted-unattended')
      // A sentence that stops a retry loop rather than describing a state.
      expect(result.error).toContain('Do not retry')
    },
  )
})

describe('what the list says', () => {
  it('maps a worker to a window only when that window is the caller’s own', async () => {
    /*
     * The disclosure line, and it is the same one `windowNamed` draws. A session
     * sees a worker's window because *the person attached that window to this
     * session*; it must not be able to learn that another session has one, and
     * the two states are indistinguishable in the answer — `window: null`.
     */
    const deps = fakeDeps()
    deps.views.set('view-a', { profileId: 'w1', name: 'Worker 1' })
    attach({ sessionId: 's1', browserTabId: 'tab-a', viewId: 'view-a' })
    const deck = control(deps, dir)

    const mine = await deck.call('browser_workers', {}, { caller: session })
    const rows = (mine.value as { workers: { name: string; window: string | null }[] }).workers
    expect(rows.find((row) => row.name === 'Worker 1')?.window).toBe('B1')
    expect(rows.find((row) => row.name === 'Worker 2')?.window).toBeNull()

    const theirs = await deck.call('browser_workers', {}, { caller: other })
    const others = (theirs.value as { workers: { window: string | null }[] }).workers
    expect(others.every((row) => row.window === null)).toBe(true)
  })

  it('says out loud when nothing can be driven, rather than leaving eight nulls to be read past', async () => {
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_workers', {}, { caller: session })
    const value = result.value as { note: string }
    expect(value.note).toContain('none can be driven yet')
  })

  it('tells the copilot the truth about itself rather than a session’s advice', async () => {
    /*
     * *"Ask the person to attach that window"* means nothing to a caller with no
     * binding to attach one to. The copilot's own pane is deliberately not a
     * bound window, so worker profiles are simply not something it drives —
     * and sending it looking for a door that is not there is how an agent
     * spends a turn learning the app's own advice does not work.
     */
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_workers', {})
    expect((result.value as { note: string }).note).toContain('copilot’s tab is not one')
  })

  it('says there are none when there are none', async () => {
    const deck = control(fakeDeps({ list: () => [] }), dir)
    const result = await deck.call('browser_workers', {}, { caller: session })
    expect((result.value as { note: string }).note).toContain('no worker profiles yet')
  })

  it('names the sites a worker is signed into, and nothing about the cookies', async () => {
    /*
     * A host name, never a cookie name and never a value. It is the difference
     * between an agent driving eight signed-in pages and eight signed-out ones
     * and reporting the results of neither.
     */
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_workers', {}, { caller: session })
    const blob = JSON.stringify(result.value)
    expect(blob).toContain('shop.example.com')
    expect(blob).not.toContain('sessionid')
    expect(blob).not.toContain('cookie')
  })

  it('reads the pace back, so an orchestrator outside the app can shape itself to it', async () => {
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_workers', {}, { caller: session })
    expect(result.value).toMatchObject({ maxConcurrent: 2, minDelayMs: 1_000, jitterMs: 500 })
  })
})

describe('taking one', () => {
  it('reports the wait that was actually served', async () => {
    /*
     * The number comes back because the *browser* served it, inside the call.
     * An agent reading `pacedMs: 0` on every lease has a pace of zero, and that
     * is worth being able to see rather than assume.
     */
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_worker', { action: 'take' }, { caller: session })
    expect(result.ok).toBe(true)
    expect((result.value as { pacedMs: number }).pacedMs).toBe(1_250)
  })

  it('says plainly that a worker with no window of yours cannot be driven yet', async () => {
    // Never a control that looks like it works. The hold is real and the agent
    // is told what is missing and who can supply it.
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_worker', { action: 'take' }, { caller: session })
    const value = result.value as { window: string | null; note: string }
    expect(value.window).toBeNull()
    expect(value.note).toContain('cannot drive it yet')
  })

  it('names the window when there is one', async () => {
    const deps = fakeDeps()
    deps.views.set('view-a', { profileId: 'w1', name: 'Worker 1' })
    attach({ sessionId: 's1', browserTabId: 'tab-a', viewId: 'view-a' })
    const deck = control(deps, dir)
    const result = await deck.call('browser_worker', { action: 'take', worker: 'Worker 1' }, { caller: session })
    expect((result.value as { window: string | null }).window).toBe('B1')
  })

  it('is asked for by the name a person reads, not by a partition uuid', async () => {
    // The tool's vocabulary and the panel's are the same one. Making a model
    // quote a uuid that appears on no screen is how two names for one thing
    // start.
    const deps = fakeDeps()
    const deck = control(deps, dir)
    await deck.call('browser_worker', { action: 'take', worker: 'worker 2' }, { caller: session })
    expect(deps.taken).toEqual([{ holder: 'session::s1', profileId: 'w2' }])
  })

  it('refuses a name that is not a worker rather than handing over a free one', async () => {
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_worker', { action: 'take', worker: 'Worker 9' }, { caller: session })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('no worker by that name')
  })

  it('passes a refusal through in the pool’s own words', async () => {
    const deck = control(
      fakeDeps({ take: async () => ({ ok: false, reason: 'every worker is out.' }) }),
      dir,
    )
    const result = await deck.call('browser_worker', { action: 'take' }, { caller: session })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('every worker is out')
  })
})

describe('letting one go', () => {
  it('is refused for a caller that is not the one holding it', async () => {
    /*
     * The pool checks the holder and this is what that check buys: agent B
     * cannot free a worker agent A is mid-page on, so the two never end up
     * driving the same cookie jar.
     */
    const deps = fakeDeps()
    const deck = control(deps, dir)
    await deck.call('browser_worker', { action: 'take', worker: 'Worker 1' }, { caller: session })
    const theirs = await deck.call(
      'browser_worker',
      { action: 'release', worker: 'Worker 1' },
      { caller: other },
    )
    expect(theirs.ok).toBe(false)
    expect(theirs.error).toContain('not held by you')

    const mine = await deck.call(
      'browser_worker',
      { action: 'release', worker: 'Worker 1' },
      { caller: session },
    )
    expect(mine.ok).toBe(true)
  })

  it('needs the worker named, because there is nothing sensible to guess', async () => {
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_worker', { action: 'release' }, { caller: session })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('needs the worker')
  })

  it('refuses an action that is not one of the three', async () => {
    const deck = control(fakeDeps(), dir)
    const result = await deck.call('browser_worker', { action: 'destroy' }, { caller: session })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('action must be one of')
  })
})
