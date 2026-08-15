import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  hasOwnAccessibleName,
  holdTitle,
  isWarm,
  hasContentName,
  pathLike,
  placeTip,
  releaseTitle,
  saysSomethingNew,
  splitChord,
  titleHold,
  WARM_MS,
  type Tipped,
} from './tooltip'

/**
 * The one thing in the tooltip layer that can hurt somebody.
 *
 * A styled bubble that fails to appear is a cosmetic bug. A `title` attribute
 * that is removed and not put back is a control that has silently lost its
 * accessible name — for the rest of that element's life, because React will not
 * notice: the `title` prop did not change between renders, so its diff writes
 * nothing and the attribute stays gone.
 *
 * So the strip/restore pair is tested as a round trip in both directions, on
 * both kinds of element: the one that already had a name (`.pane-cell-close`,
 * which carries `aria-label` *and* `title`, the duplication the visual pass
 * reported) and the icon-only one for which `title` was the only name there
 * ever was.
 *
 * ## The fake
 *
 * There is no DOM in this project's tests — deliberately; `dialog-render.test.tsx`
 * explains why — so the elements below are the smallest object that satisfies
 * `Tipped`, which is the same slice of `Element` the production call sites pass
 * a real `HTMLElement` into. Nothing here is standing in for a wrapper; it is
 * standing in for attributes.
 */
function element(
  attrs: Record<string, string> = {},
  text = '',
  children: Tipped[] = [],
): Tipped & { attrs: Record<string, string> } {
  const store = { ...attrs }
  return {
    attrs: store,
    getAttribute: (name) => (name in store ? store[name] : null),
    setAttribute: (name, value) => {
      store[name] = value
    },
    removeAttribute: (name) => {
      delete store[name]
    },
    // `textContent` is every descendant's text, exactly as the DOM computes it,
    // so a fake that carried only its own would not be able to reproduce the
    // aria-hidden bug this file exists to keep fixed.
    textContent: text + children.map((child) => child.textContent ?? '').join(''),
    children,
  }
}

/** `<span aria-hidden="true">↻</span>` — the glyph inside every icon button here. */
const glyph = (mark: string): Tipped => element({ 'aria-hidden': 'true' }, mark)

describe('taking a title off an element', () => {
  it('removes it, so the OS has nothing to draw its own tooltip from', () => {
    const el = element({ title: 'Close this pane', 'aria-label': 'Close this pane' })
    const held = holdTitle(el)

    expect(held).toEqual({ text: 'Close this pane', aria: false })
    expect(el.getAttribute('title')).toBeNull()
  })

  it('leaves an existing accessible name exactly as it found it', () => {
    // The `.pane-cell-close` case. Its name comes from `aria-label`; `title`
    // was never part of the computed name, so removing it changes nothing a
    // screen reader can observe — and this layer must not "helpfully" write a
    // second one.
    const el = element({ title: 'Close this pane', 'aria-label': 'Close this pane' })
    const held = holdTitle(el)

    expect(el.getAttribute('aria-label')).toBe('Close this pane')
    expect(held?.aria).toBe(false)
  })

  it('lends its own aria-label to a control that had no other name', () => {
    // The icon-only button: a glyph, `aria-hidden`, and a `title`. Strip the
    // title without this and the control becomes "button".
    const el = element({ title: 'Reload MCP servers' })
    const held = holdTitle(el)

    expect(held?.aria).toBe(true)
    expect(el.getAttribute('aria-label')).toBe('Reload MCP servers')
  })

  it('lends one to a button whose only content is an aria-hidden glyph', () => {
    /*
     * The regression, and it was found in the running app rather than here.
     *
     * The first version of this decision asked `textContent`, which answers
     * "↻" for the markup below — non-empty, so the layer concluded the button
     * already had a name, stripped the title and lent nothing. Chromium's own
     * accessible name for it, read over CDP, went from "Reload MCP servers" to
     * the empty string for as long as the pointer rested on it.
     *
     * The whitespace matters too: JSX leaves newlines between the tags, so the
     * button's `textContent` is "\n  ↻\n" and a naive comparison against the
     * glyph's "↻" puts the bug straight back.
     */
    const el = element({ title: 'Reload MCP servers' }, '\n  ', [glyph('↻')])
    const held = holdTitle(el)

    expect(held?.aria).toBe(true)
    expect(el.getAttribute('aria-label')).toBe('Reload MCP servers')
  })

  it('does not lend one to a button that has a glyph and a word', () => {
    // The sidebar's own New session button: a glyph *and* a label. Its name
    // comes from the label, so writing an aria-label would replace "New
    // session" with "New session (⌘T)" — a keyboard chord read out loud.
    const el = element({ title: 'New session (⌘T)' }, '', [glyph('+'), element({}, 'New session')])
    const held = holdTitle(el)

    expect(held?.aria).toBe(false)
    expect(el.getAttribute('aria-label')).toBeNull()
  })

  it('says no to an element with no title, and to a blank one', () => {
    expect(holdTitle(element({}))).toBeNull()
    // A bubble containing nothing is a hover state that promises nothing.
    expect(holdTitle(element({ title: '   ' }))).toBeNull()
  })

  it('does not disturb an element it declined to open on', () => {
    const el = element({ title: '  ', 'aria-label': 'Something' })
    holdTitle(el)
    expect(el.attrs).toEqual({ title: '  ', 'aria-label': 'Something' })
  })
})

