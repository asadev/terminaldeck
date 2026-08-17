import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar } from './Sidebar'
import { StoreProvider } from '../state/store'
import type { WorkspaceTab } from './workspace-tabs'

/**
 * The rename, as far as a static render can see it.
 *
 * Reported walking the app: **"a session's name cannot be edited."** The rule
 * behind the fix — that a name somebody typed is never overwritten by one the
 * app derived — is pinned in `state/store.test.ts`, where it can be driven
 * directly. What is left for here is the half that lives in markup and in the
 * source: that the way in exists, that it is on the right rows, and that it can
 * be reached without a mouse.
 *
 * ## Why the button went, and what replaced it
 *
 * Asad, walking the app on 2026-08-16: *"I don't want this edit button here.
 * Just double click should make it editable. That's it. Over the text, when I
 * double click, it should become like editable and I can change the text."*
 *
 * So the pencil is gone and the row itself opens the field. That is the right
 * gesture — it is what Finder, VS Code's explorer and every project rail does —
 * but it costs two things a button gave for free, and both are pinned below: a
 * gesture leaves nothing on screen to say it exists, and a double-click cannot
 * be performed from a keyboard. The row's tooltip answers the first; F2 answers
 * the second.
 *
 * `react-dom/server`, like the rest of this window's tests — this project has
 * no DOM in its test setup. So the *field* cannot be opened here: it appears on
 * a gesture, and there is nothing to gesture at. Handlers are invisible to a
 * static render too, so the two that matter are read out of the source, the way
 * `wiring.test.ts` and `finish.test.ts` already read files for the things a
 * rendered string cannot show.
 */

const noop = (): void => {}

const SOURCE = readFileSync(join(__dirname, 'Sidebar.tsx'), 'utf8')

const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]

const tabs: WorkspaceTab[] = [
  {
    id: 's1',
    kind: 'session',
    label: 'Fix the parser',
    projectPath: projects[0].path,
    closable: true,
  },
  { id: 'b1', kind: 'browser', label: 'localhost:3000', closable: true },
]

function render(inStore: boolean): string {
  const rail = (
    <Sidebar
      width={264}
      projects={projects}
      tabs={tabs}
      activeTabId={null}
      activePanel={null}
      onSelectTab={noop}
      onCloseTab={noop}
      onSelectPanel={noop}
      onNewSession={noop}
      onNewBrowserTab={noop}
      onOpenProject={noop}
      onCloseProject={noop}
      onOpenSettings={noop}
      onOpenAlerts={noop}
      onToggleCollapsed={noop}
      onPeekStart={noop}
      onPeekEnd={noop}
      onStartResize={noop}
    />
  )
  return renderToStaticMarkup(inStore ? <StoreProvider>{rail}</StoreProvider> : rail)
}

