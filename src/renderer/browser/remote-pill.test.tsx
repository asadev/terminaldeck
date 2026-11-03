import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { WorkspaceTabStrip } from './WorkspaceTabStrip'
import {
  KIND_ICON,
  MACHINE_ICON,
  machineTabId,
  readMachineTabId,
  tabTooltip,
  type WorkspaceTab,
} from '../shell/workspace-tabs'

/**
 * A session on another machine gets a pill on the top strip, and it is the same
 * pill a local session gets.
 *
 * ## The instruction, which overrules the night before
 *
 * Asad, 2026-08-18: *"When I click on any session — the shape of the icon, top
 * bar header is not same, and I cannot drag it up there. You cannot have that
 * tab pill here for this on the top. So it should be there on the top, just like
 * the normal internal local session."*
 *
 * A remote session was deliberately left out of `WorkspaceTab` the night before,
 * on the argument that a ✕ on the pill would promise to end something this
 * window does not own. He asked for the pill directly, so that decision is
 * reversed — and the objection is answered by the ✕ meaning less rather than
 * more: *"for the sessions it will just close from the top bar, but it will
 * still stay in the side panel."* It takes the pill off the bar. It cannot
 * reach the machine, and there is no longer any handler through which it could.
 *
 * ## What is pinned here, and why each one
 *
 * The pill has to be **indistinguishable** from a local one — same glyph, same
 * status dot, same ✕ doing the same harmless thing — because "the shape of the
 * application should not be changing for local and remote devices" is the
 * sentence he has now said three nights running. And the ✕ has to be
 * **distinguishable from the browser window's**, which really does destroy
 * something and sits a centimetre away wearing the same glyph. Those are the
 * two halves, and each needs its own test.
 */

const MACHINE = { id: 'm-1', name: 'DESKTOP-DDGMNCV' }
const REMOTE_ID = machineTabId(MACHINE.id, 'r1')

const LOCAL: WorkspaceTab = {
  id: 's1',
  kind: 'session',
  label: 'Session 1',
  status: 'idle',
  projectPath: '/p',
  closable: true,
}

const REMOTE: WorkspaceTab = {
  id: REMOTE_ID,
  kind: 'session',
  label: 'Fix the parser',
  status: 'working',
  projectPath: 'C:\\Users\\asad\\site',
  machine: MACHINE,
  closable: true,
}

/**
 * A storage holding a promoted order, so both pills are on the bar at once.
 *
 * The strip draws the tabs somebody promoted, plus whichever one is active — so
 * a remote session with nothing promoted and the local one selected is correctly
 * *not* on the bar, and half these assertions would be comparing one pill
 * against nothing. Promoting both is what a person who has dragged two windows
 * up there has, which is the state the comparison is about.
 */
function promoting(ids: readonly string[]): Storage {
  const held = new Map<string, string>([['terminaldeck.strip.promoted', JSON.stringify(ids)]])
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => void held.delete(key),
    setItem: (key: string, value: string) => void held.set(key, value),
  }
}

function strip(
  tabs: readonly WorkspaceTab[],
  props: { onCloseWindow?: (id: string) => void; activeTabId?: string | null } = {},
): string {
  const { activeTabId = 's1', onCloseWindow } = props
  return renderToStaticMarkup(
    <WorkspaceTabStrip
      tabs={tabs}
      activeTabId={activeTabId}
      onSelect={() => {}}
      // Wired on every mount here, because it is what makes a session's ✕ appear
      // at all — the strip draws no control it cannot finish. Leaving it out
      // would make every assertion below about "the ✕ this pill carries" pass
      // for the wrong reason.
      onShowInstead={() => {}}
      {...(onCloseWindow ? { onCloseWindow } : {})}
      storage={promoting(tabs.map((tab) => tab.id))}
    />,
  )
}

/** The markup of one tab, sliced out of the strip by its id. */
function pill(html: string, id: string): string {
  const at = html.indexOf(`data-tab-id="${id}"`)
  expect(at, `no tab ${id} in the strip`).toBeGreaterThan(-1)
  const start = html.lastIndexOf('<div', at)
  const next = html.indexOf('data-strip-tab', at + 1)
  return html.slice(start, next === -1 ? undefined : html.lastIndexOf('<div', next))
}

