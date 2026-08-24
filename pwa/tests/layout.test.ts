import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/**
 * Three CSS rules that have each already been a bug, pinned as text.
 *
 * ## Why a stylesheet is being asserted at all
 *
 * Because nothing else in this client can be. `main.ts` builds its DOM against
 * a real browser and vitest runs here with no DOM environment, so every layout
 * decision in this product lives in exactly one place a test can reach: the
 * stylesheet, as a string. The alternative is what happened — two of the three
 * rules below were found by a person looking at the screen, once in a screen
 * recording, and the third by the same person a fortnight earlier.
 *
 * This is deliberately not a test of appearance. It cannot see a pixel and does
 * not try to; it asserts that three specific *decisions* are still written down.
 * Each one is a rule whose absence is invisible in a diff, silent in a typecheck,
 * and obvious on a screen.
 *
 * ## Reading it as text rather than parsing it
 *
 * A CSS parser would let these assertions be about structure rather than about
 * spelling, and it would also be a dependency this client does not have and a
 * second thing to be wrong. The rules being pinned are short and are quoted
 * whole, so a reformat that breaks this test is a reformat somebody should look
 * at anyway.
 */

const styles = readFileSync(fileURLToPath(new URL('../src/styles.css', import.meta.url)), 'utf8')

/** The declarations inside one selector's block, as written. */
function block(selector: string): string {
  const at = styles.indexOf(`${selector} {`)
  expect(at, `${selector} is not in styles.css at all`).toBeGreaterThan(-1)
  const open = styles.indexOf('{', at)
  const close = styles.indexOf('}', open)
  return styles.slice(open + 1, close)
}

