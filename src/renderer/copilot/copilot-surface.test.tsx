import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { CopilotMachines } from './CopilotMachines'
import type { CopilotMachine } from './useCopilotMachines'

/**
 * The machine switch at the top of the copilot page, and the **surface it is
 * drawn on**.
 *
 * ## The defect
 *
 * Asad, 2026-08-21: *"on the copilot page dont give full light bar for full
 * width of page for the pills keep it less obvious and simple."*
 *
 * Nothing in `.cp-machines` drew a bar. `.copilot-page` had no `background` at
 * all, so every pixel above `.cp-body` fell through to `.main`, which paints the
 * app canvas — `#ffffff` in the light theme against the terminal's `#e8e8e8`
 * paper. The switch was therefore sitting on a **pure white plate the width of
 * the window**, wedged between the toolbar and the terminal, and the plate grew
 * to the record strip's whole height whenever the strip had anything in it. In
 * the dark theme the canvas and the paper are the same colour, which is why the
 * complaint names a *light* bar and why reading the rule for `.cp-machines`
 * alone explains nothing.
 *
 * ## Why these are assertions about the stylesheet
 *
 * Because the defect was in the stylesheet and nowhere else — no component
 * changed to produce it and none had to change to fix it. The values are read
 * out of the real `copilot.css` and the real `tokens.css` and compared with each
 * other, so what is pinned is the *relationship* the app already states in
 * `tokens.css` under `--tab-active` — **a band takes the surface of the thing
 * directly under it** — rather than a colour typed into a test, which would go
 * stale the day the palette moves.
 */

const ROOT = join(__dirname, '..', '..', '..')
const sheet = (rel: string): string => readFileSync(join(ROOT, 'src', rel), 'utf8')

