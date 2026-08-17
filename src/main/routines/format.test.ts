import { describe, expect, it } from 'vitest'
import {
  DEFAULT_MAX_RUNS_PER_HOUR,
  HARD_MAX_RUNS_PER_HOUR,
  isValidId,
  MAX_PROMPT_BYTES,
  parseDuration,
  parseRoutine,
  parseTrigger,
  routineFromDraft,
  serializeRoutine,
  slugify,
  suggestId,
  type Routine,
} from './format'

/**
 * The routine file format.
 *
 * Two things are worth pinning here above all others, and they are the two that
 * would be silently wrong rather than loudly wrong:
 *
 *  - **A round trip changes nothing.** `routines.create` writes a file and a
 *    person then edits it in an editor; if serialising a parsed routine did not
 *    reproduce it, the app would rewrite somebody's file every time it touched
 *    it, and the damage would be invisible until they looked.
 *  - **A draft cannot become a header.** A draft arrives from a renderer and,
 *    in phase 2, from a language model. A `name` containing a newline is the
 *    whole exploit.
 */

const GOOD = `# Nightly sweep

when: schedule 02:30
when: session-failed
in: /Users/asad/Projects/terminaldeck
enabled: yes
overlap: skip
max-runs-per-hour: 4
quiet-for: 2m
expect-every: 26h

---

Run the tests. If anything fails, say what.
`

describe('parseRoutine', () => {
  it('reads a whole routine', () => {
    const result = parseRoutine('nightly-sweep', GOOD)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    const routine = result.routine
    expect(routine.id).toBe('nightly-sweep')
    expect(routine.name).toBe('Nightly sweep')
    expect(routine.triggers).toHaveLength(2)
    expect(routine.triggers[0]).toEqual({
      kind: 'schedule',
      schedule: { kind: 'at', minutes: 150, days: null },
    })
    expect(routine.triggers[1]).toEqual({ kind: 'session-failed' })
    expect(routine.folder).toBe('/Users/asad/Projects/terminaldeck')
    expect(routine.overlap).toBe('skip')
    expect(routine.maxRunsPerHour).toBe(4)
    expect(routine.quietForMs).toBe(120_000)
    expect(routine.expectEveryMs).toBe(26 * 3_600_000)
    expect(routine.prompt).toBe('Run the tests. If anything fails, say what.')
  })

  it('round-trips: serialise, parse, and nothing has moved', () => {
    const first = parseRoutine('nightly-sweep', GOOD)
    expect(first.ok).toBe(true)
    if (!first.ok) return
    const second = parseRoutine('nightly-sweep', serializeRoutine(first.routine))
    expect(second.ok).toBe(true)
    if (!second.ok) return
    expect(second.routine).toEqual(first.routine)
  })

  it('keeps the file short by leaving defaults out of it', () => {
    const parsed = parseRoutine(
      'quick',
      '# Quick\n\nwhen: manual\nin: /tmp/x\n\n---\n\nDo the thing.\n',
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    const text = serializeRoutine(parsed.routine)
    expect(text).not.toContain('max-runs-per-hour')
    expect(text).not.toContain('quiet-for')
    expect(text).toContain('when: manual')
    expect(text).toContain('in: /tmp/x')
  })

  it('reads a file an editor saved with CRLF', () => {
    const parsed = parseRoutine('crlf', GOOD.replace(/\n/g, '\r\n'))
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.folder).toBe('/Users/asad/Projects/terminaldeck')
    expect(parsed.routine.prompt).toBe('Run the tests. If anything fails, say what.')
  })

  it('names every missing part rather than failing once', () => {
    const parsed = parseRoutine('empty', '# Nothing\n')
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.problems.join(' ')).toContain('`when:`')
    expect(parsed.problems.join(' ')).toContain('`in:`')
    expect(parsed.problems.join(' ')).toContain('`---`')
  })

  it('keeps a key it does not understand instead of deleting it', () => {
    const parsed = parseRoutine(
      'future',
      '# Future\n\nwhen: manual\nin: /tmp/x\nnotify: slack\n\n---\n\nHello.\n',
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.warnings.join(' ')).toContain('notify')
    expect(serializeRoutine(parsed.routine)).toContain('notify: slack')
  })

  it('clamps a ceiling a hand edit tried to raise, and says so', () => {
    const parsed = parseRoutine(
      'greedy',
      '# Greedy\n\nwhen: manual\nin: /tmp/x\nmax-runs-per-hour: 100000\n\n---\n\nGo.\n',
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.maxRunsPerHour).toBe(HARD_MAX_RUNS_PER_HOUR)
    expect(parsed.warnings.join(' ')).toContain('lowered')
  })

  it('defaults the ceilings when the file says nothing', () => {
    const parsed = parseRoutine('plain', '# Plain\n\nwhen: manual\nin: /tmp/x\n\n---\n\nGo.\n')
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.maxRunsPerHour).toBe(DEFAULT_MAX_RUNS_PER_HOUR)
  })

  it('refuses a prompt too large to re-send on every fire', () => {
    const huge = 'x'.repeat(MAX_PROMPT_BYTES + 1)
    const parsed = parseRoutine('huge', `# Huge\n\nwhen: manual\nin: /tmp/x\n\n---\n\n${huge}\n`)
    expect(parsed.ok).toBe(false)
  })

  it('refuses an id that could become a path', () => {
    expect(parseRoutine('../../state', GOOD).ok).toBe(false)
    expect(parseRoutine('Nightly Sweep', GOOD).ok).toBe(false)
  })

  it('only splits on the first --- so a prompt may contain one', () => {
    const parsed = parseRoutine(
      'ruled',
      '# Ruled\n\nwhen: manual\nin: /tmp/x\n\n---\n\nOne\n\n---\n\nTwo\n',
    )
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.prompt).toBe('One\n\n---\n\nTwo')
  })
})