describe('putting it back', () => {
  it('restores an element that already had a name to byte-identical attributes', () => {
    const before = { title: 'Close this pane', 'aria-label': 'Close this pane' }
    const el = element(before)
    const held = holdTitle(el)
    if (held === null) throw new Error('holdTitle refused a real title')
    releaseTitle(el, held)

    expect(el.attrs).toEqual(before)
  })

  it('takes back the aria-label it lent, rather than leaving it behind', () => {
    // Leaving it is the subtle version of the bug: everything looks right, and
    // a `title` that later changes is shadowed forever by a stale name that
    // appears nowhere in the source.
    const el = element({ title: 'Reload MCP servers' })
    const held = holdTitle(el)
    if (held === null) throw new Error('holdTitle refused a real title')
    releaseTitle(el, held)

    expect(el.attrs).toEqual({ title: 'Reload MCP servers' })
    expect(el.getAttribute('aria-label')).toBeNull()
  })

  it('survives being held and released repeatedly', () => {
    // Every hover is a round trip, and a toolbar button gets hundreds.
    const el = element({ title: 'New session (⌘T)' })
    for (let i = 0; i < 25; i++) {
      const held = holdTitle(el)
      if (held === null) throw new Error(`title was lost on pass ${i}`)
      releaseTitle(el, held)
    }
    expect(el.attrs).toEqual({ title: 'New session (⌘T)' })
  })
})

/**
 * The invariant the whole layer stands on: whatever the pointer does, every
 * element it touched ends up with the attributes it started with.
 *
 * This is tested apart from the component because it is the part that can be
 * wrong silently. A bubble that fails to appear gets reported in a minute; a
 * `title` left off a button is invisible until somebody who needs a screen
 * reader tries to use it.
 */