/** Declarations of one rule, by its exact selector, from a stylesheet's text. */
function rule(css: string, selector: string): Record<string, string> {
  const bare = css.replace(/\/\*[\s\S]*?\*\//g, '')
  const found: Record<string, string> = {}
  for (const match of bare.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (match[1].trim() !== selector) continue
    for (const decl of match[2].split(';')) {
      const at = decl.indexOf(':')
      if (at === -1) continue
      found[decl.slice(0, at).trim()] = decl.slice(at + 1).trim()
    }
  }
  return found
}

/** Every selector in a stylesheet, in source order. */
function selectors(css: string): string[] {
  const bare = css.replace(/\/\*[\s\S]*?\*\//g, '')
  return [...bare.matchAll(/([^{}]+)\{[^{}]*\}/g)].map((m) => m[1].trim())
}

/**
 * What one custom property is set to, in each appearance, in source order.
 *
 * `tokens.css` states the light values first (`:root, [data-theme='light']`) and
 * the dark ones second, so index 0 is light and index 1 is dark. Both are read
 * because a tint that orders correctly on white can invert on a dark canvas.
 */
function token(name: string): string[] {
  const css = sheet('renderer/styles/tokens.css').replace(/\/\*[\s\S]*?\*\//g, '')
  return [...css.matchAll(new RegExp(`--${name}:\\s*([^;]+);`, 'g'))].map((m) => m[1].trim())
}

/** The alpha of an `rgba(…)` fill, which is the only thing these greys differ in. */
function alpha(value: string): number {
  const parts = /rgba?\(([^)]*)\)/.exec(value)
  expect(parts, `${value} is not an rgba() fill`).not.toBeNull()
  const bits = (parts as RegExpExecArray)[1].split(',')
  expect(bits).toHaveLength(4)
  return Number(bits[3])
}

const COPILOT = sheet('renderer/copilot/copilot.css')

describe('the page is drawn on the surface of the pane it holds', () => {
  it('paints a ground at all, so the row is not a plate of app canvas', () => {
    /*
     * The one-line version of the whole defect. Without a `background` here the
     * page is `.main`'s canvas, and in the light theme that is a white bar the
     * width of the window above a grey terminal.
     */
    expect(rule(COPILOT, '.copilot-page').background).toBeTruthy()
    expect(rule(COPILOT, '.copilot-page').background).not.toBe('var(--bg-primary)')
  })

  it('paints the same ground as the pane directly under it', () => {
    // `.cp-body` is the pane. The page above it must agree, or the difference
    // between them is a bar — which is what a person sees, whatever it is called
    // in the file.
    expect(rule(COPILOT, '.copilot-page').background).toBe(rule(COPILOT, '.cp-body').background)
  })

  it('follows the pane to the app canvas when the pane is a remote conversation', () => {
    /*
     * `.cp-remote` is deliberately *not* the terminal's paper — there is no
     * terminal in that branch and one cannot be put on the network, so it is
     * drawn on the app's own surface. The band above it has to move with it;
     * pinning the page to the terminal's paper unconditionally would relocate
     * the seam rather than close it.
     */
    const remote = rule(COPILOT, '.copilot-page:has(.cp-remote)')
    expect(remote.background, 'no rule follows the page to the remote pane').toBeTruthy()
    expect(remote.background).toBe(rule(COPILOT, '.cp-remote').background)
  })

  it('leaves the switch and the strip painting nothing of their own', () => {
    /*
     * The fix is one ground on the page, not a fill per band. A `background` on
     * either of these would be the full-width bar drawn back on purpose — and it
     * would be wrong in the remote branch as well, where the pane under them is
     * a different surface.
     */
    expect(rule(COPILOT, '.cp-machines').background).toBeUndefined()
    expect(rule(COPILOT, '.cp-strip').background).toBeUndefined()
  })
})

describe('the machine you are on still reads as chosen', () => {
  const chosen = rule(COPILOT, '.cp-machine[data-chosen]')

  it('is marked twice — a tint and a weight — rather than by one plate', () => {
    // *"less obvious and simple"* is answered by saying it quietly twice, not by
    // saying it once louder. The row carries no accent, so with the plate alone
    // one small grey rectangle was the entire answer to which machine this is.
    expect(chosen.background).toBeTruthy()
    expect(chosen['font-weight']).toBeTruthy()
    expect(chosen['font-weight']).not.toBe(rule(COPILOT, '.cp-machine')['font-weight'])
  })

  it('is never quieter than the machine merely under the pointer', () => {
    /*
     * Measured, not assumed: the first pass of this dropped the chosen fill one
     * step to `--fill-quaternary` to quieten it, and rendering showed 0.045
     * against `--bg-hover`'s 0.055 — the machine being *hovered* then had the
     * stronger plate than the machine actually chosen, so the row answered the
     * wrong question for as long as a cursor sat over it. Both appearances are
     * checked because these greys are alpha over opposite grounds.
     */
    const hover = rule(COPILOT, '.cp-machine:not([data-chosen]):hover')
    const on = token(/var\(--([\w-]+)\)/.exec(chosen.background as string)?.[1] ?? '')
    const over = token(/var\(--([\w-]+)\)/.exec(hover.background as string)?.[1] ?? '')
    expect(on).toHaveLength(2)
    expect(over).toHaveLength(2)
    for (const appearance of [0, 1]) {
      expect(alpha(on[appearance])).toBeGreaterThan(alpha(over[appearance]))
    }
  })

  it('does not lean on source order to keep hover off the chosen row', () => {
    /*
     * It used to: a bare `.cp-machine:hover` and `.cp-machine[data-chosen]` have
     * the same specificity, so the chosen fill won only by being later in the
     * file. That is a correct screen held up by nothing — moving either block
     * inverts it silently. The exclusion is in the selector now.
     */
    expect(selectors(COPILOT)).toContain('.cp-machine:not([data-chosen]):hover')
    expect(selectors(COPILOT)).not.toContain('.cp-machine:hover')
  })
})

describe('the switch itself is untouched', () => {
  const here: CopilotMachine = { id: '', name: 'this Mac', reach: 'ready', open: true }
  const pc: CopilotMachine = { id: 'm1', name: 'office-pc', reach: 'ready', open: true }

  it('still offers every machine, and marks exactly one', () => {
    // Quietening a control must not cost it the affordance. Rendered rather than
    // reasoned about: the row is still a row, every machine is still pressable,
    // and the one you are on is still the one marked.
    const html = renderToStaticMarkup(
      <CopilotMachines machines={[here, pc]} chosen="" onChoose={() => {}} />,
    )
    expect(html).toContain('class="cp-machines"')
    expect(html).toContain('this Mac')
    expect(html).toContain('office-pc')
    expect(html).not.toContain('disabled')
    expect(html.match(/data-chosen="true"/g)).toHaveLength(1)
    expect(html.match(/aria-checked="true"/g)).toHaveLength(1)
  })
})
