import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { AgentControls } from './AgentControls'
import { controlName, MENU_CONTROLS, PRIMARY_CONTROLS } from './catalog'

/**
 * What the controls put on screen, asserted on their markup.
 *
 * Rendered to a string because this project has no DOM in its test setup — the
 * arrangement `ChatComposer.test.tsx` and `ChatView.test.tsx` already use. That
 * limits these to the closed state, which is the state that matters here: the
 * failure being pinned is a control that cannot be *found*, and everything a
 * person has to look at before they find one is in this markup.
 *
 * The panel's own contents are checked two other ways: `ControlSection.test.tsx`
 * renders a section, and `wiring.test.ts` pins that the panel is built from
 * `MENU_CONTROLS` rather than from a subset of it.
 */

/** The bridge is read off `globalThis` during render, so it has to exist first. */
function withBridge(): void {
  ;(globalThis as { deck?: unknown }).deck = {
    readAgentControls: async () => ({}),
    applyAgentControl: async () => ({}),
  }
}

afterEach(() => {
  delete (globalThis as { deck?: unknown }).deck
})

function render(props: Parameters<typeof AgentControls>[0]): string {
  return renderToStaticMarkup(<AgentControls {...props} />)
}

/** Every button's accessible name — its aria-label, or its tooltip. */
function names(html: string): string[] {
  return (html.match(/<button[^>]*>/g) ?? []).map((tag) => {
    return /aria-label="([^"]*)"/.exec(tag)?.[1] ?? /title="([^"]*)"/.exec(tag)?.[1] ?? ''
  })
}

describe('a live agent session', () => {
  it('puts the controls a session reaches for on the row itself', () => {
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'claude' })
    for (const control of PRIMARY_CONTROLS) expect(html).toContain(controlName(control))
  })

  it('offers the rest behind one button that says Options, not "More"', () => {
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'claude' })
    expect(html).toContain('Options')
    // "More" names nothing, which is why the controls behind it were reported
    // as removed rather than as folded away.
    expect(html).not.toMatch(/>\s*More\s*</)
  })

  it('names every control in the panel on the button that opens it', () => {
    // The button is the only thing on screen while the panel is shut, so it is
    // the only place the contents can be advertised. Built from the control
    // names, so it cannot go on naming one that has been deleted.
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'claude' })
    // The panel's own button, not a picker's: it is the one that opens a dialog.
    const tag = (html.match(/<button[^>]*>/g) ?? []).find((one) =>
      one.includes('aria-haspopup="dialog"'),
    )
    const label = /title="([^"]*)"/.exec(tag ?? '')?.[1]
    expect(label, 'the Options button has no name listing what it holds').toBeTruthy()
    for (const control of MENU_CONTROLS) {
      expect(label?.toLowerCase(), control).toContain(controlName(control).toLowerCase())
    }
  })

  it('mentions the usage readout too when there is one to show', () => {
    withBridge()
    const html = render({
      sessionId: 's1',
      cwd: '/tmp/p',
      provider: 'claude',
      extra: <span data-usage="here" />,
    })
    expect(names(html).some((name) => /cost/i.test(name))).toBe(true)
  })

  it('gives every button a name a person can read or hear', () => {
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'claude' })
    expect(names(html).length).toBeGreaterThan(0)
    for (const name of names(html)) expect(name).not.toBe('')
  })
})

describe('when nothing here can be changed', () => {
  it('still offers the panel, so the reason is reachable rather than absent', () => {
    // No bridge: the pickers cannot be drawn. The button is what keeps the
    // explanation — and the usage readout — from vanishing with them.
    const html = render({ sessionId: 's1', cwd: '/tmp/p', extra: <span data-usage="here" /> })
    expect(html).toContain('Options')
  })

  it('draws no button at all on a shell, because nothing is behind it', () => {
    // A shell has no model, no effort, no fast mode and no permission mode, and
    // its usage readout is withheld — so the panel could only open onto a
    // paragraph about its own emptiness. That is the dead control the brief
    // forbids, and the pane already says the session is a shell.
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'shell' })
    expect(html).not.toContain('<button')
  })
})
