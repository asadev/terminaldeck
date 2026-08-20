import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar, type SidebarMachine } from './Sidebar'
import { GroupHead } from './GroupHead'
import { machineTabId, MACHINE_ICON, type WorkspaceTab } from './workspace-tabs'
import { StoreProvider, type Project } from '../state/store'

/**
 * The machine group in the rail, and the three things he asked for on
 * 2026-08-18.
 *
 * The screen he was looking at: a `DESKTOP-DDGMNCV` heading with a monitor
 * glyph, and **every session row under it wearing the same monitor glyph**, with
 * a "New session on DESKTOP-DDGMNCV" row bolted underneath the list.
 *
 *   1. *"You don't need to give icon of the remote next to all of them — only
 *      above there, next to the PC, the remote device."* The rows below take the
 *      icons a local session row takes; being under the heading is already what
 *      says they are remote.
 *   2. *"You will give this exactly same, like this kind of pill to drop, with
 *      same drop-down, same button — continue last session, new session, or
 *      close."* The same component a project heading uses, not a lookalike.
 *   3. *"It will just close all of the sessions from that PC… it should not
 *      disconnect the remote account."*
 *
 * ## Why these assertions and not a screenshot
 *
 * Every one of the three is a claim about *which element is where*, and each one
 * of them was true of the markup on the night it was written and stopped being
 * true when somebody added a row. A count of monitor glyphs, and an identity
 * check between the two headings' markup, are the two facts that cannot be
 * satisfied by a second component that merely looks right today. The rendering
 * itself is checked by looking at it, which is the other half and is not this
 * file's job.
 */

const PROJECTS: Project[] = [{ path: '/p', name: 'p' }]

const LOCAL: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Session 1', status: 'idle', projectPath: '/p', closable: true },
]

const MACHINE_ID = 'm-1'
const REMOTE: WorkspaceTab[] = [
  {
    id: machineTabId(MACHINE_ID, 'r1'),
    kind: 'session',
    label: 'Fix the parser',
    status: 'working',
    projectPath: 'C:\\Users\\asad\\site',
    machine: { id: MACHINE_ID, name: 'DESKTOP-DDGMNCV' },
    closable: true,
  },
  {
    id: machineTabId(MACHINE_ID, 'r2'),
    kind: 'session',
    label: 'Session 2',
    status: 'idle',
    projectPath: 'C:\\Users\\asad\\site',
    machine: { id: MACHINE_ID, name: 'DESKTOP-DDGMNCV' },
    closable: true,
  },
]

function machineGroup(overrides: Partial<SidebarMachine> = {}): SidebarMachine {
  return {
    machineId: MACHINE_ID,
    name: 'DESKTOP-DDGMNCV',
    sessions: REMOTE,
    canClose: true,
    ...overrides,
  }
}

function railElement(props: {
  machines?: readonly SidebarMachine[]
  activeTabId?: string | null
  onCloseMachine?: (id: string) => void
  onNewMachineSession?: (id: string) => void
  canResume?: boolean
} = {}) {
  const { machines = [machineGroup()], activeTabId = 's1', ...rest } = props
  return (
    <Sidebar
      {...rest}
      width={280}
      projects={PROJECTS}
      tabs={LOCAL}
      machines={machines}
      activeTabId={activeTabId}
      activePanel={null}
      panels={[]}
      browser={false}
      browserOffer={null}
      alerts={false}
      alertCount={0}
      unread={[]}
      held={[]}
      peeking={false}
      update={null}
      onSelectTab={() => {}}
      onCloseTab={() => {}}
      onSelectPanel={() => {}}
      onNewSession={() => {}}
      onNewBrowserTab={() => {}}
      onOpenProject={() => {}}
      onCloseProject={() => {}}
      onOpenSettings={() => {}}
      onOpenAlerts={() => {}}
      onToggleCollapsed={() => {}}
      onPeekStart={() => {}}
      onPeekEnd={() => {}}
      onStartResize={() => {}}
      storage={null}
    />
  )
}

function rail(props: Parameters<typeof railElement>[0] = {}): string {
  return renderToStaticMarkup(railElement(props))
}

