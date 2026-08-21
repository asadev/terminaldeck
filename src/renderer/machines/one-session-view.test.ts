import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * There is one in-session view, and the Remote panel lands on it.
 *
 * ## The complaint, in the part of it that was still open
 *
 * Asad, 2026-08-21:
 *
 *   > *"every time I tell you I want exactly same identical view of every type
 *   > of session inside, including remote session, including local session"*
 *
 * `shell/session-view-parity.test.ts` answered the half of that which lives in
 * `App.tsx`: one bar, one control cluster, one mode switch, one set of panes,
 * whichever of the three computers a session is running on. What it could not
 * see is that there was a **second** in-session view somewhere else entirely.
 *
 * A machine's card in the Remote panel lists the sessions running on it, and
 * pressing one used to draw that session's terminal *inside the panel*, in a
 * `.machines-pane` under a head with a title, a folder and a Close. No
 * controls, no model, no effort, no fast mode, no connectors, no usage bar, no
 * account chip, no Terminal/Chat, no Split. The same session opened from the
 * rail had every one of those. Two doors marked with one session, and the door
 * a person reaches by going to look at the machine it belongs to was the one
 * that opened onto less.
 *
 * That was the literal drift. This file pins that it is gone and that the press
 * goes where the rail's press goes.
 *
 * ## Why a source read
 *
 * Three of the four claims are about *which expression is wired to which*, over
 * files that cannot be rendered together: the panel is drawn by `PanelView`
 * from a `PanelId`, five components below the window whose state it now
 * reaches, and this repository's test environment has no DOM to mount an xterm
 * in. A render test can say a button exists; it cannot say where the press
 * lands, and "where the press lands" is the whole subject.
 *
 * The markup half is held where it belongs, beside the components:
 * `MachineLinks.test.tsx` (`lists what is running on a machine as ways into the
 * window…`, and the session-row cases) and `RemoteSection.test.tsx` (`opens a
 * session in the window’s view rather than in a second one here`).
 */

const SRC = join(__dirname, '..', '..', '..', 'src')
const APP = readFileSync(join(SRC, 'renderer', 'App.tsx'), 'utf8')
const LINKS = readFileSync(join(SRC, 'renderer', 'machines', 'MachineLinks.tsx'), 'utf8')
const REMOTE = readFileSync(join(SRC, 'renderer', 'remote', 'RemoteSection.tsx'), 'utf8')
const CONTEXT = readFileSync(join(SRC, 'renderer', 'machines', 'session-view-context.ts'), 'utf8')

/**
 * A source file with its prose taken out.
 *
 * These files argue at length about what they used to do, and three cases below
 * assert that something is *gone* — so a grep over the raw text would find the
 * paragraph explaining the removal and report the removal as undone. That is not
 * hypothetical: `shell/new-session-route.test.ts` shipped a case that stayed
 * green for two days because the identifier it looked for survived in the note
 * about its deletion.
 *
 * Block comments and whole-line `//` ones, and it stops there — the same helper,
 * with the same limit and for the same reason, as that file and
 * `reachable.test.ts`. Copied rather than exported from one of them, which
 * vitest would then have to treat as a suite with no tests in it.
 */
function withoutComments(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => {
      const trimmed = line.trimStart()
      return !trimmed.startsWith('//') && !trimmed.startsWith('*')
    })
    .join('\n')
}

describe('the Remote panel draws no session view of its own', () => {
  it('has no pane, no pane head and no Close over a terminal', () => {
    /*
     * The four class names are asserted together because the head is what made
     * this a *view* rather than a list: a title, a folder and a Close is a
     * session bar with three things on it, and three is the number that made it
     * look finished enough to leave alone.
     */
    const code = withoutComments(LINKS)
    expect(code, 'the second in-session view is back in the Remote panel').not.toContain(
      'machines-pane',
    )
    expect(code).not.toContain('machines-pane-head')
    expect(code).not.toContain('machines-pane-title')
  })

  it('is handed no terminal to draw, and keeps no state saying which one', () => {
    /*
     * `MachinesHalf.pane` was a `ReactNode` — the terminal, built by the caller
     * because it needs a DOM — and `MachinesHalf.open` was which session it was
     * for. Either one back is the panel owning a session again.
     *
     * Read off the interface rather than the component, because that is the seam
     * a second view would have to come back through: `MachineLinks` is pure and
     * takes what it draws.
     */
    const half = /export interface MachinesHalf \{[\s\S]*?\n\}/.exec(withoutComments(LINKS))?.[0] ?? ''
    expect(half, 'MachinesHalf has changed shape').not.toBe('')
    expect(half).not.toMatch(/^ {2}open[?]?:/m)
    expect(half).not.toMatch(/^ {2}pane[?]?:/m)
  })

  it('does not build a second copy of the far machine’s terminal', () => {
    /*
     * This is the mount that matters, and not only for tidiness. Unmounting a
     * remote session detaches from the far machine and the way back is answered
     * with the entire scrollback replayed — *"If I go to other page and come
     * back, it will start from beginning again."* The window mounts
     * `MachineSessionPane` once and keeps it mounted for the life of the window
     * precisely so that never happens; a copy in a panel is a second mount of
     * the same session that appears and disappears with a Close button, and both
     * of them write into the same `machines:output` subscription.
     */
    expect(
      withoutComments(REMOTE),
      'the Remote panel is mounting a far machine’s terminal again',
    ).not.toContain('MachineSessionPane')
  })

  it('leaves the window as the only place that mounts one', () => {
    // One mount, in the list of panes the window keeps up. Not "at least one":
    // the count is the claim, because a second one anywhere is the defect above
    // wearing a different file name.
    const mounts = APP.match(/<MachineSessionPane\b/g) ?? []
    expect(mounts, 'a far machine’s terminal is mounted more than once').toHaveLength(1)
    // And it is not inside `mainView`, which draws one thing and therefore
    // unmounts what it stops drawing. `shell/session-view-parity.test.ts` holds
    // the rest of that arrangement.
    expect(APP).toContain('machineSessionPanes.map((pane) => (')
  })
})

