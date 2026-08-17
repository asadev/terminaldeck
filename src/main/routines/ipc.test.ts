import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import { routineLogger } from './log'
import { RoutineEngine, type RoutineRunner } from './engine'
import {
  RoutineApi,
  ROUTINES_CREATE,
  ROUTINES_DELETE,
  ROUTINES_GET,
  ROUTINES_LIST,
  ROUTINES_PAUSE,
  ROUTINES_RESUME,
  ROUTINES_RUN,
  ROUTINES_UPDATE,
  ROUTINE_TIERS,
  registerRoutinesIpc,
} from './ipc'
import { RoutineStore } from './store'
import { RuntimeState } from './runtime-state'

/**
 * The surface the settings pane and, in phase 2, the `deck-control` MCP server
 * both go through.
 *
 * The claims that matter are about refusal: an id that is really a path, a name
 * that is already taken, a draft with no trigger. Every one of those arrives
 * from something untrusted — a renderer, or a language model — and the answer
 * has to be a sentence rather than a thrown error, because the caller on the
 * other end has to be able to tell the user what went wrong.
 */

let dir: string
let api: RoutineApi
let engine: RoutineEngine
const runs: string[] = []

const runner: RoutineRunner = {
  async run(request) {
    runs.push(request.routine.id)
    return { ok: true }
  },
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-routines-ipc-'))
  mkdirSync(join(dir, 'routines'), { recursive: true })
  runs.length = 0
  const store = new RoutineStore({ dir: join(dir, 'routines') })
  engine = new RoutineEngine({
    store,
    runtime: new RuntimeState({ file: join(dir, 'state.json'), debounceMs: 0 }),
    log: routineLogger(copilotPaths(dir)),
    runner,
    watchFiles: () => () => undefined,
    watchGit: () => () => undefined,
  })
  engine.markSource('session-finished', true)
  engine.reload()
  api = new RoutineApi(engine, store)
})

afterEach(async () => {
  await engine.stop()
  rmSync(dir, { recursive: true, force: true })
})

const DRAFT = {
  name: 'Nightly sweep',
  when: 'manual',
  in: '/tmp/td-project',
  prompt: 'Run the tests.',
}

