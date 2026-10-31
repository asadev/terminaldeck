import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SessionTitle } from './SessionTitle'
import { StoreProvider } from '../state/store'

/**
 * Renaming a session from inside the terminal, as far as a static render sees it.
 *
 * Asad, walking the app: *"And session name also inside the terminal, if we
 * want to change we should be able to change."* The rail could already do it;
 * the heading over the terminal — which is often the only copy of the name on
 * screen, because the rail can be pinned away entirely — could not.
 *
 * `react-dom/server`, like every other render test in this folder: the project
 * has no DOM in its test setup. So the *field* cannot be opened here — it
 * appears on a gesture and there is nothing to gesture at — and handlers are
 * invisible to a rendered string. The two that matter are read out of the
 * source, the way `session-rename.test.tsx` and `wiring.test.ts` already read
 * files for the things a rendered string cannot show.
 */

const SOURCE = readFileSync(join(__dirname, 'SessionTitle.tsx'), 'utf8')
const CSS = readFileSync(join(__dirname, 'SessionTitle.css'), 'utf8')
const FIELD = readFileSync(join(__dirname, '../state/session-rename.ts'), 'utf8')

function render(node: React.ReactElement, inStore = true): string {
  return renderToStaticMarkup(inStore ? <StoreProvider>{node}</StoreProvider> : node)
}

describe('the session’s name over its terminal', () => {
  const html = render(<SessionTitle title="Fix the parser" sessionId="s1" />)

  it('says the gesture exists, because a gesture leaves nothing on screen', () => {
    // The same sentence the rail's rows carry. It is the same gesture on the
    // same name, and a second wording would read as a second feature.
    expect(html).toContain('double-click or F2 to rename')
  })

  it('offers no pencil, because that decision is already on record', () => {
    /*
     * *"I don't want this edit button here. Just double click should make it
     * editable. That's it."* A second idiom for one action is worse than either
     * on its own, because then neither is the answer to "how do I rename this".
     */
    expect(html).not.toContain('<button')
    expect(html).not.toContain('Rename')
  })

  it('opens the field on a double-click of the heading itself', () => {
    // Invisible to a rendered string, so read from the source. What has to stay
    // true is that the gesture lands on the text — not on some new target
    // invented beside it.
    const at = SOURCE.indexOf('data-renameable="true"')
    expect(at, 'the heading has changed shape — this test can no longer see it').toBeGreaterThan(0)
    const attributes = SOURCE.slice(at, SOURCE.indexOf('>\n      {title}', at))
    expect(attributes).toContain('onDoubleClick={() => field.begin(sessionId, title)}')
  })

  it('can still be reached without a mouse', () => {
    // F2 rather than Return, because Return on a focused element means "press
    // it" everywhere else in this window.
    expect(SOURCE).toContain("if (event.key !== 'F2') return")
    expect(SOURCE).not.toContain("event.key === 'Enter'")
    expect(html).toContain('aria-keyshortcuts="F2"')
    // Focusable, or F2 can never arrive at all.
    expect(html).toContain('tabindex="0"')
  })

  it('stops being part of the window’s drag handle', () => {
    /*
     * The trap that makes this gesture different here from in the rail. The
     * toolbar's lead is deliberately draggable — it is the part of a title bar
     * everybody grabs to move a window — and a double-click on a draggable
     * region is claimed by the OS before any handler sees it: macOS reads it as
     * the title-bar double-click action, which by default zooms the window. So
     * the renameable heading gives the drag up for its own rectangle, and only
     * that one: a heading with no session behind it keeps it.
     */
    expect(CSS).toContain('.toolbar-title[data-renameable] {')
    const rule = CSS.slice(
      CSS.indexOf('.toolbar-title[data-renameable] {'),
      CSS.indexOf('}', CSS.indexOf('.toolbar-title[data-renameable] {')),
    )
    expect(rule).toContain('-webkit-app-region: no-drag')
  })
})

describe('what it does not offer a rename on', () => {
  it('leaves a heading that is not a session’s alone', () => {
    // A sidebar view's heading is the app's word for a page. There is no
    // session to rename, and the toolbar's drag region is the whole reason not
    // to claim the rectangle anyway.
    const html = render(<SessionTitle title="Source control" sessionId={null} />)
    expect(html).toBe('<h1 class="toolbar-title">Source control</h1>')
  })

  it('draws no affordance where there is nowhere to write a name', () => {
    /*
     * Outside a store — `.harness/`, and the static-render tests next door —
     * there is no session list. A gesture that opens a field whose value goes
     * nowhere is the same fault as a button that highlights and does nothing,
     * so the affordance is absent rather than inert. Same rule the rail follows.
     */
    const alone = render(<SessionTitle title="Fix the parser" sessionId="s1" />, false)
    expect(alone).toBe('<h1 class="toolbar-title">Fix the parser</h1>')
  })
})

describe('the rename underneath it', () => {
  it('is the one the rail uses, not a second copy', () => {
    /*
     * `useSessionRename` owns the cleaning, the length budget, "a blank field
     * is a cancel", and the `fromUser` flag that stops the auto-titler taking
     * the name away again at the session's next pause in output. A copy here is
     * exactly how the heading would come to disagree with the rail about
     * whether a name survives the next chunk of output.
     */
    expect(SOURCE).toContain("from '../state/session-rename'")
    expect(SOURCE).toContain('useSessionRename()')
    expect(SOURCE).toContain('useRenameField(rename)')
    expect(SOURCE).toContain('maxLength={MAX_TITLE_LENGTH}')
    // And nothing that writes a title on its own.
    expect(SOURCE).not.toContain('setSessionTitle')
  })

  it('is not closed again by the terminal that just took focus', () => {
    /*
     * The half of the gesture that is broken and looks like nothing — and it is
     * worse over a terminal than over a rail, because the thing that steals the
     * focus is directly underneath this heading. Timed in the running app:
     * field at t+73ms, `xterm-helper-textarea` takes focus at t+75ms, field gone
     * at t+76ms, because a blur means "save and close".
     *
     * `relatedTarget` cannot separate the two cases — a real click into the
     * terminal names the same element. What can is that a click or a keypress
     * is something the *user* did and arrives before the focus moves.
     */
    expect(FIELD).toContain('userActed')
    expect(FIELD).toContain("document.addEventListener('pointerdown', mark, true)")
    expect(FIELD).toContain("document.addEventListener('keydown', mark, true)")
    // And the caller takes the focus back on the next frame rather than inside
    // the handler: a `focus()` in the middle of a `blur` is a fight the browser
    // arbitrates and Chromium does not always give to the caller.
    expect(SOURCE).toMatch(/if \(field\.blurred\(\)\) return[\s\S]{0,160}requestAnimationFrame/)
  })
})