describe('a session row lands on the one view there is', () => {
  it('asks the window, through a context, because there is no prop route', () => {
    /*
     * `PanelView` draws all ten views off a `PanelId` and threads no per-view
     * props, and it is the shared file every parallel change is told not to
     * touch. `machines/session-view-context.ts` carries the whole argument; this
     * pins that the panel reads it rather than growing its own way up.
     */
    expect(withoutComments(REMOTE)).toContain('useMachineSessionView()')
    expect(withoutComments(REMOTE)).toMatch(
      /showSession:\s*\n?\s*sessionView === null\s*\n?\s*\? null/,
    )
  })

  it('carries both handles, and joins them nowhere but App.tsx', () => {
    /*
     * The window routes by the single id the two are joined into, and
     * `machineTabId` / `readMachineTabId` are the only code that knows how they
     * join. A context method that took the joined id would make the Remote panel
     * the second place that knows — which is the duplication those two functions
     * exist to prevent.
     */
    expect(CONTEXT).toMatch(/show\(machineId: string, sessionId: string\): void/)
    expect(withoutComments(LINKS)).not.toContain('machineTabId')
    expect(withoutComments(REMOTE)).not.toContain('machineTabId')
  })

  it('lands on `selectTab`, which is the road every other route already takes', () => {
    /*
     * The rail, the pill, ⌘1–9 and the command palette all arrive at `selectTab`,
     * and it is what clears the panel, gives the far session the frame when the
     * window is whole and the focused pane when it is split. A second expression
     * here — `setOpenMachineSession` straight, say — would answer those three
     * questions its own way, which is exactly how a second view starts.
     */
    const viewer = /const machineSessionViewer = useMemo\([\s\S]*?\n {2}\)/.exec(APP)?.[0] ?? ''
    expect(viewer, 'machineSessionViewer has changed shape').not.toBe('')
    expect(viewer).toContain('selectTab(machineTabId(machineId, sessionId))')
    expect(viewer, 'the panel’s press has grown its own way into the window').not.toContain(
      'setOpenMachineSession',
    )
    expect(APP).toContain('<MachineSessionViews.Provider value={machineSessionViewer}>')
  })

  it('is a separate context from the one that starts a session on a machine', () => {
    /*
     * They are one directory apart and one word apart. That one *starts* a
     * session on a far machine by opening the new-session dialog, and
     * `shell/new-session-route.test.ts` counts its methods to keep it carrying a
     * machine id and nothing else — because a second thing a press on that page
     * can mean is how the spawn-without-asking defect got in the first time.
     * This one *shows* a session that is already running.
     */
    expect(CONTEXT).not.toContain('openNewSessionDialog')
    const methods = CONTEXT.match(/^ {2}\w+\(/gm) ?? []
    expect(methods, 'the machine session view has grown a second method — what does it do?').toHaveLength(1)
  })

  it('draws no control at all where there is no window to act in', () => {
    /*
     * The standing rule, and the one a no-op default quietly breaks: a control
     * that cannot act must be absent. `machineActions` spreads `open` in rather
     * than assigning it, so "there is no window" reaches the row as a *missing*
     * method and the row draws its three facts as text. `MachineLinks.test.tsx`
     * renders both shapes; this pins the expression that makes them different.
     */
    const links = withoutComments(LINKS)
    expect(links).toContain('...(showSession === null ? {} : { open: showSession })')
    expect(links).toContain('actions.open === undefined')
  })
})
