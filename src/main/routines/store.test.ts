import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { parseRoutine } from './format'
import { MAX_ROUTINES, RoutineStore, routineFilePath, routinesDirFor } from './store'
import { runtimeStateFileFor } from './runtime-state'

/**
 * The routines folder, against a real filesystem.
 *
 * Deliberately not mocked. The claims worth pinning are all about what actually
 * happens on disk — a file dropped in by hand becomes a routine, a broken one
 * stays visible, an id that looks like a path cannot become one, and a save
 * lands atomically — and none of those means anything against a fake `fs`.
 */

let dir: string

const GOOD = '# Sweep\n\nwhen: manual\nin: /tmp/project\n\n---\n\nHave a look.\n'

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-routines-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('where the folder is', () => {
  it('is beside the copilot folder and never inside it', () => {
    /*
     * A path assertion doing security work, so it says why.
     *
     * `<userData>/copilot` is the only directory the copilot session may write
     * to, and this store's whole design is that a `.md` file appearing in its
     * folder is a routine that really runs. Inside the boundary those two facts
     * multiply into a way for the agent to schedule its own work with no
     * confirmation; outside it, the kernel refuses the write. The real proof is
     * `copilot-writable-boundary.test.ts` running `sandbox-exec`; this is the
     * cheap pin that fails first if somebody moves the folder back.
     */
    expect(routinesDirFor('/data')).toBe(join('/data', 'routines'))
    expect(routinesDirFor('/data')).not.toContain(join('/data', 'copilot'))
    expect(runtimeStateFileFor('/data')).toBe(join('/data', 'routine-state.json'))
    expect(runtimeStateFileFor('/data')).not.toContain(join('/data', 'copilot'))
  })
})

describe('RoutineStore', () => {
  it('is empty, not broken, before the folder exists', () => {
    const store = new RoutineStore({ dir: join(dir, 'not-there') })
    expect(store.list()).toEqual([])
  })

  it('reads a file somebody dropped in by hand', () => {
    writeFileSync(join(dir, 'sweep.md'), GOOD, 'utf8')
    const store = new RoutineStore({ dir })
    const listed = store.list()
    expect(listed).toHaveLength(1)
    expect(listed[0].ok).toBe(true)
    if (!listed[0].ok) return
    expect(listed[0].routine.name).toBe('Sweep')
    expect(listed[0].id).toBe('sweep')
  })

  it('keeps a broken routine in the list, with its problems', () => {
    writeFileSync(join(dir, 'broken.md'), '# Broken\n\nwhen: nonsense\n', 'utf8')
    const store = new RoutineStore({ dir })
    const listed = store.list()
    expect(listed).toHaveLength(1)
    expect(listed[0].ok).toBe(false)
    if (listed[0].ok) return
    expect(listed[0].problems.join(' ')).toContain('nonsense')
  })

  it('ignores anything that is not a routine file', () => {
    writeFileSync(join(dir, 'notes.txt'), 'hello', 'utf8')
    mkdirSync(join(dir, 'archive'))
    writeFileSync(join(dir, 'sweep.md'), GOOD, 'utf8')
    expect(new RoutineStore({ dir }).list()).toHaveLength(1)
  })

  it('reports a filename that is not a usable routine name instead of loading it', () => {
    writeFileSync(join(dir, 'Not Valid.md'), GOOD, 'utf8')
    const listed = new RoutineStore({ dir }).list()
    expect(listed[0].ok).toBe(false)
  })

  it('saves and reads back what it saved', () => {
    const parsed = parseRoutine('sweep', GOOD)
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    const store = new RoutineStore({ dir })
    store.save(parsed.routine)
    const back = store.read('sweep')
    expect(back.ok).toBe(true)
    if (!back.ok) return
    expect(back.routine).toEqual(parsed.routine)
  })

  it('leaves no temp file behind, so a save is one event to a watcher', () => {
    const parsed = parseRoutine('sweep', GOOD)
    if (!parsed.ok) throw new Error('fixture does not parse')
    const store = new RoutineStore({ dir })
    store.save(parsed.routine)
    expect(new RoutineStore({ dir }).list()).toHaveLength(1)
  })

  it('removes one, and says when there was nothing to remove', () => {
    const parsed = parseRoutine('sweep', GOOD)
    if (!parsed.ok) throw new Error('fixture does not parse')
    const store = new RoutineStore({ dir })
    store.save(parsed.routine)
    expect(store.remove('sweep')).toBe(true)
    expect(store.remove('sweep')).toBe(false)
    expect(store.list()).toEqual([])
  })

  it('refuses to turn an id into a path outside the folder', () => {
    // The whole class, closed in one place: `routines.delete` is reachable by
    // the copilot in phase 2 and this is the argument it will eventually send.
    expect(() => routineFilePath(dir, '../../state')).toThrow()
    expect(() => routineFilePath(dir, '/etc/passwd')).toThrow()
    expect(() => routineFilePath(dir, '..')).toThrow()
    const store = new RoutineStore({ dir })
    expect(() => store.remove('../../state')).toThrow()
  })

  it('stops loading past the cap rather than watching ten thousand folders', () => {
    for (let index = 0; index < MAX_ROUTINES + 3; index++) {
      writeFileSync(join(dir, `r${String(index).padStart(4, '0')}.md`), GOOD, 'utf8')
    }
    const listed = new RoutineStore({ dir }).list()
    expect(listed.filter((item) => item.ok)).toHaveLength(MAX_ROUTINES)
    expect(listed.filter((item) => !item.ok).length).toBeGreaterThan(0)
  })

  it('notices a hand edit, with a real watcher', async () => {
    const store = new RoutineStore({ dir })
    let changes = 0
    store.startWatching(() => {
      changes += 1
    }, 20)
    // chokidar returns before it is actually watching — the same trap
    // `transcript.ts` documents — so the write is delayed rather than issued
    // straight after `startWatching`.
    await new Promise((resolve) => setTimeout(resolve, 250))
    writeFileSync(join(dir, 'sweep.md'), GOOD, 'utf8')
    for (let waited = 0; waited < 40 && changes === 0; waited++) {
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    expect(changes).toBeGreaterThan(0)
    expect(store.list()).toHaveLength(1)
    await store.stop()
  })

  it('stops watching when it is stopped', async () => {
    const store = new RoutineStore({ dir })
    let changes = 0
    store.startWatching(() => {
      changes += 1
    }, 10)
    await new Promise((resolve) => setTimeout(resolve, 250))
    await store.stop()
    writeFileSync(join(dir, 'sweep.md'), GOOD, 'utf8')
    await new Promise((resolve) => setTimeout(resolve, 200))
    expect(changes).toBe(0)
  })
})
