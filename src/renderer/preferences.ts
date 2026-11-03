/**
 * Reading the four values `store.ts` keeps, safely.
 *
 * These two functions are all that is left of `PreferencesModal.tsx`, which was
 * the app's settings dialog until `settings/SettingsWindow.tsx` replaced it.
 * The dialog then sat in the tree for weeks with nothing rendering it, kept
 * alive only because two other components imported these helpers out of it —
 * a component nobody can open is not a component, and "it exports something
 * useful" is not a reason to keep the rest of it around.
 *
 * The shapes come from `@shared/types` rather than being declared again here.
 * The old copy was written when this file and that one were being built in
 * parallel; keeping it would leave two definitions of one fact, and the sort of
 * drift that produces is exactly what the settings schema exists to prevent.
 */

import type { Preferences, ProviderId } from '@shared/types'
// Relative, not '@shared/…': vitest runs without the electron-vite alias, so a
// *value* import through it resolves in the app and throws in a test.
import { isCustomProviderId } from '../shared/custom-agents'
import { isThemePreference } from './theme'

export type { Preferences, ProviderId }

/** Mirrors the main-process store defaults, so an unreadable file still reads sanely. */
export const PREFERENCE_DEFAULTS: Preferences = {
  theme: 'dark',
  defaultProvider: 'claude',
  restoreSessions: true,
  notifyOnComplete: true,
}

/**
 * Is this a provider this window can act on?
 *
 * The four names this build ships, **or** an id somebody added — and the second
 * half is not tidiness, it is the fix for a row that could never be selected.
 * `installedProviders` filters the detection answer through this, and
 * `providers:detect` merges the added agents into that answer, so while this
 * named only the four an added agent came back reported-installed by the main
 * process and dropped here: the New-session dialog drew it greyed out, saying
 * the machine could not start a command it had just resolved, and starting a
 * session on it was impossible.
 *
 * The custom half is tested rather than listed for the reason `types.ts` gives
 * at length: the set is per machine, so there is no list to check against, and
 * `isCustomProviderId` is the single place the prefix is spelled.
 */
export function isProviderId(value: unknown): value is ProviderId {
  return (
    value === 'claude' ||
    value === 'codex' ||
    value === 'gemini' ||
    value === 'shell' ||
    isCustomProviderId(value)
  )
}

/**
 * Coerce whatever comes back over IPC into a complete Preferences object.
 * The store can hand back a partial or stale blob after an upgrade, and a
 * missing field must not blank a control.
 */
export function normalizePreferences(raw: unknown): Preferences {
  if (typeof raw !== 'object' || raw === null) return { ...PREFERENCE_DEFAULTS }
  const value = raw as Record<string, unknown>
  return {
    theme: isThemePreference(value.theme) ? value.theme : PREFERENCE_DEFAULTS.theme,
    defaultProvider: isProviderId(value.defaultProvider)
      ? value.defaultProvider
      : PREFERENCE_DEFAULTS.defaultProvider,
    restoreSessions:
      typeof value.restoreSessions === 'boolean'
        ? value.restoreSessions
        : PREFERENCE_DEFAULTS.restoreSessions,
    notifyOnComplete:
      typeof value.notifyOnComplete === 'boolean'
        ? value.notifyOnComplete
        : PREFERENCE_DEFAULTS.notifyOnComplete,
  }
}

/**
 * Reduce a provider-detection result to the ids actually on PATH.
 *
 * Returns null for "unknown — leave every option selectable", which covers a
 * missing, malformed, or empty result. Total by construction: the previous
 * inline `Object.entries(found)` threw a TypeError on null, and because it threw
 * inside a promise's fulfilment handler the sibling rejection handler could not
 * catch it — the app got an unhandled rejection and the provider list stayed
 * null forever. An all-false result is a real answer and still yields [].
 */
export function installedProviders(raw: unknown): ProviderId[] | null {
  if (typeof raw !== 'object' || raw === null) return null
  const entries = Object.entries(raw as Record<string, unknown>)
  // No keys at all is a broken detector, not "nothing is installed" — the main
  // process always reports every provider. Fail open rather than locking the
  // user out of every agent.
  if (entries.length === 0) return null
  return entries
    .filter(([id, ok]) => Boolean(ok) && isProviderId(id))
    .map(([id]) => id as ProviderId)
}
