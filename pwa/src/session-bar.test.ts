/**
 * The rules the phone's session bar reads a far machine's records with.
 *
 * Only the pure half is exercised here, and that is why the pure half exists as
 * exported functions rather than as expressions inside a DOM builder: vitest
 * runs in this repo with no DOM at all — `pwa/tests/layout.test.ts` reads the
 * stylesheet as *text* for the same reason — so a rule that lives inside
 * `render()` is a rule nothing can ask a question of. The drawing is checked by
 * rendering it, in a browser, against a real host.
 *
 * The fixtures are the far machine's own shapes: `UsageReport` as
 * `usage-window.ts` assembles it, and the context reading as
 * `emptyUsageReading` and `readContextWindow` write it.
 */

import { describe, expect, it } from 'vitest'
import { accountDotColor, contextFraction, foreignAccount, percentText, planFraction } from './session-bar'

function window(id: string, used: number | null): Record<string, unknown> {
  return {
    id,
    account: { provider: 'claude', id: 'a', name: 'A', configDir: null },
    window: id,
    windowMinutes: null,
    label: id,
    used: used === null ? { state: 'not-reported' } : { state: 'reported', fraction: used },
    resets: { state: 'not-reported' },
    observedAt: 0,
    reportedAt: 0,
    source: 'claude-usage-panel',
  }
}

describe('reading a plan report onto a ring', () => {
  it('takes the window nearest its end, not the first one', () => {
    /*
     * A person is limited by whichever window they are closest to the end of.
     * Picking "the five-hour one" would draw a calm ring while the weekly window
     * is the one that actually stops them working.
     */
    const report = { readings: [window('five-hour', 0.42), window('weekly', 0.67)] }
    expect(planFraction(report)).toBe(0.67)
  })

  it('answers null when nothing reported a figure, rather than zero', () => {
    /*
     * `used` is a union precisely so that nothing can `?? 0` past the
     * difference. A ring drawn at 0% says *you have used nothing*, which is a
     * claim; an absent ring says nothing, which is the truth.
     */
    expect(planFraction({ readings: [window('weekly', null)] })).toBeNull()
    expect(planFraction({ readings: [], reason: 'Nothing to report.' })).toBeNull()
    // The empty report `emptyUsageReading('plan', …)` composes, verbatim.
    expect(planFraction({ sessionId: null, readings: [], reason: 'no', account: null, assembledAt: 0 })).toBeNull()
  })

  it('answers null for anything it cannot read, and never throws on it', () => {
    // The far machine's record is `Record<string, unknown>` on this wire and
    // this client is not another copy of the app. A shape this build does not
    // understand is a chip that is not drawn, never one drawn from a guess.
    for (const value of [null, undefined, 7, 'plan', [], {}, { readings: 'no' }, { readings: [1, null] }]) {
      expect(planFraction(value), JSON.stringify(value ?? null)).toBeNull()
    }
  })

  it('clamps a fraction to the bar it has to fit in', () => {
    // A figure of 3.4 is a ring that leaves its own frame — the defect he filmed
    // on the desktop, one element down.
    expect(planFraction({ readings: [window('weekly', 3.4)] })).toBe(1)
    expect(planFraction({ readings: [window('weekly', -1)] })).toBe(0)
    expect(planFraction({ readings: [window('weekly', Number.NaN)] })).toBeNull()
  })
})

describe('reading a context window onto a bar', () => {
  it('divides the percent the far machine reports', () => {
    // `percent` over there is 0..100, and it is divided here and nowhere else.
    expect(contextFraction({ state: 'reported', percent: 17 })).toBeCloseTo(0.17)
    expect(percentText(0.17)).toBe('17%')
  })

  it('draws nothing for a reading that says there is no figure', () => {
    /*
     * `not-reported` is the state `emptyUsageReading('context', …)` composes for
     * a session the far end will not discuss, and it carries a `detail` sentence
     * that this client deliberately never renders — the bar is simply absent.
     */
    expect(contextFraction({ state: 'not-reported', percent: null, detail: 'No session is running.' })).toBeNull()
    expect(contextFraction({ state: 'reported', percent: null })).toBeNull()
    for (const value of [null, undefined, 7, 'ctx', []]) expect(contextFraction(value)).toBeNull()
  })

  it('rounds to a whole percent, because a phone chip is not a report', () => {
    expect(percentText(0.174)).toBe('17%')
    expect(percentText(0)).toBe('0%')
    expect(percentText(1)).toBe('100%')
  })
})

describe('the account dot', () => {
  it('uses the property name the wire carries, dashes and all', () => {
    /*
     * `AccountWire.color` is a custom property *name*, never a colour value, so
     * the palette stays in one stylesheet. The desktop's own chip writes
     * `var(${account.color})`; `var(--${color})` produces `var(----accent)` and
     * paints nothing, which is how the dot came out blank the first time this
     * was rendered.
     */
    expect(accountDotColor('--accent')).toBe('var(--accent)')
    expect(accountDotColor('--status-completed')).toBe('var(--status-completed)')
  })

  it('refuses anything that is not a plain property name', () => {
    // This string arrives from another machine and lands inside a style
    // attribute. A machine that sent a value, or a closing paren, gets the
    // neutral fill the class already gives the dot.
    for (const value of [null, '', 'accent', '#c96', '--a) ; background: url(x', '--' + 'x'.repeat(60)]) {
      expect(accountDotColor(value), String(value)).toBeNull()
    }
  })
})

describe('which logins the sheet lets you press', () => {
  const wire = (id: string, provider: string | null) => ({ id, name: id, provider, color: null, system: false })

  it('refuses a login of a different agent than the session runs', () => {
    /*
     * Measured on 2026-08-20 from a phone against a real Claude session on this
     * Mac: the sheet listed *Default (Codex CLI)* as a pressable row, the press
     * spun the chip, and nothing happened — `session-switch.ts` refuses the
     * switch with a sentence this bar deliberately does not draw. Inert here is
     * what the desktop's own remote chip already does with the same two fields.
     */
    expect(foreignAccount(wire('system', 'claude'), wire('system:codex', 'codex'))).toBe(true)
    expect(foreignAccount(wire('system', 'claude'), wire('work', 'claude'))).toBe(false)
  })

  it('stays pressable when either provider is unknown', () => {
    // Two of them cannot be said to differ until both are known. An older
    // machine that does not name the agent must not grey out every login.
    expect(foreignAccount(wire('system', null), wire('system:codex', 'codex'))).toBe(false)
    expect(foreignAccount(wire('system', 'claude'), wire('other', null))).toBe(false)
    expect(foreignAccount(null, wire('system:codex', 'codex'))).toBe(false)
  })
})
