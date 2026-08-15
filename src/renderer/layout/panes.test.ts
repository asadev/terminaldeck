import { describe, expect, it } from 'vitest'
import {
  closePane,
  createLayout,
  emptyLayout,
  focusedSessionId,
  listPanes,
  sessionIds,
  type PaneLayout,
} from './pane-tree'
import {
  closePaneOrCollapse,
  isSplit,
  pruneClosedSessions,
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
  listPanes(layout).map((pane) => pane.sessionId)

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
    expect(focusedSessionId(layout)).toBe('a')
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

describe('pruneClosedSessions', () => {
  it('drops a pane whose session has gone', () => {
    const three = splitFocused(seedSplit([session('a'), session('b')], 'a'))
    expect(sessionIds(three).sort()).toEqual(['a', 'b'])
    const pruned = pruneClosedSessions(three, [session('a')])
    expect(sessionIds(pruned)).toEqual(['a'])
  })

  it('collapses rather than leaving one pane behind', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(isSplit(pruneClosedSessions(seeded, [session('a')]))).toBe(false)
  })

  it('keeps panes nobody has filled yet', () => {
    // An empty pane is something the user made on purpose; only a pane naming a
    // session that no longer exists is stale.
    const seeded = seedSplit([session('only')], 'only')
    const pruned = pruneClosedSessions(seeded, [session('only')])
    expect(ids(pruned)).toEqual(['only', null])
  })

  it('never leaves the focused pane pointing at a dead session', () => {
    /*
     * The bug this exists for: `focusedSessionId` is what the toolbar, the
     * inspector and the composer all read, so a pane still naming a closed
     * session means every one of them acts on a session the store has already
     * forgotten.
     */
    const three = splitFocused(seedSplit([session('a'), session('b')], 'a'))
    const pruned = pruneClosedSessions(three, [session('b')])
    const focused = focusedSessionId(pruned)
    expect(focused === null || focused === 'b').toBe(true)
    expect(sessionIds(pruned)).not.toContain('a')
  })

  it('hands back the same layout when nothing has gone', () => {
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(pruneClosedSessions(seeded, [session('a'), session('b')])).toBe(seeded)
  })

  it('survives every session disappearing at once', () => {
    // Closing a whole project takes several sessions in one go.
    const seeded = seedSplit([session('a'), session('b')], 'a')
    expect(isSplit(pruneClosedSessions(seeded, []))).toBe(false)
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
    const byPrune = pruneClosedSessions(seeded, [session('b')])
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
