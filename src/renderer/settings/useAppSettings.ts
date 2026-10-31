import { useCallback, useEffect, useState } from 'react'
import { applyStoredTheme } from '../theme'
import { applyTerminalScheme } from '../terminal-scheme'
import { toStoredSettings } from './settings-bridge'
import {
  DEFAULT_VALUES,
  mergeSettings,
  stringSetting,
  valuesFromPreferences,
  type SettingValues,
} from './settings-schema'

/**
 * The stored settings, for the parts of the app that have to *behave*
 * differently because of one.
 *
 * The settings window reads the same file, but it is a dialog: it exists only
 * while it is open, and everything it knows dies with it. Anything that changes
 * how the app runs — how big the terminal's type is, whether a finished session
 * earns a banner, whether closing a working session asks first — is needed
 * whether or not that dialog has ever been opened, which is exactly the bug
 * that left Compact density inert until the first visit to Settings.
 *
 * One read, at launch, and one setter the dialog pushes through as the user
 * changes things — `SettingsWindow` already fires `onChange` with the merged
 * values after every accepted write, so nothing here polls and nothing re-reads
 * a file that only this app writes.
 */
export function useAppSettings(): {
  values: SettingValues
  /**
   * False until the file has been read.
   *
   * Anything that acts *once*, at launch, has to wait for this — reopening the
   * user's projects reads a setting, and doing it against the schema default
   * would reopen them for someone who turned that off, a frame before their
   * answer arrived.
   */
  loaded: boolean
  /** Fed from `<SettingsWindow onChange>` so a change lands here immediately. */
  apply: (next: SettingValues) => void
} {
  const [values, setValues] = useState<SettingValues>(DEFAULT_VALUES)
  const [loaded, setLoaded] = useState(false)

  /**
   * Both files, because a setting lives in one of two.
   *
   * Four of them — the theme, the default agent, reopen-on-launch, notify-on-
   * finish — are in `store.ts`, which the main process reads at spawn time, and
   * the rest are in `settings.json`. Reading only the second is a bug with no
   * symptom at all: `mergeSettings` fills the four missing keys with their
   * schema defaults, so the app runs on a default that the settings window
   * simultaneously shows as the user's own choice. Preferences win for the keys
   * they own, exactly as `SettingsWindow` resolves the same two sources.
   */
  useEffect(() => {
    let cancelled = false
    void Promise.all([
      window.deck.getSettings().catch(() => ({})),
      window.deck.getPreferences().catch(() => ({})),
    ])
      .then(([stored, prefs]) => {
        if (cancelled) return
        setValues(
          mergeSettings({ ...toStoredSettings(stored), ...valuesFromPreferences(prefs) }),
        )
        setLoaded(true)
      })
      .catch(() => {
        // The schema defaults are what the app already assumes.
        if (!cancelled) setLoaded(true)
      })
    return () => {
      cancelled = true
    }
  }, [])

  /**
   * A value changed by something that is not this window.
   *
   * The copilot can write settings and preferences — with a confirmation, and
   * with a last-good copy taken first — and so, behind it, can a paired phone.
   * Until 2026-08-18 none of that reached React: a preference was only ever
   * learned from the return value of this window's own `prefs:set`, so a write
   * from anywhere else landed on disk and the running window went on drawing
   * what it had read at startup. Watched live, in words: *"switch to the light
   * theme"* → the dialog drew, `state.json` said `"light"`, the window stayed
   * dark, and the copilot reported it as done. True of the file, false of the
   * screen — which to the person in front of it is a tool that does not work.
   *
   * **This hook rather than `App.tsx`**, which is where the handback proposed
   * it. This is the module that already owns "the settings the app behaves by",
   * and it is the one that writes the theme and the density onto `<html>` in the
   * effect below — so one subscription here repaints the theme, the density and
   * every behaviour keyed off a setting, while the same subscription in `App.tsx`
   * would have had to reach back into this hook to do any of it.
   *
   * Merged over what is held rather than replacing it, because the two stores
   * arrive on two channels: a preferences push must not blank the forty values
   * that live in `settings.json`, and a settings push must not blank the four
   * that live in `store.ts`.
   *
   * Guarded with `?.` on both, and that is not defensiveness about the preload —
   * it is the harness. `.harness/stub.ts` mounts this same `App` against a
   * stubbed bridge, and a method it has not grown yet must leave the window
   * running rather than throw on mount.
   */
  useEffect(() => {
    const offPrefs = window.deck.onPreferencesChanged?.((prefs) => {
      setValues((prev) => mergeSettings({ ...prev, ...valuesFromPreferences(prefs) }))
    })
    const offSettings = window.deck.onSettingsChanged?.((stored) => {
      setValues((prev) => mergeSettings({ ...prev, ...toStoredSettings(stored) }))
    })
    return () => {
      offPrefs?.()
      offSettings?.()
    }
  }, [])

  /**
   * Theme and density are attributes on <html>, so they are applied here rather
   * than read by a component. Everything else in this table is a value someone
   * asks for. Doing it here is also what makes them apply before Settings has
   * ever been opened — Compact was inert until the first visit to that dialog.
   */
  useEffect(() => {
    document.documentElement.dataset.density = stringSetting(values, 'appearance.density')
    applyStoredTheme(values['appearance.theme'])
    /*
     * And the terminal's own colours, for the same reason the two above are
     * here rather than in a component: no terminal is handed the settings, and
     * a scheme that only took effect once Settings had been opened would be
     * `appearance.density` all over again — inert on every launch until
     * somebody visited the dialog that sets it.
     *
     * Order matters by one frame. This runs after the theme attribute is
     * written, so a window launching on "follow the app" has the right tokens
     * on `<html>` before any terminal resolves them.
     */
    applyTerminalScheme(values)
  }, [values])

  const apply = useCallback((next: SettingValues) => setValues(next), [])
  return { values, loaded, apply }
}
