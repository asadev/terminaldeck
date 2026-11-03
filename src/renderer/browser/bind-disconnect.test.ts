import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The disconnect control on the browser's own toolbar.
 *
 *   > *"When we connect any browser, and we should be have a button here to
 *   > disconnect also, or it should only this way."*
 *
 * Filmed on 2026-08-21. The only way out of a connection was to re-click the
 * ticked row in the checklist the chain button pops — a gesture rather than an
 * affordance — and on the window in the frame nothing was ticked at all, so the
 * exit was invisible *and* unreachable while the page was being driven.
 *
 * Source rather than a render, for the reason `ProfileMenu.test.tsx` gives:
 * this component reads the binding store through `useSyncExternalStore` and
 * this suite has no DOM to run a subscription in. What the markup does once it
 * is on screen is `browser-binding-menu.test.ts`'s subject — that file holds
 * the act itself, from both doors, including that it ends the drive.
 */
const source = readFileSync(join(__dirname, 'BindChip.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('a browser window can be disconnected from where it is seen', () => {
  it('draws the control only while something is attached', () => {
    // A greyed Disconnect on every toolbar is the dead control this round is
    // about; the standing rule on this bar is that a control which cannot do
    // anything is not drawn.
    expect(onScreen).toContain("if (slot === '') return connect")
  })

  it('says the word to anything that reads names, and the window with it', () => {
    expect(onScreen).toContain("title=\"Disconnect\"")
    expect(onScreen).toContain('aria-label={`Disconnect ${slot}`}')
  })

  it('breaks the relation through the main process, which owns it', () => {
    // `browser:unbind` is the same act the menu's own Disconnect row runs. The
    // renderer holds no copy of the map — see `binding-view.ts`.
    expect(onScreen).toContain('browserUnbind')
    expect(onScreen).toContain('unbind?.(browserTabId)')
  })

  it('does nothing at all on a preload without the channel', () => {
    // Never a button that looks like it worked. The optional call is the whole
    // of it: no local state is changed here, so there is nothing to roll back.
    expect(onScreen).not.toContain('unbind!(')
  })
})
