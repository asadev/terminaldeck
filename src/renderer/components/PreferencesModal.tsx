import { useCallback, useEffect, useId, useState } from 'react'
import { Modal } from './Modal'
import { applyTheme, isThemePreference, type ThemePreference } from '../theme'
import './PreferencesModal.css'

/**
 * Declared locally rather than imported from shared/types: this module is
 * built in parallel with that file, and the shapes are checked at the IPC
 * boundary by normalizePreferences() anyway.
 */
export type ProviderId = 'claude' | 'codex' | 'gemini' | 'shell'

export interface Preferences {
  theme: ThemePreference
  defaultProvider: ProviderId
  restoreSessions: boolean
  notifyOnComplete: boolean
}

/** Mirrors the main-process store defaults, so an unreadable file still renders a sane form. */
const DEFAULTS: Preferences = {
  theme: 'dark',
  defaultProvider: 'claude',
  restoreSessions: true,
  notifyOnComplete: true,
}

const THEMES: ReadonlyArray<{ id: ThemePreference; label: string }> = [
  { id: 'dark', label: 'Dark' },
  { id: 'light', label: 'Light' },
  { id: 'system', label: 'System' },
]

const PROVIDERS: ReadonlyArray<{ id: ProviderId; label: string }> = [
  { id: 'claude', label: 'Claude Code' },
  { id: 'codex', label: 'Codex' },
  { id: 'gemini', label: 'Gemini' },
  { id: 'shell', label: 'Plain shell' },
]

/** 'mod' renders as the platform's primary modifier. */
const SHORTCUTS: ReadonlyArray<{ keys: readonly string[]; label: string }> = [
  { keys: ['mod', 'O'], label: 'Open a project' },
  { keys: ['mod', 'T'], label: 'New session' },
  { keys: ['mod', 'W'], label: 'Close the current session' },
  { keys: ['mod', '1–9'], label: 'Jump to a session tab' },
  { keys: ['mod', ','], label: 'Preferences' },
  { keys: ['Esc'], label: 'Close this dialog' },
]

function isProviderId(value: unknown): value is ProviderId {
  return value === 'claude' || value === 'codex' || value === 'gemini' || value === 'shell'
}

/**
 * Coerce whatever comes back over IPC into a complete Preferences object.
 * The store can hand back a partial or stale blob after an upgrade, and a
 * missing field must not blank a control.
 */