describe('RoutineApi', () => {
  it('creates a routine, writes the file, and lists it', () => {
    const created = api.create(DRAFT)
    expect(created.ok).toBe(true)
    if (!created.ok) return
    expect(created.id).toBe('nightly-sweep')

    const onDisk = readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')
    expect(onDisk).toContain('# Nightly sweep')
    expect(onDisk).toContain('when: manual')
    expect(api.list()).toHaveLength(1)
  })

  it('refuses to overwrite a name the caller asked for by hand', () => {
    api.create({ ...DRAFT, id: 'sweep' })
    const again = api.create({ ...DRAFT, id: 'sweep', prompt: 'Something else.' })
    expect(again.ok).toBe(false)
    if (again.ok) return
    expect(again.problems[0]).toContain('already a routine')
  })

  it('refuses a routine that does exactly what an existing one does', () => {
    // The retry case: an agent that thinks its call failed and sends it again
    // must not end up with two copies both spending money on one trigger.
    api.create(DRAFT)
    const again = api.create(DRAFT)
    expect(again.ok).toBe(false)
    if (again.ok) return
    expect(again.problems[0]).toContain('already does exactly this')
    expect(api.list()).toHaveLength(1)
  })

  it('moves out of the way of a name that is taken when the routine differs', () => {
    api.create(DRAFT)
    const second = api.create({ ...DRAFT, prompt: 'Run the linter instead.' })
    expect(second.ok).toBe(true)
    if (!second.ok) return
    expect(second.id).toBe('nightly-sweep-2')
  })

  it('refuses an id that is really a path, without touching the filesystem', () => {
    const created = api.create({ ...DRAFT, id: '../../state' })
    expect(created.ok).toBe(false)
    expect(api.remove('../../state').ok).toBe(false)
    expect(api.get('../../state')).toBeNull()
  })

  it('refuses a draft with nothing to trigger it', () => {
    const created = api.create({ name: 'Nothing', in: '/tmp/x', prompt: 'Go.' })
    expect(created.ok).toBe(false)
    if (created.ok) return
    expect(created.problems.join(' ')).toContain('`when:`')
  })

  it('updates in place and keeps the same file', () => {
    api.create(DRAFT)
    const updated = api.update('nightly-sweep', { ...DRAFT, prompt: 'Run the tests twice.' })
    expect(updated.ok).toBe(true)
    expect(api.get('nightly-sweep')?.prompt).toBe('Run the tests twice.')
    expect(api.list()).toHaveLength(1)
  })

  it('refuses to update one that is not there', () => {
    expect(api.update('missing', DRAFT).ok).toBe(false)
  })

  it('removes one, and says when there was nothing to remove', () => {
    api.create(DRAFT)
    expect(api.remove('nightly-sweep').ok).toBe(true)
    expect(api.remove('nightly-sweep').ok).toBe(false)
    expect(api.list()).toHaveLength(0)
  })

  it('runs one by name', async () => {
    api.create(DRAFT)
    const result = await api.run('nightly-sweep')
    expect(result.started).toBe(true)
    await new Promise((resolve) => setImmediate(resolve))
    expect(runs).toEqual(['nightly-sweep'])
  })

  it('pauses and resumes without editing the file its owner wrote', () => {
    api.create(DRAFT)
    const before = readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')
    expect(api.pause('nightly-sweep', 'Not right now')).toBe(true)
    expect(api.get('nightly-sweep')?.state).toBe('paused')
    expect(readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')).toBe(before)
    expect(api.resume('nightly-sweep')).toBe(true)
    expect(api.get('nightly-sweep')?.state).toBe('armed')
  })

  it('will not run a paused routine, so pausing means something', async () => {
    api.create(DRAFT)
    api.pause('nightly-sweep', 'Not right now')
    const result = await api.run('nightly-sweep', 'copilot')
    expect(result.started).toBe(false)
    if (result.started) return
    expect(result.reason).toContain('Not right now')
  })
})

describe('registerRoutinesIpc', () => {
  it('registers every channel exactly once', () => {
    const handlers = new Map<string, unknown>()
    const ipcMain = {
      handle: (channel: string, handler: unknown) => {
        expect(handlers.has(channel)).toBe(false)
        handlers.set(channel, handler)
      },
    } as unknown as IpcMain

    registerRoutinesIpc(ipcMain, api)
    expect([...handlers.keys()].sort()).toEqual(
      [
        ROUTINES_CREATE,
        ROUTINES_DELETE,
        ROUTINES_GET,
        ROUTINES_LIST,
        ROUTINES_PAUSE,
        ROUTINES_RESUME,
        ROUTINES_RUN,
        ROUTINES_UPDATE,
      ].sort(),
    )
  })

  it('gives every channel a permission tier', () => {
    // The tier table is what phase 2 will build the confirmation prompt from.
    // A channel added without one would be a power the copilot gets for free.
    for (const channel of [
      ROUTINES_LIST,
      ROUTINES_GET,
      ROUTINES_CREATE,
      ROUTINES_UPDATE,
      ROUTINES_DELETE,
      ROUTINES_RUN,
      ROUTINES_PAUSE,
      ROUTINES_RESUME,
    ]) {
      expect(ROUTINE_TIERS[channel]).toBeDefined()
    }
    expect(ROUTINE_TIERS[ROUTINES_CREATE]).toBe('alter')
    expect(ROUTINE_TIERS[ROUTINES_DELETE]).toBe('alter')
    expect(ROUTINE_TIERS[ROUTINES_LIST]).toBe('read')
    expect(ROUTINE_TIERS[ROUTINES_RUN]).toBe('act')
  })
})
