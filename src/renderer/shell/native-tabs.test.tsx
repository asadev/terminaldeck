import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { WorkspaceTabStrip } from '../browser/WorkspaceTabStrip'
import { promotedStore } from '../browser/workspace-strip'
import { BROWSER_SYMBOL, HOOT_SYMBOL, SESSION_SYMBOL } from './native-sidebar'
import { buildNativeTabs, EMPTY_NATIVE_TABS, stripClose, stripHas, type NativeTabsInput } from './native-tabs'
import type { WorkspaceTab } from './workspace-tabs'

/**
 * The native top bar's tabs are the web strip, described: the strip's own
 * functions over the strip's own inputs, and — the check that matters — the
 * real strip rendered from the same input names the same tabs in the same order
 * with the same one selected.
 */

function memory(initial: Record<string, string> = {}): Storage {
  const map = new Map(Object.entries(initial))
  return {
    get length() {
      return map.size
    },
    clear: () => map.clear(),
    getItem: (key) => map.get(key) ?? null,
    key: (index) => [...map.keys()][index] ?? null,
    removeItem: (key) => void map.delete(key),
    setItem: (key, value) => void map.set(key, value),
  }
}

const tab = (id: string, extra: Partial<WorkspaceTab> = {}): WorkspaceTab => ({
  id,
  kind: 'session',
  label: 'fix login',
  status: 'idle',
  projectPath: '/work/api',
  closable: true,
  ...extra,
})

const TABS: WorkspaceTab[] = [
  tab('s1'),
  tab('s2', { status: 'working' }),
  tab('s3', { label: 'deploy', projectPath: '/work/web' }),
  tab('hoot', { label: 'Hoot', isCopilot: true, projectPath: '/copilot' }),
  tab('p1', { kind: 'browser', label: 'Docs', projectPath: undefined, status: undefined }),
  tab('s4', { label: 'not up here' }),
]

const INPUT: NativeTabsInput = {
  order: ['s2', 's1', 'hoot', 's3'],
  tabs: TABS,
  activeTabId: 's1',
  covered: false,
  unread: ['s3'],
  canNewBrowser: false,
  serverSessions: [],
  serverShellIds: {},
  mode: 'terminal',
  swarm: false,
  panes: { root: null, focusedPaneId: null },
  modeSwitch: false,
  splitOffer: false,
  swarmSessions: [],
  accountSwitch: null,
}

describe('the tabs state', () => {
  const state = buildNativeTabs(INPUT)

  it('lists what the strip shows, in its order: the promoted tabs, then every browser window', () => {
    expect(state.tabs.map((entry) => entry.id)).toEqual(['s2', 's1', 'hoot', 's3', 'p1'])
  })

  it('adds the tab in front when it is not up there, as the strip does', () => {
    expect(buildNativeTabs({ ...INPUT, activeTabId: 's4' }).tabs.map((entry) => entry.id)).toEqual([
      's2',
      's1',
      'hoot',
      's3',
      'p1',
      's4',
    ])
  })

  it('names, marks and selects each tab', () => {
    const byId = new Map(state.tabs.map((entry) => [entry.id, entry]))
    // Two sessions with one name are told apart, as on the strip.
    expect(byId.get('s1')?.title).not.toBe(byId.get('s2')?.title)
    expect(byId.get('s1')).toMatchObject({ kind: 'session', symbol: SESSION_SYMBOL, active: true, status: 'idle', closable: true })
    expect(byId.get('s2')).toMatchObject({ active: false, status: 'working' })
    // Hoot's own window is `hoot`, so the native side draws the owl as the strip does.
    expect(byId.get('hoot')).toMatchObject({ symbol: HOOT_SYMBOL, kind: 'hoot' })
    expect(byId.get('p1')).toMatchObject({ kind: 'browser', symbol: BROWSER_SYMBOL, closable: true })
    expect(byId.get('p1')?.status).toBeUndefined()
    expect(byId.get('s3')?.unread).toBe(true)
    expect(byId.get('s1')?.unread).toBeUndefined()
  })

  it('selects nothing while a sidebar view covers the window', () => {
    expect(buildNativeTabs({ ...INPUT, covered: true }).tabs.some((entry) => entry.active)).toBe(false)
  })

  it('offers a new terminal always, and a new browser window only when one can open', () => {
    expect(state.canNewTerminal).toBe(true)
    expect(state.canNewBrowser).toBe(false)
    expect(buildNativeTabs({ ...INPUT, canNewBrowser: true }).canNewBrowser).toBe(true)
  })

  it('is plain data, with nothing undefined in it', () => {
    const text = JSON.stringify(state)
    expect(JSON.parse(text)).toEqual(state)
    expect(text).not.toContain('undefined')
    expect(buildNativeTabs(EMPTY_NATIVE_TABS)).toEqual({
      tabs: [],
      canNewTerminal: true,
      canNewBrowser: false,
      accountSwitch: null,
      layout: {
        mode: 'terminal',
        swarm: false,
        root: null,
        focusedPaneId: null,
        primaryPaneId: null,
        modeSwitch: false,
        splitOffer: false,
        swarmSessions: [],
      },
    })
  })
})

