import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  chordTarget,
  findAvailable,
  matchLabel,
  parseChord,
  parseFindCount,
  printAvailable,
  resolveFindApi,
  workspaceChord,
} from './find-bridge'

/**
 * The rules that keep the find bar honest, held where something DOM-less can
 * hold them. The two that matter most are the two failure modes the lane brief
 * names outright: a bar drawn over the wrong pane, and a control offered by a
 * preload that cannot answer for it.
 */

const wired = {
  browserFind: async () => undefined,
  browserFindStop: async () => undefined,
  browserPrint: async () => undefined,
  onBrowserFind: () => () => undefined,
  onBrowserChord: () => () => undefined,
}

describe('what counts as available', () => {
  it('offers find only with the query, the stop and the count together', () => {
    expect(findAvailable(resolveFindApi(wired))).toBe(true)
    // Any one absent and the bar is a control that looks like it works: no
    // stop strands highlights, no count finds things and reports nothing.
    for (const missing of ['browserFind', 'browserFindStop', 'onBrowserFind'] as const) {
      const partial: Record<string, unknown> = { ...wired }
      delete partial[missing]
      expect(findAvailable(resolveFindApi(partial)), `without ${missing}`).toBe(false)
    }
  })

  it('does not hold find hostage to the chord channel', () => {
    // An older preload without the chord push still opens the bar from the
    // chrome's own ⌘F and from the menu row.
    const partial: Record<string, unknown> = { ...wired }
    delete partial.onBrowserChord
    expect(findAvailable(resolveFindApi(partial))).toBe(true)
  })

  it('offers print exactly when the preload can print', () => {
    expect(printAvailable(resolveFindApi(wired))).toBe(true)
    const partial: Record<string, unknown> = { ...wired }
    delete partial.browserPrint
    expect(printAvailable(resolveFindApi(partial))).toBe(false)
  })

  it('answers an empty partial for a host with nothing at all', () => {
    expect(resolveFindApi(null)).toEqual({})
    expect(resolveFindApi(undefined)).toEqual({})
    expect(findAvailable(resolveFindApi({}))).toBe(false)
  })
})

describe('routing a chord to a pane', () => {
  const tabs = [
    { key: 'tab-1', id: 'view-a' },
    { key: 'tab-2', id: 'view-b' },
    { key: 'tab-3', id: null },
  ]

  it('acts only on the page in front', () => {
    expect(chordTarget(tabs, 'tab-1', 'view-a')).toBe('tab-1')
  })

  it('refuses a view this panel never opened — another split, another panel', () => {
    // The find bar over the wrong pane, refusal one: a chord from a page some
    // other workspace owns must not draw a bar here.
    expect(chordTarget(tabs, 'tab-1', 'view-elsewhere')).toBeNull()
  })

  it('refuses one of its own tabs that is not the active one', () => {
    // Refusal two: a bar captioned with a background page's matches, drawn
    // over the page in front, is the same wrong pane from inside.
    expect(chordTarget(tabs, 'tab-1', 'view-b')).toBeNull()
  })

  it('never matches a tab that has no view yet', () => {
    expect(chordTarget(tabs, 'tab-3', '')).toBeNull()
  })
})

describe('the wire is parsed, never trusted', () => {
  it('accepts exactly the chords the main process sends', () => {
    for (const chord of ['find', 'find-close', 'find-next', 'find-prev', 'zoom-in', 'zoom-out', 'zoom-reset', 'print']) {
      expect(parseChord(chord)).toBe(chord)
    }
    expect(parseChord('reboot')).toBeNull()
    expect(parseChord(42)).toBeNull()
    expect(parseChord(null)).toBeNull()
  })

  it('accepts a count only with both finite numbers on it', () => {
    expect(parseFindCount({ ordinal: 2, matches: 17, final: true })).toEqual({ ordinal: 2, matches: 17 })
    expect(parseFindCount({ ordinal: 'two', matches: 17 })).toBeNull()
    expect(parseFindCount({ ordinal: 2 })).toBeNull()
    expect(parseFindCount(null)).toBeNull()
    // Chromium never sends these, so anything shaped like them is corruption —
    // clamp rather than let a negative walk into the label.
    expect(parseFindCount({ ordinal: -1, matches: 2.5 })).toEqual({ ordinal: 0, matches: 2 })
  })
})

describe('the chrome-side chords', () => {
  it('matches the guest side for the four it owns', () => {
    expect(workspaceChord({ key: 'f', metaKey: true })).toBe('find')
    expect(workspaceChord({ key: 'F', ctrlKey: true })).toBe('find')
    expect(workspaceChord({ key: '=', metaKey: true })).toBe('zoom-in')
    expect(workspaceChord({ key: '+', ctrlKey: true, shiftKey: true })).toBe('zoom-in')
    expect(workspaceChord({ key: '-', metaKey: true })).toBe('zoom-out')
    expect(workspaceChord({ key: '0', metaKey: true })).toBe('zoom-reset')
  })

  it('claims nothing that belongs to the app or to typing', () => {
    // ⌘⇧F is Search Sessions; bare letters are the address bar's text; ⌘P is
    // Quick Open whenever the renderer has focus — print is the *page's* chord
    // and only `guestChord` answers it.
    expect(workspaceChord({ key: 'f', metaKey: true, shiftKey: true })).toBeNull()
    expect(workspaceChord({ key: 'f' })).toBeNull()
    expect(workspaceChord({ key: 'p', metaKey: true })).toBeNull()
    expect(workspaceChord({ key: '=', metaKey: true, altKey: true })).toBeNull()
  })
})

describe('the sentence beside the field', () => {
  it('is silent with no query, counts with one, and says No matches over 0/0', () => {
    expect(matchLabel('', null)).toBe('')
    expect(matchLabel('', { ordinal: 1, matches: 3 })).toBe('')
    expect(matchLabel('needle', null)).toBe('')
    expect(matchLabel('needle', { ordinal: 2, matches: 17 })).toBe('2/17')
    expect(matchLabel('needle', { ordinal: 0, matches: 0 })).toBe('No matches')
  })
})

/**
 * The workspace's half of the bargain, held as source the way
 * `BrowserMenu.test.ts` holds its rows — this suite has no DOM to click, and
 * the two lines below are the ones a refactor would quietly drop.
 */
describe('the workspace keeps the routing honest', () => {
  const source = readFileSync(join(__dirname, 'BrowserWorkspace.tsx'), 'utf8')

  it('routes every pushed chord through chordTarget, never straight to the bar', () => {
    expect(source).toContain('chordTarget(tabsRef.current, activeRef.current, viewId)')
  })

  it('draws the bar only where the preload can find', () => {
    // A bar whose invokes are missing is a control that looks like it works.
    expect(source).toContain('findState.open && findAvailable(findApi) && (')
  })

  it('parses both pushes before acting on them', () => {
    expect(source).toContain('parseFindCount(raw)')
    expect(source).toContain('parseChord(raw)')
  })
})
