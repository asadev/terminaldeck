import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  isTabDrag,
  middleEllipsis,
  readTabDrag,
  startTabDrag,
  STRIP_LABEL_BUDGET,
  tabLabel,
  tabTooltip,
  TAB_DRAG_MIME,
  type TabTransfer,
  type WorkspaceTab,
} from '../shell/workspace-tabs'
import { Sidebar } from '../shell/Sidebar'
import { WorkspaceTabStrip } from './WorkspaceTabStrip'
import {
  createPromotedStore,
  demote,
  dropIndex,
  MAX_PROMOTED,
  promote,
  promotedStore,
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

describe('the strip on a window with nothing in it', () => {
  /*
   * Caught by rendering the real build and looking at it, not by reading this
   * file: on a fresh launch — no project, no session — the strip drew a bar
   * across the window reading "Drag a session or a page here to keep it along
   * the top", directly above a side panel that said "Nothing open yet".
   *
   * The hint is right whenever something *could* be dragged. It is wrong when
   * nothing exists, because it advertises a gesture that cannot be performed
   * and spends a strip of every empty window doing it. The distinguishing fact
   * is `tabs`, not `promoted`.
   */
  it('draws nothing when there is nothing that could be dragged into it', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={[]} activeTabId={null} onSelect={() => {}} storage={null} />,
    )
    expect(html).toBe('')
  })

  it('still offers the drop target once something exists to promote', () => {
    // Through `session()` like every other fixture in this file, rather than an
    // object literal of its own. The literal that was here named a `title` field
    // — `WorkspaceTab` has `label` — and left out `closable`, so it compiled to
    // nothing the component could have rendered. Vitest never noticed because it
    // does not typecheck; `npm run typecheck` did.
    const tabs: WorkspaceTab[] = [session('s1', 'Session 1')]
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={tabs} activeTabId="s1" onSelect={() => {}} storage={null} />,
    )
    expect(html).toContain('Drag a session or a page here')
  })
})

/* ------------------------------------------------- what a tab is called -- */

describe('middleEllipsis', () => {
  /*
   * Not a style preference. The window this was written in had three sessions
   * in one folder, all titled by the agent as "Update Claude Code terminal to
   * …", and cutting the end — the only thing CSS can do — printed the same
   * twenty-three characters on all three. The half that tells them apart is the
   * tail.
   */
  it('leaves a label that already fits alone', () => {
    expect(middleEllipsis('Session 2', 22)).toBe('Session 2')
    expect(middleEllipsis('x'.repeat(22), 22)).toBe('x'.repeat(22))
  })

  it('keeps both ends of a label that does not', () => {
    const cut = middleEllipsis('Update Claude Code terminal to new API', 22)
    expect(cut.startsWith('Update Cla')).toBe(true)
    expect(cut.endsWith('to new API')).toBe(true)
    expect(cut).toContain('…')
    expect(cut.length).toBeLessThanOrEqual(22)
  })

  it('tells two labels apart that share a long opening', () => {
    const [a, b] = ['Update Claude Code terminal to new API', 'Update Claude Code terminal to new UI']
    expect(middleEllipsis(a, 22)).not.toBe(middleEllipsis(b, 22))
    // Which is exactly what cutting the end cannot do — the failure this fixes.
    expect(a.slice(0, 22)).toBe(b.slice(0, 22))
  })

  it('does not leave a space stranded against the ellipsis', () => {
    expect(middleEllipsis('Update Claude Code terminal', 22)).not.toContain(' …')
    expect(middleEllipsis('Update Claude Code terminal', 22)).not.toContain('… ')
  })

  it('gives up rather than returning a lone ellipsis', () => {
    // There is nothing to show on either side of the mark at these budgets, and
    // a tab reading "…" says less than a clipped word.
    expect(middleEllipsis('Session 2', 3)).toBe('Session 2')
    expect(middleEllipsis('Session 2', Number.NaN)).toBe('Session 2')
  })
})