export function normalizePreferences(raw: unknown): Preferences {
  if (typeof raw !== 'object' || raw === null) return { ...DEFAULTS }
  const value = raw as Record<string, unknown>
  return {
    theme: isThemePreference(value.theme) ? value.theme : DEFAULTS.theme,
    defaultProvider: isProviderId(value.defaultProvider)
      ? value.defaultProvider
      : DEFAULTS.defaultProvider,
    restoreSessions:
      typeof value.restoreSessions === 'boolean' ? value.restoreSessions : DEFAULTS.restoreSessions,
    notifyOnComplete:
      typeof value.notifyOnComplete === 'boolean'
        ? value.notifyOnComplete
        : DEFAULTS.notifyOnComplete,
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
  return entries.filter(([id, ok]) => Boolean(ok) && isProviderId(id)).map(([id]) => id as ProviderId)
}

function modifierLabel(): string {
  const agent = typeof navigator === 'undefined' ? '' : navigator.userAgent
  return /Mac|iPhone|iPad/.test(agent) ? '⌘' : 'Ctrl'
}

interface Props {
  open: boolean
  onClose(): void
  /** Fired after every accepted write, so the app can react to a changed default. */
  onChange?(preferences: Preferences): void
}

/**
 * Preferences. Changes save as they are made — there is no OK/Cancel, so a
 * theme click is visible immediately and nothing is lost by pressing Escape.
 */
export function PreferencesModal({ open, onClose, onChange }: Props) {
  const [preferences, setPreferences] = useState<Preferences>(DEFAULTS)
  const [installed, setInstalled] = useState<readonly ProviderId[] | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ids = useId()

  useEffect(() => {
    if (!open) return
    let cancelled = false

    setError(null)
    // Reset rather than leave the last visit's answers on screen. Without this,
    // reopening renders the previous values as loaded and editable while the
    // fresh read is still in flight, so a toggle flipped in that window is
    // computed against stale state — and aria-busy lies about it.
    setLoaded(false)
    setInstalled(null)

    void window.deck.getPreferences().then(
      (stored) => {
        if (cancelled) return
        const next = normalizePreferences(stored)
        setPreferences(next)
        setLoaded(true)
        // Paint what was actually stored. The radio reflects the saved
        // preference, so if anything has drifted from it — a failed save, a
        // first paint off index.html's hardcoded attribute — the control and
        // the window would otherwise disagree about the current theme.
        applyTheme(next.theme)
      },
      () => {
        if (cancelled) return
        setError('Could not read your saved preferences — showing defaults.')
        setLoaded(true)
      },
    )

    // Providers that are not on PATH are still listed, but cannot be chosen:
    // picking one would silently fall back to a plain shell at spawn time.
    void window.deck.detectProviders().then(
      (found) => {
        if (!cancelled) setInstalled(installedProviders(found))
      },
      () => {
        // Detection failing is not worth an error banner — leave every option enabled.
        if (!cancelled) setInstalled(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open])

  const save = useCallback(
    (patch: Partial<Preferences>) => {
      setPreferences((prev) => ({ ...prev, ...patch }))
      void window.deck.setPreferences(patch).then(
        (saved) => onChange?.(normalizePreferences(saved)),
        () => setError('Could not save that change — it may not survive a restart.'),
      )
    },
    [onChange],
  )

  const chooseTheme = useCallback(
    (theme: ThemePreference) => {
      // Repaint first: the disk round-trip should never be visible as a lag
      // between clicking a theme and seeing it.
      applyTheme(theme)
      save({ theme })
    },
    [save],
  )

  const modifier = modifierLabel()
  const canPick = (id: ProviderId): boolean =>
    id === 'shell' || installed === null || installed.includes(id)

  return (
    <Modal
      open={open}
      title="Preferences"
      description="Applies to every project and session."
      onClose={onClose}
      size="lg"
      footer={
        <button type="button" className="modal-btn primary" onClick={onClose}>
          Done
        </button>
      }
    >
      <div className="prefs" aria-busy={!loaded}>
        {error && (
          <p className="prefs-error" role="status">
            {error}
          </p>
        )}

        <section className="pref-section">
          <h3 className="pref-section-title">Appearance</h3>

          <div className="pref-row">
            <div className="pref-text">
              <span className="pref-label" id={`${ids}-theme`}>
                Theme
              </span>
              <span className="pref-hint">System follows your desktop appearance.</span>
            </div>
            <div className="segmented" role="radiogroup" aria-labelledby={`${ids}-theme`}>
              {THEMES.map((option) => (
                <label key={option.id} className="segmented-option">
                  <input
                    type="radio"
                    name={`${ids}-theme-choice`}
                    value={option.id}
                    checked={preferences.theme === option.id}
                    disabled={!loaded}
                    onChange={() => chooseTheme(option.id)}
                  />
                  <span className="segmented-label">{option.label}</span>
                </label>
              ))}
            </div>
          </div>
        </section>

        <section className="pref-section">
          <h3 className="pref-section-title">Sessions</h3>

          <div className="pref-row">
            <div className="pref-text">
              <label className="pref-label" htmlFor={`${ids}-provider`}>
                Default agent
              </label>
              <span className="pref-hint">Used for new sessions unless a project overrides it.</span>
            </div>
            <span className="select-wrap">
              <select
                id={`${ids}-provider`}
                className="pref-select"
                value={preferences.defaultProvider}
                disabled={!loaded}
                onChange={(event) => {
                  const next = event.target.value
                  if (isProviderId(next)) save({ defaultProvider: next })
                }}
              >
                {PROVIDERS.map((provider) => (
                  <option key={provider.id} value={provider.id} disabled={!canPick(provider.id)}>
                    {provider.label}
                    {canPick(provider.id) ? '' : ' — not installed'}
                  </option>
                ))}
              </select>
            </span>
          </div>

          <div className="pref-row">
            <div className="pref-text">
              <span className="pref-label" id={`${ids}-restore`}>
                Restore sessions on launch
              </span>
              <span className="pref-hint" id={`${ids}-restore-hint`}>
                Reopen the projects and tabs that were up when you quit.
              </span>
            </div>
            <label className="switch">
              <input
                type="checkbox"
                role="switch"
                checked={preferences.restoreSessions}
                disabled={!loaded}
                aria-labelledby={`${ids}-restore`}
                aria-describedby={`${ids}-restore-hint`}
                onChange={(event) => save({ restoreSessions: event.target.checked })}
              />
              <span className="switch-track" aria-hidden="true">
                <span className="switch-thumb" />
              </span>
            </label>
          </div>
        </section>

        <section className="pref-section">
          <h3 className="pref-section-title">Notifications</h3>

          <div className="pref-row">
            <div className="pref-text">
              <span className="pref-label" id={`${ids}-notify`}>
                Notify when a session finishes
              </span>
              <span className="pref-hint" id={`${ids}-notify-hint`}>
                A desktop notification when an agent completes or needs you.
              </span>
            </div>
            <label className="switch">
              <input
                type="checkbox"
                role="switch"
                checked={preferences.notifyOnComplete}
                disabled={!loaded}
                aria-labelledby={`${ids}-notify`}
                aria-describedby={`${ids}-notify-hint`}
                onChange={(event) => save({ notifyOnComplete: event.target.checked })}
              />
              <span className="switch-track" aria-hidden="true">
                <span className="switch-thumb" />
              </span>
            </label>
          </div>
        </section>

        <section className="pref-section">
          <h3 className="pref-section-title">Shortcuts</h3>
          <ul className="shortcut-list">
            {SHORTCUTS.map((shortcut) => (
              <li key={shortcut.label} className="shortcut-row">
                <span className="shortcut-label">{shortcut.label}</span>
                <span className="shortcut-keys">
                  {shortcut.keys.map((key) => (
                    <kbd key={key}>{key === 'mod' ? modifier : key}</kbd>
                  ))}
                </span>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </Modal>
  )
}
