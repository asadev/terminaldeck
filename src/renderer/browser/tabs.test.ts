import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  BLANK_URL,
  NEW_TAB_LABEL,
  closeTab,
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

  /**
   * The app's own start page called itself `about:blank` — in the sidebar row,
   * in the tab strip, in the pane bar, and in the tooltip on each of them,
   * because all four read this one function. Chromium substitutes the address
   * for a document with no `<title>`, `stateOf` in the main process forwarded
   * it, and nothing here questioned a title that was plainly a URL.
   *
   * Fixed at the source in `src/main/browser-url.ts`; kept here as well because
   * the renderer is not always talking to a main process built from the same
   * commit — `patchFrom` in `BrowserWorkspace` already carries a field that
   * "older main processes did not send".
   */
  it('does not let the blank address pass itself off as a name', () => {
    const tab = newTab('a')
    expect(tabTitle({ ...tab, title: BLANK_URL })).toBe(NEW_TAB_LABEL)
    // With a real page behind it the host still wins over the placeholder.
    expect(tabTitle({ ...tab, title: BLANK_URL, label: 'localhost:3000' })).toBe('localhost:3000')
  })

  it('does not repeat the address a tab is already showing', () => {
    const tab = newTab('a')
    expect(
      tabTitle({
        ...tab,
        title: 'http://localhost:3000/pricing',
        url: 'http://localhost:3000/pricing',
        label: 'localhost:3000/pricing',
      }),
    ).toBe('localhost:3000/pricing')
  })
})

/**
 * The placeholder is one string in two files.
 *
 * The renderer cannot import from `src/main`, so `NEW_TAB_LABEL` exists twice.
 * That is survivable only while something checks. Reading the other copy off
 * disk is the check: rename one and this fails, instead of the sidebar and the
 * main process quietly calling the same page two different things.
 */
describe('the name of an unvisited page', () => {
  const mainSource = readFileSync(
    join(resolve(__dirname, '..', '..'), 'main', 'browser-url.ts'),
    'utf8',
  )

  it('matches the copy in the main process', () => {
    expect(mainSource).toContain(`export const NEW_TAB_LABEL = '${NEW_TAB_LABEL}'`)
    expect(mainSource).toContain(`export const BLANK_URL = '${BLANK_URL}'`)
  })

  it('is what a tab is born with, so the strip never jumps', () => {
    expect(newTab('a').label).toBe(NEW_TAB_LABEL)
  })
})
