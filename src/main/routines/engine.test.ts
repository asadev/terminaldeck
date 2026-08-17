import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { AlertReport } from '../alerts'
import type { SessionMeta } from '../../shared/types'
import { copilotPaths } from '../copilot-home'
import { routineLogger } from './log'
import {
  CANCEL_GRACE_MS,
  MAX_CHAIN_DEPTH,
  MAX_CONSECUTIVE_FAILURES,
  RoutineEngine,
  type RoutineRunOutcome,
  type RoutineRunRequest,
  type RoutineRunner,
} from './engine'
import { RoutineStore } from './store'
import { RuntimeState } from './runtime-state'

/**
 * The engine, and above all the four things that decide whether it is safe to
 * leave running while nobody is watching: a routine that triggers itself,
 * overlap, cost, and the difference between quiet and broken.
 *
 * Real files, a real store, a fake clock. The clock is fake because the
 * alternative is a test suite that waits fifteen minutes for a `session-idle`
 * trigger; the files are real because the storage format is half the feature.
 * There is no fake filesystem anywhere in here.
 */

/* ------------------------------------------------------------- test rig -- */

/** A clock the tests drive. Holds the engine's timers; nothing waits. */
class Clock {
  now = new Date(2026, 7, 17, 9, 0, 0).getTime()
  private nextId = 1
  private readonly timers = new Map<number, { at: number; fn: () => void }>()

  set = (fn: () => void, ms: number): unknown => {
    const id = this.nextId++
    this.timers.set(id, { at: this.now + Math.max(0, ms), fn })
    return id
  }

  clear = (handle: unknown): void => {
    this.timers.delete(handle as number)
  }

  get pending(): number {
    return this.timers.size
  }

  /** Move time forward, running whatever comes due, then let promises settle. */
  async advance(ms: number): Promise<void> {
    const target = this.now + ms
    for (let guard = 0; guard < 1000; guard++) {
      let dueId: number | null = null
      let dueAt = Number.POSITIVE_INFINITY
      for (const [id, timer] of this.timers) {
        if (timer.at <= target && timer.at < dueAt) {
          dueAt = timer.at
          dueId = id
        }
      }
      if (dueId === null) break
      const timer = this.timers.get(dueId)
      this.timers.delete(dueId)
      this.now = dueAt
      timer?.fn()
      await settle()
    }
    this.now = target
    await settle()
  }
}

/** Let every already-scheduled microtask and `setImmediate` run. */
async function settle(): Promise<void> {
  for (let round = 0; round < 6; round++) {
    await new Promise((resolve) => setImmediate(resolve))
  }
}

/** A runner the tests drive: it records every run and can be made to hang. */
class Runner implements RoutineRunner {
  readonly calls: RoutineRunRequest[] = []
  cancellable = true
  /** While true, a run does not finish until {@link finish} is called. */
  gated = false
  outcome: RoutineRunOutcome = { ok: true }
  /** Sessions to claim each run started, so provenance can be exercised. */
  spawns: string[] = []
  aborted = 0
  private readonly waiting: Array<(outcome: RoutineRunOutcome) => void> = []

  async run(request: RoutineRunRequest): Promise<RoutineRunOutcome> {
    this.calls.push(request)
    const answer = {
      ...this.outcome,
      ...(this.spawns.length > 0 ? { sessionIds: [...this.spawns] } : {}),
    }
    if (!this.gated) return answer
    return new Promise<RoutineRunOutcome>((resolve) => {
      request.signal.addEventListener('abort', () => {
        this.aborted += 1
      })
      this.waiting.push(resolve)
    })
  }

  /** Let the oldest gated run finish. */
  finish(outcome: RoutineRunOutcome = { ok: true }): void {
    this.waiting.shift()?.(outcome)
  }
}

let dir: string
let clock: Clock
let runner: Runner
let engine: RoutineEngine

interface RigOptions {
  runner?: RoutineRunner | null
  globalMaxRunsPerHour?: number
  allowFolder?: (folder: string) => { ok: true } | { ok: false; reason: string }
  /** Leave the session and alert sources undeclared, as a half-wired shell would. */
  unwired?: boolean
}

