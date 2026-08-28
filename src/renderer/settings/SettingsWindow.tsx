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
import type { ProviderId } from '@shared/types'
import { Modal } from '../components/Modal'
import { applyStoredTheme, applyTheme, isThemePreference } from '../theme'
import {
  mergeSettings,
  MERGED_SECTIONS,
  resolveSection,
  SECTIONS,
  sectionsFor,
  splitPatch,
  stringSetting,
  valuesFromPreferences,
  type LiveSectionId,
  type SectionId,
  type SettingValues,
} from './settings-schema'
import { detectPlatform, type UiPlatform } from '../platform'
import {
  errorText,
  resolveSettingsBridge,
  toStoredSettings,
  type SectionProps,
  type SettingsBridge,
} from './settings-bridge'
import { useFeatures } from '../features/FeaturesProvider'
import { GeneralSection } from './sections/GeneralSection'
import { ToolsSection } from './sections/ToolsSection'
import { AppearanceSection } from './sections/AppearanceSection'
import { NotificationsSection } from './sections/NotificationsSection'
import { AgentsSection } from './sections/AgentsSection'
import { BrowserSection } from './sections/BrowserSection'
import { ScrapingSection } from './sections/ScrapingSection'
import { PowerSection } from './sections/PowerSection'
import { AdvancedSection } from './sections/AdvancedSection'
import { LinuxSection } from './sections/LinuxSection'
import { CopilotSection } from './sections/CopilotSection'
import { HelpSection } from './sections/HelpSection'
import { ShortcutsPopover } from './ShortcutsPopover'
import { RailFooter } from './RailFooter'
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

/** Takes no settings props: it reads its own bridge off `window.deck`. */

/**
 * Wrapped for the same reason, and it is the same argument as `RemoteSection`'s:
 * Power's switch is bound to a *system* setting read back from the OS on every
 * change, so it holds none of this window's `values` and writes through none of
 * its `save`. It resolves its own three channels; casting it into `SectionProps`
 * would hand it the settings bridge as its own and it would decide the feature
 * was missing from the build.
 */
const PowerSectionView: ComponentType<SectionProps> = () => <PowerSection />

/**
 * Wrapped for the same reason again: it reads its own two channels off
 * `window.deck` and holds none of this window's values. It is also the only
 * section in the rail on one platform and absent on the others — see
 * `sectionsFor`.
 */
const LinuxSectionView: ComponentType<SectionProps> = () => <LinuxSection />

/*
 * There is no `ServerControlView` here any more.
 *
 * A server's settings were a rail entry once — a full mirror of the server's own
 * page inside this window. Asad consolidated it away: server management now lives
 * in exactly one place, the server's own page in the Machines panel, so this
 * window no longer draws a second copy of it. See the note where `servers` used
 * to be in `settings-schema.ts`.
 */

/**
 * Wrapped for the third time, and for the strongest version of the reason.
 *
 * The Copilot pane stores nothing at all. Every one of its channels reads a
 * folder, a log or a list of automations off `window.deck`, so handing it this
 * window's `values` and `save` would give it a settings bridge as its own
 * `bridge` — and it would conclude that none of its capabilities exist in this
 * build while every method was sitting on the preload. That is exactly the
 * mistake `RemoteSection` shipped once, and the note above `PowerSectionView`
 * is the record of it.
 */
/**
 * Wrapped for the fourth time, and for the same reason as the three above: this
 * pane holds none of this window's values and resolves its own three bridges —
 * the scraping seams, the browser's profiles and the downloads view — off
 * `window.deck`. Handing it `SectionProps.bridge` would give it the settings
 * bridge as its own and it would draw the whole subject as missing from this
 * build while every method sat on the preload.
 */
const ScrapingSectionView: ComponentType<SectionProps> = () => <ScrapingSection />

const CopilotSectionView: ComponentType<SectionProps> = ({ setUpCopilot }) => (
  // One prop, and it is a capability of the *window* rather than a setting —
  // see `SectionProps.setUpCopilot` for why the setup flow cannot open from
  // inside this sheet.
  <CopilotSection {...(setUpCopilot ? { setUpCopilot } : {})} />
)

/**
 * One view per pane — and there are four fewer panes than there were views.
 *
 * Accounts and Setup are groups inside `AgentsSection`, About is the masthead at
 * the top of `HelpSection`, and Shortcuts is a popover off the rail's footer, so
 * none of the four has an entry here. Every id that used to name one of them
 * still resolves, through `MERGED_SECTIONS`, to the pane its contents went to —
 * which is why this map is keyed on `LiveSectionId` and the props are still
 * typed `SectionId`.
 */
