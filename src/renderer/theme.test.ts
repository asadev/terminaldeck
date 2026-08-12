import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  createThemeController,
  isThemePreference,
  resolveTheme,
  themeController,
  THEME_ATTRIBUTE,
  type ThemeHost,
  type ThemeMediaQuery,
} from './theme'
// The preferences form ships no DOM tests — there is no jsdom here — but its
// two IPC-boundary reducers are pure, and both are places bad input reaches.
import { installedProviders, normalizePreferences } from './components/PreferencesModal'

/**
 * A stand-in for <html> plus matchMedia. There is no jsdom in this project, so
 * the controller is exercised through the same injection seam the app uses.
 */
function fakeHost(systemPrefersDark: boolean) {
  const attributes = new Map<string, string>()
  const changeListeners = new Set<(event: { matches: boolean }) => void>()

  const media: ThemeMediaQuery = {
    matches: systemPrefersDark,
    addEventListener: (_type, listener) => {
      changeListeners.add(listener)
    },
    removeEventListener: (_type, listener) => {
      changeListeners.delete(listener)
    },
  }

  const host: ThemeHost = {
    root: {
      setAttribute: (name, value) => {
        attributes.set(name, value)
      },
    },
    matchMedia: () => media,
  }

  return {
    host,
    painted: () => attributes.get(THEME_ATTRIBUTE),
    osListeners: () => changeListeners.size,
    setSystemDark(dark: boolean) {
      media.matches = dark
      for (const listener of [...changeListeners]) listener({ matches: dark })
    },
  }
}

describe('resolveTheme', () => {
  it('ignores the OS for explicit preferences', () => {
    expect(resolveTheme('dark', false)).toBe('dark')
    expect(resolveTheme('light', true)).toBe('light')
  })

  it('follows the OS for system', () => {
    expect(resolveTheme('system', true)).toBe('dark')
    expect(resolveTheme('system', false)).toBe('light')
  })
})

describe('isThemePreference', () => {
  it('accepts the three preferences', () => {
    expect(isThemePreference('dark')).toBe(true)
    expect(isThemePreference('light')).toBe(true)
    expect(isThemePreference('system')).toBe(true)
  })

  it('rejects anything else', () => {
    for (const value of ['Dark', '', null, undefined, 0, {}]) {
      expect(isThemePreference(value)).toBe(false)
    }
  })
})

describe('createThemeController', () => {
  it('paints the initial preference on construction', () => {
    const env = fakeHost(false)
    createThemeController(env.host, 'light')
    expect(env.painted()).toBe('light')
  })

  it('resolves an initial system preference against the OS', () => {
    const env = fakeHost(true)
    const theme = createThemeController(env.host, 'system')
    expect(theme.getPreference()).toBe('system')
    expect(theme.getResolved()).toBe('dark')
    expect(env.painted()).toBe('dark')
  })

  it('repaints when the preference changes', () => {
    const env = fakeHost(true)
    const theme = createThemeController(env.host, 'dark')

    expect(theme.setPreference('light')).toBe('light')
    expect(env.painted()).toBe('light')
    expect(theme.getPreference()).toBe('light')
  })

  it('tracks the OS while the preference is system', () => {
    const env = fakeHost(true)
    const theme = createThemeController(env.host, 'system')

    env.setSystemDark(false)
    expect(theme.getResolved()).toBe('light')
    expect(env.painted()).toBe('light')

    env.setSystemDark(true)
    expect(env.painted()).toBe('dark')
  })

  it('ignores the OS once a preference is explicit', () => {
    const env = fakeHost(true)
    const theme = createThemeController(env.host, 'system')
    const listener = vi.fn()
    theme.subscribe(listener)

    theme.setPreference('light')
    listener.mockClear()

    env.setSystemDark(false)
    expect(env.painted()).toBe('light')
    expect(listener).not.toHaveBeenCalled()
  })

  it('notifies subscribers with the resolved theme and the preference', () => {
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    const listener = vi.fn()

    theme.subscribe(listener)
    theme.setPreference('system')

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith('light', 'system')
  })

  it('stays quiet when nothing actually changed', () => {
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    const listener = vi.fn()

    theme.subscribe(listener)
    theme.setPreference('dark')

    expect(listener).not.toHaveBeenCalled()
    // Still repainted, so a stale attribute would be corrected.
    expect(env.painted()).toBe('dark')
  })

  it('stops notifying after unsubscribe', () => {
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    const listener = vi.fn()

    const off = theme.subscribe(listener)
    off()
    theme.setPreference('light')

    expect(listener).not.toHaveBeenCalled()
  })

  it('releases the OS listener on destroy', () => {
    const env = fakeHost(true)
    const theme = createThemeController(env.host, 'system')
    expect(env.osListeners()).toBe(1)

    theme.destroy()
    expect(env.osListeners()).toBe(0)

    // A destroyed controller must not keep repainting behind the app's back.
    env.setSystemDark(false)
    expect(env.painted()).toBe('dark')
  })
})

