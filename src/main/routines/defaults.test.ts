import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { chooseSeedFolder, DEFAULT_ROUTINES, seedDefaultRoutines, seedMarkerPath } from './defaults'
import { parseRoutine, type TriggerKind } from './format'

/**
 * The routines that are actually in the folder on a fresh install.
 *
 * The two assertions that matter most are the ones a reader would not think to
 * write: **every shipped file must parse**, because a default routine that
 * fails to load is the worst possible first impression of a feature, and it
 * would fail silently — the engine keeps a broken routine listed and disarmed,
 * which looks exactly like one that has not fired. And **every trigger must be
 * one this build actually emits**, because a routine armed against an event
 * nothing sends is indistinguishable from a quiet week.
 */

/** The triggers the engine has a live source for. See `defaults.ts`'s header. */
const EMITTED: readonly TriggerKind[] = [
  'session-finished',
  'session-failed',
  'session-idle',
  'alert',
  'git-change',
  'file-change',
  'schedule',
  'manual',
]

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-defaults-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the shipped routines', () => {
  it('all parse, with no problems and no warnings', () => {
    for (const entry of DEFAULT_ROUTINES) {
      const parsed = parseRoutine(entry.id, entry.file('/work/api'))
      expect(parsed.ok, `${entry.id}: ${parsed.ok ? '' : parsed.problems.join(' ')}`).toBe(true)
      if (!parsed.ok) continue
      // A warning means this build wrote a key it does not understand, which
      // for a file this build authored is a mistake rather than a courtesy.
      expect(parsed.warnings, `${entry.id}`).toEqual([])
      expect(parsed.routine.folder).toBe('/work/api')
    }
  })

  it('only uses triggers this build emits', () => {
    for (const entry of DEFAULT_ROUTINES) {
      const parsed = parseRoutine(entry.id, entry.file('/work/api'))
      if (!parsed.ok) continue
      for (const trigger of parsed.routine.triggers) {
        expect(EMITTED, `${entry.id} fires on ${trigger.kind}`).toContain(trigger.kind)
      }
    }
  })

  /**
   * `session-idle` deliberately excludes `input`, so a routine that watched for
   * idleness would never see the one state that means a human is blocking an
   * agent. The signal that does exist is the `session-blocked` alert.
   */
  it('watches for a blocked agent through the alert, not through idleness', () => {
    const parsed = parseRoutine('blocked-agent', named('blocked-agent').file('/work/api'))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.triggers).toEqual([
      { kind: 'alert', severity: null, alertKind: 'session-blocked' },
    ])
  })

  /**
   * The routine that catches a stuck agent overnight fires on the *loop* alert.
   *
   * It used to hang off `heavy-session` alone, because nothing in this app
   * emitted anything for a session that was repeating itself — and
   * `heavy-session` needs `HEAVY_MIN_TOKENS`, a million tokens, before it says
   * a word. So a session stuck on a failing build for forty minutes reached
   * nobody. `alerts.ts` now derives `loop` from the same `progress.ts` verdict
   * `sessions.result` reports, and this pins the wire between them: if somebody
   * removes the alert kind, or retargets the routine, this test is the thing
   * that notices rather than a person at 09:00 wondering why nothing was said.
   *
   * The cost trigger stays as the second one, deliberately. The two catch
   * different failures — expensive-and-productive is not looping — and dropping
   * it would trade one blind spot for another.
   */
  it('catches a looping session through the loop alert, not only through cost', () => {
    const parsed = parseRoutine('stuck-session', named('stuck-session').file('/work/api'))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.triggers).toEqual([
      { kind: 'alert', severity: null, alertKind: 'loop' },
      { kind: 'alert', severity: null, alertKind: 'heavy-session' },
    ])
    expect(parsed.routine.enabled).toBe(true)
  })

  it('leaves anything that starts a session switched off', () => {
    for (const id of ['ai-marker', 'quality-gate']) {
      const parsed = parseRoutine(id, named(id).file('/work/api'))
      expect(parsed.ok).toBe(true)
      if (!parsed.ok) continue
      // Both start sessions, and a session costs money. On by default would be
      // this app spending somebody's money on a machine they have just
      // installed it on.
      expect(parsed.routine.enabled, id).toBe(false)
    }
  })

  it('gives every routine a “do not” section written as prohibitions', () => {
    // The rules that actually hold are the ones written as prohibitions under a
    // hard header; the aspirational positive ones decay. This is that finding,
    // enforced.
    for (const entry of DEFAULT_ROUTINES) {
      expect(entry.file('/work/api'), entry.id).toMatch(/## Do not/)
    }
  })

  it('never asks an unattended run to write anything', () => {
    // A routine run has no `Write`, no `Edit` and no shell — see `runner.ts`.
    // A shipped routine that told it to prune a folder or commit a change would
    // be asking for something it cannot do, and the model would spend a turn
    // discovering that and then apologise.
    for (const entry of DEFAULT_ROUTINES) {
      const text = entry.file('/work/api')
      expect(text, entry.id).not.toMatch(/\bgit commit\b/)
      expect(text, entry.id).not.toMatch(/\bdelete the file\b/)
    }
  })
})

