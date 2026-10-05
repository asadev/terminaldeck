/**
 * Settings, inside the native macOS window.
 *
 * In Electron, Settings is a sheet over the main window (`SettingsWindow`). In
 * the native window it is a window of its own: AppKit draws the window and its
 * list of sections, and the page inside it is this app's own `SettingsPanel`,
 * loaded from the same origin at {@link settingsPageUrl} and rendered by
 * `SettingsPage.tsx` with the web list of sections hidden.
 *
 * Messages to the native side (`macos/`):
 *   main page     → { type: 'open-settings', url, section }   instead of opening the sheet
 *   settings page → { type: 'settings-sections', sections: [{ id, title, symbol }], selected }
 * and from it, on the settings page: `window.tdNative.run('settings-section', id)`.
 *
 * The sheet's three hand-backs to the main window — a changed value, "sign this
 * account in" (which starts a session), and "set Hoot up again" — cannot be
 * callbacks across two pages, so they travel on a `BroadcastChannel` between
 * them ({@link openSettingsRelay}). Same origin, so it needs nothing from the
 * engine or from the native side.
 */

import type { ProviderId } from '../../shared/types'
import { isProviderId } from '../preferences'
import type { NativeHost } from '../../shared/native-shell'
import { openRelay, type ChannelLike, type Relay } from '../native-relay'
import { isSectionId } from './SettingsWindow'
import { resolveSection, type LiveSectionId, type SectionId, type SettingValues } from './settings-schema'

/* ---------------------------------------------------------------- the URL -- */

/** The query parameter `main.tsx` reads to render the Settings page instead of the app. */
export const SETTINGS_PAGE_PARAM = 'settings'

/**
 * Where the Settings page is: the renderer's own `index.html`, which the engine
 * serves at `/`, with `?settings=1`. Relative, so it is the same origin and
 * carries the same cookie as the window that asked.
 */
export function settingsPageUrl(section?: SectionId, intent?: SettingsIntent): string {
  const query = new URLSearchParams({ [SETTINGS_PAGE_PARAM]: '1' })
  if (section !== undefined) query.set('section', resolveSection(section))
  if (intent !== undefined) {
    query.set('action', intent.action)
    if (intent.provider) query.set('provider', intent.provider)
  }
  return `/?${query.toString()}`
}

/**
 * Settings opened to *do* something, not only to look: today, "Add account"
 * from a session's account chip, which in the sheet opens Accounts' own popup
 * (`askForAddAccount`). Carried on `open-settings` (and on the page's URL, for
 * a Settings window that is still the web page) so it is not lost between the
 * window that asked and the one that answers.
 */
export interface SettingsIntent {
  action: 'add-account'
  /** The agent the account is for, when the chip knew it. */
  provider?: ProviderId
}

/** The intent the URL carries, when it carries one this build knows. */
export function settingsIntentFromUrl(search: string): SettingsIntent | undefined {
  const query = new URLSearchParams(search)
  if (query.get('action') !== 'add-account') return undefined
  const provider = query.get('provider')
  return provider !== null && isProviderId(provider) ? { action: 'add-account', provider } : { action: 'add-account' }
}

/** True when this page load is the Settings page. */
export function isSettingsPage(search: string): boolean {
  return new URLSearchParams(search).get(SETTINGS_PAGE_PARAM) === '1'
}

/** The section the URL asks for, when it names a real one. */
export function settingsSectionFromUrl(search: string): SectionId | undefined {
  const wanted = new URLSearchParams(search).get('section')
  return isSectionId(wanted) ? wanted : undefined
}

/** What the main page posts in place of opening the sheet. */
export function openSettingsMessage(
  section: SectionId = 'general',
  intent?: SettingsIntent,
): {
  type: 'open-settings'
  url: string
  section: LiveSectionId
  action?: SettingsIntent['action']
  provider?: ProviderId
} {
  return {
    type: 'open-settings',
    url: settingsPageUrl(section, intent),
    section: resolveSection(section),
    ...(intent === undefined ? {} : { action: intent.action }),
    ...(intent?.provider ? { provider: intent.provider } : {}),
  }
}

/* ------------------------------------------------------------ the list -- */

/** Hoot's own section — titled with Hoot's name, `copilot` by id. */
export const HOOT_SECTION: LiveSectionId = 'copilot'

/** Each section's SF Symbol in the native list. Every live section has one. */
export const SECTION_SYMBOLS: Readonly<Record<LiveSectionId, string>> = {
  general: 'gearshape',
  appearance: 'paintpalette',
  notifications: 'bell',
  agents: 'cpu',
  features: 'wrench.and.screwdriver',
  linux: 'terminal',
  browser: 'globe',
  scraping: 'doc.text.magnifyingglass',
  copilot: 'bird',
  'ai-apps': 'link',
  tasks: 'checklist',
  plugins: 'puzzlepiece.extension',
  power: 'bolt',
  advanced: 'slider.horizontal.3',
  help: 'questionmark.circle',
}

export interface SettingsSectionsMessage {
  type: 'settings-sections'
  /** `kind: 'hoot'` on Hoot's own section, so the native list draws the owl there as the app does. */
  sections: Array<{ id: LiveSectionId; title: string; symbol: string; kind?: 'hoot' }>
  selected: LiveSectionId
}

/**
 * The list the web rail would draw — `SettingsPanel`'s own, already filtered to
 * this platform and to the installed features — and the selected one.
 */
export function settingsSectionsMessage(
  sections: ReadonlyArray<{ id: LiveSectionId; label: string }>,
  selected: LiveSectionId,
): SettingsSectionsMessage {
  return {
    type: 'settings-sections',
    sections: sections.map((section) => ({
      id: section.id,
      title: section.label,
      symbol: SECTION_SYMBOLS[section.id],
      ...(section.id === HOOT_SECTION ? { kind: 'hoot' as const } : {}),
    })),
    selected,
  }
}

/**
 * `window.tdNative` on the Settings page: one command, `settings-section`.
 * `select` answers whether that id is a section the page is showing.
 */
export function publishSettingsCommands(
  select: (id: string) => boolean,
  host: NativeHost = globalThis as NativeHost,
): () => void {
  const previous = host.tdNative
  const commands = {
    run(name: string, arg?: unknown): boolean {
      return name === 'settings-section' && typeof arg === 'string' ? select(arg) : false
    },
  }
  host.tdNative = commands
  return () => {
    if (host.tdNative === commands) host.tdNative = previous
  }
}

/* ----------------------------------------------------------- the relay -- */

export const SETTINGS_RELAY_CHANNEL = 'terminaldeck:native-settings'

/** The three things the sheet hands back to the main window, as messages. */
export type SettingsRelayMessage =
  | { type: 'changed'; values: SettingValues }
  | { type: 'start-session'; profileId: string; provider?: ProviderId }
  | { type: 'set-up-copilot' }

function isRelayMessage(value: unknown): value is SettingsRelayMessage {
  if (typeof value !== 'object' || value === null) return false
  const { type } = value as { type?: unknown }
  if (type === 'changed') return typeof (value as { values?: unknown }).values === 'object'
  if (type === 'start-session') return typeof (value as { profileId?: unknown }).profileId === 'string'
  return type === 'set-up-copilot'
}

/** One end of the channel between the Settings page and the main page. */
export function openSettingsRelay(open?: (name: string) => ChannelLike): Relay<SettingsRelayMessage> {
  return openRelay(SETTINGS_RELAY_CHANNEL, isRelayMessage, open)
}
