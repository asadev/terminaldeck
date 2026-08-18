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
 * reversed — and the ✕ is answered rather than avoided: it means what Close on
 * the machine's heading means, which is *"It will just close all of the sessions
 * from that PC… it should not disconnect the remote account."*
 *
 * ## What is pinned here, and why each one
 *
 * The pill has to be **indistinguishable** from a local one — same glyph, same
 * status dot — because "the shape of the application should not be changing for
 * local and remote devices" is the sentence he has now said three nights
 * running. And its ✕ has to be **distinguishable in what it says and does**,
 * because two controls a few pixels apart that do opposite things is the one
 * thing this bar has always been careful about. Those two pull against each
 * other, which is exactly why both halves need a test.
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
  props: { onEndRemote?: (id: string) => void; activeTabId?: string | null } = {},
): string {
  const { activeTabId = 's1', onEndRemote } = props
  return renderToStaticMarkup(
    <WorkspaceTabStrip
      tabs={tabs}
      activeTabId={activeTabId}
      onSelect={() => {}}
      onShowInstead={() => {}}
      {...(onEndRemote ? { onEndRemote } : {})}
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
        onShowInstead={() => {}}
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

describe('the ✕ on a remote pill ends the session, and says so', () => {
  it('is absent when the machine will not accept a close', () => {
    // Absent rather than drawn and inert — a machine on an older build never
    // advertised `close`, and a ✕ that sends a frame into silence is the fake
    // control this whole pass is removing. The tab can still leave the strip by
    // being dragged out or folded back from its row in the rail.
    const html = strip([{ ...REMOTE, closable: false }], { onEndRemote: () => {} })
    expect(pill(html, REMOTE_ID)).not.toContain('strip-tab-close')
  })

  it('is absent when the host gave the strip no way to end one', () => {
    // A bare mount — a test, the harness — has no handler, so there is no ✕
    // rather than one whose press goes nowhere.
    expect(pill(strip([REMOTE]), REMOTE_ID)).not.toContain('strip-tab-close')
  })

  it('does not describe itself the way a local ✕ does', () => {
    /*
     * The local one is harmless and its label says the whole sentence, because
     * the obvious reading of a ✕ is wrong there: *"it should not delete the
     * session… side panel will have everything inside."*
     *
     * The remote one is not harmless, so it must not borrow that sentence. Both
     * halves are asserted, because the failure that matters is the two drifting
     * into saying the same thing.
     */
    const html = strip([LOCAL, REMOTE], { onEndRemote: () => {} })
    expect(pill(html, 's1')).toContain('Remove from the top bar')
    const remote = pill(html, REMOTE_ID)
    expect(remote).not.toContain('Remove from the top bar')
    expect(remote).toContain('ends the session on DESKTOP-DDGMNCV')
    expect(remote).toContain('stays connected')
  })

  it('wears the mark that separates tidying from destroying', () => {
    // `[data-ends]` is what `WorkspaceTabStrip.css` paints `--color-critical` on
    // hover, which is the same mark the rail's ✕ has always had for the same
    // distinction. A local pill must not have it.
    const html = strip([LOCAL, REMOTE], { onEndRemote: () => {} })
    expect(pill(html, REMOTE_ID)).toContain('data-ends=""')
    expect(pill(html, 's1')).not.toContain('data-ends')
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