describe('the layout decisions that cannot be seen from a test', () => {
  it('never caps the width of the frame', () => {
    /*
     * The regression this exists to stop, in his words: "this is not full page …
     * and it's not terminal experience as well".
     *
     * `#app { max-width: 900px; margin: 0 auto }` inside a `min-width: 700px`
     * query is the obvious way to make a phone layout survive a monitor, and it
     * put a *terminal* in a 900px strip down the middle of the screen — about
     * 110 columns, on the one surface in this product whose whole job is
     * columns. Nothing may cap the frame again. What caps a screen's content is
     * `--column`, `--form` and `--prose`, applied per screen, and the terminal
     * is on none of those lists.
     */
    expect(block('#app')).not.toContain('max-width')
    // Not merely absent from the base rule: it must not come back inside a
    // width query either, which is where it was.
    const wide = styles.slice(styles.indexOf('@media (min-width: 700px)'))
    expect(wide).not.toContain('#app')
  })

  it('lets a screen stop growing while the terminal never does', () => {
    // The other half of the same decision. A list and a form cap; the emulator
    // is given the window.
    expect(block('.screen')).toContain('max-width: var(--column)')
    expect(block('.screen--form')).toContain('max-width: var(--form)')
    expect(block('.terminal')).not.toContain('max-width')
    expect(block('.terminal-screen')).not.toContain('max-width')
  })

  it('really hides the key bar when there is a physical keyboard', () => {
    /*
     * `main.ts` sets `hidden` on the dock from `physical-keyboard.ts`, and
     * `hidden` is a UA rule of `display: none` that **any** `display` in an
     * author stylesheet outranks. `.keybar-dock` sets `flex: none`, and its
     * parent is a flex column, so without this rule the attribute is set, the
     * tests pass, the typecheck passes and eleven buttons stay on screen.
     *
     * This is not hypothetical in this file. `.header__back` shipped with
     * exactly that bug — a back chevron on the pair screen, pointing at
     * nothing — and carries a comment saying so.
     */
    expect(block('.keybar-dock[hidden]')).toContain('display: none')
    expect(block('.tabs[hidden]')).toContain('display: none')
    expect(block('.header__back[hidden]')).toContain('display: none')
    expect(block('.ask[hidden]')).toContain('display: none')
  })

  it('has a hidden rule for every flex element the client hides', () => {
    /*
     * The general form of the rule above, so the next one is caught when it is
     * written rather than when somebody notices it on a screen.
     *
     * Every selector that declares `display: flex` and is a *root* name — `#app`
     * or a class with no `__` element in it — is listed here with the answer to
     * "does it need the escape hatch". Adding a flex block to this stylesheet
     * means answering that question, which is the whole point.
     *
     * The `__` exclusion is the interesting half and is deliberate rather than
     * incidental: this client is a BEM-ish stylesheet where a `block__element`
     * is drawn by its block and is never hidden on its own, so the ones worth
     * asking about are exactly the blocks.
     */
    const flexBlocks = [...styles.matchAll(/\n(\.[a-z][a-z-]*|#app) \{([^}]*)\}/g)]
      .filter((match) => /display:\s*flex/.test(match[2]))
      .map((match) => match[1])

    // Hidden by main.ts, so each needs its own `[hidden]` rule.
    //
    // `.dock` is the copilot's side panel and `.sheet` is the confirmation it
    // raises, and both are hidden far more often than they are shown — the dock
    // is absent on the copilot's own screen by the layout rule, and the sheet
    // exists only while a question is waiting. Each is a flex container, so each
    // would ignore the attribute without a rule of its own, and the failure would
    // be the worst one in this client: a permission dialog that stays on screen
    // after it has been answered.
    // `.sbar` is the session's own row of chips — usage, context, account — and
    // it is empty far more often than the others: a desktop that predates
    // `CAPABILITY.usage`, a session nothing has answered for yet, an account that
    // could not be established. Empty it would still be a 1px rule across the top
    // of the terminal, so it is hidden, so it needs the hatch.
    // `.sctl` is the session's control cluster — model, effort, fast mode,
    // permission — and it is hidden in the same situations `.sbar` is empty: a
    // desktop that predates `CAPABILITY.controls`, a session nothing has
    // answered for yet, a plain shell with no agent to control. Same 1px-rule
    // failure, same hatch.
    const hidden = ['.tabs', '.ask', '.dock', '.sheet', '.sbar', '.sctl']
    for (const selector of hidden) {
      expect(flexBlocks, `${selector} should still be a flex container`).toContain(selector)
      expect(styles, `${selector} is hidden and needs a [hidden] rule`).toContain(`${selector}[hidden] {`)
    }

    // Everything else that is flex is never hidden. If this list has to grow,
    // check whether the new one is hidden anywhere before adding it.
    //
    // `.appearance` is on that list rather than the one above deliberately: the
    // appearance control is drawn on every screen including the pair screen,
    // because it is the one preference somebody changes *because of what is on
    // the screen right now*, and a control that disappeared before pairing would
    // be missing from the first screen anybody sees.
    //
    // `.setting` is a settings row — an icon-less title, its current value and
    // either a chevron or a stepper. It is never hidden: a row that would have
    // nothing to say is not drawn at all, which is the same rule the tab strip
    // and the folder picker follow.
    //
    // The copilot's blocks are all on this list and none is on the other one,
    // which is the point of listing them: everything inside the panel is drawn or
    // not drawn by the builder that assembles it, so none of them is ever hidden
    // by an attribute. The two that are — the panel itself and the sheet — are
    // above.
    const never = [
      '#app',
      '.appearance',
      '.banner',
      '.body',
      '.chat',
      // `.chatv` is the *session's* conversation — the copilot's is `.chat` —
      // and `.chatc` is the composer under it. Both are swapped in and out of
      // the pane rather than hidden in place, so neither needs an attribute
      // rule: both halves of the mode toggle exist for the life of the pane and
      // only one of them is in the document.
      '.chatc',
      '.chatv',
      '.composer',
      '.content',
      '.copilot',
      '.copilot-fleet',
      '.copilot-playhead',
      '.copilot-scan',
      // The two state chips at the head of the copilot screen — the machine's
      // copilot and this browser's run. Drawn or not drawn by the builder that
      // assembles the panel, never hidden by an attribute.
      '.copilot-state',
      '.copilot-toggle',
      '.header',
      '.keybar',
      '.pending',
      // The three flex blocks of the terminal colour picker: a scheme card, the
      // row of buttons under the grid, and one colour's row inside the editor.
      // None is ever hidden — the editor and the paste box are built or not
      // built by `scheme-picker.ts` when the settings screen is assembled, which
      // is the same rule every copilot block above follows.
      '.scheme',
      '.scheme-actions',
      '.scheme-row',
      '.session',
      '.session-line',
      '.setting',
      '.terminal-screen',
      '.trail',
    ]
    expect(flexBlocks.filter((selector) => !hidden.includes(selector)).sort()).toEqual(never)
  })

  it('keeps the appearance control small enough to survive a phone header', () => {
    /*
     * > *"On the top header bar I still see the same three separate — Auto,
     * > Light, Dark. You can just give one small icon for switching."*
     *
     * The three pills took about 150 of a 390px header, which inside a terminal
     * truncated the session's title to "Rework the localhost sc…". The answer
     * used to be a width rule that deleted the control on that screen; the
     * answer now is that the control is one icon and fits, so both the rule and
     * the `is-terminal` class it keyed off are gone.
     *
     * This pins the size, because the way the old problem comes back is somebody
     * putting a word next to the glyph. A 28px control plus the 44px tap target
     * around it leaves a phone header its title.
     */
    const control = block('.appearance')
    expect(control).toContain('width: 28px')
    expect(control).toContain('height: 28px')
    // And no rule anywhere may delete it again: it is the one preference somebody
    // changes because of what is on the screen right now, and the screen most
    // likely to be too bright is the one with a terminal on it.
    expect(styles).not.toContain('is-terminal')
    const source = readFileSync(fileURLToPath(new URL('../src/main.ts', import.meta.url)), 'utf8')
    expect(source).not.toContain("classList.toggle('is-terminal'")
    // One button, not a strip of them. The old markup was a `<div class="appearance">`
    // holding three `.appearance__choice` pills.
    expect(styles).not.toContain('.appearance__choice')
    expect(source).toContain("element('button', 'appearance')")
  })

  it('gives both spellings of Open a disabled treatment', () => {
    /*
     * Open is a `<button>` when the page opens on the machine and an `<a>` when
     * it opens in this browser — two elements, because one puts a frame on a
     * socket and the other is a navigation, and only a real link can be
     * cmd-clicked, copied or dragged to a bookmark bar.
     *
     * The trap is that an anchor has no `:disabled`. A field with nothing typed
     * in it disables the button through the property and the anchor through
     * `aria-disabled` plus a removed href, and a stylesheet that only knew about
     * the first would leave a full-strength blue Open sitting over an empty
     * address bar — a control that looks pressable and does nothing, which is the
     * single most repeated complaint across three nights of review.
     */
    for (const selector of ['.port__open', '.browse__go']) {
      expect(styles, `${selector} has no aria-disabled rule`).toContain(`${selector}[aria-disabled='true']`)
    }
    const off = block(".port__open[aria-disabled='true'],\n.browse__go[aria-disabled='true']")
    expect(off).toContain('pointer-events: none')
    expect(off).toContain('opacity')
  })

  it('draws no address field when there is nowhere to send an address', () => {
    /*
     * The standing rule, in the stylesheet: a control that cannot act is absent,
     * not greyed. `.browse__none` is the sentence that replaces the whole bar
     * when this browser reached the machine through the relay *and* the machine
     * will not open pages, and it exists so that the empty case is a paragraph
     * rather than a cursor blinking in a field that goes nowhere.
     */
    expect(styles).toContain('.browse__none {')
    // And nothing anywhere disables the field itself, which would be the other
    // way of drawing that state and the wrong one.
    expect(styles).not.toContain('.browse__field:disabled')
    expect(styles).not.toContain(".browse__field[aria-disabled")
  })

  it('really hides the toast when there is nothing being said', () => {
    /*
     * The general rule again, for the one element added since it was written.
     * `.toast` is `position: fixed` with a `z-index`, so an author `display` that
     * outranks the UA's `hidden` would leave an empty capsule floating over the
     * bottom of every screen — visible as a dark pill on a dark theme only when
     * something happened to be behind it, which is exactly the class of bug that
     * ships.
     */
    expect(block('.toast[hidden]')).toContain('display: none')
    // And it may never take a press. It is an aside — everything that matters has
    // a surface that stays until it stops being true — so a finger aimed at the
    // row underneath must reach the row.
    expect(block('.toast')).toContain('pointer-events: none')
  })

  it('caps the settings and machines screens without capping the terminal', () => {
    /*
     * Both new screens are `.screen`, which is where `--column` is applied, and
     * neither invents a width of its own. The rule being pinned is that they went
     * through the existing decision rather than around it: a screen that set its
     * own `max-width` would be the third answer to a question this sheet already
     * answers in one place, and the one that drifts.
     */
    for (const selector of ['.group', '.machine', '.machines', '.portgroup']) {
      expect(block(selector), `${selector} must not cap its own width`).not.toContain('max-width')
    }
  })

  it('draws no line between the port rows now that they are grouped', () => {
    /*
     * "A lot of separations is not a good idea, it's not Apple style." The rows
     * were separated by a hairline each while they were one flat list. They are
     * grouped under headers now, and a rule between every row *inside* a group is
     * a separation inside a separation — space does that job here, and the group
     * header does the rest.
     */
    expect(block('.port')).not.toContain('border-bottom')
    expect(block('.portgroup')).not.toContain('border')
    expect(block('.portgroup__head')).not.toContain('border')
  })

  it('paints the terminal in the terminal’s own paper, in both appearances', () => {
    /*
     * The failure this exists to stop is the one that makes a light theme look
     * broken rather than absent: the chrome flips to paper and the emulator
     * stays charcoal, because the surface under xterm was painted with the
     * page's canvas.
     *
     * Two rules, because there are two layers — the box `.terminal` fills, and
     * the scrolling viewport xterm paints inside it — and a mismatch between
     * them is the black gutter this stylesheet already fixed once.
     */
    expect(block('.terminal')).toContain('background: var(--terminal-bg)')
    expect(block('.terminal .xterm-viewport')).toContain('background-color: var(--terminal-bg)')
    // And never the page's canvas, which is the value both of them used to have
    // and which is only correct by accident in the dark theme.
    expect(block('.terminal')).not.toContain('var(--bg-primary)')
  })
})
