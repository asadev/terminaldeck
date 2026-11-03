import { describe, expect, it } from 'vitest'
import cold from './fixtures/cli-check-cold.json'
import regression from './fixtures/cli-check-regression.json'
import clean from './fixtures/cli-check-clean.json'
import web from './fixtures/web-check-regression.json'
import doctor from './fixtures/doctor.json'
import init from './fixtures/init.json'
import shipCut from './fixtures/ship-cut.json'
import shipRefused from './fixtures/ship-refused.json'
import shipForced from './fixtures/ship-forced.json'
import {
  fileSafe,
  lastRunFromFile,
  MAX_CHANGES,
  MAX_VALUE_CHARS,
  notCheckedLine,
  picturesFor,
  plainTitle,
  readinessFromDoctor,
  readinessFromPlan,
  toDescription,
  toMarkOutcome,
  toResults,
  toSetupOutcome,
  valueText,
} from './read'

/**
 * The readers, against what Stays Fixed 0.15.0 actually printed.
 *
 * Every fixture is real output from a real run on a two-file project (a
 * command-line greeter and a one-page shop), captured on 2026-10-04 and trimmed
 * — see `fixtures/`. The point of using them rather than hand-written objects
 * is the one CLAUDE.md makes about this codebase: it has been wrong, again and
 * again, in ways only real data exposed.
 */

describe('a check, as the page says it', () => {
  it('calls the cold start what it is: nothing compared, not a pass', () => {
    const results = toResults(cold)
    expect(results.verdict).toBe('not-compared')
    expect(results.headline).toMatch(/Nothing to compare against yet/)
    expect(results.differences).toEqual([])
    // No "all 12 things are unchanged" — nothing was compared, so nothing is known to be unchanged.
    expect(results.unchanged).toBe('')
    expect(results.against).toBeNull()
  })

  it('lists only the difference nobody asked for, with both values and the reason a person must look', () => {
    const results = toResults(regression)
    expect(results.verdict).toBe('differences')
    expect(results.headline).toBe('1 difference nobody asked for.')
    expect(results.against).toBe('1.0.0')
    expect(results.differences).toHaveLength(1)
    const [difference] = results.differences
    expect(difference?.changes[0]).toEqual({
      what: expect.stringContaining('printed to the screen'),
      before: 'Hello, --help!\nTotal: 10.00\n',
      after: 'Hello, --help!\nTotal: 10.0\n',
      kind: 'changed',
    })
    // "Total" is money to the engine, so no agent may wave it through.
    expect(difference?.needsPerson).toBe(true)
    expect(difference?.needsPersonWhy).toMatch(/money/)
    // The escaped line breaks inside the quoted values are gone from the title.
    expect(difference?.title).not.toMatch(/\\n/)
  })

  it('says everything unchanged in one line with a count, and never lists it', () => {
    const results = toResults(regression)
    expect(results.unchanged).toBe('Everything else it looked at — 11 things — is unchanged.')
    expect(toResults(web).unchanged).toBe('Everything else it looked at — 47 things — is unchanged.')
  })

  it('reads a clean run as clean', () => {
    const results = toResults(clean)
    expect(results.verdict).toBe('clean')
    expect(results.headline).toBe('Nothing that worked has changed.')
    expect(results.unchanged).toMatch(/^All \d+ things it looked at are unchanged\.$/)
  })

  it('says what was not looked at in one plain line rather than in capitals', () => {
    const line = toResults(regression).notChecked ?? ''
    expect(line).toMatch(/^Not everything was checked:/)
    expect(line).not.toMatch(/NOT EVERYTHING/)
    expect(notCheckedLine({ gaps: [] }, 0)).toBeNull()
  })

  it('carries a refusal to run as a result that says why, with the hint', () => {
    const results = toResults({ error: { message: 'This folder is not a git repository.', hint: 'Run git init.' } })
    expect(results.verdict).toBe('could-not-run')
    expect(results.headline).toBe('This folder is not a git repository. Run git init.')
  })

  it('reads a blocked verdict by its one gap, which is the error', () => {
    const results = toResults({
      blocked: true,
      reference: { id: '' },
      candidate: { id: '' },
      findings: [],
      coverage: { paths: 0, gaps: [{ what: 'Everything.', why: 'No settings file here.' }] },
      summary: 'The check could not be run, so this is not a pass and not a failure. No settings file here.',
    })
    expect(results.verdict).toBe('could-not-run')
    expect(results.headline).toBe('No settings file here.')
  })

  it('shows a few changes and counts the rest, and the full report keeps every one', () => {
    const many = {
      ...regression,
      findings: [
        {
          ...regression.findings[0],
          count: 10,
          differences: Array.from({ length: 10 }, (_, i) => ({ path: `p${i}`, kind: 'changed', reference: 'a', candidate: 'b' })),
        },
      ],
    }
    const short = toResults(many)
    expect(short.differences[0]?.changes).toHaveLength(MAX_CHANGES)
    expect(short.differences[0]?.more).toBe(10 - MAX_CHANGES)
    const full = toResults(many, undefined, { full: true })
    expect(full.differences[0]?.changes).toHaveLength(10)
    expect(full.differences[0]?.more).toBe(0)
  })

  it('cuts a long value and says how much was cut', () => {
    const text = valueText('x'.repeat(MAX_VALUE_CHARS + 25)) ?? ''
    expect(text.endsWith('(25 more characters)')).toBe(true)
    expect(valueText('x'.repeat(MAX_VALUE_CHARS + 25), true)).toHaveLength(MAX_VALUE_CHARS + 25)
    expect(valueText(undefined)).toBeNull()
    expect(valueText({ a: 1 })).toBe('{"a":1}')
  })

  it('turns escaped characters in a title back into what a person would type', () => {
    expect(plainTitle('is now "a\\nb" where it was \\"c\\"')).toBe('is now "a b" where it was "c"')
  })
})

