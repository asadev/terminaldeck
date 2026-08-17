import { describe, expect, it } from 'vitest'
import {
  closePane,
  createLayout,
  emptyLayout,
  focusedTabId,
  listPanes,
  tabIds,
  type PaneLayout,
} from './pane-tree'
import {
  closePaneOrCollapse,
  isSplit,
  pruneClosedPanes,
  seedSplit,
  showInFocusedPane,
  splitFocused,
} from './panes'

/**
 * The seam between the pane tree and the session list.
 *
 * Everything here is about one promise: the sidebar names the session in the
 * focused pane, and no pane may ever show a session the sidebar does not list.
 * The pane tree's own behaviour is covered by `pane-tree.test.ts`; what is
 * tested here is the rules that keep the two models from telling different
 * stories, which is the objection that kept `SplitView` unrendered for the
 * whole life of the project.
 */

const session = (id: string) => ({ id })
const ids = (layout: PaneLayout): Array<string | null> =>
  listPanes(layout).map((pane) => pane.tabId)

describe('isSplit', () => {
  it('is false for a layout with no root', () => {
    expect(isSplit(emptyLayout())).toBe(false)
  })

  it('is true as soon as there is a pane', () => {
    expect(isSplit(createLayout('a'))).toBe(true)
  })
})

describe('seedSplit', () => {
  it('opens on the session you were working in, beside the next one', () => {
    const layout = seedSplit([session('a'), session('b'), session('c')], 'b')
    expect(ids(layout)).toEqual(['b', 'a'])
  })

  it('leaves the keyboard where it was', () => {
    // Pressing Split must not send the next keystroke to the other agent.
    const layout = seedSplit([session('a'), session('b')], 'a')
    expect(focusedTabId(layout)).toBe('a')
  })

  it('falls back to the first session when nothing is focused', () => {
    const layout = seedSplit([session('a'), session('b')], null)
    expect(ids(layout)).toEqual(['a', 'b'])
  })

  it('leaves the second pane empty when there is only one session', () => {
    // Not a bug and not a placeholder: splitting is how you make room for the
    // next agent, and the empty pane is what offers to start one.
    const layout = seedSplit([session('only')], 'only')
    expect(ids(layout)).toEqual(['only', null])
  })

  it('always produces two panes, so pressing Split visibly does something', () => {
    for (const list of [[], [session('a')], [session('a'), session('b')]]) {
      expect(listPanes(seedSplit(list, null))).toHaveLength(2)
    }
  })
})

describe('showInFocusedPane', () => {
  it('fills the focused pane rather than adding one', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const next = showInFocusedPane(seeded, 'c')
    expect(listPanes(next)).toHaveLength(2)
    expect(ids(next)).toEqual(['c', 'b'])
  })

  it('is a no-op on an empty layout', () => {
    const empty = emptyLayout()
    expect(showInFocusedPane(empty, 'a')).toBe(empty)
  })

  it('hands back the same layout when the pane already shows that session', () => {
    // Same reference, or every sidebar click re-renders both terminals.
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(showInFocusedPane(seeded, 'a')).toBe(seeded)
  })
})

describe('splitFocused', () => {
  it('adds a pane showing the same session', () => {
    const layout = splitFocused(createLayout('a'))
    expect(ids(layout)).toEqual(['a', 'a'])
  })

  it('splits the pane that has focus, not the first one', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const second = listPanes(seeded)[1]
    const focusedOnSecond: PaneLayout = { ...seeded, focusedPaneId: second.id }
    expect(ids(splitFocused(focusedOnSecond))).toEqual(['a', 'b', 'b'])
  })

  it('is a no-op on an empty layout', () => {
    const empty = emptyLayout()
    expect(splitFocused(empty)).toBe(empty)
  })
})

describe('closePaneOrCollapse', () => {
  it('collapses to nothing when one pane would be left', () => {
    // A "split view" holding a single pane is the ordinary session view wearing
    // a divider, with a mode switch claiming you are somewhere you are not.
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const closed = closePaneOrCollapse(seeded, listPanes(seeded)[1].id)
    expect(isSplit(closed)).toBe(false)
  })

  it('keeps the layout when two or more panes survive', () => {
    const three = splitFocused(seedSplit([session('a'), session('b')], 'a'))
    const closed = closePaneOrCollapse(three, listPanes(three)[0].id)
    expect(listPanes(closed)).toHaveLength(2)
  })
})

