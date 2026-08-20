import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  readBindings,
  resetBindingsForTests,
  setBindings,
  useBindings,
  type BindingsView,
} from './binding-view'

/**
 * The renderer's copy of the session ↔ browser relation, held against the three
 * rules that make a `useSyncExternalStore` store safe to read from four places.
 *
 * None of these is a performance test, and it is worth saying so because all
 * three look like one. The identity rule is the difference between a component
 * that renders and a component that renders for ever; the no-op rule is the
 * difference between one push per page title and a render storm behind a
 * browser page nobody is looking at; and the narrowing rule is the difference
 * between one chip missing and a strip that empties itself because a single
 * field arrived malformed. `shell/workspace-strip.ts` records all three as
 * measured defects rather than as style, which is why they were copied wholesale
 * into that module and are pinned here.
 *
 * ## How the store is read without a DOM
 *
 * There is no DOM environment in this project's test setup — `BrowserWorkspace.test.tsx`
 * says so and renders through static markup for the same reason. That works
 * here rather than merely being tolerable: on the server path
 * `useSyncExternalStore` calls its **third** argument, and `binding-view.ts`
 * passes the real `getSnapshot` as both the second and the third. So a static
 * render exercises the genuine snapshot function, not a stand-in.
 *
 * What a static render does *not* exercise is `subscribe`, because nothing on
 * the server path ever subscribes. The no-op rule is therefore asserted through
 * the thing that decides it: `setBindings` returns before it assigns *and*
 * before it notifies, so a snapshot whose identity is unchanged is a push that
 * woke nobody. Same branch, observed through the exported surface rather than
 * by reaching into a private `Set`.
 */

/** One well-formed view, as main sends it. */
const view = (windows: Array<{ n: number; browserTabId: string }>): unknown => ({
  sessions: [
    {
      sessionId: 'session-1',
      machineId: '',
      colour: 0,
      ended: false,
      windows: windows.map((w) => ({ ...w, url: 'https://example.test/', title: 'Example' })),
    },
  ],
})

/**
 * The value the store hands a component, taken from a real render.
 *
 * A probe rather than one of the chips, because the chips ask their own
 * questions of the view and a failure in either would land on the same line.
 * `createElement` rather than JSX so this stays a `.ts` file next to the module
 * it tests.
 */
function snapshotFromRender(): BindingsView {
  let seen: BindingsView | null = null
  const Probe = (): null => {
    seen = useBindings()
    return null
  }
  renderToStaticMarkup(createElement(Probe))
  if (!seen) throw new Error('the probe did not read the store')
  return seen
}

beforeEach(() => {
  resetBindingsForTests()
})

describe('the snapshot is stable by identity', () => {
  /**
   * V1, and the reason it is first: a `getSnapshot` that builds a fresh object
   * on every call reports a change on every render, and `useSyncExternalStore`
   * compares by identity, so React re-renders for ever. Nothing throws and
   * nothing looks wrong in a diff — the symptom is a frozen window, which is
   * why this is asserted rather than reasoned about.
   */
  it('reads the same object twice before anything has been pushed', () => {
    expect(snapshotFromRender()).toBe(snapshotFromRender())
  })

  it('reads the same object twice after a push', () => {
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    expect(snapshotFromRender()).toBe(snapshotFromRender())
  })

  it('hands back a different object once the view really changes', () => {
    const before = snapshotFromRender()
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    expect(snapshotFromRender()).not.toBe(before)
  })
})