describe('a remote session is drawn as a tab', () => {
  it('appears in the strip at all', () => {
    // The whole of the complaint: the strip used to read "Drag a session or a
    // page here to keep it along the top" with a remote session open, because
    // the session was not in `tabs` and there was nothing to draw.
    expect(strip([LOCAL, REMOTE])).toContain(`data-tab-id="${REMOTE_ID}"`)
  })

  it('is drawn while it is the one on screen, with nothing promoted', () => {
    /*
     * The exact screen he was describing: a remote session open, nothing dragged
     * to the top, and a strip reading *"Drag a session or a page here to keep it
     * along the top."* The bar always draws the active tab whether or not it is
     * promoted — a window displaying a terminal must have a tab naming it — and
     * that rule only reaches a remote session now that one can *be* the active
     * tab. Asserted with a null storage, which is a window whose strip nobody
     * has arranged.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[LOCAL, REMOTE]}
        activeTabId={REMOTE_ID}
        onSelect={() => {}}

        storage={null}
      />,
    )
    expect(html).toContain(`data-tab-id="${REMOTE_ID}"`)
    expect(html).not.toContain('Drag a session or a page here')
  })

  it('wears the session glyph, not the machine glyph', () => {
    const remote = pill(strip([LOCAL, REMOTE]), REMOTE_ID)
    expect(remote).toContain(KIND_ICON.session)
    expect(remote).not.toContain(MACHINE_ICON)
  })

  it('carries a status dot, exactly as the local pill does', () => {
    const html = strip([LOCAL, REMOTE])
    // `StatusDot`'s own words, which is the point: the remote row is not drawing
    // a second dot of its own, it is drawing the app's, so the colour, the fill
    // and the sentence a screen reader says are the same object on both pills.
    expect(pill(html, REMOTE_ID)).toContain('aria-label="Working"')
    expect(pill(html, 's1')).toContain('aria-label="Ready"')
  })

  it('is draggable, which is the other half of what he asked for', () => {
    // *"I cannot drag it up there."* The strip's drop target has always existed;
    // what was missing was a tab to drop. `draggable` on the tab is what makes
    // one already in the strip reorderable, and the rail's rows are the source
    // for getting one up here — both read the same promoted order.
    expect(pill(strip([LOCAL, REMOTE]), REMOTE_ID)).toContain('draggable="true"')
  })

  it('is the one drawn as selected when it is the one on screen', () => {
    const html = strip([LOCAL, REMOTE], { activeTabId: REMOTE_ID })
    expect(pill(html, REMOTE_ID)).toContain('aria-selected="true"')
    expect(pill(html, 's1')).toContain('aria-selected="false"')
  })

  it('says which machine in its tooltip and nowhere on the pill', () => {
    // The machine is the one fact that separates this pill from an identical
    // local one, and the pill deliberately does not draw it — the complaint is
    // that remote work *looked* like a different kind of thing. The hover is
    // where the difference is stated, which is the same trade the rail makes
    // with the account caption.
    expect(tabTooltip(REMOTE, 'Fix the parser')).toBe(
      'Fix the parser\nC:\\Users\\asad\\site on DESKTOP-DDGMNCV',
    )
    expect(tabTooltip(LOCAL, 'Session 1')).toBe('Session 1\n/p')
  })
})

describe('a remote pill’s ✕ takes it off the bar and cannot end it — 2026-08-20', () => {
  /*
   * It used to carry one that ended the session where it was running, on his
   * 2026-08-18 instruction. He reversed that after watching one of those presses
   * take a visible moment and another do nothing he could name, and then said
   * what the reversal meant: *"for the sessions it will just close from the top
   * bar, but it will still stay in the side panel."*
   *
   * A remote session takes the same road as a local one, and deliberately so —
   * the rail lists it under its machine's heading, and the whole point of the
   * pill was that a remote session should look and behave like a local one up
   * here. What used to make it special was the one thing it must not be: a ✕
   * that reached across the network and killed something.
   */
  it('has one, and it is the harmless one', () => {
    const html = strip([LOCAL, REMOTE], { onCloseWindow: () => {} })
    for (const id of [REMOTE_ID, 's1']) {
      expect(pill(html, id)).toContain('strip-tab-close')
      // `[data-ends]` is the mark for a control that destroys something. Its
      // absence here is the entire difference between this ✕ and the browser
      // window's, and the only one visible in the running app.
      expect(pill(html, id)).not.toContain('data-ends')
      expect(pill(html, id)).toContain('title="Take off the bar"')
    }
  })

  it('says nothing about ending anything, on either pill', () => {
    // The sentence that used to sit on a remote ✕ is gone with the handler that
    // made it true. A phrase left behind would describe a button that no longer
    // does what it says.
    const html = strip([LOCAL, REMOTE], { onCloseWindow: () => {} })
    expect(html).not.toContain('ends the session on')
    expect(html).not.toMatch(/aria-label="[^"]*[Cc]lose [^"]*Fix the parser/)
  })

  it('is absent, not inert, where the host cannot move the selection', () => {
    // Taking the tab you are *looking at* off the bar is the ordinary press, and
    // without `onShowInstead` the strip redraws it as transient — a ✕ that
    // visibly does nothing. So there is no ✕ rather than a broken one.
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[LOCAL, REMOTE]}
        activeTabId="s1"
        onSelect={() => {}}
        storage={promoting([LOCAL.id, REMOTE.id])}
      />,
    )
    expect(html).not.toContain('strip-tab-close')
  })
})

describe('the id that joins a machine to a session', () => {
  it('goes out and comes back', () => {
    expect(readMachineTabId(machineTabId('m-1', 'r1'))).toEqual({
      machineId: 'm-1',
      sessionId: 'r1',
    })
  })

  it('takes the whole remainder as the session id', () => {
    // Only the machine id has to be space-free — it is a UUID minted by
    // `machines/store.ts` — and the session id is whatever the far machine calls
    // it, so the split is on the first space and never on the last.
    expect(readMachineTabId(machineTabId('m-1', 'r 1 odd'))).toEqual({
      machineId: 'm-1',
      sessionId: 'r 1 odd',
    })
  })

  it('answers null for every id that is not one', () => {
    // The ordinary case, and the reason this is a question rather than an
    // assertion: `selectTab` and `closeTab` take an id from a click and route
    // it, and a router that throws on the common path is not a router.
    for (const id of ['s1', '', 'machine ', 'machine m-1', 'machine m-1 ', 'machinem-1 r1']) {
      expect(readMachineTabId(id), id).toBeNull()
    }
  })
})