describe('parseTrigger', () => {
  it('reads each kind', () => {
    expect(parseTrigger('session-finished')).toEqual({ trigger: { kind: 'session-finished' } })
    expect(parseTrigger('session-idle 15m')).toEqual({
      trigger: { kind: 'session-idle', afterMs: 900_000 },
    })
    expect(parseTrigger('alert critical')).toEqual({
      trigger: { kind: 'alert', severity: 'critical', alertKind: null },
    })
    expect(parseTrigger('alert session-blocked')).toEqual({
      trigger: { kind: 'alert', severity: null, alertKind: 'session-blocked' },
    })
    expect(parseTrigger('file-change src/**')).toEqual({
      trigger: { kind: 'file-change', glob: 'src/**' },
    })
    expect(parseTrigger('git-change')).toEqual({ trigger: { kind: 'git-change' } })
    expect(parseTrigger('manual')).toEqual({ trigger: { kind: 'manual' } })
  })

  it('refuses an idle trigger with no unit, because 15 is ambiguous', () => {
    const result = parseTrigger('session-idle 15')
    expect('problem' in result).toBe(true)
  })

  it('lists the triggers it does know when it does not know one', () => {
    const result = parseTrigger('when-the-moon-is-full')
    expect('problem' in result).toBe(true)
    if (!('problem' in result)) return
    expect(result.problem).toContain('session-finished')
    expect(result.problem).toContain('schedule 09:00')
  })
})

describe('parseDuration', () => {
  it('takes a unit and refuses a bare number', () => {
    expect(parseDuration('30s')).toBe(30_000)
    expect(parseDuration('15m')).toBe(900_000)
    expect(parseDuration('2h')).toBe(7_200_000)
    expect(parseDuration('1d')).toBe(86_400_000)
    expect(parseDuration('15')).toBeNull()
    expect(parseDuration('0m')).toBeNull()
    expect(parseDuration('')).toBeNull()
  })
})

describe('ids', () => {
  it('produces only characters with no meaning to a filesystem', () => {
    expect(slugify('Nightly Sweep!')).toBe('nightly-sweep')
    expect(slugify('../../etc/passwd')).toBe('etc-passwd')
    expect(isValidId(slugify('../../etc/passwd'))).toBe(true)
    expect(isValidId('../x')).toBe(false)
    expect(isValidId('CON')).toBe(false)
    expect(isValidId('')).toBe(false)
  })

  it('finds a free name beside one that is taken', () => {
    expect(suggestId('Nightly sweep', new Set(['nightly-sweep']))).toBe('nightly-sweep-2')
  })

  it('refuses a name Windows cannot make a file out of', () => {
    // `con.md` cannot be created on Windows and the error says nothing useful.
    // Refused everywhere so a routines folder copied to a PC still works.
    expect(isValidId('con')).toBe(false)
    expect(isValidId('lpt1')).toBe(false)
    expect(suggestId('Con', new Set())).toBe('con-routine')
    expect(suggestId('', new Set())).toBe('routine')
  })
})

describe('routineFromDraft', () => {
  it('builds a routine from the shape a settings pane or a tool would send', () => {
    const parsed = routineFromDraft('sweep', {
      name: 'Sweep',
      when: ['git-change', 'manual'],
      in: '/tmp/project',
      prompt: 'Look at what changed.',
      overlap: 'skip',
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.triggers.map((trigger) => trigger.kind)).toEqual(['git-change', 'manual'])
    expect(parsed.routine.overlap).toBe('skip')
  })

  it('cannot be made to write a second header line from a name', () => {
    const parsed = routineFromDraft('sneaky', {
      name: 'Sweep\nin: /',
      when: 'manual',
      in: '/tmp/project',
      prompt: 'Hello.',
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    // The folder is the one that was actually supplied, not the one smuggled
    // through the label.
    expect(parsed.routine.folder).toBe('/tmp/project')
    expect(parsed.routine.name).not.toContain('\n')
  })

  it('cannot be made to smuggle a trigger through the prompt', () => {
    const parsed = routineFromDraft('sneaky2', {
      name: 'Sweep',
      when: 'manual',
      in: '/tmp/project',
      prompt: 'when: schedule every 5m\nin: /\n',
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.triggers).toEqual([{ kind: 'manual' }])
    expect(parsed.routine.folder).toBe('/tmp/project')
  })

  it('goes through the same clamps a hand-edited file does', () => {
    const parsed = routineFromDraft('greedy', {
      name: 'Greedy',
      when: 'manual',
      in: '/tmp/project',
      prompt: 'Go.',
      maxRunsPerHour: 999999,
    })
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.routine.maxRunsPerHour).toBe(HARD_MAX_RUNS_PER_HOUR)
  })

  it('refuses a draft with no trigger', () => {
    const parsed = routineFromDraft('nothing', { name: 'Nothing', in: '/tmp/x', prompt: 'Go.' })
    expect(parsed.ok).toBe(false)
  })
})

describe('serializeRoutine', () => {
  it('writes the prompt below the rule, verbatim', () => {
    const routine: Routine = {
      id: 'x',
      name: 'X',
      triggers: [{ kind: 'manual' }],
      folder: '/tmp/x',
      prompt: 'Line one\n\nLine two',
      enabled: false,
      overlap: 'queue',
      maxRunsPerHour: DEFAULT_MAX_RUNS_PER_HOUR,
      maxRunsPerDay: 24,
      quietForMs: 30_000,
      expectEveryMs: null,
      unknown: {},
    }
    const text = serializeRoutine(routine)
    expect(text).toContain('enabled: no')
    expect(text.slice(text.indexOf('---') + 4)).toContain('Line one\n\nLine two')
  })
})
