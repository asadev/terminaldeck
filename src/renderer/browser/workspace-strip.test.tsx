import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  isTabDrag,
  readTabDrag,
  startTabDrag,
  TAB_DRAG_MIME,
  type TabTransfer,
  type WorkspaceTab,
} from '../shell/workspace-tabs'
import { WorkspaceTabStrip } from './WorkspaceTabStrip'
import {
  demote,
  dropIndex,
  MAX_PROMOTED,
  promote,
  pruneOrder,
  readPromoted,
  stripTabs,
  writePromoted,
} from './workspace-strip'

/**
 * *"we should be able to just drag and drop in the top whatever we want to see
 * in the top, and the rest we can fold inside the side panel."*
 *
 * The interesting behaviour is the model — what a drop does to the order, what
 * happens to a promoted tab that gets closed, and what a drag that lands
 * nowhere means. All of it is pure, so all of it is pinned here rather than
 * left to a browser nobody runs in CI.
 */

function session(id: string, label = id): WorkspaceTab {
  return { id, kind: 'session', label, closable: true }
}

const OPEN = [session('a'), session('b'), session('c')]

describe('promote', () => {
  it('puts a tab in at the index the pointer was over', () => {
    expect(promote(['a', 'c'], 'b', 1)).toEqual(['a', 'b', 'c'])
    expect(promote(['a', 'c'], 'b', 0)).toEqual(['b', 'a', 'c'])
    expect(promote(['a', 'c'], 'b', 2)).toEqual(['a', 'c', 'b'])
  })

  it('moves rather than duplicates a tab that is already promoted', () => {
    // Reordering within the strip goes through this same function, so a
    // duplicate here would be a tab that appears twice after one drag.
    expect(promote(['a', 'b', 'c'], 'a', 3)).toEqual(['b', 'c', 'a'])
    expect(promote(['a', 'b', 'c'], 'c', 0)).toEqual(['c', 'a', 'b'])
  })

  it('clamps a drop past either end instead of throwing', () => {
    // The index comes from a pointer position, so out of range is ordinary.
    expect(promote(['a'], 'b', 99)).toEqual(['a', 'b'])
    expect(promote(['a'], 'b', -5)).toEqual(['b', 'a'])
    expect(promote(['a'], 'b', Number.NaN)).toEqual(['b', 'a'])
  })

  it('refuses past the cap rather than silently dropping the far end', () => {
    // A strip that quietly threw away the tab at the other side while you were
    // watching the one you dragged would read as a bug in the drag.
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    expect(promote(full, 'extra', 0)).toEqual(full)
    // Rearranging one that is already in a full strip still has to work.
    expect(promote(full, full[3], 0)[0]).toBe(full[3])
  })
})

describe('demote', () => {
  it('folds a tab back into the side panel', () => {
    expect(demote(['a', 'b', 'c'], 'b')).toEqual(['a', 'c'])
  })

  it('is a no-op for a tab that was never promoted', () => {
    expect(demote(['a'], 'zzz')).toEqual(['a'])
  })
})

describe('stripTabs', () => {
  it('draws the promoted tabs in the promoted order, not the sidebar’s', () => {
    expect(stripTabs(['c', 'a'], OPEN).map((tab) => tab.id)).toEqual(['c', 'a'])
  })

  it('drops a promoted tab whose window has been closed', () => {
    /*
     * With no bookkeeping at the closing end, which is the point. A session can
     * end four different ways and only one of them is somewhere a caller could
     * remember to prune the strip.
     */
    expect(stripTabs(['a', 'gone', 'b'], OPEN).map((tab) => tab.id)).toEqual(['a', 'b'])
  })

  it('is empty until something is promoted', () => {
    // An untouched install never sees this strip at all, which is what pays for
    // a second band of chrome in a one-toolbar window.
    expect(stripTabs([], OPEN)).toEqual([])
  })
})

describe('pruneOrder', () => {
  it('keeps only the ids that still name an open window', () => {
    expect(pruneOrder(['a', 'gone', 'b'], OPEN)).toEqual(['a', 'b'])
  })
})

describe('dropIndex', () => {
  const rects = [
    { left: 0, width: 100 },
    { left: 100, width: 100 },
    { left: 200, width: 100 },
  ]

  it('lands before a tab while the pointer is on its first half', () => {
    expect(dropIndex(rects, 10)).toBe(0)
    expect(dropIndex(rects, 49)).toBe(0)
  })

  it('lands after a tab once the pointer passes its middle', () => {
    expect(dropIndex(rects, 51)).toBe(1)
    expect(dropIndex(rects, 151)).toBe(2)
  })

  it('lands at the end past the last tab, which is a real answer', () => {
    expect(dropIndex(rects, 999)).toBe(3)
  })

  it('lands at zero on an empty strip', () => {
    expect(dropIndex([], 400)).toBe(0)
  })
})

/* --------------------------------------------------------- the contract -- */