describe('renaming a session from the rail', () => {
  const html = render(true)

  it('has no edit button on the row any more', () => {
    // The whole of what he asked for. A pencil beside a name is a control
    // standing in for a gesture people already know.
    expect(html).not.toContain('sb-rename')
    expect(html).not.toContain('aria-label="Rename Fix the parser"')
  })

  it('opens the field on a double-click of the row itself', () => {
    /*
     * Invisible to a rendered string, so read from the source. What has to stay
     * true is that the gesture lands on the row's own button — the thing the
     * name is printed on — rather than on some new target invented beside it.
     */
    const at = SOURCE.indexOf('className="sb-row-main"')
    expect(at, 'the session row has changed shape — this test can no longer see it').toBeGreaterThan(0)
    // The attribute list of that one button: from its className to its first
    // child. Sliced rather than matched with a pattern, because JSX attribute
    // values contain braces and arrows and a regex over them finds whatever it
    // likes — which is how a test starts passing by looking at the wrong file.
    const attributes = SOURCE.slice(at, SOURCE.indexOf('<StatusDot', at))
    expect(attributes).toContain('onDoubleClick=')
    expect(attributes).toContain('beginRename(tab.id, label)')
  })

  it('can still be reached without a mouse', () => {
    /*
     * The half a gesture loses. F2 rather than Return, because Return on a
     * focused button is "press it" — stealing that would make the row
     * unopenable from a keyboard, which is a worse bug than the one being
     * fixed.
     */
    expect(SOURCE).toContain("event.key !== 'F2'")
    expect(SOURCE).not.toContain("event.key === 'Enter'")
  })

  it('is not closed again by the terminal that just took focus', () => {
    /*
     * The half of the gesture that was broken and looked like nothing.
     *
     * Double-clicking a row that is *not* the open session does two things: the
     * first click switches to it, and the second opens the field. The terminal
     * for the session you just switched to then focuses its own textarea —
     * timed in the running app: field at t+73ms, `xterm-helper-textarea` takes
     * focus at t+75ms, field gone at t+76ms, because a blur means "save and
     * close". So renaming worked on the row you were already in and silently did
     * nothing on every other row, which is the worst shape a bug can have.
     *
     * `relatedTarget` cannot separate the two cases — a real click into the
     * terminal names the same element. What can is that a click or a keypress is
     * something the *user* did and arrives before the focus moves, so a blur
     * with no user action behind it is a steal rather than a dismissal.
     */
    expect(SOURCE).toContain('userActed')
    expect(SOURCE).toMatch(/if \(!userActed\.current\)[\s\S]{0,200}requestAnimationFrame/)
    // Both of the things a person can do to leave a field, watched wherever
    // they land — the capture phase, because the dismissing click by definition
    // happens somewhere other than the field.
    expect(SOURCE).toContain("document.addEventListener('pointerdown', mark, true)")
    expect(SOURCE).toContain("document.addEventListener('keydown', mark, true)")
    // And a blur that the user did cause still saves, which is the behaviour
    // this must not have traded away.
    expect(SOURCE).toMatch(/endRename\(true\)\s*\n\s*\}\}/)
  })

  it('says the gesture exists, because a gesture leaves nothing on screen', () => {
    // The tooltip is the only advertisement a hidden gesture gets, and it names
    // both ways in.
    expect(html).toContain('double-click or F2 to rename')
  })

  it('does not offer one on a browser tab', () => {
    /*
     * A browser tab is named by the page it is showing, and the next navigation
     * would overwrite anything typed here. Offering a rename that the app
     * intends to undo is worse than not offering one — it is the same failure
     * as the auto-titler eating a session's name, just with the app's own
     * behaviour as the culprit rather than a missing flag.
     */
    expect(html).toContain('aria-label="Close localhost:3000"')
    const browserRow = /title="localhost:3000[^"]*"/.exec(html)?.[0] ?? ''
    expect(browserRow).not.toContain('rename')
  })
})

describe('what took the pencil’s place', () => {
  const html = render(true)

  it('moves the keep-at-the-top control into the slot the pencil was in', () => {
    /*
     * *"This button should come maybe here where the edit button is."* It does,
     * and it does so by subtraction rather than by a rule: the row's trailing
     * controls are laid out in order, so removing the middle one slides the
     * first into its place. What this pins is the resulting order — the
     * promote control, then the close, with nothing between them.
     */
    expect(html.indexOf('sb-promote')).toBeGreaterThan(0)
    expect(html.indexOf('sb-promote')).toBeLessThan(html.indexOf('sb-close'))
    const between = html.slice(html.indexOf('sb-promote'), html.indexOf('sb-close'))
    expect(between).not.toContain('sb-row-action sb-')
  })

  it('draws the arrow he asked for and not the one he objected to', () => {
    /*
     * *"It should be some arrow like to the corner to maybe right top corner,
     * not straight to up and without this line above there."* The old glyph was
     * `M5 4.5h14M12 20V9M8 13l4-4 4 4` — a horizontal bar across the top and a
     * shaft rising straight into it, which is both of the things he named. The
     * new one is a diagonal with a corner bracket at its head and no bar at all.
     */
    expect(SOURCE).not.toContain('M5 4.5h14')
    expect(SOURCE).toContain("const TO_STRIP = 'M7.5 16.5 16.5 7.5M10.5 7.5H16.5V13.5'")
  })
})

describe('outside a session list', () => {
  it('offers no rename at all rather than a dead one', () => {
    /*
     * The rail renders on its own in `.harness/` and in the tests next door,
     * where there is no store to write a name into. A gesture that opens a field
     * whose value goes nowhere is the same fault as a button that highlights and
     * does nothing, so the affordance is absent instead — see `useSessionRename`.
     */
    const alone = render(false)
    expect(alone).toContain('aria-label="Close Fix the parser"')
    expect(alone).not.toContain('double-click or F2 to rename')
  })
})
