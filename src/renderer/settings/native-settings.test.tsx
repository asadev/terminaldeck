import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { NATIVE_MESSAGE_HANDLER, type NativeHost } from '../../shared/native-shell'
import {
  SECTION_SYMBOLS,
  SETTINGS_RELAY_CHANNEL,
  isSettingsPage,
  openSettingsMessage,
  openSettingsRelay,
  publishSettingsCommands,
  settingsPageUrl,
  settingsSectionFromUrl,
  settingsSectionsMessage,
  type SettingsRelayMessage,
} from './native-settings'
import { SettingsPage } from './SettingsPage'
import { takeAddAccountRequest } from '../accounts'
import { settingsIntentFromUrl } from './native-settings'
import { SECTIONS, sectionsFor } from './settings-schema'

/**
 * Settings in the native macOS window: the URL its window loads, the list of
 * sections it draws, the one command it sends back, and the channel that hands
 * the sheet's three callbacks to the main window.
 */

const read = (path: string): string => readFileSync(join(__dirname, path), 'utf8')

describe('the URL', () => {
  it('is the renderer’s own page on the same origin, with ?settings=1 and the section', () => {
    expect(settingsPageUrl()).toBe('/?settings=1')
    expect(settingsPageUrl('agents')).toBe('/?settings=1&section=agents')
    // A merged section is sent as the live one it became.
    expect(settingsPageUrl('setup')).toBe('/?settings=1&section=agents')
    expect(settingsPageUrl('about')).toBe('/?settings=1&section=help')
  })

  it('is read back by the page', () => {
    expect(isSettingsPage('?settings=1&section=agents')).toBe(true)
    expect(isSettingsPage('?popout=abc')).toBe(false)
    expect(settingsSectionFromUrl('?settings=1&section=appearance')).toBe('appearance')
    expect(settingsSectionFromUrl('?settings=1&section=nonsense')).toBeUndefined()
    expect(settingsSectionFromUrl('?settings=1')).toBeUndefined()
  })

  it('is what the main window posts instead of opening the sheet', () => {
    expect(openSettingsMessage()).toEqual({ type: 'open-settings', url: '/?settings=1&section=general', section: 'general' })
    expect(openSettingsMessage('setup')).toEqual({ type: 'open-settings', url: '/?settings=1&section=agents', section: 'agents' })
  })

  it('renders the Settings page, and only that, from main.tsx', () => {
    const main = read('../main.tsx')
    expect(main).toContain('const settingsPage = isSettingsPage(location.search)')
    expect(main).toContain('initialSection={settingsSectionFromUrl(location.search)}')
    expect(main).toContain('intent={settingsIntentFromUrl(location.search)}')
  })
})

describe('Settings opened to do something', () => {
  it('carries "Add account" — and the agent, when known — on the message and the URL', () => {
    expect(openSettingsMessage('profiles', { action: 'add-account' })).toEqual({
      type: 'open-settings',
      url: '/?settings=1&section=agents&action=add-account',
      section: 'agents',
      action: 'add-account',
    })
    expect(openSettingsMessage('profiles', { action: 'add-account', provider: 'codex' })).toEqual({
      type: 'open-settings',
      url: '/?settings=1&section=agents&action=add-account&provider=codex',
      section: 'agents',
      action: 'add-account',
      provider: 'codex',
    })
    expect(settingsIntentFromUrl('?settings=1&section=agents&action=add-account&provider=codex')).toEqual({
      action: 'add-account',
      provider: 'codex',
    })
    expect(settingsIntentFromUrl('?settings=1&action=add-account&provider=nonsense')).toEqual({ action: 'add-account' })
    expect(settingsIntentFromUrl('?settings=1&action=delete-everything')).toBeUndefined()
  })

  it('is taken from the request the account chip leaves, when the main window opens Settings', () => {
    const app = read('../App.tsx')
    const open = app.slice(app.indexOf('const openSettings = useCallback('), app.indexOf('setPrefsOpen(true)'))
    expect(open).toContain('const adding = takeAddAccountRequest()')
    expect(open).toContain("adding === undefined ? undefined : { action: 'add-account'")
    // The chip leaves that request and then opens Settings — the path this carries.
    const chip = read('../shell/AccountChip.tsx')
    expect(chip).toMatch(/askForAddAccount\(\)\s*onManage\(\)/)
  })

  it('opens Accounts\u2019 own popup in a Settings page that is still the web one', () => {
    takeAddAccountRequest()
    renderToStaticMarkup(<SettingsPage initialSection="agents" intent={{ action: 'add-account', provider: 'gemini' }} />)
    expect(takeAddAccountRequest()).toBe('gemini')
    renderToStaticMarkup(<SettingsPage initialSection="agents" />)
    expect(takeAddAccountRequest()).toBeUndefined()
  })
})

