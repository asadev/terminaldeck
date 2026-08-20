import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  isTabDrag,
  middleEllipsis,
  readTabDrag,
  startTabDrag,
  STRIP_LABEL_BUDGET,
  tabIcon,
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
  defaultStorage,
  demote,
  dropIndex,
  keepBesideInStrip,
  keepInStrip,
  keepNewWindowInStrip,
  keepWindowBesideInStrip,
  MAX_PROMOTED,
  promote,
  promotedStore,
  pruneOrder,
  readPromoted,
  removeFromStrip,
  replaceInStrip,
  replaceWindowInStrip,
  shownTabs,
  stripIsPresent,
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

/** A browser window — the only kind of tab that draws a ✕ since 2026-08-20. */
function page(id: string, label = id): WorkspaceTab {
  return { id, kind: 'browser', label, closable: true }
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
  /**
   * The bug this grew a third argument for, reproduced as a unit.
   *
   * Promote five sessions, reload the renderer, and one of them is gone from the
   * strip for good — measured four times out of four in the running app, with
   * the write caught in the act: one `setItem` during the load, four ids where
   * storage had five, at a moment the sidebar had drawn no rows at all.
   *
   * A reload does not restore the session list in one step. The renderer comes
   * up empty, asks the main process which ptys are alive, and fills in as the
   * answers land — so for a few frames `tabs` is a partial view. Pruning against
   * a partial view deletes what has not arrived, and the result goes straight to
   * storage.
   */
  it('does not forget a tab that has simply not arrived yet', () => {
    const seen = new Set(['a'])
    // Mid-restore: only `a` has been added so far, and the window has never laid
    // eyes on `b` or `c`. Neither is closed; both are on their way.
    expect(pruneOrder(['a', 'b', 'c'], [session('a')], seen)).toEqual(['a', 'b', 'c'])
  })

  it('forgets a tab once this window has watched it close', () => {
    // `b` was here and is not any more. That is a closure, and the whole point
    // of pruning.
    expect(pruneOrder(['a', 'b'], [session('a')], new Set(['a', 'b']))).toEqual(['a'])
  })

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
  it('draws the tab you are in even when nothing has been promoted', () => {
    /*
     * The defect from the frames: *the title bar names a session that has no
     * tab in the strip*. Both halves were individually right — the heading names
     * what you are in, the strip holds what you dragged there — but they are
     * stacked at the top of one window, so read together they contradicted each
     * other. The strip is the half that can give.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={OPEN} activeTabId="a" onSelect={() => undefined} storage={store()} />,
    )
    expect(html).not.toContain('Drag a session or a page here')
    expect(html).toContain('aria-selected="true"')
    expect(html.match(/aria-selected="true"/g)).toHaveLength(1)
    // And only that one: a strip is not a second copy of the sidebar.
    expect(html.match(/data-strip-tab/g)).toHaveLength(1)
  })

  it('marks the tab you are only visiting, and carries no control for it', () => {
    /*
     * A transient tab is still marked — it is here because you are in it and
     * will be gone when you leave — but the button that used to offer to keep
     * it is gone, and by name: *"the arrow inside the pill also doesn't need to
     * be there, because we will not move windows down to the side panel from
     * there."* The rail's own arrow is the way up, and it is a better one: it
     * is on the list of everything that is open rather than only on the handful
     * that happen to be on the bar.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        storage={store()}
      />,
    )
    expect(html).toContain('data-transient="true"')
    expect(html).not.toContain('Keep api along the top')
    expect(html).not.toContain('aria-pressed')
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

  it('draws a ✕ on a session tab that only takes it off the bar', () => {
    /*
     * The correction of 2026-08-20, after a first pass deleted this control
     * outright: *"from the windows it should be able to close it, but at least
     * from the top bar… for the sessions it will just close from the top bar,
     * but it will still stay in the side panel."*
     *
     * What is pinned is the pair of things that make it safe. It is **not**
     * marked `[data-ends]` — that attribute is the whole of the stylesheet's
     * difference between the ✕ that destroys and the ✕ that tidies — and its
     * title names the act in three words rather than explaining it, because the
     * standing rule this round is no prose on screen.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        onShowInstead={() => undefined}
        onCloseWindow={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a"]' })}
      />,
    )
    expect(html.match(/strip-tab-close/g)).toHaveLength(1)
    expect(html).toContain('title="Take off the bar"')
    expect(html).toContain('aria-label="Take api off the bar"')
    // Nothing on this bar closes a session, so nothing on it says it does.
    expect(html).not.toMatch(/aria-label="[^"]*[Cc]lose/)
    expect(/<button[^>]*class="strip-tab-close"[^>]*>/.exec(html)?.[0]).not.toContain('data-ends')
  })

  it('draws the two ✕s so that they cannot be read as the same control', () => {
    /*
     * The whole hazard, in one render: two identical glyphs a centimetre apart,
     * one of which throws away the page you were reading and one of which tidies
     * a tab. *"for the windows it will completely close, and for the sessions it
     * will just close from the top bar."*
     *
     * They are told apart by the mark and by the words, and both are asserted
     * here rather than in two places, because the assertion that matters is the
     * *contrast* — either one alone reads as fine.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), page('b1', 'New tab')]}
        activeTabId="a"
        onSelect={() => undefined}
        onShowInstead={() => undefined}
        onCloseWindow={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b1"]' })}
      />,
    )
    const buttons = html.match(/<button[^>]*class="strip-tab-close"[^>]*>/g) ?? []
    expect(buttons).toHaveLength(2)
    // In tab order: the session first, then the page.
    expect(buttons[0]).not.toContain('data-ends')
    expect(buttons[0]).toContain('title="Take off the bar"')
    // `[data-ends]` is what the stylesheet paints `--color-critical` on: this
    // one destroys something, so it wears the window's mark for that.
    expect(buttons[1]).toContain('data-ends=""')
    expect(buttons[1]).toContain('title="Close this page"')
    expect(html).toContain('aria-label="Close New tab"')
    // No sentence on either. The reasoning lives in the source, not on screen.
    expect(html).not.toContain('top bar. It keeps running')
  })

  it('has no handler through which a session ✕ could end anything', () => {
    /*
     * The strongest form the rule can take, and the reason it is asserted
     * against the source rather than against markup: a rendered strip can only
     * show what the ✕ *says*, and the failure being guarded is one where it says
     * the right thing and calls the wrong function.
     *
     * `onEndRemote` is named because it is the one that did. It took a press on
     * a pill up here and ended the session on the machine it was running on, and
     * it was deleted rather than reworded when Asad settled that the top bar
     * demotes and the sidebar deletes. A prop declaration is how it would come
     * back, so a prop declaration is what this looks for — the word may still
     * appear in the prose explaining its absence.
     */
    const source = readFileSync(join(__dirname, 'WorkspaceTabStrip.tsx'), 'utf8')
    expect(source).not.toMatch(/onEndRemote\??\s*[(?:]/)
    // And the one handler a session tab does reach only moves the selection.
    expect(source).toMatch(/onClick=\{\(\) => removeTab\(tab\.id\)\}/)
  })

  it('draws no ✕ where the host cannot finish the act', () => {
    // Absent rather than inert, on both kinds — a test or a board mounting this
    // bare gets no control at all instead of one that swallows the press.
    //
    // For the session that hangs on `onShowInstead`, which is not decoration:
    // taking the tab you are *looking at* off the bar is the ordinary press, and
    // without it the strip redraws that tab as transient and the press appears
    // to do nothing.
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), page('b1', 'New tab')]}
        activeTabId="b1"
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b1"]' })}
      />,
    )
    expect(html).not.toContain('strip-tab-close')
  })

  it('renders with no storage at all rather than throwing', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={OPEN} activeTabId={null} onSelect={() => undefined} storage={null} />,
    )
    expect(html).toContain('Drag a session or a page here')
  })

  it('has no ＋ on a tab, and two icons after the last one instead', () => {
    /*
     * *"Pills of the windows will not show that plus button inside. There will
     * be a terminal and browser globe icon next to the last window. Whatever
     * the icon we click accordingly it will open the next window."*
     *
     * The ＋ that was on every tab is gone with the menu it needed — one target
     * offering two commands is a menu, two targets are not — and so is the
     * per-tab placement it existed for. What is left is one press per kind of
     * window, at the end of the row.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), session('b', 'web')]}
        activeTabId="a"
        onSelect={() => undefined}
        onNewSession={() => undefined}
        onNewBrowserTab={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b"]' })}
      />,
    )
    expect(html).not.toContain('aria-haspopup="menu"')
    expect(html).not.toContain('Open something next to this tab')
    expect(html).toContain('aria-label="New session"')
    expect(html).toContain('aria-label="New browser tab"')
    // One pair for the whole bar, not one pair per tab — which is the same
    // count mistake the ＋ made in the other direction.
    expect(html.match(/class="strip-open"/g)).toHaveLength(2)
    // After the last tab, and — since 2026-08-20 — *outside the scroll box*.
    // See the test below, which is the whole of what he asked for here.
    expect(html.indexOf('strip-openers')).toBeGreaterThan(html.lastIndexOf('data-strip-tab'))
  })

  it('pins the openers in the corner, outside the rail that scrolls', () => {
    /*
     * *"these two buttons to start new session and new window are like coming
     * above the tab. So they should be always in the corner and whenever we
     * start new, these will become smaller."* — 2026-08-20.
     *
     * They used to be the last child of `.strip-rail`, which is the element
     * that scrolls. So on a full bar they scrolled with the tabs and came to
     * rest on top of the last tab's name, which is the frame he stopped on.
     *
     * Asserted as *markup structure* rather than as a rendered position,
     * because there is no layout engine here and because the structure is what
     * the behaviour follows from: a control that is a sibling of the scroll box
     * cannot scroll with its contents, whatever the stylesheet later says. The
     * shrinking half is the stylesheet's and is pinned in `finish.test.ts`.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), session('b', 'web')]}
        activeTabId="a"
        onSelect={() => undefined}
        onNewSession={() => undefined}
        onNewBrowserTab={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b"]' })}
      />,
    )
    // The rail closes before the openers open: `</div>` for `.strip-rail` has to
    // fall between the last tab and `strip-openers`, which is only true when the
    // openers are outside it.
    const lastTab = html.lastIndexOf('data-strip-tab')
    const openers = html.indexOf('strip-openers')
    expect(openers).toBeGreaterThan(lastTab)
    /*
     * Three closing tags, not two, and the third one is the whole assertion.
     * The last tab closes, then `.strip-list`, then `.strip-rail` — and only
     * then do the openers open. With them back inside the rail there would be
     * two, because the rail would still be open when they started.
     */
    const between = html.slice(lastTab, openers)
    expect(
      between.match(/<\/div>/g)?.length ?? 0,
      'the openers are back inside the scrolling rail',
    ).toBe(3)
    // And the corner survives the empty bar, where somebody most wants to start
    // something — `.strip-empty` has no rail at all, so this is a second shape.
    const empty = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId={null}
        onSelect={() => undefined}
        onNewSession={() => undefined}
        onNewBrowserTab={() => undefined}
        storage={store()}
      />,
    )
    expect(empty).toContain('strip-openers')
  })

  it('draws neither opener the host has not wired', () => {
    // The rule the whole window holds itself to: absent, not dead. Nothing in
    // this component can open a session — the dialog is mounted in `App.tsx`.
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        storage={store()}
      />,
    )
    expect(html).not.toContain('strip-open')
    expect(html).not.toContain('strip-openers')
  })

  it('keeps both openers on a bar with nothing on it', () => {
    /*
     * A host that says `activeTabId: null` while something is open. Taking the
     * last tab off with its ✕ does not produce this — `removeFromStrip` answers
     * `select: null` and `App.tsx` resolves that to the first open tab, so the
     * window keeps showing a session and this bar keeps showing its tab. What
     * is pinned here is that the state is still usable when it does occur: an
     * empty bar is exactly where somebody wants to start something.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={OPEN}
        activeTabId={null}
        onSelect={() => undefined}
        onNewSession={() => undefined}
        onNewBrowserTab={() => undefined}
        storage={store()}
      />,
    )
    expect(html).toContain('Drag a session or a page here')
    expect(html.match(/class="strip-open"/g)).toHaveLength(2)
  })

  it('draws exactly one reveal button, and only while the rail is away', () => {
    /*
     * The strip is the window's top band now, so the traffic lights land on it
     * and the control that brings a pinned-away rail back belongs here.
     * `WindowToolbar` gives its copy up in exactly this case — see its
     * `underStrip` prop — because two of them, 48px apart in the same corner,
     * is worse than either.
     */
    const away = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        sidebarHidden
        onRevealSidebar={() => undefined}
        storage={store()}
      />,
    )
    expect(away.match(/aria-label="Show sidebar"/g)).toHaveLength(1)
    expect(away).toContain('data-sidebar-collapsed="true"')

    const out = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        onSelect={() => undefined}
        onRevealSidebar={() => undefined}
        storage={store()}
      />,
    )
    expect(out).not.toContain('Show sidebar')
    expect(out).not.toContain('data-sidebar-collapsed')
  })

  it('scrolls the tab you are in into view, and only sideways', () => {
    /*
     * A DOM behaviour in a project with no DOM in its tests, so this is read out
     * of the source the way `wiring.test.ts` and `finish.test.ts` read files for
     * the claims a rendered string cannot show. What it is guarding is small and
     * was measured in the running app: six tabs on a 1440px window, the heading
     * reading "Session 3", and the tab of that name past the right edge — the
     * strip and the title agreeing about a tab nobody can see.
     *
     * `block: 'nearest'` is the load-bearing half. `scrollIntoView` walks every
     * scrollable ancestor, and the pane under this bar is one, so the default
     * vertical alignment would scroll the *window* to bring a tab into view.
     */
    const source = readFileSync(join(__dirname, 'WorkspaceTabStrip.tsx'), 'utf8')
    expect(source).toContain('scrollIntoView(')
    expect(source).toContain("block: 'nearest', inline: 'nearest'")
    // Keyed on the selection, not the tab list: scrolling the strip by hand to
    // look at something else must not be undone by the next render.
    expect(source).toMatch(/scrollIntoView[\s\S]{0,80}\}, \[selectedId\]\)/)
  })

  it('stops claiming a tab is selected while a view is covering the window', () => {
    /*
     * Overview filling the pane, its name in the bar below, and a highlighted
     * "Session 1" still lit up top: that is the two halves of the chrome
     * disagreeing about what is on screen, which is the same defect as a title
     * bar naming a session with no tab. The tab stays drawn — it is what you
     * will come back to, and a strip that emptied itself on every glance at
     * Files would shuffle under the pointer — it just stops being selected.
     */
    const covered = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api')]}
        activeTabId="a"
        covered
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a"]' })}
      />,
    )
    expect(covered).toContain('api')
    expect(covered).not.toContain('aria-selected="true"')
    expect(covered).not.toContain('data-active="true"')
  })

  it('tells two tabs with the same name apart by their project', () => {
    /*
     * `Session 1  Session 2  Session 1  Session 2` — read off his own screen.
     * Two projects, each with an unnamed first session, and a strip with no
     * headings to qualify them. The project is what differs, so the project is
     * what gets printed, and only on the tabs that collide.
     */
    const tabs: WorkspaceTab[] = [
      { id: 'a', kind: 'session', label: '', projectPath: '/w/app', closable: true },
      { id: 'b', kind: 'session', label: '', projectPath: '/w/site', closable: true },
    ]
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={tabs}
        activeTabId="a"
        onSelect={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b"]' })}
      />,
    )
    expect(html.match(/class="strip-tab-label">Session 1</g)).toHaveLength(2)
    expect(html).toContain('class="strip-tab-qualifier">app<')
    expect(html).toContain('class="strip-tab-qualifier">site<')
  })
})

