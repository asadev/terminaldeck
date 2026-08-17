/**
 * A routine reaching for an alter-tier tool at three in the morning.
 *
 * ## The failure this is about
 *
 * A routine runs *through* the copilot, and the copilot's alter tier is defined
 * as a real question put to a real person. At 03:00 there is no person. Before
 * this, the call went to `ConsentBroker` anyway and could only end one of two
 * ways: `no-approver` if no window had attached, or — worse, because a window
 * may well be open in front of a sleeping owner — a two-minute wait ending in
 * `timeout`, holding one of the three pending slots the whole time and burning a
 * whole agent turn on a refusal the model was told to treat as temporary.
 *
 * It is not a hypothesis. OpenClaw's heartbeat did exactly this on this machine:
 * exec needed approval, a heartbeat cannot obtain interactive approval, and the
 * run died with `approval-timeout`, then again, then `user-denied` — each attempt
 * spending a turn generating an apology. The fix there was to delete the command.
 *
 * ## Why the test is assembled rather than mocked
 *
 * Both halves already have unit tests: `control.test.ts` proves the gate, and
 * `engine.test.ts` proves the run lifecycle. Neither of them can prove the thing
 * that actually has to be true, which is that the routine engine's runs arrive
 * at the gate *marked* — an engine that forgot, or a runner handed the wrong
 * object, would leave both suites green and the 03:00 deadlock exactly where it
 * was. So this builds a real `DeckControl`, a real `ConsentBroker`, a real
 * `RoutineEngine` over a real routine file, and a runner that does what a runner
 * will do: take what the run request handed it and call a tool with it.
 *
 * The consent broker's `ask` is the instrument. It counts how many times a human
 * would have been interrupted; the number that matters is zero.
 */

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from '../deck-control/action-log'
import { ConsentBroker, type ConsentRequest } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { ToolSpec } from '../deck-control/catalogue'
import type { DeckSurface } from '../deck-control/surface'
import { copilotPaths } from '../copilot-home'
import { RoutineEngine, type RoutineRunner } from './engine'
import { routineLogger } from './log'
import { RoutineStore } from './store'
import { RuntimeState } from './runtime-state'

/**
 * A surface that fails loudly if anything touches it.
 *
 * The one tool this test exercises is contributed through `extraTools` and does
 * not reach the app at all, so a stub with plausible methods would be inventing
 * behaviour nobody needs. A proxy that throws is both smaller and stronger: if a
 * change ever routes this path through a real app operation, the test says so
 * instead of quietly exercising a fake. It also means this file does not have to
 * be edited every time `DeckSurface` grows a method.
 */
const surface = new Proxy(
  {},
  {
    get(_target, property) {
      throw new Error(`no tool in this test should reach the app surface (asked for ${String(property)})`)
    },
  },
) as DeckSurface

/**
 * One alter-tier tool, standing in for `settings.write` and `sessions.stop`.
 *
 * Contributed rather than borrowed from the catalogue so that this file tests
 * the *tier*, not any particular tool's arguments — and so it keeps testing the
 * tier while `catalogue.ts` is being extended in parallel. `control.ts` holds a
 * contributed tool to exactly the same rules as a built-in one, which is the
 * property being relied on here.
 */
function alterTool(onRun: () => void): ToolSpec {
  return {
    id: 'demo.alter',
    wire: 'demo_alter',
    tier: 'alter',
    title: 'Change something',
    description: 'Stands in for any alter-tier tool.',
    inputSchema: { type: 'object', properties: {} },
    summary: () => 'Change something that cannot be undone',
    run: async () => {
      onRun()
      return { value: { changed: true }, summary: { changed: true } }
    },
  }
}

const ROUTINE = [
  '# Overnight sweep',
  '',
  'when: manual',
  'in: /tmp/td-unattended-project',
  '',
  '---',
  '',
  'Have a look and fix what you can.',
  '',
].join('\n')

let dir: string
let control: DeckControl
let consent: ConsentBroker
let engine: RoutineEngine
let asked: ConsentRequest[]
let ran: number
/** What the runner saw when it called the tool. */
let seen: { ok: boolean; refusal: string | null; error: string | null } | null