describe('the same strip the web draws', () => {
  it('names the same tabs, in the same order, with the same one selected', () => {
    const storage = memory()
    promotedStore(storage).set(INPUT.order)
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={TABS}
        activeTabId={INPUT.activeTabId}
        covered={INPUT.covered}
        onSelect={() => undefined}
        onShowInstead={() => undefined}
        onCloseWindow={() => undefined}
        onNewSession={() => undefined}
        onNewBrowserTab={() => undefined}
        storage={storage}
      />,
    )
    const names = [...html.matchAll(/data-tab-name="([^"]*)"/g)].map((match) =>
      match[1].replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#x27;/g, "'"),
    )
    const active = [...html.matchAll(/data-tab-id="([^"]*)"[^>]*data-active="true"/g)].map((match) => match[1])
    const state = buildNativeTabs(INPUT)
    expect(names.length).toBe(5)
    expect(state.tabs.map((entry) => entry.title)).toEqual(names)
    expect(state.tabs.filter((entry) => entry.active).map((entry) => entry.id)).toEqual(active)
  })
})

describe('a tab’s ✕, as the strip does it', () => {
  it('takes a session off the bar, and picks what to show when it was in front', () => {
    const close = stripClose(INPUT, 's1')
    expect(close).toEqual({ kind: 'off-bar', order: ['s2', 'hoot', 's3'], select: 'hoot' })
    const behind = stripClose(INPUT, 's2')
    expect(behind).toEqual({ kind: 'off-bar', order: ['s1', 'hoot', 's3'] })
  })

  it('closes a browser window, and refuses a tab the strip is not showing', () => {
    expect(stripClose(INPUT, 'p1')).toEqual({ kind: 'close-window' })
    expect(stripClose(INPUT, 's4')).toBeNull()
    expect(stripClose(INPUT, 'nope')).toBeNull()
    expect(stripHas(INPUT, 's3')).toBe(true)
    expect(stripHas(INPUT, 's4')).toBe(false)
  })
})

describe('a terminal on a server', () => {
  const box = {
    tabId: 's3',
    serverId: 'box',
    serverName: 'Box',
    shellKey: 'k1',
    status: 'idle' as const,
    startIn: '/srv/app',
    run: 'claude',
  }

  it('carries what it takes to open its shell, and the shell id once one is open', () => {
    const closed = buildNativeTabs({ ...INPUT, serverSessions: [box] }).tabs.find((tab) => tab.id === 's3')
    expect(closed?.server).toEqual({ serverId: 'box', serverName: 'Box', shellKey: 'k1', startIn: '/srv/app', run: 'claude', shellId: null })
    const open = buildNativeTabs({ ...INPUT, serverSessions: [box], serverShellIds: { s3: 'sh-1' } }).tabs.find((tab) => tab.id === 's3')
    expect(open?.server?.shellId).toBe('sh-1')
  })

  it('leaves every other tab without it', () => {
    const tabs = buildNativeTabs({ ...INPUT, serverSessions: [box] }).tabs.filter((tab) => tab.id !== 's3')
    expect(tabs.every((tab) => !('server' in tab))).toBe(true)
  })
})

describe('the window\'s arrangement (split and swarm)', () => {
  it('carries the pane tree as it is, the focused and primary pane, and ModeSwitch\'s facts', () => {
    const root = {
      type: 'split' as const,
      id: 'sp1',
      direction: 'horizontal' as const,
      ratio: 0.4,
      children: [
        { type: 'leaf' as const, id: 'p1', tabId: 's1' },
        { type: 'leaf' as const, id: 'p2', tabId: 's2' },
      ] as const,
    }
    const layout = buildNativeTabs({
      ...INPUT,
      mode: 'split',
      panes: { root, focusedPaneId: 'p2' },
      modeSwitch: true,
      splitOffer: true,
    }).layout
    expect(layout.mode).toBe('split')
    expect(layout.root).toEqual(root)
    expect(layout.focusedPaneId).toBe('p2')
    expect(layout.primaryPaneId).toBe('p1')
    expect(layout.modeSwitch).toBe(true)
    expect(layout.splitOffer).toBe(true)
    expect(JSON.parse(JSON.stringify(layout))).toEqual(layout)
  })

  it('lists swarm\'s sessions with their titles', () => {
    const layout = buildNativeTabs({
      ...INPUT,
      swarm: true,
      swarmSessions: [{ id: 's1', title: 'api', status: 'idle' }],
    }).layout
    expect(layout.swarm).toBe(true)
    expect(layout.swarmSessions).toEqual([{ id: 's1', title: 'api', status: 'idle' }])
  })
})

describe('the account-switch note', () => {
  it('carries the session, whether it is still going, and its words', () => {
    const working = { sessionId: 's1', state: 'working' as const, text: 'Switching to Work…' }
    expect(buildNativeTabs({ ...INPUT, accountSwitch: working }).accountSwitch).toEqual(working)
    const done = { sessionId: 's1', state: 'done' as const, text: 'Switched to Work' }
    expect(buildNativeTabs({ ...INPUT, accountSwitch: done }).accountSwitch).toEqual(done)
    expect(buildNativeTabs(INPUT).accountSwitch).toBeNull()
  })

  it('is built in App from switchingNote first, then accountSwitchNote', () => {
    const app = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')
    const strip = app.slice(app.indexOf('stripInput.current = {'))
    expect(strip).toContain("? { sessionId: switcher.working.sessionId, state: 'working', text: switchingNote }")
    expect(strip).toContain("? { sessionId: accountSwitchNote.sessionId, state: 'done', text: accountSwitchNote.text }")
  })
})