describe('holding one title at a time', () => {
  it('gives the first element back when a second is grabbed', () => {
    // Sweeping along a toolbar: this is the common path, not the edge case.
    const first = element({ title: 'New session (⌘T)' })
    const second = element({ title: 'New browser tab', 'aria-label': 'New browser tab' })
    const hold = titleHold()

    expect(hold.grab(first)).toBe(true)
    expect(first.getAttribute('title')).toBeNull()

    expect(hold.grab(second)).toBe(true)
    expect(first.attrs).toEqual({ title: 'New session (⌘T)' })
    expect(second.getAttribute('title')).toBeNull()

    hold.release()
    expect(second.attrs).toEqual({ title: 'New browser tab', 'aria-label': 'New browser tab' })
  })

  it('reports what it is holding, and nothing once it lets go', () => {
    const el = element({ title: 'Close project' })
    const hold = titleHold()

    hold.grab(el)
    expect(hold.element()).toBe(el)
    expect(hold.text()).toBe('Close project')

    hold.release()
    expect(hold.element()).toBeNull()
    expect(hold.text()).toBeNull()
  })

  it('is safe to release when it holds nothing, and to release twice', () => {
    // Every dismissal path in the layer calls this, several of them in a row —
    // a pointer leaving the window as the window loses focus fires both.
    const el = element({ title: 'Settings' })
    const hold = titleHold()

    hold.release()
    hold.grab(el)
    hold.release()
    hold.release()

    expect(el.attrs).toEqual({ title: 'Settings' })
  })

  it('holds nothing after refusing an element with no title', () => {
    // The refusal must not leave the previous element stranded either: the
    // pointer has moved on, so the old title is owed back regardless.
    const previous = element({ title: 'New session (⌘T)' })
    const bare = element({})
    const hold = titleHold()

    hold.grab(previous)
    expect(hold.grab(bare)).toBe(false)
    expect(previous.attrs).toEqual({ title: 'New session (⌘T)' })
    expect(hold.element()).toBeNull()
  })

  it('leaves nothing behind across a long sweep of controls', () => {
    // The property, rather than one case of it: after any sequence of grabs and
    // releases, every element is exactly as it was.
    const before: Record<string, string>[] = [
      { title: 'New session (⌘T)' },
      { title: 'Close this pane', 'aria-label': 'Close this pane' },
      { title: '/Users/apple/Projects/terminaldeck' },
      { title: 'Settings (⌘,)' },
    ]
    const elements = before.map((attrs) => element({ ...attrs }))
    const hold = titleHold()

    for (let pass = 0; pass < 3; pass++) {
      for (const el of elements) hold.grab(el)
      hold.release()
      for (const el of [...elements].reverse()) hold.grab(el)
      hold.release()
    }

    expect(elements.map((el) => el.attrs)).toEqual(before)
  })
})

describe('deciding whether a name already exists', () => {
  it('accepts aria-label, aria-labelledby, alt and visible text', () => {
    expect(hasOwnAccessibleName(element({ 'aria-label': 'Close' }))).toBe(true)
    expect(hasOwnAccessibleName(element({ 'aria-labelledby': 'heading-3' }))).toBe(true)
    expect(hasOwnAccessibleName(element({ alt: 'Terminal Deck' }))).toBe(true)
    // The folder chip: its button holds the folder's name, so content is the
    // accessible name and `title` — the full path — never was.
    expect(hasOwnAccessibleName(element({}, 'terminaldeck'))).toBe(true)
  })

  it('treats blank and whitespace-only as no name at all', () => {
    // `aria-label=""` computes to the empty name, which is the icon-only case
    // wearing a disguise; a button whose only content is the newline between
    // two tags is the same thing.
    expect(hasOwnAccessibleName(element({ 'aria-label': '' }))).toBe(false)
    expect(hasOwnAccessibleName(element({ 'aria-label': '   ' }))).toBe(false)
    expect(hasOwnAccessibleName(element({}, '\n      '))).toBe(false)
  })

  it('does not count text an accessible name would ignore', () => {
    expect(hasOwnAccessibleName(element({}, '', [glyph('↻')]))).toBe(false)
    expect(hasContentName(element({}, '\n  ', [glyph('↻')]))).toBe(false)
    // Two hidden glyphs and nothing else is still nothing.
    expect(hasContentName(element({}, ' ', [glyph('←'), glyph('→')]))).toBe(false)
  })

  it('counts text that is really on screen', () => {
    expect(hasContentName(element({}, 'terminaldeck'))).toBe(true)
    expect(hasContentName(element({}, '', [glyph('+'), element({}, 'New session')]))).toBe(true)
  })

  it('does not over-subtract a hidden thing inside a hidden thing', () => {
    // Recursing past an `aria-hidden` element would count the nested glyph
    // twice, subtract more text than is there, and declare a button that plainly
    // says "Save" to be nameless — at which point the layer would overwrite its
    // name with the tooltip's.
    const nested = element({}, 'Save', [element({ 'aria-hidden': 'true' }, '', [glyph('↻')])])
    expect(hasContentName(nested)).toBe(true)
  })
})