/** A `DataTransfer` stand-in, including the protected-mode behaviour. */
function transfer(protectedMode = false): TabTransfer & { data: Map<string, string> } {
  const data = new Map<string, string>()
  return {
    data,
    effectAllowed: 'none',
    get types() {
      return [...data.keys()]
    },
    setData(format, value) {
      data.set(format, value)
    },
    getData(format) {
      // During dragover the browser withholds the payload and returns ''. This
      // is spec behaviour in every engine and the reason `isTabDrag` exists.
      return protectedMode ? '' : (data.get(format) ?? '')
    },
  }
}

describe('the drag contract', () => {
  it('offers a tab in one private format and nothing else', () => {
    /*
     * Load-bearing. This window is full of drop targets that are not ours — a
     * terminal types dropped text, the omnibox takes a dragged URL — and a tab
     * offered as `text/plain` would be droppable into all of them.
     */
    const dt = transfer()
    startTabDrag(dt, 'session-7')
    expect([...dt.data.keys()]).toEqual([TAB_DRAG_MIME])
    expect(dt.data.get(TAB_DRAG_MIME)).toBe('session-7')
    expect(dt.effectAllowed).toBe('move')
  })

  it('recognises a tab drag while the payload is still protected', () => {
    // The failure this prevents: a dragover handler that read the payload would
    // see '' and refuse every drop it was written to accept.
    const dt = transfer(true)
    startTabDrag(dt, 'session-7')
    expect(isTabDrag(dt)).toBe(true)
    expect(dt.getData(TAB_DRAG_MIME)).toBe('')
  })

  it('reads the id on drop, when the payload is released', () => {
    const dt = transfer()
    startTabDrag(dt, 'session-7')
    expect(readTabDrag(dt)).toBe('session-7')
  })

  it('refuses anything that is not one of our tabs', () => {
    const plain = transfer()
    plain.setData('text/plain', 'rm -rf /')
    expect(isTabDrag(plain)).toBe(false)
    expect(readTabDrag(plain)).toBeNull()
    expect(readTabDrag(null)).toBeNull()
    expect(readTabDrag(undefined)).toBeNull()
  })

  it('refuses an empty id, which is a drag that started wrong', () => {
    const dt = transfer()
    dt.setData(TAB_DRAG_MIME, '')
    expect(readTabDrag(dt)).toBeNull()
  })
})

/* ---------------------------------------------------------- the markup -- */

/** A `Storage` stand-in — this project's test run has no DOM and no window. */
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

describe('the strip’s markup', () => {
  it('teaches the gesture when nothing has been promoted', () => {
    // An invisible drop zone is undiscoverable, and this is a gesture nobody
    // has been taught anywhere else in the app.
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={OPEN} activeTabId="a" onSelect={() => undefined} storage={store()} />,
    )
    expect(html).toContain('Drag a session or a page here')
  })

  it('draws the promoted tabs it was left with', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), session('b', 'web')]}
        activeTabId="b"
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["b","a"]' })}
      />,
    )
    expect(html).toContain('web')
    expect(html).toContain('api')
    // Promoted order, not the sidebar's.
    expect(html.indexOf('web')).toBeLessThan(html.indexOf('api'))
    expect(html).toContain('aria-selected="true"')
  })

  it('offers a fold-away that is not dressed as a close button', () => {
    /*
     * The one mistake this strip cannot afford: a control that looks like ✕ and
     * quietly removes the tab from the strip would read as having killed the
     * session. The label says what it does, and Close is a separate control
     * that only exists when a host actually wired one.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a"]' })}
      />,
    )
    expect(html).toContain('aria-label="Fold api back into the sidebar"')
    expect(html).not.toContain('aria-label="Close api"')
  })

  it('adds a real close only when the host wired one', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        onClose={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a"]' })}
      />,
    )
    expect(html).toContain('aria-label="Close api"')
  })

  it('renders with no storage at all rather than throwing', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={OPEN} activeTabId={null} onSelect={() => undefined} storage={null} />,
    )
    expect(html).toContain('Drag a session or a page here')
  })
})

describe('remembering the arrangement', () => {
  it('reads back exactly what it wrote', () => {
    const disk = store()
    writePromoted(disk, ['b', 'a'])
    expect(readPromoted(disk)).toEqual(['b', 'a'])
  })

  it('starts empty rather than throwing on a corrupt value', () => {
    expect(readPromoted(store({ 'terminaldeck.strip.promoted': 'not json' }))).toEqual([])
    expect(readPromoted(store({ 'terminaldeck.strip.promoted': '{"a":1}' }))).toEqual([])
    expect(readPromoted(store({ 'terminaldeck.strip.promoted': '[1,null,"a",""]' }))).toEqual(['a'])
    expect(readPromoted(null)).toEqual([])
  })

  it('does not fail a render when the store refuses to be written', () => {
    const refusing = { ...store(), setItem: () => { throw new Error('quota') } } as Storage
    expect(() => writePromoted(refusing, ['a'])).not.toThrow()
    expect(() => writePromoted(null, ['a'])).not.toThrow()
  })
})
