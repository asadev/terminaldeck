import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ComponentType,
  type KeyboardEvent,
} from 'react'
import { Modal } from '../components/Modal'
import { applyStoredTheme, applyTheme, isThemePreference } from '../theme'
import {
  mergeSettings,
  SECTIONS,
  splitPatch,
  stringSetting,
  valuesFromPreferences,
  type SectionId,
  type SettingValues,
} from './settings-schema'
import {
  errorText,
  resolveSettingsBridge,
  toStoredSettings,
  type SectionProps,
  type SettingsBridge,
} from './settings-bridge'
import { GeneralSection } from './sections/GeneralSection'
import { AppearanceSection } from './sections/AppearanceSection'
import { NotificationsSection } from './sections/NotificationsSection'
import { AgentsSection } from './sections/AgentsSection'
import { SetupSection } from './sections/SetupSection'
import { BrowserSection } from './sections/BrowserSection'
import { ShortcutsSection } from './sections/ShortcutsSection'
import { ProfilesSection } from './sections/ProfilesSection'
import { AdvancedSection } from './sections/AdvancedSection'
import { HelpSection } from './sections/HelpSection'
import { AboutSection } from './sections/AboutSection'
import './SettingsWindow.css'

/**
 * The settings window.
 *
 * A narrow list of sections on the left, one section on the right, and no OK
 * button: every change is written as it is made. That is the whole interaction
 * model, and it is why there is no draft state anywhere in this file — a value
 * on screen is a value on disk, so pressing Escape can never lose anything.
 *
 * ## Two stores, one surface
 *
 * Values arrive from two places (`prefs:get` and `settings:get`) and are merged
 * through the schema, which fills in defaults and keeps keys it does not know.
 * Writes go back the same way: `splitPatch` decides which file each key belongs
 * to. Sections never see any of this — they get `values` and `save`.
 *
 * ## Optimistic, and honest when it fails
 *
 * A toggle moves the moment it is clicked, because a disk round-trip is not
 * something a switch should wait for. If the write then fails, the footer says
 * so rather than silently reverting the control under the user's finger — the
 * value in front of them is what they chose, and the message tells them it may
 * not survive a restart.
 */

const SECTION_VIEWS: Record<SectionId, ComponentType<SectionProps>> = {
  general: GeneralSection,
  appearance: AppearanceSection,
  notifications: NotificationsSection,
  agents: AgentsSection,
  setup: SetupSection,
  browser: BrowserSection,
  shortcuts: ShortcutsSection,
  profiles: ProfilesSection,
  advanced: AdvancedSection,
  // Takes no props: it renders the shared HelpPanel, which reads its own bridge.
  help: HelpSection,
  about: AboutSection,
}

function isSectionId(value: unknown): value is SectionId {
  return SECTIONS.some((section) => section.id === value)
}

/**
 * Density is an attribute on the root element, the same mechanism `theme.ts`
 * uses — one write, and any stylesheet can answer to it.
 */
function applyDensity(values: SettingValues): void {
  if (typeof document === 'undefined') return
  document.documentElement.dataset.density = stringSetting(values, 'appearance.density')
}

export type SaveState =
  | { kind: 'idle' }
  | { kind: 'saving' }
  | { kind: 'saved' }
  | { kind: 'error'; message: string }

/**
 * How long the window waits for the stored values before giving up on them.
 *
 * Generous: this is a local file read behind one IPC hop, so anything close to
 * this is already a bug somewhere else. It exists to bound the wait, not to
 * race it.
 */
export const LOAD_TIMEOUT_MS = 8000

export interface SettingsPanelProps {
  bridge?: SettingsBridge
  initialSection?: SectionId
  /** Fired after every accepted write, so the app can react to a changed value. */
  onChange?(values: SettingValues): void
  /** Rendered in the footer by the window; exposed so the panel can drive it. */
  onSaveState?(state: SaveState): void
}

/**
 * The dialog's contents, without the dialog.
 *
 * Split out for the same reason `ShortcutsList` is: `Modal` portals into
 * `document.body`, and this project's tests run with no document at all.
 */