/** A runner that does the one thing a real runner will do with the request. */
const runner: RoutineRunner = {
  async run(request) {
    // The contract, exercised rather than described: the engine says the run is
    // unattended, and hands over a caller that is already marked as such.
    expect(request.attended).toBe(false)
    if (request.control === null) return { ok: false, error: 'no tool surface' }
    const result = await request.control.call('demo.alter', {})
    seen = { ok: result.ok, refusal: result.refusal, error: result.error }
    return { ok: true }
  },
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-unattended-'))
  mkdirSync(join(dir, 'routines'), { recursive: true })
  writeFileSync(join(dir, 'routines', 'sweep.md'), ROUTINE, 'utf8')
  asked = []
  ran = 0
  seen = null

  consent = new ConsentBroker({
    ask: (request) => {
      asked.push(request)
      // True means "delivered to a window". The pessimistic setting on purpose:
      // if the unattended check were missing, the call would *not* fall through
      // to `no-approver` — it would sit here until it timed out, which is the
      // exact behaviour being removed and the one a test must be able to see.
      return true
    },
    // Long enough that a test which reached the broker would visibly hang rather
    // than pass by accident on a fast timeout.
    timeoutMs: 60_000,
  })

  control = new DeckControl({
    surface,
    log: new ActionLog({ dir: copilotPaths(dir).log }),
    consent,
    extraTools: [alterTool(() => (ran += 1))],
  })

  engine = new RoutineEngine({
    store: new RoutineStore({ dir: join(dir, 'routines') }),
    runtime: new RuntimeState({ file: join(dir, 'routine-state.json'), debounceMs: 0 }),
    log: routineLogger(copilotPaths(dir)),
    runner,
    control: control.unattended(),
    allowFolder: () => ({ ok: true }),
    watchFiles: () => () => undefined,
    watchGit: () => () => undefined,
  })
  engine.start()
})

afterEach(async () => {
  await engine.stop()
  rmSync(dir, { recursive: true, force: true })
})

function actionLog(): string {
  return readFileSync(copilotPaths(dir).actions, 'utf8')
}

