import { describe, expect, it } from 'vitest'
import {
  closeTab,
  cycle,
  moveTab,
  newTab,
  openTab,
  tabForId,
  tabTitle,
  withTab,
  withTabId,
  type WorkspaceTab,
} from './tabs'

const strip = (...keys: string[]): WorkspaceTab[] => keys.map((key) => newTab(key))
const keys = (tabs: WorkspaceTab[]): string[] => tabs.map((tab) => tab.key)

describe('openTab', () => {
  it('opens after the active tab, not at the end', () => {
    const tabs = openTab(strip('a', 'b', 'c'), newTab('new'), 'a')
    expect(keys(tabs)).toEqual(['a', 'new', 'b', 'c'])
  })

  it('appends when there is nothing to open after', () => {
    expect(keys(openTab(strip('a'), newTab('new'), null))).toEqual(['a', 'new'])
    expect(keys(openTab(strip('a'), newTab('new'), 'gone'))).toEqual(['a', 'new'])
    expect(keys(openTab([], newTab('new'), null))).toEqual(['new'])
  })
})

describe('closeTab', () => {
  it('lands on the right-hand neighbour', () => {
    // Falling back to tabs[0] instead throws the user across the strip every
    // time they close something in the middle of it.
    const result = closeTab(strip('a', 'b', 'c'), 'b', 'b')
    expect(keys(result.tabs)).toEqual(['a', 'c'])
    expect(result.activeKey).toBe('c')
  })

  it('falls back to the left when the closed tab was last', () => {
    expect(closeTab(strip('a', 'b', 'c'), 'c', 'c').activeKey).toBe('b')
  })

  it('leaves the selection alone when another tab closed', () => {
    expect(closeTab(strip('a', 'b', 'c'), 'a', 'c').activeKey).toBe('c')
  })

  it('has no active tab once the last one closes', () => {
    const result = closeTab(strip('a'), 'a', 'a')
    expect(result.tabs).toEqual([])
    expect(result.activeKey).toBe('')
  })

  it('ignores a key that is not in the strip', () => {
    const tabs = strip('a', 'b')
    const result = closeTab(tabs, 'gone', 'a')
    expect(result.tabs).toBe(tabs)
    expect(result.activeKey).toBe('a')
  })
})

describe('moveTab', () => {
  it('reorders without touching anything else', () => {
    expect(keys(moveTab(strip('a', 'b', 'c'), 'a', 2))).toEqual(['b', 'c', 'a'])
    expect(keys(moveTab(strip('a', 'b', 'c'), 'c', 0))).toEqual(['c', 'a', 'b'])
  })

  it('clamps a drop past either end instead of losing the tab', () => {
    expect(keys(moveTab(strip('a', 'b', 'c'), 'a', 99))).toEqual(['b', 'c', 'a'])
    expect(keys(moveTab(strip('a', 'b', 'c'), 'c', -5))).toEqual(['c', 'a', 'b'])
  })

  it('returns the same array when nothing moved', () => {
    const tabs = strip('a', 'b')
    expect(moveTab(tabs, 'a', 0)).toBe(tabs)
    expect(moveTab(tabs, 'gone', 1)).toBe(tabs)
  })
})

describe('cycle', () => {
  it('wraps in both directions', () => {
    const tabs = strip('a', 'b', 'c')
    expect(cycle(tabs, 'a', 1)).toBe('b')
    expect(cycle(tabs, 'c', 1)).toBe('a')
    expect(cycle(tabs, 'a', -1)).toBe('c')
  })

  it('copes with an unknown or empty selection', () => {
    expect(cycle(strip('a', 'b'), 'gone', 1)).toBe('a')
    expect(cycle([], 'a', 1)).toBe('')
  })
})

describe('patching', () => {
  it('never mutates the array it was handed', () => {
    const tabs = strip('a', 'b')
    const next = withTab(tabs, 'a', { loading: true })
    expect(tabs[0].loading).toBe(false)
    expect(next[0].loading).toBe(true)
  })

  it('finds a tab by the main-process id that events carry', () => {
    const tabs = withTab(strip('a', 'b'), 'b', { id: 'tab-42' })
    expect(tabForId(tabs, 'tab-42')?.key).toBe('b')
    expect(withTabId(tabs, 'tab-42', { title: 'Dev' })[1].title).toBe('Dev')
  })

  it('ignores an id no tab is holding — an event for a tab already closed', () => {
    const tabs = strip('a')
    expect(withTabId(tabs, 'gone', { title: 'x' })).toBe(tabs)
    expect(withTab(tabs, 'gone', { title: 'x' })).toBe(tabs)
  })
})

describe('tabTitle', () => {
  it('prefers the page title, then the host, then a placeholder', () => {
    const tab = newTab('a')
    expect(tabTitle({ ...tab, title: 'Dashboard', label: 'localhost:3000' })).toBe('Dashboard')
    expect(tabTitle({ ...tab, title: '   ', label: 'localhost:3000' })).toBe('localhost:3000')
    expect(tabTitle(tab)).toBe('New tab')
  })
})
