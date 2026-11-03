import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from './SettingsWindow'
import { sectionsFor } from './settings-schema'
import * as controls from './controls'

/**
 * One Settings window, one ⓘ.
 *
 * ## The defect this file exists to stop coming back
 *
 * Asad, 2026-08-17, about Settings → Copilot: *"the ⓘ dot shows its detail **on
 * hover, as a popup** — not by expanding the pane downward."*
 *
 * That was done to Copilot and to nothing else, and the result was worse than
 * either pattern on its own: one window, two dots drawn identically, behaving
 * differently. On Copilot a hover opened a popup over the page and cost nothing
 * below it. On General, Appearance, Notifications, Tools, Browser, Advanced,
 * About and Remote the same glyph was a disclosure — a click inserted the
 * paragraph into the flow and pushed every row under it down the pane.
 *
 * A person learns what a control does once. Which lesson they learn depended on
 * which pane they happened to open first, and the other eight then behaved
 * "wrong". That is the whole complaint, and it is not a matter of taste: two
 * behaviours behind one glyph is the interface lying about how many things it
 * has.
 *
 * ## Why the popup won
 *
 * `components/HoverNote.tsx` carries the argument at length. In short: a
 * disclosure is the right pattern for a single settings row and the wrong one
 * for a pane with six of them, because reading the second explanation moves the
 * third somewhere else — and it is reachable by pointer, keyboard, click and
 * screen reader, so nothing that could be read before became unreachable.
 *
 * ## What is asserted, and why it is asserted twice
 *
 * A `HoverNote` renders **nothing** until somebody hovers it, and this project's
 * test setup has no DOM to hover with. So the popup's absence from static markup
 * proves nothing on its own — which is exactly the property that makes it the
 * right control and the awkward one to pin.
 *
 * Two halves, then:
 *
 *  - **The rendered window** must contain no expanding body and no old dot, for
 *    every section on every platform. That is the regression as a reader would
 *    meet it.
 *  - **The source** of every settings surface must not name the disclosure
 *    machinery at all, and `controls.tsx` must not export it. That is the
 *    regression as it would actually arrive: somebody adding a pane, copying the
 *    nearest row they can find, and reaching for a control that should no longer
 *    be there to reach for.
 */

const HERE = join(__dirname)
const RENDERER = join(__dirname, '..')

/** Everything that draws a pane of the settings window, or a section of it. */
const SURFACES = [HERE, join(RENDERER, 'remote'), join(RENDERER, 'copilot')]

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry)
    if (statSync(path).isDirectory()) {
      sourceFiles(path, out)
      continue
    }
    // Tests are excluded deliberately: this file names all three symbols in its
    // own prose and in its own assertions, and so may any test that describes
    // what was removed.
    if (/\.tsx?$/.test(entry) && !/\.test\.tsx?$/.test(entry)) out.push(path)
  }
  return out
}

/**
 * The three names the disclosure was built from.
 *
 * `<Info` rather than `Info`, because `AboutInfo`, `HookServerInfo` and a dozen
 * other honest identifiers contain the word — the thing being banned is the
 * *element*, and an element is unambiguous in the source.
 */
const GONE = [/\bMoreBody\b/, /\buseMore\b/, /<Info\b/]

/**
 * The file with its comments taken out, because what is banned is the code.
 *
 * `controls.tsx` explains at length what used to be declared there and why it is
 * not any more, naming all three symbols — and that paragraph is the reason the
 * next person will not put them back. A scan that failed on prose would force
 * the explanation out of the file it explains.
 *
 * Crude on purpose. A `//` inside a string literal takes the rest of that line
 * with it, which can only ever hide an occurrence, never invent one — and this
 * assertion is about an absence, so the safe direction for the imprecision is
 * the one it already goes in. Every real declaration of these three is a line of
 * code with nothing quoted around it.
 */
function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')
}

describe('the ⓘ behaves one way in the whole window', () => {
  it('has no disclosure machinery left in any settings surface', () => {
    const offenders: string[] = []
    for (const dir of SURFACES) {
      for (const file of sourceFiles(dir)) {
        const source = withoutComments(readFileSync(file, 'utf8'))
        for (const banned of GONE) {
          if (banned.test(source)) offenders.push(`${file.slice(RENDERER.length + 1)} — ${banned}`)
        }
      }
    }
    expect(offenders).toEqual([])
  })

  it('does not offer the disclosure controls from `controls.tsx` any more', () => {
    /*
     * The export is the door. A pane cannot expand downward by accident if the
     * thing that expands it is not importable — and leaving the exports behind
     * "just in case" is how one window ends up with two behaviours again, one
     * pane at a time.
     */
    const exported = Object.keys(controls)
    expect(exported).not.toContain('Info')
    expect(exported).not.toContain('MoreBody')
    expect(exported).not.toContain('useMore')
  })

  it('draws no expanding body on any pane, on any platform', () => {
    for (const platform of ['mac', 'windows', 'other'] as const) {
      for (const section of sectionsFor(platform)) {
        const html = renderToStaticMarkup(
          <SettingsPanel bridge={{}} platform={platform} initialSection={section.id} />,
        )
        // The paragraph inserted into the flow, and the button that inserted it.
        expect(html, `${platform}/${section.id}`).not.toContain('settings-info-body')
        expect(html, `${platform}/${section.id}`).not.toContain('class="settings-info"')
      }
    }
  })

  it('still puts a dot beside the rows that have more to say', () => {
    /*
     * The other half of the same claim: the explanations were moved, not
     * deleted. General carries four of them and is the pane the rail opens on,
     * so it is the one worth naming here — an empty window would pass every
     * assertion above and fail every reader.
     */
    const html = renderToStaticMarkup(
      <SettingsPanel bridge={{}} platform="mac" initialSection="general" />,
    )
    expect(html).toContain('class="hovernote-dot"')
    /*
     * The paragraph is in the document — clipped to a pixel, so the dot's
     * `aria-describedby` resolves for a reader who cannot hover — and the *box*
     * is not, because a box is laid out and a clipped span is not. That is the
     * property the whole change was for: the words are reachable and they cost
     * the page no height.
     */
    expect(html).toContain('class="hovernote-text"')
    expect(html).not.toContain('class="hovernote"')
  })

  it('reaches the paragraph four ways, so hover is not the only door', () => {
    /*
     * A popup that answered only to a pointer would be a dead control on a
     * touch screen and for anybody driving this window from the keyboard — the
     * exact objection that made the original ⓘ a disclosure in the first place.
     * `HoverNote` answers to pointer, focus, click and screen reader, and this
     * pins the two that are visible in static markup: it is a real `<button>`
     * so Tab reaches it, and it names its paragraph through `aria-describedby`
     * so a screen reader announces the text whether or not it is drawn.
     */
    const html = renderToStaticMarkup(
      <SettingsPanel bridge={{}} platform="mac" initialSection="general" />,
    )
    const dot = html.slice(html.indexOf('hovernote-dot') - 200, html.indexOf('hovernote-dot') + 200)
    expect(dot).toContain('type="button"')
    expect(dot).toContain('aria-describedby')
    expect(dot).toContain('aria-label="More about ')
  })
})