describe('an alter-tier call from a routine run', () => {
  it('is refused immediately, and nobody is asked', async () => {
    const result = await engine.runNow('sweep')
    expect(result.started).toBe(true)
    await settled()

    expect(seen).not.toBeNull()
    expect(seen?.ok).toBe(false)
    expect(seen?.refusal).toBe('not-permitted-unattended')
    // The whole point. A dialog was never drawn, so nothing waited on one.
    expect(asked).toEqual([])
    // And the tool did not run behind the refusal.
    expect(ran).toBe(0)
  })

  it('tells the model to report rather than retry', async () => {
    // A refusal a model reads as temporary is a refusal it will try again, and
    // a routine has a finite turn to spend. The sentence has to close the door.
    await engine.runNow('sweep')
    await settled()
    expect(seen?.error).toMatch(/cannot be confirmed at all/i)
    expect(seen?.error).toMatch(/do not retry/i)
  })

  it('shows on the routine which call was refused', async () => {
    /*
     * The half a person actually needs. Without it the only record is a line in
     * a chronological action log holding every tool call the copilot has ever
     * made, and "my routine did nothing overnight" is answered by scrolling.
     */
    await engine.runNow('sweep')
    await settled()

    const view = engine.get('sweep')
    expect(view?.refusedCalls).toHaveLength(1)
    expect(view?.refusedCalls[0]?.tool).toBe('demo.alter')
    expect(view?.refusedCalls[0]?.reason).toBe('not-permitted-unattended')
    // Tied to the run, so the row can be lined up with the rest of that run in
    // the action log.
    expect(view?.refusedCalls[0]?.runId).toEqual(expect.any(String))
    expect(view?.refusedCalls[0]?.runId).not.toBe('')
  })

  it('survives a restart, because the person reads it in the morning', async () => {
    await engine.runNow('sweep')
    await settled()
    await engine.stop()

    // A second engine over the same state file, which is what tomorrow is.
    const next = new RoutineEngine({
      store: new RoutineStore({ dir: join(dir, 'routines') }),
      runtime: new RuntimeState({ file: join(dir, 'routine-state.json'), debounceMs: 0 }),
      log: routineLogger(copilotPaths(dir)),
      runner,
      control: control.unattended(),
      allowFolder: () => ({ ok: true }),
      watchFiles: () => () => undefined,
      watchGit: () => () => undefined,
    })
    next.start()
    expect(next.get('sweep')?.refusedCalls[0]?.tool).toBe('demo.alter')
    await next.stop()
  })

  it('writes both rows a person would look for, in the one action log', async () => {
    await engine.runNow('sweep')
    await settled()
    const rows = actionLog()
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as Record<string, unknown>)

    // The gate's own row, in the same file and the same shape as every other
    // tool call the copilot makes.
    const gate = rows.find((row) => row.action === 'tool.demo.alter')
    expect(gate?.outcome).toBe('refused')
    expect((gate?.confirmed as { required: boolean; reason: string }).required).toBe(true)
    expect((gate?.confirmed as { required: boolean; reason: string }).reason).toBe(
      'not-permitted-unattended',
    )

    // And the routine's own row beside it, naming the routine. One file, two
    // views of the same moment, which is the whole reason `log.ts` refuses to
    // open a second one.
    const routine = rows.find((row) => row.action === 'routine.refused')
    expect(routine?.routine).toBe('sweep')
    expect(routine?.outcome).toBe('refused')
    expect(String(routine?.detail)).toContain('demo.alter')
  })

  it('hands the runner nothing at all when no shell has wired the surface', async () => {
    /*
     * The honest state of the app as it stands: `deck-control` is not assembled
     * in `src/main/index.ts` yet, so `control` is null and a runner is told so
     * rather than handed something that looks like a tool surface and is not.
     * Pinned because the tempting shortcut — a no-op caller that answers every
     * call with a polite failure — would be a surface that cannot do the thing,
     * which house rule three forbids for exactly this reason: the model would
     * believe it had tools.
     */
    const bare = new RoutineEngine({
      store: new RoutineStore({ dir: join(dir, 'routines') }),
      runtime: new RuntimeState({ file: join(dir, 'bare-state.json'), debounceMs: 0 }),
      log: routineLogger(copilotPaths(dir)),
      runner,
      allowFolder: () => ({ ok: true }),
      watchFiles: () => () => undefined,
      watchGit: () => () => undefined,
    })
    bare.start()
    await bare.runNow('sweep')
    await settled()
    expect(seen).toBeNull()
    expect(asked).toEqual([])

    // And the shell can wire it later, which it has to: `createRoutines` runs at
    // module scope and `registerDeckControlIpc` is awaited well after it.
    bare.setControl(control.unattended())
    await bare.runNow('sweep')
    await settled()
    expect(seen?.refusal).toBe('not-permitted-unattended')
    await bare.stop()
  })

  it('is not a way for the routine to skip the gate quietly', async () => {
    /*
     * The counterfactual that makes the rest of this file mean something.
     *
     * If the tool were somehow not alter-tier, or if the contributed spec were
     * being held to a weaker rule than a built-in one, every assertion above
     * would pass for the wrong reason — the call would simply have succeeded and
     * nobody would have been asked either. So: the same tool, called the
     * ordinary attended way, must reach the broker.
     */
    const pending = control.call('demo.alter', {})
    await Promise.resolve()
    expect(asked).toHaveLength(1)
    // Answer it so the promise settles rather than leaving a timer behind.
    expect(asked[0]?.tier).toBe('alter')
    consent.respond(asked[0].id, false, 'test')
    const result = await pending
    expect(result.refusal).toBe('declined')
  })
})

/** Let the run's promise chain drain. The runner does no real I/O. */
async function settled(): Promise<void> {
  for (let i = 0; i < 20; i += 1) await Promise.resolve()
  await new Promise((resolve) => setTimeout(resolve, 10))
}