describe('where the arrangement is kept', () => {
  /**
   * Session storage, not local, and the lifetime is the whole argument.
   *
   * A promoted id names a pty in *this* main process. Quit the app and every one
   * of them names nothing for ever — so a `localStorage` order accumulates twelve
   * dead ids per run, and `promote` counts them against its cap: two runs and the
   * strip looks empty and silently refuses everything. Session storage is cleared
   * when the app goes, and survives the thing that actually matters, which is a
   * renderer reload with every pty still running. Verified in the app itself:
   * written, reloaded, read back.
   */
  it('defaults to the storage that dies with the app', () => {
    /*
     * Read from the source, because this test process has no `window` at all —
     * `defaultStorage()` answers null here whichever storage it names, so an
     * assertion on its return value would pass on the wrong answer. The body is
     * two lines and the claim is which global it reaches for.
     */
    const source = readFileSync(join(__dirname, 'workspace-strip.ts'), 'utf8')
    const body = /export function defaultStorage\(\)[\s\S]*?\n\}/.exec(source)?.[0] ?? ''
    expect(body, 'defaultStorage has changed shape').not.toBe('')
    expect(body).toContain('window.sessionStorage')
    expect(body).not.toContain('window.localStorage')
  })

  it('still answers null where there is no window, rather than throwing', () => {
    // The guard is a try/catch and not a `typeof` test alone: reading the
    // property itself can throw where storage is disabled by policy.
    expect(defaultStorage()).toBeNull()
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

  it('becomes the window’s top band the moment something is open', () => {
    /*
     * Through `session()` like every other fixture in this file, rather than an
     * object literal of its own. The literal that was here named a `title` field
     * — `WorkspaceTab` has `label` — and left out `closable`, so it compiled to
     * nothing the component could have rendered. Vitest never noticed because it
     * does not typecheck; `npm run typecheck` did.
     */
    const tabs: WorkspaceTab[] = [session('s1', 'Session 1')]
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={tabs} activeTabId="s1" onSelect={() => {}} storage={null} />,
    )
    expect(html).toContain('Session 1')
    expect(stripIsPresent(tabs)).toBe(true)
    expect(stripIsPresent([])).toBe(false)
  })
})

