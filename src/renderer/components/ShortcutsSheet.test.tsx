import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ShortcutsList } from './ShortcutsSheet'
import { FeaturesProvider } from '../features/FeaturesProvider'
import { defaultFeatureState, offCommands } from '../features/state'
import { KEYMAP, type KeyBinding } from '../keymap'

/**
 * There is no DOM environment in this project's test setup, so these render
 * the list to static markup. `ShortcutsSheet` itself wraps it in `Modal`,
 * which portals into `document.body` and therefore needs a real document —
 * the same split `SessionInspector.test.tsx` uses.
 *
 * `isMac` is passed explicitly throughout. Node's global `navigator.platform`
 * reports 'MacIntel' on a Mac, so the default would silently be macOS-mode and
 * the non-mac assertions would pass for the wrong reason.
 *
 * Rendered without a `FeaturesProvider` unless a case wants one, which means
 * the shipped defaults decide what is live — `Every session at once` is off out
 * of the box, so `⌘\` is not in a default sheet and the expectations below are
 * built from the same table rather than typed out.
 */

function render(props: Partial<Parameters<typeof ShortcutsList>[0]> = {}): string {
  return renderToStaticMarkup(<ShortcutsList isMac {...props} />)
}

/** The keymap as a fresh install sees it. */
const off = offCommands(defaultFeatureState())
const LIVE = KEYMAP.filter((binding) => !off.includes(binding.id))

describe('ShortcutsList', () => {
  it('lists every binding whose feature is installed', () => {
    const html = render()
    for (const binding of LIVE) {
      expect(html, binding.id).toContain(binding.label)
    }
  })

  it('leaves out a chord whose feature is not installed, and puts it back on install', () => {
    /*
     * The sheet is where somebody goes when they are not sure what a chord
     * does, so a sheet that advertises one the app will not carry out is worse
     * than no sheet. `Split the window ⌘D` was printed as working with Split
     * view uninstalled, while the command palette in the same window greyed the
     * row out and offered "Install Split view" — two answers to one question,
     * from one keymap.
     */
    const withProvider = (split: 'on' | 'uninstalled'): string =>
      renderToStaticMarkup(
        <FeaturesProvider storage={null} initial={{ ...defaultFeatureState(), split }}>
          <ShortcutsList isMac />
        </FeaturesProvider>,
      )

    const gone = withProvider('uninstalled')
    expect(gone).not.toContain('Split the window')
    expect(gone).not.toContain('<kbd>⌘D</kbd>')
    // The chords it does not own are untouched.
    expect(gone).toContain('New session')

    const back = withProvider('on')
    expect(back).toContain('Split the window')
    expect(back).toContain('<kbd>⌘D</kbd>')
  })

  it('groups by scope in reading order, with a heading and a hint for each', () => {
    const html = render()
    expect(html).toContain('Anywhere')
    expect(html).toContain('In a session')
    expect(html).toContain('In a dialog')
    expect(html.indexOf('Anywhere')).toBeLessThan(html.indexOf('In a session'))
    expect(html).toContain('Everything else reaches the agent.')
  })

  it('renders the platform glyphs', () => {
    expect(render({ isMac: true })).toContain('<kbd>⌘⇧I</kbd>')
    const pc = render({ isMac: false })
    expect(pc).toContain('<kbd>Ctrl+Shift+I</kbd>')
    expect(pc).not.toContain('⌘')
  })

  it('offers a search field wired to a live count', () => {
    const html = render()
    expect(html).toContain('type="search"')
    expect(html).toContain('aria-label="Search shortcuts"')
    expect(html).toContain('aria-live="polite"')
    // The count is what is on screen, which is the installed half of the
    // keymap — printing `KEYMAP.length` beside a shorter list is the same lie
    // in a smaller place.
    expect(html).toContain(`>${LIVE.length}<`)
  })

  it('names the search field as the count it describes', () => {
    const html = render()
    const described = /aria-describedby="([^"]+)"/.exec(html)
    expect(described).not.toBeNull()
    expect(html).toContain(`id="${described?.[1]}"`)
  })

  it('shows both chords of a binding that has two', () => {
    const html = render()
    expect(html).toContain('<kbd>⌘K</kbd>')
    expect(html).toContain('<kbd>⌘⇧P</kbd>')
    expect(html).toContain('sheet-or')
  })

  it('renders a range as one entry rather than nine rows', () => {
    const html = render()
    expect(html).toContain('<kbd>⌘1–9</kbd>')
    expect(html).not.toContain('<kbd>⌘7</kbd>')
  })

  it('marks the keys it deliberately does not intercept', () => {
    const html = render()
    expect(html).toContain('passes through')
    expect(html).toContain('Interrupt the agent')
  })

  it('flags commands the app has not wired up', () => {
    const html = render({ handled: ['session.new'] })
    expect(html).toContain('unassigned')
    expect(html).toContain('data-unassigned="true"')
  })

  it('never calls a documented passthrough unassigned', () => {
    const html = render({ handled: [] })
    const interrupt = html.slice(html.indexOf('Interrupt the agent'))
    expect(interrupt.slice(0, 200)).not.toContain('unassigned')
  })

  it('trusts every binding when no handler list is given', () => {
    expect(render()).not.toContain('unassigned')
  })

  it('does not report an empty keymap as a failed search', () => {
    // Nothing has been typed, so “Nothing matches “”.” would read as a broken
    // filter rather than a sheet with nothing in it.
    const html = render({ bindings: [] })
    expect(html).toContain('No shortcuts to show.')
    expect(html).not.toContain('Nothing matches')
  })

  it('shows one key chip per chord, never a repeat', () => {
    // Off macOS `mod` and `ctrl` render the same, so these two chords collapse
    // to one chip instead of "Ctrl+X or Ctrl+X" with a duplicated React key.
    const bindings: KeyBinding[] = [
      { id: 'x', keys: ['mod+x', 'ctrl+x'], label: 'Doubled', scope: 'global', group: 'G' },
    ]
    const html = render({ bindings, isMac: false })
    expect(html.match(/<kbd>Ctrl\+X<\/kbd>/g)).toHaveLength(1)
    expect(html).not.toContain('sheet-or')
  })

  it('renders a supplied keymap instead of the app one', () => {
    const bindings: KeyBinding[] = [
      { id: 'only', keys: ['mod+j'], label: 'Only Command', scope: 'global', group: 'G' },
    ]
    const html = render({ bindings })
    expect(html).toContain('Only Command')
    expect(html).toContain('<kbd>⌘J</kbd>')
    expect(html).not.toContain('New session')
    // A scope with no bindings contributes no heading.
    expect(html).not.toContain('In a dialog')
  })
})