const SECTION_VIEWS: Record<LiveSectionId, ComponentType<SectionProps>> = {
  general: GeneralSection,
  appearance: AppearanceSection,
  notifications: NotificationsSection,
  // The rail calls it "Coding AI" — it was "Agents", then "Assistants", both
  // rejected on review; the id and the file have not moved once through either
  // rename, for the reason the schema gives beside that entry. Accounts and
  // Setup are assembled into it — see the note in `AgentsSection.tsx`.
  agents: AgentsSection,
  // The id is `features` and the label is "Tools": `App.tsx` names this id and
  // is a file no agent may edit while others are working here.
  features: ToolsSection,
  linux: LinuxSectionView,
  browser: BrowserSection,
  // The browser's harvesting half, and the same `ScrapingBody` its three-dot
  // panel draws — one component, so the two surfaces cannot come to disagree
  // about what a control does. See `ScrapingSectionView`.
  scraping: ScrapingSectionView,
  // Reads only, and resolves its own bridge. See `CopilotSectionView`.
  copilot: CopilotSectionView,
  // Wrapped, not cast. `SectionProps` carries its own `bridge` — the settings
  // bridge — and casting RemoteSection to this type handed it that object as
  // its `bridge` prop, so it decided remote access was "not wired into this
  // build" while every method was sitting on window.deck. RemoteSection
  // resolves its own bridge; it wants none of these props.
  power: PowerSectionView,
  advanced: AdvancedSection,
  // Help is a page again, and About is the first block on it. `AboutSection` is
  // still its own component and is still what `openSettings('about')` reaches.
  help: HelpSection,
}

/**
 * Anything that has ever named a section, including the four that merged.
 *
 * `goTo` takes a string off a button handler, and a link written before the
 * merge must still land somewhere real rather than being silently ignored —
 * which is what a check against the live rail alone would do.
 */
