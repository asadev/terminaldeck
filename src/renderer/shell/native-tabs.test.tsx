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
    expect(buildNativeTabs(EMPTY_NATIVE_TABS)).toEqual({ tabs: [], canNewTerminal: true, canNewBrowser: false })
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
