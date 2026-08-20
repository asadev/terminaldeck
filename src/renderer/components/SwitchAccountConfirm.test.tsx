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
    /*
     * "Run this session as X?" was the title, and *"run them as is not the best
     * way"* was about that phrasing rather than about the one settings row he
     * happened to be looking at when he said it. The act is a switch.
     */
    expect(html).toContain(`Switch to ${names.to}?`)
    expect(html).not.toContain('Run this session as')
    expect(html).toContain(`${names.from} → ${names.to}`)
  })

  /*
   * The sheet used to open with two paragraphs: what a switch keeps, then what
   * becomes of the conversation. He read them in the recording and asked for
   * the first to go, and for the rule to be general:
   *
   *   > *"here you have a very long description… Remove this full shit. I don't
   *   > want any kind of long descriptions anywhere. Just if somewhere it's
   *   > very required, give the i icon like other ones, information icon in the
   *   > settings, same way."*
   *
   * So it is behind the dot, which is the affordance he named — `HoverNote`,
   * the same component the Settings rows use. Asserted as "not in the body
   * text" rather than "absent", because deleting the fact outright would leave
   * a control that stops a running agent with nothing anywhere saying so.
   */
  it('keeps the description behind the information dot rather than on the sheet', () => {
    const html = sheet()
    expect(html).toContain('hovernote-dot')
    const body = html.slice(html.indexOf('switch-confirm'), html.indexOf('modal-footer'))
    const shown = body.replace(/<span id="[^"]*" class="hovernote-text">[\s\S]*?<\/span>/g, '')
    expect(shown, 'the long description is back on the sheet').not.toContain('Same tab, same folder')
    expect(shown).not.toContain('has not written to disk')
  })

  /*
   * The half that is not a description. A conversation that is *not* coming
   * with him is a loss, and a loss nobody was warned about is the fault this
   * sheet exists for — so it stays, and it stays only in that case. Both halves
   * are asserted together, because the way this rots is one of them being
   * relaxed on its own: silence about a loss, or a reassurance nobody needs.
   */
  it('warns only when the conversation is not coming with him', () => {
    expect(sheet({ plan: plan({ conversation: 'theirs' }) })).toContain(
      'not the one on screen now',
    )
    expect(sheet({ plan: plan({ conversation: 'taken' }) })).toContain('another tab is already')

    const follows = sheet({ plan: plan({ conversation: 'follows' }) })
    expect(follows, 'a reassurance he did not ask for').not.toContain('This conversation')
    expect(follows).not.toContain('stays with')
  })
})

describe('the button that does it', () => {
  it('is offered once there is a plan and nothing objects', () => {
    expect(sheet()).toContain('Switch now')
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
    expect(html).not.toContain('Switch now')
    expect(html).toContain('Working out what this would do')
  })

  it('is withheld when the main process refused, and prints the refusal', () => {
    const html = sheet({
      plan: plan({ refusal: 'A plain shell has no account to sign in to.' }),
    })
    expect(html).not.toContain('Switch now')
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
    expect(sheet({ problem: 'no' })).not.toContain('Switch now')
  })
})