export function SettingsPanel({
  bridge: injected,
  initialSection = 'general',
  onChange,
  onSaveState,
}: SettingsPanelProps) {
  const bridge = useMemo(() => injected ?? resolveSettingsBridge(), [injected])
  const [section, setSection] = useState<SectionId>(initialSection)
  const [values, setValues] = useState<SettingValues>(() => mergeSettings({}))
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  // Reads of the current values from inside a callback, without making every
  // callback depend on them — a save handler that changed identity on every
  // keystroke would remount the control it is attached to.
  const latest = useRef(values)
  latest.current = values

  const navRef = useRef<HTMLDivElement>(null)
  const ids = useId()

  /**
   * Which load is the current one.
   *
   * Two reads can be in flight at once — Advanced reloads straight after a
   * reset, and the reset is what changed the values — and IPC replies are not
   * ordered against each other. Without this, the older answer can land last
   * and put the pre-reset values back on screen.
   */
  const loadId = useRef(0)
  const loadTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const load = useCallback(() => {
    const generation = (loadId.current += 1)
    setLoading(true)
    setLoadError(null)

    const prefs = bridge.getPreferences?.() ?? Promise.resolve(null)
    const extra = bridge.getSettings?.() ?? Promise.resolve(null)

    // Every control is disabled while loading, so a handler that never replies
    // is a settings window nobody can use and that says nothing about why.
    // A promise that does not settle is not a state this can sit in.
    if (loadTimer.current !== null) clearTimeout(loadTimer.current)
    loadTimer.current = setTimeout(() => {
      if (loadId.current !== generation) return
      setLoadError('Your saved settings are taking too long to read — showing defaults for now.')
      setLoading(false)
    }, LOAD_TIMEOUT_MS)

    const settle = (): boolean => {
      if (loadId.current !== generation) return false
      if (loadTimer.current !== null) {
        clearTimeout(loadTimer.current)
        loadTimer.current = null
      }
      return true
    }

    void Promise.all([prefs, extra]).then(
      ([prefsRaw, extraRaw]) => {
        if (!settle()) return
        // Preferences win for the four keys they own: store.ts is what the main
        // process reads at spawn and at launch, so it is the truth for those.
        const merged = mergeSettings({
          ...toStoredSettings(extraRaw),
          ...valuesFromPreferences(prefsRaw),
        })
        latest.current = merged
        setValues(merged)
        setLoading(false)
        setLoadError(null)
        // Paint what is actually stored. If anything has drifted — a failed
        // save, the hardcoded attribute index.html ships for first paint — the
        // control and the window would otherwise disagree about the theme.
        applyStoredTheme(merged['appearance.theme'])
        applyDensity(merged)
      },
      (cause: unknown) => {
        if (!settle()) return
        setLoadError(errorText(cause, 'Could not read your saved settings — showing defaults.'))
        setLoading(false)
      },
    )
  }, [bridge])

  useEffect(load, [load])

  // The timer outlives the window otherwise, and fires setState into a tree
  // that is no longer mounted.
  useEffect(
    () => () => {
      loadId.current += 1
      if (loadTimer.current !== null) clearTimeout(loadTimer.current)
    },
    [],
  )

  const save = useCallback(
    (patch: Record<string, unknown>) => {
      const next = mergeSettings({ ...latest.current, ...patch })
      latest.current = next
      setValues(next)

      const { prefs, extra } = splitPatch(patch)
      const prefsRecord = prefs as Record<string, unknown>

      // Repaint before persisting: the disk round-trip should never be visible
      // as a lag between clicking a theme and seeing it.
      if (isThemePreference(prefsRecord.theme)) applyTheme(prefsRecord.theme)
      if ('appearance.density' in extra) applyDensity(next)

      const jobs: Array<Promise<unknown>> = []
      const missing: string[] = []

      if (Object.keys(prefsRecord).length > 0) {
        if (bridge.setPreferences) jobs.push(bridge.setPreferences(prefsRecord))
        else missing.push('preferences')
      }
      if (Object.keys(extra).length > 0) {
        if (bridge.setSettings) jobs.push(bridge.setSettings(extra))
        else missing.push('settings')
      }

      if (missing.length > 0) {
        onSaveState?.({
          kind: 'error',
          message: `This build cannot save ${missing.join(' or ')} yet — the change applies now but will not survive a restart.`,
        })
        return
      }
      if (jobs.length === 0) return

      onSaveState?.({ kind: 'saving' })
      void Promise.all(jobs).then(
        () => {
          onSaveState?.({ kind: 'saved' })
          onChange?.(next)
        },
        (cause: unknown) => {
          onSaveState?.({
            kind: 'error',
            message: errorText(cause, 'Could not save that change — it may not survive a restart.'),
          })
        },
      )
    },
    [bridge, onChange, onSaveState],
  )

  const goTo = useCallback((next: string) => {
    if (isSectionId(next)) setSection(next)
  }, [])

  /**
   * Arrow keys move between sections, which is what a vertical tab list is
   * expected to do. Focus follows the selection so the panel that appears is
   * the one a screen reader announces.
   */
  const onNavKeyDown = useCallback(
    (event: KeyboardEvent<HTMLDivElement>) => {
      const keys = ['ArrowDown', 'ArrowUp', 'Home', 'End']
      if (!keys.includes(event.key)) return
      event.preventDefault()

      const index = SECTIONS.findIndex((entry) => entry.id === section)
      const last = SECTIONS.length - 1
      const nextIndex =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? last
            : event.key === 'ArrowDown'
              ? (index + 1) % SECTIONS.length
              : (index - 1 + SECTIONS.length) % SECTIONS.length

      const target = SECTIONS[nextIndex]
      setSection(target.id)
      navRef.current
        ?.querySelector<HTMLButtonElement>(`[data-section="${target.id}"]`)
        ?.focus()
    },
    [section],
  )

  const View = SECTION_VIEWS[section]

  return (
    <div className="settings" data-loading={loading || undefined}>
      <div
        className="settings-nav"
        role="tablist"
        aria-orientation="vertical"
        aria-label="Settings sections"
        ref={navRef}
        onKeyDown={onNavKeyDown}
      >
        {SECTIONS.map((entry) => {
          const selected = entry.id === section
          return (
            <button
              key={entry.id}
              type="button"
              role="tab"
              id={`${ids}-tab-${entry.id}`}
              data-section={entry.id}
              className="settings-nav-item"
              aria-selected={selected}
              // Only one panel is in the tree at a time, so only the selected
              // tab can honestly point at one. The other eight used to name an
              // id that does not exist, which a screen reader follows to
              // nothing.
              aria-controls={selected ? `${ids}-panel-${entry.id}` : undefined}
              // One stop in the tab order for the whole list; the arrow keys
              // move within it. Tabbing lands on the selected section, not on
              // the first of nine.
              tabIndex={selected ? 0 : -1}
              onClick={() => setSection(entry.id)}
            >
              {entry.label}
            </button>
          )
        })}
      </div>

      <div
        className="settings-panel"
        role="tabpanel"
        id={`${ids}-panel-${section}`}
        aria-labelledby={`${ids}-tab-${section}`}
        tabIndex={-1}
        aria-busy={loading || undefined}
      >
        {loadError && (
          <p className="settings-notice" data-tone="error" role="status">
            {loadError}
          </p>
        )}
        <View
          values={values}
          save={save}
          bridge={bridge}
          loading={loading}
          goTo={goTo}
          reload={load}
        />
      </div>
    </div>
  )
}