describe('tabLabel', () => {
  const inProject = (id: string, label: string): WorkspaceTab => ({
    id,
    kind: 'session',
    label,
    projectPath: '/Users/apple/Projects/terminaldeck',
    closable: true,
  })

  it('numbers an unnamed session the way the sidebar does', () => {
    /*
     * Seen on screen, which is the only way it could have been: the strip drew
     * `tab.label` raw, so a session the agent had not yet named read
     * "terminaldeck" along the top and "Session 1" down the side — one window
     * with two names, and promoting it looked like it had renamed it.
     */
    const tabs = [inProject('a', 'terminaldeck'), inProject('b', 'terminaldeck')]
    expect(tabs.map((tab) => tabLabel(tab, tabs))).toEqual(['Session 1', 'Session 2'])
  })

  it('keeps a title the agent actually wrote', () => {
    const tabs = [inProject('a', 'Fix the login redirect')]
    expect(tabLabel(tabs[0], tabs)).toBe('Fix the login redirect')
  })

  it('counts siblings per folder, not per strip', () => {
    // The strip holds an arbitrary subset in an arbitrary order, so numbering by
    // position in it would call the same window different things on different
    // days.
    const other: WorkspaceTab = {
      id: 'z',
      kind: 'session',
      label: 'science-locus',
      projectPath: '/Users/apple/Projects/science-locus',
      closable: true,
    }
    const tabs = [other, inProject('a', 'terminaldeck'), inProject('b', 'terminaldeck')]
    expect(tabLabel(tabs[2], tabs)).toBe('Session 2')
    expect(tabLabel(other, tabs)).toBe('Session 1')
  })

  it('leaves a browser page named after its page', () => {
    const page: WorkspaceTab = { id: 'p', kind: 'browser', label: 'localhost:5173', closable: true }
    expect(tabLabel(page, [page])).toBe('localhost:5173')
  })
})

describe('tabTooltip', () => {
  it('carries the whole title and the folder under it', () => {
    const tab = session('a', 'Fix the login redirect')
    expect(tabTooltip({ ...tab, projectPath: '/Users/apple/Projects/terminaldeck' }, tab.label)).toBe(
      'Fix the login redirect\n/Users/apple/Projects/terminaldeck',
    )
  })

  it('says nothing about a folder a browser page does not have', () => {
    // An empty second line reads as a value that failed to load.
    expect(tabTooltip(session('a', 'localhost:5173'), 'localhost:5173')).toBe('localhost:5173')
  })
})

/* -------------------------------------------- the order, shared two ways -- */

describe('the promoted store', () => {
  it('reads its opening value out of storage', () => {
    const held = createPromotedStore(store({ 'terminaldeck.strip.promoted': '["b","a"]' }))
    expect(held.get()).toEqual(['b', 'a'])
  })

  it('writes through, and tells everyone who asked', () => {
    const disk = store()
    const held = createPromotedStore(disk)
    let heard = 0
    held.subscribe(() => (heard += 1))
    held.set(['a'])
    expect(heard).toBe(1)
    expect(held.get()).toEqual(['a'])
    expect(readPromoted(disk)).toEqual(['a'])
  })

  it('ignores a set that changes nothing', () => {
    /*
     * Load-bearing, not an optimisation. The strip prunes its order against the
     * live tab list inside an effect that runs on every render; without this
     * guard that effect would hand back a new array identity every time, wake
     * itself, and never settle.
     */
    const held = createPromotedStore(store())
    let heard = 0
    held.subscribe(() => (heard += 1))
    held.set(['a', 'b'])
    held.set(['a', 'b'])
    expect(heard).toBe(1)
  })

  it('hands the same store back for the same storage, and only then', () => {
    // The sidebar's toggle and the strip have to be looking at one list. They
    // find each other by both asking for `window.localStorage`.
    const disk = store()
    expect(promotedStore(disk)).toBe(promotedStore(disk))
    expect(promotedStore(disk)).not.toBe(promotedStore(store()))
  })

  it('stops listening when told to', () => {
    const held = createPromotedStore(store())
    let heard = 0
    const off = held.subscribe(() => (heard += 1))
    off()
    held.set(['a'])
    expect(heard).toBe(0)
  })

  it('keeps the arrangement when there is nowhere to write it', () => {
    // A window with storage disabled by policy still gets a working strip for
    // as long as it is open; only the memory across a reload is lost.
    const held = createPromotedStore(null)
    held.set(['a'])
    expect(held.get()).toEqual(['a'])
  })
})

/* ------------------------------------------------ the gesture, and not it -- */

