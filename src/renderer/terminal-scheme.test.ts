import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  BUILTIN_SCHEMES,
  CUSTOM_SCHEME_PREFIX,
  FOLLOW_APP_SCHEME_ID,
  TERMINAL_SCHEME_SETTING,
  copyOf,
  customSchemeKey,
  schemeById,
  storedScheme,
} from '../shared/terminal-theme'
import {
  applyTerminalScheme,
  previewTerminalScheme,
  pinnedScheme,
  resetTerminalScheme,
  resolveTerminalScheme,
  subscribeTerminalScheme,
} from './terminal-scheme'

const ROOT = resolve(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

afterEach(() => resetTerminalScheme())

/**
 * Which scheme a settings map means, including the three ways it means none.
 *
 * The resolution is the whole of this module that can be wrong in a way a
 * screenshot would not show: the module state around it is a variable and a
 * `Set`. So it is pure and it is tested as a function of a settings map, the
 * same shape `useAppSettings` holds and `SettingsWindow` writes.
 */
describe('the scheme a settings map names', () => {
  it('is none at all before anybody has opened the pane', () => {
    expect(resolveTerminalScheme({})).toBeNull()
  })

  it('is none when the stored choice is to follow the app', () => {
    expect(resolveTerminalScheme({ [TERMINAL_SCHEME_SETTING]: FOLLOW_APP_SCHEME_ID })).toBeNull()
  })

  /**
   * And none for an id nothing answers, which is not a corner case.
   *
   * It is what a downgrade looks like from the inside — a settings file naming
   * a scheme this build has never heard of — and what a second window sees for
   * the moment after another one deletes the custom scheme both were using.
   * Falling back to the app's own appearance is the only answer that is never
   * wrong; falling back to whichever built-in happens to be first would repaint
   * somebody's terminal a colour they never chose.
   */
  it('is none for an id this build does not know', () => {
    expect(resolveTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'gone-in-a-downgrade' })).toBeNull()
  })

  it('is none when the stored value is not even a string', () => {
    expect(resolveTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 42 })).toBeNull()
    expect(resolveTerminalScheme({ [TERMINAL_SCHEME_SETTING]: '' })).toBeNull()
  })

  it('is the built-in an id names', () => {
    const scheme = resolveTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'pure-black' })
    expect(scheme?.name).toBe('Pure Black')
    expect(scheme?.background).toBe('#000000')
  })

  it('is one of the person’s own, read out of the same map', () => {
    const mine = { ...copyOf(schemeById('nord')!, []), name: 'Mine' }
    const scheme = resolveTerminalScheme({
      [TERMINAL_SCHEME_SETTING]: mine.id,
      [customSchemeKey(mine.id)]: storedScheme(mine),
    })
    expect(scheme?.name).toBe('Mine')
    expect(scheme?.brightCyan).toBe('#8fbcbb')
  })
})

describe('telling every terminal', () => {
  it('starts pinned to nothing', () => {
    expect(pinnedScheme()).toBeNull()
  })

  it('fires once when the scheme changes and not at all when it does not', () => {
    const heard = vi.fn()
    subscribeTerminalScheme(heard)
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'dracula' })
    expect(heard).toHaveBeenCalledTimes(1)
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'dracula' })
    expect(heard).toHaveBeenCalledTimes(1)
    expect(pinnedScheme()?.id).toBe('dracula')
  })

  /**
   * A colour changed inside one scheme is a change, and this is the assertion
   * that says so.
   *
   * Comparing by id would be the obvious implementation and would leave every
   * open session in the old colours through an entire editing session — the id
   * does not move while somebody drags twenty-one pickers.
   */
  it('fires when a colour moves inside the scheme that is already pinned', () => {
    const mine = copyOf(schemeById('nord')!, [])
    const values = {
      [TERMINAL_SCHEME_SETTING]: mine.id,
      [customSchemeKey(mine.id)]: storedScheme(mine),
    }
    applyTerminalScheme(values)
    const heard = vi.fn()
    subscribeTerminalScheme(heard)
    applyTerminalScheme({
      ...values,
      [customSchemeKey(mine.id)]: storedScheme({ ...mine, red: '#ff0000' }),
    })
    expect(heard).toHaveBeenCalledTimes(1)
    expect(pinnedScheme()?.red).toBe('#ff0000')
  })

  it('goes back to nothing when the choice goes back to following the app', () => {
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'dracula' })
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: FOLLOW_APP_SCHEME_ID })
    expect(pinnedScheme()).toBeNull()
  })

  it('stops telling a terminal that has gone', () => {
    const heard = vi.fn()
    const off = subscribeTerminalScheme(heard)
    off()
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'nord' })
    expect(heard).not.toHaveBeenCalled()
  })

  /**
   * One subscriber throwing must not take the others down with it.
   *
   * The subscribers are three terminals mid-teardown; the same argument
   * `theme.ts` makes beside its own notify, and the same failure it is guarding
   * against — a disposed xterm throwing on `options.theme` and leaving every
   * other session in the window painted in the old scheme.
   */
  it('carries on past a subscriber that throws', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const second = vi.fn()
    subscribeTerminalScheme(() => {
      throw new Error('disposed')
    })
    subscribeTerminalScheme(second)
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: 'nord' })
    expect(second).toHaveBeenCalledTimes(1)
    spy.mockRestore()
  })

  it('paints a preview nothing has stored, and lets the next write replace it', () => {
    const heard = vi.fn()
    subscribeTerminalScheme(heard)
    previewTerminalScheme({ ...schemeById('nord')!, background: '#123456' })
    expect(pinnedScheme()?.background).toBe('#123456')
    expect(heard).toHaveBeenCalledTimes(1)
    applyTerminalScheme({ [TERMINAL_SCHEME_SETTING]: FOLLOW_APP_SCHEME_ID })
    expect(pinnedScheme()).toBeNull()
  })
})