describe('shownTabs', () => {
  /**
   * What the strip draws: what you kept, plus what you are in.
   *
   * The second half is the fix for "the title bar names a session that has no
   * tab in the strip", and the first half is what stops that fix turning the
   * strip into a second sidebar.
   */
  it('is the promoted set, in the promoted order, when the active tab is in it', () => {
    expect(shownTabs(['b', 'a'], OPEN, 'a').map((entry) => entry.tab.id)).toEqual(['b', 'a'])
    expect(shownTabs(['b', 'a'], OPEN, 'a').every((entry) => entry.promoted)).toBe(true)
  })

  it('adds the active tab when it is not promoted, and marks it transient', () => {
    const shown = shownTabs(['b'], OPEN, 'c')
    expect(shown.map((entry) => entry.tab.id)).toEqual(['b', 'c'])
    expect(shown.map((entry) => entry.promoted)).toEqual([true, false])
  })

  it('appends it rather than pushing into the arrangement somebody made', () => {
    // The promoted order is a hand-made thing. A transient tab that inserted
    // itself in the middle would move the tabs the user placed, every time they
    // clicked a row in the sidebar.
    expect(shownTabs(['a', 'b'], OPEN, 'c').map((entry) => entry.tab.id)).toEqual(['a', 'b', 'c'])
  })

  it('adds nothing for an id that names no open window', () => {
    // A stale id from a previous run's storage, or a session that has just
    // exited. Resolved against the live list like everything else here.
    expect(shownTabs(['a'], OPEN, 'gone').map((entry) => entry.tab.id)).toEqual(['a'])
    expect(shownTabs(['a'], OPEN, null).map((entry) => entry.tab.id)).toEqual(['a'])
  })

  it('is empty only when nothing is promoted and nothing is active', () => {
    expect(shownTabs([], OPEN, null)).toEqual([])
    expect(shownTabs([], OPEN, 'a')).toHaveLength(1)
  })
})

/* ------------------------------------- taking a tab off, and not closing -- */