describe('a strip tab', () => {
  const long = 'Update Claude Code terminal to new API'
  const tabs: WorkspaceTab[] = [
    { ...session('a', long), projectPath: '/Users/apple/Projects/terminaldeck' },
    { ...session('b', 'terminaldeck'), projectPath: '/Users/apple/Projects/terminaldeck' },
  ]
  const html = renderToStaticMarkup(
    <WorkspaceTabStrip
      tabs={tabs}
      activeTabId="a"
      onSelect={() => undefined}
      onClose={() => undefined}
      storage={store({ 'terminaldeck.strip.promoted': '["a","b"]' })}
    />,
  )

  it('cuts a long title in the middle rather than at the end', () => {
    expect(html).toContain(middleEllipsis(long, STRIP_LABEL_BUDGET))
    expect(html).not.toContain(`>${long}<`)
  })

  it('carries the whole title and the folder in its tooltip', () => {
    // The tab is 220px wide; this is where the rest of the answer lives.
    expect(html).toContain('title="Update Claude Code terminal to new API')
    expect(html).toContain('/Users/apple/Projects/terminaldeck"')
  })

  it('calls an unnamed session what the sidebar calls it', () => {
    expect(html).toContain('>Session 2<')
    expect(html).not.toContain('>terminaldeck<')
  })

  it('is draggable, and says which one is in hand to nobody but CSS', () => {
    // `data-dragging` is set from an event this renderer never fires; what is
    // pinned here is that the attribute is absent at rest, so a tab is not born
    // looking like it is being dragged.
    expect(html).toContain('draggable="true"')
    expect(html).not.toContain('data-dragging')
  })
})

/* ----------------------------------------- the same thing, without a drag -- */

describe('promoting from the sidebar', () => {
  const noop = (): void => {}
  const projects = [{ path: '/Users/apple/Projects/terminaldeck', name: 'terminaldeck' }]
  const tabs: WorkspaceTab[] = [
    { ...session('a', 'Fix the login redirect'), projectPath: projects[0].path },
    { ...session('b', 'terminaldeck'), projectPath: projects[0].path },
  ]

  function rail(disk: Storage, extra: { onNewSessionOptions?: () => void } = {}): string {
    return renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={tabs}
        activeTabId="a"
        activePanel={null}
        storage={disk}
        {...extra}
        onSelectTab={noop}
        onCloseTab={noop}
        onSelectPanel={noop}
        onNewSession={noop}
        onNewBrowserTab={noop}
        onOpenProject={noop}
        onCloseProject={noop}
        onOpenSettings={noop}
        onToggleCollapsed={noop}
        onPeekStart={noop}
        onPeekEnd={noop}
        onStartResize={noop}
      />,
    )
  }

  it('offers every open window a way up that is not a gesture', () => {
    /*
     * A drag is invisible until somebody tries it and impossible without a
     * mouse, and it was the only route into the strip. This button is both
     * halves of that: the row's hover controls are revealed by
     * `:focus-within` as well as `:hover`, so it is reachable by Tab.
     */
    const html = rail(store())
    expect(html).toContain('aria-label="Show Fix the login redirect at the top"')
    expect(html.match(/class="sb-row-action sb-promote"/g)).toHaveLength(2)
  })

  it('reads its pressed state off the same order the strip draws', () => {
    // The failure this rules out is the one that makes assistive tech lie: a
    // toggle with private state, next to a strip with its own.
    const disk = store({ 'terminaldeck.strip.promoted': '["a"]' })
    const html = rail(disk)
    expect(html).toContain('aria-pressed="true"')
    expect(html.match(/aria-pressed="true"/g)).toHaveLength(1)
    expect(html).toContain('aria-label="Fold Fix the login redirect back into the sidebar"')
  })

  it('refuses rather than silently dropping a tab off the far end', () => {
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    const disk = store({ 'terminaldeck.strip.promoted': JSON.stringify(full) })
    const html = rail(disk)
    // Disabled and saying why, because `promote` past the cap is a no-op and a
    // button that does nothing when pressed is indistinguishable from a bug.
    expect(html).toMatch(/class="sb-row-action sb-promote"[^>]*disabled/)
    expect(html).toContain(`The top strip is full (${MAX_PROMOTED})`)
    // And live again the moment there is room, rather than staying dead.
    expect(rail(store())).not.toMatch(/class="sb-row-action sb-promote"[^>]*disabled/)
  })

  it('carries a drag image that is a tab, not a photograph of the row', () => {
    // The node `setDragImage` is handed. Off-screen rather than hidden: both
    // `display: none` and a negative z-index make the browser fall back to its
    // own ghost of the 264px row, which is the look this replaced.
    expect(rail(store())).toContain('class="tab-ghost"')
  })

  it('offers the options dialog beside New session, but only once wired', () => {
    /*
     * Pressing New session spawns immediately — deliberately; the dialog that
     * used to stand in front of ⌘T was taken away on purpose. What was missing
     * is any route *from here* to the panel that names the folder and the
     * agent, which lives behind a command-palette entry.
     *
     * Absent rather than inert when no host wired it: this component cannot
     * open a dialog mounted in `App.tsx`, and a chevron that does nothing is
     * the thing this app calls a fake feature.
     */
    expect(rail(store())).not.toContain('sb-new-more')
    expect(rail(store(), { onNewSessionOptions: noop })).toContain(
      'aria-label="New session with options"',
    )
  })
})