/**
 * The wiring, pinned as text — the half no unit test can reach.
 *
 * `wiring.test.ts` already makes this argument for the app theme, and it makes
 * it because the bug it is about was invisible: `subscribeTheme` existed for a
 * year with no caller, every test passed, and a session opened before a theme
 * switch stayed in the old palette. A scheme is the same shape of wire, one
 * layer along, and it has one more end to come loose — a terminal that
 * subscribes and never unsubscribes leaks a closure over a disposed emulator.
 */
describe('every terminal is wired to the scheme', () => {
  const OWNERS = [
    'src/renderer/components/TerminalView.tsx',
    'src/renderer/machines/RemoteTerminal.tsx',
    'src/renderer/machines/servers/ServerTerminal.tsx',
  ]

  it.each(OWNERS)('%s subscribes, repaints and unsubscribes', (file) => {
    const source = read(file)
    expect(source, 'a terminal that never hears about a scheme keeps the one it was born in').toMatch(
      /subscribeTerminalScheme\(/,
    )
    expect(source, 'subscribing without writing options.theme changes nothing').toMatch(
      /const offScheme = subscribeTerminalScheme\(\(\) => \{\s*term\.options\.theme = terminalTheme\(\)/,
    )
    expect(source, 'a subscription that outlives its terminal is a leak').toMatch(/\boffScheme\(\)/)
  })

  /**
   * And all three resolve it through the one function, which is what makes the
   * remote panes look like the local one.
   */
  it('resolves the palette through TerminalView’s own function in all three', () => {
    expect(read('src/renderer/machines/RemoteTerminal.tsx')).toMatch(
      /import \{ terminalTheme \} from '\.\.\/components\/TerminalView'/,
    )
    expect(read('src/renderer/machines/servers/ServerTerminal.tsx')).toMatch(
      /terminalTheme[,}].*from '\.\.\/\.\.\/components\/TerminalView'/,
    )
  })

  /**
   * The app's own settings apply the scheme, not just the settings window.
   *
   * This is `appearance.density` all over again if it is missed: that setting
   * was inert on every launch until somebody opened the dialog that sets it,
   * because the only code applying it lived in the dialog.
   */
  it('is applied at launch by the hook that owns "how the app behaves"', () => {
    expect(read('src/renderer/settings/useAppSettings.ts')).toMatch(/applyTerminalScheme\(values\)/)
  })

  /**
   * And the surfaces xterm does not paint follow it too.
   *
   * xterm fills the box it was given; the padding around it, the copilot's
   * body and a split pane's ground are painted by the stylesheet from
   * `--terminal-bg`. Overriding that one token is what keeps a pinned cream
   * terminal from sitting inside a dark grey frame.
   */
  it('moves the token every surface around a session is painted from', () => {
    const source = read('src/renderer/terminal-scheme.ts')
    expect(source).toContain("const PAPER_TOKEN = '--terminal-bg'")
    expect(source).toMatch(/root\.style\.setProperty\(PAPER_TOKEN, scheme\.background\)/)
    expect(source).toMatch(/root\.style\.removeProperty\(PAPER_TOKEN\)/)
    // Every path that changes what is painted has to repaint the paper too.
    expect(source.match(/paintPaper\(/g)?.length ?? 0).toBeGreaterThanOrEqual(4)
  })

  /**
   * The selected tab deliberately does *not* follow it.
   *
   * `--tab-active` is declared as a literal in `tokens.css` rather than as
   * `var(--terminal-bg)`, which is what stops a cream terminal putting a cream
   * tab in a dark title bar. That is load-bearing now, so it is asserted here
   * as well as in `tokens.test.ts`, which checks the two for equality and would
   * still pass if one became a reference to the other.
   */
  it('leaves the tab strip on the app’s own colour', () => {
    const sheet = read('src/renderer/styles/tokens.css')
    for (const declaration of sheet.matchAll(/--tab-active:\s*([^;]+);/g)) {
      expect(declaration[1].trim()).toMatch(/^#[0-9a-f]{6}$/i)
    }
  })
})

/**
 * The keyed settings prefix is one thing, spelled once.
 *
 * `splitPatch` routes on it, the pane writes under it and `customSchemesFrom`
 * reads it back. Three copies of a string is how a scheme gets written to a key
 * nothing reads.
 */
describe('the settings key a custom scheme lives under', () => {
  it('is the shared model’s, everywhere it is used', () => {
    expect(customSchemeKey('custom-1')).toBe(`${CUSTOM_SCHEME_PREFIX}custom-1`)
    expect(read('src/renderer/settings/settings-schema.ts')).toContain('CUSTOM_SCHEME_PREFIX')
    expect(read('src/renderer/settings/sections/TerminalColours.tsx')).toContain('customSchemeKey(')
  })

  it('is a child of the setting that names the chosen scheme, so a raw file reads clearly', () => {
    expect(CUSTOM_SCHEME_PREFIX.startsWith(`${TERMINAL_SCHEME_SETTING}.`)).toBe(true)
  })

  it('never collides with a built-in id, whichever scheme ships next', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      expect(scheme.id.startsWith('custom-')).toBe(false)
    }
  })
})