describe('a push that says nothing new changes nothing', () => {
  /**
   * V2. The guard is load-bearing rather than an optimisation: main pushes the
   * whole view on every url and every title change of every attached window, so
   * a store that swapped its snapshot unconditionally would re-render the strip,
   * the rail and every pane bar on each keystroke of a page's `document.title`.
   *
   * Identity is the assertion because identity is the mechanism — `setBindings`
   * returns before both the assignment and the notification, so an unchanged
   * snapshot is precisely a push that woke no subscriber.
   */
  it('keeps the same snapshot for an equal view', () => {
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    const before = snapshotFromRender()
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    expect(snapshotFromRender()).toBe(before)
  })

  it('swaps the snapshot when a window is added', () => {
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    const before = snapshotFromRender()
    setBindings(
      view([
        { n: 1, browserTabId: 'browser:1:1' },
        { n: 2, browserTabId: 'browser:1:2' },
      ]),
    )
    expect(snapshotFromRender()).not.toBe(before)
  })

  it('swaps the snapshot when only a title changed', () => {
    // The cheapest possible change, and the one that must still get through: a
    // page renaming itself is what the chip's tooltip is drawn from.
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    const before = snapshotFromRender()
    setBindings({
      sessions: [
        {
          sessionId: 'session-1',
          machineId: '',
          colour: 0,
          ended: false,
          windows: [
            {
              n: 1,
              browserTabId: 'browser:1:1',
              url: 'https://example.test/',
              title: 'Something else',
            },
          ],
        },
      ],
    })
    expect(snapshotFromRender()).not.toBe(before)
  })

  it('swaps the snapshot when only the session ended', () => {
    setBindings(view([{ n: 1, browserTabId: 'browser:1:1' }]))
    const before = snapshotFromRender()
    setBindings({
      sessions: [
        {
          sessionId: 'session-1',
          machineId: '',
          colour: 0,
          ended: true,
          windows: [
            {
              n: 1,
              browserTabId: 'browser:1:1',
              url: 'https://example.test/',
              title: 'Example',
            },
          ],
        },
      ],
    })
    // `ended` is what the browser pill's tooltip says instead of a page title,
    // so a comparison that skipped it would leave a window claiming a live
    // session behind it.
    expect(snapshotFromRender()).not.toBe(before)
  })
})

describe('a malformed row costs one chip, not the whole view', () => {
  /**
   * V3, and the `seen`-set discipline from `pruneOrder` in its smallest form: a
   * view that arrives partly wrong must not empty a strip that is mostly right.
   * The payload crosses the bridge as `unknown` by design, so this narrowing is
   * the only thing between a renamed field in the main process and a rail with
   * no marks on it at all.
   */
  it('drops a window with no number and keeps its neighbours', () => {
    const read = readBindings({
      sessions: [
        {
          sessionId: 'session-1',
          machineId: '',
          colour: 1,
          ended: false,
          windows: [
            { n: 1, browserTabId: 'browser:1:1', url: 'https://a.test/', title: 'A' },
            { browserTabId: 'browser:1:2', url: 'https://b.test/', title: 'B' },
            { n: 3, browserTabId: 'browser:1:3', url: 'https://c.test/', title: 'C' },
          ],
        },
      ],
    })
    expect(read.sessions).toHaveLength(1)
    expect(read.sessions[0].windows.map((w) => w.n)).toEqual([1, 3])
  })

  it('drops a session with no id and keeps the rest of the view', () => {
    const read = readBindings({
      sessions: [
        { machineId: '', colour: 0, ended: false, windows: [] },
        {
          sessionId: 'session-2',
          machineId: '',
          colour: 2,
          ended: true,
          windows: [{ n: 4, browserTabId: 'browser:2:1', url: '', title: '' }],
        },
      ],
    })
    expect(read.sessions.map((s) => s.sessionId)).toEqual(['session-2'])
    expect(read.sessions[0].ended).toBe(true)
  })

  it('answers an empty view for anything that is not one', () => {
    // Not a throw. The push is a courtesy from the main process, and a renderer
    // that threw inside an IPC handler because a payload was wrong would take
    // the whole window down over a browser chip.
    for (const nonsense of [null, undefined, 42, 'sessions', {}, { sessions: 'no' }]) {
      expect(readBindings(nonsense).sessions).toEqual([])
    }
  })

  it('leaves a missing url and title empty rather than filling them in', () => {
    const read = readBindings({
      sessions: [
        {
          sessionId: 'session-1',
          machineId: '',
          colour: 0,
          ended: false,
          windows: [{ n: 1, browserTabId: 'browser:1:1' }],
        },
      ],
    })
    // Empty is what `BindChip` turns into "a browser window". A placeholder
    // here would reach a tooltip as a page title that no page ever had, which
    // is the one thing the binding must never print.
    expect(read.sessions[0].windows[0]).toEqual({
      n: 1,
      browserTabId: 'browser:1:1',
      url: '',
      title: '',
    })
  })
})