function build(options: RigOptions = {}): RoutineEngine {
  const built = new RoutineEngine({
    store: new RoutineStore({ dir: join(dir, 'routines') }),
    runtime: new RuntimeState({ file: join(dir, 'state.json'), now: () => clock.now, debounceMs: 0 }),
    log: routineLogger(copilotPaths(dir)),
    runner: options.runner === undefined ? runner : options.runner,
    now: () => clock.now,
    setTimer: clock.set,
    clearTimer: clock.clear,
    ...(options.allowFolder ? { allowFolder: options.allowFolder } : {}),
    ...(options.globalMaxRunsPerHour
      ? { globalMaxRunsPerHour: () => options.globalMaxRunsPerHour as number }
      : {}),
    // Neither is exercised here; `sources.test.ts` covers the real ones.
    watchFiles: () => () => undefined,
    watchGit: () => () => undefined,
  })
  if (!options.unwired) {
    // What a correctly wired shell declares at boot. Left out on purpose in the
    // one test that checks a half-wired build reports itself as one.
    for (const kind of ['session-finished', 'session-failed', 'session-idle', 'alert'] as const) {
      built.markSource(kind, true)
    }
  }
  return built
}

function write(id: string, body: string): void {
  writeFileSync(join(dir, 'routines', `${id}.md`), body, 'utf8')
}

const PROJECT = '/tmp/td-project'

function routineText(options: {
  when: string | string[]
  folder?: string
  overlap?: string
  extra?: string
}): string {
  const triggers = Array.isArray(options.when) ? options.when : [options.when]
  return [
    '# A routine',
    '',
    ...triggers.map((trigger) => `when: ${trigger}`),
    `in: ${options.folder ?? PROJECT}`,
    ...(options.overlap ? [`overlap: ${options.overlap}`] : []),
    ...(options.extra ? [options.extra] : []),
    '',
    '---',
    '',
    'Do the thing.',
    '',
  ].join('\n')
}

function session(id: string, extra: Partial<SessionMeta> = {}): SessionMeta {
  return {
    id,
    cwd: PROJECT,
    title: 'project',
    provider: 'claude',
    exitCode: null,
    createdAt: clock.now,
    ...extra,
  }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-engine-'))
  mkdtempSync(join(tmpdir(), 'td-engine-x-'))
  writeFileSync(join(dir, 'placeholder'), '', 'utf8')
  // The store makes this itself on save, but the tests write files directly.
  rmSync(join(dir, 'placeholder'))
  clock = new Clock()
  runner = new Runner()
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  require('node:fs').mkdirSync(join(dir, 'routines'), { recursive: true })
})

afterEach(async () => {
  await engine?.stop()
  rmSync(dir, { recursive: true, force: true })
})

/* ------------------------------------------------------------- the basics */

