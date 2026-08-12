/**
 * Theme application for the renderer.
 *
 * tokens.css keys its whole palette off `data-theme` on the root element, so
 * theming is one attribute write. The DOM this module touches is injected
 * rather than reached for, which keeps it runnable — and testable — with no
 * browser environment at all.
 */

export type ThemePreference = 'dark' | 'light' | 'system'

/** What is actually painted. 'system' always collapses to one of these. */
export type ResolvedTheme = 'dark' | 'light'

/** The attribute tokens.css selects on. */
export const THEME_ATTRIBUTE = 'data-theme'

export const DARK_QUERY = '(prefers-color-scheme: dark)'

/** The slice of MediaQueryList the controller uses. */
export interface ThemeMediaQuery {
  matches: boolean
  addEventListener(type: 'change', listener: (event: { matches: boolean }) => void): void
  removeEventListener(type: 'change', listener: (event: { matches: boolean }) => void): void
}

/** The DOM surface a controller needs: the element carrying the attribute, and the OS preference. */
export interface ThemeHost {
  root: { setAttribute(name: string, value: string): void }
  matchMedia(query: string): ThemeMediaQuery
}

export type ThemeListener = (resolved: ResolvedTheme, preference: ThemePreference) => void

/** Collapse a preference plus the OS setting into the theme to paint. */
export function resolveTheme(preference: ThemePreference, systemPrefersDark: boolean): ResolvedTheme {
  if (preference === 'system') return systemPrefersDark ? 'dark' : 'light'
  return preference
}

/** Guard for values coming back off disk or across IPC, where the type is only a promise. */
export function isThemePreference(value: unknown): value is ThemePreference {
  return value === 'dark' || value === 'light' || value === 'system'
}

export interface ThemeController {
  getPreference(): ThemePreference
  getResolved(): ResolvedTheme
  /** Writes the attribute, notifies subscribers, and returns what is now painted. */
  setPreference(preference: ThemePreference): ResolvedTheme
  /** Returns an unsubscribe function, matching the window.pawl.on* convention. */
  subscribe(listener: ThemeListener): () => void
  /** Detach the OS listener and drop subscribers. */
  destroy(): void
}

export function createThemeController(
  host: ThemeHost,
  initial: ThemePreference = 'dark',
): ThemeController {
  const media = host.matchMedia(DARK_QUERY)
  const listeners = new Set<ThemeListener>()

  let preference: ThemePreference = initial
  let resolved: ResolvedTheme = resolveTheme(preference, media.matches)
  host.root.setAttribute(THEME_ATTRIBUTE, resolved)

  // Subscribers are other people's code — a disposed terminal, a stale pane.
  // One that throws must not swallow the rest of the list, and must not
  // propagate out of setPreference: callers chain persistence off it (paint the
  // theme, then write it to disk), so an exception here would leave the app
  // showing a theme it never saved. Iterated over a snapshot so subscribing or
  // unsubscribing from inside a listener cannot disturb the current pass.
  const notify = (nextResolved: ResolvedTheme, nextPreference: ThemePreference): void => {
    for (const listener of [...listeners]) {
      try {
        listener(nextResolved, nextPreference)
      } catch (error) {
        console.error('theme: subscriber threw', error)
      }
    }
  }

  const apply = (next: ThemePreference): ResolvedTheme => {
    const nextResolved = resolveTheme(next, media.matches)
    const changed = next !== preference || nextResolved !== resolved
    preference = next
    resolved = nextResolved
    // Written even when unchanged: it is one attribute write, and it repairs
    // the value if anything else has stamped over it (index.html ships a
    // hardcoded data-theme so the first paint is not white).
    host.root.setAttribute(THEME_ATTRIBUTE, resolved)
    if (changed) notify(resolved, preference)
    return resolved
  }

  // One OS listener for the controller's whole life rather than attaching and
  // detaching as the preference changes — apply() re-reads media.matches, so
  // the handler only has to decide whether the preference cares.
  const onSystemChange = (): void => {
    if (preference === 'system') apply('system')
  }
  media.addEventListener('change', onSystemChange)

  return {
    getPreference: () => preference,
    getResolved: () => resolved,
    setPreference: apply,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    destroy() {
      media.removeEventListener('change', onSystemChange)
      listeners.clear()
    },
  }
}

function browserHost(): ThemeHost {
  if (typeof document === 'undefined' || typeof window === 'undefined') {
    throw new Error('theme: no DOM available — build a controller with an explicit ThemeHost')
  }
  return {
    root: document.documentElement,
    matchMedia: (query) => window.matchMedia(query),
  }
}

let shared: ThemeController | null = null

/**
 * The app-wide controller. Built on first use rather than at import time, so
 * importing this module stays free of side effects.
 */
export function themeController(): ThemeController {
  if (shared) return shared
  const controller = createThemeController(browserHost())
  // Destroying the shared controller has to uninstall it too. Otherwise the
  // module keeps handing out a corpse: it still writes the attribute, but its
  // OS listener is gone and its subscribers have been dropped, so 'system'
  // silently stops tracking the desktop with no way to recover short of a
  // reload. Clearing the slot lets the next call build a live one.
  const wrapped: ThemeController = {
    ...controller,
    destroy() {
      controller.destroy()
      if (shared === wrapped) shared = null
    },
  }
  shared = wrapped
  return wrapped
}

/** Set the app theme. Safe to call on every keystroke — it is a single attribute write. */
export function applyTheme(preference: ThemePreference): ResolvedTheme {
  return themeController().setPreference(preference)
}

/** Watch what is painted, e.g. to recolour the terminals. Returns an unsubscribe function. */
export function subscribeTheme(listener: ThemeListener): () => void {
  return themeController().subscribe(listener)
}

/**
 * Apply a theme value of unknown provenance — the stored preference read back
 * over IPC — falling back to dark rather than throwing on junk.
 */
export function applyStoredTheme(value: unknown): ResolvedTheme {
  return applyTheme(isThemePreference(value) ? value : 'dark')
}