describe('createThemeController — a throwing subscriber', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('does not stop the subscribers behind it', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    const after = vi.fn()

    theme.subscribe(() => {
      throw new Error('a disposed terminal')
    })
    theme.subscribe(after)

    theme.setPreference('light')
    expect(after).toHaveBeenCalledWith('light', 'light')
  })

  it('does not escape setPreference, which callers chain persistence off', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    theme.subscribe(() => {
      throw new Error('a disposed terminal')
    })

    // Throwing here would paint the new theme and then skip the disk write,
    // leaving the app showing a preference it never saved.
    expect(theme.setPreference('light')).toBe('light')
    expect(env.painted()).toBe('light')
  })

  it('survives a subscriber that unsubscribes mid-notification', () => {
    const env = fakeHost(false)
    const theme = createThemeController(env.host, 'dark')
    const later = vi.fn()

    const off = theme.subscribe(() => off())
    theme.subscribe(later)

    theme.setPreference('light')
    expect(later).toHaveBeenCalledTimes(1)
  })
})

describe('themeController', () => {
  it('explains itself when there is no DOM to theme', () => {
    expect(() => themeController()).toThrow(/no DOM/)
  })
})

describe('installedProviders', () => {
  it('reports the ids that came back true', () => {
    expect(installedProviders({ claude: true, codex: false, gemini: true, shell: true })).toEqual([
      'claude',
      'gemini',
      'shell',
    ])
  })

  it('returns an empty list when nothing is installed', () => {
    // A real answer, not a broken one — every option but the plain shell
    // should end up unpickable.
    expect(installedProviders({ claude: false, codex: false, gemini: false, shell: false })).toEqual(
      [],
    )
  })

  it('treats a missing or malformed result as unknown rather than throwing', () => {
    // Regression: this was Object.entries(found) inline, which is a TypeError
    // on null — thrown inside a promise's fulfilment handler, where the sibling
    // rejection handler cannot catch it.
    for (const value of [null, undefined, 'nope', 42, true]) {
      expect(installedProviders(value)).toBe(null)
    }
  })

  it('treats an empty object as unknown, not as nothing installed', () => {
    expect(installedProviders({})).toBe(null)
  })

  it('drops keys that are not providers', () => {
    expect(installedProviders({ claude: true, rustc: true })).toEqual(['claude'])
  })
})

describe('normalizePreferences', () => {
  const defaults = {
    theme: 'dark',
    defaultProvider: 'claude',
    restoreSessions: true,
    notifyOnComplete: true,
  }

  it('fills every field when the store hands back nothing usable', () => {
    for (const value of [null, undefined, 'wat', 7, []]) {
      expect(normalizePreferences(value)).toEqual(defaults)
    }
  })

  it('keeps the fields it recognises and defaults the rest', () => {
    expect(normalizePreferences({ theme: 'light', restoreSessions: false })).toEqual({
      ...defaults,
      theme: 'light',
      restoreSessions: false,
    })
  })

  it('rejects out-of-range values rather than passing them to a control', () => {
    expect(
      normalizePreferences({ theme: 'midnight', defaultProvider: 'rustc', notifyOnComplete: 'yes' }),
    ).toEqual(defaults)
  })

  it('does not let a false toggle be read as missing', () => {
    // The tempting `value.restoreSessions || DEFAULT` would flip this back to
    // true and silently re-enable session restore on every read.
    const prefs = normalizePreferences({ restoreSessions: false, notifyOnComplete: false })
    expect(prefs.restoreSessions).toBe(false)
    expect(prefs.notifyOnComplete).toBe(false)
  })
})
