import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  CheckRow,
  ReadinessPanel,
  ScoreRing,
  sortChecks,
  type ReadinessCheck,
  type ReadinessFix,
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

describe('CheckRow', () => {
  it('renders no button when there is nothing to fix', () => {
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