describe('splitting the keyboard chord off a label', () => {
  it('separates what tip() joined', () => {
    // `tip('New session', 'session.new')` on this Mac.
    expect(splitChord('New session (⌘T)')).toEqual({ label: 'New session', chord: '⌘T' })
    expect(splitChord('Continue last session (⌘⇧R)')).toEqual({
      label: 'Continue last session',
      chord: '⌘⇧R',
    })
  })

  it('reads the non-Mac spelling too', () => {
    expect(splitChord('New session (Ctrl+T)')).toEqual({ label: 'New session', chord: 'Ctrl+T' })
  })

  it('leaves a label alone when it has no chord', () => {
    expect(splitChord('Close project')).toEqual({ label: 'Close project', chord: null })
  })

  it('does not demote a parenthesis that is part of the text', () => {
    // The reason the tail is shape-checked rather than assumed: plenty of these
    // titles are paths and folder names, and a folder really can be called
    // `renderer (old)`.
    expect(splitChord('/Users/apple/Projects/renderer (old)')).toEqual({
      label: '/Users/apple/Projects/renderer (old)',
      chord: null,
    })
    expect(splitChord('Sessions (3)')).toEqual({ label: 'Sessions (3)', chord: null })
  })
})

describe('deciding what is data and what is a sentence', () => {
  it('sets a bare path in mono', () => {
    expect(pathLike('/Users/apple/Projects/terminaldeck')).toBe(true)
    expect(pathLike('~/Projects/terminaldeck')).toBe(true)
    expect(pathLike('C:\\Users\\Asad\\Projects\\deck')).toBe(true)
  })

  it('leaves anything that reads as a sentence in the UI face', () => {
    expect(pathLike('Close this pane')).toBe(false)
    // A sentence that merely mentions a path is still a sentence — mixing the
    // two rules inside one line would look like a rendering bug.
    expect(pathLike('/Users/apple/Projects/deck — start a session somewhere else')).toBe(false)
    expect(pathLike('/')).toBe(false)
  })
})

describe('placing the bubble', () => {
  const view = { width: 1200, height: 800 }
  const tip = { width: 160, height: 28 }

  it('sits below the control and centred on it', () => {
    const placed = placeTip({ left: 500, top: 100, width: 40, height: 26 }, tip, view)
    expect(placed.side).toBe('below')
    // 100 + 26 + 6
    expect(placed.top).toBe(132)
    // 500 + 20 - 80
    expect(placed.left).toBe(440)
  })

  it('flips above a control near the bottom edge', () => {
    const placed = placeTip({ left: 500, top: 770, width: 40, height: 26 }, tip, view)
    expect(placed.side).toBe('above')
    // 770 - 6 - 28
    expect(placed.top).toBe(736)
  })

  it('does not flip a control that merely sits low, when below still fits', () => {
    // A bubble that flips on a window one pixel too short reads as a glitch.
    // 700 + 26 + 6 + 28 = 760, and 800 - 8 = 792, so below fits.
    const placed = placeTip({ left: 500, top: 700, width: 40, height: 26 }, tip, view)
    expect(placed.side).toBe('below')
  })

  it('keeps a bubble at the window edge inside the window', () => {
    const left = placeTip({ left: 0, top: 100, width: 26, height: 26 }, tip, view)
    expect(left.left).toBe(8)

    const right = placeTip({ left: 1180, top: 100, width: 26, height: 26 }, tip, view)
    // 1200 - 160 - 8
    expect(right.left).toBe(1032)
  })

  it('keeps the start of a bubble wider than the window', () => {
    // A long path clamped to a negative left loses the half you actually need.
    const placed = placeTip({ left: 100, top: 100, width: 40, height: 26 }, { width: 1400, height: 28 }, view)
    expect(placed.left).toBe(8)
  })

  it('rounds, because this is text on glass', () => {
    const placed = placeTip({ left: 100.4, top: 100.6, width: 41, height: 25 }, tip, view)
    expect(Number.isInteger(placed.left)).toBe(true)
    expect(Number.isInteger(placed.top)).toBe(true)
  })
})

describe('the warm window', () => {
  it('is cold the first time anything is hovered', () => {
    expect(isWarm(null, 10_000)).toBe(false)
  })

  it('stays warm long enough to sweep along a toolbar', () => {
    expect(isWarm(10_000, 10_000 + WARM_MS - 1)).toBe(true)
  })

  it('goes cold again, so crossing the window on the way somewhere shows nothing', () => {
    expect(isWarm(10_000, 10_000 + WARM_MS)).toBe(false)
  })
})

