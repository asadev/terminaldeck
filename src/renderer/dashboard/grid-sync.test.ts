import { describe, expect, it } from 'vitest'
import { reconcileGrid } from './grid-sync'

/** Stand-ins for DOM nodes. Identity is the whole subject, so they are objects. */
const nodeA = { tag: 'a' }
const nodeB = { tag: 'b' }
const nodeC = { tag: 'c' }

describe('reconcileGrid', () => {
  it('adopts a tile gridstack has never seen', () => {
    const sync = reconcileGrid(new Map(), new Map([['cost', nodeA]]))
    expect(sync.adopt).toEqual([{ id: 'cost', element: nodeA }])
    expect(sync.drop).toEqual([])
  })

  it('drops a tile that has left the layout', () => {
    const sync = reconcileGrid(new Map([['cost', nodeA]]), new Map())
    expect(sync.drop).toEqual([{ id: 'cost', element: nodeA }])
    expect(sync.adopt).toEqual([])
  })

  it('leaves a tile alone when nothing about it changed', () => {
    const same = new Map([['cost', nodeA]])
    expect(reconcileGrid(same, same)).toEqual({ drop: [], adopt: [] })
  })

  /**
   * The one that matters, and the one an id-only record could not see.
   *
   * A widget whose feature is switched off and back on again renders `null` for
   * a commit and then mounts a **new** `<div>` under the same id. Before this,
   * gridstack was still holding the old detached node — so its cells stayed
   * reserved — and was never told about the new one, so the new one never got a
   * position and was invisible for the rest of the session. That is Asad's
   * "the widget vanished and never came back".
   */
  it('replaces a tile whose node changed under the same id', () => {
    const sync = reconcileGrid(new Map([['cost', nodeA]]), new Map([['cost', nodeB]]))
    expect(sync.drop).toEqual([{ id: 'cost', element: nodeA }])
    expect(sync.adopt).toEqual([{ id: 'cost', element: nodeB }])
  })

  it('keeps the order it was given, so packing lands where the layout said', () => {
    const drawn = new Map([
      ['a', nodeA],
      ['b', nodeB],
      ['c', nodeC],
    ])
    expect(reconcileGrid(new Map(), drawn).adopt.map((entry) => entry.id)).toEqual(['a', 'b', 'c'])
  })

  it('handles a whole page turning over at once', () => {
    const sync = reconcileGrid(
      new Map([
        ['old', nodeA],
        ['kept', nodeB],
      ]),
      new Map([
        ['kept', nodeB],
        ['new', nodeC],
      ]),
    )
    expect(sync.drop).toEqual([{ id: 'old', element: nodeA }])
    expect(sync.adopt).toEqual([{ id: 'new', element: nodeC }])
  })
})
