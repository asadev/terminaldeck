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
    const hidden = ['.tabs', '.ask']
    for (const selector of hidden) {
      expect(flexBlocks, `${selector} should still be a flex container`).toContain(selector)
      expect(styles, `${selector} is hidden by main.ts and needs a [hidden] rule`).toContain(`${selector}[hidden] {`)
    }

    // Everything else that is flex is never hidden. If this list has to grow,
    // check whether the new one is hidden anywhere before adding it.
    const never = ['#app', '.banner', '.content', '.header', '.keybar', '.session', '.terminal-screen']
    expect(flexBlocks.filter((selector) => !hidden.includes(selector)).sort()).toEqual(never)
  })
})