describe('subscribing', () => {
  it('runs a routine when a session in its folder finishes', async () => {
    write('sweep', routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()

    expect(runner.calls).toHaveLength(1)
    expect(runner.calls[0].cause).toEqual({ kind: 'session-finished', sessionId: 's1', exitCode: 0 })
  })

  it('tells a finish from a failure', async () => {
    write('on-fail', routineText({ when: 'session-failed' }))
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(0)

    engine.noteSessionStarted(session('s2'))
    engine.noteSessionExit('s2', 1)
    await settle()
    expect(runner.calls).toHaveLength(1)
  })

  it('ignores a session in somebody else’s folder', async () => {
    write('sweep', routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1', { cwd: '/tmp/somewhere-else' }))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(0)
  })

  it('waits out an idle period, and cancels it the moment the session speaks', async () => {
    write('idle', routineText({ when: 'session-idle 15m' }))
    engine = build()
    engine.reload()
    engine.noteSessionStarted(session('s1'))

    engine.noteSessionStatus('s1', 'idle')
    await clock.advance(14 * 60_000)
    expect(runner.calls).toHaveLength(0)

    // It came back to life with a minute to go.
    engine.noteSessionStatus('s1', 'working')
    await clock.advance(60 * 60_000)
    expect(runner.calls).toHaveLength(0)

    engine.noteSessionStatus('s1', 'waiting')
    await clock.advance(15 * 60_000)
    expect(runner.calls).toHaveLength(1)
  })

  it('does not treat a session blocked on a question as idle', async () => {
    write('idle', routineText({ when: 'session-idle 5m' }))
    engine = build()
    engine.reload()
    engine.noteSessionStarted(session('s1'))
    engine.noteSessionStatus('s1', 'input')
    await clock.advance(60 * 60_000)
    expect(runner.calls).toHaveLength(0)
  })

  it('fires once per alert, not once per scan', async () => {
    write('alerts', routineText({ when: 'alert critical' }))
    engine = build()
    engine.reload()

    const report = (ids: Array<[string, 'critical' | 'warning']>): AlertReport => ({
      projectPath: PROJECT,
      alerts: ids.map(([id, severity]) => ({
        id,
        kind: 'session-blocked' as const,
        severity,
        title: id,
        detail: '',
        at: clock.now,
        action: null,
      })),
      counts: { critical: 0, warning: 0, info: 0 },
      worst: null,
      scannedAt: clock.now,
    })

    engine.noteAlertReport(report([['a1', 'critical']]))
    await settle()
    expect(runner.calls).toHaveLength(1)

    // The panel scans again a minute later and the same alert is still there.
    engine.noteAlertReport(report([['a1', 'critical']]))
    await settle()
    expect(runner.calls).toHaveLength(1)

    // A warning is not what this routine asked for.
    engine.noteAlertReport(report([['a1', 'critical'], ['a2', 'warning']]))
    await settle()
    expect(runner.calls).toHaveLength(1)
  })
})

/* -------------------------------------------------- a routine that loops */

describe('a routine that triggers itself', () => {
  it('is not started by a session its own run began', async () => {
    write('spawner', routineText({ when: 'session-finished' }))
    runner.spawns = ['child']
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)

    // The session the run started now finishes. This is the loop, and it stops
    // here: the engine knows which run that session came from.
    engine.noteSessionExit('child', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)
  })

  it('follows provenance carried on the session metadata across a hand-off', async () => {
    write('spawner', routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    const runId = runner.calls[0].runId

    // The copilot started the session itself and labelled it, rather than the
    // runner reporting it back. Same answer.
    engine.noteSessionStarted(
      session('child', { origin: 'copilot', originRoutineId: 'spawner', originRunId: runId }),
    )
    engine.noteSessionExit('child', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)
  })

  it('stops a ring of routines that start each other', async () => {
    for (const id of ['a', 'b', 'c', 'd']) write(id, routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()

    // Every routine fires on the same event, so one session exit starts four
    // runs; each claims a child session, and each child's exit would start four
    // more. The chain cap is what makes that terminate.
    let sequence = 0
    runner.spawns = []
    const originalRun = runner.run.bind(runner)
    runner.run = async (request) => {
      const child = `child-${sequence++}`
      const outcome = await originalRun(request)
      engine.noteSessionStarted(session(child))
      queueMicrotask(() => {
        engine.noteSessionExit(child, 0)
      })
      return { ...outcome, sessionIds: [child] }
    }

    engine.noteSessionStarted(session('root'))
    engine.noteSessionExit('root', 0)
    for (let round = 0; round < 20; round++) await settle()

    // Without a cap this does not terminate at all. With one, it is bounded by
    // the depth rather than by anybody noticing.
    expect(runner.calls.length).toBeGreaterThan(0)
    expect(runner.calls.every((call) => call.chain.length <= MAX_CHAIN_DEPTH)).toBe(true)
  })
})

/* -------------------------------------------------------------- overlap */

describe('overlap', () => {
  it('queues exactly one, however many times the trigger fires', async () => {
    write('slow', routineText({ when: 'session-finished', extra: 'quiet-for: 1s' }))
    engine = build()
    engine.reload()
    runner.gated = true

    for (const id of ['s1', 's2', 's3', 's4']) {
      engine.noteSessionStarted(session(id))
      engine.noteSessionExit(id, 0)
      await settle()
    }
    expect(runner.calls).toHaveLength(1)
    expect(engine.get('slow')?.pending).toBe(true)

    runner.gated = false
    runner.finish()
    await settle()
    // Four fires, one run in flight, and exactly one more afterwards — not
    // three. The queue is one deep and the rest collapse into it.
    await clock.advance(2000)
    expect(runner.calls).toHaveLength(2)
    expect(engine.get('slow')?.pending).toBe(false)
  })

  it('skips rather than queues when the routine says so', async () => {
    write('once', routineText({ when: 'session-finished', overlap: 'skip' }))
    engine = build()
    engine.reload()
    runner.gated = true

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    engine.noteSessionStarted(session('s2'))
    engine.noteSessionExit('s2', 0)
    await settle()

    expect(runner.calls).toHaveLength(1)
    expect(engine.get('once')?.pending).toBe(false)
  })

  it('cancels the run in flight, and never has two going at once', async () => {
    write('latest', routineText({ when: 'session-finished', overlap: 'cancel', extra: 'quiet-for: 1s' }))
    engine = build()
    engine.reload()
    runner.gated = true

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)

    engine.noteSessionStarted(session('s2'))
    engine.noteSessionExit('s2', 0)
    await settle()
    expect(runner.aborted).toBe(1)
    // Still one: the replacement waits for the first to actually stop. This is
    // the invariant — a routine never has two runs going, whatever its overlap
    // policy says and whatever the runner does with the abort.
    expect(runner.calls).toHaveLength(1)

    runner.gated = false
    runner.finish({ ok: false, error: 'cancelled' })
    await settle()
    // The replacement still waits out the quiet period, and that is deliberate:
    // `cancel` chooses which run wins, not how often the routine may start work.
    expect(runner.calls).toHaveLength(1)
    await clock.advance(2000)
    expect(runner.calls).toHaveLength(2)
  })

  it('drops the replacement when the previous run will not stop', async () => {
    write('latest', routineText({ when: 'session-finished', overlap: 'cancel', extra: 'quiet-for: 1s' }))
    engine = build()
    engine.reload()
    // A runner that ignores the signal — which is what `cancellable: false`
    // declares, and what any runner might do by accident.
    runner.gated = true
    runner.cancellable = false

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    engine.noteSessionStarted(session('s2'))
    engine.noteSessionExit('s2', 0)
    await settle()
    expect(engine.get('latest')?.pending).toBe(true)

    await clock.advance(CANCEL_GRACE_MS + 1000)
    expect(engine.get('latest')?.pending).toBe(false)
    expect(runner.calls).toHaveLength(1)
  })
})

/* ----------------------------------------------------------------- cost */

describe('cost', () => {
  it('stops at the routine’s own hourly ceiling and says when it recovers', async () => {
    write('chatty', routineText({ when: 'session-finished', extra: 'max-runs-per-hour: 2\nquiet-for: 1s' }))
    engine = build()
    engine.reload()

    for (let index = 0; index < 5; index++) {
      engine.noteSessionStarted(session(`s${index}`))
      engine.noteSessionExit(`s${index}`, 0)
      await clock.advance(2000)
    }

    expect(runner.calls).toHaveLength(2)
    const view = engine.get('chatty')
    expect(view?.state).toBe('paused')
    expect(view?.reason).toContain('hourly ceiling of 2')
    expect(view?.pausedUntil).not.toBeNull()

    // And it comes back on its own once the window has moved.
    await clock.advance(61 * 60_000)
    expect(engine.get('chatty')?.state).toBe('armed')
  })

  it('counts fires separately from runs, so a chatty trigger is visible', async () => {
    write('chatty', routineText({ when: 'session-finished', extra: 'max-runs-per-hour: 1\nquiet-for: 1s' }))
    engine = build()
    engine.reload()

    for (let index = 0; index < 4; index++) {
      engine.noteSessionStarted(session(`s${index}`))
      engine.noteSessionExit(`s${index}`, 0)
      await clock.advance(2000)
    }

    const view = engine.get('chatty')
    expect(view?.runsLastHour).toBe(1)
    expect(view?.firesLastHour).toBe(4)
  })

  it('holds an app-wide ceiling that no routine file can raise', async () => {
    write('a', routineText({ when: 'session-finished', extra: 'quiet-for: 1s' }))
    write('b', routineText({ when: 'session-finished', extra: 'quiet-for: 1s' }))
    engine = build({ globalMaxRunsPerHour: 3 })
    engine.reload()

    for (let index = 0; index < 4; index++) {
      engine.noteSessionStarted(session(`s${index}`))
      engine.noteSessionExit(`s${index}`, 0)
      await clock.advance(2000)
    }

    expect(runner.calls).toHaveLength(3)
    expect(engine.get('a')?.reason).toContain("this app's ceiling")
  })

  it('cannot be reset by restarting the app', async () => {
    write('chatty', routineText({ when: 'manual', extra: 'max-runs-per-hour: 2\nquiet-for: 1s' }))
    engine = build()
    engine.reload()
    await engine.runNow('chatty')
    await clock.advance(2000)
    await engine.runNow('chatty')
    await clock.advance(2000)
    expect(runner.calls).toHaveLength(2)
    await engine.stop()

    // A brand-new engine over the same state file — which is what a relaunch,
    // or a crash loop, actually is.
    engine = build()
    engine.reload()
    const result = await engine.runNow('chatty')
    expect(result.started).toBe(false)
    expect(runner.calls).toHaveLength(2)
  })

  it('does not let a hand run round the ceiling', async () => {
    write('chatty', routineText({ when: 'manual', extra: 'max-runs-per-hour: 1\nquiet-for: 1s' }))
    engine = build()
    engine.reload()
    expect((await engine.runNow('chatty', 'copilot')).started).toBe(true)
    await clock.advance(2000)
    const second = await engine.runNow('chatty', 'copilot')
    expect(second.started).toBe(false)
    if (second.started) return
    expect(second.reason).toContain('ceiling')
  })

  it('debounces a burst into one run rather than one run per event', async () => {
    write('bursty', routineText({ when: 'session-finished', extra: 'quiet-for: 30s' }))
    engine = build()
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)

    // Three more within the quiet period collapse into one trailing run.
    for (const id of ['s2', 's3', 's4']) {
      engine.noteSessionStarted(session(id))
      engine.noteSessionExit(id, 0)
      await clock.advance(1000)
    }
    expect(runner.calls).toHaveLength(1)

    await clock.advance(40_000)
    expect(runner.calls).toHaveLength(2)
  })
})

/* -------------------------------------------------------------- failure */

describe('telling a broken routine from a quiet one', () => {
  it('says the copilot is missing rather than looking idle', async () => {
    write('sweep', routineText({ when: 'session-finished' }))
    engine = build({ runner: null })
    engine.reload()
    const view = engine.get('sweep')
    expect(view?.state).toBe('unarmed')
    expect(view?.reason).toContain('copilot is not running')
  })

  it('says the folder is not one this app watches', async () => {
    write('sweep', routineText({ when: 'session-finished', folder: '/' }))
    engine = build({
      allowFolder: (folder) =>
        folder === PROJECT ? { ok: true } : { ok: false, reason: `${folder} is not one of your projects.` },
    })
    engine.reload()
    expect(engine.get('sweep')?.state).toBe('unarmed')
    expect(engine.get('sweep')?.reason).toContain('not one of your projects')
  })

  it('says nothing is subscribed to a trigger this process never wired', async () => {
    write('sweep', routineText({ when: 'alert' }))
    engine = build({ unwired: true })
    engine.reload()
    const view = engine.get('sweep')
    expect(view?.state).toBe('unarmed')
    expect(view?.sources.find((source) => source.kind === 'alert')?.subscribed).toBe(false)

    // One real report is proof the source is live, and it flips.
    engine.noteAlertReport({
      projectPath: PROJECT,
      alerts: [],
      counts: { critical: 0, warning: 0, info: 0 },
      worst: null,
      scannedAt: clock.now,
    })
    expect(engine.get('sweep')?.state).toBe('armed')
    expect(engine.get('sweep')?.sources.find((source) => source.kind === 'alert')?.lastEventAt).toBe(
      clock.now,
    )
  })

  it('reports a routine that said how often it expects to fire and has not', async () => {
    write('nightly', routineText({ when: 'session-finished', extra: 'expect-every: 26h' }))
    engine = build()
    engine.reload()
    // Nothing has ever fired it, and it said it expected to by now.
    expect(engine.get('nightly')?.state).toBe('stale')

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(engine.get('nightly')?.state).toBe('armed')

    await clock.advance(27 * 3_600_000)
    expect(engine.get('nightly')?.state).toBe('stale')
  })

  it('stops a routine that keeps failing, and keeps it stopped across a restart', async () => {
    write('doomed', routineText({ when: 'manual', extra: 'quiet-for: 1s' }))
    engine = build()
    engine.reload()
    runner.outcome = { ok: false, error: 'the prompt could not be delivered' }

    for (let index = 0; index < MAX_CONSECUTIVE_FAILURES; index++) {
      await engine.runNow('doomed')
      await clock.advance(2000)
      await settle()
    }

    const view = engine.get('doomed')
    expect(view?.state).toBe('paused')
    expect(view?.reason).toContain('failures in a row')
    expect(view?.lastError).toContain('could not be delivered')

    await engine.stop()
    engine = build()
    engine.reload()
    expect(engine.get('doomed')?.state).toBe('paused')

    // And a person can put it back.
    expect(engine.resume('doomed')).toBe(true)
    expect(engine.get('doomed')?.state).toBe('armed')
  })

  it('keeps a broken file in the list with its problems, rather than dropping it', async () => {
    write('typo', '# Typo\n\nwhen: sesion-finished\nin: /tmp/td-project\n\n---\n\nGo.\n')
    engine = build()
    engine.reload()
    const view = engine.get('typo')
    expect(view?.state).toBe('broken')
    expect(view?.problems.join(' ')).toContain('sesion-finished')
  })

  it('reports a routine turned off in its file as off, not as broken', async () => {
    write('off', routineText({ when: 'session-finished', extra: 'enabled: no' }))
    engine = build()
    engine.reload()
    expect(engine.get('off')?.state).toBe('disabled')
    expect((await engine.runNow('off')).started).toBe(false)
  })
})

/* -------------------------------------------------------------- schedule */

describe('schedule', () => {
  it('runs when it comes due, from one timer', async () => {
    write('nightly', routineText({ when: 'schedule 09:30' }))
    engine = build()
    engine.start()
    await settle()

    const before = clock.pending
    expect(before).toBeGreaterThan(0)
    await clock.advance(29 * 60_000)
    expect(runner.calls).toHaveLength(0)
    await clock.advance(2 * 60_000)
    expect(runner.calls).toHaveLength(1)
    expect(runner.calls[0].cause.kind).toBe('schedule')

    // Re-armed for tomorrow rather than left to fire again.
    expect(engine.get('nightly')?.nextDueAt).toBeGreaterThan(clock.now)
    await clock.advance(60 * 60_000)
    expect(runner.calls).toHaveLength(1)
  })

  it('re-checks after the machine wakes rather than waiting for a late timer', async () => {
    write('nightly', routineText({ when: 'schedule 09:30' }))
    engine = build()
    engine.start()
    await settle()

    // A suspend: the clock moves without any timer firing.
    clock.now += 60 * 60_000
    engine.wake()
    await settle()
    expect(runner.calls).toHaveLength(1)
  })

  it('runs once and reports the rest when the app was closed', async () => {
    write('nightly', routineText({ when: 'schedule 09:30' }))
    engine = build()
    engine.start()
    await settle()
    await clock.advance(31 * 60_000)
    expect(runner.calls).toHaveLength(1)
    await engine.stop()

    // Three days later.
    clock.now += 3 * 86_400_000
    engine = build()
    engine.reload()
    const view = engine.get('nightly')
    expect(view?.missedWhileClosed).toBe(3)
  })
})

/* -------------------------------------------------------- reload and IPC */

describe('reloading', () => {
  it('picks up a routine added to the folder', async () => {
    engine = build()
    engine.reload()
    expect(engine.list()).toHaveLength(0)

    write('new', routineText({ when: 'session-finished' }))
    engine.reload()
    expect(engine.list()).toHaveLength(1)

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(1)
  })

  it('drops a routine whose file is gone, and stops firing it', async () => {
    write('going', routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()
    rmSync(join(dir, 'routines', 'going.md'))
    engine.reload()

    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()
    expect(runner.calls).toHaveLength(0)
    expect(engine.list()).toHaveLength(0)
  })

  it('leaves a run in flight alone when its file is edited under it', async () => {
    write('editing', routineText({ when: 'session-finished' }))
    engine = build()
    engine.reload()
    runner.gated = true
    engine.noteSessionStarted(session('s1'))
    engine.noteSessionExit('s1', 0)
    await settle()

    write('editing', routineText({ when: 'session-finished', overlap: 'skip' }))
    engine.reload()
    expect(engine.get('editing')?.running).toBe(true)
    expect(runner.aborted).toBe(0)
  })
})