describe('the list of sections', () => {
  it('has a symbol for every section', () => {
    for (const section of SECTIONS) expect(SECTION_SYMBOLS[section.id], section.id).toMatch(/^[a-z0-9.]+$/)
  })

  it('is the list the web rail draws, with titles, symbols and the selected one', () => {
    const sections = sectionsFor('mac')
    const message = settingsSectionsMessage(sections, 'appearance')
    expect(message.type).toBe('settings-sections')
    expect(message.selected).toBe('appearance')
    expect(message.sections.map((entry) => entry.id)).toEqual(sections.map((entry) => entry.id))
    expect(message.sections[0]).toEqual({ id: 'general', title: 'General', symbol: 'gearshape' })
    // Hoot's section keeps its id and is marked, so the native list draws the owl.
    expect(message.sections.find((entry) => entry.id === 'copilot')).toEqual({
      id: 'copilot',
      title: 'Hoot',
      symbol: 'bird',
      kind: 'hoot',
    })
    expect(message.sections.filter((entry) => entry.kind === 'hoot')).toHaveLength(1)
    // The Linux pane is the Windows rail's only.
    expect(message.sections.some((entry) => entry.id === 'linux')).toBe(false)
  })

  it('is posted by the panel whenever it changes, and the panel selects through the same `goTo` its panes use', () => {
    const panel = read('SettingsWindow.tsx')
    expect(panel).toContain('onSections?.(sections, section, goTo)')
    expect(panel).toContain('[onSections, sections, section, goTo]')
    const page = read('SettingsPage.tsx')
    expect(page).toContain('postToNative(settingsSectionsMessage(sections, selected))')
  })
})

describe('the settings-section command', () => {
  function host() {
    const target: NativeHost = {
      document: { documentElement: { dataset: { shell: 'native' } } },
      webkit: { messageHandlers: { [NATIVE_MESSAGE_HANDLER]: { postMessage: () => {} } } },
    }
    return target
  }

  it('selects through the page and says whether it could', () => {
    const target = host()
    const chosen: string[] = []
    const cleanup = publishSettingsCommands((id) => {
      chosen.push(id)
      return id === 'appearance'
    }, target)
    const commands = target.tdNative as { run(name: string, arg?: unknown): boolean }
    expect(commands.run('settings-section', 'appearance')).toBe(true)
    expect(commands.run('settings-section', 'nonsense')).toBe(false)
    expect(chosen).toEqual(['appearance', 'nonsense'])
    cleanup()
  })

  it('answers no to any other name, or to a missing id', () => {
    const target = host()
    const chosen: string[] = []
    publishSettingsCommands((id) => chosen.push(id) > 0, target)
    const commands = target.tdNative as { run(name: string, arg?: unknown): boolean }
    expect(commands.run('settings-section')).toBe(false)
    expect(commands.run('settings-section', 3)).toBe(false)
    expect(commands.run('new-session')).toBe(false)
    expect(commands.run('select', 'general')).toBe(false)
    expect(chosen).toEqual([])
  })

  it('puts back what was there before', () => {
    const target = host()
    const stub = { run: () => false }
    target.tdNative = stub
    const cleanup = publishSettingsCommands(() => true, target)
    expect(target.tdNative).not.toBe(stub)
    cleanup()
    expect(target.tdNative).toBe(stub)
  })

  it('only selects a section the page is showing (SettingsPage)', () => {
    const page = read('SettingsPage.tsx')
    expect(page).toContain('if (!current.sections.some((section) => section.id === live)) return false')
  })
})

describe('the relay to the main window', () => {
  it('carries each hand-back from the Settings page to the main page, and ignores anything else', async () => {
    const settings = openSettingsRelay()
    const main = openSettingsRelay()
    const heard: SettingsRelayMessage[] = []
    const stop = main.listen((message) => heard.push(message))
    const done = new Promise<void>((resolve) => {
      const check = setInterval(() => {
        if (heard.length >= 3) {
          clearInterval(check)
          resolve()
        }
      }, 5)
    })
    const raw = new BroadcastChannel(SETTINGS_RELAY_CHANNEL)
    raw.postMessage({ type: 'nonsense' })
    raw.postMessage({ type: 'start-session' })
    settings.post({ type: 'changed', values: { 'appearance.theme': 'light' } })
    settings.post({ type: 'start-session', profileId: 'work', provider: 'codex' })
    settings.post({ type: 'set-up-copilot' })
    await done
    expect(heard).toEqual([
      { type: 'changed', values: { 'appearance.theme': 'light' } },
      { type: 'start-session', profileId: 'work', provider: 'codex' },
      { type: 'set-up-copilot' },
    ])
    stop()
    raw.close()
    settings.close()
    main.close()
  })
})

describe('the Settings page', () => {
  it('is the Settings panel, filling its window, with the save status at its foot', () => {
    const html = renderToStaticMarkup(<SettingsPage initialSection="appearance" />)
    expect(html).toContain('class="settings-page"')
    expect(html).toContain('class="settings"')
    expect(html).toContain('class="settings-page-foot"')
    expect(html).toContain('class="settings-status"')
    // The web list is still rendered — the stylesheet hides it in the native shell only.
    expect(html).toContain('class="settings-rail"')
    // And its one button that is not a section, Shortcuts, is at the page's foot too.
    const foot = html.slice(html.indexOf('class="settings-page-foot"'))
    expect(foot).toContain('aria-label="Keyboard shortcuts"')
  })
})
