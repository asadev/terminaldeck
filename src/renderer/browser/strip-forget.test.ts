import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { forgetWindowInStrip, MAX_PROMOTED, promotedStore } from './workspace-strip'

/**
 * The ids of windows that no longer exist, and the cap they were filling.
 *
 * ## What was measured
 *
 * `MAX_PROMOTED` is twelve, and `promote` refuses rather than evicting — which
 * is right, and which turns a list of dead ids into a bar that silently stops
 * accepting drags. The route in is not exotic: the strip is drawn behind
 * `stripIsPresent`, so closing the last window unmounts the component that owns
 * the pruning, along with the `seen` set the prune depends on. The id of the
 * window that was just closed is left in the order with nobody to notice, and
 * when the strip mounts again its `seen` is empty — the one state in which
 * `pruneOrder` is *required* to keep an id, because it cannot tell "closed"
 * from "on its way".
 *
 * So the fix cannot live in the strip, and this file is about the two places it
 * does live: a function that edits the shared store from outside a render, and
 * the two events in `App.tsx` that already say a window is gone.
 */

const app = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

/** A store with the memory of a real one and none of the environment. */
function store(seed: Record<string, string> = {}): Storage {
  const held = new Map<string, string>(Object.entries(seed))
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => {
      held.delete(key)
    },
    setItem: (key: string, value: string) => {
      held.set(key, value)
    },
  } as Storage
}

describe('forgetWindowInStrip', () => {
  it('takes a closed window out of the arrangement', () => {
    const disk = store({ 'terminaldeck.strip.promoted': '["a","b","c"]' })
    forgetWindowInStrip('b', disk)
    expect(JSON.parse(disk.getItem('terminaldeck.strip.promoted') ?? '[]')).toEqual(['a', 'c'])
  })

  it('leaves everything else exactly where it was', () => {
    // The order is a hand-made arrangement; closing one window is not a reason
    // to move the others, and a remove-and-re-add spelling would do exactly that.
    const disk = store({ 'terminaldeck.strip.promoted': '["a","b","c"]' })
    forgetWindowInStrip('a', disk)
    expect(JSON.parse(disk.getItem('terminaldeck.strip.promoted') ?? '[]')).toEqual(['b', 'c'])
  })

  it('does nothing for a window that was never up there', () => {
    const disk = store({ 'terminaldeck.strip.promoted': '["a"]' })
    forgetWindowInStrip('zzz', disk)
    expect(JSON.parse(disk.getItem('terminaldeck.strip.promoted') ?? '[]')).toEqual(['a'])
  })

  it('gives the cap back, which is the whole point of it', () => {
    /*
     * Twelve closed windows and a drag that does nothing, reproduced against
     * the model: fill the bar, close every one of them, and without this the
     * next promotion is refused by a list of ids that name nothing.
     */
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    const disk = store({ 'terminaldeck.strip.promoted': JSON.stringify(full) })
    expect(promotedStore(disk).get()).toHaveLength(MAX_PROMOTED)
    for (const id of full) forgetWindowInStrip(id, disk)
    expect(JSON.parse(disk.getItem('terminaldeck.strip.promoted') ?? '[]')).toEqual([])
  })

  it('reaches the same store the strip is rendering from', () => {
    // Not a copy: the whole reason this is a store rather than component state
    // is that the presses that change it happen outside a render.
    const disk = store({ 'terminaldeck.strip.promoted': '["a","b"]' })
    const shared = promotedStore(disk)
    forgetWindowInStrip('a', disk)
    expect(shared.get()).toEqual(['b'])
  })
})

describe('the two events it is called on', () => {
  it('is called when this window closes a tab', () => {
    /*
     * `closeTabNow` is ⌘W, the tab's ✕ for a page, the rail's Delete and the
     * main process asking for a page to go. Every one of them is the app letting
     * go of the window, and every one of them used to leave the id behind.
     */
    const close = /const closeTabNow = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(close, 'closeTabNow has changed shape').not.toBe('')
    expect(close).toContain('forgetWindowInStrip(id)')
  })

  it('is called when something else ends a session', () => {
    /*
     * `session:removed` is the copilot's `sessions.stop`, a paired phone, a
     * routine — the endings this window did not cause. It is deliberately not
     * `onSessionExit`: a process that dies keeps its tab, its scrollback and its
     * place, because reading what it printed is why that tab is still worth
     * having.
     */
    const removed = /onSessionRemoved\?\.\(\(id\) => \{[\s\S]*?\n {6}\}\)/.exec(app)?.[0] ?? ''
    expect(removed, 'the session:removed handler has changed shape').not.toBe('')
    expect(removed).toContain('forgetWindowInStrip(id)')
  })

  it('is not called on a timer or a sweep', () => {
    // *"Events, not polling."* Two call sites, both of them a thing that happened.
    expect(app.match(/forgetWindowInStrip\(/g)).toHaveLength(2)
  })
})