describe('pruneClosedPanes', () => {
  it('drops a pane whose session has gone', () => {
    const three = splitFocused(seedSplit([session('a'), session('b')], 'a'))
    expect(tabIds(three).sort()).toEqual(['a', 'b'])
    const pruned = pruneClosedPanes(three, [session('a')])
    expect(tabIds(pruned)).toEqual(['a'])
  })

  it('collapses rather than leaving one pane behind', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(isSplit(pruneClosedPanes(seeded, [session('a')]))).toBe(false)
  })

  it('keeps panes nobody has filled yet', () => {
    // An empty pane is something the user made on purpose; only a pane naming a
    // session that no longer exists is stale.
    const seeded = seedSplit([session('only')], 'only')
    const pruned = pruneClosedPanes(seeded, [session('only')])
    expect(ids(pruned)).toEqual(['only', null])
  })

  it('never leaves the focused pane pointing at a dead session', () => {
    /*
     * The bug this exists for: `focusedTabId` is what the toolbar, the
     * inspector and the composer all read, so a pane still naming a closed
     * session means every one of them acts on a session the store has already
     * forgotten.
     */
    const three = splitFocused(seedSplit([session('a'), session('b')], 'a'))
    const pruned = pruneClosedPanes(three, [session('b')])
    const focused = focusedTabId(pruned)
    expect(focused === null || focused === 'b').toBe(true)
    expect(tabIds(pruned)).not.toContain('a')
  })

  it('hands back the same layout when nothing has gone', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(pruneClosedPanes(seeded, [session('a'), session('b')])).toBe(seeded)
  })

  it('survives every session disappearing at once', () => {
    // Closing a whole project takes several sessions in one go.
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(isSplit(pruneClosedPanes(seeded, []))).toBe(false)
  })
})

describe('the sidebar and the layout tell the same story', () => {
  it('a click fills the pane you are looking at, whichever that is', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const [first, second] = listPanes(seeded)

    const intoFirst = showInFocusedPane({ ...seeded, focusedPaneId: first.id }, 'c')
    expect(ids(intoFirst)).toEqual(['c', 'b'])

    const intoSecond = showInFocusedPane({ ...seeded, focusedPaneId: second.id }, 'c')
    expect(ids(intoSecond)).toEqual(['a', 'c'])
  })

  it('a pane count never changes because a session was selected', () => {
    let layout = seedSplit([session('a'), session('b')], 'a')
    for (const id of ['c', 'd', 'a', 'b']) layout = showInFocusedPane(layout, id)
    expect(listPanes(layout)).toHaveLength(2)
  })

  it('closing by hand and pruning end in the same place', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const byHand = closePaneOrCollapse(seeded, listPanes(seeded)[0].id)
    const byPrune = pruneClosedPanes(seeded, [session('b')])
    expect(isSplit(byHand)).toBe(isSplit(byPrune))
  })

  it('the tree is happy with one pane, and this module is not', () => {
    // The difference is the whole reason `closePaneOrCollapse` exists, and the
    // reason it is used from both the ✕ and the prune.
    const seeded = seedSplit([session('a'), session('b')], 'a')
    const paneId = listPanes(seeded)[0].id
    expect(listPanes(closePane(seeded, paneId))).toHaveLength(1)
    expect(listPanes(closePaneOrCollapse(seeded, paneId))).toHaveLength(0)
  })
})

/* ------------------------------------------------- and a pane holds a page -- */

/**
 * A pane may hold a browser page, and the prune must not take it away.
 *
 * This is the defect this seam was rewritten for, and it is worth stating
 * exactly because the symptom and the cause were three files apart. With the
 * window split, opening a page put its id into the focused pane; the very next
 * render called this module's prune with the *session* list; the page's id was
 * not in it; the pane was declared dead and the whole hand-made split collapsed
 * back to one window. Reproduced live, backed out, and pinned as "never call
 * `setPanes` from `newBrowserTab`" — which pinned the workaround rather than the
 * fix.
 *
 * The fix is that the authority is the open-window list. A page id is spelled
 * `browser:<millis>` by `App.tsx`; nothing here parses it, and that is the
 * point — these tests use that spelling only so a reader can see which of the
 * two kinds is which.
 */
describe('a pane can hold a page, not only a session', () => {
  const page = (id: string) => ({ id })

  it('keeps a pane whose page is still open', () => {
    const split = seedSplit([session('a'), page('browser:1')], 'a')
    expect(ids(split)).toEqual(['a', 'browser:1'])
    // The render right after the click, with the same two things still open.
    expect(pruneClosedPanes(split, [session('a'), page('browser:1')])).toBe(split)
  })

  it('collapsed the split when the page was missing from the list — the bug', () => {
    /*
     * Kept as a test rather than deleted, because it is the *mechanism*: hand
     * this function a list that is narrower than what is open and it will
     * cheerfully dismantle the layout. The guard is at the call site, which
     * must pass `tabs` and never `sessions`.
     */
    const split = seedSplit([session('a'), page('browser:1')], 'a')
    expect(isSplit(pruneClosedPanes(split, [session('a')]))).toBe(false)
  })

  it('drops a page pane once the page is genuinely closed', () => {
    const three = splitFocused(seedSplit([session('a'), page('browser:1')], 'a'))
    const pruned = pruneClosedPanes(three, [session('a'), page('browser:1')])
    expect(tabIds(pruned).sort()).toEqual(['a', 'browser:1'])
    // Now the page's tab is closed for real, and the pane goes with it.
    expect(tabIds(pruneClosedPanes(three, [session('a')]))).toEqual(['a'])
  })

  it('opens a split on the page you were reading, not on some session', () => {
    // Seeded from the session list, the page in front of you simply vanished.
    const split = seedSplit([page('browser:1'), session('a')], 'browser:1')
    expect(ids(split)).toEqual(['browser:1', 'a'])
  })

  it('lets a click put a page into the pane you are looking at', () => {
    const split = seedSplit([session('a'), session('b')], 'a')
    expect(ids(showInFocusedPane(split, 'browser:1'))).toEqual(['browser:1', 'b'])
  })
})