describe('removeFromStrip', () => {
  /**
   * The ✕ on a tab, and the whole of what it may and may not do.
   *
   * *"It should not delete the session… side panel will have everything inside,
   * and above we just set a view which one we want to see."* So this function
   * has exactly two outputs and neither of them is a session: an arrangement,
   * and — only when the tab being removed is the one on screen — what to look
   * at instead. Nothing here can reach a pty, which is the strongest form the
   * guarantee can take: the tab's ✕ is wired to this and to nothing else, so it
   * *cannot* end a session however it is called.
   */
  it('takes the tab out of the arrangement and leaves the window alone', () => {
    const result = removeFromStrip(['a', 'b', 'c'], OPEN, 'b', 'a')
    expect(result.order).toEqual(['a', 'c'])
    // Not `null` — `undefined`, which means "do not touch the selection". A
    // `null` here would blank the pane every time somebody tidied their bar.
    expect(result.select).toBeUndefined()
  })

  it('leaves every session open and listed', () => {
    /*
     * Stated as an assertion rather than left implicit, because it is the
     * behaviour he asked for and the one a future refactor is most likely to
     * "fix". The tab list is the app's inventory of what is running; this
     * function is pure and returns no new one, so the same three sessions are
     * open after the removal as before it.
     */
    const before = OPEN.map((tab) => tab.id)
    const result = removeFromStrip(['a', 'b'], OPEN, 'a', null)
    expect(OPEN.map((tab) => tab.id)).toEqual(before)
    expect(result.order).toEqual(['b'])
    expect(OPEN.some((tab) => tab.id === 'a')).toBe(true)
  })

  it('moves to the right-hand neighbour when it removes the tab you are in', () => {
    // Otherwise the tab does not go away: `shownTabs` always draws the active
    // tab, so it would come straight back as a transient one and the press
    // would look like it had failed.
    expect(removeFromStrip(['a', 'b', 'c'], OPEN, 'a', 'a')).toEqual({
      order: ['b', 'c'],
      select: 'b',
    })
  })

  it('falls to the left when there is nothing to the right', () => {
    expect(removeFromStrip(['a', 'b'], OPEN, 'b', 'b')).toEqual({ order: ['a'], select: 'a' })
  })

  it('chooses from the bar, not from everything that is open', () => {
    // `c` is running and has never been promoted. Pulling it up here would be
    // the strip putting a tab back the moment one was taken off.
    expect(removeFromStrip(['a'], OPEN, 'a', 'a')).toEqual({ order: [], select: null })
  })

  it('empties the bar rather than refusing the last tab', () => {
    /*
     * `null` is a real answer. Every tab can come off — the sessions are all
     * still in the rail — and the window falls back to its empty view, which is
     * exactly what he described the top bar as being: a set of views you choose,
     * not the list of what exists.
     */
    const result = removeFromStrip(['a'], [OPEN[0]], 'a', 'a')
    expect(result.order).toEqual([])
    expect(result.select).toBeNull()
  })

  it('handles the tab that is only there because you are looking at it', () => {
    // A transient tab is in no arrangement to be removed from, so the press is
    // entirely a change of selection — to whatever is actually pinned up there.
    expect(removeFromStrip(['b'], OPEN, 'c', 'c')).toEqual({ order: ['b'], select: 'b' })
  })

  it('skips a promoted id whose window has already gone', () => {
    // The order outlives a closed session by design; `stripTabs` resolves it on
    // every render. The neighbour has to be resolved the same way or the ✕
    // selects a tab that is not on screen.
    expect(removeFromStrip(['a', 'gone', 'b'], OPEN, 'a', 'a').select).toBe('b')
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

  it('calls the copilot by its name, never Session N', () => {
    /*
     * The copilot is a session, and its title is the name of its own folder —
     * which is exactly the case `sessionLabel` turns into "Session 1". So
     * without the rule in `tabLabel` the pinned row in the rail would read
     * "Nova" and the pill three centimetres above it would read "Session 3",
     * for one window. That is the same defect `tabIdentities` prevents between
     * two different tabs; it would be worse coming from one.
     *
     * The name is user data — somebody typed it into the setup flow and it
     * lives in the copilot's own instruction file — so `App.tsx` puts it on the
     * tab and this function reads it from there. The label is *not* the folder
     * name for this tab, and that is the difference from every other session.
     */
    const copilotTab: WorkspaceTab = {
      id: 'cp',
      kind: 'session',
      label: 'Nova',
      projectPath: '/Users/apple/Library/Application Support/terminaldeck/copilot',
      isCopilot: true,
      closable: true,
    }
    const tabs = [inProject('a', 'terminaldeck'), copilotTab]
    expect(tabLabel(copilotTab, tabs)).toBe('Nova')
    // And it is not counted as a sibling of anything: the session beside it is
    // still Session 1.
    expect(tabLabel(tabs[0], tabs)).toBe('Session 1')
  })

  it('falls back to this app’s word for a copilot nobody has named', () => {
    /*
     * A tab assembled without a name — a test, the harness, or a window whose
     * read of the instruction file has not landed — must not draw an empty pill.
     * `COPILOT_NAME` is what is left, and it is a description rather than a
     * name: `shared/copilot-identity.ts` says why the two are different things.
     */
    const unnamed: WorkspaceTab = { id: 'cp', kind: 'session', label: '', isCopilot: true, closable: true }
    expect(tabLabel(unnamed, [unnamed])).toBe('Copilot')
  })
})

describe('tabIcon', () => {
  it('gives the copilot its own mark and everything else its kind\u2019s', () => {
    // One of a kind, in a row of `>_` glyphs. Drawn with the same compass the
    // pinned row wears, from the same constant, so the row and the pill are
    // recognisably one thing rather than two features with one name.
    const plain = session('a')
    const page: WorkspaceTab = { id: 'p', kind: 'browser', label: 'x', closable: true }
    expect(tabIcon({ ...plain, isCopilot: true })).not.toBe(tabIcon(plain))
    expect(tabIcon(plain)).not.toBe(tabIcon(page))
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

  function rail(disk: Storage): string {
    return renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={projects}
        tabs={tabs}
        activeTabId="a"
        activePanel={null}
        storage={disk}
        onSelectTab={noop}
        onCloseTab={noop}
        onSelectPanel={noop}
        onNewSession={noop}
        onNewBrowserTab={noop}
        onOpenProject={noop}
        onCloseProject={noop}
        onOpenSettings={noop}
        onOpenAlerts={noop}
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
     * mouse, and it was the only route into the strip. The row's ⋯ menu is both
     * halves of that: the hover controls are revealed by `:focus-within` as well
     * as `:hover`, so it is reachable by Tab, and the entry inside it says the
     * placement in words instead of asking the reader to recognise an arrow.
     *
     * It was a button of its own until 2026-08-20 — *"instead of these two
     * buttons, give … one three-dot button"* — so what is asserted here is that
     * every open window still has a route up, one per row, rather than that a
     * particular glyph is on screen.
     */
    const html = rail(store())
    expect(html).toContain('aria-label="More for Fix the login redirect"')
    expect(html.match(/class="sb-row-action sb-more"/g)).toHaveLength(2)
  })

  it('reads its state off the same order the strip draws', () => {
    /*
     * The failure this rules out is the one that makes assistive tech lie: a
     * toggle with private state, next to a strip with its own. The toggle is a
     * menu entry now and the menu is native, so the check moved down one level
     * — to the value the row hands the menu, which is read from `promotedOrder`
     * in the same frame the strip reads it.
     */
    const source = readFileSync(join(__dirname, '..', 'shell', 'Sidebar.tsx'), 'utf8')
    expect(source).toContain('const promoted = promotedOrder.includes(tab.id)')
    expect(source).toContain('promoted,')
    // And the menu says which of the two it is offering, in words.
    const menu = readFileSync(join(__dirname, '..', '..', 'main', 'session-row-menu.ts'), 'utf8')
    expect(menu).toContain("request.promoted ? 'Fold back into the sidebar' : 'Show at the top'")
  })

  it('refuses rather than silently dropping a tab off the far end', () => {
    /*
     * Disabled and saying why, because `promote` past the cap is a no-op and an
     * entry that does nothing when chosen is indistinguishable from a bug. The
     * reason travels as the sentence itself rather than as a boolean, so the
     * menu has no wording of its own to keep in step with the cap.
     */
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    const disk = store({ 'terminaldeck.strip.promoted': JSON.stringify(full) })
    // The rail still renders with the cap reached; the refusal is inside the
    // menu it opens, not on the row.
    expect(rail(disk)).toContain('class="sb-row-action sb-more"')
    const source = readFileSync(join(__dirname, '..', 'shell', 'Sidebar.tsx'), 'utf8')
    expect(source).toContain('stripFull ? `The top strip is full (${MAX_PROMOTED})` : null')
    const menu = readFileSync(join(__dirname, '..', '..', 'main', 'session-row-menu.ts'), 'utf8')
    expect(menu).toContain('enabled: request.promoted || !request.promoteBlocked')
  })

  it('carries a drag image that is a tab, not a photograph of the row', () => {
    // The node `setDragImage` is handed. Off-screen rather than hidden: both
    // `display: none` and a negative z-index make the browser fall back to its
    // own ghost of the 264px row, which is the look this replaced.
    expect(rail(store())).toContain('class="tab-ghost"')
  })

  it('has one New session button and no second half to it', () => {
    /*
     * *"Remove this drop-down button at all from the side panel."*
     *
     * The chevron was the second half of a split control: press for a session,
     * press the chevron to be asked. Both halves started a session, in two
     * different ways, one pixel apart — and the one that did not ask was the
     * default. The button asks now, so the chevron has nothing left to offer,
     * and this line is what stops it coming back.
     */
    const html = rail(store())
    expect(html).not.toContain('sb-new-more')
    expect(html).not.toContain('New session with options')
    // Two actions on that line and no more: the session, and the globe.
    expect(html.match(/class="sb-new"/g)).toHaveLength(1)
    expect(html.match(/class="sb-new-alt"/g)).toHaveLength(1)
  })

  it('warns on the rail’s close that it ends the session, which the tab’s ✕ does not', () => {
    /*
     * The pair, checked as a pair, because neither half means anything on its
     * own. The rail's is the control that kills a pty; the strip's takes the tab
     * off the bar and leaves everything running. They are two panels apart and
     * they are both a way of getting rid of a session tab, so the difference has
     * to be in the words — and, on the strip's side, in the mark it refuses to
     * wear.
     */
    const source = readFileSync(join(__dirname, '..', 'shell', 'Sidebar.tsx'), 'utf8')
    // The ✕ became a menu entry, and the entry is the sentence — see
    // `closeSentence`. A native menu is not in this document, so the assertion
    // reads the words where they are now written.
    expect(source).toContain('ends the session`')

    const strip = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={tabs}
        activeTabId="a"
        onSelect={noop}
        onShowInstead={noop}
        storage={store({ 'terminaldeck.strip.promoted': '["a"]' })}
      />,
    )
    // The strip's answer says the opposite thing, and says nothing about ending.
    expect(strip).toContain('title="Take off the bar"')
    expect(strip).not.toContain('ends the session')
    expect(strip).not.toContain('data-ends')
  })
})

/* --------------------------------------- a window you opened stays opened -- */

/**
 * *"if I open any new session and any new browser from the header, it should
 * automatically open in the top bar, in the top header, come next to it in the
 * top there. If I want to remove it from there and keep only side panel, I
 * should have to do it myself specifically."*
 *
 * Both halves of that are one requirement, and the second half is the one that
 * was failing in a way a screenshot could not show. The new session *did*
 * appear on the bar before this — `shownTabs` draws the tab you are looking at
 * whether or not it was promoted — so the press looked right and the tab was
 * gone the next time you clicked a different one. What these pin is that it is
 * **kept**: in the order, at the end, and leaving only when its ✕ is pressed.
 */
describe('keeping a window that was just opened', () => {
  it('puts it at the end, after every tab already there', () => {
    expect(keepInStrip(['a', 'b'], 'c')).toEqual(['a', 'b', 'c'])
    // *"come next to it in the top there"* — the end of the row, which is
    // exactly where the openers that started it are drawn.
    expect(keepInStrip([], 'a')).toEqual(['a'])
  })

  it('leaves a tab that is already kept exactly where the user put it', () => {
    /*
     * Not `promote(order, id, order.length)`, which would move it. Re-anchoring
     * a tab somebody dragged into position, in response to anything that is not
     * another drag, is the strip rearranging itself — the one thing the model
     * at the top of `workspace-strip.ts` says it must never do.
     */
    expect(keepInStrip(['a', 'b', 'c'], 'a')).toEqual(['a', 'b', 'c'])
  })

  it('does not mutate the order it was handed', () => {
    const order = ['a', 'b']
    keepInStrip(order, 'c')
    expect(order).toEqual(['a', 'b'])
  })

  it('refuses past the cap rather than evicting a tab the user kept', () => {
    /*
     * The same bargain a drop strikes. The new window is not lost — it is the
     * active tab, so `shownTabs` draws it as transient — but a bar that threw
     * away one of your twelve to make room for a thirteenth would be destroying
     * an arrangement in order to honour a press about something else.
     */
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    expect(keepInStrip(full, 'extra')).toEqual(full)
    expect(shownTabs(keepInStrip(full, 'extra'), [session('extra')], 'extra')).toEqual([
      { tab: session('extra'), promoted: false },
    ])
  })

  it('writes through the store the strip is rendering from', () => {
    /*
     * The half that makes it visible. Every window in this app is opened from
     * an event handler, which cannot read `usePromotedOrder`; this is the seam
     * between those handlers and the component, and a version of it that
     * updated a local copy would pass every test above while changing nothing
     * on screen.
     */
    const backing = store({ 'terminaldeck.strip.promoted': '["a"]' })
    keepNewWindowInStrip('b', backing)
    expect(promotedStore(backing).get()).toEqual(['a', 'b'])
    expect(readPromoted(backing)).toEqual(['a', 'b'])
  })

  it('survives a window with no storage at all', () => {
    // `defaultStorage()` answers null under policy-disabled storage and in
    // every test process here. Losing the arrangement on the next reload is a
    // cost; throwing inside the handler that opens a session is a broken app.
    expect(() => keepNewWindowInStrip('a', null)).not.toThrow()
  })

  it('draws the new tab as kept and last, not as one you are merely visiting', () => {
    /*
     * The whole point, seen from the markup. `data-transient` is the italic
     * that says "provisional" — its presence on a session the user just started
     * is precisely the defect, so this asserts the tab is there *and* that the
     * mark is not.
     */
    const tabs = [session('a', 'Session 1'), session('b', 'Session 2')]
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={tabs}
        activeTabId="b"
        onSelect={() => undefined}
        storage={store({
          'terminaldeck.strip.promoted': JSON.stringify(keepInStrip(['a'], 'b')),
        })}
      />,
    )
    expect(html).toContain('>Session 2<')
    expect(html).not.toContain('data-transient')
    // Last in the row, which is what "come next to it" means with two tabs.
    expect(html.indexOf('>Session 1<')).toBeLessThan(html.indexOf('>Session 2<'))
  })

  it('still lets the ✕ be the only thing that takes it off again', () => {
    /*
     * The other half of his sentence: *"if I want to remove it from there…I
     * should have to do it myself specifically."* Keeping a window and removing
     * it are exact inverses over the order, and the removal leaves every
     * session running — `removeFromStrip` returns a new order and touches
     * nothing else.
     */
    const kept = keepInStrip(['a'], 'b')
    const removed = removeFromStrip(kept, OPEN, 'b', 'b')
    expect(removed.order).toEqual(['a'])
    expect(OPEN.some((tab) => tab.id === 'b')).toBe(true)
    // And the window shows the neighbour rather than appearing to do nothing —
    // `shownTabs` would otherwise draw the tab straight back as transient.
    expect(removed.select).toBe('a')
  })
})

/* -------------------------------------------- and from every way in, once -- */

/**
 * Which presses keep their window, read off `App.tsx`.
 *
 * A wiring claim, so it is checked the way `wiring.test.ts` checks wiring: in
 * the source. There is no DOM in this test run and no way to press a button in
 * one; what can go wrong here is not a broken function but a call site that was
 * never added, and that is visible in the text.
 *
 * There are exactly three places in the renderer where a window is *created* —
 * `newSessionIn`, `newBrowserTab`, and the new-session dialog's `onStart` — and
 * the six ways a user reaches them all funnel through those three. The strip's
 * terminal glyph and the rail's button and the project heading's ＋ and ⌘T all
 * open the dialog; the strip's globe and the rail's globe and the palette all
 * call `newBrowserTab`. His words are about the header, and the header is
 * covered twice over; the rest are in because a session that stays on the bar
 * when it was started one way and vanishes when it was started another is the
 * window disagreeing with itself.
 */
describe('every route that opens a window keeps it', () => {
  const app = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

  it('keeps a session started from the dialog — the terminal opener, the rail, ⌘T', () => {
    // `(request, machineId)` since remote sessions landed: the handler routes a
    // session on another machine to that machine and returns before any of the
    // local bookkeeping — which is exactly what this test is guarding, one
    // branch further down.
    const onStart = /onStart=\{async \(request, machineId\) => \{[\s\S]*?\n {8}\}\}/.exec(app)?.[0] ?? ''
    expect(onStart, 'the dialog’s onStart has changed shape').not.toBe('')
    expect(onStart).toContain('keepNewWindowInStrip(meta.id)')
  })

  it('keeps a session started without the dialog — continue-last, and first launch', () => {
    const body = /const newSessionIn = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(body, 'newSessionIn has changed shape').not.toBe('')
    expect(body).toContain('keepNewWindowInStrip(meta.id)')
  })

  it('keeps a page opened from the globe', () => {
    const body = /const newBrowserTab = useCallback\([\s\S]*?\n {2}\}/.exec(app)?.[0] ?? ''
    expect(body, 'newBrowserTab has changed shape').not.toBe('')
    expect(body).toContain('keepNewWindowInStrip(id)')
  })

  /**
   * The globe's handler is never handed a DOM event.
   *
   * `newBrowserTab` takes an optional address now — a link opens a page the same
   * way the globe does — and both components that receive it put it straight on
   * a button's `onClick`, which calls it with a `MouseEvent`. TypeScript cannot
   * see that, because `(target?: string) => void` is assignable to `() => void`.
   *
   * Photographed on 2026-08-17: the event travelled out of `App.tsx` as
   * `WorkspaceTab.url`, arrived in `BrowserWorkspace` as `initialUrl`, became a
   * tab's `draft`, and threw `input.trim is not a function` out of
   * `resolveOmnibox` **during render** — so the error boundary replaced every
   * browser pane in the window with "New tab stopped working".
   */
  it('never hands the globe’s press in as the address', () => {
    const bare = [...app.matchAll(/onNewBrowserTab=\{([^}]*)\}/g)].map((m) => m[1].trim())
    expect(bare, 'App.tsx no longer wires onNewBrowserTab at all').not.toEqual([])
    expect(
      bare.filter((value) => value === 'newBrowserTab'),
      'onNewBrowserTab={newBrowserTab} passes React’s MouseEvent in as the URL — wrap it',
    ).toEqual([])
  })

  it('puts that page in the pane you pressed the globe from', () => {
    /*
     * This assertion is the inverse of the one it replaces, and the flip is the
     * point.
     *
     * It used to read `expect(body).not.toContain('setPanes(')`. While split,
     * the strip is handed `focusedId` — the focused pane's tab — so a page
     * opened from the globe arrived unselected and stayed behind the split.
     * `showInFocusedPane(current, id)` selected it and *also* destroyed the
     * layout: a pane holding an id that was not a session was a dead pane, and
     * the prune collapsed the split on the next render. Reproduced in the
     * running app — split on, globe pressed, split gone — so the line was taken
     * out and pinned so nobody retried it casually.
     *
     * What that pinned was the workaround. The cause was one level down: a pane
     * held a `sessionId`, and the prune was handed the session list, so a page
     * in a pane was a contradiction the layout resolved by throwing the layout
     * away. A pane holds a *tab* now and the prune is told about pages —
     * `layout/panes.test.ts` covers that end — so this line is safe, and
     * without it the defect it was guarding is simply back: a page you asked
     * for that never appears.
     */
    const body = /const newBrowserTab = useCallback\([\s\S]*?\n {2}\}/.exec(app)?.[0] ?? ''
    expect(body, 'newBrowserTab has changed shape').not.toBe('')
    // Asserted on `setPanes`, which is the only way this component can change a
    // layout, rather than on the name of the helper — the reasoning in the
    // source names that helper in order to explain itself, and a match on the
    // name alone would pass on the explanation.
    expect(body).toContain('setPanes(')
    expect(body).toContain('showInFocusedPane(current, id)')
    // And only while the window is split. Unsplit there is no layout to put it
    // in, and seeding one from a press of the globe would be the button
    // rearranging the window as a side effect of opening a page.
    expect(body).toContain('isSplit(current)')
  })

  it('keeps nothing this window did not open', () => {
    /*
     * The deliberate exclusions, and both would be actively wrong.
     *
     * A session started on a paired phone arrives with `focus: false` on
     * purpose — answering a message on your phone must not yank the Mac out of
     * the terminal you are typing in — and a tab that appeared on the bar would
     * do exactly that in the one place it is most visible. And the reload that
     * re-lists the running ptys is not somebody opening anything: promoting
     * there would fill the twelve slots with whatever `listSessions` happened
     * to answer and overwrite the arrangement the reload exists to preserve.
     */
    const created = /onSessionCreated\(\(meta\) => \{[\s\S]*?\n {6}\}\)/.exec(app)?.[0] ?? ''
    expect(created, 'onSessionCreated has changed shape').not.toBe('')
    expect(created).not.toContain('keepNewWindowInStrip')

    const restore = /listSessions\(\)[\s\S]*?\n {6}\}\)/.exec(app)?.[0] ?? ''
    expect(restore, 'the reload restore has changed shape').not.toBe('')
    expect(restore).not.toContain('keepNewWindowInStrip')
  })

  it('promotes on an opening and nowhere else, so nothing fills the bar on its own', () => {
    /*
     * The one-line version of this feature — promote whatever becomes active —
     * is the automatic strip this model rejected on its first page. A call
     * appearing beside a plain `selectTab` or `showTab` is how that mistake
     * would arrive, so the count is pinned and each one is accounted for here.
     *
     * It was three until 2026-08-17, and two joined because the copilot may not
     * exist yet: opening it starts a CLI, so `openCopilot` keeps its window when
     * there is already a session and the effect that waits for one keeps it when
     * there is not. Both are the press, not a navigation.
     *
     * The sixth arrived on 2026-08-18 and is inside `openTabWindow` — where it
     * keeps the window you were *already looking at* as a second one opens
     * beside it. Measured, in the harness: without it, launching and clicking
     * the second row made `Session 1` vanish from the bar, which is the same
     * disappearance he reported one window earlier. It is still bounded to an
     * opening: `openTabWindow` is called from the rail's rows and from nothing
     * else, and `keepWindowBesideInStrip` on the next line is the new window
     * itself.
     *
     * The seventh arrived later the same day, in `openServerShell` — the press
     * that opens a terminal on a server. It is an opening in the strictest sense
     * of this rule: the window *creates* that shell, the way it creates a
     * session or a page, which is exactly what *"if I open any new session and
     * any new browser from the header, it should automatically open in the top
     * bar"* is about. Note that opening a session on a paired **machine** is
     * deliberately not in this list and must not join it: that session was
     * already running over there and is merely being looked at.
     */
    expect(app.match(/keepNewWindowInStrip\(/g)).toHaveLength(7)
    /* And the seventh is inside the press rather than loose beside a
       navigation, which is the shape the count alone cannot tell apart. */
    const server = /const openServerShell = useCallback\([\s\S]*?\n {4}\[clearPanel\],/.exec(app)?.[0] ?? ''
    expect(server, 'openServerShell has changed shape').not.toBe('')
    expect(server).toContain('keepNewWindowInStrip(id)')
    // And the new one is genuinely inside that handler rather than loose beside
    // a navigation — the shape the count alone could not tell apart.
    const opening = /const openTabWindow = useCallback\([\s\S]*?\n {4}\[activeTab, selectTab\],/.exec(app)?.[0] ?? ''
    expect(opening, 'openTabWindow has changed shape').not.toBe('')
    expect(opening).toContain('keepNewWindowInStrip(anchor)')
    expect(opening).toContain('keepWindowBesideInStrip(id, anchor)')
  })

  it('takes the copilot off the bar rather than ending it', () => {
    /*
     * ⌘W is the one path in the window that could have killed the copilot's
     * session, because a singleton has no row in the rail and therefore no ✕
     * that ends it. `closeTab` has to answer that press the way the tab's own ✕
     * does — off the bar, still running — and this is a wiring claim rather than
     * a component one: every piece involved is correct on its own, and what can
     * regress is the branch in `App.tsx` that routes the press.
     */
    const close = /const closeTab = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(close, 'closeTab has changed shape').not.toBe('')
    expect(close).toContain('tab?.isCopilot')
    expect(close).toContain('removeWindowFromStrip(')
    // The guard is before the kill, or it is not a guard.
    expect(close.indexOf('tab?.isCopilot')).toBeLessThan(close.indexOf('closeTabNow(id)'))
  })
})

/* ------------------------------------------------- how wide a tab sits at -- */

/**
 * *"session tabs and browser tabs should be the same size. I see sometimes
 * inconsistency. Some of them are more wide, some of them are less wide. They
 * should be all at the same size. … this one is the perfect size, the one B1
 * and B2, this tab."* — 2026-08-20.
 *
 * Read out of the stylesheet, which is the only place this exists — there is no
 * layout engine in this test run, so the alternative is nothing at all. What
 * makes it worth reading as text is that "the same width" is not one
 * declaration: it is a basis that is equal on every tab, a ceiling at the same
 * number so a half-empty bar does not stretch them, and a floor that is *not*
 * that number so a full one can still compress. Delete any one of the three as
 * redundant and the row goes back to being sized by its contents, which is the
 * ragged row in his recording — 155, 110, 110, 140, 178, 109 pixels.
 *
 * The equal-basis half is the one that is easy to lose: `min`/`max` alone
 * cannot make two tabs agree, because between them a tab is still as wide as
 * what is written on it.
 */
describe('the width of a tab', () => {
  const css = readFileSync(join(__dirname, 'WorkspaceTabStrip.css'), 'utf8')
  const rule = /\.strip-tab \{[\s\S]*?\n\}/.exec(css)?.[0] ?? ''

  it('is stated once, as a ratio on the tab’s own height', () => {
    // Not `180px`. The tab's height is already derived from the bar's, so a
    // pixel here would be the one measurement in this sheet that stops moving
    // when `--toolbar-h` does.
    expect(css).toContain('--strip-tab-w: calc(var(--strip-tab-h) * 5);')
    expect(css).toContain('--strip-tab-min: calc(var(--strip-tab-h) * 3.5);')
  })

  it('gives every tab the same basis, which is what makes them equal', () => {
    expect(rule, '.strip-tab has changed shape').not.toBe('')
    expect(rule).toMatch(/flex: 0 1 var\(--strip-tab-w\);/)
  })

  it('caps at that same width, so four tabs do not stretch across the bar', () => {
    expect(rule).toContain('max-width: var(--strip-tab-w);')
  })

  it('can still shrink, so a full bar compresses before it starts scrolling', () => {
    // The floor is a different token from the width now. A floor equal to the
    // width would be a fixed size, and the bar would scroll at six tabs rather
    // than give — *"whenever we start new, these will become smaller."*
    expect(rule).toContain('min-width: var(--strip-tab-min);')
    expect(rule).not.toMatch(/flex-shrink: 0;/)
    expect(rule).not.toContain('min-width: var(--strip-tab-w);')
  })
})

/* --------------------------------------------------- how bright a tab sits -- */

/**
 * *"Let's make the selected tab pill up there, selected and other tabs' pill, a
 * little bit more white."*
 *
 * Read out of the stylesheet, for the same reason the widths above are: there
 * is no layout engine and no compositor in this test run, so the alternative is
 * nothing at all. What is worth pinning as text is not the shade — a shade is a
 * taste call and taste calls move — it is the three structural facts underneath
 * it, each of which was arrived at by measuring the running app and each of
 * which a later edit would undo while believing it was tidying up.
 *
 * Measured in the running app at the time this was written, in the dark theme:
 * the bar `rgb(33,33,33)`, an unselected tab `rgb(33,33,33)` — the same number,
 * which is what "dim and flat" was — and the selected tab `rgb(25,25,25)`,
 * equal to the pane below it on both sides of the seam. After: bar 33, rest 41,
 * hover 48, selected 25 and the seam still 25 on both sides. In the light
 * theme: bar 253, rest 244, hover 238, selected 232, seam 232 either side.
 */
describe('the fill under a tab', () => {
  const css = readFileSync(join(__dirname, 'WorkspaceTabStrip.css'), 'utf8')
  /** One top-level rule's body, anchored on column zero the way the sheet is written. */
  const rule = (selector: string): string => {
    const open = `\n${selector} {\n`
    const start = css.indexOf(open)
    expect(start, `no \`${selector}\` rule — has the strip been rewritten?`).not.toBe(-1)
    return css.slice(start + open.length, css.indexOf('\n}', start + open.length))
  }

  const rest = rule('.strip-tab:not([data-active])')
  const hover = rule('.strip-tab:hover:not([data-active])')

  it('gives an unselected tab a pill at rest, which it did not have', () => {
    /*
     * The whole of what he asked for on this half. Before this there was no
     * rule here at all: an unselected tab was `background: transparent` by
     * omission and the tint arrived only under the pointer, so four fifths of
     * the row was a word and an icon lying on glass.
     */
    expect(rest).toContain('var(--fill-quaternary)')
  })

  it('fades the fill rather than snapping it, which needed a registered property', () => {
    /*
     * Chromium does not interpolate between two gradients here. Sampled every
     * frame in the running app, the tint went 0.07 to 0.04 in one step with
     * nothing in between — so the pill snapped while the label carried on
     * easing over the same 120ms, which is one hover running at two speeds.
     *
     * A registered custom property does interpolate. The gradient reads one,
     * the property is what the transition names, and the fill fades again. The
     * `@property` block is what makes it a registered one: without it the same
     * declarations parse, cascade and paint correctly, and silently stop
     * animating — which is exactly the failure this replaced, back again with
     * no visible cause.
     */
    expect(css).toContain('@property --strip-tab-fill')
    expect(css).toContain("syntax: '<color>'")
    expect(rule('.strip-tab')).toContain('transition: --strip-tab-fill var(--dur-fast)')
    expect(rest).toContain('var(--strip-tab-fill)')
  })

  it('steps up one rung of the same ladder on hover, and not two', () => {
    /*
     * `--fill-secondary` is the rung above and it is wrong here, for a reason
     * that is invisible in the dark theme where the work was done: the fills
     * are a tint of the *ink*, so in the light theme every step up the ladder
     * moves an unselected tab towards `--tab-active` rather than away from it.
     * `--fill-secondary` was tried in the running app and measured
     * rgb(232,232,232) against a selected tab of rgb(232,232,232) — the same
     * number, which is the exact fault this change was fixing, moved off the
     * bar and onto the selection. The light theme would have lost the
     * difference between the tab you are in and the tab you are pointing at in
     * order to give the dark theme a louder hover.
     */
    expect(hover).toContain('var(--fill-tertiary)')
    expect(hover).not.toContain('var(--fill-secondary)')
    // And it still lifts the text with it, which is the larger half of the
    // hover in both themes.
    expect(hover).toContain('color: var(--text-primary)')
  })

  it('stops the fill a pixel above the bar’s hairline', () => {
    /*
     * `.strip` draws the window's one hairline as an inset shadow, which paints
     * under every child — so a fill that reaches a tab's bottom edge covers the
     * line for that tab's whole width. The *selected* tab does exactly that on
     * purpose; it is the mark that says the tab and the pane are one surface.
     * Five unselected tabs doing it as well would leave the strip ending in a
     * dashed line and would spend the only signal the selected tab has left now
     * that it is no longer the only tab with a fill.
     *
     * Hence a gradient with a hard stop rather than a colour: it is the one way
     * to end a pixel early without moving the box, and a `margin-bottom` or a
     * transparent `border-bottom` would each buy the same pixel and jog the
     * label half a pixel up with it every time the selection moved.
     *
     * Verified in the running app: the hairline reads rgb(44,44,44) under a
     * resting tab, under a hovered tab, in the gap between them and past the
     * last tab, and is absent only under the selected one. The hover state
     * inherits all of this, because it changes the colour and nothing else.
     */
    expect(rest, 'the fill is not a gradient').toContain('linear-gradient(')
    expect(rest, 'the fill does not stop short').toContain('calc(100% - 1px)')
    expect(rest, 'the fill has no transparent tail').toContain('transparent')
    // The hover must not respell the paint — a second gradient here is how the
    // two states drift a pixel apart.
    expect(hover).not.toContain('linear-gradient(')
  })

  it('leaves the selected tab and its join to the pane exactly where they were', () => {
    /*
     * The half of his sentence this change did *not* answer, pinned so that
     * answering it later is a deliberate act rather than a side effect of
     * somebody lifting the row again.
     *
     * The selected tab is filled with `--tab-active`, and `--tab-active` is not
     * this tab's colour — it is the session bar's, `.panes`', the browser
     * panel's and the terminal's own paper. Lifting it here alone opens the
     * seam the rebuild exists to close; lifting it everywhere is a change to
     * `tokens.css` and to the window's content surfaces, which is a different
     * piece of work with a different blast radius.
     */
    expect(rule('.strip-tab[data-active]')).toContain('background: var(--tab-active)')
    // And nothing paints under it: a background on the tab itself would sit
    // beneath the active fill and show through the flares, which are masked.
    expect(rule('.strip-tab')).not.toMatch(/^\s*background/m)
  })
})

/* ------------------------------------------------------ where the ✕ sits -- */

/**
 * *"The close button on the most right side of the pill, not next to the text —
 * it should be just at the end of the pill inside."*
 *
 * The ✕ is the last child of the tab, so where it lands is decided entirely by
 * how much of the tab everything in front of it uses up — and nothing in a tab
 * grew. A tab is at least 144px wide whatever is written on it, so on a short
 * name the content ran out early and the ✕ stopped there: measured in the
 * running app at 30.6px in from the tab's right edge on an unselected tab and
 * 29.0px on the selected one, because its label is `--w-medium` and a pixel and
 * a half wider. Two tabs of identical width with their ✕ glyphs on different
 * vertical lines.
 *
 * After: 4.0px in from the right edge — `var(--sp-1)`, the tab's own trailing
 * padding — on every tab in a bar of ten, at the 144px floor, on a session
 * renamed long enough to be cut by `middleEllipsis`, and on the selected tab.
 */
describe('the ✕ at the end of a tab', () => {
  const css = readFileSync(join(__dirname, 'WorkspaceTabStrip.css'), 'utf8')
  const rule = (selector: string): string => {
    const open = `\n${selector} {\n`
    const start = css.indexOf(open)
    expect(start, `no \`${selector}\` rule`).not.toBe(-1)
    return css.slice(start + open.length, css.indexOf('\n}', start + open.length))
  }

  it('is pinned by the face taking the slack, not by a margin on the ✕', () => {
    /*
     * Both spellings put the glyph in the same place and only one of them also
     * hands the empty space to something that can be clicked. Before this, the
     * thirty dead pixels between the name and the ✕ belonged to the tab's own
     * `div`, which switches nothing and only starts a drag.
     */
    expect(rule('.strip-tab-face')).toContain('flex: 1 1 auto;')
    expect(rule('.strip-tab-close, .strip-open')).toContain('flex-shrink: 0;')
    expect(rule('.strip-tab-close')).not.toContain('margin-left: auto')
  })

  it('keeps a gutter between a cut title and the glyph', () => {
    /*
     * 2px was enough while the ✕ trailed the text and the pair sat together in
     * the middle of the tab. With the label now growing right up to the ✕, a
     * title ending in an ellipsis and a ✕ two pixels apart read as one smudge —
     * so the gap is a spacing step. Measured at 4.0px between the label's box
     * and the ✕ on every tab whose title is long enough to be cut.
     */
    expect(rule('.strip-tab')).toContain('gap: var(--sp-1);')
  })

  it('holds its box while it is invisible, so the title is not re-cut on hover', () => {
    /*
     * `opacity`, not `display: none`. The ✕ is hidden until the tab is hovered,
     * focused or selected, and if it gave up its 18 pixels while hidden the
     * label would measure against a different right edge and retruncate under
     * the pointer — the title changing as you reach for the tab.
     */
    expect(rule('.strip-tab-close')).toContain('opacity: 0;')
    expect(rule('.strip-tab-close')).toContain('width: 18px;')
    expect(css).not.toMatch(/\.strip-tab-close[^{]*\{[^}]*display: none/)
  })

  it('keeps the destroying ✕ marked and the tidying one plain', () => {
    /*
     * The one thing about this control that a layout pass must not quietly
     * flatten. Two identical glyphs share every rule in the stylesheet — the
     * geometry, the reveal on hover, the grey — and `[data-ends]` is the single
     * declaration that separates the browser window's ✕ from the session's. A
     * destructive control drawn in the same grey as a harmless one is exactly the
     * confusion this bar has spent three revisions on.
     */
    const strip = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[session('a', 'api'), page('b1', 'New tab')]}
        activeTabId="b1"
        onSelect={() => undefined}
        onShowInstead={() => undefined}
        onCloseWindow={() => undefined}
        storage={store({ 'terminaldeck.strip.promoted': '["a","b1"]' })}
      />,
    )
    expect(strip).toContain('title="Close this page"')
    expect(strip).toContain('title="Take off the bar"')
    expect(rule('.strip-tab-close:hover')).toContain('color: var(--text-primary)')
    expect(rule('.strip-tab-close[data-ends]:hover')).toContain('color: var(--color-critical)')
  })
})

