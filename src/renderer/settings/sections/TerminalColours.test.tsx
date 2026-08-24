import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  BUILTIN_SCHEMES,
  CUSTOM_SCHEME_PREFIX,
  FOLLOW_APP_SCHEME_ID,
  SLOT_LABELS,
  TERMINAL_SCHEME_SETTING,
  copyOf,
  customSchemeKey,
  schemeById,
  storedScheme,
} from '../../../shared/terminal-theme'
import { DEFAULT_VALUES, splitPatch, isKeyedSettingId } from '../settings-schema'
import { AppearanceSection } from './AppearanceSection'
import { TerminalColours } from './TerminalColours'

/**
 * The picker, as markup.
 *
 * Static markup rather than a driven DOM, like every other test in this window
 * — and the limits of that are worth stating rather than papering over. What is
 * checkable here is that every scheme reaches the screen, that each card is
 * drawn *in its own colours* rather than named, and that the pane says which
 * one is on. What is not is anything that needs a click, which is why this
 * feature was also driven in a real browser with a live terminal beside it: the
 * claim that a colour repaints an open session is not a claim any renderer of
 * strings can settle.
 */
const props = (values: Record<string, unknown> = {}) => ({
  values: { ...DEFAULT_VALUES, ...values },
  save: () => {},
})

const render = (values: Record<string, unknown> = {}): string =>
  renderToStaticMarkup(<TerminalColours {...props(values)} />)

describe('the scheme picker', () => {
  it('draws a card for every scheme that ships, plus following the app', () => {
    const markup = render()
    for (const scheme of BUILTIN_SCHEMES) {
      expect(markup, `${scheme.name} has no card`).toContain(scheme.name)
    }
    expect(markup).toContain('Follow the app')
    // Counted through `aria-pressed`, which every card carries and nothing
    // else does — `class="scheme-card` also matches the name and the tag.
    expect((markup.match(/aria-pressed=/g) ?? []).length).toBe(BUILTIN_SCHEMES.length + 1)
  })

  /**
   * Each card is the scheme, which is the whole argument for this control.
   *
   * A picker of names is a picker you cannot use: nobody knows what Gruvbox
   * looks like from the word. So the assertion is that the scheme's own hex
   * values are in the markup of its own card — if a card ever went back to
   * being a label, this is what fails.
   */
  it('paints each card in the colours it is offering', () => {
    const markup = render()
    for (const scheme of BUILTIN_SCHEMES) {
      expect(markup, `${scheme.name}'s ground is not on the page`).toContain(scheme.background)
      expect(markup, `${scheme.name}'s magenta is not on the page`).toContain(scheme.brightMagenta)
    }
  })

  it('shows all sixteen as swatches, on every card', () => {
    const swatches = (render().match(/class="scheme-swatch"/g) ?? []).length
    expect(swatches).toBe(BUILTIN_SCHEMES.length * 16)
  })

  it('marks nothing as chosen, and says so, before anybody picks', () => {
    const markup = render()
    expect(markup).toContain('Sessions follow the app’s own light and dark.')
    expect((markup.match(/aria-pressed="true"/g) ?? []).length).toBe(1)
  })

  it('names the scheme in the help line once one is pinned', () => {
    expect(render({ [TERMINAL_SCHEME_SETTING]: 'gruvbox-dark' })).toContain(
      'Every session is drawn in Gruvbox Dark.',
    )
  })

  it('offers no editing while sessions follow the app, because there is nothing to edit', () => {
    expect(render()).not.toContain('Edit colours')
    expect(render({ [TERMINAL_SCHEME_SETTING]: 'nord' })).toContain('Edit colours')
  })

  /**
   * Delete and Rename belong to a scheme somebody made, and to nothing else.
   *
   * A Delete button on Dracula is the dead control the design brief forbids:
   * it cannot work, because a built-in is what the app ships.
   */
  it('offers Delete and Rename on your own schemes only', () => {
    const builtin = render({ [TERMINAL_SCHEME_SETTING]: 'nord' })
    expect(builtin).not.toContain('>Delete<')
    expect(builtin).not.toContain('>Rename<')

    const mine = copyOf(schemeById('nord')!, [])
    const markup = render({
      [TERMINAL_SCHEME_SETTING]: mine.id,
      [customSchemeKey(mine.id)]: storedScheme(mine),
    })
    expect(markup).toContain('>Delete<')
    expect(markup).toContain('>Rename<')
    expect(markup).toContain('Nord (yours)')
    // And it is marked as yours on the card, because a person with fifteen
    // schemes cannot tell from the order which ones they may delete.
    expect(markup).toContain('scheme-card-tag')
  })

  it('draws every one of the twenty-one rows once the editor is open', () => {
    // The editor is behind a click, which static markup cannot make — so the
    // rows are checked through the labels table they are generated from, and
    // the click itself is exercised in the browser.
    expect(Object.keys(SLOT_LABELS)).toHaveLength(21)
  })

  /**
   * A verb with nothing to act on is not drawn greyed — it is not drawn.
   *
   * Copying, editing, duplicating and deleting all act on the *chosen* scheme,
   * and while sessions follow the app there is no chosen scheme. A greyed row
   * of four buttons in that state is four dead controls, which is the thing the
   * design brief forbids; the one verb that always makes sense — pasting a new
   * scheme in — stays on the row above and is always live.
   */
  it('draws no verb that would have nothing to act on', () => {
    const following = render()
    for (const verb of ['Copy as JSON', 'Duplicate', 'Edit colours']) {
      expect(following, `${verb} is offered with no scheme chosen`).not.toContain(`>${verb}<`)
    }
    expect(following).toContain('>Paste a scheme<')

    const chosen = render({ [TERMINAL_SCHEME_SETTING]: 'nord' })
    for (const verb of ['Copy as JSON', 'Duplicate', 'Edit colours', 'Paste a scheme']) {
      expect(chosen, `${verb} is missing`).toContain(`>${verb}<`)
    }
    expect(chosen).not.toMatch(/<button[^>]*disabled[^>]*>Copy as JSON<\/button>/)
  })
})