describe('the last check on disk', () => {
  it('is the same reader over the verdict the engine keeps as a string', () => {
    const file = JSON.stringify({ at: '2026-10-03T23:42:05.690Z', result: JSON.stringify(clean) })
    expect(lastRunFromFile(file)?.verdict).toBe('clean')
    expect(lastRunFromFile('not json')).toBeNull()
    expect(lastRunFromFile(JSON.stringify({ result: '{}' }))).toBeNull()
  })
})

describe('pictures', () => {
  const files = [
    'git-76e2ab57c913-single-the-front-page-the-front-page-end.png',
    'work-0f72dd0e31b2-a-the-front-page-the-front-page-end.png',
    'work-0f72dd0e31b2-b-the-front-page-the-front-page-end.png',
    'work-0f72dd0e31b2-a--about.html--about.html-end.png',
  ]

  it('pairs the old build’s live picture with the checked build’s first run, by journey', () => {
    const [difference] = toResults(web).differences
    const found = picturesFor(difference ?? { journeys: [] }, files, 'work-0f72dd0e31b2', 'git-76e2ab57c913')
    const front = found.find((entry) => entry.journey === 'the front page')
    expect(front).toEqual({
      journey: 'the front page',
      before: 'git-76e2ab57c913-single-the-front-page-the-front-page-end.png',
      after: 'work-0f72dd0e31b2-a-the-front-page-the-front-page-end.png',
    })
    // The about page only has the checked build's picture kept, so it has no before.
    expect(found.find((entry) => entry.journey === '/about.html')).toEqual({
      journey: '/about.html',
      before: null,
      after: 'work-0f72dd0e31b2-a--about.html--about.html-end.png',
    })
  })

  it('names journeys the way the engine names its files', () => {
    expect(fileSafe('the front page')).toBe('the-front-page')
    expect(fileSafe('/about.html')).toBe('-about.html')
  })

  it('has nothing to show for a product with no screen', () => {
    const [difference] = toResults(regression).differences
    expect(picturesFor(difference ?? { journeys: [] }, files, 'work-b63f5e292f71', 'git-a54e4cd3e911')).toEqual([])
  })
})

