import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { bridgeChromeDim, chromeDim, createChromeDim, type ChromeDimHost } from './chrome-dim'

/**
 * The counter that tells Windows its own buttons have gone dim, exercised with
 * no window and no bridge.
 *
 * There is no DOM in this test process — deliberately, see CLAUDE.md — which is
 * why `createChromeDim` takes a host at all. What it guards is not a type error
 * and never was: a dialog closing over another dialog would leave the window's
 * caption buttons at full brightness with Settings still open behind it, and
 * nothing on this Mac can watch that happen.
 */

/** A bridge that remembers everything it was told, in order. */
function fakeHost(): ChromeDimHost & { sent: boolean[] } {
  const sent: boolean[] = []
  return { sent, setChromeDimmed: (dimmed) => void sent.push(dimmed) }
}

describe('one surface over the window', () => {
  it('dims on the way in and brightens on the way out', () => {
    const host = fakeHost()
    const dim = createChromeDim(host)

    const release = dim.dim()
    expect(host.sent).toEqual([true])
    expect(dim.held()).toBe(1)

    release()
    expect(host.sent).toEqual([true, false])
    expect(dim.held()).toBe(0)
  })

  it('says nothing at all until something is over the window', () => {
    // A window with no dialog is the state the strip is already painted in.
    // Announcing it on mount would repaint the caption buttons on every launch
    // for a change that has not happened.
    const host = fakeHost()
    createChromeDim(host)
    expect(host.sent).toEqual([])
  })
})

describe('dialogs stack, and the strip is dim while any of them is up', () => {
  it('sends once on the way in however many open', () => {
    /*
     * Settings can open the add-account dialog over itself, and a confirm over
     * that. Each mounts its own `.modal-overlay`; the window is dim once.
     */
    const host = fakeHost()
    const dim = createChromeDim(host)

    const settings = dim.dim()
    const addAccount = dim.dim()
    const confirm = dim.dim()

    expect(host.sent).toEqual([true])
    expect(dim.held()).toBe(3)
    void settings
    void addAccount
    void confirm
  })

  it('stays dim while an inner dialog closes over an outer one', () => {
    // The failure a boolean has: the inner dialog was the last to move, so a
    // "set false on close" would brighten the caption buttons with Settings
    // still open underneath.
    const host = fakeHost()
    const dim = createChromeDim(host)

    const settings = dim.dim()
    const addAccount = dim.dim()
    addAccount()

    expect(host.sent).toEqual([true])
    expect(dim.held()).toBe(1)

    settings()
    expect(host.sent).toEqual([true, false])
  })

  it('brightens when an outer dialog closes and takes its children with it', () => {
    /*
     * The other direction of the same failure, and the one React actually
     * produces: closing Settings unmounts the subtree, so both cleanups run in
     * one commit and the *outer* one can run first. Order does not matter to a
     * count; it is everything to a flag.
     */
    const host = fakeHost()
    const dim = createChromeDim(host)

    const settings = dim.dim()
    const addAccount = dim.dim()
    settings()
    addAccount()

    expect(host.sent).toEqual([true, false])
    expect(dim.held()).toBe(0)
  })
})

describe('a release is a claim, not a decrement', () => {
  it('ignores being called twice', () => {
    /*
     * React runs an effect's cleanup once in production and twice under
     * StrictMode's development double-invoke. A release that decremented on
     * every call would take the count below zero, and the next dialog to open
     * would then have to be opened twice before the strip dimmed.
     */
    const host = fakeHost()
    const dim = createChromeDim(host)

    const release = dim.dim()
    release()
    release()
    release()

    expect(dim.held()).toBe(0)
    expect(host.sent).toEqual([true, false])
  })

  it('survives a double release under one that is still open', () => {
    const host = fakeHost()
    const dim = createChromeDim(host)

    const outer = dim.dim()
    const inner = dim.dim()
    inner()
    inner()

    expect(dim.held()).toBe(1)
    expect(host.sent).toEqual([true])

    outer()
    expect(host.sent).toEqual([true, false])
  })

  it('dims again after everything has closed', () => {
    // The count is a level, not a latch: closing everything and opening one
    // more dialog is a second `true`, because the strip really was repainted
    // bright in between.
    const host = fakeHost()
    const dim = createChromeDim(host)

    dim.dim()()
    dim.dim()()

    expect(host.sent).toEqual([true, false, true, false])
  })
})

describe('the window that has no bridge', () => {
  it('hands back a host that does nothing rather than a null to check for', () => {
    /*
     * This test process has no `window` at all, which is exactly the shape
     * `chrome-render.test.tsx` renders components in. A nullable host would put
     * that check at every call site; a no-op host is the honest answer for a
     * surface nobody is looking at, and it is what keeps `Modal` free of a
     * platform branch.
     */
    expect(typeof globalThis.window).toBe('undefined')
    expect(() => bridgeChromeDim().setChromeDimmed(true)).not.toThrow()
    expect(() => chromeDim.dim()()).not.toThrow()
  })
})

describe('every dialog in the app is wired to it', () => {
  /*
   * Asserted as source text, for the reason `preload/contract.test.ts` gives at
   * length: this is a string-matching problem across files, there is no DOM here
   * to mount a dialog in, and the failure mode is the wiring being absent rather
   * than wrong. `Modal` is the single component every dialog in the app is built
   * from — Settings included — so one call there is all of them.
   */
  const MODAL = readFileSync(
    join(resolve(__dirname, '..'), 'components', 'Modal.tsx'),
    'utf8',
  ).replace(/\r\n?/g, '\n')

  it('Modal holds the dim while it is open', () => {
    expect(MODAL).toContain("import { chromeDim } from '../shell/chrome-dim'")
    expect(MODAL).toContain('return chromeDim.dim()')
  })

  it('lets go while the dialog has stepped aside for a native panel', () => {
    /*
     * `hidden` is `display: none` on the overlay — the scrim is off the window
     * while a system file picker owns it, so there is nothing for the caption
     * buttons to be dim with. Depending on `open` alone would leave them dark
     * under a picker that is the brightest thing on the screen.
     */
    expect(MODAL).toContain('if (!open || hidden) return\n    return chromeDim.dim()')
    expect(MODAL).toContain('}, [open, hidden])')
  })
})
