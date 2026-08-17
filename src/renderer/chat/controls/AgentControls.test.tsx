import { readFileSync } from 'node:fs'
import { join } from 'node:path'
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

  it('does not advertise a control that is already a chip on the row', () => {
    /*
     * The duplication complaint, asserted from the one place it is visible in a
     * static render: "options is having all of the things that we already have
     * here and there."
     *
     * The label is built from the panel's own contents, so a control that
     * reappeared in `MENU_CONTROLS` would be named here — which makes this the
     * cheapest available proof that the panel is not repeating the row. The
     * panel's markup itself cannot be read: it is shut in a static render, and
     * this project has no DOM in its test setup to open it with.
     */
    withBridge()
    const html = render({ sessionId: 's1', cwd: '/tmp/p', provider: 'claude' })
    const tag = (html.match(/<button[^>]*>/g) ?? []).find((one) =>
      one.includes('aria-haspopup="dialog"'),
    )
    const label = /title="([^"]*)"/.exec(tag ?? '')?.[1] ?? ''
    expect(label).not.toBe('')
    for (const control of PRIMARY_CONTROLS) {
      expect(label.toLowerCase(), control).not.toContain(controlName(control).toLowerCase())
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
    // "used", not "cost": this app prints no money anywhere. See the bottom of
    // `src/main/cost.ts`.
    expect(names(html).some((name) => /used/i.test(name))).toBe(true)
    expect(names(html).some((name) => /cost/i.test(name))).toBe(false)
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

  it('withdraws every picker from an agent CLI this build cannot drive', () => {
    /*
     * Codex and Gemini get the same treatment as a shell and for a related
     * reason: every option in `catalog.ts` is a Claude Code command, and every
     * value the pickers show is read out of Claude Code's own screen or its
     * settings file. A Codex session wearing this row would offer five model
     * aliases that mean nothing there and print an effort level out of a file
     * it never wrote.
     *
     * The panel's sentence explaining it cannot be asserted here — the panel is
     * shut in a static render — so it lives in `catalog.ts` and is pinned in
     * `catalog.test.ts` instead.
     */
    withBridge()
    for (const provider of ['codex', 'gemini'] as const) {
      const html = render({ sessionId: 's1', cwd: '/tmp/p', provider })
      for (const control of PRIMARY_CONTROLS) {
        expect(html, `${provider} still shows the ${control} picker`).not.toContain(controlName(control))
      }
    }
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

/**
 * Two facts about this component that a rendered string cannot carry.
 *
 * Both calls into the bridge happen in places a static render never reaches —
 * one in an effect, one in a click handler — and this project has no DOM in its
 * test setup to run either. So they are asserted against the source, the way
 * `wiring.test.ts` and `finish.test.ts` already assert the things that are only
 * visible there. The alternative was to leave the most important line in the
 * file untested because it is awkward to reach.
 */
describe('what the controls tell the main process', () => {
  const source = readFileSync(join(__dirname, 'AgentControls.tsx'), 'utf8')

  it('names the provider on every call, because the main process refuses on it', () => {
    // Without this the main process sees `provider: undefined` for a Codex
    // session and falls back to asking the screen — which, finding none of
    // Claude Code's markers, refuses. Correct by luck rather than by design,
    // and wrong the moment another CLI draws something that looks similar.
    expect(source).toMatch(/readAgentControls\(\{[^}]*provider[^}]*\}\)/)
    expect(source).toMatch(/applyAgentControl\(\{[^}]*provider[^}]*\}\)/)
  })

  it('shows the value the session reported, not the one that was clicked', () => {
    /*
     * `answer.reading` is what the main process re-read off the session after
     * the change settled. Writing `{ ...was, [control]: { value, label: value } }`
     * here instead would tick the row that was pressed whether or not anything
     * happened — a picker showing an intention rather than a state, which is a
     * bug class this app has already shipped once.
     */
    expect(source).toContain('setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))')
    expect(source).not.toMatch(/\[control\]:\s*\{\s*value\b/)
  })
})