/** Every `<path d="…">` in the markup, so a glyph can be counted. */
function paths(html: string): string[] {
  return [...html.matchAll(/<path d="([^"]+)"/g)].map((match) => match[1])
}

describe('the monitor glyph is on the machine and on nothing else', () => {
  it('draws exactly one, however many sessions are under it', () => {
    // Two sessions on the machine. Before this change there were three marks —
    // one on the heading and one per row — and the group read as a foreign kind
    // of thing sitting in a list of ordinary ones.
    const marks = paths(rail()).filter((d) => d === MACHINE_ICON)
    expect(marks).toHaveLength(1)
  })

  it('still draws exactly one when the machine has nothing running', () => {
    // The empty state is the case where an off-by-one is invisible: with no rows
    // there is nothing to repeat the mark on, so a heading that had lost its own
    // would look the same as one that never had one.
    const marks = paths(rail({ machines: [machineGroup({ sessions: [] })] })).filter(
      (d) => d === MACHINE_ICON,
    )
    expect(marks).toHaveLength(1)
    expect(rail({ machines: [machineGroup({ sessions: [] })] })).toContain('Nothing running there.')
  })

  it('gives a remote row the same status dot a local row has', () => {
    const html = rail()
    // `StatusDot` owns the mark, the colour and the words a screen reader says,
    // and a remote row goes through the same `rowsFor` a project's rows do — so
    // the working session over there is drawn exactly as a working session here
    // is. The old markup drew a machine glyph in that slot and no dot at all.
    expect(html).toContain('Working')
    // And the row is a `.sb-row.sb-open` like any other, rather than a shape of
    // its own. `sb-machine-new`, the bolted-on last row, is gone with it.
    expect(html).not.toContain('sb-machine-new')
  })
})

describe('the machine heading is the project heading', () => {
  it('renders the same component, with the same classes and controls', () => {
    /*
     * The strongest available statement of "exactly same, not a lookalike":
     * render the two headings through `GroupHead` with the machine's extras
     * stripped, and require the markup to be identical. A second component
     * written to look the same would pass a class-name check and fail this.
     */
    const project = renderToStaticMarkup(
      <GroupHead
        name="n"
        title="t"
        open
        onToggle={() => {}}
        add={{ label: 'a', title: 'a', onPress: () => {} }}
        close={{ label: 'c', title: 'c', onPress: () => {} }}
      />,
    )
    expect(project).toContain('sb-row sb-project-head')
    expect(project).toContain('sb-project-name')
    // The rail's own heading and a machine's are the same markup up to the one
    // element a machine adds — see the count above.
    const machine = renderToStaticMarkup(
      <GroupHead
        name="n"
        title="t"
        open
        onToggle={() => {}}
        icon={MACHINE_ICON}
        add={{ label: 'a', title: 'a', onPress: () => {} }}
        close={{ label: 'c', title: 'c', onPress: () => {} }}
      />,
    )
    expect(machine.replace(/<svg class="sb-glyph sb-machine-mark".*?<\/svg>/, '')).toBe(project)
  })

  it('offers New session and Close on the machine, in the rail', () => {
    const html = rail()
    expect(html).toContain('New session on DESKTOP-DDGMNCV')
    expect(html).toContain('Close the sessions on DESKTOP-DDGMNCV')
  })

  it('never prints a keyboard shortcut on the machine’s New session', () => {
    // ⌘T starts a session on *this* computer. Printing it beside a button that
    // starts one on another machine would be the app claiming a key that goes
    // somewhere else — the same class of untruth as a folder chip that opens
    // nothing.
    const html = rail()
    const button = /<button[^>]*aria-label="New session on DESKTOP-DDGMNCV"[^>]*>/.exec(html)?.[0]
    expect(button, 'the machine’s New session button has changed shape').toBeTruthy()
    expect(button).not.toMatch(/⌘|Ctrl/)
  })

  it('draws no Continue on a machine, because nothing can continue there', () => {
    /*
     * He asked for all three controls. Two of them can act and one cannot:
     * `create` on the wire carries a cwd and a provider and no resume flag —
     * `protocol.ts` says so and calls it a live gap — so a Continue here would
     * start a *fresh* session silently, which is the exact defect the project
     * heading's own Continue was fixed for. A machine group also has no folder
     * of its own to continue in.
     *
     * Asserted against a rail rendered with `canResume` on, so this is "absent
     * on a machine" rather than "absent everywhere in this render".
     */
    const html = rail({ canResume: true })
    expect(html).toContain('Continue the last session in p')
    expect(html).not.toMatch(/Continue the last session on/)
  })

  it('says why Close cannot act against a machine that will not accept it', () => {
    // A machine on an older build never advertised `close`. The button stays —
    // its neighbours have one, and a silently missing control reads as the bug
    // he reported — and it carries the reason instead of a press that does
    // nothing.
    const html = rail({ machines: [machineGroup({ canClose: false })] })
    const button =
      /<button[^>]*aria-label="Close the sessions on DESKTOP-DDGMNCV"[^>]*>/.exec(html)?.[0] ?? ''
    expect(button).toContain('aria-disabled="true"')
    expect(button).toContain('cannot end sessions from here')
  })
})