describe('what this Mac can check', () => {
  it('reads doctor into ready, gaps with their exact fix, and one line of not-here', () => {
    const readiness = readinessFromDoctor(doctor)
    expect(readiness.ready).toContain('web apps and sites')
    expect(readiness.gaps.map((gap) => gap.name)).toEqual(['command-line tools and libraries', 'servers and APIs'])
    const server = readiness.gaps.find((gap) => gap.name === 'servers and APIs')
    expect(server?.byPerson).toBe(true)
    expect(server?.fix).toMatch(/Docker/)
    expect(readiness.gaps.find((gap) => gap.name === 'command-line tools and libraries')?.byPerson).toBe(false)
    expect(readiness.notHere).toContain('Electron desktop apps')
    expect(readiness.git).toBe(true)
    expect(readiness.summary).not.toBe('')
  })

  it('puts a missing git repository first, with the fix', () => {
    const readiness = readinessFromDoctor({ ...doctor, project: { ...doctor.project, isGitRepo: false } })
    expect(readiness.gaps[0]).toMatchObject({ what: 'a git repository', fix: 'git init' })
  })

  it('never lists "staysfixed ship" as a fix — that is the page’s own button', () => {
    const readiness = readinessFromPlan(init)
    expect(readiness.ready).toEqual(['the `greet` command'])
    expect(readiness.gaps.some((gap) => /staysfixed ship/.test(gap.fix))).toBe(false)
  })

  it('reports what Set up wrote, relative to the project', () => {
    const outcome = toSetupOutcome(init, '/Users/you/Projects/tiny-greeter', null)
    expect(outcome.ok).toBe(true)
    expect(outcome.wrote).toEqual(['staysfixed.config.js', '.gitignore'])
    expect(outcome.readiness?.ready).toEqual(['the `greet` command'])
    expect(toSetupOutcome({}, '/x', 'The engine stopped.')).toEqual({ ok: false, wrote: [], problem: 'The engine stopped.', readiness: null })
  })
})

describe('marking a build as good', () => {
  it('says it moved when it moved', () => {
    expect(toMarkOutcome(shipCut, null)).toMatchObject({ marked: true, refused: null, refusedFor: null })
    expect(toMarkOutcome(shipForced, null).marked).toBe(true)
  })

  it('offers "anyway" only for a refusal about differences the person can see', () => {
    const outcome = toMarkOutcome(shipRefused, null)
    expect(outcome).toMatchObject({ marked: false, refusedFor: 'differences' })
    expect(outcome.summary).toBe('The last check found 1 difference nobody asked for. Marking this build as good makes it the new normal.')
  })

  it('sends a build nobody checked to Run check, never to "anyway"', () => {
    const outcome = toMarkOutcome({ ok: true, cut: false, decision: { state: 'never-checked' }, refused: 'Refusing…' }, null)
    expect(outcome.refusedFor).toBe('unchecked')
    expect(outcome.summary).toMatch(/Run a check first/)
  })

  it('answers with the failure when the engine said nothing', () => {
    expect(toMarkOutcome({}, 'It took too long.')).toMatchObject({ ok: false, summary: 'It took too long.' })
  })
})

describe('a project’s guards and good build', () => {
  it('reads the describe script’s answer and names the build by its version', () => {
    const description = toDescription({
      product: 'tiny-greeter',
      guards: [{ name: 'the total keeps its pennies', because: 'It printed 10.0 once.', file: '/p/.staysfixed/guards/a.js' }, { name: '' }],
      reference: { buildId: 'git-a54e4cd3e911', setAt: '2026-10-03T23:41:27Z', setBy: 'staysfixed ship', version: '1.0.0', forced: false },
    })
    expect(description.guards).toEqual([{ name: 'the total keeps its pennies', because: 'It printed 10.0 once.', file: '/p/.staysfixed/guards/a.js' }])
    expect(description.reference?.name).toBe('1.0.0')
    expect(toDescription({}).reference).toBeNull()
  })
})