describe('seeding', () => {
  function rig() {
    const written = new Map<string, string>()
    return {
      written,
      deps: {
        write: (id: string, contents: string) => {
          written.set(id, contents)
          writeFileSync(join(dir, `${id}.md`), contents, 'utf8')
        },
        existing: () => [...written.keys()],
      },
    }
  }

  it('writes every default the first time and nothing the second', () => {
    const built = rig()
    const first = seedDefaultRoutines(dir, '/work/api', built.deps)
    expect(first.written).toEqual(DEFAULT_ROUTINES.map((entry) => entry.id))

    const second = seedDefaultRoutines(dir, '/work/api', built.deps)
    expect(second.written).toEqual([])
  })

  /**
   * The single most irritating behaviour a scaffolder can have.
   *
   * Somebody who deletes `overnight.md` has said they do not want it. An app
   * that puts it back on the next launch is an app arguing with them, and it is
   * why the marker file exists at all rather than the check being "is the file
   * there".
   */
  it('keeps a deleted routine deleted', () => {
    const built = rig()
    seedDefaultRoutines(dir, '/work/api', built.deps)
    built.written.delete('overnight')
    rmSync(join(dir, 'overnight.md'), { force: true })

    const again = seedDefaultRoutines(dir, '/work/api', built.deps)
    expect(again.written).toEqual([])
  })

  it('does not overwrite a hand-written routine that shares a name', () => {
    const built = rig()
    built.written.set('overnight', '# mine\n')
    const result = seedDefaultRoutines(dir, '/work/api', built.deps)
    expect(result.written).not.toContain('overnight')
    expect(built.written.get('overnight')).toBe('# mine\n')
  })

  it('waits rather than seeding a routine with nowhere to run', () => {
    const built = rig()
    const result = seedDefaultRoutines(dir, null, built.deps)
    expect(result.written).toEqual([])
    expect(result.skipped).toMatch(/No project folder/)
    // And no marker, so the next launch — after a project exists — tries again.
    expect(() => rmSync(seedMarkerPath(dir))).toThrow()
  })
})

function named(id: string) {
  const entry = DEFAULT_ROUTINES.find((candidate) => candidate.id === id)
  if (entry === undefined) throw new Error(`no default routine called ${id}`)
  return entry
}

/**
 * The folder choice, which was wrong on a real install before it was looked at.
 *
 * `createRoutines` picks the most recently opened project, and on the first
 * launch after the copilot has ever run, that project is the copilot's own
 * folder inside `<userData>` — because this app registers the folder a session
 * runs in. Eight routines were seeded watching the app's own storage. The rule
 * lives in `routines/index.ts`; this pins the shape of the answer.
 */
describe('choosing a folder to seed against', () => {
  const state = '/Users/x/Library/Application Support/terminaldeck'

  it('never points a routine at this app’s own storage', () => {
    expect(
      chooseSeedFolder(
        [{ path: `${state}/copilot` }, { path: '/Users/x/Projects/api' }],
        state,
      ),
    ).toBe('/Users/x/Projects/api')
  })

  it('does not exclude a folder that merely shares a prefix', () => {
    expect(chooseSeedFolder([{ path: `${state}-backup` }], state)).toBe(`${state}-backup`)
  })

  it('answers null when every project is inside it, so nothing is seeded yet', () => {
    expect(chooseSeedFolder([{ path: state }, { path: `${state}/copilot` }], state)).toBeNull()
  })
})
