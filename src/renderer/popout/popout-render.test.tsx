import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { WorkspaceTabStrip } from '../browser/WorkspaceTabStrip'
import type { WorkspaceTab } from '../shell/workspace-tabs'
import { PoppedOutCard } from './PoppedOutCard'

function store(initial: Record<string, string> = {}): Storage {
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

const TABS: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Session 1', closable: true },
  { id: 's2', kind: 'session', label: 'Session 2', closable: true },
]

const moves = (popped: string[]) => ({
  popped: new Set(popped),
  canMove: () => true,
  popOut: () => undefined,
})

describe('what the main window draws for a session that is out', () => {
  it('says where it went and offers the window, then the way back', () => {
    const html = renderToStaticMarkup(
      <PoppedOutCard visible where="DELL U2723QE" onShow={() => undefined} onDock={() => undefined} />,
    )
    expect(html).toContain('Open in its own window')
    expect(html).toContain('On DELL U2723QE')
    expect(html).toContain('Show window')
    expect(html).toContain('Move back here')
    // The window is the one thing to do from here; the way back is the quiet one.
    expect(html).toMatch(/class="btn-primary page-blank-action"[^>]*>Show window/)
  })

  it('names no display on a single screen, where "another window" is the whole answer', () => {
    const html = renderToStaticMarkup(<PoppedOutCard visible where="" onShow={() => undefined} onDock={() => undefined} />)
    expect(html).not.toContain('On ')
  })

  it('stays mounted and hidden behind another tab, the way a terminal does', () => {
    const html = renderToStaticMarkup(<PoppedOutCard visible={false} where="" onShow={() => undefined} onDock={() => undefined} />)
    expect(html).toContain('data-visible="false"')
  })
})

describe('the mark on a tab that is out', () => {
  it('is on the tab of the session that is out, and no other', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={TABS}
        activeTabId="s1"
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': JSON.stringify(['s1', 's2']) })}
        windowMoves={moves(['s2'])}
      />,
    )
    expect(html.match(/Open in its own window/g)).toHaveLength(2) // title + aria-label, one tab
    const second = html.slice(html.indexOf('data-tab-id="s2"'))
    expect(second).toContain('popped-mark')
    const first = html.slice(html.indexOf('data-tab-id="s1"'), html.indexOf('data-tab-id="s2"'))
    expect(first).not.toContain('popped-mark')
  })

  it('is absent where the window cannot move sessions at all', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={TABS} activeTabId="s1" onSelect={() => undefined} storage={store()} />,
    )
    expect(html).not.toContain('popped-mark')
  })
})

/*
 * The wiring a static render cannot see, read off the source — the same way
 * `wiring.test.ts` holds `App.tsx` to its seams. A session that is out must
 * never be mounted as a second terminal in any of the three layouts.
 */
describe('the main window never mounts a second terminal for a session that is out', () => {
  const app = readFileSync(join(__dirname, '../App.tsx'), 'utf8')

  it('asks before the single-session terminal, the swarm cell and the split pane', () => {
    expect(app).toContain('if (sessionWindows.popped.has(session.id)) return poppedCard(session.id, active)')
    expect(app).toContain('renderCell={({ session }) => sessionWindows.popped.has(session.id) ? poppedCard(session.id, true)')
    expect(app).toContain(') : session && sessionWindows.popped.has(session.id) ? (')
  })

  it('hands both bars the moves', () => {
    expect(app.match(/windowMoves=\{windowMoves\}/g)).toHaveLength(2)
  })
})
