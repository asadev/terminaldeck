import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SwitchPlanView } from '../session-switch'

/**
 * The sheet that describes a switch before it happens.
 *
 * Rendered rather than reasoned about, because every claim worth pinning here is
 * a claim about what is *on screen*: which sentences appear, and — the load
 * bearing one — whether the button that stops a running agent is offered at all.
 *
 * The harness is `dialog-render.test.tsx`'s, for the reasons stated there: this
 * project has no DOM in its test setup, `Modal` portals into `document.body`,
 * and effects do not run under SSR, so what is measured is the first paint.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})

;(globalThis as { document?: unknown }).document = { body: {} }

const { SwitchAccountConfirm } = await import('./SwitchAccountConfirm')

const names = { from: 'work@example.com', to: 'home@example.com' }
const noop = (): void => {}

const plan = (over: Partial<SwitchPlanView> = {}): SwitchPlanView => ({
  sessionId: 's1',
  refusal: null,
  from: { id: 'work', name: 'Work', provider: 'claude' },
  to: { id: 'home', name: 'Home', provider: 'claude' },
  conversation: 'stays',
  resume: false,
  ...over,
})

const sheet = (
  over: {
    plan?: SwitchPlanView | null
    busy?: boolean
    problem?: string | null
  } = {},
): string =>
  renderToStaticMarkup(
    <SwitchAccountConfirm
      open
      title="app"
      names={names}
      plan={over.plan === undefined ? plan() : over.plan}
      busy={over.busy ?? false}
      problem={over.problem ?? null}
      onCancel={noop}
      onConfirm={noop}
    />,
  )

describe('what the sheet says before anything is stopped', () => {
  it('names both accounts — the one it is on and the one it would move to', () => {
    const html = sheet()
    expect(html).toContain(`Run this session as ${names.to}?`)
    expect(html).toContain(`This session is running as ${names.from}.`)
  })

  it('says what survives and what does not, in that order', () => {
    const html = sheet()
    const keeps = html.indexOf('Same tab, same folder')
    const conversation = html.indexOf('This conversation stays with')
    expect(keeps).toBeGreaterThan(-1)
    expect(conversation).toBeGreaterThan(keeps)
  })

  it('warns that the agent is stopped part-way through', () => {
    // The one irreversible thing about a switch, and the one a person picking an
    // account from a menu has no way to guess.
    expect(sheet()).toContain('has not written to disk')
  })
})

describe('the button that does it', () => {
  it('is offered once there is a plan and nothing objects', () => {
    expect(sheet()).toContain('Switch account')
  })

  /**
   * The rule the whole sheet exists for.
   *
   * A description that has not arrived yet describes nothing, so a button beside
   * it would stop a running agent on the strength of an empty paragraph — which
   * is the restart nobody expected, wearing a dialog.
   */
  it('is withheld while the plan is still being worked out', () => {
    const html = sheet({ plan: null, busy: true })
    expect(html).not.toContain('Switch account')
    expect(html).toContain('Working out what this would do')
  })

  it('is withheld when the main process refused, and prints the refusal', () => {
    const html = sheet({
      plan: plan({ refusal: 'A plain shell has no account to sign in to.' }),
    })
    expect(html).not.toContain('Switch account')
    expect(html).toContain('A plain shell has no account to sign in to.')
  })

  it('says Close rather than Cancel when there is nothing left to cancel', () => {
    // "Cancel" beside a refusal implies the switch is pending and could be
    // stopped. Nothing is pending; there is only something to read.
    expect(sheet({ plan: plan({ refusal: 'no' }) })).toContain('Close')
    expect(sheet()).toContain('Cancel')
  })
})

describe('a switch that could not start', () => {
  /**
   * The main process starts the replacement *before* it stops anything, exactly
   * so that a failure costs nothing. That is only useful if the person is told —
   * somebody who has just read "could not" will otherwise go looking for what
   * they lost.
   */
  it('says the session is still running as it was', () => {
    const html = sheet({ problem: 'Claude Code could not be found on this machine.' })
    expect(html).toContain('Claude Code could not be found on this machine.')
    expect(html).toContain('This session is still running as it was.')
  })

  it('stops offering to try, so the sheet is a report rather than a retry', () => {
    expect(sheet({ problem: 'no' })).not.toContain('Switch account')
  })
})