export interface SettingsWindowProps extends SettingsPanelProps {
  open: boolean
  onClose(): void
}

const STATUS_TEXT: Record<SaveState['kind'], string> = {
  idle: 'Changes save as you make them.',
  saving: 'Saving…',
  saved: 'Saved.',
  error: '',
}

export function SettingsWindow({ open, onClose, ...panel }: SettingsWindowProps) {
  const [state, setState] = useState<SaveState>({ kind: 'idle' })

  // "Saved" is an acknowledgement, not a state — it should fade back to the
  // standing explanation rather than sit there implying the last click is
  // still special. An error stays until the next write.
  useEffect(() => {
    if (state.kind !== 'saved') return
    const timer = window.setTimeout(() => setState({ kind: 'idle' }), 1600)
    return () => window.clearTimeout(timer)
  }, [state])

  // Nothing is in flight when the window is shut, and a stale error greeting
  // the next visit would describe a change from another session.
  useEffect(() => {
    if (!open) setState({ kind: 'idle' })
  }, [open])

  return (
    <Modal
      open={open}
      title="Settings"
      description="Applies to every project and session."
      onClose={onClose}
      size="lg"
      footer={
        <>
          <span
            className="settings-status"
            data-tone={state.kind === 'error' ? 'error' : 'quiet'}
            role="status"
            aria-live="polite"
          >
            {state.kind === 'error' ? state.message : STATUS_TEXT[state.kind]}
          </span>
          <button type="button" className="modal-btn primary" onClick={onClose}>
            Done
          </button>
        </>
      }
    >
      <SettingsPanel {...panel} onSaveState={setState} />
    </Modal>
  )
}
