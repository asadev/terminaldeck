import { useCallback, useEffect, useRef, useState } from 'react'
import { postToNative } from '../../shared/native-shell'
import { publishNativeAppearance } from '../native-appearance'
import { FeaturesProvider } from '../features/FeaturesProvider'
import { resolveSection, type LiveSectionId, type Section, type SectionId } from './settings-schema'
import { askForAddAccount } from '../accounts'
import { isSectionId, SettingsPanel, STATUS_TEXT, type SaveState } from './SettingsWindow'
import { RailFooter } from './RailFooter'
import { ShortcutsPopover } from './ShortcutsPopover'
import {
  openSettingsRelay,
  publishSettingsCommands,
  settingsSectionsMessage,
  type SettingsIntent,
  type SettingsRelayMessage,
} from './native-settings'
import './SettingsPage.css'

/**
 * Settings as a page of its own — what the native macOS window's Settings
 * window loads (`/?settings=1`, see `native-settings.ts`).
 *
 * The same `SettingsPanel` the sheet holds, so every section is the same
 * component either way. What differs is only what a window around it does:
 *
 *  - the list of sections is drawn natively, so the web one is hidden
 *    (`SettingsWindow.css`) and the list is posted to the native side instead,
 *    which selects through `window.tdNative.run('settings-section', id)`;
 *  - there is no Done button — the native window has its own close — and the
 *    save status sits at the foot of the page where the sheet's footer had it,
 *    beside the Shortcuts button that sat at the foot of the web list;
 *  - the three things the sheet hands to the main window go there over the
 *    settings relay, and the main window does with them exactly what it does
 *    for the sheet.
 */
export function SettingsPage({ initialSection, intent }: { initialSection?: SectionId; intent?: SettingsIntent }) {
  // Opened to add an account: asked for before the first render's effects, so
  // Accounts finds the request waiting when it mounts — as it does in the sheet.
  useState(() => {
    if (intent?.action === 'add-account') askForAddAccount(intent.provider ?? null)
  })
  // Opened once mounted rather than while rendering, so nothing renders a channel open.
  const relay = useRef<ReturnType<typeof openSettingsRelay> | null>(null)
  useEffect(() => {
    const opened = openSettingsRelay()
    relay.current = opened
    return () => {
      opened.close()
      relay.current = null
    }
  }, [])
  const handBack = (message: SettingsRelayMessage): void => relay.current?.post(message)

  const [state, setState] = useState<SaveState>({ kind: 'idle' })
  // The rail's one button that is not a section — Shortcuts — lives on in the
  // page's foot, since the rail it sat at the bottom of is drawn natively.
  const [shortcuts, setShortcuts] = useState(false)
  useEffect(() => {
    if (state.kind !== 'saved') return
    const timer = window.setTimeout(() => setState({ kind: 'idle' }), 1600)
    return () => window.clearTimeout(timer)
  }, [state])

  // The native Settings window's chrome follows the theme picked here.
  useEffect(() => publishNativeAppearance(), [])

  const nav = useRef<{ sections: readonly Section[]; select(id: string): void } | null>(null)
  const onSections = useCallback(
    (sections: readonly Section[], selected: LiveSectionId, select: (id: string) => void) => {
      nav.current = { sections, select }
      postToNative(settingsSectionsMessage(sections, selected))
    },
    [],
  )
  useEffect(
    () =>
      publishSettingsCommands((id) => {
        const current = nav.current
        if (current === null || !isSectionId(id)) return false
        const live = resolveSection(id)
        if (!current.sections.some((section) => section.id === live)) return false
        current.select(live)
        return true
      }),
    [],
  )

  return (
    <FeaturesProvider>
      <div className="settings-page">
        {shortcuts && <ShortcutsPopover onClose={() => setShortcuts(false)} />}
        <SettingsPanel
          initialSection={initialSection}
          onSections={onSections}
          onSaveState={setState}
          onChange={(values) => handBack({ type: 'changed', values })}
          onStartSession={({ profileId, provider }) =>
            handBack({ type: 'start-session', profileId, ...(provider === undefined ? {} : { provider }) })
          }
          onSetUpCopilot={() => handBack({ type: 'set-up-copilot' })}
        />
        <footer className="settings-page-foot">
          <span
            className="settings-status"
            data-tone={state.kind === 'error' ? 'error' : 'quiet'}
            role="status"
            aria-live="polite"
          >
            {state.kind === 'error' ? state.message : STATUS_TEXT[state.kind]}
          </span>
          <RailFooter onShortcuts={() => setShortcuts(true)} />
        </footer>
      </div>
    </FeaturesProvider>
  )
}