/**
 * A window whose id changed under it.
 *
 * Switching the account a running session is on stops its process and starts
 * another, which produces a new id for what the person is still calling the same
 * tab. The strip holds an arrangement somebody made by hand — this file is
 * emphatic that it holds what the user *chose* — so the tab has to stay exactly
 * where it was rather than being taken off the end and pushed back on.
 */
describe('an id replaced in place', () => {
  it('keeps the tab’s position', () => {
    // The remove-and-add spelling produces the right set and the wrong order.
    // Invisible until somebody with four tabs switches the account on the first.
    expect(replaceInStrip(['a', 'b', 'c'], 'a', 'z')).toEqual(['z', 'b', 'c'])
    expect(replaceInStrip(['a', 'b', 'c'], 'b', 'z')).toEqual(['a', 'z', 'c'])
  })

  it('leaves an unpromoted window unpromoted', () => {
    // A switch is not a promotion. The session was transient or it was on the
    // bar; this changes neither, it only keeps whichever was true from breaking.
    expect(replaceInStrip(['a'], 'b', 'z')).toEqual(['a'])
  })

  it('does not mutate the order it was handed', () => {
    const order = ['a', 'b']
    replaceInStrip(order, 'a', 'z')
    expect(order).toEqual(['a', 'b'])
  })

  it('writes through the store the strip is rendering from', () => {
    const backing = store({ 'terminaldeck.strip.promoted': '["a","b"]' })
    replaceWindowInStrip('a', 'z', backing)
    expect(readPromoted(backing)).toEqual(['z', 'b'])
  })

  it('survives a window with no storage at all', () => {
    expect(() => replaceWindowInStrip('a', 'z', null)).not.toThrow()
  })
})

