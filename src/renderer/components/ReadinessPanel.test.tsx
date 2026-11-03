import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  actionFor,
  AgentPills,
  CheckRow,
  fileUrlFor,
  headlineFor,
  ReadinessPanel,
  reportFor,
  ScoreRing,
  sortChecks,
  type ReadinessCheck,
  type ReadinessFix,
  type ReadinessForAgent,
  type ReadinessReport,
} from './ReadinessPanel'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup. That covers the ordering rule and the accessible structure —
 * the parts most likely to rot in a refactor. The confirm-then-apply click
 * path is state, and is exercised through the main-process fix tests instead.
 */

function check(partial: Partial<ReadinessCheck> & { id: string }): ReadinessCheck {
  return {
    title: partial.id,
    status: 'pass',
    weight: 10,
    detail: 'detail',
    fix: null,
    gate: false,
    opens: null,
    ...partial,
  }
}

const DESTRUCTIVE_FIX: ReadinessFix = {
  id: 'untrack-secrets',
  label: 'Untrack and ignore',
  description: 'Runs git rm --cached and does not rewrite history.',
  touches: ['.gitignore', 'git index'],
  destructive: true,
}

describe('sortChecks', () => {
  it('puts failures first, then warnings, then passes, then skips', () => {
    const order = sortChecks([
      check({ id: 'skipped', status: 'skip' }),
      check({ id: 'passing', status: 'pass' }),
      check({ id: 'warning', status: 'warn' }),
      check({ id: 'failing', status: 'fail' }),
    ]).map((entry) => entry.id)
    expect(order).toEqual(['failing', 'warning', 'passing', 'skipped'])
  })

  it('lifts an unclean gate above every other failure', () => {
    const order = sortChecks([
      check({ id: 'heavy-fail', status: 'fail', weight: 30 }),
      check({ id: 'secrets', status: 'warn', weight: 30, gate: true }),
    ]).map((entry) => entry.id)
    expect(order[0]).toBe('secrets')
  })

  it('leaves a passing gate in its ordinary place', () => {
    const order = sortChecks([
      check({ id: 'secrets', status: 'pass', gate: true, weight: 30 }),
      check({ id: 'claude-md', status: 'fail', weight: 18 }),
    ]).map((entry) => entry.id)
    expect(order).toEqual(['claude-md', 'secrets'])
  })

  it('breaks ties by weight, and does not mutate its input', () => {
    const input = [check({ id: 'light', status: 'fail', weight: 6 }), check({ id: 'heavy', status: 'fail', weight: 30 })]
    expect(sortChecks(input).map((entry) => entry.id)).toEqual(['heavy', 'light'])
    expect(input.map((entry) => entry.id)).toEqual(['light', 'heavy'])
  })
})

describe('ScoreRing', () => {
  it('names the score for assistive tech', () => {
    const html = renderToStaticMarkup(<ScoreRing score={39} band="at-risk" />)
    expect(html).toContain('aria-label="AI readiness score 39 out of 100 — At risk"')
    expect(html).toContain('data-band="at-risk"')
  })

  it('draws a full arc at 100 and an empty one at 0', () => {
    const full = /stroke-dashoffset="([\d.]+)"/.exec(renderToStaticMarkup(<ScoreRing score={100} band="strong" />))
    const empty = /stroke-dashoffset="([\d.]+)"/.exec(renderToStaticMarkup(<ScoreRing score={0} band="at-risk" />))
    expect(Number(full?.[1])).toBe(0)
    expect(Number(empty?.[1])).toBeGreaterThan(200)
  })

  it('clamps a score outside the range rather than drawing past the ring', () => {
    const over = /stroke-dashoffset="([\d.]+)"/.exec(renderToStaticMarkup(<ScoreRing score={140} band="strong" />))
    expect(Number(over?.[1])).toBe(0)
  })
})

/**
 * *"Every not-ready item needs an action button that actually does it, or a way
 * to dismiss it. They should not see something they cannot do something about
 * it."*
 *
 * The rule has three shapes on a row and all three are pinned below, because
 * the failure mode is invisible: a row that loses its button looks exactly like
 * a row that never had one.
 */
