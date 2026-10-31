import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import { TIERS } from '../deck-control/surface'
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
  ROUTINES_SAVE_TEXT,
  ROUTINES_TEXT,
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
        ROUTINES_SAVE_TEXT,
        ROUTINES_TEXT,
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
      ROUTINES_TEXT,
      ROUTINES_CREATE,
      ROUTINES_UPDATE,
      ROUTINES_DELETE,
      ROUTINES_RUN,
      ROUTINES_PAUSE,
      ROUTINES_RESUME,
      ROUTINES_SAVE_TEXT,
    ]) {
      expect(ROUTINE_TIERS[channel]).toBeDefined()
    }
    expect(ROUTINE_TIERS[ROUTINES_CREATE]).toBe('alter')
    expect(ROUTINE_TIERS[ROUTINES_DELETE]).toBe('alter')
    expect(ROUTINE_TIERS[ROUTINES_LIST]).toBe('read')
    expect(ROUTINE_TIERS[ROUTINES_RUN]).toBe('act')
  })
})

describe('editing a routine file as text', () => {
  const withNote = [
    '# Nightly sweep',
    '',
    '# NOTE: leave the folder alone, the path is deliberate',
    '',
    'when: manual',
    'in: /tmp/td-project',
    '',
    '---',
    '',
    'Run the tests twice.',
    '',
  ].join('\n')

  it('hands a person the file rather than the parsed prompt', () => {
    api.create(DRAFT)
    const result = api.text('nightly-sweep')
    expect(result.ok).toBe(true)
    // The whole file, header and all — the trigger and the folder are the parts
    // of a routine that are actually wrong when a routine is wrong, and neither
    // is in `view.prompt`.
    expect(result.ok && result.text).toContain('when: manual')
    expect(result.ok && result.text).toContain('Run the tests.')
  })

  it('writes what was typed, verbatim, and reloads the engine', () => {
    api.create(DRAFT)
    const saved = api.saveText('nightly-sweep', withNote)
    expect(saved.ok).toBe(true)

    // Byte for byte, including the second heading `serializeRoutine` drops.
    expect(readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')).toBe(withNote)
    // And live: the engine has re-read the folder, so the next trigger uses it.
    expect(api.get('nightly-sweep')?.prompt).toBe('Run the tests twice.')
  })

  it('refuses text that would not parse, and writes nothing at all', () => {
    /*
     * A routine that stopped working is the failure this whole feature must not
     * have, and it is silent: the file is still there, the list still shows it,
     * and nothing fires. So the parse happens before the write and the parser's
     * own sentences come back — "this routine has no `when:` line" is something
     * a person can act on in the box they are already looking at.
     */
    api.create(DRAFT)
    const before = readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')
    const result = api.saveText('nightly-sweep', '# Broken\n\nin: /tmp/td-project\n\n---\n\nGo.\n')

    expect(result.ok).toBe(false)
    expect(result.ok === false && result.problems.join(' ')).toContain('`when:`')
    expect(readFileSync(join(dir, 'routines', 'nightly-sweep.md'), 'utf8')).toBe(before)
  })

  it('refuses an id that is really a path, and one that is not there', () => {
    expect(api.text('../../state').ok).toBe(false)
    expect(api.saveText('../../state', withNote).ok).toBe(false)
    // Not a create. `saveText` is an editor for a routine somebody is looking
    // at; making a routine is `create`, which checks the cap, the duplicate and
    // the name.
    expect(api.saveText('never-existed', withNote).ok).toBe(false)
    expect(api.list()).toHaveLength(0)
  })

  it('refuses anything that is not a string', () => {
    api.create(DRAFT)
    for (const junk of [undefined, null, 3, {}, ['a']]) {
      expect(api.saveText('nightly-sweep', junk).ok, String(junk)).toBe(false)
    }
  })
})

describe('the raw-text write is a human route and cannot become a copilot one', () => {
  /**
   * The trap this guards, in one sentence: `saveText` writes chosen bytes into
   * the routines folder, and that folder was moved out of the copilot's
   * writable reach precisely so that authoring an automation takes a person.
   *
   * Every other write here goes through `routineFromDraft`, whose `headerValue`
   * strips newlines out of each field — which is what makes `create` and
   * `update` safe to hand to a language model, because a `name` of
   * `"Sweep\nin: /"` cannot become a routine rooted at the disk. `saveText` has
   * no such guard and cannot have one: the point is that a person types the
   * header themselves. So it is wider than the alter tier, and there is no tier
   * it belongs at.
   */
  it('marks it `human`, which is not a tier deck-control has', () => {
    expect(ROUTINE_TIERS[ROUTINES_SAVE_TEXT]).toBe('human')
    expect(ROUTINE_TIERS[ROUTINES_UPDATE]).toBe('alter')

    /*
     * And the claim that makes `human` mean something rather than being a label.
     * `deck-control`'s own `Tier` is exactly three values and every catalogue
     * entry must declare one of them, so a tool exposing this operation would
     * not typecheck until somebody first widened that union — a deliberate,
     * visible act rather than a mistake made in passing.
     */
    expect(TIERS).toEqual(['read', 'act', 'alter'])
    expect(TIERS).not.toContain('human')
  })

  it('is absent from the copilot’s tool catalogue', () => {
    // Read as text rather than by importing the catalogue, because the
    // assertion is about what is *not* declared and an import can only show
    // what is. A future `routines.list` tool is fine and expected; a tool that
    // writes a routine file's bytes is what must never appear.
    const catalogue = readFileSync(join(__dirname, '..', 'deck-control', 'catalogue.ts'), 'utf8')
    for (const name of ['saveText', 'save-text', 'routines.text']) {
      expect(catalogue, name).not.toContain(name)
    }
  })
})