describe('a remote row says where it is, in its hover and nowhere else', () => {
  it('names the folder and the machine in the row’s tooltip', () => {
    // The line carries the name and nothing else — that is what taking the mark
    // off every row means. The fact has to survive somewhere, and the hover is
    // where the rail already puts the account when the line runs out of room.
    expect(rail()).toContain('Fix the parser — C:\\Users\\asad\\site on DESKTOP-DDGMNCV')
  })

  it('says that the machine survives the close, wherever the close now lives', () => {
    /*
     * The question a person actually has, closing a session that belongs to a
     * computer they are not sitting at, is whether this unpairs it. He answered
     * it himself — *"it should not disconnect the remote account"* — and the
     * answer belongs on the control rather than in a dialog they reach by
     * committing to the press.
     *
     * The control moved on 2026-08-20: the row's ✕ became an entry in its ⋯
     * menu, which is a native menu built in the main process, so the sentence is
     * no longer in the markup to assert against. It is passed to the menu at the
     * moment it opens, and this reads it where it is now written — the
     * `closeSentence` in `Sidebar.tsx`. What is being held is the promise, not
     * the widget: neither half of it may be lost in the move.
     */
    const source = readFileSync(join(__dirname, 'Sidebar.tsx'), 'utf8')
    expect(source).toContain('ends the session on ${tab.machine.name}')
    expect(source).toContain('That machine stays connected.')
    // And a local row keeps the sentence it already had.
    expect(source).toContain('ends the session`')
    // The row still says which machine it belongs to, in the one place it ever
    // did — its own tooltip.
    expect(rail()).toContain('on DESKTOP-DDGMNCV')
  })

  it('offers no rename on a remote row, where a local one has it', () => {
    /*
     * `sessionRename` writes into *this* app's session store, keyed by session
     * id, and a remote session's id belongs to a store on another computer. So
     * the field would have taken a name, written a row nothing reads, and the
     * label would have gone back to what it said before — a control that appears
     * to work and does not, which is worse than one that is absent.
     *
     * Inside a `StoreProvider`, because that is what makes renaming available at
     * all: without one, `useSessionRename` reports unavailable and *no* row gets
     * the hint, so the assertion would pass against a rail that had simply lost
     * the feature. The local row is the control.
     */
    const html = renderToStaticMarkup(<StoreProvider>{railElement()}</StoreProvider>)
    expect(html).toMatch(/Session 1 — double-click or F2 to rename/)
    expect(html).not.toMatch(/Fix the parser[^"]*double-click or F2/)
  })
})

describe('a remote row is selected the same way a local one is', () => {
  it('marks the open remote session as current', () => {
    const html = rail({ activeTabId: machineTabId(MACHINE_ID, 'r1') })
    // One `aria-current="true"` on the rail, and it is the remote row — the
    // local session is no longer the selected one. Before this change the rail
    // took a separate `activeMachineSession` prop, which is two answers to one
    // question and is how a rail and a strip come to disagree.
    expect([...html.matchAll(/aria-current="true"/g)]).toHaveLength(1)
    expect(html).toMatch(/aria-current="true"[^>]*>.*?Fix the parser/s)
  })
})
