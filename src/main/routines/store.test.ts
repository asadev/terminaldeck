import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MAX_FILE_BYTES, parseRoutine, serializeRoutine } from './format'
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

describe('reading and writing a routine file as text', () => {
  /**
   * A file with the things `parseRoutine` throws away: a second heading and a
   * blank-line rhythm somebody chose. Both survive a round trip through
   * `readText`/`saveText` and neither survives `serializeRoutine`, which is the
   * whole reason the text pair exists.
   */
  const HAND_WRITTEN = [
    '# Sweep',
    '',
    '# NOTE: raised the rate limit after the 2026-08 incident',
    '',
    'when: manual',
    'in: /tmp/project',
    '',
    '---',
    '',
    'Have a look.',
    '',
  ].join('\n')

  it('hands back the exact bytes on disk', () => {
    writeFileSync(join(dir, 'sweep.md'), HAND_WRITTEN, 'utf8')
    const store = new RoutineStore({ dir })
    const result = store.readText('sweep')
    expect(result.ok && result.text).toBe(HAND_WRITTEN)
    expect(result.ok && result.file).toBe(routineFilePath(dir, 'sweep'))
  })

  it('writes the exact bytes back, keeping what the parser would have dropped', () => {
    /*
     * The bug this exists to prevent, stated as a comparison.
     *
     * `store.save` serialises a parsed `Routine`, which is right for a caller
     * holding a value and wrong for a caller holding somebody's file: the
     * canonical writer keeps no second heading, so an editor that round-tripped
     * through it would delete the note above every time the person pressed
     * Save. Deleting somebody's writing to normalise their formatting is the
     * fastest way to teach them that the box in Settings is not really their
     * file.
     */
    const store = new RoutineStore({ dir })
    store.saveText('sweep', HAND_WRITTEN)
    expect(readFileSync(join(dir, 'sweep.md'), 'utf8')).toBe(HAND_WRITTEN)

    const parsed = store.read('sweep')
    expect(parsed.ok).toBe(true)
    // And what the canonical writer would have produced instead, so the
    // difference is visible here rather than inferred.
    expect(parsed.ok && serializeRoutine(parsed.routine)).not.toContain('NOTE: raised the rate limit')
  })

  it('leaves no half-written file behind, because the write is a rename', () => {
    const store = new RoutineStore({ dir })
    store.saveText('sweep', HAND_WRITTEN)
    /*
     * The whole directory rather than one name, and the change is not cosmetic.
     *
     * This asserted `sweep.md.tmp` was absent, which was a live claim while this
     * file wrote its own temp-and-rename with that fixed name — and became a
     * claim about a filename that can no longer occur the moment the write moved
     * to `writeFileAtomic`, whose temp names carry the pid and a counter. An
     * assertion that cannot fail is worse than none: it reads like coverage.
     * What is actually being promised is that a watcher sees one complete file
     * and nothing else, so that is what is checked.
     */
    expect(readdirSync(dir)).toEqual(['sweep.md'])
  })

  it('refuses an id that is really a path, in both directions', () => {
    // `routineFilePath` is the one function that turns an id into a path, and
    // it throws rather than answering "nowhere". Reading catches that and
    // reports it; writing is allowed to throw, because every caller of
    // `saveText` has already validated the id through `RoutineApi`.
    const store = new RoutineStore({ dir })
    expect(store.readText('../../etc/passwd').ok).toBe(false)
    expect(() => store.saveText('../../etc/passwd', 'x')).toThrow()
  })

  it('refuses to open a file too large to be a routine', () => {
    writeFileSync(join(dir, 'huge.md'), 'x'.repeat(MAX_FILE_BYTES + 1), 'utf8')
    const store = new RoutineStore({ dir })
    const result = store.readText('huge')
    expect(result.ok).toBe(false)
    expect(result.ok === false && result.error).toContain('larger than')
  })
})

/**
 * Saving on Windows, which nobody here can run — so it is pinned by construction
 * instead.
 *
 * Both writers in this file used to be `writeFileSync(`${file}.tmp`, …)` then
 * `renameSync`, and on POSIX that is exactly right: `rename(2)` is *guaranteed*
 * to replace the destination, which is why it has never once failed on a Mac.
 * Windows gives no such guarantee. `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` fails
 * with EPERM/EACCES/EBUSY while any process holds the destination open without
 * FILE_SHARE_DELETE, and Defender's real-time scan, the search indexer and any
 * backup agent all do that for a few milliseconds immediately after a file is
 * written. The result on Windows only: a routine somebody edited in the Settings
 * box occasionally does not save, intermittently and with nothing on screen to
 * say so. The fixed `.tmp` name was the second half — two windows of this app
 * saving at once wrote the same temp file.
 *
 * `atomic-write.ts` is the one answer to that, and `atomic-write.test.ts` pins
 * the retry against an injected filesystem with the platform forced to win32.
 * What is left for *this* file to promise is that the routines store actually
 * goes through it, which is a property of the source and is checked as one — the
 * same shape of guard `release-signing.test.ts` and `platform/env-path.test.ts`
 * use for decisions whose loss would be invisible on the machine that runs the
 * suite.
 */
describe('how a routine reaches the disk', () => {
  const source = readFileSync(fileURLToPath(new URL('./store.ts', import.meta.url)), 'utf8')

  it('does not do its own temp-and-rename', () => {
    // The *call*, not the word: the comment on `save` names both functions to
    // explain what they used to do and why that was wrong, and a scan that
    // could not tell an explanation from a call would make the explanation
    // undeletable. A `renameSync(` here would be green on every machine this is
    // developed on and would silently drop a Windows user's edits.
    expect(source).not.toMatch(/renameSync\(/)
    expect(source).not.toMatch(/writeFileSync\(/)
  })

  it('writes through the one helper that knows about Windows', () => {
    expect(source).toMatch(/import \{ writeFileAtomic \} from '\.\.\/atomic-write'/)
    // Both writers, not just the one somebody remembered: `save` is the tool and
    // engine path, `saveText` is the person's own typing.
    expect(source.match(/writeFileAtomic\(/g) ?? []).toHaveLength(2)
  })
})