function isSectionId(value: unknown): value is SectionId {
  if (typeof value !== 'string') return false
  if (SECTIONS.some((section) => section.id === value)) return true
  return Object.prototype.hasOwnProperty.call(MERGED_SECTIONS, value)
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
  /**
   * Which platform's rail to draw.
   *
   * A parameter rather than a read, for the reason `src/main/platform/host.ts`
   * gives at length: one section exists only on Windows, and a branch that can
   * only be exercised on the machine it was written on is a branch whose first
   * reader is a user. Production passes nothing and gets this window's own.
   */
  platform?: UiPlatform
  initialSection?: SectionId
  /**
   * Start a session and close this window.
   *
   * Only Accounts uses it, and only for Sign in: the agent's login runs inside
   * a terminal, so signing an account in *is* opening a session under it. The
   * window owns the session store, which is why this comes down as a prop
   * rather than the pane calling `session:create` behind its back and leaving a
   * running process with no tab.
   */
  onStartSession?(request: { profileId: string; provider?: ProviderId }): void
  /**
   * Run the copilot's setup questions again, and close this window.
   *
   * The same shape as {@link SettingsPanelProps.onStartSession} and for the same
   * reason: the flow is a dialog the *app window* owns. Opening it from inside
   * this sheet would put one dialog over another, where a single Escape reaches
   * both handlers and takes the sheet away with the flow. So the pane asks, the
   * app answers, and the questions arrive over the workspace their answers
   * change.
   */
  onSetUpCopilot?(): void
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
  platform = detectPlatform(),
  initialSection = 'general',
  onStartSession,
  onSetUpCopilot,
  onChange,
  onSaveState,
}: SettingsPanelProps) {
  const bridge = useMemo(() => injected ?? resolveSettingsBridge(), [injected])
  const features = useFeatures()
  /*
   * The rail for this machine, and for the features it has.
   *
   * A section that exists nowhere on this platform is not drawn disabled — it is
   * not drawn — and the same is now true of a section belonging to an
   * uninstalled feature. Leaving "Browser" in the rail with the browser
   * uninstalled would be a settings pane for something the window does not have,
   * which is the dead control the design brief forbids, wearing a different hat.
   */
  const sections = useMemo(
    () => sectionsFor(platform).filter((entry) => features.sectionOn(entry.id)),
    [platform, features],
  )
  /*
   * Resolved through the merge table on the way in.
   *
   * `App.tsx` opens this window at `setup` from the application menu and at
   * `profiles` from the account chip inside a session, and neither of those is
   * a pane any more — both are groups inside Agents. Landing on General because
   * the requested id is not in the rail would be a menu item that appears to do
   * nothing, which is worse than the reorganisation it came from.
   */
  const [chosen, setSection] = useState<LiveSectionId>(() => {
    const wanted = resolveSection(initialSection)
    // A section can also be asked for that this platform does not have — a deep
    // link, or a remembered choice from a machine that did have it. Landing on
    // an empty pane with no rail entry selected is worse than landing on
    // General.
    return sections.some((entry) => entry.id === wanted) ? wanted : sections[0].id
  })
  /*
   * What is actually on screen.
   *
   * The rail can lose the selected entry while the window is open: uninstalling
   * the browser from Features takes the Browser section with it, and the pane
   * behind it was still rendering, with nothing in the rail selected. Resolved
   * on render rather than repaired in an effect, because the wrong pane must
   * never be shown for even one frame.
   */
  const section = sections.some((entry) => entry.id === chosen) ? chosen : sections[0].id
  const [values, setValues] = useState<SettingValues>(() => mergeSettings({}))
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  /** The shortcut reference, which is a popover now rather than a pane. */
  const [shortcuts, setShortcuts] = useState(false)

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

  /**
   * Somebody else changed a stored value while this window was open.
   *
   * The copilot can write settings and preferences, with a confirmation, and so
   * can a paired device behind it. Without this the app would repaint — the
   * theme, the density, everything keyed off a setting — while the dialog that
   * exists to *show* those values went on displaying what it read when it
   * opened. Somebody watching their app turn light while the Appearance picker
   * still said Dark would reasonably conclude the picker is broken.
   *
   * A re-read rather than a merge of the pushed values, deliberately: `load`
   * already resolves the two stores against each other, guards against an older
   * reply landing last, and repaints the theme and the density from what is
   * actually stored. A second path that merged a payload would be a second
   * answer to the same question, and this window has had that bug before.
   *
   * Guarded with `?.` because the bridge is `Partial` by house rule — a build
   * without these channels loses the live update and keeps the window.
   */
  useEffect(() => {
    const offPrefs = bridge.onPreferencesChanged?.(() => load())
    const offSettings = bridge.onSettingsChanged?.(() => load())
    return () => {
      offPrefs?.()
      offSettings?.()
    }
  }, [bridge, load])

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
    if (isSectionId(next)) setSection(resolveSection(next))
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

      const index = sections.findIndex((entry) => entry.id === section)
      const last = sections.length - 1
      const nextIndex =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? last
            : event.key === 'ArrowDown'
              ? (index + 1) % sections.length
              : (index - 1 + sections.length) % sections.length

      const target = sections[nextIndex]
      setSection(target.id)
      navRef.current
        ?.querySelector<HTMLButtonElement>(`[data-section="${target.id}"]`)
        ?.focus()
    },
    [section, sections],
  )

  const View = SECTION_VIEWS[section]

  return (
    <div className="settings" data-loading={loading || undefined}>
      {shortcuts && <ShortcutsPopover onClose={() => setShortcuts(false)} />}
      <div className="settings-rail">
      <div
        className="settings-nav"
        role="tablist"
        aria-orientation="vertical"
        aria-label="Settings sections"
        ref={navRef}
        onKeyDown={onNavKeyDown}
      >
        {sections.map((entry) => {
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

      {/*
        One icon where a rail entry used to be.

        Shortcuts was the longest pane in the window and is a thing you look at
        rather than a thing you change, which is the line this rail draws. Help
        was the second icon here and is a pane again — see `RailFooter`.

        Deliberately a sibling of the tablist rather than one of its children.
        The list handles Arrow, Home and End to move between tabs, and a button
        that is not a tab sitting inside it would either be skipped by those
        keys or — worse — change the selected pane under somebody who was
        reaching for the shortcut list.
      */}
      <RailFooter onShortcuts={() => setShortcuts(true)} />
      </div>

      <div
        /*
         * Keyed on the section, so switching tabs mounts a fresh pane.
         *
         * Without it the scroll position is the *element's*, not the section's:
         * scrolling Browser down to its cookie list and then clicking Help
         * opened Help 240px down, in the middle of a sentence. A page keyed on
         * what it is showing starts where a page starts.
         */
        key={section}
        className="settings-panel scroll-fade"
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
          // Absent when the host did not pass one, which is what makes the Sign
          // in button disappear rather than sit there doing nothing.
          {...(onStartSession ? { startSession: onStartSession } : {})}
          // Same rule for the copilot's setup questions: no host, no button.
          {...(onSetUpCopilot ? { setUpCopilot: onSetUpCopilot } : {})}
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
      /*
       * No description, deliberately.
       *
       * The header stack said the same thing three times before any content:
       * "Settings / Applies to every project and session.", then the rail's
       * selected item, then the panel's own heading and blurb. Two of those are
       * the platform idiom — System Settings has a selected row in the sidebar
       * and a title on the pane, and this window's section blurbs are where the
       * "bright title, dim description" treatment actually earns its keep. The
       * third was this line, which explains what a settings window is.
       */
      onClose={onClose}
      /*
       * A large sheet, not the whole window.
       *
       * It used to be `page`: edge to edge, no scrim, no corners. Twelve
       * sections do need room, but taking the window away to give it to them
       * turned "change a setting" into "leave what you were doing" — and the
       * thing this window is *for* is a change you make in the middle of
       * something else. The rail is inside the sheet now, so picking a section
       * happens within the dialog, and closing it puts the workspace back
       * because the workspace never went anywhere.
       */
      size="xl"
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