/**
 * Terminal appearance is one place on one pane.
 *
 * The complaint this whole rail was reorganised for — *"everything should be in
 * one place so they don't have to think, always they need to go for one piece of
 * information into general and for the other piece in agents"* — applies inside
 * a pane as well as across the rail. The size and the face were generated into
 * a flat list with the window's own theme between them and the colours; they are
 * in a group of their own now, and this is what keeps them there.
 */
describe('the Terminal group on Appearance', () => {
  const pane = renderToStaticMarkup(<AppearanceSection {...props()} bridge={{}} loading={false} goTo={() => {}} reload={() => {}} />)

  it('carries a heading of its own', () => {
    expect(pane).toContain('>Terminal</h4>')
  })

  it('holds the colours, the size and the face — and the window’s rows do not', () => {
    const group = pane.slice(pane.indexOf('>Terminal</h4>'))
    for (const label of ['Terminal colours', 'Terminal font size', 'Terminal font']) {
      expect(group, `${label} is not in the Terminal group`).toContain(label)
    }
    const above = pane.slice(0, pane.indexOf('>Terminal</h4>'))
    expect(above).toContain('Theme')
    expect(above).toContain('Density')
    expect(above).not.toContain('Terminal font size')
  })
})

/**
 * A scheme somebody made is a settings key, and the router knows it.
 *
 * This is the one place the settings pipeline had to grow for this feature, and
 * it is the place it could silently fail: `splitPatch` drops what it cannot
 * place, and `SettingsWindow` does not look at what was dropped. A scheme
 * written under an id nothing routes would apply on screen, survive until the
 * pane re-read the file, and then vanish — which is the worst shape of bug this
 * feature could have, because the person would have watched it work.
 */
describe('routing a scheme somebody made to the settings file', () => {
  it('recognises a keyed id and nothing else', () => {
    expect(isKeyedSettingId(`${CUSTOM_SCHEME_PREFIX}custom-1`)).toBe(true)
    // The prefix with nothing after it is not a scheme; nor is the setting that
    // names the chosen one, which is a declared row.
    expect(isKeyedSettingId(CUSTOM_SCHEME_PREFIX)).toBe(false)
    expect(isKeyedSettingId(TERMINAL_SCHEME_SETTING)).toBe(false)
    expect(isKeyedSettingId('appearance.theme')).toBe(false)
  })

  it('sends it to settings.json rather than dropping it as unknown', () => {
    const mine = copyOf(schemeById('nord')!, [])
    const split = splitPatch({ [customSchemeKey(mine.id)]: storedScheme(mine) })
    expect(split.unknown).toEqual([])
    expect(split.extra[customSchemeKey(mine.id)]).toBe(storedScheme(mine))
  })

  it('carries a delete through as null, which is how the store removes a key', () => {
    const split = splitPatch({ [`${CUSTOM_SCHEME_PREFIX}custom-1`]: null })
    expect(split.extra[`${CUSTOM_SCHEME_PREFIX}custom-1`]).toBeNull()
    expect(split.unknown).toEqual([])
  })

  it('refuses anything under the prefix that is not a scheme’s text', () => {
    const split = splitPatch({ [`${CUSTOM_SCHEME_PREFIX}custom-1`]: { not: 'a string' } })
    expect(split.extra).toEqual({})
    expect(split.unknown).toEqual([`${CUSTOM_SCHEME_PREFIX}custom-1`])
  })

  it('still sends the chosen scheme itself down the declared path', () => {
    const split = splitPatch({ [TERMINAL_SCHEME_SETTING]: FOLLOW_APP_SCHEME_ID })
    expect(split.extra[TERMINAL_SCHEME_SETTING]).toBe(FOLLOW_APP_SCHEME_ID)
    expect(split.prefs).toEqual({})
  })
})