/* ------------------------------------------------ opening a window from the rail -- */

/**
 * *"whenever I click on side panel on anyone, it should open a new window
 * instead of switching. It should open its own new window next to it."*
 *
 * The measured failure, in the harness, before this existed: three clicks down
 * the rail produced a strip reading `Session 1`, then `Session 2`, then
 * `Update Claude Code…` — **one** pill, overwritten each time, because none of
 * them was ever kept and `shownTabs` was drawing whichever happened to be
 * active. Which is also the whole of *"if I click on commander, they go away."*
 */
describe('keepBesideInStrip', () => {
  it('puts the new window immediately after the one it was opened from', () => {
    expect(keepBesideInStrip(['a', 'b', 'c'], 'd', 'a')).toEqual(['a', 'd', 'b', 'c'])
  })

  it('goes to the end when the window you were in is not on the bar', () => {
    // A transient tab has no place in the order to be next to. So does an
    // `after` of null, which is a window with nothing selected at all.
    expect(keepBesideInStrip(['a', 'b'], 'd', 'ghost')).toEqual(['a', 'b', 'd'])
    expect(keepBesideInStrip(['a', 'b'], 'd', null)).toEqual(['a', 'b', 'd'])
  })

  it('leaves a window that is already up there exactly where it is', () => {
    // Re-anchoring a tab somebody placed, in response to something that is not
    // a drag, is the strip rearranging itself — the one thing this file's
    // opening note refuses. Clicking a row you already kept must not move it.
    expect(keepBesideInStrip(['a', 'b', 'c'], 'c', 'a')).toEqual(['a', 'b', 'c'])
  })

  it('moves nothing else', () => {
    const before = ['a', 'b', 'c']
    const after = keepBesideInStrip(before, 'd', 'b')
    expect(after.filter((id) => id !== 'd')).toEqual(before)
  })

  it('refuses at the cap, like every other route in', () => {
    const full = Array.from({ length: MAX_PROMOTED }, (_, i) => `t${i}`)
    expect(keepBesideInStrip(full, 'extra', 't0')).toEqual(full)
  })

  it('opening three rows in turn keeps all three, which is the reported bug', () => {
    let order: readonly string[] = []
    // Each click opens beside whatever was in front — so they accumulate left
    // to right in the order they were opened, and the copilot arriving fourth
    // takes none of them away.
    order = keepBesideInStrip(order, 'one', null)
    order = keepBesideInStrip(order, 'two', 'one')
    order = keepBesideInStrip(order, 'three', 'two')
    expect(order).toEqual(['one', 'two', 'three'])
    order = keepBesideInStrip(order, 'copilot', 'three')
    expect(order).toEqual(['one', 'two', 'three', 'copilot'])
  })
})

describe('keepWindowBesideInStrip', () => {
  it('writes through the shared store the strip renders from', () => {
    const storage = store()
    const shared = promotedStore(storage)
    shared.set(['a', 'b'])
    keepWindowBesideInStrip('new', 'a', storage)
    expect(shared.get()).toEqual(['a', 'new', 'b'])
  })

  it('survives a window with no storage at all', () => {
    expect(() => keepWindowBesideInStrip('a', null, null)).not.toThrow()
  })
})