describe('nothing on this page is un-actionable', () => {
  const noFix = check({ id: 'git-clean', status: 'warn' })

  it('picks the fix when there is one, the file when there is not', () => {
    const withFix = check({ id: 'secrets', status: 'fail', fix: DESTRUCTIVE_FIX, opens: '.gitignore' })
    // Never both. The fix is what repairs the finding, and an Open beside it
    // invites somebody to do by hand what the button next to it does properly.
    expect(actionFor(withFix, true)).toBe('fix')
    expect(actionFor(check({ id: 'readme', status: 'warn', opens: 'README.md' }), true)).toBe('open')
    // A window that cannot hand a file to the machine draws no Open button,
    // rather than one that does nothing.
    expect(actionFor(check({ id: 'readme', status: 'warn', opens: 'README.md' }), false)).toBe('none')
    expect(actionFor(noFix, true)).toBe('none')
  })

  it('offers nothing at all on a passing row', () => {
    // There is nothing to do about good news, and a Dismiss on every green row
    // is five controls asking to be read on a page whose job is to be skimmed.
    expect(actionFor(check({ id: 'readme', status: 'pass', opens: 'README.md' }), true)).toBe('none')
    const html = renderToStaticMarkup(
      <CheckRow
        check={check({ id: 'readme', status: 'pass', opens: 'README.md' })}
        busy={false}
        result={null}
        onApply={() => {}}
        onOpen={() => {}}
        onDismiss={() => {}}
      />,
    )
    expect(html).not.toContain('<button')
  })

  it('gives a row with no possible fix a dismissal', () => {
    const html = renderToStaticMarkup(
      <CheckRow check={noFix} busy={false} result={null} onApply={() => {}} onDismiss={() => {}} />,
    )
    expect(html).toContain('Dismiss')
    // And it says what dismissing does not do, because a button that quietly
    // raised the score by looking away would be the fake control this whole
    // release exists to remove.
    expect(html).toContain('still counts towards the score')
  })

  it('gives a row that names a file somewhere to go', () => {
    const html = renderToStaticMarkup(
      <CheckRow
        check={check({ id: 'readme', status: 'warn', opens: 'README.md' })}
        busy={false}
        result={null}
        onApply={() => {}}
        onOpen={() => {}}
        onDismiss={() => {}}
      />,
    )
    expect(html).toContain('Open it')
    expect(html).toContain('Open README.md on this machine')
  })

  it('builds a file URL a system opener will accept', () => {
    expect(fileUrlFor('/Users/me/proj', 'README.md')).toBe('file:///Users/me/proj/README.md')
    expect(fileUrlFor('/Users/me/My Proj/', 'README.md')).toBe('file:///Users/me/My%20Proj/README.md')
    // Windows. Per-segment encoding turns the drive's colon into %3A, which no
    // file handler will open — hence `encodeURI` rather than a segment map.
    expect(fileUrlFor('C:\\Users\\me\\proj', '.gitignore')).toBe('file:///C:/Users/me/proj/.gitignore')
    // The two characters `encodeURI` deliberately leaves alone, both of which
    // are legal in a filename here.
    expect(fileUrlFor('/a', 'note#1?.md')).toBe('file:///a/note%231%3F.md')
  })
})

describe('CheckRow', () => {
  it('renders no button when there is nothing to fix and no way to dismiss', () => {
    const html = renderToStaticMarkup(
      <CheckRow check={check({ id: 'git-clean', status: 'warn' })} busy={false} result={null} onApply={() => {}} />,
    )
    expect(html).not.toContain('<button')
  })

  it('shows the fix label, and asks before running a destructive one', () => {
    const html = renderToStaticMarkup(
      <CheckRow
        check={check({ id: 'secrets', status: 'fail', gate: true, fix: DESTRUCTIVE_FIX })}
        busy={false}
        result={null}
        onApply={() => {}}
      />,
    )
    // The first press confirms; it must not read as the action itself.
    expect(html).toContain('Untrack and ignore')
    expect(html).not.toContain('Yes, apply it')
    expect(html).toContain('data-destructive="true"')
    expect(html).toContain('caps the score')
  })

  it('disables the button while its fix is running', () => {
    const html = renderToStaticMarkup(
      <CheckRow
        check={check({ id: 'secrets', status: 'fail', fix: DESTRUCTIVE_FIX })}
        busy
        result={null}
        onApply={() => {}}
      />,
    )
    expect(html).toContain('disabled=""')
    expect(html).toContain('Working…')
  })

  it('reports the outcome of a fix that refused', () => {
    const html = renderToStaticMarkup(
      <CheckRow
        check={check({ id: 'readme', status: 'fail' })}
        busy={false}
        result={{ ok: false, message: 'README.md already exists — nothing was changed.', changed: [] }}
        onApply={() => {}}
      />,
    )
    expect(html).toContain('data-ok="false"')
    expect(html).toContain('nothing was changed')
  })
})

/* --------------------------------------------------------------- headline -- */

/**
 * The arithmetic he could not do.
 *
 *   > *"Maybe you know the reason why it is at risk, AI readiness."*
 *
 * *"1 of 5 checks passing"* stood over ten rows, five of which the scan had
 * skipped and left out of the denominator. Both numbers were right and the pair
 * was unreadable.
 */
describe('headlineFor', () => {
  it('says which rows the count is about, and how many it is not counting', () => {
    expect(headlineFor(38, 1, 5, 5)).toBe(
      '38 out of 100 — 1 of 5 applicable checks passing, weighted · 5 not applicable here.',
    )
  })

  it('adds up to the rows on screen', () => {
    // The property that was missing, stated as one: applicable + skipped is
    // what a reader counts down the page.
    const line = headlineFor(70, 4, 7, 3)
    expect(line).toContain('4 of 7')
    expect(line).toContain('3 not applicable')
  })

  it('says nothing about skipped checks when none were skipped', () => {
    expect(headlineFor(100, 10, 10, 0)).toBe(
      '100 out of 100 — 10 of 10 applicable checks passing, weighted.',
    )
  })

  it('keeps the grammar of a single applicable check', () => {
    expect(headlineFor(0, 0, 1, 9)).toContain('0 of 1 applicable check passing')
  })
})