/**
 * The facts a look-with-your-eyes pass establishes, pinned the way
 * `finish.test.ts` pins them — because the CSS can read correct and the
 * rendered result still be wrong, and this project has no DOM to render in.
 *
 * Every one of these is a way the bubble would be invisible or unusable while
 * every unit test above stayed green.
 */
describe('the bubble is actually drawable', () => {
  const HERE = join(__dirname)
  const read = (name: string): string => readFileSync(join(HERE, name), 'utf8')
  const css = read('tooltip.css')
  const layer = read('Tooltips.tsx')

  it('renders under <body>, so its glass has something to frost', () => {
    // Inside the toolbar — which carries `backdrop-filter`, and is therefore a
    // backdrop root — a descendant's own blur samples nothing, and a positioned
    // descendant of the panes paints straight over it. The folder menu learned
    // this the hard way; `finish.test.ts` has the full account.
    expect(layer).toContain('createPortal')
    expect(layer).toContain('document.body')
  })

  it('stacks above the modals it can appear inside', () => {
    const z = /\.tooltip \{[^}]*z-index:\s*(\d+)/.exec(css)?.[1]
    expect(z, '.tooltip declares no z-index, so it is in the same layer as the page').toBeTruthy()
    // Modal.css and CommandPalette.css both sit at 100 under <body>. A tooltip
    // on a control inside a dialog has to win that, not tie it.
    expect(Number(z)).toBeGreaterThan(100)
  })

  it('never eats the hover it is describing', () => {
    // A bubble that takes the pointer ends the hover that opened it, which
    // reads as a tooltip that flickers and a control that will not respond.
    expect(/\.tooltip \{[^}]*pointer-events:\s*none/.test(css)).toBe(true)
  })

  it('stays invisible until it has been placed', () => {
    // It is rendered before it is measured — it has to be laid out to have a
    // size — so without this it paints one frame at the top-left of the window.
    expect(/\.tooltip \{[^}]*visibility:\s*hidden/.test(css)).toBe(true)
    expect(css).toContain('.tooltip[data-placed]')
    expect(layer).toContain('data-placed')
  })

  it('takes every colour from the token sheet', () => {
    // Rule: no hex in a component stylesheet. A tooltip with a hard-coded grey
    // is a tooltip that is wrong in one of the two themes, and nobody notices
    // until they switch.
    const body = css.replace(/\/\*[\s\S]*?\*\//g, '')
    expect(body).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(body).toMatch(/var\(--material-bg-strong\)/)
  })
})

describe('a tooltip that only repeats the control', () => {
  /**
   * Six rows of the sidebar had one. Hovering "Alerts" popped a bubble reading
   * exactly "Alerts" — over the top of the "Machines" row underneath it, so the
   * hover cost the reader the row they were about to click and told them a word
   * they had just read. Every view without a keyboard chord was in that state.
   */
  const row = (label: string): Tipped => element({ title: label }, label)

  it('says nothing new when the title is the visible label', () => {
    expect(saysSomethingNew('Alerts', row('Alerts'), false)).toBe(false)
  })

  it('still speaks when it carries a chord the control does not show', () => {
    expect(saysSomethingNew('Alerts (⌘5)', row('Alerts'), false)).toBe(true)
  })

  it('still speaks for a control with no text of its own', () => {
    // The icon-only case: `title` is the only name the button has.
    expect(saysSomethingNew('New browser tab', element({}, '', [glyph('◻')]), false)).toBe(true)
  })

  it('still speaks when the label is cut off, because then it is not on screen', () => {
    expect(saysSomethingNew('A very long session title', row('A very long session title'), true)).toBe(
      true,
    )
  })

  it('ignores whitespace and glyphs the accessible name would ignore', () => {
    // The markup JSX actually produces: a hidden glyph, newlines between tags.
    const button = element({ title: 'Machines' }, '', [glyph('↻'), element({}, '\n  Machines\n')])
    expect(saysSomethingNew('Machines', button, false)).toBe(false)
  })
})