/* ------------------------------------------------------------- per agent -- */

function forAgent(over: Partial<ReadinessForAgent> & { agent: string }): ReadinessForAgent {
  return {
    label: over.agent,
    file: 'INSTRUCTIONS.md',
    check: check({ id: 'claude-md', status: 'pass', detail: 'found it' }),
    score: 90,
    band: 'strong',
    cappedBy: null,
    ...over,
  }
}

function report(over: Partial<ReadinessReport> = {}): ReadinessReport {
  return {
    projectPath: '/p',
    score: 38,
    band: 'at-risk',
    checks: [check({ id: 'claude-md', status: 'fail', detail: 'nothing here' }), check({ id: 'readme' })],
    cappedBy: null,
    scannedAt: '2026-08-21T00:00:00.000Z',
    ...over,
  }
}

/**
 * Switching the pill has to move the row *and* the ring, or the page is back to
 * a headline that does not follow from what is under it.
 */
describe('reportFor', () => {
  it('gives the project’s own answer when no agent is picked', () => {
    const view = reportFor(report({ agents: [forAgent({ agent: 'codex' })] }), null)
    expect(view.agent).toBeNull()
    expect(view.score).toBe(38)
    expect(view.checks[0]?.detail).toBe('nothing here')
  })

  it('swaps the instructions row and the score together', () => {
    const scanned = report({ agents: [forAgent({ agent: 'codex', label: 'Codex CLI', file: 'AGENTS.md' })] })
    const view = reportFor(scanned, 'codex')
    expect(view.agent?.label).toBe('Codex CLI')
    expect(view.checks[0]?.detail).toBe('found it')
    expect(view.score).toBe(90)
    expect(view.band).toBe('strong')
    // Every other row is the same object — one scan, one list, one swap.
    expect(view.checks[1]).toBe(scanned.checks[1])
  })

  it('falls back to the neutral view for an agent the scan did not answer for', () => {
    const view = reportFor(report({ agents: [] }), 'gemini')
    expect(view.agent).toBeNull()
    expect(view.score).toBe(38)
  })

  it('survives a report from a build that answered for no agents at all', () => {
    const view = reportFor(report(), 'claude')
    expect(view.checks).toHaveLength(2)
  })
})

/**
 * The rule this screen has to keep, pinned where it can be:
 *
 *   > *"where we can have an option between Claude, Codex, Gemini, in those
 *   > places don't name only Claude. Give all the options."*
 */
describe('AgentPills', () => {
  const three = [
    forAgent({ agent: 'claude', label: 'Claude Code', file: 'CLAUDE.md' }),
    forAgent({ agent: 'codex', label: 'Codex CLI', file: 'AGENTS.md' }),
    forAgent({ agent: 'gemini', label: 'Gemini CLI', file: 'GEMINI.md' }),
  ]

  it('offers every agent the scan answered for, and the project’s own answer', () => {
    const html = renderToStaticMarkup(<AgentPills agents={three} pick={null} onPick={() => {}} />)
    for (const label of ['Any agent', 'Claude Code', 'Codex CLI', 'Gemini CLI']) {
      expect(html, label).toContain(label)
    }
  })

  it('says which file each agent reads before it is pressed', () => {
    const html = renderToStaticMarkup(<AgentPills agents={three} pick={null} onPick={() => {}} />)
    for (const file of ['CLAUDE.md', 'AGENTS.md', 'GEMINI.md']) {
      expect(html, file).toContain(file)
    }
  })

  it('marks the pressed one for a reader who cannot see the fill', () => {
    const html = renderToStaticMarkup(<AgentPills agents={three} pick={'codex'} onPick={() => {}} />)
    expect(html).toContain('data-on="true"')
    // One pressed, and it is not the first — the default must not be sticky.
    expect(html.match(/data-on="true"/g)).toHaveLength(1)
  })

  it('draws nothing when there is nothing to switch between', () => {
    expect(renderToStaticMarkup(<AgentPills agents={[]} pick={null} onPick={() => {}} />)).toBe('')
  })
})

describe('ReadinessPanel', () => {
  it('says so rather than crashing when the bridge is missing', () => {
    const html = renderToStaticMarkup(<ReadinessPanel projectPath="/tmp/x" />)
    expect(html).toContain('not available here')
    // The shared blank, not a bare sentence of its own — see `PageEmpty`.
    expect(html).toContain('page-blank-title')
  })

  it('renders a scanning state before the first report arrives', () => {
    const bridge = {
      scanReadiness: () => new Promise<never>(() => {}),
      applyReadinessFix: () => Promise.resolve({ ok: true, message: '', changed: [] }),
    }
    const html = renderToStaticMarkup(<ReadinessPanel projectPath="/tmp/x" bridge={bridge} />)
    expect(html).toContain('AI readiness')
    expect(html).toContain('Scanning…')
  })
})
